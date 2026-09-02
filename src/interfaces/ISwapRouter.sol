// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Minimal Uniswap V3 `SwapRouter` surface used by the fee buyback-and-burn.
///         Only `exactInput` is declared: the buyback always spends a known USDT amount
///         and takes whatever the pool gives, floored by `amountOutMinimum`. The
///         multi-hop `path` form is used (rather than `exactInputSingle`) so ops can
///         route USDT → WETH → RAIN when no direct USDT/RAIN pool has depth, without
///         a contract upgrade.
///
///         Arbitrum One: `0xE592427A0AEce92De3Edee1F18E0157C05861564` (canonical
///         `SwapRouter`, which carries the `deadline` field this interface relies on;
///         `SwapRouter02` drops it and is NOT ABI-compatible here).
interface ISwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}
