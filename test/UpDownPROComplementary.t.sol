// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {UpDownSettlement} from "../src/UpDownSettlement.sol";

/// @notice PR-O Step 2 — Phase 1 §5 unit tests for the complementary-mint
///         entrypoint, the buyer-cash flip in enterPosition, and the
///         resolution-payout conservation property.
contract UpDownPROComplementaryTest is Test {
    bytes32 internal constant PAIR = keccak256("BTC/USD");

    ERC20Mock internal usdt;
    UpDownSettlement internal s;
    address internal owner = address(this);
    address internal autocycler = makeAddr("autocycler-pro");
    address internal resolver = makeAddr("resolver-pro");
    address internal relayer = makeAddr("relayer-pro");
    address internal treasury = makeAddr("treasury-pro");
    address internal backer = makeAddr("backer-pro");
    address internal buyerEoa = makeAddr("buyer-pro");

    Vm.Wallet internal maker;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdt = new ERC20Mock();
        s = new UpDownSettlement(usdt, owner, 70, 80);
        s.setAutocycler(autocycler);
        s.setResolver(resolver);
        s.setRelayer(relayer);
        s.setTreasury(treasury);

        maker = vm.createWallet("maker-pro");
        usdt.mint(maker.addr, 10_000e18);
        vm.prank(maker.addr);
        usdt.approve(address(s), type(uint256).max);

        usdt.mint(backer, 10_000e18);
        vm.prank(backer);
        usdt.approve(address(s), type(uint256).max);

        usdt.mint(buyerEoa, 10_000e18);
        vm.prank(buyerEoa);
        usdt.approve(address(s), type(uint256).max);
    }

    function _createMarket() internal returns (uint256 mid) {
        vm.prank(autocycler);
        mid = s.createMarket(PAIR, 300, 50_000e8);
    }

    function _signOrder(UpDownSettlement.Order memory order, Vm.Wallet memory signer)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = s.orderDigest(order);
        (uint8 v, bytes32 r, bytes32 sSig) = vm.sign(signer.privateKey, digest);
        return abi.encodePacked(r, sSig, v);
    }

    // ── Phase 1 §5 test 1 ───────────────────────────────────────────────

    function test_complementaryMint_increments_retained() public {
        uint256 mid = _createMarket();
        uint256 contractBefore = usdt.balanceOf(address(s));
        uint256 backerBefore = usdt.balanceOf(backer);

        vm.expectEmit(true, true, false, true);
        emit UpDownSettlement.ComplementaryMinted(mid, backer, 50e18);

        vm.prank(relayer);
        s.complementaryMint(mid, 50e18, backer);

        assertEq(s.marketRetained(mid), 50e18, "retained += amount");
        assertEq(usdt.balanceOf(address(s)), contractBefore + 50e18, "contract holds the deposit");
        assertEq(usdt.balanceOf(backer), backerBefore - 50e18, "minter paid the deposit");
    }

    function test_complementaryMint_revertsForNonRelayer() public {
        uint256 mid = _createMarket();
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(UpDownSettlement.OnlyRelayer.selector);
        s.complementaryMint(mid, 50e18, backer);
    }

    function test_complementaryMint_revertsForZeroAmount() public {
        uint256 mid = _createMarket();
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.FillExceedsOrderAmount.selector);
        s.complementaryMint(mid, 0, backer);
    }

    function test_complementaryMint_revertsForZeroMinter() public {
        uint256 mid = _createMarket();
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.ZeroAddress.selector);
        s.complementaryMint(mid, 50e18, address(0));
    }

    function test_complementaryMint_revertsAfterMarketEnd() public {
        uint256 mid = _createMarket();
        UpDownSettlement.Market memory m = s.getMarket(mid);
        vm.warp(uint256(m.endTime) + 1);
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.MarketNotOpen.selector);
        s.complementaryMint(mid, 50e18, backer);
    }

    // ── Phase 1 §5 test 2 ───────────────────────────────────────────────

    function test_complementaryBurn_decrements_retained() public {
        uint256 mid = _createMarket();
        vm.prank(relayer);
        s.complementaryMint(mid, 50e18, backer);
        assertEq(s.marketRetained(mid), 50e18);

        uint256 backerBefore = usdt.balanceOf(backer);
        uint256 contractBefore = usdt.balanceOf(address(s));

        vm.expectEmit(true, true, false, true);
        emit UpDownSettlement.ComplementaryBurned(mid, backer, 50e18);

        vm.prank(relayer);
        s.complementaryBurn(mid, 50e18, backer);

        assertEq(s.marketRetained(mid), 0, "retained -= amount");
        assertEq(usdt.balanceOf(backer), backerBefore + 50e18, "holder got the deposit back");
        assertEq(usdt.balanceOf(address(s)), contractBefore - 50e18, "contract no longer holds it");
    }

    function test_complementaryBurn_revertsWithoutBacking() public {
        uint256 mid = _createMarket();
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(UpDownSettlement.NoBackingForSeller.selector, mid, 50e18, 0)
        );
        s.complementaryBurn(mid, 50e18, backer);
    }

    function test_complementaryBurn_revertsForNonRelayer() public {
        uint256 mid = _createMarket();
        vm.prank(relayer);
        s.complementaryMint(mid, 50e18, backer);

        vm.prank(makeAddr("attacker2"));
        vm.expectRevert(UpDownSettlement.OnlyRelayer.selector);
        s.complementaryBurn(mid, 50e18, backer);
    }

    // ── Phase 1 §5 test 3 ───────────────────────────────────────────────

    function test_enterPosition_pulls_only_cash_side_when_backing_present() public {
        uint256 mid = _createMarket();
        // Pre-fund backing.
        vm.prank(relayer);
        s.complementaryMint(mid, 100e18, backer);

        // Sign a BUY order at price=5500 (cashPart = $55 of $100 share).
        UpDownSettlement.Order memory order = UpDownSettlement.Order({
            maker: maker.addr,
            market: mid,
            option: 1,
            side: 0,
            orderType: 0,
            price: 5500,
            amount: 100e18,
            nonce: 1,
            expiry: block.timestamp + 3600
        });
        bytes memory sig = _signOrder(order, maker);

        uint256 buyerBefore = usdt.balanceOf(maker.addr);
        uint256 platformFee = 5e17; // 0.5
        uint256 makerFee = 0;

        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            order: order,
            signature: sig,
            marketId: mid,
            option: 1,
            fillAmount: 100e18,
            taker: makeAddr("counterparty"),
            sellerReceives: 55e18, // = cashPart, Option B
            platformFee: platformFee,
            makerFee: makerFee,
            makerFeeRecipient: address(0)
        });
        vm.prank(relayer);
        s.enterPosition(f);

        // Buyer paid cashPart + fees = 55.5, NOT 100.
        assertEq(usdt.balanceOf(maker.addr), buyerBefore - 55e18 - platformFee, "buyer pays cash + fees only");
    }

    // ── Phase 1 §5 test 4 ───────────────────────────────────────────────

    function test_enterPosition_reverts_without_backing() public {
        uint256 mid = _createMarket();
        // NO pre-mint.

        UpDownSettlement.Order memory order = UpDownSettlement.Order({
            maker: maker.addr,
            market: mid,
            option: 1,
            side: 0,
            orderType: 0,
            price: 5500,
            amount: 100e18,
            nonce: 1,
            expiry: block.timestamp + 3600
        });
        bytes memory sig = _signOrder(order, maker);

        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            order: order,
            signature: sig,
            marketId: mid,
            option: 1,
            fillAmount: 100e18,
            taker: makeAddr("counterparty2"),
            sellerReceives: 55e18,
            platformFee: 0,
            makerFee: 0,
            makerFeeRecipient: address(0)
        });

        // mintBackingDelta = (10000-5500)/10000 * 100e18 = 45e18; available = 0.
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(UpDownSettlement.NoBackingForSeller.selector, mid, 45e18, 0)
        );
        s.enterPosition(f);
    }

    function test_enterPosition_rejectsSellerReceivesAboveCashPart() public {
        uint256 mid = _createMarket();
        vm.prank(relayer);
        s.complementaryMint(mid, 100e18, backer);

        UpDownSettlement.Order memory order = UpDownSettlement.Order({
            maker: maker.addr,
            market: mid,
            option: 1,
            side: 0,
            orderType: 0,
            price: 5500,
            amount: 100e18,
            nonce: 2,
            expiry: block.timestamp + 3600
        });
        bytes memory sig = _signOrder(order, maker);
        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            order: order,
            signature: sig,
            marketId: mid,
            option: 1,
            fillAmount: 100e18,
            taker: makeAddr("counterparty3"),
            sellerReceives: 60e18, // > cashPart (55) — invalid under Option B
            platformFee: 0,
            makerFee: 0,
            makerFeeRecipient: address(0)
        });
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.FeeBreakdownInvalid.selector);
        s.enterPosition(f);
    }

    // ── Phase 1 §5 test 5 ───────────────────────────────────────────────

    function test_resolution_pays_exactly_marketRetained() public {
        // Multi-mint + multi-fill, then resolve. Verify marketRetained at
        // resolution = the relayer's payout pool (and equals contract
        // balance for this market).
        uint256 mid = _createMarket();

        vm.prank(relayer);
        s.complementaryMint(mid, 100e18, backer);
        vm.prank(relayer);
        s.complementaryMint(mid, 50e18, backer);
        assertEq(s.marketRetained(mid), 150e18);

        // One fill at price 5500, balance-neutral (sellerReceives = cashPart).
        UpDownSettlement.Order memory order = UpDownSettlement.Order({
            maker: maker.addr,
            market: mid,
            option: 1,
            side: 0,
            orderType: 0,
            price: 5500,
            amount: 100e18,
            nonce: 1,
            expiry: block.timestamp + 3600
        });
        bytes memory sig = _signOrder(order, maker);
        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            order: order,
            signature: sig,
            marketId: mid,
            option: 1,
            fillAmount: 100e18,
            taker: makeAddr("counterparty4"),
            sellerReceives: 55e18,
            platformFee: 0,
            makerFee: 0,
            makerFeeRecipient: address(0)
        });
        vm.prank(relayer);
        s.enterPosition(f);

        // Fill was balance-neutral; marketRetained unchanged.
        assertEq(s.marketRetained(mid), 150e18, "fill is pool-neutral under Option B");

        // Resolve + withdraw.
        UpDownSettlement.Market memory m = s.getMarket(mid);
        vm.warp(uint256(m.endTime) + 1);
        vm.prank(resolver);
        s.resolve(mid, 60_000e8, 1);

        uint256 relBefore = usdt.balanceOf(relayer);
        vm.prank(relayer);
        s.withdrawSettlement(mid);

        // Relayer received exactly marketRetained worth of USDT.
        assertEq(usdt.balanceOf(relayer), relBefore + 150e18, "relayer receives full retained");
        assertEq(s.marketRetained(mid), 0, "retained zeroed post-withdraw");
    }

    // ── Bonus: Phase 1 conservation worked example ──────────────────────

    function test_workedExample_bot_mints100_sells100UP_at055_buys_winsDOWN() public {
        // Reproduces Phase 1 Section 3 numerical example in-contract.
        uint256 mid = _createMarket();

        address bot = backer;
        address alice = buyerEoa;
        uint256 botStart = usdt.balanceOf(bot);
        uint256 aliceStart = usdt.balanceOf(alice);
        uint256 treasStart = usdt.balanceOf(treasury);

        // Step 1: bot mints $100 → 100 UP + 100 DOWN (off-chain credit; we
        // verify the on-chain delta only here).
        vm.prank(relayer);
        s.complementaryMint(mid, 100e18, bot);
        assertEq(s.marketRetained(mid), 100e18);

        // Step 3: Alice BUYs 100 UP @ price 5500 with platformFee 0.2475.
        // (makerFee=0 for clarity.) Buyer pulls cashPart + platformFee.
        // Bot's signed SELL is the maker side.
        UpDownSettlement.Order memory order = UpDownSettlement.Order({
            maker: maker.addr,
            market: mid,
            option: 1,
            side: 1, // SELL maker
            orderType: 0,
            price: 5500,
            amount: 100e18,
            nonce: 7,
            expiry: block.timestamp + 3600
        });
        bytes memory sig = _signOrder(order, maker);

        // Maker (= bot proxy) doesn't actually hold positions on-chain;
        // for the fee assertions all we need is the bookkeeping. The bot
        // here is `backer`, and we route the seller-side payout to `bot`
        // via the FillInputs.taker field — since side=1 (SELL), taker is
        // the BUYER, and order.maker is the SELLER.
        order.maker = bot; // override — bot is the SELL maker
        sig = _signOrder(order, maker); // sig must match the order pre-override; rebuild
        // The sig logic above is wrong for the override path. For the worked
        // example, simplest: build the order with maker=bot from the start,
        // but sign it with our test EOA. Since bot is a plain address (not
        // an EOA wallet with a key in this test), we instead set bot = maker.addr.
        order.maker = maker.addr;
        sig = _signOrder(order, maker);

        // Re-targeting: maker is the SELLER. Pre-fund maker with USDT for
        // the mint deposit (since bot in the example IS the maker now).
        // The pre-mint we did from `backer` provided the backing; maker.addr
        // doesn't need to hold balance for the fill itself.
        uint256 makerStart = usdt.balanceOf(maker.addr);

        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            order: order,
            signature: sig,
            marketId: mid,
            option: 1,
            fillAmount: 100e18,
            taker: alice,
            sellerReceives: 55e18,
            platformFee: 2475e14, // = 0.2475 USDT
            makerFee: 0,
            makerFeeRecipient: address(0)
        });
        vm.prank(relayer);
        s.enterPosition(f);

        // Alice paid cashPart + platformFee = 55.2475.
        assertEq(usdt.balanceOf(alice), aliceStart - 55e18 - 2475e14);
        // Maker (the SELL-side maker, = seller) received cashPart = 55.
        assertEq(usdt.balanceOf(maker.addr), makerStart + 55e18);
        // Treasury got platformFee.
        assertEq(usdt.balanceOf(treasury), treasStart + 2475e14);
        // marketRetained unchanged (fill is pool-neutral with sellerReceives=cashPart).
        assertEq(s.marketRetained(mid), 100e18);

        // Step 4-5: resolve DOWN, withdraw.
        UpDownSettlement.Market memory m = s.getMarket(mid);
        vm.warp(uint256(m.endTime) + 1);
        vm.prank(resolver);
        s.resolve(mid, 49_000e8, 2);
        vm.prank(relayer);
        s.withdrawSettlement(mid);

        // Conservation: bot ends down $100 (mint); alice ends down $55.2475;
        // maker (= seller proxy) ends up $55; treasury up $0.2475; relayer
        // up $100 (= marketRetained, to be paid out off-chain).
        assertEq(usdt.balanceOf(bot), botStart - 100e18);
        // Sum of all on-chain deltas = 0 (relayer's $100 pending off-chain
        // payout to whichever holder won DOWN).
        int256 sumDelta = (int256(usdt.balanceOf(bot)) - int256(botStart))
            + (int256(usdt.balanceOf(alice)) - int256(aliceStart))
            + (int256(usdt.balanceOf(maker.addr)) - int256(makerStart))
            + (int256(usdt.balanceOf(treasury)) - int256(treasStart))
            + (int256(usdt.balanceOf(relayer)));
        assertEq(sumDelta, 0, "conservation: sum of on-chain deltas = 0");
    }
}
