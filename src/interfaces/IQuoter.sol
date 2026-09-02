// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Minimal Uniswap V3 `Quoter` surface used to derive the buyback's slippage floor.
///         Deliberately NOT `view`: the quoter simulates the swap and reverts internally to
///         return data, so it costs gas like any state-changing call. This mirrors the RAIN
///         protocol's `LibUtils.swapAndBurn`, which quotes on-chain for the same reason — the
///         burn is triggered by `resolve`, where no off-chain caller exists to supply a
///         trustworthy `amountOutMinimum`.
///
///         Arbitrum One: `0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6`.
interface IQuoter {
    function quoteExactInput(bytes memory path, uint256 amountIn) external returns (uint256 amountOut);
}
