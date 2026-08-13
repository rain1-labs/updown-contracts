// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {MockUSDT} from "../src/mocks/MockUSDT.sol";
import {MockVerifierProxy} from "../src/mocks/MockVerifierProxy.sol";

/// @notice Helper: deploy the mock-DON demo dependencies that the canonical
///         `Deploy.s.sol` expects to receive as env addresses but does NOT
///         create itself — the stateless MockVerifierProxy (Data Streams
///         verifier stand-in; no Chainlink account / LINK / subscription
///         needed) and, when `USDT_ADDRESS` is unset, a mintable MockUSDT
///         as valueless demo collateral.
///
///         Run BEFORE `Deploy.s.sol`, then copy the printed addresses into
///         `.env` as CHAINLINK_VERIFIER_PROXY_ADDRESS / USDT_ADDRESS.
///
///   forge script script/DeployMockDon.s.sol \
///       --rpc-url $ARBITRUM_RPC_URL --broadcast
///
/// On this path the strike-side BTC/ETH aggregators and the sequencer feed
/// are the REAL Arbitrum One Chainlink addresses (see Deploy.s.sol header) —
/// only the Data Streams verifier is mocked. The off-chain report producer
/// lives in updown-backend (`STREAMS_MOCK=1`); see
/// `updown-demo/UPDOWN_DEMO_PLAN_MOCK_DON.md`.
contract DeployMockDon is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Reuse an existing collateral token when supplied; otherwise
        // deploy a fresh publicly-mintable MockUSDT.
        address existingUsdt;
        try vm.envAddress("USDT_ADDRESS") returns (address a) {
            existingUsdt = a;
        } catch {
            existingUsdt = address(0);
        }

        vm.startBroadcast(deployerKey);

        MockVerifierProxy verifier = new MockVerifierProxy();
        address usdt = existingUsdt;
        if (usdt == address(0)) {
            usdt = address(new MockUSDT());
        }

        vm.stopBroadcast();

        console.log("=== Mock-DON demo dependencies deployed ===");
        console.log("CHAINLINK_VERIFIER_PROXY_ADDRESS =", address(verifier));
        console.log("USDT_ADDRESS                     =", usdt);
        console.log("");
        console.log("Next: copy these into .env, then run Deploy.s.sol.");
        console.log("Anyone can mint demo USDT:  cast send <USDT> 'mint(address,uint256)' <to> <amount6dp>");
    }
}
