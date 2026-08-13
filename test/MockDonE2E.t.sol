// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {UpDownSettlement} from "../src/UpDownSettlement.sol";
import {ChainlinkResolver} from "../src/ChainlinkResolver.sol";
import {UpDownAutoCycler} from "../src/UpDownAutoCycler.sol";
import {MockUSDT} from "../src/mocks/MockUSDT.sol";
import {MockAggregatorV3} from "../src/mocks/MockAggregatorV3.sol";
import {MockVerifierProxy} from "../src/mocks/MockVerifierProxy.sol";
import {ReportV3} from "../src/interfaces/IVerifierProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock-DON demo path e2e: drives `captureStrike` (via the AutoCycler
///         upkeep flow, exactly as the dev-keeper does) and `resolve` (as the
///         resolver service does) through the PROMOTED stateless
///         `src/mocks/MockVerifierProxy` using the exact off-chain blob
///         encoding the backend report producer fabricates in
///         `STREAMS_MOCK=1` mode:
///
///             reportData   = abi.encode(ReportV3{...})
///             signedReport = abi.encode([bytes32(0) x3], reportData)
///
///         This is the encoding-compatibility gate for
///         `updown-demo/UPDOWN_DEMO_PLAN_MOCK_DON.md` — if the wrapper shape
///         or ReportV3 layout drifts between the backend producer and the
///         resolver's decode, this test is what catches it before a deploy.
contract MockDonE2ETest is Test {
    bytes32 constant BTCUSD = keccak256("BTC/USD");
    bytes32 constant ETHUSD = keccak256("ETH/USD");
    // The demo's actual mock stream ids (keccak256("UPDOWN.MOCK.<pair>")).
    bytes32 constant FEED_BTC = bytes32((uint256(3) << 240) | (uint256(keccak256("UPDOWN.MOCK.BTC/USD")) >> 16));
    bytes32 constant FEED_ETH = bytes32((uint256(3) << 240) | (uint256(keccak256("UPDOWN.MOCK.ETH/USD")) >> 16));

    // 18-decimal atomic scale (real Crypto Streams scale; backend
    // STRIKE_DECIMALS_FOR_NEW_MARKETS defaults to 18 to match).
    int192 constant BTC_STRIKE = 108_000e18;

    // Aligned to 3600 (= 486555 * 3600) so the bootstrap slot of all three
    // timeframes (300/900/3600) lands on the same boundary. NB: a literal
    // expression like `x / 3600 * 3600` would NOT floor — Solidity constant
    // arithmetic is exact-rational.
    uint256 constant T0 = 1_751_598_000;

    address owner = makeAddr("owner");
    address relayer = makeAddr("relayer");
    address treasury = makeAddr("treasury");

    MockUSDT usdt;
    MockVerifierProxy verifier;
    UpDownSettlement settlement;
    ChainlinkResolver resolver;
    UpDownAutoCycler cycler;

    function setUp() public {
        vm.warp(T0);

        usdt = new MockUSDT();
        verifier = new MockVerifierProxy();
        MockAggregatorV3 btcFeed = new MockAggregatorV3(108_000e8, 8, 0);
        MockAggregatorV3 ethFeed = new MockAggregatorV3(2_500e8, 8, 0);
        // answer=0 => sequencer up; fixedStartedAt=1 => ancient => past grace.
        MockAggregatorV3 sequencer = new MockAggregatorV3(0, 0, 1);

        // Mirror Deploy.s.sol wiring exactly.
        vm.startPrank(owner);
        settlement = new UpDownSettlement(IERC20(address(usdt)), owner);
        resolver = new ChainlinkResolver(
            owner,
            address(sequencer),
            BTCUSD,
            address(btcFeed),
            ETHUSD,
            address(ethFeed),
            address(settlement),
            address(verifier),
            address(0xF97F) // LINK: stored, never used (s_feeManager()==0)
        );
        cycler = new UpDownAutoCycler(owner, address(resolver), address(settlement));

        settlement.setResolver(address(resolver));
        settlement.setAutocycler(address(cycler));
        settlement.setRelayer(relayer);
        settlement.setTreasury(treasury);

        resolver.setAuthorizedCaller(address(cycler), true);
        resolver.setAuthorizedCaller(relayer, true);

        cycler.setForwarder(relayer);
        cycler.addPair(BTCUSD);

        // Post-deploy ops step from the runbook: bind pair -> mock stream id.
        resolver.configureStreamsFeed(BTCUSD, FEED_BTC);
        vm.stopPrank();
    }

    /// @dev Byte-for-byte the blob the backend producer fabricates
    ///      (ChainlinkResolverService.fetchSignedReport, STREAMS_MOCK=1).
    ///      `nowTs` is the fabrication wall-clock, passed explicitly instead
    ///      of reading block.timestamp: solc CSEs the TIMESTAMP opcode
    ///      within a test function, so a read here would not track vm.warp.
    function _wrapReport(bytes32 feedId, uint256 obsTs, uint256 nowTs, int192 price)
        internal
        pure
        returns (bytes memory signedReport)
    {
        ReportV3 memory r = ReportV3({
            feedId: feedId,
            validFromTimestamp: uint32(obsTs),
            observationsTimestamp: uint32(obsTs),
            nativeFee: 0,
            linkFee: 0,
            expiresAt: uint32(nowTs + 300),
            price: price,
            bid: price,
            ask: price
        });
        bytes memory reportData = abi.encode(r);
        bytes32[3] memory ctx;
        signedReport = abi.encode(ctx, reportData);
    }

    /// @dev Dev-keeper loop: checkUpkeep -> fill each CreateSlot.signedReport
    ///      for its own plannedStart -> performUpkeep as the forwarder.
    function _runKeeper(uint256 nowTs, int192 strikePrice) internal {
        (bool needed, bytes memory performData) = cycler.checkUpkeep("");
        assertTrue(needed, "upkeep expected");

        (uint256[] memory resolveIndices, UpDownAutoCycler.CreateSlot[] memory slots) =
            abi.decode(performData, (uint256[], UpDownAutoCycler.CreateSlot[]));
        for (uint256 i; i < slots.length; ++i) {
            slots[i].signedReport = _wrapReport(FEED_BTC, slots[i].plannedStart, nowTs, strikePrice);
        }

        vm.prank(relayer);
        cycler.performUpkeep(abi.encode(resolveIndices, slots));
    }

    function test_mockDon_strikeAndResolve_exactProducerEncoding() public {
        // ── Strike: bootstrap creates one market per timeframe (300/900/3600),
        //    all at the same T0 boundary; captureStrike verifies the first
        //    blob through MockVerifierProxy and dedup-caches the rest.
        _runKeeper(T0, BTC_STRIKE);

        (uint256 m5, uint256 end5,) = cycler.activeMarkets(0);
        UpDownSettlement.Market memory m = settlement.getMarket(m5);
        assertEq(uint256(m.startTime), T0, "5m market starts at boundary");
        assertEq(uint256(m.endTime), T0 + 300, "5m market ends next boundary");
        assertEq(int256(m.strikePrice), int256(BTC_STRIKE), "strike == producer price");
        assertEq(end5, T0 + 300);
        assertEq(int256(resolver.capturedStrike(BTCUSD, uint64(T0))), int256(BTC_STRIKE));

        // ── Resolve UP: close 0.5% above strike at exactly endTime.
        vm.warp(T0 + 300);
        int192 closeUp = int192((int256(BTC_STRIKE) * 1005) / 1000);
        vm.prank(relayer);
        resolver.resolve(m5, _wrapReport(FEED_BTC, T0 + 300, T0 + 300, closeUp));

        m = settlement.getMarket(m5);
        assertTrue(m.resolved, "5m market resolved");
        assertEq(uint256(m.winner), 1, "UP wins when close > strike");
        assertEq(int256(m.settlementPrice), int256(closeUp));

        // ── Resolve DOWN on the 15m market at its own boundary.
        (uint256 m15, uint256 end15,) = cycler.activeMarkets(1);
        assertEq(end15, T0 + 900, "15m market ends at its own boundary");
        vm.warp(T0 + 900);
        int192 closeDown = int192((int256(BTC_STRIKE) * 995) / 1000);
        vm.prank(relayer);
        resolver.resolve(m15, _wrapReport(FEED_BTC, T0 + 900, T0 + 900, closeDown));

        m = settlement.getMarket(m15);
        assertTrue(m.resolved, "15m market resolved");
        assertEq(uint256(m.winner), 2, "DOWN wins when close < strike");
    }

    /// @dev The observation-window guards must still bite through the mock:
    ///      a producer bug that stamps `Date.now()` instead of the requested
    ///      boundary is rejected on-chain (plan §10 trap 4).
    function test_mockDon_wrongObservationTimestamp_reverts() public {
        _runKeeper(T0, BTC_STRIKE);
        (uint256 m5,,) = cycler.activeMarkets(0);

        vm.warp(T0 + 300 + 60); // resolver service running a minute late
        // obs stamped "now" instead of endTime: outside [end-3s, end].
        bytes memory bad = _wrapReport(FEED_BTC, T0 + 360, T0 + 360, BTC_STRIKE);
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkResolver.ReportObservationOutOfWindow.selector, T0 + 300, T0 + 360)
        );
        resolver.resolve(m5, bad);

        // obs == endTime still verifies fine a minute late (expiresAt allows it).
        vm.prank(relayer);
        resolver.resolve(m5, _wrapReport(FEED_BTC, T0 + 300, T0 + 360, BTC_STRIKE + 1e18));
        UpDownSettlement.Market memory m = settlement.getMarket(m5);
        assertTrue(m.resolved);
        assertEq(uint256(m.winner), 1);
    }

    /// @dev Wrong feed id in the fabricated report must be rejected — the
    ///      pair<->feedId binding survives the mock path.
    function test_mockDon_feedIdMismatch_reverts() public {
        _runKeeper(T0, BTC_STRIKE);
        (uint256 m5,,) = cycler.activeMarkets(0);

        vm.warp(T0 + 300);
        bytes memory wrongFeed = _wrapReport(FEED_ETH, T0 + 300, T0 + 300, BTC_STRIKE);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkResolver.ReportFeedIdMismatch.selector, FEED_BTC, FEED_ETH));
        resolver.resolve(m5, wrongFeed);
    }
}
