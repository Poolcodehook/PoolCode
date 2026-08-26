// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ................................................****+...............................................
// ...............................................**...**..............................................
// ..............................................***....**...................:+*+......................
// .............................................**+.....-*:.................**...*****.................
// ...........................................+**.......**.................**.........***..............
// ........................................****..........*******..........+*..+*+.+.....*=.............
// ....................................=****...................+****......*+...+:+.==..-*=.............
// .................................+***...........................***...**.......==..:**..............
// ...............................***........................::...::::**-.**---.......-**..............
// .............................+**...........................:..:::::::**.*****----::**...............
// ...........................+*+.................................::::::.***...-*******................
// ..........................+*................................::::::::::.***..........................
// .........................*+................................:::::::.......+*.........................
// ........................**..................................::::::........+*........................
// .......................**...........................................:::....*+.......................
// ......................**.............................................::.....**......................
// .....................**.....................................................:**.....................
// ....................-**......................................................**.....................
// ....................**............ *.*+++..................*.**+.............:*+....................
// ....................**............:***+**=............... *+***+*............:**....................
// ...................**..............****++:................+*+*+++............:+*....................
// ...................**..........:....+++++......+*+**.......+++++..::.........::**...................
// ...................**........:::::::............................:::::::.....:::**...................
// ...................**:.......:::::::...........................:::::::......:::**...................
// ...................**:............................................::.......::::**...................
// ...................**::.............+.........................+...........:::::**...................
// ...................**:::.............**......................**..........:::::-*....................
// ....................**:::............:*.....................**..........::::::**....................
// ....................**-:::::....+******.....................:******...::::::::*:....................
// .....................**::::::.....::::.......................:::::..:::::::::**.....................
// ......................**::::::...................................:::::::::::**......................
// .......................**:::::::::............................::::::::::::+**.......................
// ........................=**:::::::::::...................::::::::::::::::**.........................
// .........................:****::::::::::::::::::::::::::::::::::::::::=**+::........................
// .......................:.....****::::::::::::::::::::::::::::::::::****...:::.......................
// .........................::...::******::::::::::::::::::::::::******::..::::........................
// .............................:......:=************************+.:...::::............................
// ........................................:.::............:.::.::.:...................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
//
//                                    https://x.com/pcodepool
//                                    https://pcodepool.org
//
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title PoolcodeToken — the fixed-supply PCODE ERC-20, the native-ETH reward ledger, and the
/// balance-checkpoint history that upgrade votes are weighed against.
///
/// POOLCODE is two contracts. This one owns everything that is a function of *balances*: the ERC-20
/// itself, the reward-index accounting, the claim path, the ETH held on behalf of holders, and the
/// per-block voting-power checkpoints. The other — PoolcodeHook — owns everything that is a function
/// of *swaps*: the Uniswap v4 pool binding, the 1% buy fee, the 4% sell fee, the 88-swap counter and
/// the module vote. The hook forwards 100% of every fee it takes into this contract through
/// `notifyFee`, and that is the only way ETH ever enters here.
///
/// ── the token/hook interface ─────────────────────────────────────────────────────────────────────
/// The two contracts are joined by exactly two calls. `notifyFee()` only ever pushes ETH *in*.
/// `getPastVotes()` is a view the hook reads while tallying a vote. The hook cannot move PCODE, cannot
/// read or write a holder's reward balance, and cannot withdraw a single wei. Binding a hook therefore
/// never grants it custody of anything.
///
/// The reward accounting lives here, next to the balances it is a function of, which is what keeps it
/// exact: `_update` runs on every mint, burn and transfer, so both sides of a balance change are
/// settled at their OLD balances *before* the new ones are written. A holder's earned ETH is banked at
/// the moment their balance changes and can never be diluted, front-run by a transfer, or carried to a
/// recipient — PCODE moves without carrying unsettled rewards with it.
///
/// ── voting power: checkpoints, not live balances ─────────────────────────────────────────────────
/// `1 PCODE = 1 vote`, with no cap, but a *live* balance would let one bag vote from wallet after
/// wallet: vote, transfer, vote again. So the same `_update` that settles rewards also writes a
/// balance checkpoint keyed by block number, and the hook only ever reads `getPastVotes(account, b)`
/// for a snapshot block `b` that is strictly in the past by the time any vote is cast. Moving tokens
/// after `b` changes nothing that the tally reads. Checkpoints are automatic and require no delegation
/// step — every holder's weight is simply their historical balance, which is why this uses
/// `Checkpoints.Trace208` directly rather than ERC20Votes (whose power is zero until you delegate).
///
/// ── trust assumptions ────────────────────────────────────────────────────────────────────────────
/// * Fixed supply: 100,000 PCODE minted once in the constructor. There is no mint function, no burn
///   privilege, no blacklist, no pause, no transfer tax, no transfer limit, and no way for anyone to
///   alter a balance.
/// * The token itself charges nothing. Wallet-to-wallet transfers are entirely fee-free; the only fee
///   in the system is the ETH one the hook charges on the official pool.
/// * The owner has exactly one power, `setHook`, which is one-shot: it reverts once a hook is bound.
///   It cannot redirect rewards (the hook can only pay in), cannot touch holder ETH, and cannot be
///   used twice. Afterwards ownership exists only so the launcher can renounce it as a public signal.
/// * Reward ETH is not withdrawable by anyone but its owner through `claimRewards`. There is no sweep,
///   no rescue function and no admin path to holder ETH.
contract PoolcodeToken is ERC20, Ownable, ReentrancyGuardTransient {
    using Checkpoints for Checkpoints.Trace208;

    // ── fixed parameters ─────────────────────────────────────────────────────────────────────────
    /// @notice The entire supply, minted once in the constructor. There is no other mint path.
    uint256 public constant SUPPLY = 100_000e18;

    /// @notice Fixed-point magnitude for the reward-per-share index.
    /// @dev 1e27, not 1e18. `rewardIndex += amount * MAG / totalShares` truncates, and with a
    /// 100,000e18 share denominator a 1e18 magnitude would strand ~1e-13 of every fee as dust. At 1e27
    /// the same fee loses well under a wei. Headroom is ample: even at 1e9 ETH of lifetime fees against
    /// a single-wei share the index stays far below 2^256.
    uint256 public constant MAG = 1e27;

    /// @notice Standard burn address, permanently excluded from rewards.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice A wallet's reward becomes sweepable after this long without a claim.
    uint256 public constant RESERVE_INTERVAL = 24 hours;

    // ── reserve wallet ────────────────────────────────────────────────────────────────────────────
    // Never receives fees directly; only sweeps rewards left unclaimed for a full day so nothing
    // strands. A reclaimed reward is credited to the reserve's own pending and withdrawn through the
    // same claimRewards() path as any holder — no ETH leaves on a reclaim.
    address private immutable reserve;

    // ── the bound hook ────────────────────────────────────────────────────────────────────────────
    /// @notice The PoolcodeHook that funds rewards here and runs the version machine. Set exactly once;
    /// the setter reverts on a second call, so the fee source is permanent and no owner can ever
    /// redirect it.
    address public hook;

    /// @notice Addresses that hold PCODE but earn no rewards and carry no vote: pool infrastructure and
    /// system addresses.
    mapping(address => bool) public excluded;

    // ── ETH holder rewards ────────────────────────────────────────────────────────────────────────
    /// @notice Cumulative ETH-per-token, summed over every fee ever received (MAG-fixed).
    uint256 public rewardIndex;
    /// @notice Σ PCODE held by reward-eligible wallets. Never counts excluded addresses.
    uint256 public totalShares;
    /// @notice Fees taken while no eligible wallet existed. Flushed into the next distribution.
    uint256 public ethBuffer;
    /// @notice Total ETH fees ever routed to holders.
    uint256 public totalRewardsCollected;
    /// @notice Total ETH ever paid out to holders.
    uint256 public totalRewardsPaid;

    /// @notice rewardIndex at a wallet's last settle — its reward debt.
    mapping(address => uint256) public rewardCheckpoint;
    /// @notice Settled, unclaimed reward ETH per wallet.
    mapping(address => uint256) public pending;
    /// @notice Total ETH a wallet has ever claimed.
    mapping(address => uint256) public claimedOf;
    /// @notice When a wallet's pending began accruing; refreshed by a claim and by a reclaim.
    mapping(address => uint64) public rewardClock;

    // ── voting-power checkpoints ──────────────────────────────────────────────────────────────────
    /// @dev Per-wallet balance history keyed by block number. Written in `_update`, so it tracks the
    /// ERC-20 balance exactly, with no delegation step. Excluded infrastructure is written as zero:
    /// the pool's own PCODE is liquidity, not a constituency, and must never be able to vote.
    mapping(address => Checkpoints.Trace208) private _voteHistory;
    /// @dev Σ eligible balances over time — the denominator a quorum or a turnout figure reads.
    Checkpoints.Trace208 private _totalVoteHistory;

    // ── events ────────────────────────────────────────────────────────────────────────────────────
    /// @notice Emitted once, when the hook is bound.
    event HookBound(address indexed hook, address indexed poolManager);
    /// @notice Emitted for every ETH fee received from the hook.
    event FeesCollected(uint256 amount, uint256 timestamp);
    /// @notice Emitted when a fee is distributed into the reward index.
    event RewardsAdded(uint256 amount, uint256 rewardIndex, uint256 timestamp);
    /// @notice Emitted when a fee arrives with no eligible holder and is parked in the buffer.
    event RewardsBuffered(uint256 amount, uint256 ethBuffer, uint256 timestamp);
    /// @notice Emitted when a holder withdraws reward ETH.
    event RewardsClaimed(address indexed account, uint256 amount, uint256 timestamp);
    /// @notice Emitted whenever a wallet's voting power changes.
    event VotingPowerChanged(address indexed account, uint256 previousVotes, uint256 newVotes);

    // ── custom errors ─────────────────────────────────────────────────────────────────────────────
    error NotHook();
    error HookAlreadySet();
    error NothingToClaim();
    error RewardNotExpired();
    error EthTransferFailed();
    error ZeroAddress();
    error ZeroFee();
    error FutureLookup();

    /// @dev Only the bound hook may push fees in. Before a hook is bound, nothing can.
    modifier onlyHook() {
        if (hook == address(0) || msg.sender != hook) revert NotHook();
        _;
    }

    /// @param reserve_ the reserve wallet that sweeps long-unclaimed rewards. It never receives a cut
    /// of any fee — it is not a treasury.
    /// @param owner_ the launcher: receives the full supply to seed the LP, binds the hook once, and
    /// may then renounce ownership.
    constructor(address reserve_, address owner_) ERC20("POOLCODE", "PCODE") Ownable(owner_) {
        if (reserve_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        reserve = reserve_;

        // Infrastructure and system addresses hold PCODE but are not real holders: no reward share and
        // no vote. address(0) is handled structurally in _update/_shareOf.
        excluded[address(this)] = true;
        excluded[DEAD] = true;
        // the reserve is bookkeeping-only: it accrues swept rewards but earns no share of its own
        excluded[reserve_] = true;

        // 100% of supply minted once to the launcher, who seeds it as Uniswap v4 liquidity.
        _mint(owner_, SUPPLY);
    }

    // ── binding the hook ──────────────────────────────────────────────────────────────────────────
    /// @notice Bind the PoolcodeHook that funds rewards, and exclude it and its PoolManager from
    /// earning a share or holding a vote. Callable once — a second call reverts, so the wiring is final.
    /// @dev The only owner-only function here, and a one-shot wiring step rather than an ongoing
    /// power: the hook it names can only send ETH in and read historical balances, never take any out.
    /// @param hook_ the deployed PoolcodeHook (its address encodes the v4 permission flags).
    /// @param poolManager_ the canonical Uniswap v4 PoolManager, excluded because the PCODE it
    /// custodies is pool liquidity, not a holder balance — and must therefore never carry a vote.
    function setHook(address hook_, address poolManager_) external onlyOwner {
        if (hook != address(0)) revert HookAlreadySet();
        if (hook_ == address(0) || poolManager_ == address(0)) revert ZeroAddress();
        hook = hook_;
        _excludeAndSettle(hook_);
        _excludeAndSettle(poolManager_);
        emit HookBound(hook_, poolManager_);
    }

    /// @dev Exclude an address, removing any share it already counted toward totalShares so the
    /// denominator stays exactly Σ eligible balances, and zeroing its voting checkpoint so pool-held
    /// PCODE can never be voted. Settling first banks whatever it had earned.
    function _excludeAndSettle(address account) private {
        if (excluded[account]) return;
        _settle(account);
        excluded[account] = true;
        uint256 bal = balanceOf(account);
        if (bal > 0) {
            totalShares -= bal;
            _writeVotes(account, 0);
            _writeTotalVotes(totalShares);
        }
    }

    // ── fee intake ────────────────────────────────────────────────────────────────────────────────
    /// @notice Receive an ETH fee from the hook and push 100% of it into the reward index.
    /// @dev The only way ETH enters this contract, and only the bound hook may call it, so the
    /// balance here is always exactly the unclaimed portion of collected fees. There is deliberately
    /// no bare `receive()`: a stray transfer cannot inflate the ledger or strand ETH.
    function notifyFee() external payable onlyHook {
        if (msg.value == 0) revert ZeroFee();
        emit FeesCollected(msg.value, block.timestamp);
        _bank(msg.value);
    }

    // ── reward accounting ─────────────────────────────────────────────────────────────────────────
    /// @dev Push a fee into the per-share index. With no eligible holder the fee waits in the buffer
    /// and joins the next distribution, so no ETH is ever lost or stranded.
    function _bank(uint256 fee) private {
        totalRewardsCollected += fee;
        uint256 shares = totalShares;
        if (shares > 0) {
            uint256 amount = fee + ethBuffer;
            ethBuffer = 0;
            rewardIndex += amount * MAG / shares;
            emit RewardsAdded(amount, rewardIndex, block.timestamp);
        } else {
            ethBuffer += fee;
            emit RewardsBuffered(fee, ethBuffer, block.timestamp);
        }
    }

    /// @dev A wallet's reward share is its PCODE balance unless it is excluded infrastructure.
    function _shareOf(address account) private view returns (uint256) {
        return excluded[account] ? 0 : balanceOf(account);
    }

    /// @dev Settle a wallet's accrued reward into its claimable `pending` at its CURRENT balance, then
    /// move its checkpoint forward. Starts the wallet's 24h clock the first time a reward lands.
    function _settle(address account) private {
        uint256 share = _shareOf(account);
        uint256 idx = rewardIndex;
        if (share > 0) {
            uint256 owed = share * (idx - rewardCheckpoint[account]) / MAG;
            if (owed > 0) {
                pending[account] += owed;
                if (rewardClock[account] == 0) rewardClock[account] = uint64(block.timestamp);
            }
        }
        rewardCheckpoint[account] = idx;
    }

    /// @dev The heart of the token/hook interface: settle both parties BEFORE balances move, then keep
    /// totalShares and the voting checkpoints in step with eligible balances. Because this runs inside
    /// every mint, burn and transfer, rewards are always computed against the balance actually held
    /// while they accrued — PCODE carries no unsettled reward to its recipient, so no transfer can
    /// capture, dilute or front-run someone else's earnings — and voting power is recorded at the block
    /// the balance actually moved, which is what makes a past-block tally immune to reshuffling.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) _settle(from);
        if (to != address(0)) _settle(to);
        super._update(from, to, value);

        bool fromEligible = from != address(0) && !excluded[from];
        bool toEligible = to != address(0) && !excluded[to];
        if (fromEligible && !toEligible) totalShares -= value;
        else if (!fromEligible && toEligible) totalShares += value;

        // Checkpoint the new balances. Only eligible wallets get a nonzero entry, so excluded
        // infrastructure (pool, hook, PoolManager, reserve, dead) always reads back as zero votes.
        if (fromEligible) _writeVotes(from, balanceOf(from));
        if (toEligible) _writeVotes(to, balanceOf(to));
        if (fromEligible != toEligible) _writeTotalVotes(totalShares);
    }

    /// @dev Write one wallet's voting checkpoint for the current block. Pushing twice in a block simply
    /// overwrites the block's entry, so the value a past-block lookup returns is the wallet's balance as
    /// of the END of that block — settled, not mid-transaction.
    function _writeVotes(address account, uint256 newVotes) private {
        (uint256 old, uint256 latest) = _voteHistory[account].push(_clock(), SafeCast.toUint208(newVotes));
        if (old != latest) emit VotingPowerChanged(account, old, latest);
    }

    /// @dev Same, for the eligible-supply denominator.
    function _writeTotalVotes(uint256 newTotal) private {
        _totalVoteHistory.push(_clock(), SafeCast.toUint208(newTotal));
    }

    /// @dev The checkpoint clock: block numbers, matching how the hook snapshots a vote.
    function _clock() private view returns (uint48) {
        return SafeCast.toUint48(block.number);
    }

    // ── voting-power views (read by the hook) ─────────────────────────────────────────────────────
    /// @notice The clock these checkpoints are keyed by. Block numbers, per EIP-6372.
    function clock() external view returns (uint48) {
        return _clock();
    }

    /// @notice EIP-6372 machine-readable clock description.
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=blocknumber&from=default";
    }

    /// @notice A wallet's voting power right now — its live eligible balance.
    /// @dev Present for interfaces and UIs. The hook never tallies against this: a vote is always
    /// weighed at a past snapshot block, which is the whole point of the checkpoint history.
    function getVotes(address account) external view returns (uint256) {
        return _voteHistory[account].latest();
    }

    /// @notice A wallet's voting power as of the END of `blockNumber` — the value an upgrade vote is
    /// weighed at. Reverts for a block that has not been mined yet, so a snapshot can never be taken of
    /// a future state.
    /// @dev This is the one call the hook makes into the vote tally. Because `blockNumber` is strictly
    /// in the past, moving PCODE afterwards cannot change what it returns: a bag that has already voted
    /// carries no fresh power to the next wallet it lands in.
    function getPastVotes(address account, uint256 blockNumber) external view returns (uint256) {
        if (blockNumber >= block.number) revert FutureLookup();
        return _voteHistory[account].upperLookupRecent(SafeCast.toUint48(blockNumber));
    }

    /// @notice The total eligible voting supply as of the END of `blockNumber` — the denominator for
    /// turnout and quorum figures.
    function getPastTotalVotes(uint256 blockNumber) external view returns (uint256) {
        if (blockNumber >= block.number) revert FutureLookup();
        return _totalVoteHistory.upperLookupRecent(SafeCast.toUint48(blockNumber));
    }

    /// @notice How many checkpoints a wallet has. Exposed for indexers; unbounded reads are never
    /// performed on-chain.
    function numCheckpoints(address account) external view returns (uint256) {
        return _voteHistory[account].length();
    }

    // ── claims ────────────────────────────────────────────────────────────────────────────────────
    /// @notice Withdraw your reward ETH — your share of every fee taken while you held PCODE. No
    /// staking, no minimum balance, no lockup; rewards already settled stay claimable even at a zero
    /// balance. Claiming refreshes your 24h window, so an active holder is never swept.
    /// @dev Checks-effects-interactions: pending is zeroed and every counter updated before the ETH is
    /// sent, and the call is reentrancy-guarded, so a reentrant receiver cannot be paid twice.
    /// @return amount the ETH paid out.
    function claimRewards() external nonReentrant returns (uint256 amount) {
        _settle(msg.sender);
        amount = pending[msg.sender];
        if (amount == 0) revert NothingToClaim();
        pending[msg.sender] = 0;
        rewardClock[msg.sender] = uint64(block.timestamp); // claiming refreshes the 24h window
        claimedOf[msg.sender] += amount;
        totalRewardsPaid += amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit RewardsClaimed(msg.sender, amount, block.timestamp);
    }

    /// @notice Fold a wallet's accrued reward into its claimable balance without paying out.
    /// Permissionless: it only moves a wallet's own reward from "accruing" to "settled".
    function sync(address account) external {
        _settle(account);
    }

    // ── reclaiming long-unclaimed rewards ─────────────────────────────────────────────────────────
    /// @notice Fold a wallet's reward into the reserve's pending once it has gone unclaimed for a full
    /// day, so nothing strands forever. There is NO global cooldown: a stale reward is reclaimable the
    /// moment it expires, and because a reclaim only moves the reward into another pending balance (no
    /// ETH leaves the contract, no shared timer is touched) it is safe to leave permissionless — no
    /// caller can grief another. The reserve later withdraws through claimRewards() like any holder,
    /// and never touches the wallet's PCODE.
    ///
    /// The wallet's window restarts on a reclaim, so an idle holder keeps cycling rather than being
    /// swept repeatedly on one expired clock. No ETH moves here: totalRewardsPaid is charged only
    /// when the reserve actually withdraws.
    /// @return amount the ETH moved into the reserve's pending.
    /// @dev The move is written in Yul; `_settle` stays in Solidity. Slots come from `.slot`, so
    /// reordering the state above cannot point this at the wrong mapping.
    ///
    /// Three things the code does not say for itself. `add(add(clk, 1), RESERVE_INTERVAL)` spells the
    /// `<=` guard Yul has no opcode for: `lt(timestamp(), clk + 1 + INTERVAL)` is exactly
    /// `timestamp <= clk + INTERVAL`, so the boundary second is not yet expired. Storing a full word
    /// into `rewardClock` is safe because its `uint64` values each occupy a whole slot — nothing
    /// shares those bits. And the unchecked `add` cannot overflow: the reserve's pending only grows by
    /// amounts already counted in `pending`, whose sum is bounded by the ETH this contract holds.
    function reclaim(address account) external returns (uint256 amount) {
        address reserve_ = reserve;
        bytes32 sigRewardNotExpired = 0xed5be5ce00000000000000000000000000000000000000000000000000000000;
        bytes32 sigNothingToClaim = 0x969bf72800000000000000000000000000000000000000000000000000000000;
        assembly {
            if eq(account, reserve_) {
                mstore(0x00, sigRewardNotExpired)
                revert(0x00, 0x04)
            }
        }

        _settle(account);

        assembly {
            mstore(0x00, account)
            mstore(0x20, rewardClock.slot)
            let clockSlot := keccak256(0x00, 0x40)
            let clk := sload(clockSlot)

            if or(iszero(clk), lt(timestamp(), add(add(clk, 1), RESERVE_INTERVAL))) {
                mstore(0x00, sigRewardNotExpired)
                revert(0x00, 0x04)
            }

            mstore(0x00, account)
            mstore(0x20, pending.slot)
            let pendingSlot := keccak256(0x00, 0x40)
            amount := sload(pendingSlot)
            if iszero(amount) {
                mstore(0x00, sigNothingToClaim)
                revert(0x00, 0x04)
            }

            sstore(pendingSlot, 0)
            sstore(clockSlot, timestamp())

            mstore(0x00, reserve_)
            mstore(0x20, pending.slot)
            let reserveSlot := keccak256(0x00, 0x40)
            sstore(reserveSlot, add(sload(reserveSlot), amount))
        }
    }

    // ── reward views ──────────────────────────────────────────────────────────────────────────────
    /// @notice A wallet's claimable reward ETH right now: what is already settled plus what it has
    /// earned since its last settle. This is exact at all times — no sync is needed to read it.
    function pendingRewards(address account) public view returns (uint256 amount) {
        amount = pending[account];
        uint256 share = _shareOf(account);
        if (share > 0) amount += share * (rewardIndex - rewardCheckpoint[account]) / MAG;
    }

    /// @notice Total ETH ever routed to holders, including anything still waiting in the buffer.
    function totalRewardsDistributed() external view returns (uint256) {
        return totalRewardsCollected;
    }

    /// @notice Total ETH ever claimed by holders.
    function totalRewardsClaimed() external view returns (uint256) {
        return totalRewardsPaid;
    }

    /// @notice The total ETH a given wallet has ever claimed.
    function lifetimeClaimed(address account) external view returns (uint256) {
        return claimedOf[account];
    }

    /// @notice The ETH still owed to holders: everything collected that has not been paid out. The
    /// contract's balance must always be at least this much.
    function rewardLiabilities() external view returns (uint256) {
        return totalRewardsCollected - totalRewardsPaid;
    }

    /// @notice When a wallet's unclaimed reward becomes reclaimable. Zero if its clock never started.
    function reclaimableAt(address account) external view returns (uint256 expiresAt) {
        uint64 clk = rewardClock[account];
        expiresAt = clk == 0 ? 0 : uint256(clk) + RESERVE_INTERVAL;
    }

    /// @notice Whether a wallet's reward is reclaimable right now, and what a reclaim would move.
    /// Callers use this to pick which accounts are worth a reclaim() call.
    function isReclaimable(address account) public view returns (bool reclaimable, uint256 amount) {
        if (account == reserve) return (false, 0);
        uint64 clk = rewardClock[account];
        if (clk == 0 || block.timestamp <= uint256(clk) + RESERVE_INTERVAL) return (false, 0);
        amount = pendingRewards(account);
        reclaimable = amount > 0;
    }
}
