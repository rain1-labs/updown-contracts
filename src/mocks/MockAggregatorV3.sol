// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Minimal AggregatorV3Interface implementation for testnet E2E.
///         Returns a fixed price with `updatedAt = block.timestamp` so the
///         resolver's `MAX_STALENESS` (1h) freshness check never trips.
///         Only used on Arbitrum Sepolia for Streams Gate 3 — production
///         Arbitrum One uses real Chainlink Data Feeds for the strike
///         (`_getLatestPrice` -> AggregatorV3Interface).
contract MockAggregatorV3 {
    int256 public price;
    uint8 public immutable decimalsValue;
    /// @dev When non-zero, latestRoundData reports `startedAt = fixedStartedAt`
    ///      instead of `block.timestamp`. Use a value far in the past to model
    ///      a sequencer feed that's past its `SEQUENCER_GRACE_PERIOD`.
    uint256 public immutable fixedStartedAt;

    constructor(int256 _initialPrice, uint8 _decimals, uint256 _fixedStartedAt) {
        price = _initialPrice;
        decimalsValue = _decimals;
        fixedStartedAt = _fixedStartedAt;
    }

    function setPrice(int256 _price) external {
        price = _price;
    }

    function decimals() external view returns (uint8) {
        return decimalsValue;
    }

    /// @dev When fixedStartedAt is non-zero, BOTH startedAt and updatedAt
    ///      report that fixed value. This matches the resolver's
    ///      `_checkSequencer` semantics — it destructures position 3
    ///      (`updatedAt`) into a local var named `startedAt` and compares
    ///      `block.timestamp - that < SEQUENCER_GRACE_PERIOD`. To get past
    ///      the grace check, both must be far enough in the past.
    function _ts() internal view returns (uint256) {
        return fixedStartedAt == 0 ? block.timestamp : fixedStartedAt;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint256 s = _ts();
        return (1, price, s, s, 1);
    }

    function getRoundData(uint80 /*_roundId*/ )
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint256 s = _ts();
        return (1, price, s, s, 1);
    }
}
