// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {UpDownSettlement} from "../src/UpDownSettlement.sol";

/// @title Complementary matching (MINT / MERGE) proof suite.
/// @notice Proves the "buy UP = sell DOWN" duality realised on-chain: two BUY orders on opposite
///         options cross by minting a fresh complete set (`mintMatch`), and two SELL orders on
///         opposite options cross by burning one (`mergeMatch`). Both peg execution to the resting
///         maker's price (price-time priority) and preserve the conservation invariant
///         `usdt.balanceOf(settlement) == sum(marketRetained)` by construction.
contract ComplementaryMatchTest is Test {
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

    // ── Helpers (mirror of RemediationV2.t.sol) ─────────────────────────

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

    /// @dev Build a FillInputs. IMPORTANT: this makes external `orderDigest` calls (via `_sign`), so
    ///      it MUST be evaluated into a local BEFORE any `vm.prank` / `vm.expectRevert`, otherwise the
    ///      cheat is consumed by the digest call instead of the mint/merge call.
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

    /// @dev Mint a complete set to `w` (so it can act as a share-covered SELL maker in merge tests).
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
    //                              MINT MATCH
    // ─────────────────────────────────────────────────────────────────────

    /// A BUY UP at 60% (maker) crosses a BUY DOWN at 40% (taker): a fresh set is minted, each buyer
    /// gets their option's shares, and their combined cash backs the set exactly.
    function test_mintMatch_basicCrossMintsSet() public {
        uint256 mid = _market();
        UpDownSettlement.Order memory upBuy = _order(alice, mid, UP, BUY, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory downBuy = _order(bob, mid, DOWN, BUY, 4000, 100e18, 0, 2);

        uint256 alice0 = usdt.balanceOf(alice.addr);
        uint256 bob0 = usdt.balanceOf(bob.addr);

        UpDownSettlement.FillInputs memory f = _inputs(upBuy, alice, downBuy, bob, 100e18, 0, 0);
        vm.prank(relayer);
        s.mintMatch(f);

        assertEq(s.sharesOf(mid, alice.addr, UP), 100e18, "UP buyer got UP shares");
        assertEq(s.sharesOf(mid, alice.addr, DOWN), 0, "UP buyer got no DOWN");
        assertEq(s.sharesOf(mid, bob.addr, DOWN), 100e18, "DOWN buyer got DOWN shares");
        assertEq(s.sharesOf(mid, bob.addr, UP), 0, "DOWN buyer got no UP");
        assertEq(s.optionShares(mid, UP), 100e18);
        assertEq(s.optionShares(mid, DOWN), 100e18);
        assertEq(s.marketRetained(mid), 100e18);
        assertEq(usdt.balanceOf(alice.addr), alice0 - 60e18, "maker paid 60%");
        assertEq(usdt.balanceOf(bob.addr), bob0 - 40e18, "taker paid the 40% complement");
        assertEq(usdt.balanceOf(address(s)), 100e18, "balance == marketRetained");
    }

    /// Execution pegs to the resting maker's price, so the aggressing taker gets price improvement:
    /// maker UP at 60% + taker DOWN at 50% (sum 110%) → taker pays only the 40% complement.
    function test_mintMatch_takerGetsPriceImprovement() public {
        uint256 mid = _market();
        UpDownSettlement.Order memory upBuy = _order(alice, mid, UP, BUY, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory downBuy = _order(bob, mid, DOWN, BUY, 5000, 100e18, 0, 2);

        uint256 bob0 = usdt.balanceOf(bob.addr);
        UpDownSettlement.FillInputs memory f = _inputs(upBuy, alice, downBuy, bob, 100e18, 0, 0);
        vm.prank(relayer);
        s.mintMatch(f);

        assertEq(usdt.balanceOf(bob.addr), bob0 - 40e18, "taker improved from 50% to 40%");
        assertEq(s.marketRetained(mid), 100e18);
        assertEq(usdt.balanceOf(address(s)), 100e18);
    }

    /// The UP leg can be the taker (order symmetry): maker DOWN at 45% + taker UP at 60%.
    function test_mintMatch_upLegIsTaker() public {
        uint256 mid = _market();
        UpDownSettlement.Order memory downBuy = _order(alice, mid, DOWN, BUY, 4500, 100e18, 0, 1);
        UpDownSettlement.Order memory upBuy = _order(bob, mid, UP, BUY, 6000, 100e18, 0, 2);

        UpDownSettlement.FillInputs memory f = _inputs(downBuy, alice, upBuy, bob, 100e18, 0, 0);
        vm.prank(relayer);
        s.mintMatch(f);

        assertEq(s.sharesOf(mid, alice.addr, DOWN), 100e18, "maker(DOWN) got DOWN");
        assertEq(s.sharesOf(mid, bob.addr, UP), 100e18, "taker(UP) got UP");
        assertEq(usdt.balanceOf(alice.addr), 1_000_000e18 - 45e18);
        assertEq(usdt.balanceOf(bob.addr), 1_000_000e18 - 55e18);
        assertEq(usdt.balanceOf(address(s)), 100e18);
    }

    /// Taker pays fees, capped by the taker's signed maxFee; maker pays no fee. Mirrors enterPosition.
    function test_mintMatch_takerPaysFees() public {
        uint256 mid = _market();
        UpDownSettlement.Order memory upBuy = _order(alice, mid, UP, BUY, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory downBuy = _order(bob, mid, DOWN, BUY, 4000, 100e18, 5e18, 2);

        uint256 treasury0 = usdt.balanceOf(treasury);
        uint256 alice0 = usdt.balanceOf(alice.addr);
        uint256 bob0 = usdt.balanceOf(bob.addr);

        UpDownSettlement.FillInputs memory f = _inputs(upBuy, alice, downBuy, bob, 100e18, 2e18, 1e18);
        vm.prank(relayer);
        s.mintMatch(f);

        assertEq(usdt.balanceOf(bob.addr), bob0 - 40e18 - 3e18, "taker paid cash + all fees");
        assertEq(usdt.balanceOf(treasury), treasury0 + 2e18, "treasury got platformFee");
        assertEq(usdt.balanceOf(alice.addr), alice0 - 60e18 + 1e18, "maker paid cash, got makerFee");
        assertEq(s.orderFeesPaid(s.hashOrder(downBuy)), 3e18, "cumulative taker fees recorded");
        assertEq(usdt.balanceOf(address(s)), 100e18, "pool holds only backing");
    }

    function test_mintMatch_feeCapEnforced() public {
        uint256 mid = _market();
        UpDownSettlement.Order memory upBuy = _order(alice, mid, UP, BUY, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory downBuy = _order(bob, mid, DOWN, BUY, 4000, 100e18, 2e18, 2);

        UpDownSettlement.FillInputs memory f = _inputs(upBuy, alice, downBuy, bob, 100e18, 2e18, 1e18);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(UpDownSettlement.FeeExceedsTakerCap.selector, 3e18, 2e18));
        s.mintMatch(f);
    }

    /// Prices summing below 100% do not fund a full set → OrdersNotCrossed.
    function test_mintMatch_notCrossed_reverts() public {
        uint256 mid = _market();
        UpDownSettlement.Order memory upBuy = _order(alice, mid, UP, BUY, 5000, 100e18, 0, 1);
        UpDownSettlement.Order memory downBuy = _order(bob, mid, DOWN, BUY, 4000, 100e18, 0, 2); // sum 90%
        UpDownSettlement.FillInputs memory f = _inputs(upBuy, alice, downBuy, bob, 100e18, 0, 0);
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.OrdersNotCrossed.selector);
        s.mintMatch(f);
    }

    function test_mintMatch_sameOption_reverts() public {
        uint256 mid = _market();
        UpDownSettlement.Order memory a = _order(alice, mid, UP, BUY, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory b = _order(bob, mid, UP, BUY, 6000, 100e18, 0, 2);
        UpDownSettlement.FillInputs memory f = _inputs(a, alice, b, bob, 100e18, 0, 0);
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.NotComplementary.selector);
        s.mintMatch(f);
    }

    function test_mintMatch_notBothBuys_reverts() public {
        uint256 mid = _market();
        UpDownSettlement.Order memory upBuy = _order(alice, mid, UP, BUY, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory downSell = _order(bob, mid, DOWN, SELL, 4000, 100e18, 0, 2);
        UpDownSettlement.FillInputs memory f = _inputs(upBuy, alice, downSell, bob, 100e18, 0, 0);
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.NotBothBuys.selector);
        s.mintMatch(f);
    }

    function test_mintMatch_invalidSignature_reverts() public {
        uint256 mid = _market();
        UpDownSettlement.Order memory upBuy = _order(alice, mid, UP, BUY, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory downBuy = _order(bob, mid, DOWN, BUY, 4000, 100e18, 0, 2);
        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            makerOrder: upBuy,
            makerSignature: _sign(alice, upBuy),
            takerOrder: downBuy,
            takerSignature: _sign(carol, downBuy), // wrong signer
            fillAmount: 100e18,
            platformFee: 0,
            makerFee: 0
        });
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.InvalidSignature.selector);
        s.mintMatch(f);
    }

    function test_mintMatch_onlyRelayer() public {
        uint256 mid = _market();
        UpDownSettlement.Order memory upBuy = _order(alice, mid, UP, BUY, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory downBuy = _order(bob, mid, DOWN, BUY, 4000, 100e18, 0, 2);
        UpDownSettlement.FillInputs memory f = _inputs(upBuy, alice, downBuy, bob, 100e18, 0, 0);
        vm.expectRevert(UpDownSettlement.OnlyRelayer.selector);
        s.mintMatch(f); // not pranked as relayer
    }

    /// Cumulative fills across partial mint matches cannot exceed either order's signed amount.
    function test_mintMatch_partialFillsCapAtOrderAmount() public {
        uint256 mid = _market();
        UpDownSettlement.Order memory upBuy = _order(alice, mid, UP, BUY, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory downBuy = _order(bob, mid, DOWN, BUY, 4000, 100e18, 0, 2);

        UpDownSettlement.FillInputs memory f1 = _inputs(upBuy, alice, downBuy, bob, 60e18, 0, 0);
        vm.prank(relayer);
        s.mintMatch(f1);
        UpDownSettlement.FillInputs memory f2 = _inputs(upBuy, alice, downBuy, bob, 40e18, 0, 0);
        vm.prank(relayer);
        s.mintMatch(f2);
        assertEq(s.sharesOf(mid, alice.addr, UP), 100e18, "two partials sum to the order");

        UpDownSettlement.FillInputs memory f3 = _inputs(upBuy, alice, downBuy, bob, 1e18, 0, 0);
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.FillExceedsOrderAmount.selector);
        s.mintMatch(f3);
    }

    /// End-to-end: after a mint match, the winning-side buyer redeems $1/share and the pool zeroes.
    function test_mintMatch_thenRedeem_isZeroSum() public {
        uint256 mid = _market();
        UpDownSettlement.Order memory upBuy = _order(alice, mid, UP, BUY, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory downBuy = _order(bob, mid, DOWN, BUY, 4000, 100e18, 0, 2);
        UpDownSettlement.FillInputs memory f = _inputs(upBuy, alice, downBuy, bob, 100e18, 0, 0);
        vm.prank(relayer);
        s.mintMatch(f);

        _resolve(mid, UP); // UP wins

        vm.prank(alice.addr);
        uint256 payout = s.redeem(mid);
        assertEq(payout, 100e18, "UP holder redeems full $1/share");
        assertEq(usdt.balanceOf(alice.addr), 1_000_000e18 + 40e18, "winner +40");
        assertEq(usdt.balanceOf(bob.addr), 1_000_000e18 - 40e18, "loser -40");
        assertEq(s.marketRetained(mid), 0, "backing fully redeemed");
        assertEq(usdt.balanceOf(address(s)), 0, "pool drained to zero");
    }

    /// F2 boundary: a maker BUY UP at 0 bps yields makerCash == 0. The guarded zero-value transfer is
    /// skipped (so a revert-on-zero token can't brick the match) and the taker fully backs the set.
    function test_mintMatch_zeroPriceLegSkipsTransfer() public {
        uint256 mid = _market();
        UpDownSettlement.Order memory upBuy = _order(alice, mid, UP, BUY, 0, 100e18, 0, 1);
        UpDownSettlement.Order memory downBuy = _order(bob, mid, DOWN, BUY, 10000, 100e18, 0, 2);

        uint256 alice0 = usdt.balanceOf(alice.addr);
        uint256 bob0 = usdt.balanceOf(bob.addr);

        UpDownSettlement.FillInputs memory f = _inputs(upBuy, alice, downBuy, bob, 100e18, 0, 0);
        vm.prank(relayer);
        s.mintMatch(f);

        assertEq(usdt.balanceOf(alice.addr), alice0, "maker paid 0 (zero-value leg skipped, no revert)");
        assertEq(usdt.balanceOf(bob.addr), bob0 - 100e18, "taker fully backed the set");
        assertEq(s.sharesOf(mid, alice.addr, UP), 100e18, "maker still credited UP shares at price 0");
        assertEq(s.sharesOf(mid, bob.addr, DOWN), 100e18);
        assertEq(s.marketRetained(mid), 100e18);
        assertEq(usdt.balanceOf(address(s)), 100e18, "conservation: balance == marketRetained");
    }

    /// F1 (rounding note): only the maker leg is floored; the taker absorbs the sub-unit residual,
    /// bounded to EXACTLY <= 1 base unit per fill. Here maker BUY UP at 99.99% + taker BUY DOWN at 0.01%
    /// with a 1-unit fill: makerCash = floor(9999*1/10000) = 0, so the taker pays the whole 1 unit. The
    /// residual flows into backing (never to the platform) and the set stays fully backed — proving the
    /// taker's signed price is not a hard per-leg cap, but the deviation is dust and solvency holds.
    function test_mintMatch_subUnitRoundingBornByTaker() public {
        uint256 mid = _market();
        UpDownSettlement.Order memory upBuy = _order(alice, mid, UP, BUY, 9999, 100e18, 0, 1);
        UpDownSettlement.Order memory downBuy = _order(bob, mid, DOWN, BUY, 1, 100e18, 0, 2);

        uint256 alice0 = usdt.balanceOf(alice.addr);
        uint256 bob0 = usdt.balanceOf(bob.addr);

        UpDownSettlement.FillInputs memory f = _inputs(upBuy, alice, downBuy, bob, 1, 0, 0);
        vm.prank(relayer);
        s.mintMatch(f);

        assertEq(usdt.balanceOf(alice.addr), alice0, "maker leg floored to 0");
        assertEq(usdt.balanceOf(bob.addr), bob0 - 1, "taker absorbed exactly 1 base unit of residual");
        assertEq(s.marketRetained(mid), 1, "set fully backed by the combined 1 unit");
        assertEq(usdt.balanceOf(address(s)), 1, "conservation holds at the rounding boundary");
        assertEq(s.sharesOf(mid, alice.addr, UP), 1);
        assertEq(s.sharesOf(mid, bob.addr, DOWN), 1);
    }

    /// F3: MintMatched now carries platformFee/makerFee so a mint-fill's full settlement (including the
    /// taker-paid fee flow) is reconstructable from the settlement event alone — parity with FillSettled.
    function test_mintMatch_eventCarriesFees() public {
        uint256 mid = _market();
        UpDownSettlement.Order memory upBuy = _order(alice, mid, UP, BUY, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory downBuy = _order(bob, mid, DOWN, BUY, 4000, 100e18, 5e18, 2);
        UpDownSettlement.FillInputs memory f = _inputs(upBuy, alice, downBuy, bob, 100e18, 2e18, 1e18);

        vm.expectEmit(true, true, true, true, address(s));
        emit UpDownSettlement.MintMatched(mid, alice.addr, bob.addr, 100e18, 60e18, 40e18, bob.addr, 2e18, 1e18);
        vm.prank(relayer);
        s.mintMatch(f);
    }

    // ─────────────────────────────────────────────────────────────────────
    //                              MERGE MATCH
    // ─────────────────────────────────────────────────────────────────────

    /// SELL UP at 60% (maker) crosses SELL DOWN at 30% (taker, sum 90%): the set burns, backing
    /// releases, and each seller is paid — the taker gets price improvement (40% over its 30% ask).
    function test_mergeMatch_basicBurnsSet() public {
        uint256 mid = _market();
        _mintSet(alice, mid, 100e18); // alice holds UP (+ DOWN)
        _mintSet(bob, mid, 100e18); // bob holds DOWN (+ UP)
        assertEq(usdt.balanceOf(address(s)), 200e18, "two sets minted");

        UpDownSettlement.Order memory upSell = _order(alice, mid, UP, SELL, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory downSell = _order(bob, mid, DOWN, SELL, 3000, 100e18, 0, 2);

        uint256 alice0 = usdt.balanceOf(alice.addr);
        uint256 bob0 = usdt.balanceOf(bob.addr);

        UpDownSettlement.FillInputs memory f = _inputs(upSell, alice, downSell, bob, 100e18, 0, 0);
        vm.prank(relayer);
        s.mergeMatch(f);

        assertEq(s.sharesOf(mid, alice.addr, UP), 0, "maker burned UP");
        assertEq(s.sharesOf(mid, bob.addr, DOWN), 0, "taker burned DOWN");
        assertEq(usdt.balanceOf(alice.addr), alice0 + 60e18, "maker got 60%");
        assertEq(usdt.balanceOf(bob.addr), bob0 + 40e18, "taker got 40% (improved)");
        assertEq(s.marketRetained(mid), 100e18);
        assertEq(s.optionShares(mid, UP), 100e18);
        assertEq(s.optionShares(mid, DOWN), 100e18);
        assertEq(usdt.balanceOf(address(s)), 100e18, "balance == remaining backing");
    }

    /// Prices summing above 100% would pay out more than the burn releases → OrdersNotCrossed.
    function test_mergeMatch_notCrossed_reverts() public {
        uint256 mid = _market();
        _mintSet(alice, mid, 100e18);
        _mintSet(bob, mid, 100e18);
        UpDownSettlement.Order memory upSell = _order(alice, mid, UP, SELL, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory downSell = _order(bob, mid, DOWN, SELL, 5000, 100e18, 0, 2); // sum 110%
        UpDownSettlement.FillInputs memory f = _inputs(upSell, alice, downSell, bob, 100e18, 0, 0);
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.OrdersNotCrossed.selector);
        s.mergeMatch(f);
    }

    /// A seller who does not hold the shares cannot merge (share-covered SELL).
    function test_mergeMatch_insufficientShares_reverts() public {
        uint256 mid = _market();
        _mintSet(alice, mid, 100e18); // only alice has shares; bob has none
        UpDownSettlement.Order memory upSell = _order(alice, mid, UP, SELL, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory downSell = _order(bob, mid, DOWN, SELL, 3000, 100e18, 0, 2);
        UpDownSettlement.FillInputs memory f = _inputs(upSell, alice, downSell, bob, 100e18, 0, 0);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(UpDownSettlement.InsufficientShares.selector, mid, DOWN, 100e18, 0));
        s.mergeMatch(f);
    }

    function test_mergeMatch_feesMustBeZero_reverts() public {
        uint256 mid = _market();
        _mintSet(alice, mid, 100e18);
        _mintSet(bob, mid, 100e18);
        UpDownSettlement.Order memory upSell = _order(alice, mid, UP, SELL, 6000, 100e18, 5e18, 1);
        UpDownSettlement.Order memory downSell = _order(bob, mid, DOWN, SELL, 3000, 100e18, 5e18, 2);
        UpDownSettlement.FillInputs memory f = _inputs(upSell, alice, downSell, bob, 100e18, 1, 0);
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.FeeBreakdownInvalid.selector);
        s.mergeMatch(f);
    }

    function test_mergeMatch_notBothSells_reverts() public {
        uint256 mid = _market();
        _mintSet(alice, mid, 100e18);
        _mintSet(bob, mid, 100e18);
        UpDownSettlement.Order memory upSell = _order(alice, mid, UP, SELL, 6000, 100e18, 0, 1);
        UpDownSettlement.Order memory downBuy = _order(bob, mid, DOWN, BUY, 3000, 100e18, 0, 2);
        UpDownSettlement.FillInputs memory f = _inputs(upSell, alice, downBuy, bob, 100e18, 0, 0);
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.NotBothSells.selector);
        s.mergeMatch(f);
    }

    /// Mint a set then immediately merge it back out (via two counterparties) leaves the pool
    /// perfectly balanced — the conservation invariant holds across a full mint→merge round-trip.
    function test_mintThenMerge_invariantRoundTrip() public {
        uint256 mid = _market();
        UpDownSettlement.Order memory upBuy = _order(alice, mid, UP, BUY, 5500, 100e18, 0, 1);
        UpDownSettlement.Order memory downBuy = _order(bob, mid, DOWN, BUY, 5000, 100e18, 0, 2);
        UpDownSettlement.FillInputs memory fm = _inputs(upBuy, alice, downBuy, bob, 100e18, 0, 0);
        vm.prank(relayer);
        s.mintMatch(fm);
        assertEq(usdt.balanceOf(address(s)), 100e18);
        assertEq(s.marketRetained(mid), 100e18);

        UpDownSettlement.Order memory upSell = _order(alice, mid, UP, SELL, 5000, 100e18, 0, 3);
        UpDownSettlement.Order memory downSell = _order(bob, mid, DOWN, SELL, 4000, 100e18, 0, 4);
        UpDownSettlement.FillInputs memory fg = _inputs(upSell, alice, downSell, bob, 100e18, 0, 0);
        vm.prank(relayer);
        s.mergeMatch(fg);

        assertEq(s.marketRetained(mid), 0, "backing fully released");
        assertEq(s.optionShares(mid, UP), 0);
        assertEq(s.optionShares(mid, DOWN), 0);
        assertEq(usdt.balanceOf(address(s)), 0, "pool empty after round-trip");
        assertEq(s.sharesOf(mid, alice.addr, UP), 0);
        assertEq(s.sharesOf(mid, bob.addr, DOWN), 0);
    }

    /// F1 mirror for MERGE: only the maker leg is floored, so the resting SELL maker is paid its
    /// floored ask and the taker receives the complement. maker SELL UP at 99.99% + taker SELL DOWN at
    /// 0.01%, 1-unit fill: makerProceeds = floor(9999*1/10000) = 0, takerProceeds = 1. Sum == fill, one
    /// unit of backing is released exactly, and no value is created or lost (sub-unit, solvency-safe).
    function test_mergeMatch_subUnitRoundingBornByTaker() public {
        uint256 mid = _market();
        _mintSet(alice, mid, 1); // alice holds 1 UP (+ 1 DOWN)
        _mintSet(bob, mid, 1); // bob holds 1 DOWN (+ 1 UP)

        UpDownSettlement.Order memory upSell = _order(alice, mid, UP, SELL, 9999, 1, 0, 1);
        UpDownSettlement.Order memory downSell = _order(bob, mid, DOWN, SELL, 1, 1, 0, 2);

        uint256 alice0 = usdt.balanceOf(alice.addr);
        uint256 bob0 = usdt.balanceOf(bob.addr);

        UpDownSettlement.FillInputs memory f = _inputs(upSell, alice, downSell, bob, 1, 0, 0);
        vm.prank(relayer);
        s.mergeMatch(f);

        assertEq(usdt.balanceOf(alice.addr), alice0, "resting maker paid its floored ask (0)");
        assertEq(usdt.balanceOf(bob.addr), bob0 + 1, "taker received the residual 1 unit");
        assertEq(s.sharesOf(mid, alice.addr, UP), 0, "maker burned its UP");
        assertEq(s.sharesOf(mid, bob.addr, DOWN), 0, "taker burned its DOWN");
        assertEq(s.marketRetained(mid), 1, "exactly one set (1 unit) released; one set remains");
        assertEq(usdt.balanceOf(address(s)), 1, "conservation holds across the burn");
    }
}
