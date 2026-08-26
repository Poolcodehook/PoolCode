// Module id -> readable name.
//
// The hook stores a module as a uint8 that selects one branch of its fee arithmetic; the names below
// are the human-facing labels for those ids. To add a module later, append one line — nothing else in
// the sync reads this table by index, so the list can grow without touching any other file.
//
// Ids must match the constants in contracts/PoolCodeHook.sol:
//   MODULE_BASE = 0, MODULE_TIDE = 1, MODULE_CASCADE = 2, MODULE_BEACON = 3
export const MODULE_NAMES = {
  0: 'Base Pool',
  1: 'Swap Streak',
  2: 'Liquidity Event',
  3: 'Quiet Mode',
};

/**
 * Resolve a module id to its label.
 *
 * An id with no entry is reported as `Module <id>` rather than throwing: the chain is the source of
 * truth, so a hook upgraded with a module this table has not learned yet must still sync — it just
 * shows an unnamed module until someone adds the line.
 */
export function moduleName(id) {
  const key = Number(id);
  return MODULE_NAMES[key] ?? `Module ${key}`;
}
