// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IVerifierProxy} from "../interfaces/IVerifierProxy.sol";

/// @notice DEMO-ONLY stateless Data Streams verifier stand-in. Trusts any
///         payload: decodes the (bytes32[3], bytes) wrapper and echoes the
///         inner ABI-encoded ReportV3. No DON signatures, no fees
///         (s_feeManager()==0 short-circuits the resolver's LINK path).
///         Stateless by design — the test-suite mock's setNextReport
///         pattern races when the dev-keeper (strike) and the resolver
///         service (resolve) submit concurrently against a live chain.
///         Never deploy where real value is at stake.
contract MockVerifierProxy is IVerifierProxy {
    function s_feeManager() external pure returns (address) {
        return address(0);
    }

    function verify(bytes calldata payload, bytes calldata) external payable returns (bytes memory) {
        (, bytes memory reportData) = abi.decode(payload, (bytes32[3], bytes));
        return reportData;
    }
}
