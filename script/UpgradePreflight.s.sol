// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {UpDownSettlement} from "../src/UpDownSettlement.sol";
import {UpDownAutoCycler} from "../src/UpDownAutoCycler.sol";
import {ChainlinkResolver} from "../src/ChainlinkResolver.sol";
import {IUpDownSettlement} from "../src/interfaces/IUpDownSettlement.sol";

/// @title UpgradePreflight
/// @notice Read-only go/no-go gate for a Resolver + AutoCycler redeploy against an
///         existing Settlement (`Deploy.s.sol` migration mode).
///
///         Broadcasts nothing. Run it, read the verdict, and only then run
///         `npm run deploy:prod`.
///
///         The hazard it exists to prevent: `Deploy.s.sol` calls
///         `settlement.setResolver(newResolver)` unconditionally. The instant that
///         lands, the OLD resolver fails Settlement's `onlyResolver` check and the new
///         resolver's `markets` mapping is empty — so any market still open at that
///         moment can be settled by neither, and whatever collateral sits in it is
///         stuck until an operator re-registers it by hand. Draining first is the whole
///         safety property of the upgrade, and nothing in the deploy path enforces it.
///
///         It also closes the ownership gap `Deploy.s.sol` documents but declines to
///         check ("we don't pre-verify here"), and validates the incoming stream ids
///         against the schemas the resolver can actually decode — the check that would
///         have caught the v2 TWAP ids before they reached a live `configureStreamsFeed`.
///
///         Usage:
///           set -a && . ./.env.prod && set +a && \
///             forge script script/UpgradePreflight.s.sol --rpc-url "$ARBITRUM_RPC_URL"
///
///         The old Resolver and AutoCycler are read from Settlement's own pointers
///         rather than env vars, so the script always inspects the stack that is
///         genuinely live rather than the one someone believes is live.
contract UpgradePreflight is Script {
    bytes32 constant BTCUSD = keccak256("BTC/USD");
    bytes32 constant ETHUSD = keccak256("ETH/USD");

    uint16 constant SCHEMA_V2 = 2;
    uint16 constant SCHEMA_V3 = 3;

    uint256 private failures;
    uint256 private warnings;

    function pass(string memory what) internal pure {
        console.log(string.concat("  [ OK ]   ", what));
    }

    function fail(string memory what) internal {
        failures++;
        console.log(string.concat("  [FAIL]   ", what));
    }

    function warn(string memory what) internal {
        warnings++;
        console.log(string.concat("  [WARN]   ", what));
    }

    function run() external {
        address settlementAddr = vm.envAddress("EXISTING_SETTLEMENT_ADDRESS");
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        UpDownSettlement settlement = UpDownSettlement(settlementAddr);

        // The live stack, straight from Settlement.
        address oldResolverAddr = settlement.resolver();
        address oldCyclerAddr = settlement.autocycler();
        UpDownAutoCycler oldCycler = UpDownAutoCycler(oldCyclerAddr);
        ChainlinkResolver oldResolver = ChainlinkResolver(oldResolverAddr);

        console.log("=========================================================");
        console.log(" UPGRADE PREFLIGHT  (read-only, nothing is broadcast)");
        console.log("=========================================================");
        console.log("  Settlement (kept):   ", settlementAddr);
        console.log("  Resolver (replaced): ", oldResolverAddr);
        console.log("  Cycler   (replaced): ", oldCyclerAddr);
        console.log("  Deployer:            ", deployer);
        console.log("");

        _checkOwnership(settlement, oldResolver, oldCycler, deployer);
        _checkDrain(settlement, oldCycler);
        _checkNewStreamIds();
        _checkChainlinkWiring(oldResolver);
        _checkEnv();

        console.log("");
        console.log("=========================================================");
        if (failures > 0) {
            console.log("  NO-GO --", failures, "blocking issue(s)");
            console.log("  Resolve every [FAIL] before running deploy:prod.");
            console.log("=========================================================");
            revert("preflight failed");
        }
        if (warnings > 0) {
            console.log("  GO (with", warnings, "warning(s) -- read them)");
        } else {
            console.log("  GO -- safe to run: npm run deploy:prod");
        }
        console.log("=========================================================");
    }

    /// @dev Every owner-gated call in `Deploy.s.sol` runs as `deployer`. If the
    ///      deployer is not the owner, the deploy reverts mid-broadcast — after the new
    ///      Resolver and Cycler have already been created and paid for.
    function _checkOwnership(
        UpDownSettlement settlement,
        ChainlinkResolver oldResolver,
        UpDownAutoCycler oldCycler,
        address deployer
    ) internal {
        console.log("-- Ownership --");
        address owner = settlement.owner();
        if (owner == deployer) {
            pass("deployer owns Settlement");
        } else {
            fail("deployer is NOT Settlement owner -- setResolver/setAutocycler will revert");
            console.log("           settlement.owner() =", owner);
        }

        if (settlement.pendingOwner() != address(0)) {
            warn("Settlement has a pendingOwner -- an Ownable2Step handoff is mid-flight");
        }

        // Informational: the outgoing contracts stay owned by whoever holds them. That
        // is fine (they become inert), but a LINK balance left on the old resolver is
        // only recoverable through its own `withdrawLink`.
        if (oldResolver.owner() != deployer) {
            warn("deployer does not own the OLD resolver -- withdrawLink would be unavailable");
        }
        if (oldCycler.owner() != deployer) {
            warn("deployer does not own the OLD cycler -- cannot removePair/deprecate it");
        }
        console.log("");
    }

    /// @dev The core gate. Walks the old cycler's active set and asks Settlement
    ///      directly whether each market resolved — `activeMarketCount` alone is not
    ///      evidence, because `_pruneResolved` only runs inside `performUpkeep`, which
    ///      stops firing once every pair is removed.
    function _checkDrain(UpDownSettlement settlement, UpDownAutoCycler oldCycler) internal {
        console.log("-- Drain (the orphaning gate) --");

        uint256 cycling = oldCycler.cyclingPairCount();
        if (cycling == 0) {
            pass("old cycler has no cycling pairs -- no new markets being created");
        } else {
            fail("old cycler is STILL CYCLING pairs -- call removePair for each first");
            console.log("           cyclingPairCount() =", cycling);
        }

        uint256 n = oldCycler.activeMarketCount();
        console.log("           activeMarketCount() =", n);

        uint256 unresolved;
        uint256 exposed;
        for (uint256 i; i < n; ++i) {
            (uint256 marketId,,) = oldCycler.activeMarkets(i);
            IUpDownSettlement.Market memory m = IUpDownSettlement(address(settlement)).getMarket(marketId);
            if (!m.resolved) {
                unresolved++;
                uint256 notional = uint256(m.cashUpFlow) + uint256(m.cashDownFlow);
                if (notional > 0) exposed++;
                console.log("           unresolved market", marketId, "notional(6dp):", notional);
            }
        }

        if (unresolved == 0) {
            pass("every market in the active set has resolved -- nothing to orphan");
            if (n > 0) {
                warn("active set is non-empty but fully resolved -- call pruneResolved() to tidy");
            }
        } else {
            fail("UNRESOLVED markets would be orphaned by setResolver");
            console.log("           unresolved:", unresolved, "of which carrying collateral:", exposed);
            console.log("           Wait for them to settle, then call pruneResolved().");
        }
        console.log("");
    }

    /// @dev Validates the stream ids the new resolver will be configured with. The
    ///      schema lives in the leading two bytes; anything the resolver cannot decode
    ///      must be caught here, not at the first captureStrike.
    function _checkNewStreamIds() internal {
        console.log("-- Data Streams ids --");
        bytes32 btc = vm.envBytes32("STREAMS_FEED_ID_BTC_USD");
        bytes32 eth = vm.envBytes32("STREAMS_FEED_ID_ETH_USD");
        _checkOneStreamId("BTC/USD", btc);
        _checkOneStreamId("ETH/USD", eth);
        if (btc == eth) fail("BTC and ETH stream ids are identical -- one pair would price off the other");
        console.log("");
    }

    function _checkOneStreamId(string memory label, bytes32 feedId) internal {
        if (feedId == bytes32(0)) {
            fail(string.concat(label, ": stream id is unset -- markets would open and never settle"));
            return;
        }
        uint16 schema = uint16(bytes2(feedId));
        if (schema == SCHEMA_V2 || schema == SCHEMA_V3) {
            console.log(string.concat("  [ OK ]   ", label, " schema v"), schema);
            console.logBytes32(feedId);
        } else {
            fail(string.concat(label, ": unsupported report schema -- configureStreamsFeed would revert"));
            console.log("           schema prefix =", schema);
            console.logBytes32(feedId);
        }
    }

    /// @dev The new resolver is constructed from env values. If any of them drift from
    ///      what the live resolver actually uses, the upgrade silently repoints at
    ///      different Chainlink infrastructure.
    function _checkChainlinkWiring(ChainlinkResolver oldResolver) internal {
        console.log("-- Chainlink wiring (env vs live) --");

        address envProxy = vm.envAddress("CHAINLINK_VERIFIER_PROXY_ADDRESS");
        address liveProxy = address(oldResolver.verifierProxy());
        if (envProxy == liveProxy) {
            pass("VerifierProxy matches the live resolver");
        } else {
            fail("VerifierProxy in env differs from the live resolver's");
            console.log("           env :", envProxy);
            console.log("           live:", liveProxy);
        }

        address envLink = vm.envAddress("CHAINLINK_LINK_TOKEN_ADDRESS");
        address liveLink = address(oldResolver.linkToken());
        if (envLink == liveLink) {
            pass("LINK token matches the live resolver");
        } else {
            fail("LINK token in env differs from the live resolver's");
            console.log("           env :", envLink);
            console.log("           live:", liveLink);
        }

        address envSeq = vm.envAddress("CHAINLINK_SEQUENCER_FEED");
        address liveSeq = address(oldResolver.sequencerFeed());
        if (envSeq == liveSeq) {
            pass("sequencer uptime feed matches the live resolver");
        } else {
            warn("sequencer feed in env differs from the live resolver's");
            console.log("           env :", envSeq);
            console.log("           live:", liveSeq);
        }

        uint256 oldLink = IERC20(liveLink).balanceOf(address(oldResolver));
        if (oldLink > 0) {
            warn("old resolver holds LINK -- withdrawLink before abandoning it");
            console.log("           balance (wei):", oldLink);
        } else {
            pass("old resolver holds no LINK -- nothing stranded");
        }
        console.log("");
    }

    /// @dev Fail fast on anything `Deploy.s.sol` reads mid-broadcast. A missing var
    ///      there aborts after the new contracts are already on chain.
    function _checkEnv() internal {
        console.log("-- Deploy env --");
        _requireAddr("RELAYER_ADDRESS");
        _requireAddr("TREASURY_ADDRESS");
        _requireAddr("USDT_ADDRESS");
        _requireAddr("CHAINLINK_BTC_USD_FEED");
        _requireAddr("CHAINLINK_ETH_USD_FEED");

        try vm.envAddress("KEEPER_FORWARDER_ADDRESS") returns (address fwd) {
            if (fwd == address(0)) {
                warn("KEEPER_FORWARDER_ADDRESS is zero -- defaults to RELAYER_ADDRESS, collapsing keeper and relayer");
            } else {
                pass("KEEPER_FORWARDER_ADDRESS set");
            }
        } catch {
            warn("KEEPER_FORWARDER_ADDRESS unset -- defaults to RELAYER_ADDRESS, collapsing keeper and relayer");
        }
        console.log("");
    }

    function _requireAddr(string memory name) internal {
        try vm.envAddress(name) returns (address a) {
            if (a == address(0)) fail(string.concat(name, " is the zero address"));
            else pass(name);
        } catch {
            fail(string.concat(name, " is unset"));
        }
    }
}
