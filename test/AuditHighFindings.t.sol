// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {UpDownSettlement} from "../src/UpDownSettlement.sol";
import {ChainlinkResolver} from "../src/ChainlinkResolver.sol";
import {UpDownAutoCycler} from "../src/UpDownAutoCycler.sol";
import {MockUSDT} from "../src/mocks/MockUSDT.sol";
import {MockAggregatorV3} from "../src/mocks/MockAggregatorV3.sol";
import {MockVerifierProxy} from "../src/mocks/MockVerifierProxy.sol";
import {ReportV2, ReportV3} from "../src/interfaces/IVerifierProxy.sol";

/// @title Proof-of-issue tests for the two High findings of the 2026-08-19 review.
/// @notice These tests assert the CURRENT (buggy) behaviour, so they pass against the
///         tree as it stands and become the regression gate once the fixes land. Each
///         one carries a `FIX:` note naming the assertion that must be inverted after
///         remediation.
///
///           H-1  A market's strike and its settlement can be sourced from two
///                different Data Streams feeds. `captureStrike` stores only the strike
///                number; `resolve` re-reads `streamsFeedId[pairId]` at settlement
///                time. Nothing binds a market to the stream it was struck on.
///
///           H-2  A market that misses its resolution window locks its collateral
///                permanently. `burn` closes at `endTime`, `redeem` needs `resolved`,
///                and the only input that can set `resolved` is a DON report that
///                itself expires.
///
///         Both are driven through the real three-contract bundle (settlement +
///         resolver + cycler) via `MockVerifierProxy`, using the same report encoding
///         the backend producer emits — so nothing here depends on a shortcut the
///         production path does not take.

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Sequencer uptime feed whose `updatedAt` can be moved after construction.
///      `MockAggregatorV3.fixedStartedAt` is immutable, so it cannot model the
///      transition H-2's sequencer case needs: a feed that has just written a
///      new round (sequencer back up) and then ages out of the grace period.
contract MutableSequencerFeed {
    int256 public answer;
    uint256 public updatedAt;

    constructor(int256 _answer, uint256 _updatedAt) {
        answer = _answer;
        updatedAt = _updatedAt;
    }

    /// @notice Model a sequencer state transition: the feed writes a fresh round.
    function setRound(int256 _answer, uint256 _updatedAt) external {
        answer = _answer;
        updatedAt = _updatedAt;
    }

    function decimals() external pure returns (uint8) {
        return 0;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @dev Shared bundle fixture — mirrors `Deploy.s.sol` wiring, same as MockDonE2E.
abstract contract UpDownBundleFixture is Test {
    bytes32 internal constant BTCUSD = keccak256("BTC/USD");

    /// @dev Schema prefix lives in the leading two bytes of a stream id
    ///      (`0x0003…` = v3 Crypto Advanced spot, `0x0002…` = v2, what the TWAP
    ///      streams publish under). These two ids stand in for the real pair that
    ///      the 2026-08-13 cutover swapped between.
    bytes32 internal constant FEED_SPOT_V3 = bytes32((uint256(3) << 240) | (uint256(keccak256("BTC/USD-spot")) >> 16));
    bytes32 internal constant FEED_TWAP_V2 =
        bytes32((uint256(2) << 240) | (uint256(keccak256("BTC/USD-twap-60s")) >> 16));

    /// @dev 18-decimal atomic scale, matching real Crypto Streams.
    int192 internal constant STRIKE = 108_000e18;

    /// @dev Aligned to 3600, so the bootstrap slot of all three timeframes
    ///      (300 / 900 / 3600) lands on one boundary.
    uint256 internal constant T0 = 1_751_598_000;

    /// @dev Close of the 5-minute market every test below drives.
    uint256 internal constant END_5M = T0 + 300;

    /// @dev Report validity window. Real Streams reports carry a finite
    ///      `expiresAt`; that finiteness is the mechanism behind H-2.
    uint256 internal constant REPORT_TTL = 300;

    // NOTE: every timestamp below is written out explicitly rather than read from
    // `block.timestamp`. solc common-subexpression-eliminates the TIMESTAMP opcode
    // within a single test function, so a read taken after a second `vm.warp` still
    // returns the first warp's value — see the same warning in MockDonE2E.t.sol.

    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");

    MockUSDT internal usdt;
    MockVerifierProxy internal verifier;
    MutableSequencerFeed internal sequencer;
    UpDownSettlement internal settlement;
    ChainlinkResolver internal resolver;
    UpDownAutoCycler internal cycler;

    function _deployBundle() internal {
        vm.warp(T0);

        usdt = new MockUSDT();
        verifier = new MockVerifierProxy();
        MockAggregatorV3 btcFeed = new MockAggregatorV3(108_000e8, 8, 0);
        // answer == 0 => sequencer up; updatedAt far in the past => past grace.
        sequencer = new MutableSequencerFeed(0, 1);

        vm.startPrank(owner);
        settlement = new UpDownSettlement(IERC20(address(usdt)), owner);
        resolver = new ChainlinkResolver(
            owner,
            address(sequencer),
            BTCUSD,
            address(btcFeed),
            bytes32(0),
            address(0),
            address(settlement),
            address(verifier),
            address(0xF97F) // LINK: stored, never used (s_feeManager() == 0)
        );
        cycler = new UpDownAutoCycler(owner, address(resolver), address(settlement));

        settlement.setResolver(address(resolver));
        settlement.setAutocycler(address(cycler));
        settlement.setRelayer(relayer);
        settlement.setTreasury(treasury);

        resolver.setAuthorizedCaller(address(cycler), true);
        resolver.setAuthorizedCaller(relayer, true);

        cycler.setForwarder(relayer);
        resolver.configureStreamsFeed(BTCUSD, FEED_SPOT_V3);
        vm.stopPrank();

        usdt.mint(alice, 10_000e6);
        vm.prank(alice);
        usdt.approve(address(settlement), type(uint256).max);
    }

    // ── Report fabrication (byte-identical to the backend producer's wrapper) ──

    function _wrapV3(bytes32 feedId, uint256 obsTs, uint256 expiresAt, int192 price)
        internal
        pure
        returns (bytes memory)
    {
        ReportV3 memory r = ReportV3({
            feedId: feedId,
            validFromTimestamp: uint32(obsTs),
            observationsTimestamp: uint32(obsTs),
            nativeFee: 0,
            linkFee: 0,
            expiresAt: uint32(expiresAt),
            price: price,
            bid: price,
            ask: price
        });
        bytes32[3] memory ctx;
        return abi.encode(ctx, abi.encode(r));
    }

    function _wrapV2(bytes32 feedId, uint256 obsTs, uint256 expiresAt, int192 price)
        internal
        pure
        returns (bytes memory)
    {
        ReportV2 memory r = ReportV2({
            feedId: feedId,
            validFromTimestamp: uint32(obsTs),
            observationsTimestamp: uint32(obsTs),
            nativeFee: 0,
            linkFee: 0,
            expiresAt: uint32(expiresAt),
            price: price
        });
        bytes32[3] memory ctx;
        return abi.encode(ctx, abi.encode(r));
    }

    /// @dev Dev-keeper loop: checkUpkeep -> fill each slot's report for its own
    ///      plannedStart -> performUpkeep as the forwarder. `nowTs` is the
    ///      fabrication wall-clock, passed explicitly (see the TIMESTAMP note above).
    function _runKeeper(uint256 nowTs, int192 strikePrice) internal {
        (bool needed, bytes memory performData) = cycler.checkUpkeep("");
        assertTrue(needed, "upkeep expected");

        (uint256[] memory resolveIndices, UpDownAutoCycler.CreateSlot[] memory slots) =
            abi.decode(performData, (uint256[], UpDownAutoCycler.CreateSlot[]));
        for (uint256 i; i < slots.length; ++i) {
            slots[i].signedReport = _wrapV3(FEED_SPOT_V3, slots[i].plannedStart, nowTs + REPORT_TTL, strikePrice);
        }

        vm.prank(relayer);
        cycler.performUpkeep(abi.encode(resolveIndices, slots));
    }

    /// @dev Bootstrap the 5-minute market at T0 and return its id.
    function _bootstrap5mMarket() internal returns (uint256 marketId) {
        _runKeeper(T0, STRIKE);
        (marketId,,) = cycler.activeMarkets(0);
        UpDownSettlement.Market memory m = settlement.getMarket(marketId);
        assertEq(uint256(m.startTime), T0, "5m market starts at the T0 boundary");
        assertEq(uint256(m.endTime), END_5M, "5m market ends one slot later");
        assertEq(int256(m.strikePrice), int256(STRIKE), "strike came from the spot stream");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// H-1 — strike and settlement can come from different feeds
// ─────────────────────────────────────────────────────────────────────────────

contract AuditH1FeedRotationTest is UpDownBundleFixture {
    function setUp() public {
        _deployBundle();
    }

    /// H-1 (control): with the feed left alone, the market settles against the same
    /// series it was struck on and the outcome is correct.
    function test_H1_control_noRotation_settlesOnItsOwnSeries() public {
        uint256 mid = _bootstrap5mMarket();

        // Spot closed 100 USD above the strike -> UP.
        int192 spotAtClose = STRIKE + 100e18;
        vm.warp(END_5M);
        vm.prank(relayer);
        resolver.resolve(mid, _wrapV3(FEED_SPOT_V3, END_5M, END_5M + REPORT_TTL, spotAtClose));

        UpDownSettlement.Market memory m = settlement.getMarket(mid);
        assertTrue(m.resolved, "resolved");
        assertEq(uint256(m.winner), 1, "UP wins: close > strike on the same series");
    }

    /// H-1: the owner rotates `streamsFeedId` while a market is open. The market was
    /// struck on the spot stream; it now settles against the TWAP stream. Nothing
    /// reverts, and the two numbers being compared come from different series.
    ///
    /// This is the 2026-08-13 cutover reproduced on-chain: `.env.prod.example` and
    /// `docs/operations.md:106` record six markets / 221.63 USDT orphaned by it.
    ///
    /// FIX: once `capturedStrikeFeedId` is recorded at capture and compared at
    /// resolve, this `resolve` must revert instead of succeeding — replace the
    /// success assertions below with the new `StrikeFeedRotated` expectation.
    function test_H1_rotationMidMarket_settlesAgainstADifferentSeries() public {
        uint256 mid = _bootstrap5mMarket();

        // The strike is on the books, captured under the spot stream.
        assertEq(int256(resolver.capturedStrike(BTCUSD, uint64(T0))), int256(STRIKE));
        assertEq(resolver.streamsFeedId(BTCUSD), FEED_SPOT_V3, "struck under the spot stream");

        // ── The cutover: owner repoints the pair mid-market. No guard on open markets.
        vm.prank(owner);
        resolver.configureStreamsFeed(BTCUSD, FEED_TWAP_V2);
        assertEq(resolver.streamsFeedId(BTCUSD), FEED_TWAP_V2, "now settles under the TWAP stream");

        // Spot at close is ABOVE the strike, so the market's own series says UP.
        // A 60-second TWAP over a rising minute reads below spot — here, below the
        // strike. The two series disagree, and the market is settled on the one it
        // was never struck against.
        int192 spotAtClose = STRIKE + 100e18;
        int192 twapAtClose = STRIKE - 40e18;

        vm.warp(END_5M);
        vm.prank(relayer);
        resolver.resolve(mid, _wrapV2(FEED_TWAP_V2, END_5M, END_5M + REPORT_TTL, twapAtClose));

        UpDownSettlement.Market memory m = settlement.getMarket(mid);

        // The core of the finding: it went through.
        assertTrue(m.resolved, "H-1: cross-series settlement is accepted, not rejected");
        assertEq(int256(m.settlementPrice), int256(twapAtClose), "settled on the TWAP series");
        assertEq(int256(m.strikePrice), int256(STRIKE), "struck on the spot series");

        // And the outcome is the opposite of what the market's own series produced.
        assertEq(uint256(m.winner), 2, "DOWN wins on the rotated series");
        assertGt(spotAtClose, int192(int256(m.strikePrice)), "UP would have won on the struck series");
    }

    /// H-1 (orphaning): after the rotation, the report from the stream the market was
    /// actually struck on is no longer accepted — the schema dispatch reads the newly
    /// configured id, so a v3 blob fails the v2 length check. The market cannot be
    /// settled on its own series at all.
    ///
    /// FIX: with the strike bound to its feed, this path should surface a typed
    /// "this market belongs to the previous stream" error rather than a length
    /// mismatch that reads like a malformed report.
    function test_H1_afterRotation_ownSeriesReportIsRejected() public {
        uint256 mid = _bootstrap5mMarket();

        vm.prank(owner);
        resolver.configureStreamsFeed(BTCUSD, FEED_TWAP_V2);

        vm.warp(END_5M);
        bytes memory ownSeriesReport = _wrapV3(FEED_SPOT_V3, END_5M, END_5M + REPORT_TTL, STRIKE + 100e18);

        // 288 bytes (v3) offered where the configured id advertises v2 (224).
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkResolver.UnexpectedReportLength.selector, 288));
        resolver.resolve(mid, ownSeriesReport);

        assertFalse(settlement.getMarket(mid).resolved, "market is stranded on the wrong side of the rotation");
    }

    /// H-1: user funds are live while the rotation happens. A holder who minted
    /// against the spot-struck market is paid out on the TWAP comparison.
    function test_H1_rotationDecidesRealMoney() public {
        uint256 mid = _bootstrap5mMarket();

        // Alice buys the side that the market's own series would have paid.
        vm.prank(alice);
        settlement.mint(mid, 100e6); // 100 USDT -> 100 UP + 100 DOWN
        assertEq(usdt.balanceOf(address(settlement)), 100e6, "collateral in");

        vm.prank(owner);
        resolver.configureStreamsFeed(BTCUSD, FEED_TWAP_V2);

        // Spot says UP by 100; TWAP says DOWN by 40. DOWN is what gets paid.
        vm.warp(END_5M);
        vm.prank(relayer);
        resolver.resolve(mid, _wrapV2(FEED_TWAP_V2, END_5M, END_5M + REPORT_TTL, STRIKE - 40e18));

        assertEq(uint256(settlement.getMarket(mid).winner), 2, "DOWN paid");

        // Alice holds both legs here, so she is whole — but only because she holds
        // both. Any single-sided holder of UP is zeroed by a series they never
        // agreed to be measured against.
        assertEq(settlement.sharesOf(mid, alice, 1), 100e6, "UP shares now worthless");
        assertEq(settlement.sharesOf(mid, alice, 2), 100e6, "DOWN shares redeem 1:1");

        vm.prank(alice);
        uint256 payout = settlement.redeem(mid);
        assertEq(payout, 100e6, "paid on the rotated series");
        assertEq(settlement.optionShares(mid, 1), 0, "loser side zeroed at resolve");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// H-2 — a market that misses its resolution window strands its collateral
// ─────────────────────────────────────────────────────────────────────────────

contract AuditH2StrandedCollateralTest is UpDownBundleFixture {
    function setUp() public {
        _deployBundle();
    }

    /// H-2: the exits are closed on both sides of `endTime`. `burn` requires the
    /// market to still be open; `redeem` requires it to be resolved. Between them
    /// there is no user-callable path to the collateral.
    function test_H2_bothExitsAreClosedOnceTheMarketEnds() public {
        uint256 mid = _bootstrap5mMarket();

        vm.prank(alice);
        settlement.mint(mid, 100e6);
        assertEq(usdt.balanceOf(address(settlement)), 100e6);

        vm.warp(END_5M); // exactly endTime

        vm.prank(alice);
        vm.expectRevert(UpDownSettlement.MarketNotOpen.selector);
        settlement.burn(mid, 100e6);

        vm.prank(alice);
        vm.expectRevert(UpDownSettlement.NotResolved.selector);
        settlement.redeem(mid);

        // Alice holds a full complete set and cannot reach a cent of it.
        assertEq(settlement.sharesOf(mid, alice, 1), 100e6);
        assertEq(settlement.sharesOf(mid, alice, 2), 100e6);
        assertEq(usdt.balanceOf(address(settlement)), 100e6, "collateral held by the contract");
    }

    /// H-2 (the terminal state): once every report that could satisfy the observation
    /// window has expired, no valid input to `resolve` exists and the collateral is
    /// stranded for good. Both candidate reports are rejected — an in-window report
    /// is expired, a fresh report is out of window — and there is no third option.
    ///
    /// FIX: after a void path exists, the tail of this test becomes "warp past the
    /// void grace period, holder burns the complete set, balance returns to zero".
    function test_H2_expiredReportStrandsCollateralPermanently() public {
        uint256 mid = _bootstrap5mMarket();

        uint256 aliceBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        settlement.mint(mid, 100e6);

        // The resolver service is down across the report's validity window: by the
        // time anyone submits, every report observed at `endTime` has expired.
        uint256 tLate = END_5M + REPORT_TTL + 1;
        vm.warp(tLate);

        // Candidate 1 — a report observed in the window. Rejected: expired.
        uint256 expiredAt = END_5M + REPORT_TTL;
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkResolver.ReportExpired.selector, expiredAt, tLate));
        resolver.resolve(mid, _wrapV3(FEED_SPOT_V3, END_5M, expiredAt, STRIKE + 100e18));

        // Candidate 2 — a fresh, unexpired report. Rejected: observed after close.
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkResolver.ReportObservationOutOfWindow.selector, END_5M, tLate));
        resolver.resolve(mid, _wrapV3(FEED_SPOT_V3, tLate, tLate + REPORT_TTL, STRIKE + 100e18));

        // No amount of waiting helps — the window is anchored to a fixed endTime and
        // recedes further from anything still verifiable.
        uint256 tYear = END_5M + 365 days;
        vm.warp(tYear);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkResolver.ReportObservationOutOfWindow.selector, END_5M, tYear));
        resolver.resolve(mid, _wrapV3(FEED_SPOT_V3, tYear, tYear + REPORT_TTL, STRIKE + 100e18));

        // A year later: still unresolved, still no exit, collateral still held.
        assertFalse(settlement.getMarket(mid).resolved, "never resolvable");

        vm.prank(alice);
        vm.expectRevert(UpDownSettlement.NotResolved.selector);
        settlement.redeem(mid);

        vm.prank(alice);
        vm.expectRevert(UpDownSettlement.MarketNotOpen.selector);
        settlement.burn(mid, 100e6);

        assertEq(usdt.balanceOf(address(settlement)), 100e6, "H-2: collateral permanently stranded");
        assertEq(usdt.balanceOf(alice), aliceBefore - 100e6, "alice is out 100 USDT with no claim");
        assertEq(settlement.marketRetained(mid), 100e6, "accounting still says the money is owed");
    }

    /// H-2 (trigger): a sequencer restart blocks every resolve for the full
    /// `SEQUENCER_GRACE_PERIOD` of 1 hour — twelve times the entire lifetime of a
    /// 5-minute market. The market's whole resolution window falls inside the outage.
    function test_H2_sequencerGraceOutlivesAShortMarket() public {
        uint256 mid = _bootstrap5mMarket();

        vm.prank(alice);
        settlement.mint(mid, 100e6);

        // The sequencer goes down and comes back up right as the market closes.
        vm.warp(END_5M);
        sequencer.setRound(0, END_5M); // up, but the round is brand new

        assertEq(resolver.SEQUENCER_GRACE_PERIOD(), 1 hours);

        // For the entire grace period the resolver refuses, whatever the report says.
        vm.prank(relayer);
        vm.expectRevert(ChainlinkResolver.SequencerGracePeriod.selector);
        resolver.resolve(mid, _wrapV3(FEED_SPOT_V3, END_5M, END_5M + REPORT_TTL, STRIKE + 100e18));

        uint256 tAlmost = END_5M + 1 hours - 1;
        vm.warp(tAlmost);
        vm.prank(relayer);
        vm.expectRevert(ChainlinkResolver.SequencerGracePeriod.selector);
        resolver.resolve(mid, _wrapV3(FEED_SPOT_V3, END_5M, tAlmost + REPORT_TTL, STRIKE + 100e18));

        // By the time the gate opens, the market has been closed for an hour and the
        // reports that observed its close are long expired (REPORT_TTL = 5 min).
        uint256 tOpen = END_5M + 1 hours;
        vm.warp(tOpen);
        uint256 realisticExpiry = END_5M + REPORT_TTL;
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkResolver.ReportExpired.selector, realisticExpiry, tOpen));
        resolver.resolve(mid, _wrapV3(FEED_SPOT_V3, END_5M, realisticExpiry, STRIKE + 100e18));

        assertFalse(settlement.getMarket(mid).resolved, "outage swallowed the market's only window");
        assertEq(usdt.balanceOf(address(settlement)), 100e6, "collateral stranded by an ordinary L2 event");
    }

    /// H-2 (trigger): a pause spanning the resolution window fails SILENTLY. The
    /// settlement's `resolve` carries `whenNotPaused`, and `ChainlinkResolver.resolve`
    /// catches the revert into a `ResolveFailed` event — so the resolver's own
    /// `info.resolved` stays false and the submitter sees a successful transaction.
    function test_H2_pauseDuringResolutionFailsSilently() public {
        uint256 mid = _bootstrap5mMarket();

        vm.prank(alice);
        settlement.mint(mid, 100e6);

        vm.prank(owner);
        settlement.setPaused(true);

        vm.warp(END_5M);
        int192 closePrice = STRIKE + 100e18;

        // The submitting transaction SUCCEEDS. Only an event records the failure.
        vm.expectEmit(true, false, false, true, address(resolver));
        emit ChainlinkResolver.ResolveFailed(
            mid, int256(closePrice), abi.encodeWithSelector(UpDownSettlement.Paused.selector)
        );
        vm.prank(relayer);
        resolver.resolve(mid, _wrapV3(FEED_SPOT_V3, END_5M, END_5M + REPORT_TTL, closePrice));

        assertFalse(settlement.getMarket(mid).resolved, "settlement never resolved");

        // Retry is possible only while a valid report still exists. Past that, the
        // pause has permanently consumed the market's resolution window.
        uint256 tAfterExpiry = END_5M + REPORT_TTL + 1;
        vm.warp(tAfterExpiry);
        vm.prank(owner);
        settlement.setPaused(false);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkResolver.ReportExpired.selector, END_5M + REPORT_TTL, tAfterExpiry)
        );
        resolver.resolve(mid, _wrapV3(FEED_SPOT_V3, END_5M, END_5M + REPORT_TTL, closePrice));

        assertEq(usdt.balanceOf(address(settlement)), 100e6, "collateral stranded by a pause");
    }

    /// H-2 (non-remedy): `evictUnresolved` is the only cleanup hatch on the cycler,
    /// and its docstring is explicit that it touches bookkeeping only. Evicting the
    /// market clears it from `_activeMarkets[]` and leaves every cent behind.
    function test_H2_evictUnresolvedDoesNotFreeCollateral() public {
        uint256 mid = _bootstrap5mMarket();

        vm.prank(alice);
        settlement.mint(mid, 100e6);

        uint256 before = cycler.activeMarketCount();

        // Past endTime + RESOLVER_MAX_STALENESS, so the market is provably unresolvable.
        vm.warp(END_5M + 1 hours + 1);

        uint256[] memory ids = new uint256[](1);
        ids[0] = mid;
        vm.prank(owner);
        cycler.evictUnresolved(ids);

        assertEq(cycler.activeMarketCount(), before - 1, "cycler forgot the market");
        assertFalse(settlement.getMarket(mid).resolved, "settlement state untouched");
        assertEq(usdt.balanceOf(address(settlement)), 100e6, "H-2: eviction frees no collateral");

        vm.prank(alice);
        vm.expectRevert(UpDownSettlement.NotResolved.selector);
        settlement.redeem(mid);
    }

    /// H-2 (current escape hatch, and why it is finding T-1): the only way out today
    /// is the owner naming themselves resolver and declaring an outcome by hand, with
    /// Chainlink bypassed entirely and no timelock. The recovery path and the
    /// arbitrary-outcome path are the same lever.
    function test_H2_onlyRecoveryIsAnUnconstrainedOwnerOverride() public {
        uint256 mid = _bootstrap5mMarket();

        vm.prank(alice);
        settlement.mint(mid, 100e6);

        vm.warp(END_5M + 365 days); // long past any verifiable report

        address ownerEoa = owner;
        vm.prank(owner);
        settlement.setResolver(ownerEoa);

        // No report, no feed, no validation beyond "caller is the resolver".
        vm.prank(ownerEoa);
        settlement.resolve(mid, 0, 2);

        UpDownSettlement.Market memory m = settlement.getMarket(mid);
        assertTrue(m.resolved, "recovered by fiat");
        assertEq(uint256(m.winner), 2, "winner chosen by the owner, not by price");
        assertEq(int256(m.settlementPrice), 0, "settlement price is whatever was passed in");

        vm.prank(alice);
        assertEq(settlement.redeem(mid), 100e6, "collateral released");
        assertEq(usdt.balanceOf(address(settlement)), 0);
    }
}
