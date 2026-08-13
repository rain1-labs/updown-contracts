// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {UpDownSettlement} from "../src/UpDownSettlement.sol";

/// @title Batch settlement proof suite (`mintMatchBatch` / `mergeMatchBatch` / `enterPositionBatch`).
/// @notice The batch entrypoints exist to lift the single-relayer settlement ceiling: they collapse
///         N on-chain settlement txs into one, applying the `nonReentrant` / `whenNotPaused` /
///         `onlyRelayer` guards ONCE per batch while settling each fill through the SAME internal
///         helper the single-fill entrypoint uses. These tests pin the two properties that make that
///         safe to ship on a money contract:
///           1. Behaviour-preserving — a batch of N produces byte-identical state to N singles, and
///              per-fill events / partial-fill / fee-cap accounting are unchanged.
///           2. All-or-nothing — one bad fill reverts the whole batch and persists NOTHING, so the
///              relayer can safely bisect / fall back to the single entrypoint for the poison fill.
///         The existing `ComplementaryMatch.t.sol` / `RemediationV2.t.sol` suites are the transplant
///         proof: they still exercise `mintMatch` / `mergeMatch` / `enterPosition`, which are now thin
///         wrappers over the extracted internals — if the extraction changed behaviour, they break.
contract SettlementBatchTest is Test {
    bytes32 internal constant PAIR = keccak256("BTC/USD");
    uint8 internal constant UP = 1;
    uint8 internal constant DOWN = 2;
    uint8 internal constant BUY = 0;
    uint8 internal constant SELL = 1;

    ERC20Mock internal usdt;
    UpDownSettlement internal s;

    address internal owner = address(this);
    address internal autocycler = makeAddr("autocycler");
    address internal resolver = makeAddr("resolver");
    address internal relayer = makeAddr("relayer");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        vm.warp(1_700_000_000);
        usdt = new ERC20Mock();
        s = new UpDownSettlement(usdt, owner);
        s.setAutocycler(autocycler);
        s.setResolver(resolver);
        s.setRelayer(relayer);
        s.setTreasury(treasury);
    }

    // ── Helpers (mirror ComplementaryMatch.t.sol) ───────────────────────

    function _wallet(string memory name) internal returns (Vm.Wallet memory w) {
        w = vm.createWallet(name);
        usdt.mint(w.addr, 1_000_000e18);
        vm.prank(w.addr);
        usdt.approve(address(s), type(uint256).max);
    }

    function _market() internal returns (uint256 mid) {
        vm.prank(autocycler);
        mid = s.createMarket(PAIR, 3600, 50_000e8);
    }

    function _order(
        Vm.Wallet memory w,
        uint256 mid,
        uint8 option,
        uint8 side,
        uint256 price,
        uint256 amount,
        uint256 maxFee,
        uint256 nonce
    ) internal view returns (UpDownSettlement.Order memory o) {
        o = UpDownSettlement.Order({
            maker: w.addr,
            market: mid,
            option: option,
            side: side,
            orderType: 0,
            price: price,
            amount: amount,
            maxFee: maxFee,
            nonce: nonce,
            expiry: block.timestamp + 3600
        });
    }

    function _sign(Vm.Wallet memory w, UpDownSettlement.Order memory o) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(w.privateKey, s.orderDigest(o));
        return abi.encodePacked(r, ss, v);
    }

    /// @dev Build a FillInputs. Makes external `orderDigest` calls (via `_sign`), so it MUST be
    ///      evaluated into a local (or into the array element) BEFORE any `vm.prank` /
    ///      `vm.expectRevert`, else the cheat is consumed by the digest call.
    function _inputs(
        UpDownSettlement.Order memory makerO,
        Vm.Wallet memory makerW,
        UpDownSettlement.Order memory takerO,
        Vm.Wallet memory takerW,
        uint256 fillAmount,
        uint256 platformFee,
        uint256 makerFee
    ) internal returns (UpDownSettlement.FillInputs memory f) {
        f = UpDownSettlement.FillInputs({
            makerOrder: makerO,
            makerSignature: _sign(makerW, makerO),
            takerOrder: takerO,
            takerSignature: _sign(takerW, takerO),
            fillAmount: fillAmount,
            platformFee: platformFee,
            makerFee: makerFee
        });
    }

    function _mintSet(Vm.Wallet memory w, uint256 mid, uint256 amount) internal {
        vm.prank(w.addr);
        s.mint(mid, amount);
    }

    function _resolve(uint256 mid, uint8 winner) internal {
        UpDownSettlement.Market memory m = s.getMarket(mid);
        vm.warp(uint256(m.endTime) + 1);
        vm.prank(resolver);
        s.resolve(mid, 60_000e8, winner);
    }

    // ─────────────────────────────────────────────────────────────────────
    //                          MINT MATCH — BATCH
    // ─────────────────────────────────────────────────────────────────────

    /// A batch of 3 independent (UP buyer, DOWN buyer) mint fills settles atomically in ONE call,
    /// crediting each buyer their option's shares and backing all three sets in full.
    function test_mintMatchBatch_aggregatesThreeFills() public {
        uint256 mid = _market();
        Vm.Wallet[3] memory ups = [_wallet("up0"), _wallet("up1"), _wallet("up2")];
        Vm.Wallet[3] memory downs = [_wallet("dn0"), _wallet("dn1"), _wallet("dn2")];

        UpDownSettlement.FillInputs[] memory fs = new UpDownSettlement.FillInputs[](3);
        for (uint256 i; i < 3; ++i) {
            UpDownSettlement.Order memory upBuy = _order(ups[i], mid, UP, BUY, 6000, 100e18, 0, 100 + i);
            UpDownSettlement.Order memory downBuy = _order(downs[i], mid, DOWN, BUY, 4000, 100e18, 0, 200 + i);
            fs[i] = _inputs(upBuy, ups[i], downBuy, downs[i], 100e18, 0, 0);
        }

        vm.prank(relayer);
        s.mintMatchBatch(fs);

        for (uint256 i; i < 3; ++i) {
            assertEq(s.sharesOf(mid, ups[i].addr, UP), 100e18, "UP buyer credited");
            assertEq(s.sharesOf(mid, downs[i].addr, DOWN), 100e18, "DOWN buyer credited");
            assertEq(usdt.balanceOf(ups[i].addr), 1_000_000e18 - 60e18, "UP buyer paid 60%");
            assertEq(usdt.balanceOf(downs[i].addr), 1_000_000e18 - 40e18, "DOWN buyer paid 40%");
        }
        assertEq(s.optionShares(mid, UP), 300e18, "UP supply == 3 sets");
        assertEq(s.optionShares(mid, DOWN), 300e18, "DOWN supply == 3 sets");
        assertEq(s.marketRetained(mid), 300e18, "3 sets backed");
        assertEq(usdt.balanceOf(address(s)), 300e18, "conservation: balance == marketRetained");
    }

    /// The whole point: a batch of N yields state byte-identical to running the same N fills as
    /// singles. Market A settles 3 fills one-by-one via `mintMatch`; market B settles the identical
    /// 3 fills in one `mintMatchBatch`. Every observable — per-buyer shares, per-buyer USDT balance,
    /// aggregate supply, backing, and the contract's own balance — must match exactly.
    function test_mintMatchBatch_equivalentToNSingles() public {
        uint256 midA = _market();
        uint256 midB = _market();

        // Independent wallet sets so cross-market balances are cleanly comparable.
        Vm.Wallet[3] memory upA = [_wallet("A_up0"), _wallet("A_up1"), _wallet("A_up2")];
        Vm.Wallet[3] memory dnA = [_wallet("A_dn0"), _wallet("A_dn1"), _wallet("A_dn2")];
        Vm.Wallet[3] memory upB = [_wallet("B_up0"), _wallet("B_up1"), _wallet("B_up2")];
        Vm.Wallet[3] memory dnB = [_wallet("B_dn0"), _wallet("B_dn1"), _wallet("B_dn2")];

        // Path 1 — SINGLES on market A. Prices vary per fill so the comparison isn't degenerate.
        for (uint256 i; i < 3; ++i) {
            uint256 upPx = 5500 + i * 500; // 55/60/65
            UpDownSettlement.Order memory upBuy = _order(upA[i], midA, UP, BUY, upPx, 100e18, 3e18, 100 + i);
            UpDownSettlement.Order memory downBuy = _order(dnA[i], midA, DOWN, BUY, 5000, 100e18, 3e18, 200 + i);
            UpDownSettlement.FillInputs memory f = _inputs(upBuy, upA[i], downBuy, dnA[i], 100e18, 1e18, 0);
            vm.prank(relayer);
            s.mintMatch(f);
        }

        // Path 2 — ONE BATCH on market B with the identical economic fills.
        UpDownSettlement.FillInputs[] memory fs = new UpDownSettlement.FillInputs[](3);
        for (uint256 i; i < 3; ++i) {
            uint256 upPx = 5500 + i * 500;
            UpDownSettlement.Order memory upBuy = _order(upB[i], midB, UP, BUY, upPx, 100e18, 3e18, 100 + i);
            UpDownSettlement.Order memory downBuy = _order(dnB[i], midB, DOWN, BUY, 5000, 100e18, 3e18, 200 + i);
            fs[i] = _inputs(upBuy, upB[i], downBuy, dnB[i], 100e18, 1e18, 0);
        }
        vm.prank(relayer);
        s.mintMatchBatch(fs);

        // Byte-for-byte equivalence of every observable.
        for (uint256 i; i < 3; ++i) {
            assertEq(s.sharesOf(midA, upA[i].addr, UP), s.sharesOf(midB, upB[i].addr, UP), "UP shares equal");
            assertEq(s.sharesOf(midA, dnA[i].addr, DOWN), s.sharesOf(midB, dnB[i].addr, DOWN), "DOWN shares equal");
            assertEq(usdt.balanceOf(upA[i].addr), usdt.balanceOf(upB[i].addr), "UP buyer balance equal");
            assertEq(usdt.balanceOf(dnA[i].addr), usdt.balanceOf(dnB[i].addr), "DOWN buyer balance equal");
        }
        assertEq(s.optionShares(midA, UP), s.optionShares(midB, UP), "UP supply equal");
        assertEq(s.optionShares(midA, DOWN), s.optionShares(midB, DOWN), "DOWN supply equal");
        assertEq(s.marketRetained(midA), s.marketRetained(midB), "backing equal");
        // Treasury received the platformFee from all 6 fills (3 per path) — same absolute total.
        assertEq(usdt.balanceOf(treasury), 6e18, "treasury got platformFee from all fills");
    }

    /// A one-element batch is indistinguishable from a single call.
    function test_mintMatchBatch_singleElementEqualsSingleCall() public {
        uint256 midA = _market();
        uint256 midB = _market();
        Vm.Wallet memory aUp = _wallet("s_A_up");
        Vm.Wallet memory aDn = _wallet("s_A_dn");
        Vm.Wallet memory bUp = _wallet("s_B_up");
        Vm.Wallet memory bDn = _wallet("s_B_dn");

        UpDownSettlement.Order memory aBuyUp = _order(aUp, midA, UP, BUY, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory aBuyDn = _order(aDn, midA, DOWN, BUY, 4000, 100e18, 0, 2);
        UpDownSettlement.FillInputs memory fA = _inputs(aBuyUp, aUp, aBuyDn, aDn, 100e18, 0, 0);
        vm.prank(relayer);
        s.mintMatch(fA);

        UpDownSettlement.Order memory bBuyUp = _order(bUp, midB, UP, BUY, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory bBuyDn = _order(bDn, midB, DOWN, BUY, 4000, 100e18, 0, 2);
        UpDownSettlement.FillInputs[] memory fs = new UpDownSettlement.FillInputs[](1);
        fs[0] = _inputs(bBuyUp, bUp, bBuyDn, bDn, 100e18, 0, 0);
        vm.prank(relayer);
        s.mintMatchBatch(fs);

        assertEq(s.sharesOf(midA, aUp.addr, UP), s.sharesOf(midB, bUp.addr, UP));
        assertEq(usdt.balanceOf(aUp.addr), usdt.balanceOf(bUp.addr));
        assertEq(usdt.balanceOf(aDn.addr), usdt.balanceOf(bDn.addr));
        assertEq(s.marketRetained(midA), s.marketRetained(midB));
    }

    /// ALL-OR-NOTHING: one bad fill in the middle reverts the whole batch and persists nothing —
    /// the good fills on either side leave no shares, no backing, no order-fill accounting.
    function test_mintMatchBatch_atomicRevertOnOneBadFill() public {
        uint256 mid = _market();
        Vm.Wallet[3] memory ups = [_wallet("bad_up0"), _wallet("bad_up1"), _wallet("bad_up2")];
        Vm.Wallet[3] memory downs = [_wallet("bad_dn0"), _wallet("bad_dn1"), _wallet("bad_dn2")];

        UpDownSettlement.FillInputs[] memory fs = new UpDownSettlement.FillInputs[](3);
        // fills 0 and 2 are valid (60/40); fill 1 does NOT cross (50 + 40 = 90% < 100%).
        for (uint256 i; i < 3; ++i) {
            uint256 upPx = i == 1 ? 5000 : 6000;
            UpDownSettlement.Order memory upBuy = _order(ups[i], mid, UP, BUY, upPx, 100e18, 0, 100 + i);
            UpDownSettlement.Order memory downBuy = _order(downs[i], mid, DOWN, BUY, 4000, 100e18, 0, 200 + i);
            fs[i] = _inputs(upBuy, ups[i], downBuy, downs[i], 100e18, 0, 0);
        }

        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.OrdersNotCrossed.selector);
        s.mintMatchBatch(fs);

        // NOTHING persisted — not even the two valid fills.
        for (uint256 i; i < 3; ++i) {
            assertEq(s.sharesOf(mid, ups[i].addr, UP), 0, "no UP shares after revert");
            assertEq(s.sharesOf(mid, downs[i].addr, DOWN), 0, "no DOWN shares after revert");
            assertEq(usdt.balanceOf(ups[i].addr), 1_000_000e18, "no cash pulled from any buyer");
        }
        assertEq(s.marketRetained(mid), 0, "no backing");
        assertEq(s.optionShares(mid, UP), 0);
        assertEq(usdt.balanceOf(address(s)), 0, "contract balance untouched");
    }

    /// Two partial fills of the SAME taker order inside ONE batch accumulate fills and fees across
    /// the loop — proving the extracted internal shares `orderFills` / `orderFeesPaid` between
    /// iterations exactly as sequential single calls would. First partial fits; the second pushes the
    /// cumulative taker fee over the signed cap → the whole batch reverts.
    function test_mintMatchBatch_cumulativeFeeCapAcrossBatch() public {
        uint256 mid = _market();
        Vm.Wallet memory up = _wallet("cf_up");
        Vm.Wallet memory dn = _wallet("cf_dn");

        // One resting UP maker (200 shares) and one aggressing DOWN taker (200 shares, maxFee 3e18).
        UpDownSettlement.Order memory upBuy = _order(up, mid, UP, BUY, 6000, 200e18, 0, 1);
        UpDownSettlement.Order memory dnBuy = _order(dn, mid, DOWN, BUY, 4000, 200e18, 3e18, 2);

        // Two partials of the same pair, each charging 2e18 fee → cumulative 4e18 > 3e18 cap.
        UpDownSettlement.FillInputs[] memory fs = new UpDownSettlement.FillInputs[](2);
        fs[0] = _inputs(upBuy, up, dnBuy, dn, 100e18, 2e18, 0);
        fs[1] = _inputs(upBuy, up, dnBuy, dn, 100e18, 2e18, 0);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(UpDownSettlement.FeeExceedsTakerCap.selector, 4e18, 3e18));
        s.mintMatchBatch(fs);

        // Atomic: the first partial's fee/fills rolled back too.
        assertEq(s.orderFeesPaid(s.hashOrder(dnBuy)), 0, "no fees persisted after batch revert");
        assertEq(s.sharesOf(mid, up.addr, UP), 0, "no shares persisted");
    }

    /// Two partial fills of the same order pair inside ONE batch sum to the full order amount, and
    /// leave the cumulative on-chain fill state exactly as two sequential singles would.
    function test_mintMatchBatch_partialFillsSumInOneBatch() public {
        uint256 mid = _market();
        Vm.Wallet memory up = _wallet("pf_up");
        Vm.Wallet memory dn = _wallet("pf_dn");
        UpDownSettlement.Order memory upBuy = _order(up, mid, UP, BUY, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory dnBuy = _order(dn, mid, DOWN, BUY, 4000, 100e18, 0, 2);

        UpDownSettlement.FillInputs[] memory fs = new UpDownSettlement.FillInputs[](2);
        fs[0] = _inputs(upBuy, up, dnBuy, dn, 60e18, 0, 0);
        fs[1] = _inputs(upBuy, up, dnBuy, dn, 40e18, 0, 0);

        vm.prank(relayer);
        s.mintMatchBatch(fs);

        assertEq(s.sharesOf(mid, up.addr, UP), 100e18, "two partials in one batch sum to the order");
        assertEq(s.sharesOf(mid, dn.addr, DOWN), 100e18);
        assertEq(s.orderFills(s.hashOrder(upBuy)), 100e18, "order fully consumed");
        assertEq(s.marketRetained(mid), 100e18);
    }

    /// A third partial in the same batch that overflows the signed order amount reverts everything.
    function test_mintMatchBatch_overfillInBatch_reverts() public {
        uint256 mid = _market();
        Vm.Wallet memory up = _wallet("of_up");
        Vm.Wallet memory dn = _wallet("of_dn");
        UpDownSettlement.Order memory upBuy = _order(up, mid, UP, BUY, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory dnBuy = _order(dn, mid, DOWN, BUY, 4000, 100e18, 0, 2);

        UpDownSettlement.FillInputs[] memory fs = new UpDownSettlement.FillInputs[](3);
        fs[0] = _inputs(upBuy, up, dnBuy, dn, 60e18, 0, 0);
        fs[1] = _inputs(upBuy, up, dnBuy, dn, 40e18, 0, 0);
        fs[2] = _inputs(upBuy, up, dnBuy, dn, 1e18, 0, 0); // 101e18 > 100e18 signed

        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.FillExceedsOrderAmount.selector);
        s.mintMatchBatch(fs);
        assertEq(s.sharesOf(mid, up.addr, UP), 0, "overflow reverted the whole batch");
    }

    function test_mintMatchBatch_onlyRelayer() public {
        uint256 mid = _market();
        Vm.Wallet memory up = _wallet("or_up");
        Vm.Wallet memory dn = _wallet("or_dn");
        UpDownSettlement.Order memory upBuy = _order(up, mid, UP, BUY, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory dnBuy = _order(dn, mid, DOWN, BUY, 4000, 100e18, 0, 2);
        UpDownSettlement.FillInputs[] memory fs = new UpDownSettlement.FillInputs[](1);
        fs[0] = _inputs(upBuy, up, dnBuy, dn, 100e18, 0, 0);
        vm.expectRevert(UpDownSettlement.OnlyRelayer.selector);
        s.mintMatchBatch(fs); // not pranked as relayer
    }

    function test_mintMatchBatch_whenPaused_reverts() public {
        uint256 mid = _market();
        Vm.Wallet memory up = _wallet("pz_up");
        Vm.Wallet memory dn = _wallet("pz_dn");
        UpDownSettlement.Order memory upBuy = _order(up, mid, UP, BUY, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory dnBuy = _order(dn, mid, DOWN, BUY, 4000, 100e18, 0, 2);
        UpDownSettlement.FillInputs[] memory fs = new UpDownSettlement.FillInputs[](1);
        fs[0] = _inputs(upBuy, up, dnBuy, dn, 100e18, 0, 0);
        s.setPaused(true);
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.Paused.selector);
        s.mintMatchBatch(fs);
    }

    /// A fill against an ended market reverts the batch (the window check lives in the internal
    /// helper). Orders are given an expiry beyond `endTime` so the market-window check — not the
    /// order-expiry check — is what fires.
    function test_mintMatchBatch_afterEndTime_reverts() public {
        uint256 mid = _market();
        Vm.Wallet memory up = _wallet("et_up");
        Vm.Wallet memory dn = _wallet("et_dn");
        UpDownSettlement.Market memory m = s.getMarket(mid);
        UpDownSettlement.Order memory upBuy = _order(up, mid, UP, BUY, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory dnBuy = _order(dn, mid, DOWN, BUY, 4000, 100e18, 0, 2);
        upBuy.expiry = uint256(m.endTime) + 1000;
        dnBuy.expiry = uint256(m.endTime) + 1000;
        UpDownSettlement.FillInputs[] memory fs = new UpDownSettlement.FillInputs[](1);
        fs[0] = _inputs(upBuy, up, dnBuy, dn, 100e18, 0, 0);

        vm.warp(uint256(m.endTime) + 1);
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.MarketNotOpen.selector);
        s.mintMatchBatch(fs);
    }

    /// An empty batch is a no-op (the guards still run, but the loop body never executes).
    function test_mintMatchBatch_emptyArray_noop() public {
        UpDownSettlement.FillInputs[] memory fs = new UpDownSettlement.FillInputs[](0);
        vm.prank(relayer);
        s.mintMatchBatch(fs); // must not revert
        assertEq(usdt.balanceOf(address(s)), 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    //                        ENTER POSITION — BATCH
    // ─────────────────────────────────────────────────────────────────────

    /// Two same-option BUY/SELL fills settle atomically in one `enterPositionBatch`. Each seller
    /// holds a minted set; the buyer takes the seller's UP shares and pays cash peer-to-peer.
    function test_enterPositionBatch_aggregatesTwoFills() public {
        uint256 mid = _market();
        Vm.Wallet[2] memory sellers = [_wallet("ep_s0"), _wallet("ep_s1")];
        Vm.Wallet[2] memory buyers = [_wallet("ep_b0"), _wallet("ep_b1")];

        UpDownSettlement.FillInputs[] memory fs = new UpDownSettlement.FillInputs[](2);
        for (uint256 i; i < 2; ++i) {
            _mintSet(sellers[i], mid, 100e18); // seller holds UP + DOWN
            UpDownSettlement.Order memory makerSell = _order(sellers[i], mid, UP, SELL, 6000, 100e18, 0, 100 + i);
            UpDownSettlement.Order memory takerBuy = _order(buyers[i], mid, UP, BUY, 6000, 100e18, 5e18, 200 + i);
            fs[i] = _inputs(makerSell, sellers[i], takerBuy, buyers[i], 100e18, 2e18, 1e18);
        }

        uint256 treasury0 = usdt.balanceOf(treasury);
        vm.prank(relayer);
        s.enterPositionBatch(fs);

        for (uint256 i; i < 2; ++i) {
            assertEq(s.sharesOf(mid, buyers[i].addr, UP), 100e18, "buyer took UP shares");
            assertEq(s.sharesOf(mid, sellers[i].addr, UP), 0, "seller's UP transferred out");
            // buyer paid 60 cash + 3 fees (2 platform + 1 maker); taker (=buyer here) pays fees.
            assertEq(usdt.balanceOf(buyers[i].addr), 1_000_000e18 - 60e18 - 3e18, "buyer paid cash + fees");
        }
        assertEq(usdt.balanceOf(treasury), treasury0 + 4e18, "treasury got 2 fills' platformFee");
        // enterPosition moves shares peer-to-peer; backing is only the two minted sets.
        assertEq(s.marketRetained(mid), 200e18, "backing unchanged by transfers");
    }

    /// ALL-OR-NOTHING for enterPositionBatch: a non-crossing fill reverts the whole batch.
    function test_enterPositionBatch_atomicRevert() public {
        uint256 mid = _market();
        Vm.Wallet memory seller = _wallet("epr_s");
        Vm.Wallet memory buyer0 = _wallet("epr_b0");
        Vm.Wallet memory buyer1 = _wallet("epr_b1");
        _mintSet(seller, mid, 200e18);

        UpDownSettlement.FillInputs[] memory fs = new UpDownSettlement.FillInputs[](2);
        // fill 0 valid (ask 60, bid 60); fill 1 does NOT cross (ask 70 > bid 60).
        UpDownSettlement.Order memory sell0 = _order(seller, mid, UP, SELL, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory buy0 = _order(buyer0, mid, UP, BUY, 6000, 100e18, 5e18, 2);
        fs[0] = _inputs(sell0, seller, buy0, buyer0, 100e18, 0, 0);
        UpDownSettlement.Order memory sell1 = _order(seller, mid, UP, SELL, 7000, 100e18, 0, 3);
        UpDownSettlement.Order memory buy1 = _order(buyer1, mid, UP, BUY, 6000, 100e18, 5e18, 4);
        fs[1] = _inputs(sell1, seller, buy1, buyer1, 100e18, 0, 0);

        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.OrdersNotCrossed.selector);
        s.enterPositionBatch(fs);

        assertEq(s.sharesOf(mid, buyer0.addr, UP), 0, "valid fill 0 rolled back with the batch");
        assertEq(s.sharesOf(mid, seller.addr, UP), 200e18, "seller kept all shares");
    }

    function test_enterPositionBatch_onlyRelayer() public {
        uint256 mid = _market();
        Vm.Wallet memory seller = _wallet("epor_s");
        Vm.Wallet memory buyer = _wallet("epor_b");
        _mintSet(seller, mid, 100e18);
        UpDownSettlement.Order memory makerSell = _order(seller, mid, UP, SELL, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory takerBuy = _order(buyer, mid, UP, BUY, 6000, 100e18, 5e18, 2);
        UpDownSettlement.FillInputs[] memory fs = new UpDownSettlement.FillInputs[](1);
        fs[0] = _inputs(makerSell, seller, takerBuy, buyer, 100e18, 0, 0);
        vm.expectRevert(UpDownSettlement.OnlyRelayer.selector);
        s.enterPositionBatch(fs); // not pranked as relayer
    }

    function test_enterPositionBatch_whenPaused_reverts() public {
        uint256 mid = _market();
        Vm.Wallet memory seller = _wallet("eppz_s");
        Vm.Wallet memory buyer = _wallet("eppz_b");
        _mintSet(seller, mid, 100e18);
        UpDownSettlement.Order memory makerSell = _order(seller, mid, UP, SELL, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory takerBuy = _order(buyer, mid, UP, BUY, 6000, 100e18, 5e18, 2);
        UpDownSettlement.FillInputs[] memory fs = new UpDownSettlement.FillInputs[](1);
        fs[0] = _inputs(makerSell, seller, takerBuy, buyer, 100e18, 0, 0);
        s.setPaused(true);
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.Paused.selector);
        s.enterPositionBatch(fs);
    }

    // ─────────────────────────────────────────────────────────────────────
    //                          MERGE MATCH — BATCH
    // ─────────────────────────────────────────────────────────────────────

    /// Two complementary SELL/SELL fills burn two sets atomically in one `mergeMatchBatch`.
    function test_mergeMatchBatch_aggregatesTwoFills() public {
        uint256 mid = _market();
        Vm.Wallet[2] memory upSellers = [_wallet("mg_u0"), _wallet("mg_u1")];
        Vm.Wallet[2] memory dnSellers = [_wallet("mg_d0"), _wallet("mg_d1")];

        UpDownSettlement.FillInputs[] memory fs = new UpDownSettlement.FillInputs[](2);
        for (uint256 i; i < 2; ++i) {
            _mintSet(upSellers[i], mid, 100e18);
            _mintSet(dnSellers[i], mid, 100e18);
            UpDownSettlement.Order memory upSell = _order(upSellers[i], mid, UP, SELL, 6000, 100e18, 0, 100 + i);
            UpDownSettlement.Order memory dnSell = _order(dnSellers[i], mid, DOWN, SELL, 3000, 100e18, 0, 200 + i);
            fs[i] = _inputs(upSell, upSellers[i], dnSell, dnSellers[i], 100e18, 0, 0);
        }
        // 4 sets minted (2 per fill counterparties) → 400e18 backing before merge.
        assertEq(usdt.balanceOf(address(s)), 400e18);

        vm.prank(relayer);
        s.mergeMatchBatch(fs);

        for (uint256 i; i < 2; ++i) {
            assertEq(s.sharesOf(mid, upSellers[i].addr, UP), 0, "UP seller burned UP");
            assertEq(s.sharesOf(mid, dnSellers[i].addr, DOWN), 0, "DOWN seller burned DOWN");
            assertEq(usdt.balanceOf(upSellers[i].addr), 1_000_000e18 - 100e18 + 60e18, "UP seller net -40");
            assertEq(usdt.balanceOf(dnSellers[i].addr), 1_000_000e18 - 100e18 + 40e18, "DOWN seller net -60");
        }
        // Each merge released one set (100e18); 2 sets burned → 200e18 released, 200e18 remains.
        assertEq(s.marketRetained(mid), 200e18, "two sets released");
        assertEq(usdt.balanceOf(address(s)), 200e18, "conservation across the batch burn");
    }

    /// ALL-OR-NOTHING for mergeMatchBatch: a seller short of shares reverts the whole batch.
    function test_mergeMatchBatch_atomicRevert() public {
        uint256 mid = _market();
        Vm.Wallet memory u0 = _wallet("mgr_u0");
        Vm.Wallet memory d0 = _wallet("mgr_d0");
        Vm.Wallet memory u1 = _wallet("mgr_u1");
        Vm.Wallet memory d1 = _wallet("mgr_d1");
        // Fund fill 0 fully; fill 1's DOWN seller holds NOTHING → InsufficientShares on fill 1.
        _mintSet(u0, mid, 100e18);
        _mintSet(d0, mid, 100e18);
        _mintSet(u1, mid, 100e18);

        UpDownSettlement.FillInputs[] memory fs = new UpDownSettlement.FillInputs[](2);
        UpDownSettlement.Order memory upSell0 = _order(u0, mid, UP, SELL, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory dnSell0 = _order(d0, mid, DOWN, SELL, 3000, 100e18, 0, 2);
        fs[0] = _inputs(upSell0, u0, dnSell0, d0, 100e18, 0, 0);
        UpDownSettlement.Order memory upSell1 = _order(u1, mid, UP, SELL, 6000, 100e18, 0, 3);
        UpDownSettlement.Order memory dnSell1 = _order(d1, mid, DOWN, SELL, 3000, 100e18, 0, 4);
        fs[1] = _inputs(upSell1, u1, dnSell1, d1, 100e18, 0, 0);

        uint256 sBal0 = usdt.balanceOf(address(s));
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(UpDownSettlement.InsufficientShares.selector, mid, DOWN, 100e18, 0));
        s.mergeMatchBatch(fs);

        assertEq(s.sharesOf(mid, u0.addr, UP), 100e18, "valid fill 0's UP seller unchanged");
        assertEq(usdt.balanceOf(address(s)), sBal0, "no backing released");
    }

    function test_mergeMatchBatch_onlyRelayer() public {
        uint256 mid = _market();
        Vm.Wallet memory upSeller = _wallet("mgor_u");
        Vm.Wallet memory dnSeller = _wallet("mgor_d");
        _mintSet(upSeller, mid, 100e18);
        _mintSet(dnSeller, mid, 100e18);
        UpDownSettlement.Order memory upSell = _order(upSeller, mid, UP, SELL, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory dnSell = _order(dnSeller, mid, DOWN, SELL, 3000, 100e18, 0, 2);
        UpDownSettlement.FillInputs[] memory fs = new UpDownSettlement.FillInputs[](1);
        fs[0] = _inputs(upSell, upSeller, dnSell, dnSeller, 100e18, 0, 0);
        vm.expectRevert(UpDownSettlement.OnlyRelayer.selector);
        s.mergeMatchBatch(fs); // not pranked as relayer
    }

    function test_mergeMatchBatch_whenPaused_reverts() public {
        uint256 mid = _market();
        Vm.Wallet memory upSeller = _wallet("mgpz_u");
        Vm.Wallet memory dnSeller = _wallet("mgpz_d");
        _mintSet(upSeller, mid, 100e18);
        _mintSet(dnSeller, mid, 100e18);
        UpDownSettlement.Order memory upSell = _order(upSeller, mid, UP, SELL, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory dnSell = _order(dnSeller, mid, DOWN, SELL, 3000, 100e18, 0, 2);
        UpDownSettlement.FillInputs[] memory fs = new UpDownSettlement.FillInputs[](1);
        fs[0] = _inputs(upSell, upSeller, dnSell, dnSeller, 100e18, 0, 0);
        s.setPaused(true);
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.Paused.selector);
        s.mergeMatchBatch(fs);
    }

    // ─────────────────────────────────────────────────────────────────────
    //                               GAS
    // ─────────────────────────────────────────────────────────────────────

    /// The throughput lever: a batch of N mint fills settles for LESS in-EVM gas than N single calls.
    /// The measurable in-EVM saving is the per-call overhead paid once instead of N times — the guard
    /// modifiers (`nonReentrant` storage writes, `onlyRelayer`/`whenNotPaused` reads) and function
    /// dispatch. The dominant REAL-WORLD saving — the 21,000 intrinsic gas + calldata base charged
    /// per transaction, i.e. per-fill under the single path — is NOT captured by an in-EVM `gasleft()`
    /// measurement (it's a per-tx charge outside the call), so this test's delta is a conservative
    /// floor; on-chain the batch wins by far more.
    function test_gas_mintMatchBatchBeatsSingles() public {
        uint256 n = 5;

        // Path 1 — N singles on market A.
        uint256 midA = _market();
        uint256 singlesGas;
        for (uint256 i; i < n; ++i) {
            Vm.Wallet memory up = _wallet(string.concat("g_A_up", vm.toString(i)));
            Vm.Wallet memory dn = _wallet(string.concat("g_A_dn", vm.toString(i)));
            UpDownSettlement.Order memory upBuy = _order(up, midA, UP, BUY, 6000, 100e18, 0, 1);
            UpDownSettlement.Order memory dnBuy = _order(dn, midA, DOWN, BUY, 4000, 100e18, 0, 2);
            UpDownSettlement.FillInputs memory f = _inputs(upBuy, up, dnBuy, dn, 100e18, 0, 0);
            vm.prank(relayer);
            uint256 g0 = gasleft();
            s.mintMatch(f);
            singlesGas += g0 - gasleft();
        }

        // Path 2 — one batch of N on market B.
        uint256 midB = _market();
        UpDownSettlement.FillInputs[] memory fs = new UpDownSettlement.FillInputs[](n);
        for (uint256 i; i < n; ++i) {
            Vm.Wallet memory up = _wallet(string.concat("g_B_up", vm.toString(i)));
            Vm.Wallet memory dn = _wallet(string.concat("g_B_dn", vm.toString(i)));
            UpDownSettlement.Order memory upBuy = _order(up, midB, UP, BUY, 6000, 100e18, 0, 1);
            UpDownSettlement.Order memory dnBuy = _order(dn, midB, DOWN, BUY, 4000, 100e18, 0, 2);
            fs[i] = _inputs(upBuy, up, dnBuy, dn, 100e18, 0, 0);
        }
        vm.prank(relayer);
        uint256 gb = gasleft();
        s.mintMatchBatch(fs);
        uint256 batchGas = gb - gasleft();

        emit log_named_uint("singles gas (in-EVM, 5 calls)", singlesGas);
        emit log_named_uint("batch gas   (in-EVM, 1 call)", batchGas);
        assertLt(batchGas, singlesGas, "batch settles N fills for less in-EVM gas than N singles");
    }
}
