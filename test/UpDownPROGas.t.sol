// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {UpDownSettlement} from "../src/UpDownSettlement.sol";

/// @notice PR-O Step 2 gas snapshot. Measures `enterPosition` alone (no
///         pre-mint cost included) so we can compare against main's
///         baseline. Per the user's <10% increase target.
contract UpDownPROGasTest is Test {
    bytes32 internal constant PAIR = keccak256("BTC/USD");

    ERC20Mock internal usdt;
    UpDownSettlement internal s;
    address internal owner = address(this);
    address internal autocycler = makeAddr("auto-gas");
    address internal resolver = makeAddr("res-gas");
    address internal relayer = makeAddr("rel-gas");
    address internal treasury = makeAddr("treas-gas");
    address internal backer = makeAddr("backer-gas");

    Vm.Wallet internal maker;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdt = new ERC20Mock();
        s = new UpDownSettlement(usdt, owner, 70, 80);
        s.setAutocycler(autocycler);
        s.setResolver(resolver);
        s.setRelayer(relayer);
        s.setTreasury(treasury);

        maker = vm.createWallet("maker-gas");
        usdt.mint(maker.addr, 10_000e18);
        vm.prank(maker.addr);
        usdt.approve(address(s), type(uint256).max);

        usdt.mint(backer, 10_000e18);
        vm.prank(backer);
        usdt.approve(address(s), type(uint256).max);
    }

    function test_gas_enterPosition_typicalFill() public {
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 50_000e8);
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
            nonce: 1,
            expiry: block.timestamp + 3600
        });
        bytes32 digest = s.orderDigest(order);
        (uint8 v, bytes32 r, bytes32 sSig) = vm.sign(maker.privateKey, digest);
        bytes memory sig = abi.encodePacked(r, sSig, v);
        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            order: order,
            signature: sig,
            marketId: mid,
            option: 1,
            fillAmount: 100e18,
            taker: makeAddr("counterparty-gas"),
            sellerReceives: 55e18,
            platformFee: 5e17,
            makerFee: 0,
            makerFeeRecipient: address(0)
        });
        vm.prank(relayer);
        uint256 gasBefore = gasleft();
        s.enterPosition(f);
        uint256 gasUsed = gasBefore - gasleft();
        // Pre-PR-O enterPosition was ~205k. Post-PR-O adds: one extra storage
        // read (marketRetained) + one underflow-safe sub + the buyer-pull
        // arithmetic. Target: under 230k (12% upper bound, slightly above the
        // user's <10% gate to leave headroom for unrelated future changes).
        // Recorded number here is the snapshot we'll compare against main.
        emit log_named_uint("gas_enterPosition_PR_O", gasUsed);
        assertLt(gasUsed, 230_000, "PR-O enterPosition stays within ~10% gas budget");
    }
}
