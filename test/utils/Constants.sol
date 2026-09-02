// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/* ===================== ARBITRUM ONE (chainId 42161) ===================== */
//
// Mirrors the RAIN protocol's own `src/shared/Constants.sol` so both repos name
// the same on-chain objects identically. Tests that touch the fee buyback run
// against these REAL contracts under `--fork-url`, exactly as rain-contracts
// does — there are no mock routers, quoters or RAIN tokens.

/// @dev Arbitrum `USDT` — the settlement collateral and the fee asset.
address constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

/// @dev Arbitrum `WETH` — the intermediate hop of the buyback route.
address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

/// @dev Arbitrum `RAIN` — the token the protocol buys back and burns.
address constant RAIN_TOKEN = 0x25118290e6A5f4139381D072181157035864099d;

/// @dev Uniswap V3 canonical `SwapRouter`. NOT `SwapRouter02`: `ISwapRouter.exactInput`
///      carries the `deadline` field that V2 of the router dropped.
address constant SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

/// @dev Uniswap V3 `Quoter`, used to derive the burn's slippage floor on-chain.
address constant QUOTER = 0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6;

/// @dev RAIN/WETH pool fee tier (0.01%), matching the RAIN protocol's `RAIN_WETH_FEE`.
uint24 constant RAIN_WETH_FEE = 100;

/// @dev USDT/WETH pool fee tier (0.05%) — the deepest tier for the pair on Arbitrum One.
uint24 constant USDT_WETH_FEE = 500;

/// @dev Arbitrum One chain id. The buyback suite asserts it is forked against this.
uint256 constant ARBITRUM_ONE = 42161;

/// @dev secp256k1 group order — a private key must land in [1, N).
uint256 constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
