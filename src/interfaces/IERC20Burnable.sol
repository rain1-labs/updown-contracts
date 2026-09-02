// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice `ERC20Burnable.burn` — the single function the buyback needs from the token it
///         retires. The buyback deliberately does NOT fall back to a dead-address transfer:
///         a token without a real `burn` must fail loudly at configuration time rather than
///         silently leaving the bought-back supply parked at `0x…dEaD` while the protocol
///         reports it as burned.
interface IERC20Burnable {
    function burn(uint256 amount) external;
}
