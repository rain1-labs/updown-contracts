// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {UpDownSettlement} from "../src/UpDownSettlement.sol";

/// @title Remediation V2 proof suite (Hacken full-recommendation pass).
/// @notice One test (or small cluster) per `Needs-decision` finding, proving the auditor's
///         recommended fix under the new non-custodial ABI. See REMEDIATION_V2.md.
contract RemediationV2Test is Test {
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

    Vm.Wallet internal alice;
    Vm.Wallet internal bob;
    Vm.Wallet internal carol;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdt = new ERC20Mock();
        s = new UpDownSettlement(usdt, owner);
        s.setAutocycler(autocycler);
        s.setResolver(resolver);
        s.setRelayer(relayer);
        s.setTreasury(treasury);
        s.setRebateBudget(1_000e18, 7 days);

        alice = _wallet("alice");
        bob = _wallet("bob");
        carol = _wallet("carol");
    }

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

    function _order(Vm.Wallet memory w, uint256 mid, uint8 option, uint8 side, uint256 price, uint256 amount, uint256 maxFee, uint256 nonce)
        internal
        view
        returns (UpDownSettlement.Order memory o)
    {
        o = UpDownSettlement.Order({
            maker: w.addr, market: mid, option: option, side: side, orderType: 0,
            price: price, amount: amount, maxFee: maxFee, nonce: nonce, expiry: block.timestamp + 3600
        });
    }

    function _sign(Vm.Wallet memory w, UpDownSettlement.Order memory o) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(w.privateKey, s.orderDigest(o));
        return abi.encodePacked(r, ss, v);
    }

    function _mintAuth(Vm.Wallet memory w, uint256 mid, uint8 action, uint256 amount, uint256 nonce)
        internal
        view
        returns (UpDownSettlement.MintAuth memory a)
    {
        a = UpDownSettlement.MintAuth({account: w.addr, market: mid, action: action, amount: amount, nonce: nonce, expiry: block.timestamp + 3600});
    }

    function _signAuth(Vm.Wallet memory w, UpDownSettlement.MintAuth memory a) internal returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", s.DOMAIN_SEPARATOR(), s.hashMintAuth(a)));
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(w.privateKey, digest);
        return abi.encodePacked(r, ss, v);
    }

    // ─────────────────────────────────────────────────────────────────────
    // F-17772 / 17777: per-user on-chain share accounting + user authorization
    // ─────────────────────────────────────────────────────────────────────

    function test_F17772_selfMint_recordsPerUserShares() public {
        uint256 mid = _market();
        vm.prank(alice.addr);
        s.mint(mid, 100e18);

        assertEq(s.sharesOf(mid, alice.addr, UP), 100e18, "UP shares recorded");
        assertEq(s.sharesOf(mid, alice.addr, DOWN), 100e18, "DOWN shares recorded");
        assertEq(s.optionShares(mid, UP), 100e18);
        assertEq(s.optionShares(mid, DOWN), 100e18);
        assertEq(s.marketRetained(mid), 100e18);
        assertEq(usdt.balanceOf(address(s)), 100e18);
    }

    function test_F17772_relayerMint_requiresSignedAuth() public {
        uint256 mid = _market();
        UpDownSettlement.MintAuth memory a = _mintAuth(alice, mid, 1, 100e18, 1);
        bytes memory sig = _signAuth(alice, a);

        vm.prank(relayer);
        s.complementaryMint(mid, 100e18, alice.addr, a, sig);
        assertEq(s.sharesOf(mid, alice.addr, UP), 100e18);

        // Replay the same nonce → reverts.
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(UpDownSettlement.MintAuthNonceUsed.selector, alice.addr, 1));
        s.complementaryMint(mid, 100e18, alice.addr, a, sig);
    }

    function test_F17772_relayerMint_rejectsWrongSigner() public {
        uint256 mid = _market();
        // Auth says account = alice, but signed by bob.
        UpDownSettlement.MintAuth memory a = _mintAuth(alice, mid, 1, 100e18, 7);
        bytes memory badSig = _signAuth(bob, a);
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.InvalidMintAuth.selector);
        s.complementaryMint(mid, 100e18, alice.addr, a, badSig);
    }

    // ─────────────────────────────────────────────────────────────────────
    // F-17756 (taker pays) + F-17757 (taker consent) + F-17731 (fee cap)
    // ─────────────────────────────────────────────────────────────────────

    /// Direction 1: maker is the SELLER, taker is the BUYER. Taker pays fees.
    function test_F17756_takerPaysFees_makerIsSeller() public {
        uint256 mid = _market();
        vm.prank(alice.addr);
        s.mint(mid, 100e18); // alice holds UP+DOWN

        UpDownSettlement.Order memory makerO = _order(alice, mid, UP, SELL, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory takerO = _order(bob, mid, UP, BUY, 6000, 100e18, 5e18, 2);

        uint256 treasury0 = usdt.balanceOf(treasury);
        uint256 alice0 = usdt.balanceOf(alice.addr);
        uint256 bob0 = usdt.balanceOf(bob.addr);

        _enter(makerO, alice, takerO, bob, 100e18, 2e18, 1e18);

        // Shares transferred seller→buyer.
        assertEq(s.sharesOf(mid, bob.addr, UP), 100e18, "buyer got UP");
        assertEq(s.sharesOf(mid, alice.addr, UP), 0, "seller gave up UP");
        // cashPart = 60% * 100 = 60; buyer(bob) pays cash + fees (taker pays).
        assertEq(usdt.balanceOf(bob.addr), bob0 - 60e18 - 3e18, "taker(buyer) paid cash + all fees");
        assertEq(usdt.balanceOf(treasury), treasury0 + 2e18, "treasury got platformFee");
        assertEq(usdt.balanceOf(alice.addr), alice0 + 60e18 + 1e18, "maker got cash + makerFee, no fee charged");
        // Contract balance unchanged by the fill (peer-to-peer; pool untouched).
        assertEq(usdt.balanceOf(address(s)), 100e18, "fill is balance-neutral for the pool");
    }

    /// Direction 2: maker is the BUYER, taker is the SELLER. Taker STILL pays fees
    /// (this is the exact case the V1 code charged to the wrong party — F-17756).
    function test_F17756_takerPaysFees_makerIsBuyer() public {
        uint256 mid = _market();
        vm.prank(carol.addr);
        s.mint(mid, 100e18); // carol (the taker/seller) holds the UP shares

        UpDownSettlement.Order memory makerO = _order(alice, mid, UP, BUY, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory takerO = _order(carol, mid, UP, SELL, 6000, 100e18, 5e18, 2);

        uint256 treasury0 = usdt.balanceOf(treasury);
        uint256 carol0 = usdt.balanceOf(carol.addr);

        _enter(makerO, alice, takerO, carol, 100e18, 2e18, 1e18);

        assertEq(s.sharesOf(mid, alice.addr, UP), 100e18, "maker(buyer) got UP");
        assertEq(s.sharesOf(mid, carol.addr, UP), 0, "taker(seller) gave up UP");
        // carol is the SELLER but the TAKER → she pays the fees, receives cash.
        // net = +cash(60) - fees(3) = +57
        assertEq(usdt.balanceOf(carol.addr), carol0 + 60e18 - 3e18, "taker(seller) paid fees despite being the seller");
        assertEq(usdt.balanceOf(treasury), treasury0 + 2e18);
    }

    function test_F17757_invalidTakerSignature_reverts() public {
        uint256 mid = _market();
        vm.prank(alice.addr);
        s.mint(mid, 100e18);

        UpDownSettlement.Order memory makerO = _order(alice, mid, UP, SELL, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory takerO = _order(bob, mid, UP, BUY, 6000, 100e18, 5e18, 2);

        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            makerOrder: makerO,
            makerSignature: _sign(alice, makerO),
            takerOrder: takerO,
            takerSignature: _sign(carol, takerO), // signed by carol, not bob → invalid
            fillAmount: 100e18,
            platformFee: 0,
            makerFee: 0
        });
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.InvalidSignature.selector);
        s.enterPosition(f);
    }

    function test_F17731_feeCap_enforced() public {
        uint256 mid = _market();
        vm.prank(alice.addr);
        s.mint(mid, 100e18);

        // taker signs maxFee = 2e18; relayer tries to charge 3e18 total.
        UpDownSettlement.Order memory makerO = _order(alice, mid, UP, SELL, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory takerO = _order(bob, mid, UP, BUY, 6000, 100e18, 2e18, 2);

        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            makerOrder: makerO,
            makerSignature: _sign(alice, makerO),
            takerOrder: takerO,
            takerSignature: _sign(bob, takerO),
            fillAmount: 100e18,
            platformFee: 2e18,
            makerFee: 1e18 // total 3e18 > 2e18 cap
        });
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(UpDownSettlement.FeeExceedsTakerCap.selector, 3e18, 2e18));
        s.enterPosition(f);
    }

    /// F-2026-17731 (cumulative): `maxFee` is the TOTAL cap across every partial fill of a taker
    /// order — a relayer cannot split one order into N fills and charge `maxFee` on each (which the
    /// per-fill-only check previously allowed, draining the taker far beyond the signed cap).
    function test_F17731_feeCap_cumulativeAcrossPartialFills() public {
        uint256 mid = _market();
        vm.prank(carol.addr);
        s.mint(mid, 100e18); // carol holds 100 UP + 100 DOWN; she is the resting seller

        // One taker order: bob BUYs 100 UP, signing a TOTAL fee cap of 5e18.
        UpDownSettlement.Order memory takerO = _order(bob, mid, UP, BUY, 6000, 100e18, 5e18, 100);
        uint256 treasury0 = usdt.balanceOf(treasury);

        // Fill #1: 20 shares, charging the whole 5e18 cap. Cumulative 0 -> 5e18 == cap → OK.
        UpDownSettlement.Order memory m1 = _order(carol, mid, UP, SELL, 6000, 20e18, 0, 201);
        _enter(m1, carol, takerO, bob, 20e18, 5e18, 0);
        assertEq(usdt.balanceOf(treasury), treasury0 + 5e18, "first fill consumed the whole cap");
        assertEq(s.orderFeesPaid(s.hashOrder(takerO)), 5e18, "cumulative taker fees recorded");

        // Fill #2 against the SAME taker order: ANY extra fee now exceeds the cumulative cap → revert.
        UpDownSettlement.Order memory m2 = _order(carol, mid, UP, SELL, 6000, 20e18, 0, 202);
        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            makerOrder: m2, makerSignature: _sign(carol, m2),
            takerOrder: takerO, takerSignature: _sign(bob, takerO),
            fillAmount: 20e18, platformFee: 1, makerFee: 0
        });
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(UpDownSettlement.FeeExceedsTakerCap.selector, 5e18 + 1, 5e18));
        s.enterPosition(f);

        // A further zero-fee partial fill of the same order still works (within cap, nothing added).
        UpDownSettlement.FillInputs memory f0 = UpDownSettlement.FillInputs({
            makerOrder: m2, makerSignature: _sign(carol, m2),
            takerOrder: takerO, takerSignature: _sign(bob, takerO),
            fillAmount: 20e18, platformFee: 0, makerFee: 0
        });
        vm.prank(relayer);
        s.enterPosition(f0);
        assertEq(usdt.balanceOf(treasury), treasury0 + 5e18, "no fees beyond the signed cap were ever pulled");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Two-sided fill: order-binding consistency (the dual-order match must reject
    // mismatched/uncrossed/unsigned pairs before any funds or shares move). These guards
    // are what makes the F-17756/17757/17739 redesign safe.
    // ─────────────────────────────────────────────────────────────────────

    function _fill(
        UpDownSettlement.Order memory makerO,
        Vm.Wallet memory makerW,
        UpDownSettlement.Order memory takerO,
        Vm.Wallet memory takerW
    ) internal returns (UpDownSettlement.FillInputs memory f) {
        f = UpDownSettlement.FillInputs({
            makerOrder: makerO,
            makerSignature: _sign(makerW, makerO),
            takerOrder: takerO,
            takerSignature: _sign(takerW, takerO),
            fillAmount: 100e18,
            platformFee: 0,
            makerFee: 0
        });
    }

    /// The two signed orders must reference the SAME market (checked before any signature/share work).
    function test_orderBinding_marketMismatch_reverts() public {
        uint256 mid = _market();
        UpDownSettlement.Order memory makerO = _order(alice, mid, UP, SELL, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory takerO = _order(bob, mid + 1, UP, BUY, 6000, 100e18, 5e18, 2);
        UpDownSettlement.FillInputs memory f = _fill(makerO, alice, takerO, bob);
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.MarketMismatch.selector);
        s.enterPosition(f);
    }

    /// The two signed orders must reference the SAME option.
    function test_orderBinding_optionMismatch_reverts() public {
        uint256 mid = _market();
        UpDownSettlement.Order memory makerO = _order(alice, mid, UP, SELL, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory takerO = _order(bob, mid, DOWN, BUY, 6000, 100e18, 5e18, 2);
        UpDownSettlement.FillInputs memory f = _fill(makerO, alice, takerO, bob);
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.OptionMismatch.selector);
        s.enterPosition(f);
    }

    /// A fill must pair one BUY with one SELL — two same-side orders cannot be matched.
    function test_orderBinding_sameSide_reverts() public {
        uint256 mid = _market();
        UpDownSettlement.Order memory makerO = _order(alice, mid, UP, BUY, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory takerO = _order(bob, mid, UP, BUY, 6000, 100e18, 5e18, 2);
        UpDownSettlement.FillInputs memory f = _fill(makerO, alice, takerO, bob);
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.NotBuySellPair.selector);
        s.enterPosition(f);
    }

    /// Prices must cross: a buy below the resting ask cannot be filled.
    function test_orderBinding_ordersNotCrossed_reverts() public {
        uint256 mid = _market();
        UpDownSettlement.Order memory makerO = _order(alice, mid, UP, SELL, 7000, 100e18, 0, 1); // ask 70%
        UpDownSettlement.Order memory takerO = _order(bob, mid, UP, BUY, 6000, 100e18, 5e18, 2); // bid 60%
        UpDownSettlement.FillInputs memory f = _fill(makerO, alice, takerO, bob);
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.OrdersNotCrossed.selector);
        s.enterPosition(f);
    }

    /// The maker side must carry a valid signature (complements the existing taker-signature test).
    function test_orderBinding_invalidMakerSignature_reverts() public {
        uint256 mid = _market();
        UpDownSettlement.Order memory makerO = _order(alice, mid, UP, SELL, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory takerO = _order(bob, mid, UP, BUY, 6000, 100e18, 5e18, 2);
        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            makerOrder: makerO,
            makerSignature: _sign(bob, makerO), // signed by bob, not alice → invalid maker sig
            takerOrder: takerO,
            takerSignature: _sign(bob, takerO),
            fillAmount: 100e18,
            platformFee: 0,
            makerFee: 0
        });
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.InvalidSignature.selector);
        s.enterPosition(f);
    }

    // ─────────────────────────────────────────────────────────────────────
    // F-17771 (no backing reuse) + F-17776 (backing can't be pulled from a live position)
    // ─────────────────────────────────────────────────────────────────────

    function test_F17771_sellerWithoutShares_cannotSell() public {
        uint256 mid = _market();
        // alice never minted → holds 0 UP. A "naked" sell must revert.
        UpDownSettlement.Order memory makerO = _order(alice, mid, UP, SELL, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory takerO = _order(bob, mid, UP, BUY, 6000, 100e18, 5e18, 2);

        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            makerOrder: makerO,
            makerSignature: _sign(alice, makerO),
            takerOrder: takerO,
            takerSignature: _sign(bob, takerO),
            fillAmount: 100e18,
            platformFee: 0,
            makerFee: 0
        });
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(UpDownSettlement.InsufficientShares.selector, mid, UP, 100e18, 0));
        s.enterPosition(f);
    }

    function test_F17771_backingNotReusableAcrossFills() public {
        uint256 mid = _market();
        vm.prank(alice.addr);
        s.mint(mid, 100e18); // alice holds 100 UP

        // First fill consumes all 100 UP → bob.
        UpDownSettlement.Order memory m1 = _order(alice, mid, UP, SELL, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory t1 = _order(bob, mid, UP, BUY, 6000, 100e18, 0, 2);
        _enter(m1, alice, t1, bob, 100e18, 0, 0);

        // Second fill: alice now holds 0 UP. The same backing can NOT satisfy another fill.
        UpDownSettlement.Order memory m2 = _order(alice, mid, UP, SELL, 6000, 100e18, 0, 3);
        UpDownSettlement.Order memory t2 = _order(carol, mid, UP, BUY, 6000, 100e18, 0, 4);
        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            makerOrder: m2, makerSignature: _sign(alice, m2),
            takerOrder: t2, takerSignature: _sign(carol, t2),
            fillAmount: 100e18, platformFee: 0, makerFee: 0
        });
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(UpDownSettlement.InsufficientShares.selector, mid, UP, 100e18, 0));
        s.enterPosition(f);
    }

    function test_F17776_cannotBurnBackingUnderLivePosition() public {
        uint256 mid = _market();
        vm.prank(alice.addr);
        s.mint(mid, 100e18); // alice holds UP+DOWN

        // alice sells her UP to bob; she now holds 0 UP, 100 DOWN (incomplete set).
        UpDownSettlement.Order memory m1 = _order(alice, mid, UP, SELL, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory t1 = _order(bob, mid, UP, BUY, 6000, 100e18, 0, 2);
        _enter(m1, alice, t1, bob, 100e18, 0, 0);

        // alice can no longer burn the "set" — she doesn't hold a complete set anymore.
        // This is exactly the V1 attack (withdraw backing under bob's live UP position): now impossible.
        vm.prank(alice.addr);
        vm.expectRevert(abi.encodeWithSelector(UpDownSettlement.InsufficientShares.selector, mid, UP, 100e18, 0));
        s.burn(mid, 100e18);

        // bob's winning backing is intact.
        assertEq(s.marketRetained(mid), 100e18, "backing under bob's position is preserved");
    }

    // ─────────────────────────────────────────────────────────────────────
    // F-17778: trustless redemption (and withdrawSettlement removed)
    // ─────────────────────────────────────────────────────────────────────

    function test_F17778_redeem_trustless() public {
        uint256 mid = _market();
        vm.prank(alice.addr);
        s.mint(mid, 100e18); // alice holds UP+DOWN

        _resolve(mid, UP);

        uint256 alice0 = usdt.balanceOf(alice.addr);
        vm.prank(alice.addr);
        uint256 payout = s.redeem(mid);
        assertEq(payout, 100e18, "winner redeems 1:1");
        assertEq(usdt.balanceOf(alice.addr), alice0 + 100e18);
        assertEq(s.marketRetained(mid), 0, "pool drained by redemption");
        assertEq(usdt.balanceOf(address(s)), 0);

        // Second redeem is a no-op revert (nothing left).
        vm.prank(alice.addr);
        vm.expectRevert(UpDownSettlement.NothingToRedeem.selector);
        s.redeem(mid);
    }

    function test_F17778_redeemFor_paysHolderNotCaller() public {
        uint256 mid = _market();
        vm.prank(alice.addr);
        s.mint(mid, 100e18);
        _resolve(mid, UP);

        uint256 alice0 = usdt.balanceOf(alice.addr);
        uint256 relayer0 = usdt.balanceOf(relayer);
        address[] memory holders = new address[](1);
        holders[0] = alice.addr;

        // Anyone can trigger; funds go to the holder, never the caller.
        vm.prank(relayer);
        s.redeemFor(mid, holders);
        assertEq(usdt.balanceOf(alice.addr), alice0 + 100e18, "holder paid");
        assertEq(usdt.balanceOf(relayer), relayer0, "caller (relayer) received nothing");
    }

    function test_F17778_loserCannotRedeem() public {
        uint256 mid = _market();
        vm.prank(bob.addr);
        s.mint(mid, 100e18); // bob holds UP+DOWN
        // bob sells his UP to alice; bob keeps DOWN.
        UpDownSettlement.Order memory m1 = _order(bob, mid, UP, SELL, 5000, 100e18, 0, 1);
        UpDownSettlement.Order memory t1 = _order(alice, mid, UP, BUY, 5000, 100e18, 0, 2);
        _enter(m1, bob, t1, alice, 100e18, 0, 0);

        _resolve(mid, UP); // UP wins → alice wins, bob's DOWN is worthless

        vm.prank(bob.addr);
        vm.expectRevert(UpDownSettlement.NothingToRedeem.selector);
        s.redeem(mid); // bob holds only DOWN (loser) → nothing

        vm.prank(alice.addr);
        assertEq(s.redeem(mid), 100e18, "winner (alice) redeems");
    }

    // ─────────────────────────────────────────────────────────────────────
    // F-17779: rolling treasury rebate budget
    // ─────────────────────────────────────────────────────────────────────

    function test_F17779_rebateBudgetCapsClaims() public {
        // Treasury approves the contract (standing approval — the V1 drain precondition).
        usdt.mint(treasury, 1_000_000e18);
        vm.prank(treasury);
        usdt.approve(address(s), type(uint256).max);

        s.setRebateBudget(500e18, 7 days);

        // A compromised relayer accrues a huge rebate to an address it controls.
        vm.prank(relayer);
        s.accumulateRebate(bob.addr, 10_000e18);

        // The on-chain budget caps the claim regardless of the standing approval.
        vm.prank(bob.addr);
        vm.expectRevert(abi.encodeWithSelector(UpDownSettlement.RebateBudgetExceeded.selector, 10_000e18, 500e18));
        s.claimRebate();
    }

    function test_F17779_rebateWithinBudget_works_andWindowRolls() public {
        usdt.mint(treasury, 1_000_000e18);
        vm.prank(treasury);
        usdt.approve(address(s), type(uint256).max);
        s.setRebateBudget(500e18, 7 days);

        // Within budget.
        vm.prank(relayer);
        s.accumulateRebate(bob.addr, 400e18);
        vm.prank(bob.addr);
        s.claimRebate();
        assertEq(usdt.balanceOf(bob.addr), 1_000_000e18 + 400e18);

        // Same window: only 100e18 of budget left → a 400e18 claim now exceeds it.
        vm.prank(relayer);
        s.accumulateRebate(carol.addr, 400e18);
        vm.prank(carol.addr);
        vm.expectRevert(abi.encodeWithSelector(UpDownSettlement.RebateBudgetExceeded.selector, 400e18, 100e18));
        s.claimRebate();

        // Next window: budget resets.
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(carol.addr);
        s.claimRebate();
        assertEq(usdt.balanceOf(carol.addr), 1_000_000e18 + 400e18);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Conservation: a full mint → trade → resolve → redeem cycle drains to zero.
    // ─────────────────────────────────────────────────────────────────────

    function test_conservation_fullCycleDrainsToZero() public {
        uint256 mid = _market();
        vm.prank(alice.addr);
        s.mint(mid, 100e18);
        vm.prank(bob.addr);
        s.mint(mid, 50e18);
        assertEq(usdt.balanceOf(address(s)), 150e18);

        // alice sells 40 UP to carol.
        UpDownSettlement.Order memory m1 = _order(alice, mid, UP, SELL, 5500, 40e18, 0, 1);
        UpDownSettlement.Order memory t1 = _order(carol, mid, UP, BUY, 5500, 40e18, 0, 2);
        _enter(m1, alice, t1, carol, 40e18, 0, 0);

        _resolve(mid, DOWN); // DOWN wins

        // DOWN holders: alice 100, bob 50. UP holders (carol 40, alice 60) get nothing.
        address[] memory holders = new address[](2);
        holders[0] = alice.addr;
        holders[1] = bob.addr;
        s.redeemFor(mid, holders);

        assertEq(s.marketRetained(mid), 0, "fully redeemed");
        assertEq(usdt.balanceOf(address(s)), 0, "contract holds nothing after all winners redeem");
    }

    // ── helpers ──
    function _enter(
        UpDownSettlement.Order memory makerO,
        Vm.Wallet memory makerW,
        UpDownSettlement.Order memory takerO,
        Vm.Wallet memory takerW,
        uint256 fillAmount,
        uint256 platformFee,
        uint256 makerFee
    ) internal {
        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            makerOrder: makerO,
            makerSignature: _sign(makerW, makerO),
            takerOrder: takerO,
            takerSignature: _sign(takerW, takerO),
            fillAmount: fillAmount,
            platformFee: platformFee,
            makerFee: makerFee
        });
        vm.prank(relayer);
        s.enterPosition(f);
    }

    function _resolve(uint256 mid, uint8 winner) internal {
        UpDownSettlement.Market memory m = s.getMarket(mid);
        vm.warp(uint256(m.endTime) + 1);
        vm.prank(resolver);
        s.resolve(mid, 60_000e8, winner);
    }
}
