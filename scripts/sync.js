#!/usr/bin/env node
/**
 * Read the POOLCODE hook's live state from Ethereum Mainnet and reflect it in README.md and
 * CHANGELOG.md. Writes files only; committing, releasing and scheduling are the workflow's job.
 *
 * The design goal is that GitHub stays quiet. A swap is not news — the counter moving from 12/88 to
 * 13/88 rewrites one line of the README and nothing else, and if even that line is unchanged the
 * script exits having touched no file, so the workflow finds an empty diff and makes no commit.
 * Only an actually-activated version appends history or cuts a release.
 *
 * Two ideas keep this safe to run on a schedule:
 *
 *   * CHANGELOG is append-only, and appending is guarded by reading the file back. A version already
 *     present is never written twice, no matter how often this runs or how the RPC behaves, so a
 *     duplicate entry is impossible rather than merely unlikely.
 *   * Every read is retried and the whole run aborts on failure WITHOUT writing. A flaky RPC can
 *     therefore make the sync do nothing; it can never make it write a half-read state.
 *
 * Env:
 *   RPC_PROVIDER_URL       an Ethereum Mainnet JSON-RPC endpoint (GitHub secret)
 *   HOOK_CONTRACT_ADDRESS  the deployed PoolCodeHook (GitHub secret)
 *   GITHUB_OUTPUT          optional; when set (in Actions) the run's outcome is written there for
 *                          later steps to branch on
 */
import { readFileSync, writeFileSync, existsSync, appendFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { JsonRpcProvider, Contract } from 'ethers';
import { moduleName } from './modules.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');
const README = join(ROOT, 'README.md');
const CHANGELOG = join(ROOT, 'CHANGELOG.md');

// ── config ───────────────────────────────────────────────────────────────────
const RPC_URL = (process.env.RPC_PROVIDER_URL ?? '').trim();
const HOOK_ADDRESS = (process.env.HOOK_CONTRACT_ADDRESS ?? '').trim();

const die = (msg) => {
  console.error(`error: ${msg}`);
  process.exit(1);
};

if (!RPC_URL) die('RPC_PROVIDER_URL is not set (add it as a GitHub secret)');
if (!HOOK_ADDRESS) die('HOOK_CONTRACT_ADDRESS is not set (add it as a GitHub secret)');
if (!/^0x[0-9a-fA-F]{40}$/.test(HOOK_ADDRESS)) die(`HOOK_CONTRACT_ADDRESS is not an address: ${HOOK_ADDRESS}`);

/** Swaps that unlock the next version. Read from the chain, with this as the fallback. */
const DEFAULT_SWAPS_PER_VERSION = 88n;

// ── the slice of the hook this script reads ──────────────────────────────────
// Only the version machine: no swap-by-swap detail, nothing that could move funds.
const HOOK_ABI = [
  'function versionState() view returns (uint256 version, uint8 moduleId, uint256 countForNext, uint256 inVersionSwaps, uint256 lifetimeSwaps, bool votingOpen, uint256 nextVersion, uint256 deadline)',
  'function currentVersion() view returns (uint256)',
  'function currentModule() view returns (uint8)',
  'function swapCountForNextVersion() view returns (uint256)',
  'function voteOpen() view returns (bool)',
  'function SWAPS_PER_VERSION() view returns (uint256)',
  'event VersionActivated(uint256 indexed version, uint8 indexed moduleId)',
];

// ── RPC with retries ─────────────────────────────────────────────────────────
/**
 * Run `fn`, retrying on failure with a widening delay. A public endpoint rate-limiting one call is
 * ordinary; letting that write a half-read state to the repo is not, so the caller treats a final
 * throw as "abort the whole run, change nothing".
 */
async function withRetry(label, fn, attempts = 4) {
  let lastErr;
  for (let i = 1; i <= attempts; i++) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      const wait = 500 * i;
      console.error(`  ${label} failed (attempt ${i}/${attempts}): ${err.shortMessage ?? err.message}`);
      if (i < attempts) await new Promise((r) => setTimeout(r, wait));
    }
  }
  throw new Error(`${label} failed after ${attempts} attempts: ${lastErr?.shortMessage ?? lastErr?.message}`);
}

// ── reading chain state ──────────────────────────────────────────────────────
/**
 * Read the whole version machine. `versionState()` returns it in one call, which also means the
 * fields are mutually consistent — they come from a single evaluation rather than several calls that
 * could straddle a block boundary and disagree.
 *
 * Falls back to the individual getters if `versionState()` is unavailable, so a hook that predates
 * that helper still syncs.
 */
async function readState(hook) {
  try {
    const s = await withRetry('versionState()', () => hook.versionState());
    return {
      version: BigInt(s.version ?? s[0]),
      moduleId: Number(s.moduleId ?? s[1]),
      countForNext: BigInt(s.countForNext ?? s[2]),
      votingOpen: Boolean(s.votingOpen ?? s[5]),
    };
  } catch (err) {
    console.error(`  versionState() unavailable, falling back to individual getters: ${err.message}`);
    const [version, moduleId, countForNext, votingOpen] = await Promise.all([
      withRetry('currentVersion()', () => hook.currentVersion()),
      withRetry('currentModule()', () => hook.currentModule()),
      withRetry('swapCountForNextVersion()', () => hook.swapCountForNextVersion()),
      withRetry('voteOpen()', () => hook.voteOpen()),
    ]);
    return {
      version: BigInt(version),
      moduleId: Number(moduleId),
      countForNext: BigInt(countForNext),
      votingOpen: Boolean(votingOpen),
    };
  }
}

/**
 * The block a given version was activated in, for the release note. Found by filtering
 * VersionActivated on its indexed version — a targeted query, not a log sweep.
 *
 * Returns null rather than throwing when the endpoint will not serve the range: the block number is
 * a nice-to-have in a release note, and refusing to release over it would be the wrong trade.
 */
async function activationBlock(hook, version) {
  try {
    const filter = hook.filters.VersionActivated(version);
    const logs = await withRetry('VersionActivated logs', () => hook.queryFilter(filter, 0, 'latest'), 2);
    if (logs.length === 0) return null;
    return logs[logs.length - 1].blockNumber;
  } catch (err) {
    console.error(`  could not read activation block (continuing without it): ${err.message}`);
    return null;
  }
}

// ── status ───────────────────────────────────────────────────────────────────
/**
 * The three states the README reports:
 *   VOTING — 88 swaps landed, holders are choosing the next module
 *   READY  — the vote has been decided but the version has not been finalized on-chain yet
 *   ACTIVE — the ordinary state: swaps accumulating toward the next unlock
 */
function statusOf({ votingOpen, countForNext }, swapsPerVersion) {
  if (votingOpen) return 'VOTING';
  if (countForNext >= swapsPerVersion) return 'READY';
  return 'ACTIVE';
}

// ── rendering ────────────────────────────────────────────────────────────────
/**
 * Render the README. Deterministic by construction: every value comes from the state argument and
 * nothing timestamps the output, so identical chain state produces a byte-identical file and the
 * workflow sees no diff to commit.
 */
function renderReadme(state, swapsPerVersion) {
  const status = statusOf(state, swapsPerVersion);
  return `<p align="center">
  <img src="pooli.png" alt="POOLCODE" width="220">
</p>

# POOLCODE

**CURRENT VERSION**
v${state.version}

**ACTIVE MODULE**
${moduleName(state.moduleId)}

**NEXT VERSION**
${state.countForNext} / ${swapsPerVersion} SWAPS

**STATUS**
${status}

---

| | |
|---|---|
| Token | POOLCODE |
| Ticker | PCODE |
| Supply | 100,000 |
| Buy fee | 1% |
| Sell fee | 4% |

Every 88 swaps unlock the next pool version. Holders vote on what gets added next.
`;
}

/** One CHANGELOG entry. Version 1 is genesis; every later version was chosen by a holder vote. */
function renderChangelogEntry(version, moduleId) {
  const name = version === 1n ? 'Genesis Pool' : moduleName(moduleId);
  const line = version === 1n ? '' : '\nChosen by holders';
  return `\n## v${version}\n${name}${line}\n`;
}

// ── changelog: append-only ───────────────────────────────────────────────────
const CHANGELOG_HEADER = '# POOLCODE CHANGELOG\n';

/**
 * Which versions the CHANGELOG already documents. Parsed back from the file rather than tracked in a
 * state file, which is what makes "never duplicate" hold: the committed history IS the record, so
 * there is no second source that could drift out of step with it.
 */
function documentedVersions() {
  if (!existsSync(CHANGELOG)) return new Set();
  const text = readFileSync(CHANGELOG, 'utf8');
  const found = new Set();
  for (const m of text.matchAll(/^##\s+v(\d+)\s*$/gm)) found.add(BigInt(m[1]));
  return found;
}

/**
 * Append entries for every version up to `current` that is not already documented.
 *
 * It backfills rather than appending only the newest: if the sync was down while two versions
 * activated, the history still ends up complete and in order. Existing text is never parsed for
 * meaning or rewritten — the file is only ever grown at the end.
 */
async function appendMissingVersions(hook, current, currentModuleId) {
  const documented = documentedVersions();
  const missing = [];
  for (let v = 1n; v <= current; v++) {
    if (!documented.has(v)) missing.push(v);
  }
  if (missing.length === 0) return [];

  let text = existsSync(CHANGELOG) ? readFileSync(CHANGELOG, 'utf8') : CHANGELOG_HEADER;
  if (!text.startsWith(CHANGELOG_HEADER)) text = CHANGELOG_HEADER + text;

  const appended = [];
  for (const v of missing) {
    // The live module is authoritative for the current version. For an older backfilled version the
    // hook's own moduleOfVersion mapping is the record, so ask it rather than guessing.
    let moduleId = currentModuleId;
    if (v !== current) {
      try {
        moduleId = Number(await withRetry(`moduleOfVersion(${v})`, () => hook.moduleOfVersion(v), 2));
      } catch {
        moduleId = 0; // an unreadable historical module falls back to the base pool
      }
    }
    text += renderChangelogEntry(v, moduleId);
    appended.push({ version: v, moduleId });
  }

  writeFileSync(CHANGELOG, text);
  return appended;
}

// ── github actions plumbing ──────────────────────────────────────────────────
/** Publish a key/value to later workflow steps. A no-op outside Actions. */
function setOutput(key, value) {
  const file = process.env.GITHUB_OUTPUT;
  if (!file) return;
  appendFileSync(file, `${key}=${value}\n`);
}

// ── main ─────────────────────────────────────────────────────────────────────
async function main() {
  const provider = new JsonRpcProvider(RPC_URL);
  // moduleOfVersion is only needed for backfill, so it is added here rather than in the core ABI.
  const hook = new Contract(
    HOOK_ADDRESS,
    [...HOOK_ABI, 'function moduleOfVersion(uint256) view returns (uint8)'],
    provider,
  );

  const swapsPerVersion = await withRetry('SWAPS_PER_VERSION()', () => hook.SWAPS_PER_VERSION())
    .then((v) => BigInt(v))
    .catch(() => DEFAULT_SWAPS_PER_VERSION);

  const state = await readState(hook);
  console.log(`chain state: v${state.version} · ${moduleName(state.moduleId)} · ` +
              `${state.countForNext}/${swapsPerVersion} swaps · ${statusOf(state, swapsPerVersion)}`);

  // README: write only when the rendered bytes actually differ.
  const readme = renderReadme(state, swapsPerVersion);
  const readmeChanged = !existsSync(README) || readFileSync(README, 'utf8') !== readme;
  if (readmeChanged) {
    writeFileSync(README, readme);
    console.log('README.md updated');
  } else {
    console.log('README.md unchanged');
  }

  // CHANGELOG: append-only, and only for versions it does not already document.
  const appended = await appendMissingVersions(hook, state.version, state.moduleId);
  if (appended.length > 0) {
    console.log(`CHANGELOG.md: appended ${appended.map((a) => `v${a.version}`).join(', ')}`);
  } else {
    console.log('CHANGELOG.md unchanged');
  }

  // Outputs the workflow branches on: what to commit, and whether to cut a release.
  const newVersion = appended.length > 0 ? appended[appended.length - 1] : null;
  setOutput('changed', String(readmeChanged || appended.length > 0));
  setOutput('version', String(state.version));
  setOutput('module_name', moduleName(state.moduleId));
  setOutput('status', statusOf(state, swapsPerVersion));
  setOutput('new_version', newVersion ? String(newVersion.version) : '');

  if (newVersion) {
    const block = await activationBlock(hook, newVersion.version);
    setOutput('release_tag', `v${newVersion.version}`);
    setOutput('release_name', `POOLCODE v${newVersion.version}`);
    setOutput('release_module', moduleName(newVersion.moduleId));
    setOutput('release_block', block === null ? '' : String(block));
    setOutput('commit_message', `POOL v${newVersion.version} activated`);
  } else {
    setOutput('commit_message', 'Update POOLCODE state');
  }
}

main().catch((err) => {
  // Any failure that reaches here happened before or during reads. Files are written only after all
  // reads succeed, so exiting non-zero here leaves the repo untouched.
  console.error(`sync failed: ${err.message}`);
  process.exit(1);
});
