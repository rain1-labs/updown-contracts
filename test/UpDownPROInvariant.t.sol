// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, StdInvariant, Vm} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {UpDownSettlement} from "../src/UpDownSettlement.sol";

/// @notice PR-O Step 2 audit-defending invariant fuzz.
///
/// Invariant under test:
///   usdt.balanceOf(settlement) == sum_over_unsettled(marketRetained[mid])
///
/// "Unsettled" here means `Market.settled == false`. Once
/// `withdrawSettlement(mid)` runs, the per-market `marketRetained[mid]` is
/// zeroed AND the USDT is transferred to the relayer, so the equality
/// holds at every external-call boundary.
///
/// The handler exposes the random surface to Foundry's invariant fuzzer:
/// complementaryMint, complementaryBurn, enterPosition, resolve,
/// withdrawSettlement. distributeWinnings is off-chain (relayer pays from
/// its wallet); it doesn't affect the contract's balance invariant.
///
/// The fuzzer's targetContract is the handler, not the settlement
/// directly — this keeps fill-input construction tractable (each handler
/// method picks valid inputs from a small param space the fuzzer can
/// search efficiently).
contract UpDownPROInvariant is StdInvariant, Test {
    bytes32 internal constant PAIR = keccak256("BTC/USD");

    ERC20Mock internal usdt;
    UpDownSettlement internal s;
    PROComplementaryHandler internal handler;

    address internal owner = address(this);
    address internal autocycler = makeAddr("auto-inv");
    address internal resolver = makeAddr("res-inv");
    address internal relayer = makeAddr("rel-inv");
    address internal treasury = makeAddr("treas-inv");

    function setUp() public {
        vm.warp(1_700_000_000);
        usdt = new ERC20Mock();
        s = new UpDownSettlement(usdt, owner, 70, 80);
        s.setAutocycler(autocycler);
        s.setResolver(resolver);
        s.setRelayer(relayer);
        s.setTreasury(treasury);

        handler = new PROComplementaryHandler(s, usdt, autocycler, resolver, relayer);
        usdt.mint(address(handler), 100_000_000e18);
        // Pre-create a fixed pool of markets the handler can index into.
        handler.bootstrap();

        // Constrain the fuzzer to handler methods (not raw settlement).
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.fuzzMint.selector;
        selectors[1] = handler.fuzzBurn.selector;
        selectors[2] = handler.fuzzFill.selector;
        selectors[3] = handler.fuzzResolve.selector;
        selectors[4] = handler.fuzzWithdraw.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice The conservation invariant. Sum of per-market retained
    ///         across all unsettled markets equals the contract's USDT
    ///         balance MINUS any accumulated dmm rebates owed (which
    ///         live in `dmmRebateAccumulated` and are paid from treasury,
    ///         not from the contract — so they don't appear here).
    ///
    ///         Settled markets contribute zero (marketRetained zeroed on
    ///         withdraw, USDT already sent to relayer).
    function invariant_balanceEqualsSumOfRetained() public view {
        uint256 sumRetained = 0;
        uint256 numMarkets = handler.marketCount();
        for (uint256 i = 0; i < numMarkets; i++) {
            uint256 mid = handler.marketIdAt(i);
            sumRetained += s.marketRetained(mid);
        }
        assertEq(
            usdt.balanceOf(address(s)),
            sumRetained,
            "balance(settlement) == sum(marketRetained over all markets)"
        );
    }

    /// @notice Per-market retained never goes negative — Solidity 0.8
    ///         underflow protection makes this true by construction inside
    ///         the contract, but checking here pins the property even if a
    ///         future PR adds `unchecked` blocks.
    function invariant_perMarketRetainedNonNegative() public view {
        uint256 numMarkets = handler.marketCount();
        for (uint256 i = 0; i < numMarkets; i++) {
            uint256 mid = handler.marketIdAt(i);
            // Use a uint256 read — if it ever overflowed via unchecked the
            // value would be enormous; check it's a plausible scale.
            uint256 r = s.marketRetained(mid);
            assertLe(r, 100_000_000e18, "retained stays within handler-funded ceiling");
        }
    }
}

/// @notice Action handler exposing fuzz-friendly methods. Owns its own
///         pool of pre-funded actors so the fuzzer doesn't waste sequences
///         on "no approval" reverts.
contract PROComplementaryHandler is Test {
    UpDownSettlement internal s;
    ERC20Mock internal usdt;
    address internal autocycler;
    address internal resolver;
    address internal relayer;

    uint256[] public markets;
    Vm.Wallet[] internal makers;
    address[] internal actors;

    constructor(
        UpDownSettlement _s,
        ERC20Mock _usdt,
        address _autocycler,
        address _resolver,
        address _relayer
    ) {
        s = _s;
        usdt = _usdt;
        autocycler = _autocycler;
        resolver = _resolver;
        relayer = _relayer;
    }

    function bootstrap() public {
        // 4 markets, 4 makers (with known keys for signing), 4 actors.
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(autocycler);
            uint256 mid = s.createMarket(PAIR_BYTES(), 3600, 50_000e8);
            markets.push(mid);
        }
        for (uint256 i = 0; i < 4; i++) {
            Vm.Wallet memory m = vm.createWallet(string(abi.encodePacked("m", i)));
            usdt.mint(m.addr, 1_000_000e18);
            vm.prank(m.addr);
            usdt.approve(address(s), type(uint256).max);
            makers.push(m);
        }
        for (uint256 i = 0; i < 4; i++) {
            address a = makeAddr(string(abi.encodePacked("actor", i)));
            usdt.mint(a, 1_000_000e18);
            vm.prank(a);
            usdt.approve(address(s), type(uint256).max);
            actors.push(a);
        }
    }

    function PAIR_BYTES() internal pure returns (bytes32) {
        return keccak256("INV-PAIR");
    }

    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    function marketIdAt(uint256 i) external view returns (uint256) {
        return markets[i];
    }

    // ── Fuzz actions ────────────────────────────────────────────────────

    function fuzzMint(uint256 marketIdx, uint256 actorIdx, uint256 amount) external {
        uint256 mid = markets[marketIdx % markets.length];
        address minter = actors[actorIdx % actors.length];
        // Skip resolved markets (would revert in normal use).
        UpDownSettlement.Market memory m = s.getMarket(mid);
        if (m.resolved || block.timestamp >= uint256(m.endTime)) return;
        amount = bound(amount, 1, 1_000e18);
        if (usdt.balanceOf(minter) < amount) return;
        vm.prank(relayer);
        s.complementaryMint(mid, amount, minter);
    }

    function fuzzBurn(uint256 marketIdx, uint256 actorIdx, uint256 amount) external {
        uint256 mid = markets[marketIdx % markets.length];
        address holder = actors[actorIdx % actors.length];
        UpDownSettlement.Market memory m = s.getMarket(mid);
        if (m.resolved) return;
        uint256 retained = s.marketRetained(mid);
        if (retained == 0) return;
        amount = bound(amount, 1, retained);
        vm.prank(relayer);
        s.complementaryBurn(mid, amount, holder);
    }

    function fuzzFill(
        uint256 marketIdx,
        uint256 makerIdx,
        uint256 takerIdx,
        uint8 option,
        uint16 priceBps,
        uint256 fillAmount,
        uint256 nonce
    ) external {
        uint256 mid = markets[marketIdx % markets.length];
        Vm.Wallet memory m = makers[makerIdx % makers.length];
        address taker = actors[takerIdx % actors.length];
        UpDownSettlement.Market memory mkt = s.getMarket(mid);
        if (mkt.resolved || block.timestamp >= uint256(mkt.endTime)) return;

        option = uint8(bound(uint256(option), 1, 2));
        priceBps = uint16(bound(uint256(priceBps), 1, 9999));
        fillAmount = bound(fillAmount, 1, 100e18);

        uint256 cashPart = (uint256(priceBps) * fillAmount) / 10000;
        uint256 mintBackingDelta = fillAmount - cashPart;
        // Need enough backing or the fill reverts (which we treat as a
        // valid "skip"); to maximize coverage, ensure backing first by
        // best-effort pre-minting if needed.
        if (s.marketRetained(mid) < mintBackingDelta) {
            uint256 short = mintBackingDelta - s.marketRetained(mid);
            address backer = actors[0];
            if (usdt.balanceOf(backer) >= short) {
                vm.prank(relayer);
                s.complementaryMint(mid, short, backer);
            } else {
                return;
            }
        }

        UpDownSettlement.Order memory order = UpDownSettlement.Order({
            maker: m.addr,
            market: mid,
            option: uint256(option),
            side: 0, // BUY-side maker — buyer is the maker
            orderType: 0,
            price: uint256(priceBps),
            amount: fillAmount,
            nonce: nonce,
            expiry: block.timestamp + 3600
        });
        bytes32 digest = s.orderDigest(order);
        (uint8 v, bytes32 r, bytes32 sSig) = vm.sign(m.privateKey, digest);
        bytes memory sig = abi.encodePacked(r, sSig, v);

        // Ensure buyer can afford the cash + fees. Set sellerReceives =
        // cashPart, no fees to keep the fuzz tractable.
        if (usdt.balanceOf(m.addr) < cashPart) return;

        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            order: order,
            signature: sig,
            marketId: mid,
            option: option,
            fillAmount: fillAmount,
            taker: taker,
            sellerReceives: cashPart,
            platformFee: 0,
            makerFee: 0,
            makerFeeRecipient: address(0)
        });
        vm.prank(relayer);
        s.enterPosition(f);
    }

    function fuzzResolve(uint256 marketIdx, uint8 winner) external {
        uint256 mid = markets[marketIdx % markets.length];
        UpDownSettlement.Market memory mkt = s.getMarket(mid);
        if (mkt.resolved) return;
        winner = uint8(bound(uint256(winner), 1, 2));
        // Need to be past endTime; warp forward enough.
        if (block.timestamp < uint256(mkt.endTime)) {
            vm.warp(uint256(mkt.endTime) + 1);
        }
        vm.prank(resolver);
        s.resolve(mid, 60_000e8, winner);
    }

    function fuzzWithdraw(uint256 marketIdx) external {
        uint256 mid = markets[marketIdx % markets.length];
        UpDownSettlement.Market memory mkt = s.getMarket(mid);
        if (!mkt.resolved || mkt.settled) return;
        vm.prank(relayer);
        s.withdrawSettlement(mid);
    }
}
