// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {UpDownSettlement} from "../src/UpDownSettlement.sol";

/// @title TransferOwnership
/// @notice Starts the Ownable2Step handoff of the LIVE stack to `OWNER_ADDRESS`.
///
///         The live stack is Settlement (`EXISTING_SETTLEMENT_ADDRESS`) plus whatever Resolver
///         and AutoCycler it currently points at — read from the Settlement itself, never from
///         a deployment record, so this always acts on what is genuinely live.
///
///         Usage (from the deployer / current owner key):
///           npm run handoff:simulate:prod     # dry run
///           npm run handoff:prod              # broadcasts transferOwnership on each contract
///
///         This only sets `pendingOwner`. Nothing changes hands until the new owner calls
///         `acceptOwnership()` on each contract — for a Safe, generate that batch with
///         `npm run safe:pending:<env>` and have the signers execute it. Until then the
///         deployer key is still the owner, so a wrong OWNER_ADDRESS cannot lock anyone out:
///         re-run with the corrected address and it simply overwrites `pendingOwner`.
///
///         Idempotent: contracts already owned by, or already pending to, OWNER_ADDRESS are
///         skipped. Any contract the deployer does not own aborts before broadcasting.
contract TransferOwnership is Script {
    function run() external {
        address settlementAddr = vm.envAddress("EXISTING_SETTLEMENT_ADDRESS");
        // envOr swallows the "0x" placeholder the env templates ship with.
        address newOwner = vm.envOr("OWNER_ADDRESS", address(0));
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        require(newOwner != address(0), "OWNER_ADDRESS is unset -- nothing to hand off to");
        require(newOwner != deployer, "OWNER_ADDRESS is the deployer itself");

        UpDownSettlement settlement = UpDownSettlement(settlementAddr);
        address[3] memory targets = [settlementAddr, settlement.resolver(), settlement.autocycler()];
        string[3] memory names = ["UpDownSettlement", "ChainlinkResolver", "UpDownAutoCycler"];

        console.log("=========================================================");
        console.log(" OWNERSHIP HANDOFF (Ownable2Step step 1 of 2)");
        console.log("=========================================================");
        console.log("  Deployer (current owner):", deployer);
        console.log("  New owner:               ", newOwner);
        if (newOwner.code.length == 0) {
            console.log("  [WARN]   OWNER_ADDRESS has no code -- an EOA, not a Safe. Fine for dev, not prod.");
        } else {
            console.log("  [ OK ]   OWNER_ADDRESS is a contract (Safe expected)");
        }
        console.log("");

        bool[3] memory todo;
        uint256 count;
        for (uint256 i; i < 3; ++i) {
            Ownable2Step c = Ownable2Step(targets[i]);
            address owner = c.owner();
            address pending = c.pendingOwner();
            console.log(string.concat("  ", names[i]), targets[i]);
            if (owner == newOwner) {
                console.log("           already owned by OWNER_ADDRESS -- skip");
                continue;
            }
            if (owner != deployer) {
                console.log("           owner is", owner);
                revert(string.concat(names[i], ": deployer is not the owner -- nothing was broadcast"));
            }
            if (pending == newOwner) {
                console.log("           already pending to OWNER_ADDRESS -- skip");
                continue;
            }
            if (pending != address(0)) {
                console.log("           overwriting a different pendingOwner:", pending);
            }
            todo[i] = true;
            count++;
        }
        console.log("");

        if (count == 0) {
            console.log("  Nothing to do. If the handoff is still pending, the new owner must acceptOwnership().");
            return;
        }

        vm.startBroadcast(deployerKey);
        for (uint256 i; i < 3; ++i) {
            if (!todo[i]) continue;
            Ownable2Step(targets[i]).transferOwnership(newOwner);
            console.log(string.concat("  transferOwnership -> ", names[i]), targets[i]);
        }
        vm.stopBroadcast();

        console.log("");
        console.log("  pendingOwner set on", count, "contract(s). The deployer is STILL the owner until");
        console.log("  OWNER_ADDRESS calls acceptOwnership() on each. Generate that batch with:");
        console.log("    npm run safe:pending:<dev|prod>");
        console.log("  then import the JSON into Safe{Wallet} > Transaction Builder (or pass --propose).");
    }
}
