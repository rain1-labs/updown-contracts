// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, StdInvariant, Vm} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {UpDownSettlement} from "../src/UpDownSettlement.sol";

/// @notice Remediation V2 conservation invariants (non-custodial share model).
///
/// Invariants under test, holding at every external-call boundary:
///   (1) usdt.balanceOf(settlement) == Σ marketRetained[mid]            (global solvency)
///   (2) unresolved market: marketRetained == optionShares[UP] == optionShares[DOWN]
///   (3) resolved market:   marketRetained == optionShares[winner]      (winners fully backed)
///
/// (1) is what proves the protocol can always pay every winner who redeems: the contract never
/// holds less USDT than it owes. `enterPosition` is balance-neutral (cash moves peer-to-peer), so
/// only mint / burn / redeem move the contract balance — each by exactly the `marketRetained` delta.
/// (2)+(3) prove F-2026-17771 (no backing reuse) and F-2026-17776 (backing can't be withdrawn out
/// from under a live position): shares are only ever created/destroyed as complete sets, and a fill
/// merely transfers an existing share, so the per-option totals can never diverge from the backing.
contract UpDownPROInvariant is StdInvariant, Test {
    ERC20Mock internal usdt;
    UpDownSettlement internal s;
    ShareHandler internal handler;

    address internal owner = address(this);
    address internal autocycler = makeAddr("auto-inv");
    address internal resolver = makeAddr("res-inv");
    address internal relayer = makeAddr("rel-inv");
    address internal treasury = makeAddr("treas-inv");

    function setUp() public {
        vm.warp(1_700_000_000);
        usdt = new ERC20Mock();
        s = new UpDownSettlement(usdt, owner);
        s.setAutocycler(autocycler);
        s.setResolver(resolver);
        s.setRelayer(relayer);
        s.setTreasury(treasury);

        handler = new ShareHandler(s, usdt, autocycler, resolver, relayer);
        handler.bootstrap();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.fuzzMint.selector;
        selectors[1] = handler.fuzzBurn.selector;
        selectors[2] = handler.fuzzFill.selector;
        selectors[3] = handler.fuzzResolve.selector;
        selectors[4] = handler.fuzzRedeem.selector;
        selectors[5] = handler.fuzzMintMatch.selector;
        selectors[6] = handler.fuzzMergeMatch.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_balanceEqualsSumOfRetained() public view {
        uint256 sumRetained = 0;
        uint256 n = handler.marketCount();
        for (uint256 i = 0; i < n; i++) {
            sumRetained += s.marketRetained(handler.marketIdAt(i));
        }
        assertEq(usdt.balanceOf(address(s)), sumRetained, "balance == sum(marketRetained)");
    }

    function invariant_retainedBacksOutstandingShares() public view {
        uint256 n = handler.marketCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 mid = handler.marketIdAt(i);
            uint256 retained = s.marketRetained(mid);
            uint256 up = s.optionShares(mid, 1);
            uint256 down = s.optionShares(mid, 2);
            UpDownSettlement.Market memory m = s.getMarket(mid);
            if (!m.resolved) {
                assertEq(retained, up, "unresolved: retained == UP shares");
                assertEq(retained, down, "unresolved: retained == DOWN shares");
            } else {
                assertEq(retained, s.optionShares(mid, m.winner), "resolved: retained == winning shares");
                // F-2026-17954: the losing side is zeroed at resolution and never re-grows.
                uint8 loser = m.winner == 1 ? 2 : 1;
                assertEq(s.optionShares(mid, loser), 0, "resolved: loser shares zeroed (F-2026-17954)");
            }
        }
    }
}

/// @notice Action handler. Owns a pool of signing wallets used as both makers (sellers) and takers
///         (buyers), pre-funded + approved, so the fuzzer spends its sequences on real state
///         transitions rather than bouncing off approvals.
contract ShareHandler is Test {
    UpDownSettlement internal s;
    ERC20Mock internal usdt;
    address internal autocycler;
    address internal resolver;
    address internal relayer;

    uint256[] public markets;
    Vm.Wallet[] internal wallets;
    uint256 internal nonceCounter;

    bytes32 internal constant PAIR = keccak256("INV-PAIR");

    constructor(UpDownSettlement _s, ERC20Mock _usdt, address _autocycler, address _resolver, address _relayer) {
        s = _s;
        usdt = _usdt;
        autocycler = _autocycler;
        resolver = _resolver;
        relayer = _relayer;
    }

    function bootstrap() public {
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(autocycler);
            // 1-hour markets so the active window stays open across a long fuzz run.
            markets.push(s.createMarket(PAIR, 3600, 50_000e8));
        }
        for (uint256 i = 0; i < 5; i++) {
            Vm.Wallet memory w = vm.createWallet(string(abi.encodePacked("w", i)));
            usdt.mint(w.addr, 1_000_000e18);
            vm.prank(w.addr);
            usdt.approve(address(s), type(uint256).max);
            wallets.push(w);
        }
    }

    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    function marketIdAt(uint256 i) external view returns (uint256) {
        return markets[i];
    }

    function _activeMarket(uint256 marketIdx) internal view returns (uint256 mid, bool ok) {
        mid = markets[marketIdx % markets.length];
        UpDownSettlement.Market memory m = s.getMarket(mid);
        ok = !m.resolved && block.timestamp < uint256(m.endTime);
    }

    // ── Mint a complete set (self-service path, F-2026-17772). ──
    function fuzzMint(uint256 marketIdx, uint256 walletIdx, uint256 amount) external {
        (uint256 mid, bool ok) = _activeMarket(marketIdx);
        if (!ok) return;
        Vm.Wallet memory w = wallets[walletIdx % wallets.length];
        amount = bound(amount, 1, 1_000e18);
        if (usdt.balanceOf(w.addr) < amount) return;
        vm.prank(w.addr);
        s.mint(mid, amount);
    }

    // ── Burn a complete set the wallet actually holds. ──
    function fuzzBurn(uint256 marketIdx, uint256 walletIdx, uint256 amount) external {
        (uint256 mid, bool ok) = _activeMarket(marketIdx);
        if (!ok) return;
        Vm.Wallet memory w = wallets[walletIdx % wallets.length];
        uint256 up = s.sharesOf(mid, w.addr, 1);
        uint256 down = s.sharesOf(mid, w.addr, 2);
        uint256 maxBurn = up < down ? up : down;
        if (maxBurn == 0) return;
        amount = bound(amount, 1, maxBurn);
        vm.prank(w.addr);
        s.burn(mid, amount);
    }

    // ── Transfer a share via a two-sided signed fill (F-2026-17756/17757). ──
    function fuzzFill(
        uint256 marketIdx,
        uint256 sellerIdx,
        uint256 buyerIdx,
        uint8 option,
        uint16 priceBps,
        uint256 fillAmount
    ) external {
        (uint256 mid, bool ok) = _activeMarket(marketIdx);
        if (!ok) return;
        Vm.Wallet memory seller = wallets[sellerIdx % wallets.length];
        Vm.Wallet memory buyer = wallets[buyerIdx % wallets.length];
        if (seller.addr == buyer.addr) return;
        option = uint8(bound(uint256(option), 1, 2));
        uint256 held = s.sharesOf(mid, seller.addr, option);
        if (held == 0) return;
        fillAmount = bound(fillAmount, 1, held);
        priceBps = uint16(bound(uint256(priceBps), 1, 9999));
        uint256 cashPart = (uint256(priceBps) * fillAmount) / 10000;
        if (usdt.balanceOf(buyer.addr) < cashPart) return;

        UpDownSettlement.Order memory makerOrder = UpDownSettlement.Order({
            maker: seller.addr,
            market: mid,
            option: option,
            side: 1,
            orderType: 0,
            price: priceBps,
            amount: fillAmount,
            maxFee: 0,
            nonce: ++nonceCounter,
            expiry: block.timestamp + 3600
        });
        UpDownSettlement.Order memory takerOrder = UpDownSettlement.Order({
            maker: buyer.addr,
            market: mid,
            option: option,
            side: 0,
            orderType: 0,
            price: priceBps,
            amount: fillAmount,
            maxFee: 0,
            nonce: ++nonceCounter,
            expiry: block.timestamp + 3600
        });

        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            makerOrder: makerOrder,
            makerSignature: _sign(seller, makerOrder),
            takerOrder: takerOrder,
            takerSignature: _sign(buyer, takerOrder),
            fillAmount: fillAmount,
            platformFee: 0,
            makerFee: 0
        });
        vm.prank(relayer);
        s.enterPosition(f);
    }

    // ── MINT match: two BUYers on opposite options, priced so p_up + p_down >= 10000. ──
    function fuzzMintMatch(uint256 marketIdx, uint256 aIdx, uint256 bIdx, uint16 upPriceBps, uint256 fillAmount)
        external
    {
        (uint256 mid, bool ok) = _activeMarket(marketIdx);
        if (!ok) return;
        Vm.Wallet memory upBuyer = wallets[aIdx % wallets.length];
        Vm.Wallet memory downBuyer = wallets[bIdx % wallets.length];
        if (upBuyer.addr == downBuyer.addr) return;

        uint256 pUp = bound(uint256(upPriceBps), 1, 9999);
        uint256 pDown = 10000 - pUp; // crossing at the boundary (sum == 10000)
        fillAmount = bound(fillAmount, 1, 1_000e18);
        uint256 upCash = (pUp * fillAmount) / 10000;
        uint256 downCash = fillAmount - upCash;
        if (usdt.balanceOf(upBuyer.addr) < upCash || usdt.balanceOf(downBuyer.addr) < downCash) return;

        UpDownSettlement.Order memory makerOrder = UpDownSettlement.Order({
            maker: upBuyer.addr,
            market: mid,
            option: 1,
            side: 0,
            orderType: 0,
            price: pUp,
            amount: fillAmount,
            maxFee: 0,
            nonce: ++nonceCounter,
            expiry: block.timestamp + 3600
        });
        UpDownSettlement.Order memory takerOrder = UpDownSettlement.Order({
            maker: downBuyer.addr,
            market: mid,
            option: 2,
            side: 0,
            orderType: 0,
            price: pDown,
            amount: fillAmount,
            maxFee: 0,
            nonce: ++nonceCounter,
            expiry: block.timestamp + 3600
        });
        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            makerOrder: makerOrder,
            makerSignature: _sign(upBuyer, makerOrder),
            takerOrder: takerOrder,
            takerSignature: _sign(downBuyer, takerOrder),
            fillAmount: fillAmount,
            platformFee: 0,
            makerFee: 0
        });
        vm.prank(relayer);
        s.mintMatch(f);
    }

    // ── MERGE match: two SELLers on opposite options who hold the shares, p_up + p_down <= 10000. ──
    function fuzzMergeMatch(uint256 marketIdx, uint256 aIdx, uint256 bIdx, uint16 upPriceBps, uint256 fillAmount)
        external
    {
        (uint256 mid, bool ok) = _activeMarket(marketIdx);
        if (!ok) return;
        Vm.Wallet memory upSeller = wallets[aIdx % wallets.length];
        Vm.Wallet memory downSeller = wallets[bIdx % wallets.length];
        if (upSeller.addr == downSeller.addr) return;

        uint256 upHeld = s.sharesOf(mid, upSeller.addr, 1);
        uint256 downHeld = s.sharesOf(mid, downSeller.addr, 2);
        uint256 maxFill = upHeld < downHeld ? upHeld : downHeld;
        if (maxFill == 0) return;
        fillAmount = bound(fillAmount, 1, maxFill);

        uint256 pUp = bound(uint256(upPriceBps), 1, 9999);
        uint256 pDown = 10000 - pUp; // sum == 10000, the crossing boundary for a merge

        UpDownSettlement.Order memory makerOrder = UpDownSettlement.Order({
            maker: upSeller.addr,
            market: mid,
            option: 1,
            side: 1,
            orderType: 0,
            price: pUp,
            amount: fillAmount,
            maxFee: 0,
            nonce: ++nonceCounter,
            expiry: block.timestamp + 3600
        });
        UpDownSettlement.Order memory takerOrder = UpDownSettlement.Order({
            maker: downSeller.addr,
            market: mid,
            option: 2,
            side: 1,
            orderType: 0,
            price: pDown,
            amount: fillAmount,
            maxFee: 0,
            nonce: ++nonceCounter,
            expiry: block.timestamp + 3600
        });
        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            makerOrder: makerOrder,
            makerSignature: _sign(upSeller, makerOrder),
            takerOrder: takerOrder,
            takerSignature: _sign(downSeller, takerOrder),
            fillAmount: fillAmount,
            platformFee: 0,
            makerFee: 0
        });
        vm.prank(relayer);
        s.mergeMatch(f);
    }

    function fuzzResolve(uint256 marketIdx, uint8 winner) external {
        uint256 mid = markets[marketIdx % markets.length];
        UpDownSettlement.Market memory m = s.getMarket(mid);
        if (m.resolved) return;
        winner = uint8(bound(uint256(winner), 1, 2));
        if (block.timestamp < uint256(m.endTime)) vm.warp(uint256(m.endTime) + 1);
        vm.prank(resolver);
        s.resolve(mid, 60_000e8, winner);
    }

    function fuzzRedeem(uint256 marketIdx, uint256 walletIdx) external {
        uint256 mid = markets[marketIdx % markets.length];
        UpDownSettlement.Market memory m = s.getMarket(mid);
        if (!m.resolved) return;
        Vm.Wallet memory w = wallets[walletIdx % wallets.length];
        if (s.sharesOf(mid, w.addr, m.winner) == 0) return;
        vm.prank(w.addr);
        s.redeem(mid);
    }

    function _sign(Vm.Wallet memory w, UpDownSettlement.Order memory o) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(w.privateKey, s.orderDigest(o));
        return abi.encodePacked(r, ss, v);
    }
}
