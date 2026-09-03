// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {UpDownSettlement} from "../src/UpDownSettlement.sol";

/// @title UnredeemedSweep
/// @notice Read-only. Walks every market on a Settlement and prints the ones still holding
///         backing collateral (`marketRetained > 0`), with resolution state and winner. This is
///         what a retired Settlement is still holding for users who have not redeemed.
///
///         Usage:
///           SWEEP_SETTLEMENT=0x... forge script script/UnredeemedSweep.s.sol --rpc-url "$ARBITRUM_RPC_URL"
///           SWEEP_FROM / SWEEP_TO (optional) bound the market id range.
///
///         Output is one line per market: `market <id> retained <usdt6> resolved <bool> winner <n>`.
///         Feed the ids to script/redeem-for.mjs, which finds the holders from events and pushes
///         their winnings with the permissionless `redeemFor`.
contract UnredeemedSweep is Script {
    function run() external view {
        UpDownSettlement s = UpDownSettlement(vm.envAddress("SWEEP_SETTLEMENT"));
        uint256 from = vm.envOr("SWEEP_FROM", uint256(0));
        uint256 to = vm.envOr("SWEEP_TO", s.nextMarketId());

        console.log("Settlement:", address(s));
        console.log("USDT held:", s.usdt().balanceOf(address(s)));
        console.log("Scanning markets", from, "to", to);

        uint256 total;
        uint256 count;
        for (uint256 id = from; id < to; ++id) {
            uint256 retained = s.marketRetained(id);
            if (retained == 0) continue;
            (,,,,,, uint8 winner, bool resolved,,,) = s.markets(id);
            console.log(string.concat("market ", vm.toString(id), " retained ", vm.toString(retained), " resolved ", resolved ? "true" : "false", " winner ", vm.toString(winner)));
            total += retained;
            count++;
        }
        console.log("Markets holding collateral:", count);
        console.log("Sum of marketRetained:", total);
        console.log("feesAccrued:", s.feesAccrued());
    }
}
