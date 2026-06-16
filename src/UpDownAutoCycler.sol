// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUpDownSettlement} from "./interfaces/IUpDownSettlement.sol";
import {ChainlinkResolver} from "./ChainlinkResolver.sol";

/// @title UpDownAutoCycler
/// @notice Chainlink Automation-compatible keeper that auto-creates and auto-resolves
///         UpDown prediction markets (e.g. BTC/USD) on 5, 15, and 60-minute cycles.
///         Markets are created inside a single `UpDownSettlement` contract (no per-market deploy).
contract UpDownAutoCycler is Ownable2Step {
    using SafeERC20 for IERC20;

    // ── Errors ──────────────────────────────────────────────────────────
    error InvalidTimeframeIndex();
    error PreStartWindowTooLarge();
    /// @notice F-04 complement: zero-address at construction would brick the
    ///         cycler permanently because `resolver`/`settlement` are
    ///         immutable. Symmetric with `ChainlinkResolver.ZeroTrustedSettlement`.
    error ZeroAddress();
    /// @notice F-02 (deep review 2026-05-11): a slot's `plannedStart + duration`
    ///         is already more than `RESOLVER_MAX_STALENESS` behind
    ///         `block.timestamp`. The resolver's Chainlink staleness check
    ///         (`ChainlinkResolver.MAX_STALENESS`) would reject any resolve
    ///         attempt on this market with `StalePrice()`, so we refuse to
    ///         create it. Closes the catch-up shadow-market class structurally.
    error PlannedStartTooStale(uint256 plannedStart, uint256 plannedEnd, uint256 nowTs);
    /// @notice F-06 part 1 (deep review 2026-05-11): the strike returned by
    ///         `resolver.getPrice` doesn't fit in `int128`. The settlement
    ///         stores `strikePrice` as `int128`; a silent downcast there
    ///         followed by the resolver's `int256(sm.strikePrice) != strikePrice`
    ///         consistency check at `registerMarket` would cascade into a
    ///         `MarketNotRegistered()` revert. Range-check loudly here
    ///         instead. Unreachable for BTC/USD at 8 decimals today; matters
    ///         for any future pair with a higher-decimal or larger-magnitude feed.
    error StrikeOverflow(int256 strike);
    /// @notice #21 (POST_DEMO_TODO 2026-05-06, deep-review companion to F-02):
    ///         caller of `evictUnresolved` named a marketId that is not
    ///         currently in `_activeMarkets[]`. Either already pruned, never
    ///         created on this cycler, or wrong cycler.
    error MarketNotInActiveSet(uint256 marketId);
    /// @notice #21: caller of `evictUnresolved` named a market that is still
    ///         within the resolver's `MAX_STALENESS` window — i.e. an
    ///         authorized `ChainlinkResolver.resolve` call could still
    ///         succeed for this market. Admin eviction is gated to provably
    ///         unresolvable markets to avoid an admin-mistake user-funds-locking
    ///         class of bug. Wait until `endTime + RESOLVER_MAX_STALENESS <
    ///         block.timestamp` or call `pruneResolved()` if the market has
    ///         already been resolved off-cycler.
    error MarketStillResolvable(uint256 marketId, uint256 endTime, uint256 nowTs);
    /// @notice F-01 (deep review 2026-05-11): keeper invoked `performUpkeep`
    ///         on this cycler after it was deprecated. Converts the
    ///         "silent burn on orphaned cycler after a redeploy" failure
    ///         mode (PR #88 generalization) into a loud revert so any
    ///         keeper still pointed at the old address sees its txes
    ///         revert and alerts. `checkUpkeep` returns `(false, "")`
    ///         silently when deprecated — only on-chain writes revert
    ///         loudly.
    error Deprecated();
    /// @notice F-01: `deprecate(address)` is a one-shot — calling twice is
    ///         an operator mistake worth surfacing rather than silently
    ///         no-op'ing. The replacement-address record from the first
    ///         call stays canonical.
    error AlreadyDeprecated();
    /// @notice F-2026-17726: `performUpkeep` was called by an address that is neither the registered
    ///         Automation forwarder nor the owner. The core of the High: a permissionless
    ///         `performUpkeep` let an attacker spam empty-report slots and fail-forward the pointer
    ///         arbitrarily far, halting market creation for zero capital.
    error NotForwarder();

    // ── Events ──────────────────────────────────────────────────────────
    event MarketCreated(uint256 indexed marketId, bytes32 indexed pairId, uint256 duration, int256 strikePrice);
    event MarketCreationFailed(bytes32 indexed pairId, uint256 indexed timeframe, bytes reason);
    /// @notice F-06 part 2 (deep review 2026-05-11): emitted alongside
    ///         `MarketCreationFailed` when the catch block in `performUpkeep`
    ///         advances `pairTfLastCreated` so the failed slot does not get
    ///         retried indefinitely. `skippedSlotStart` is the value that
    ///         `pairTfLastCreated[pairId][tfIdx]` was set to (= the
    ///         plannedStart that the failed `_createMarket` would have used).
    ///         Off-chain consumers can audit fail-forward gaps by indexing
    ///         this event in tandem with `MarketCreationFailed`.
    event SlotSkippedAfterFailure(bytes32 indexed pairId, uint256 indexed tfIdx, uint256 skippedSlotStart);
    /// @notice #21: emitted when the owner manually evicts a stuck market
    ///         from `_activeMarkets[]`. Ops audit trail for the admin
    ///         escape hatch. Sister event to `MarketCreationFailed` /
    ///         `SlotSkippedAfterFailure` — together these three events let
    ///         off-chain consumers reconstruct the lifecycle of every slot.
    event SlotEvictedManually(uint256 indexed marketId, bytes32 indexed pairId, uint256 endTime);
    /// @notice F-01 (deep review 2026-05-11): emitted on `deprecate()`.
    ///         `replacement` is the new cycler address operators are
    ///         migrating to, or `address(0)` if the deprecation is a
    ///         final shutdown with no replacement (winding down).
    ///         Off-chain indexers track rotations by following this event.
    event CyclerDeprecated(address indexed oldCycler, address indexed replacement);
    event ResolutionFailed(uint256 indexed marketId, bytes reason);
    event TimeframeToggled(uint256 indexed index, bool active);
    event FundsWithdrawn(address indexed token, uint256 amount);
    /// @notice Emitted when the owner changes the pre-start window. Off-chain
    ///         consumers (the backend's MarketSyncer) read this to know how
    ///         far ahead of `startTime` markets may now appear.
    event PreStartWindowUpdated(uint256 previous, uint256 current);
    /// @notice F-2026-17782: emitted when the owner deactivates a pair so it
    ///         stops receiving new markets each cycle. Inverse of the
    ///         (event-less) `addPair`.
    event PairRemoved(bytes32 indexed pairId);
    /// @notice F-2026-17726: emitted when the owner manually repairs a
    ///         `pairTfLastCreated` pointer (e.g. after a fail-forward skipped
    ///         a legitimate slot). Recovery audit trail.
    event PairTfLastCreatedReset(bytes32 indexed pairId, uint256 indexed tfIdx, uint256 value);
    /// @notice F-2026-17726: emitted when the owner sets/rotates the Automation forwarder.
    event ForwarderSet(address indexed previous, address indexed current);
    /// @notice F-2026-17780: emitted when a `performUpkeep` create slot is a no-op because its
    ///         `plannedStart` doesn't match the contract's expected next slot (stale/replayed
    ///         performData). Distinguishes an idempotent skip from a genuine creation failure.
    event SlotAlreadyProcessed(bytes32 indexed pairId, uint256 indexed tfIdx, uint256 plannedStart);

    // ── Types ───────────────────────────────────────────────────────────
    struct TimeframeConfig {
        uint256 duration;
        uint256 disputeDuration;
        bool active;
    }

    struct ActiveMarket {
        uint256 marketId;
        uint256 endTime;
        bytes32 pairId;
    }

    /// @dev Encoded in performData alongside resolve indices for market creation.
    ///
    /// Streams-strike (2026-05-16): `signedReport` carries the Chainlink
    /// Data Streams report blob used to capture the strike for this slot.
    /// `checkUpkeep` emits CreateSlot with empty `signedReport`; the upkeep
    /// coordinator (dev-keeper on dev, Chainlink Automation StreamsLookup
    /// in production) fetches the per-slot report off-chain and fills in
    /// `signedReport` before calling `performUpkeep`. The Resolver verifies
    /// the report + extracts the strike at `_createMarket` time.
    struct CreateSlot {
        bytes32 pairId;
        uint256 tfIdx;
        uint64 plannedStart;  // pre-computed by checkUpkeep so the coordinator knows the exact slot boundary to fetch a report for
        bytes signedReport;
    }

    // ── Constants ───────────────────────────────────────────────────────
    bytes32 public constant BTCUSD = keccak256("BTC/USD");
    bytes32 public constant ETHUSD = keccak256("ETH/USD");
    uint256 public constant NUM_TIMEFRAMES = 3;
    /// @notice Mirrors `ChainlinkResolver.MAX_STALENESS` (1 hour). Duplicated
    ///         here so `_createMarket`'s F-02 freshness guard can short-circuit
    ///         without an external SLOAD per call. The cycler + resolver
    ///         deploy as a bundle; if `MAX_STALENESS` ever changes in the
    ///         resolver, this constant must change in lockstep. Reviewed in
    ///         the same audit pass to catch divergence.
    uint256 public constant RESOLVER_MAX_STALENESS = 1 hours;

    // ── State ───────────────────────────────────────────────────────────
    /// @notice F-04 (deep review 2026-05-11): both pointers are `immutable`.
    ///         Symmetric with `ChainlinkResolver.trustedSettlement` (also
    ///         immutable). Rotation of either contract requires a full
    ///         redeployment of the cycler — by design. The deploy unit is the
    ///         three-contract bundle (settlement + resolver + cycler); a
    ///         mid-life pointer rotation could orphan unresolved entries in
    ///         `_activeMarkets[]` and permanently lock user positions. See
    ///         the F-04 section of the deep-review doc for the full mechanism.
    ChainlinkResolver public immutable resolver;
    IUpDownSettlement public immutable settlement;

    TimeframeConfig[NUM_TIMEFRAMES] public timeframes;
    ActiveMarket[] internal _activeMarkets;
    mapping(bytes32 => bool) public supportedPairs;

    /// @notice Pairs that receive new markets each cycle (owner extends via `addPair`).
    bytes32[] internal _cyclingPairs;
    mapping(bytes32 => bool) public isCyclingPair;

    /// @notice Start timestamp of the last created slot (clock-aligned boundary) per (pairId, timeframeIndex).
    mapping(bytes32 => mapping(uint256 => uint256)) public pairTfLastCreated;

    /// @notice Pre-positioning window — number of seconds BEFORE a slot's
    ///         `startTime` at which `_createMarket` becomes eligible to
    ///         create that slot's market. Default 0 = current behavior
    ///         (markets are created at-or-after `startTime`, never early).
    ///         When set to e.g. 30, the cycler creates a market with
    ///         `startTime = next slot boundary` once `block.timestamp +
    ///         preStartWindowSec >= nextSlotBoundary`. Backend matching
    ///         engine refuses to match orders on a market whose
    ///         `startTime` is in the future, so trades only land at-or-
    ///         after the boundary; the pre-window exists only so makers
    ///         can sign orders + post them to the engine before the
    ///         continuous cross begins.
    ///
    ///         Capped at the smallest active timeframe duration (300s)
    ///         so the next-slot market can't be created before the
    ///         current slot's market is even live.
    uint256 public preStartWindowSec;
    uint256 public constant PRE_START_WINDOW_MAX = 300;

    /// @notice F-01 (deep review 2026-05-11): one-shot deprecation marker.
    ///         When `true`, this cycler signals "do not drive me" to all
    ///         keepers: `checkUpkeep` returns `(false, "")` so Chainlink
    ///         Automation stops scheduling, and `performUpkeep` reverts
    ///         with `Deprecated()` so any keeper still pointed at this
    ///         address sees broadcast failures and alerts. Set by
    ///         `deprecate(address replacement)` (one-shot). The
    ///         replacement-cycler address is recorded in the
    ///         `CyclerDeprecated` event for off-chain indexers.
    bool public deprecated;

    /// @notice F-2026-17726: the Chainlink Automation forwarder permitted to call `performUpkeep`
    ///         (alongside the owner). Set post-deploy via `setForwarder` once the upkeep is
    ///         registered (the forwarder address only exists after registration). While unset, only
    ///         the owner can drive the cycler — fail-safe. The stopgap cron drives it from the
    ///         relayer wallet, so the deploy script seeds `forwarder = relayer`.
    address public forwarder;

    // ── Constructor ─────────────────────────────────────────────────────
    constructor(address _owner, address _resolver, address _settlement) Ownable(_owner) {
        if (_resolver == address(0) || _settlement == address(0)) revert ZeroAddress();
        resolver = ChainlinkResolver(_resolver);
        settlement = IUpDownSettlement(_settlement);

        // 5 min markets, 10 min dispute
        timeframes[0] = TimeframeConfig({duration: 300, disputeDuration: 600, active: true});
        // 15 min markets, 30 min dispute
        timeframes[1] = TimeframeConfig({duration: 900, disputeDuration: 1800, active: true});
        // 1 hour markets, 120 min dispute
        timeframes[2] = TimeframeConfig({duration: 3600, disputeDuration: 7200, active: true});

        supportedPairs[BTCUSD] = true;
        isCyclingPair[BTCUSD] = true;
        _cyclingPairs.push(BTCUSD);
    }

    /// @notice Number of pairs that participate in automated market creation.
    function cyclingPairCount() external view returns (uint256) {
        return _cyclingPairs.length;
    }

    /// @notice Pair id at index in the cycling list (for indexers / backends).
    function cyclingPairAt(uint256 index) external view returns (bytes32) {
        return _cyclingPairs[index];
    }

    /// @notice Same layout as the default getter for a public array of structs.
    function activeMarkets(uint256 index)
        external
        view
        returns (uint256 marketId, uint256 endTime, bytes32 pairId)
    {
        ActiveMarket storage m = _activeMarkets[index];
        return (m.marketId, m.endTime, m.pairId);
    }

    // ── Chainlink Automation ────────────────────────────────────────────

    /// @notice Called off-chain by Chainlink Automation nodes every block.
    /// @dev    PR-PrePos: market creation triggers `preStartWindowSec`
    ///         seconds earlier than today; each slot's market is created
    ///         when `block.timestamp + preStartWindowSec >= pairTfLastCreated
    ///         + tf.duration`. Reduces to today's behavior (`>= pairTfLastCreated
    ///         + tf.duration`) when `preStartWindowSec == 0`.
    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData) {
        // F-01: silent short-circuit when deprecated. Chainlink Automation
        // polls `checkUpkeep`; returning `(false, "")` tells it nothing is
        // pending and it stops scheduling perform calls. No event emitted —
        // the `CyclerDeprecated` event from `deprecate()` already records
        // the lifecycle transition.
        if (deprecated) return (false, "");

        uint256 marketsLen = _activeMarkets.length;
        uint256 preWin = preStartWindowSec;

        uint256 resolveCount;
        for (uint256 i; i < marketsLen; ++i) {
            if (block.timestamp >= _activeMarkets[i].endTime) ++resolveCount;
        }

        uint256 createCount;
        uint256 nPairs = _cyclingPairs.length;
        for (uint256 pi; pi < nPairs; ++pi) {
            bytes32 pid = _cyclingPairs[pi];
            if (!supportedPairs[pid]) continue;
            for (uint256 ti; ti < NUM_TIMEFRAMES; ++ti) {
                TimeframeConfig storage tft = timeframes[ti];
                if (tft.active && block.timestamp + preWin >= pairTfLastCreated[pid][ti] + tft.duration) {
                    ++createCount;
                }
            }
        }

        // Prior #2 (AUDIT_FINDING_CHECKUPKEEP_GAS_LEAK.md, 2026-05-07):
        // `upkeepNeeded` is gated on `createCount > 0` only — `resolveCount`
        // is kept for diagnostic emission in `performData` but does NOT
        // trigger keeper work. Resolution is off-chain (PR-10 / P0-16); this
        // contract's `performUpkeep` ignores `resolveIndices`. Pre-fix,
        // every past-endTime market in `_activeMarkets[]` made `checkUpkeep`
        // return `true` on every block, burning ~2M gas per call on a
        // `_pruneResolved` walk that pops nothing (because resolution is
        // async and shadow markets per F-02/StalePrice never resolve). At
        // Chainlink Automation cadence on Arbitrum (~250ms blocks), that's
        // ~$200-500/day in LINK billed against the upkeep registration for
        // unproductive walks. Gating on `createCount > 0` reduces the keeper
        // to "fire only when there's actual on-chain work to do" — pruning
        // happens naturally at create cadence (every 5 min in normal
        // operation), which is more than sufficient for a healthy
        // `_activeMarkets[]` lifecycle.
        upkeepNeeded = createCount > 0;

        if (upkeepNeeded) {
            uint256[] memory resolveIndices = new uint256[](resolveCount);
            CreateSlot[] memory createSlots = new CreateSlot[](createCount);

            uint256 ri;
            for (uint256 i; i < marketsLen; ++i) {
                if (block.timestamp >= _activeMarkets[i].endTime) resolveIndices[ri++] = i;
            }

            uint256 ci;
            for (uint256 pi; pi < nPairs; ++pi) {
                bytes32 pid = _cyclingPairs[pi];
                if (!supportedPairs[pid]) continue;
                for (uint256 ti; ti < NUM_TIMEFRAMES; ++ti) {
                    TimeframeConfig storage tft = timeframes[ti];
                    if (tft.active && block.timestamp + preWin >= pairTfLastCreated[pid][ti] + tft.duration) {
                        // Streams-strike: plannedStart is the clock-aligned boundary
                        // the upkeep coordinator needs to fetch a report for.
                        // `signedReport` is empty here — coordinator fills it in
                        // before calling performUpkeep.
                        uint256 lastStart = pairTfLastCreated[pid][ti];
                        uint256 plannedStart = lastStart == 0
                            ? (block.timestamp / tft.duration) * tft.duration
                            : lastStart + tft.duration;
                        createSlots[ci++] = CreateSlot({
                            pairId: pid,
                            tfIdx: ti,
                            plannedStart: uint64(plannedStart),
                            signedReport: bytes("")
                        });
                    }
                }
            }

            performData = abi.encode(resolveIndices, createSlots);
        }
    }

    /// @notice Called on-chain by Chainlink Automation when checkUpkeep returns true.
    /// @dev    PR-10 (P0-16): on-chain resolve dispatch was REMOVED here. The
    ///         resolver now requires `(marketId, uint80 roundId)` — the
    ///         canonical Chainlink round whose `updatedAt <= market.endTime`,
    ///         which only an off-chain helper can compute by scanning the
    ///         feed's round history. Backend `ChainlinkResolverService` owns
    ///         this responsibility now; Chainlink Automation only drives
    ///         creation + pruning. `resolveIndices` is preserved in
    ///         `performData` (still emitted by `checkUpkeep`) so a future
    ///         redesign can read it, but `performUpkeep` ignores it today.
    function performUpkeep(bytes calldata performData) external {
        // F-01: loud revert when deprecated.
        if (deprecated) revert Deprecated();

        // F-2026-17726: gate to the Automation forwarder (or owner). This is the core of the High —
        // a permissionless `performUpkeep` let any attacker submit empty-report slots and fail-forward
        // `pairTfLastCreated` arbitrarily far for gas only, halting market creation. Restricting the
        // caller removes the adversarial-input surface entirely; the transient-failure policy and
        // idempotency below are defense-in-depth for an honest-but-buggy keeper.
        if (msg.sender != forwarder && msg.sender != owner()) revert NotForwarder();

        // `resolveIndices` is decoded for ABI/payload stability with the
        // Chainlink Automation registration but not iterated here because
        // resolution is roundId-bound and lives off-chain.
        (, CreateSlot[] memory createSlots) =
            abi.decode(performData, (uint256[], CreateSlot[]));

        // Phase B: create new markets (external self-call so try/catch can recover)
        for (uint256 i; i < createSlots.length; ++i) {
            CreateSlot memory slot = createSlots[i];
            // F-2026-17780: thread `slot.plannedStart` so `_createMarket` can validate it against the
            // expected next slot and no-op on a replayed/duplicate performData.
            try this._createMarketExternal(slot.tfIdx, slot.pairId, slot.plannedStart, slot.signedReport) {}
            catch (bytes memory reason) {
                // F-2026-17726: transient-vs-permanent failure policy. We advance the pointer ONLY on
                // `PlannedStartTooStale` — the one genuinely-permanent skip, where the slot's window
                // has irrecoverably passed and creating it is impossible. For every OTHER revert
                // (a bad/stale/unavailable Streams report, a resolver hiccup, a transient config gap)
                // we do NOT advance: the next `checkUpkeep` re-flags the same slot and a legitimate
                // retry with a fresh report creates it. Pre-fix, advancing on ANY revert is exactly
                // what let the empty-report attack push the pointer forward.
                bool permanentSkip = _isSelector(reason, PlannedStartTooStale.selector);
                if (permanentSkip && slot.tfIdx < NUM_TIMEFRAMES) {
                    TimeframeConfig storage tft = timeframes[slot.tfIdx];
                    uint256 lastStart = pairTfLastCreated[slot.pairId][slot.tfIdx];
                    uint256 skippedSlotStart = lastStart == 0
                        ? (block.timestamp / tft.duration) * tft.duration
                        : lastStart + tft.duration;
                    pairTfLastCreated[slot.pairId][slot.tfIdx] = skippedSlotStart;
                    emit SlotSkippedAfterFailure(slot.pairId, slot.tfIdx, skippedSlotStart);
                }
                emit MarketCreationFailed(slot.pairId, slot.tfIdx, reason);
            }
        }

        _pruneResolved();
    }

    /// @dev Extract the 4-byte error selector from raw revert bytes for the transient-vs-permanent
    ///      classification in `performUpkeep` (F-2026-17726).
    function _isSelector(bytes memory reason, bytes4 selector) internal pure returns (bool) {
        if (reason.length < 4) return false;
        bytes4 got;
        assembly {
            got := mload(add(reason, 0x20))
        }
        return got == selector;
    }

    /// @dev Callable only via `this` from performUpkeep so failures are catchable.
    ///      Streams-strike (2026-05-16): also takes the signed Streams report for strike capture.
    ///      F-2026-17780: `plannedStart` from the upkeep payload is threaded through for the
    ///      idempotency check in `_createMarket`.
    function _createMarketExternal(uint256 tfIdx, bytes32 pairId, uint64 plannedStart, bytes memory signedReport)
        external
    {
        require(msg.sender == address(this), "only cycler");
        _createMarket(tfIdx, pairId, plannedStart, signedReport);
    }

    // ── Internal ────────────────────────────────────────────────────────

    /// @dev PR-PrePos: planned start = `lastStart + tf.duration` so each
    ///      cycle creates the slot AFTER the most recently created one.
    ///      For the first-ever create on a (pair, tf), bootstrap to the
    ///      current clock-aligned boundary (preserves today's bootstrap
    ///      semantics). When `preStartWindowSec > 0`, `_createMarket` is
    ///      reachable via `checkUpkeep` up to `preStartWindowSec` seconds
    ///      before `plannedStart`, so the resulting market may have
    ///      `startTime > block.timestamp` (= "pre-start" / "WAITING_TO_START"
    ///      from the backend's perspective). The off-chain matching engine
    ///      refuses to match orders on a market whose `startTime` is in
    ///      the future, so trades only land at-or-after the boundary.
    function _createMarket(uint256 tfIdx, bytes32 pairId, uint64 plannedStartArg, bytes memory signedReport)
        internal
    {
        if (tfIdx >= NUM_TIMEFRAMES) revert InvalidTimeframeIndex();
        if (!supportedPairs[pairId]) revert("pair not supported");

        TimeframeConfig storage tf = timeframes[tfIdx];

        uint256 nowTs = block.timestamp;
        uint256 lastStart = pairTfLastCreated[pairId][tfIdx];
        uint256 plannedStart;
        if (lastStart == 0) {
            // First create on this (pair, tf): align to the current boundary.
            plannedStart = (nowTs / tf.duration) * tf.duration;
        } else {
            // Continuing cycle: next slot follows the previous one exactly.
            plannedStart = lastStart + tf.duration;
        }

        // F-2026-17780: idempotency. The keeper-supplied `plannedStartArg` must equal the slot the
        // contract is actually expecting. A replayed/duplicate performData carries a stale
        // `plannedStart` (the slot was already created and the pointer advanced), so this is a clean
        // no-op — no double-create, and crucially no fail-forward that would skip the next valid slot.
        if (uint256(plannedStartArg) != plannedStart) {
            emit SlotAlreadyProcessed(pairId, tfIdx, uint256(plannedStartArg));
            return;
        }

        uint256 end = plannedStart + tf.duration;

        if (end + RESOLVER_MAX_STALENESS < nowTs) {
            revert PlannedStartTooStale(plannedStart, end, nowTs);
        }

        // Streams-strike (2026-05-16): replace the prior
        // `resolver.getPrice(pairId)` (Data Feeds AggregatorV3 read, 1e8
        // atomic scale) with `resolver.captureStrike(pairId, signedReport,
        // plannedStart)` (Data Streams ReportV3 read, 1e18 atomic scale).
        // Strike value flows through the same `int256` channel and the same
        // settlement.createMarket signature — only the scale changes. The
        // F-06 int128 range check below still applies; at 1e18 atomic
        // representing ETH/BTC prices, the values fit comfortably in
        // int128 (~9.2e36 max).
        int256 strike = resolver.captureStrike(pairId, signedReport, uint64(plannedStart));

        if (strike > type(int128).max || strike < type(int128).min) {
            revert StrikeOverflow(strike);
        }

        uint256 marketId = settlement.createMarket(pairId, tf.duration, strike, uint64(plannedStart), uint64(end));

        resolver.registerMarket(marketId, address(settlement), pairId, strike);
        _activeMarkets.push(ActiveMarket({marketId: marketId, endTime: end, pairId: pairId}));
        pairTfLastCreated[pairId][tfIdx] = plannedStart;

        emit MarketCreated(marketId, pairId, tf.duration, strike);
    }

    // ── Owner: configuration ────────────────────────────────────────────

    function toggleTimeframe(uint256 index, bool active) external onlyOwner {
        if (index >= NUM_TIMEFRAMES) revert InvalidTimeframeIndex();
        timeframes[index].active = active;
        emit TimeframeToggled(index, active);
    }

    /// @notice Set the pre-positioning window (seconds before `startTime`
    ///         at which a slot's market becomes eligible to be created).
    ///         0 disables pre-positioning (default; matches pre-PR behavior).
    ///         Capped at `PRE_START_WINDOW_MAX` (= the smallest active
    ///         timeframe duration, 300s) so the next-slot market can't
    ///         appear before the current slot's market is even live.
    function setPreStartWindowSec(uint256 v) external onlyOwner {
        if (v > PRE_START_WINDOW_MAX) revert PreStartWindowTooLarge();
        uint256 prev = preStartWindowSec;
        preStartWindowSec = v;
        emit PreStartWindowUpdated(prev, v);
    }

    /// @notice Whitelist a pair and include it in automated cycling (idempotent for cycling list).
    function addPair(bytes32 pairId) external onlyOwner {
        supportedPairs[pairId] = true;
        if (!isCyclingPair[pairId]) {
            isCyclingPair[pairId] = true;
            _cyclingPairs.push(pairId);
        }
    }

    /// @notice F-2026-17782: inverse of `addPair`. Deactivate a pair so it
    ///         stops receiving new markets and is removed from the cycling
    ///         list. Both `checkUpkeep` and `_createMarket` gate on
    ///         `supportedPairs[pairId]`, so flipping it to `false` halts
    ///         iteration and creation for the pair without deprecating the
    ///         whole cycler. Existing open markets for the pair are untouched
    ///         and still resolve normally via the resolver. `isCyclingPair`
    ///         is also cleared so a later `addPair` re-adds the pair cleanly
    ///         instead of silently skipping the `_cyclingPairs.push`.
    function removePair(bytes32 pairId) external onlyOwner {
        supportedPairs[pairId] = false;
        if (isCyclingPair[pairId]) {
            isCyclingPair[pairId] = false;
            uint256 len = _cyclingPairs.length;
            for (uint256 i; i < len; ++i) {
                if (_cyclingPairs[i] == pairId) {
                    _cyclingPairs[i] = _cyclingPairs[len - 1];
                    _cyclingPairs.pop();
                    break;
                }
            }
        }
        emit PairRemoved(pairId);
    }

    /// @notice F-2026-17726: owner recovery hatch for a corrupted
    ///         `pairTfLastCreated` pointer. The permissionless fail-forward in
    ///         `performUpkeep` can advance the pointer past legitimate slots
    ///         (e.g. an invalid/empty report makes `captureStrike` revert and
    ///         the catch block skips the slot). Before this setter the only
    ///         remedy was `deprecate` + a full bundle redeploy. Setting the
    ///         pointer back to the last legitimately-created slot's start lets
    ///         `checkUpkeep` re-schedule the skipped boundaries. Owner-only;
    ///         does not move funds or touch settlement state.
    ///
    ///         NOTE: this is a recovery hatch, not the primary fix for
    ///         F-2026-17726. The primary fix — restricting `performUpkeep`
    ///         to the Chainlink Automation `forwarder` (or owner) plus
    ///         advancing the pointer only on a permanent `PlannedStartTooStale`
    ///         skip — is now implemented (see `performUpkeep` / `setForwarder`).
    ///         This hatch is retained as defense-in-depth for an honest-but-
    ///         stuck pointer.
    function setPairTfLastCreated(bytes32 pairId, uint256 tfIdx, uint256 value) external onlyOwner {
        if (tfIdx >= NUM_TIMEFRAMES) revert InvalidTimeframeIndex();
        pairTfLastCreated[pairId][tfIdx] = value;
        emit PairTfLastCreatedReset(pairId, tfIdx, value);
    }

    /// @notice F-2026-17726: set/rotate the Automation forwarder permitted to call `performUpkeep`.
    ///         Called post-deploy once the upkeep is registered (the forwarder address only exists
    ///         after registration). Allowing `address(0)` is intentional — it disables all non-owner
    ///         upkeep (owner can still drive the cycler), a deliberate kill-switch.
    function setForwarder(address f) external onlyOwner {
        address prev = forwarder;
        forwarder = f;
        emit ForwarderSet(prev, f);
    }

    // F-04 (deep review 2026-05-11): `setResolver` and `setSettlement` removed.
    // Both pointers are `immutable`, set once in the constructor. Rotation
    // requires a full bundle redeploy (settlement + resolver + cycler). See
    // the immutables' docstring above and the F-04 section of the deep-review
    // doc for the user-funds-locking mechanism this prevents.

    /// @notice F-01 (deep review 2026-05-11): one-shot deprecation. Flips
    ///         the `deprecated` state so any subsequent `checkUpkeep` returns
    ///         `(false, "")` and any direct `performUpkeep` call reverts
    ///         with `Deprecated()`. Use this between deploys to fence off
    ///         the old cycler from accepting keeper work (closes the PR #88
    ///         "obsolete-cycler keeper bleed" class at the contract level).
    ///
    /// @param replacement Address of the cycler operators are migrating to,
    ///        or `address(0)` if this is a final shutdown with no successor.
    ///        Recorded in the `CyclerDeprecated` event for off-chain
    ///        indexers — not enforced or stored on-chain (no reason to;
    ///        the value is informational).
    function deprecate(address replacement) external onlyOwner {
        if (deprecated) revert AlreadyDeprecated();
        deprecated = true;
        emit CyclerDeprecated(address(this), replacement);
    }

    // ── Owner: fund management ──────────────────────────────────────────

    /// @notice Withdraw any ERC-20 from this contract.
    function withdrawFunds(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(msg.sender, amount);
        emit FundsWithdrawn(token, amount);
    }

    // ── Owner: gas optimization ─────────────────────────────────────────

    /// @notice Remove resolved markets from the active array (swap-and-pop).
    function pruneResolved() external onlyOwner {
        _pruneResolved();
    }

    function _pruneResolved() internal {
        uint256 i;
        while (i < _activeMarkets.length) {
            uint256 mid = _activeMarkets[i].marketId;
            if (settlement.getMarket(mid).resolved) {
                _activeMarkets[i] = _activeMarkets[_activeMarkets.length - 1];
                _activeMarkets.pop();
            } else {
                ++i;
            }
        }
    }

    /// @notice #21 (POST_DEMO_TODO 2026-05-06): admin escape hatch for
    ///         markets stuck in `_activeMarkets[]` because they passed the
    ///         resolver's `MAX_STALENESS` window before
    ///         `ChainlinkResolver.resolve` could complete (catch-up shadows,
    ///         resolver outages crossing the staleness boundary, etc.).
    ///         F-02's `_createMarket` freshness guard prevents NEW shadows
    ///         on this cycler; `evictUnresolved` is the defense-in-depth
    ///         cleanup hatch for any that slip through (e.g., resolver
    ///         transiently unavailable across the staleness boundary AFTER
    ///         a market was successfully created).
    ///
    ///         Safety: only allows eviction of markets whose
    ///         `endTime + RESOLVER_MAX_STALENESS < block.timestamp`. This
    ///         is the same provably-unresolvable condition F-02 uses to
    ///         REFUSE creation. Markets within the staleness window are
    ///         still resolvable via the authorized
    ///         `ChainlinkResolver.resolve` and admin must not be able to
    ///         force-evict them (that would lock user funds in those
    ///         markets — the same hazard F-04 closes for resolver/settlement
    ///         pointer rotation).
    ///
    ///         Eviction touches ONLY the cycler's `_activeMarkets[]` index.
    ///         The settlement contract's per-market state
    ///         (`settlement.markets[id]`) is left intact — eviction is a
    ///         bookkeeping cleanup, not a market-state mutation.
    ///
    ///         Callers pass marketIds directly; F-11 (no per-pair index)
    ///         leaves the responsibility of finding stuck IDs to off-chain
    ///         scans of `SlotSkippedAfterFailure` + market endTimes.
    function evictUnresolved(uint256[] calldata marketIds) external onlyOwner {
        uint256 nowTs = block.timestamp;
        for (uint256 idx; idx < marketIds.length; ++idx) {
            uint256 mid = marketIds[idx];

            // Linear scan — `_activeMarkets[]` size is bounded by
            // (timeframes × pairs × pending-resolve-window) in normal ops
            // (single digits to low hundreds). Per-pair index (F-11) is a
            // future optimization if the array ever grows pathologically.
            uint256 len = _activeMarkets.length;
            uint256 found = type(uint256).max;
            for (uint256 i; i < len; ++i) {
                if (_activeMarkets[i].marketId == mid) {
                    found = i;
                    break;
                }
            }
            if (found == type(uint256).max) revert MarketNotInActiveSet(mid);

            ActiveMarket memory m = _activeMarkets[found];
            if (m.endTime + RESOLVER_MAX_STALENESS >= nowTs) {
                revert MarketStillResolvable(mid, m.endTime, nowTs);
            }

            // swap-and-pop
            _activeMarkets[found] = _activeMarkets[len - 1];
            _activeMarkets.pop();

            emit SlotEvictedManually(mid, m.pairId, m.endTime);
        }
    }

    // ── View helpers ────────────────────────────────────────────────────

    function activeMarketCount() external view returns (uint256) {
        return _activeMarkets.length;
    }
}
