// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {UpDownSettlement} from "../src/UpDownSettlement.sol";
import {ChainlinkResolver} from "../src/ChainlinkResolver.sol";
import {MockUSDT} from "../src/mocks/MockUSDT.sol";
import {MockAggregatorV3} from "../src/mocks/MockAggregatorV3.sol";
import {IVerifierProxy, IFeeManager, FeeManagerAsset, ReportV3} from "../src/interfaces/IVerifierProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice **Gate 3 real-DON fork test** (see updown-demo/UPDOWN_LIVE_TESTNET_DEPLOY_PLAN.md §5).
///
///         Forks Arbitrum Sepolia, deploys UpDown against the REAL Chainlink
///         Data Streams Verifier Proxy (`0x2ff0…488A`) + real LINK
///         (`0xb1D4538…1E80E`), fetches a REAL signed ETH/USD `ReportV3`
///         from `api.testnet-dataengine.chain.link` (via the FFI helper
///         `script/fetch_streams_report.mjs`, which is byte-identical to the
///         backend's `ChainlinkResolverService`), and asserts the full
///         off-chain-fetch → on-chain `verify` → LINK-fee-deducted →
///         `settlement.resolve` / `captureStrike` round-trip.
///
///         Unlike `MockDonE2E.t.sol` (which fabricates unsigned blobs through
///         the promoted `MockVerifierProxy`), this test exercises the ACTUAL
///         DON signatures + FeeManager LINK path — the thing that cannot be
///         proven with a mock. Two negative controls confirm the real
///         verifier + the resolver's own window guard both bite.
///
///         ── Gate-3 economics finding (measured on-chain 2026-07-08) ──
///         The report blob QUOTES `linkFee ≈ 0.0423 LINK`, but the Arbitrum
///         Sepolia FeeManager applies a **100% discount** (`getFeeAndReward`
///         returns `fee.amount = 0`, `totalDiscount = 1e18`), so verification
///         is **free on testnet** — the resolver's LINK balance does NOT drop
///         per verify. The plan's "~0.042 LINK/verify → ~2.5 days soak" budget
///         concern is therefore moot on testnet (LINK is only consumed on
///         mainnet, where the discount is 0). This test asserts the
///         chain-agnostic invariant instead: the resolver's LINK delta equals
///         exactly what the FeeManager quotes for THIS report+subscriber —
///         which is 0 here and would be ~0.0423 on Arbitrum One. The nonzero
///         mainnet fee-pull path (forceApprove → RewardManager) is covered by
///         `UpDownUnit.t.sol` against a mock FeeManager that quotes > 0.
///
///         ── Why ETH/USD, not BTC/USD ──
///         The Gate-3 API key is allow-listed for ETH/USD only; BTC/USD
///         returns HTTP 401 "feeds not authorized" (plan §1a). This test
///         therefore leads with ETH/USD, exactly like the backend cadence
///         (plan §3). Once BTC is authorized, set `STREAMS_FEED_ID` to the
///         BTC stream and it works unchanged.
///
///         ── How to run ──
///         Needs a fork RPC + the Data Streams creds in the environment, and
///         forge FFI. The `fork` profile in foundry.toml enables ffi:
///
///           set -a && source ../testnet.env && set +a
///           export STREAMS_API_BASE_URL=https://api.testnet-dataengine.chain.link
///           export ARBITRUM_SEPOLIA_RPC_URL=https://arb-sepolia.g.alchemy.com/v2/<KEY>
///           FOUNDRY_PROFILE=fork forge test --match-contract UpDownForkTest -vvv
///
///         When `ARBITRUM_SEPOLIA_RPC_URL` or the Streams creds are absent
///         (e.g. the default CI audit run) every test self-skips via
///         `vm.skip(true)`, so the 143-test suite stays green and never
///         touches the network.
contract UpDownForkTest is Test {
    // ── Real Arbitrum Sepolia Chainlink Data Streams infra (plan §1) ──────
    address constant VERIFIER_PROXY = 0x2ff010DEbC1297f19579B4246cad07bd24F2488A;
    address constant LINK = 0xb1D4538B4571d411F07960EF2838Ce337FE1E80E;
    // ETH/USD Data Streams stream id on Arbitrum Sepolia testnet.
    bytes32 constant ETH_STREAM_ID = 0x000359843a543ee2fe414dc14c7e7920ef10f4372990b79d6361cdc0dd1ba782;

    bytes32 constant BTCUSD = keccak256("BTC/USD");
    bytes32 constant ETHUSD = keccak256("ETH/USD");

    MockUSDT usdt;
    UpDownSettlement settlement;
    ChainlinkResolver resolver;

    bool _skipFork; // set in setUp when creds / fork RPC unavailable
    uint64 alignedTs; // recent clock-aligned (300s) boundary with a finalized report

    function setUp() public {
        string memory rpc = vm.envOr("ARBITRUM_SEPOLIA_RPC_URL", string(""));
        // Accept either the bare cred names (testnet.env) or the backend's
        // CHAINLINK_-prefixed ones. The FFI helper reads both too.
        string memory k1 = vm.envOr("STREAMS_API_KEY", string(""));
        string memory k2 = vm.envOr("CHAINLINK_STREAMS_API_KEY", string(""));
        if (bytes(rpc).length == 0 || (bytes(k1).length == 0 && bytes(k2).length == 0)) {
            _skipFork = true;
            return;
        }

        vm.createSelectFork(rpc);

        // A safely-finalized, non-expired past boundary: the previous complete
        // 300s slot relative to the fork's head. The Streams timestamp endpoint
        // returns the exact-second report for it (obs == alignedTs, delta 0 —
        // plan §5.2), and testnet reports carry a ~30-day expiry so it is still
        // verifiable.
        alignedTs = uint64((block.timestamp / 300) * 300 - 300);

        // Mirror Deploy.s.sol wiring; owner == this test so it can drive every
        // authorized entrypoint directly.
        usdt = new MockUSDT();
        MockAggregatorV3 btcFeed = new MockAggregatorV3(60_000e8, 8, 0);
        MockAggregatorV3 ethFeed = new MockAggregatorV3(3_000e8, 8, 0);
        MockAggregatorV3 sequencer = new MockAggregatorV3(0, 0, 1); // up + ancient => past grace

        settlement = new UpDownSettlement(IERC20(address(usdt)), address(this));
        resolver = new ChainlinkResolver(
            address(this),
            address(sequencer),
            BTCUSD,
            address(btcFeed),
            ETHUSD,
            address(ethFeed),
            address(settlement),
            VERIFIER_PROXY, // <-- REAL Chainlink Verifier Proxy
            LINK //           <-- REAL Sepolia LINK (must match FeeManager.i_linkAddress())
        );

        settlement.setResolver(address(resolver));
        // Let this test create markets directly (createMarket is onlyAutocycler).
        settlement.setAutocycler(address(this));
        settlement.setRelayer(address(this));
        settlement.setTreasury(address(this));

        resolver.setAuthorizedCaller(address(this), true);
        resolver.configureStreamsFeed(ETHUSD, ETH_STREAM_ID);

        // Gate-3 wiring assertions: the resolver goes through the REAL fee
        // branch of `_payVerificationFee` (FeeManager set), and its configured
        // LINK matches what the FeeManager expects (else the "FeeManager LINK
        // mismatch" require would abort every verify).
        address feeManager = IVerifierProxy(VERIFIER_PROXY).s_feeManager();
        assertTrue(feeManager != address(0), "Sepolia proxy has no FeeManager -- fee branch not exercised");
        assertEq(IFeeManager(feeManager).i_linkAddress(), LINK, "FeeManager LINK != configured LINK");

        // Fund the resolver with LINK so the real FeeManager path can deduct
        // the per-verify fee (~0.042 LINK). `deal` writes the balance slot on
        // the fork — no real testnet LINK is spent.
        deal(LINK, address(resolver), 10 ether);
    }

    // ── FFI: fetch a real signed report + decode it (same unwrap the resolver does) ──

    function _fetchRealReport(uint64 ts) internal returns (bytes memory blob) {
        string[] memory inputs = new string[](4);
        inputs[0] = "node";
        inputs[1] = "script/fetch_streams_report.mjs";
        inputs[2] = vm.toString(ETH_STREAM_ID);
        inputs[3] = vm.toString(uint256(ts));
        blob = vm.ffi(inputs); // stdout is 0x<fullReport>, forge decodes hex -> bytes
        require(blob.length > 500, "fork: FFI returned no/short report (creds? feed auth? --ffi?)");
    }

    function _decode(bytes memory blob) internal pure returns (ReportV3 memory r) {
        (, bytes memory reportData) = abi.decode(blob, (bytes32[3], bytes));
        r = abi.decode(reportData, (ReportV3));
    }

    /// @dev What the live FeeManager actually bills the resolver for this
    ///      report — the source of truth for the on-chain LINK deduction
    ///      (0 on Sepolia via the 100% testnet discount; >0 on mainnet).
    ///      Queried with the SAME subscriber (the resolver) the resolve path
    ///      uses, so the quote matches the deduction exactly.
    function _quotedLinkFee(bytes memory blob) internal view returns (uint256 amount, uint256 totalDiscount) {
        (, bytes memory reportData) = abi.decode(blob, (bytes32[3], bytes));
        IFeeManager fm = IFeeManager(IVerifierProxy(VERIFIER_PROXY).s_feeManager());
        (FeeManagerAsset memory fee,, uint256 disc) = fm.getFeeAndReward(address(resolver), reportData, LINK);
        return (fee.amount, disc);
    }

    function _createAndRegister(int256 strike, uint64 startTime, uint64 endTime) internal returns (uint256 marketId) {
        uint256 duration = uint256(endTime) - uint256(startTime);
        marketId = settlement.createMarket(ETHUSD, duration, strike, startTime, endTime);
        resolver.registerMarket(marketId, address(settlement), ETHUSD, strike);
    }

    // ── 5.1 core: real report resolves a market, real LINK fee is deducted ──

    function test_realDon_resolve_roundTrip() public {
        if (_skipFork) {
            vm.skip(true);
            return;
        }

        bytes memory blob = _fetchRealReport(alignedTs);
        ReportV3 memory r = _decode(blob);

        // The timestamp endpoint returns the exact-second report (plan §5.2).
        assertEq(uint256(r.observationsTimestamp), uint256(alignedTs), "obs != requested aligned ts");
        assertEq(r.feedId, ETH_STREAM_ID, "report feedId != ETH stream id");
        assertGt(r.price, 0, "non-positive DON price");
        assertGt(r.linkFee, 0, "real report should quote a LINK fee in its blob");
        (uint256 quotedFee, uint256 discount) = _quotedLinkFee(blob);
        console.log("ETH/USD price (1e18):     ", uint256(int256(r.price)));
        console.log("report-quoted linkFee(wei):", uint256(r.linkFee));
        console.log("FeeManager billed fee(wei):", quotedFee);
        console.log("FeeManager discount(1e18=100%):", discount);

        // strike = 1 wei => settlement price (~1.7e21) > strike => UP deterministically.
        uint64 endTime = uint64(r.observationsTimestamp); // obs == endTime => in window
        uint256 marketId = _createAndRegister(1, endTime - 300, endTime);

        vm.warp(uint256(endTime)); // block.timestamp == endTime; report not expired

        uint256 linkBefore = IERC20(LINK).balanceOf(address(resolver));
        assertGt(linkBefore, 0, "resolver not LINK-funded (deal hit the wrong slot?)");
        resolver.resolve(marketId, blob);
        uint256 linkAfter = IERC20(LINK).balanceOf(address(resolver));

        UpDownSettlement.Market memory m = settlement.getMarket(marketId);
        assertTrue(m.resolved, "market not resolved by real report");
        assertEq(uint256(m.winner), resolver.OPTION_UP(), "UP expected (price > strike=1)");
        assertEq(int256(m.settlementPrice), int256(r.price), "settlementPrice != report price");

        // Chain-agnostic fee invariant: the resolver's LINK balance drops by
        // EXACTLY what the FeeManager quotes for this report+subscriber. On
        // Sepolia that is 0 (100% testnet discount => free verify); on mainnet
        // it would be the ~0.0423 LINK the report quotes. Either way the
        // resolver pays precisely the billed amount and never more.
        uint256 feePaid = linkBefore - linkAfter;
        assertEq(feePaid, quotedFee, "resolver LINK delta != FeeManager-billed fee");
        // On a fee-charging chain (mainnet; discount 0) the verify MUST strictly
        // consume LINK — guards against a vacuous 0==0 pass if the fee path were
        // ever silently skipped there.
        if (quotedFee > 0) assertLt(linkAfter, linkBefore, "fee-charging chain deducted no LINK");
    }

    // ── strike-side: captureStrike verifies a real report + is idempotent ──

    function test_realDon_captureStrike_roundTripAndIdempotent() public {
        if (_skipFork) {
            vm.skip(true);
            return;
        }

        bytes memory blob = _fetchRealReport(alignedTs);
        ReportV3 memory r = _decode(blob);
        assertEq(uint256(r.observationsTimestamp), uint256(alignedTs), "obs != aligned ts");
        // alignedTs is a 300-multiple => satisfies STRIKE_ALIGNMENT.
        assertEq(uint256(alignedTs) % 300, 0, "alignedTs not 300-aligned");

        vm.warp(uint256(alignedTs)); // report not expired; |obs - startTime| == 0

        (uint256 quotedFee,) = _quotedLinkFee(blob);

        uint256 linkBefore = IERC20(LINK).balanceOf(address(resolver));
        assertGt(linkBefore, 0, "resolver not LINK-funded (deal hit the wrong slot?)");
        int256 strike = resolver.captureStrike(ETHUSD, blob, alignedTs);
        uint256 linkAfterFirst = IERC20(LINK).balanceOf(address(resolver));

        assertEq(strike, int256(r.price), "captured strike != report price");
        assertEq(resolver.capturedStrike(ETHUSD, alignedTs), int256(r.price), "capturedStrike mapping wrong");
        assertTrue(resolver.strikeCaptured(ETHUSD, alignedTs), "strikeCaptured flag not set");
        // Same chain-agnostic invariant as resolve: LINK delta == FeeManager
        // quote (0 on Sepolia's 100% discount, >0 on mainnet).
        assertEq(linkBefore - linkAfterFirst, quotedFee, "strike LINK delta != FeeManager-billed fee");
        if (quotedFee > 0) assertLt(linkAfterFirst, linkBefore, "fee-charging chain deducted no LINK");

        // Idempotency: a second capture of the same (pair, slot) must SHORT-
        // CIRCUIT to the cached strike WITHOUT re-verifying. Prove it positively
        // via recorded logs: the cache path returns before `_checkSequencer`,
        // `verify`, and the `StrikeCaptured` emit, so it produces ZERO logs —
        // whereas a re-verify would emit (verifier events + StrikeCaptured). A
        // LINK-balance check alone can't prove this on testnet, where a
        // re-verify is also free (review finding #6).
        vm.recordLogs();
        int256 strike2 = resolver.captureStrike(ETHUSD, blob, alignedTs);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(strike2, strike, "cached strike differs");
        assertEq(logs.length, 0, "cached capture re-verified (emitted logs) instead of short-circuiting");
        assertEq(IERC20(LINK).balanceOf(address(resolver)), linkAfterFirst, "cached capture charged a fee");
    }

    // ── negative control 1: a report observed AFTER close is rejected ──
    //    (a genuine report, but the market's endTime is before its obs).

    function test_realDon_postCloseObservation_reverts() public {
        if (_skipFork) {
            vm.skip(true);
            return;
        }

        bytes memory blob = _fetchRealReport(alignedTs);
        ReportV3 memory r = _decode(blob);
        uint64 obs = uint64(r.observationsTimestamp);

        // endTime 100s BEFORE the observation => obs > endTime => out of window.
        uint64 endTime = obs - 100;
        uint256 marketId = _createAndRegister(1, endTime - 300, endTime);

        vm.warp(uint256(obs)); // past endTime, so we reach the window check (not MarketNotExpired)

        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkResolver.ReportObservationOutOfWindow.selector, uint256(endTime), uint256(obs)
            )
        );
        resolver.resolve(marketId, blob);
    }

    // ── negative control 2: the REAL verifier rejects a tampered blob ──
    //    Proves on-chain verification is genuine, not a passthrough: a single
    //    flipped byte inside the DON-signed report body invalidates the digest.

    function test_realDon_tamperedReport_reverts() public {
        if (_skipFork) {
            vm.skip(true);
            return;
        }

        bytes memory blob = _fetchRealReport(alignedTs);
        ReportV3 memory r = _decode(blob);
        uint64 endTime = uint64(r.observationsTimestamp);
        uint256 marketId = _createAndRegister(1, endTime - 300, endTime);
        vm.warp(uint256(endTime));

        // Corrupt one byte inside the PRICE word of reportData (fullReport
        // layout: 7-word envelope head = 224B, reportData length word at 224,
        // reportData content from 256; ReportV3 words are feedId, validFrom,
        // obs, nativeFee, linkFee, expiresAt, price, bid, ask — so the price
        // field spans bytes 448..479). Mutating price — NOT a fee field —
        // leaves `getFeeAndReward`/`processFee` computing the identical fee,
        // so the fee path is provably NOT the revert source; the only thing
        // that changed is inside the DON-signed digest. The verifier must
        // therefore be the revert source, on ANY chain regardless of the fee
        // discount (review finding #1). The abi envelope still decodes (offsets
        // untouched), so this cannot revert on a malformed-decode either.
        require(blob.length > 480, "blob too short to tamper the price word");
        blob[470] = bytes1(uint8(blob[470]) ^ 0xff);

        vm.expectRevert(); // real Chainlink verifier reverts on signature/digest mismatch
        resolver.resolve(marketId, blob);
    }
}
