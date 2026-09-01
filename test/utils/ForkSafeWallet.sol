// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Vm} from "forge-std/Vm.sol";
import {SECP256K1_N} from "./Constants.sol";

/// @notice Derives signer wallets that are safe to use on a MAINNET FORK.
///
///         `vm.createWallet("alice")` derives its key from the label, and that key's address may
///         already hold code on the forked chain — `vm.createWallet("alice")` lands on
///         `0x3288…dac6`, which is a deployed contract on Arbitrum One. `SignatureChecker`
///         branches on `signer.code.length`, so such a signer is treated as an ERC-1271 account and
///         every EOA-signed order fails `InvalidSignature`. That is an artifact of the fork, not a
///         settlement bug, but it makes an otherwise-correct suite unrunnable with `--fork-url`.
///
///         Walking to the next key until the address is codeless costs nothing off-fork (the first
///         candidate always wins on a bare EVM, so unforked runs derive deterministically) and
///         makes the same suite valid against the live chain.
library ForkSafeWallet {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function derive(string memory name) internal returns (Vm.Wallet memory) {
        uint256 pk = (uint256(keccak256(bytes(name))) % (SECP256K1_N - 1)) + 1;
        while (vm.addr(pk).code.length != 0) {
            pk = (uint256(keccak256(abi.encode(pk))) % (SECP256K1_N - 1)) + 1;
        }
        return vm.createWallet(pk, name);
    }
}
