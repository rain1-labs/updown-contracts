// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {MockUSDT} from "../src/mocks/MockUSDT.sol";
import {MockAggregatorV3} from "../src/mocks/MockAggregatorV3.sol";

/// @notice Helper: deploy the throwaway testnet dependencies that the canonical
///         `Deploy.s.sol` expects to receive as env addresses but does NOT
///         create itself — a mintable USDT and the AggregatorV3 feeds.
///
///         Run BEFORE `Deploy.s.sol`, then copy the printed addresses into
///         `.env.sepolia` as USDT_ADDRESS / CHAINLINK_BTC_USD_FEED /
///         CHAINLINK_ETH_USD_FEED / CHAINLINK_SEQUENCER_FEED.
///
///   forge script script/DeployTestnetMocks.s.sol \
///       --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
///       --broadcast --private-key $DEPLOYER_PRIVATE_KEY
///
/// On the real-Data-Streams path, the BTC/ETH aggregators are LEGACY (strike +
/// resolution read from Chainlink Data Streams, not these feeds) but the
/// resolver constructor still stores them and `registerMarket` gates on
/// `priceFeeds[pair] != 0 || streamsFeedId[pair] != 0`, so they must be
/// non-zero addresses. We seed them with plausible prices anyway in case any
/// legacy view path reads them.
///
/// The sequencer mock is `MockAggregatorV3(0, 0, 1)`: answer=0 (sequencer UP)
/// with an ancient startedAt (=1) so the resolver's `_checkSequencer`
/// grace-period check passes. Use the REAL Arbitrum Sepolia sequencer uptime
/// feed instead if you want to exercise the real outage path.
contract DeployTestnetMocks is Script {
    // 8-decimal seed prices (legacy-feed scale). Streams strikes are 1e18 and
    // come from the DON; these are only a fallback for any legacy reader.
    int256 constant BTC_SEED_PRICE = 60_000e8;
    int256 constant ETH_SEED_PRICE = 3_000e8;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        MockUSDT usdt = new MockUSDT();
        MockAggregatorV3 btcFeed = new MockAggregatorV3(BTC_SEED_PRICE, 8, 0);
        MockAggregatorV3 ethFeed = new MockAggregatorV3(ETH_SEED_PRICE, 8, 0);
        // answer=0 => sequencer up; fixedStartedAt=1 => ancient => past grace.
        MockAggregatorV3 sequencer = new MockAggregatorV3(0, 0, 1);

        vm.stopBroadcast();

        console.log("=== Testnet mocks deployed ===");
        console.log("USDT_ADDRESS                =", address(usdt));
        console.log("CHAINLINK_BTC_USD_FEED      =", address(btcFeed));
        console.log("CHAINLINK_ETH_USD_FEED      =", address(ethFeed));
        console.log("CHAINLINK_SEQUENCER_FEED    =", address(sequencer));
        console.log("");
        console.log("Next: copy these into .env.sepolia, then run Deploy.s.sol.");
        console.log("Anyone can mint test USDT:  cast send <USDT> 'mint(address,uint256)' <to> <amount6dp>");
    }
}
