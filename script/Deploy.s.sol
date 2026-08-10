// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {ChainlinkResolver} from "../src/ChainlinkResolver.sol";
import {UpDownAutoCycler} from "../src/UpDownAutoCycler.sol";
import {UpDownSettlement} from "../src/UpDownSettlement.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deploys UpDownSettlement, ChainlinkResolver, and UpDownAutoCycler; wires roles.
///         Run with:
///
///   forge script script/Deploy.s.sol --rpc-url $ARBITRUM_RPC_URL --broadcast --verify
///
/// 2026-05-16 Streams-strike migration: this script can either do a full
/// fresh deploy (no env override) OR preserve an existing Settlement and
/// redeploy only Resolver + AutoCycler against it. Migration mode is
/// triggered by setting `EXISTING_SETTLEMENT_ADDRESS` env var. In that
/// path, Settlement deploy is SKIPPED, and after Resolver + AutoCycler
/// are deployed the script calls `settlement.setResolver(newResolver)` +
/// `settlement.setAutocycler(newCycler)` from the deployer (owner) to
/// rewire the existing Settlement's pointers. All historic markets +
/// ThinWallet allowances against the existing Settlement stay intact.
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY            — the deployer/owner key
///   ARBITRUM_RPC_URL                — Arbitrum One RPC
///   USDT_ADDRESS                    — USDT token on the target network
///   RELAYER_ADDRESS                 — relayer wallet that calls enterPosition / mint / redeemFor
///   TREASURY_ADDRESS                — treasury EOA that receives platformFee + funds rebate claims
///   STREAMS_FEED_ID_BTC_USD         — Data Streams feed id for BTC/USD
///   STREAMS_FEED_ID_ETH_USD         — Data Streams feed id for ETH/USD
///
///     Both feed ids are REQUIRED and configured inside the broadcast below.
///     They used to be a post-deploy manual step, which was a live footgun:
///     `registerMarket` gates on `priceFeeds[pair] != 0 || streamsFeedId[pair] != 0`
///     and this script populates `priceFeeds` from the constructor, so the gate
///     PASSES with no Streams config. The cycler would then happily open markets
///     and take user collateral while `resolve`/`captureStrike` — which read
///     `streamsFeedId`, not `priceFeeds` — could never settle them. Since
///     `redeem` reverts `NotResolved` and `burn` needs a complete set before
///     `endTime`, that collateral would be permanently locked. Fail fast here
///     instead: an unset feed id aborts the deploy.
///
/// Optional env vars (deploy shape):
///   PRE_START_WINDOW_SEC            — cycler pre-listing window, default 300.
///                                     NOTE: the contract default is 0 and the
///                                     constructor does not set it, but both live
///                                     deployments run 300 (set by hand post-deploy).
///                                     Defaulting to 300 here stops a fresh deploy
///                                     from silently regressing to 0, which would
///                                     publish markets only at the slot boundary and
///                                     leave market makers no pre-positioning window.
///   KEEPER_FORWARDER_ADDRESS        — cycler forwarder, default RELAYER_ADDRESS.
///                                     Prod drives the keeper from a wallet distinct
///                                     from the relayer; dev shares one.
///   OWNER_ADDRESS                   — when set, transfers ownership of all three
///                                     contracts to it as the last broadcast step.
///                                     All three are Ownable2Step, so this only sets
///                                     `pendingOwner` — the target must call
///                                     `acceptOwnership()` to complete it. No lockout
///                                     risk if the address is wrong.
///   DEPLOY_LABEL                    — names the JSON deployment record, e.g. "dev" /
///                                     "prod". Both environments share chain id 42161,
///                                     so the record is keyed on this rather than on
///                                     chainid to stop dev clobbering prod.
///
/// Optional env var (migration mode):
///   EXISTING_SETTLEMENT_ADDRESS     — when set, skip Settlement deploy and
///                                     redeploy only Resolver + AutoCycler
///                                     against this existing Settlement.
///                                     Caller must be the existing
///                                     Settlement's owner (deployer key
///                                     matches).
///   CHAINLINK_VERIFIER_PROXY_ADDRESS — Data Streams VerifierProxy on the target network
///                                     (Arbitrum Sepolia testnet: 0x2ff010DEbC1297f19579B4246cad07bd24F2488A)
///   CHAINLINK_LINK_TOKEN_ADDRESS    — LINK token address on the target network
///                                     (Arbitrum One: 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4)
///   CHAINLINK_BTC_USD_FEED          — BTC/USD AggregatorV3 (strike-side, push-based)
///                                     Arbitrum One:     0x6ce185860a4963106506C203335A2910413708e9
///                                     Arbitrum Sepolia: deploy `MockAggregatorV3` and supply its addr.
///   CHAINLINK_ETH_USD_FEED          — ETH/USD AggregatorV3 (strike-side)
///                                     Arbitrum One:     0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612
///                                     Arbitrum Sepolia: deploy `MockAggregatorV3` and supply its addr.
///   CHAINLINK_SEQUENCER_FEED        — L2 sequencer uptime feed
///                                     Arbitrum One:     0xFdB631F5EE196F0ed6FAa767959853A9F217697D
///                                     Arbitrum Sepolia: deploy `MockAggregatorV3(0, 0, 1)` (answer=0, ancient updatedAt).
contract DeployUpDown is Script {

    // ── Pair IDs ────────────────────────────────────────────────────────
    bytes32 constant BTCUSD = keccak256("BTC/USD");
    bytes32 constant ETHUSD = keccak256("ETH/USD");

    // ── Rebate budget defaults (F-2026-17779 rolling treasury circuit-breaker) ──
    // Cap rebate claims to $5,000 / 7-day window by default. Ops tunes via
    // `setRebateBudget`. A $0 budget would disable rebates entirely (fail-safe),
    // so the deploy seeds a working non-zero default.
    uint256 constant REBATE_BUDGET_PER_WINDOW = 5_000_000_000; // 5,000 USDT (6 decimals)
    uint256 constant REBATE_WINDOW_DURATION = 7 days;

    /// @dev Matches the value live on both dev and prod. Capped at
    ///      `UpDownAutoCycler.PRE_START_WINDOW_MAX` (300).
    uint256 constant PRE_START_WINDOW_DEFAULT = 300;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address usdt = vm.envAddress("USDT_ADDRESS");
        address relayer = vm.envAddress("RELAYER_ADDRESS");
        // PR-5-bundle (P0-7): treasury must be configured pre-broadcast or
        // any fill with platformFee > 0 reverts on TreasuryNotConfigured.
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        // 2026-05-13 Data Streams swap: resolver constructor now also
        // takes the VerifierProxy + LINK token addresses. Both must be
        // env-supplied to avoid hardcoding per-network values in the
        // script. On Arbitrum One, LINK = 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4.
        address verifierProxy = vm.envAddress("CHAINLINK_VERIFIER_PROXY_ADDRESS");
        address linkToken = vm.envAddress("CHAINLINK_LINK_TOKEN_ADDRESS");
        // Strike-side feeds + sequencer feed. Env-driven so the same
        // script targets both Arbitrum One (real Chainlink addresses) and
        // Arbitrum Sepolia (MockAggregatorV3 deploys) — see header doc
        // for the canonical addresses on each network.
        address btcUsdFeed = vm.envAddress("CHAINLINK_BTC_USD_FEED");
        address ethUsdFeed = vm.envAddress("CHAINLINK_ETH_USD_FEED");
        address sequencerFeed = vm.envAddress("CHAINLINK_SEQUENCER_FEED");

        // Streams feed ids — required; see the header note on why an unset id
        // must abort rather than defer to a post-deploy checklist.
        bytes32 btcStreamsFeedId = vm.envBytes32("STREAMS_FEED_ID_BTC_USD");
        bytes32 ethStreamsFeedId = vm.envBytes32("STREAMS_FEED_ID_ETH_USD");

        uint256 preStartWindowSec = vm.envOr("PRE_START_WINDOW_SEC", PRE_START_WINDOW_DEFAULT);
        // Defaults to the relayer, preserving the previous behaviour for dev.
        address keeperForwarder = vm.envOr("KEEPER_FORWARDER_ADDRESS", relayer);
        address newOwner = vm.envOr("OWNER_ADDRESS", address(0));

        // Migration mode: EXISTING_SETTLEMENT_ADDRESS preserves historic
        // markets + ThinWallet allowances. New deploy when unset.
        address existingSettlement;
        try vm.envAddress("EXISTING_SETTLEMENT_ADDRESS") returns (address a) {
            existingSettlement = a;
        } catch {
            existingSettlement = address(0);
        }

        console.log("Deployer:", deployer);
        console.log("USDT:", usdt);
        console.log("Relayer:", relayer);
        console.log("Treasury:", treasury);
        if (existingSettlement != address(0)) {
            console.log("Migration mode -- reusing Settlement:", existingSettlement);
        } else {
            console.log("Fresh deploy mode -- Settlement will be created");
        }

        vm.startBroadcast(deployerKey);

        UpDownSettlement settlement;
        if (existingSettlement != address(0)) {
            // Reuse the existing Settlement. Caller is responsible for
            // ensuring `deployer` == existing settlement.owner() — if not,
            // the setResolver/setAutocycler calls below will revert
            // OnlyOwner from inside the broadcast. We don't pre-verify
            // here because vm.broadcast eats the static call cleanly and
            // any failure surfaces in the broadcast simulator.
            settlement = UpDownSettlement(existingSettlement);
            console.log("UpDownSettlement (existing):", address(settlement));
        } else {
            // F-2026-17746: fee bps removed from the constructor — fees are signed-and-capped
            // per order, not derived from on-chain bps.
            settlement = new UpDownSettlement(IERC20(usdt), deployer);
            console.log("UpDownSettlement (fresh):", address(settlement));
        }

        ChainlinkResolver resolver = new ChainlinkResolver(
            deployer,
            sequencerFeed,
            BTCUSD,
            btcUsdFeed,
            ETHUSD,
            ethUsdFeed,
            address(settlement),
            verifierProxy,
            linkToken
        );
        console.log("ChainlinkResolver:", address(resolver));
        // Post-deploy ops: ops must (a) `configureStreamsFeed(pairId, feedId)`
        // for each pair once the DON allow-lists this resolver address,
        // and (b) topup the resolver with LINK for verify fees (default
        // floor 5 LINK per the OPS_RUNBOOK).

        UpDownAutoCycler cycler = new UpDownAutoCycler(deployer, address(resolver), address(settlement));
        console.log("UpDownAutoCycler:", address(cycler));

        // Rewire Settlement pointers. In migration mode, this overwrites
        // the OLD resolver + autocycler refs that point at the orphaned
        // pre-Streams-strike contracts. The relayer + treasury are
        // unchanged across migrations but we set them idempotently to
        // preserve a single source of truth in the deploy script.
        settlement.setResolver(address(resolver));
        settlement.setAutocycler(address(cycler));
        settlement.setRelayer(relayer);
        settlement.setTreasury(treasury);
        // F-2026-17779: seed the rolling rebate budget circuit-breaker.
        settlement.setRebateBudget(REBATE_BUDGET_PER_WINDOW, REBATE_WINDOW_DURATION);

        // F-2026-17760: the cycler captures strikes; the relayer (resolver service) submits
        // resolutions. Both must be authorized now that resolve/captureStrike are access-gated.
        resolver.setAuthorizedCaller(address(cycler), true);
        resolver.setAuthorizedCaller(relayer, true);

        // Bind each pair to its Data Streams feed id. This is what the
        // strike/resolve lifecycle actually reads — without it the deploy
        // produces a system that opens markets it can never settle. Done
        // in-broadcast so a missing env var fails the deploy rather than a
        // post-deploy checklist item.
        resolver.configureStreamsFeed(BTCUSD, btcStreamsFeedId);
        resolver.configureStreamsFeed(ETHUSD, ethStreamsFeedId);

        // F-2026-17726: gate performUpkeep to the keeper. The stopgap cron drives the cycler from
        // the keeper wallet (== relayer on dev, a separate wallet on prod); once Chainlink
        // Automation is registered, ops updates this to the Automation forwarder address.
        cycler.setForwarder(keeperForwarder);

        // Whitelist + start cycling both pairs. In migration mode, the
        // NEW cycler has a fresh _cyclingPairs[] state and needs the same
        // whitelist as the orphaned old cycler.
        cycler.addPair(BTCUSD);
        cycler.addPair(ETHUSD);

        // Pre-listing window. Not set by the constructor (defaults to 0), so
        // this must be explicit or a fresh deploy silently regresses.
        cycler.setPreStartWindowSec(preStartWindowSec);

        // Ownership handoff LAST — every owner-gated call above must land while
        // the deployer still holds the role. Ownable2Step: this only sets
        // `pendingOwner`; the target completes it with `acceptOwnership()`.
        if (newOwner != address(0) && newOwner != deployer) {
            settlement.transferOwnership(newOwner);
            resolver.transferOwnership(newOwner);
            cycler.transferOwnership(newOwner);
        }

        vm.stopBroadcast();

        uint256 ts = block.timestamp;
        console.log("");
        console.log("Clock-aligned market boundaries at deploy block.timestamp:");
        console.log("  5m slot start (unix):", (ts / 300) * 300);
        console.log("  15m slot start (unix):", (ts / 900) * 900);
        console.log("  60m slot start (unix):", (ts / 3600) * 3600);
        console.log("");
        console.log("=== Deployment complete ===");
        console.log("UpDownSettlement:", address(settlement));
        console.log("ChainlinkResolver:", address(resolver));
        console.log("UpDownAutoCycler:", address(cycler));
        console.log("Keeper forwarder:", keeperForwarder);
        console.log("Pre-start window:", preStartWindowSec);
        console.log("BTC/USD + ETH/USD pairs cycling, Streams feed ids configured.");

        // ── Deployment record ───────────────────────────────────────────────
        // `broadcast/` is gitignored and console output is not machine-readable,
        // so emit a JSON artifact the backend can consume and ops can audit
        // after the fact. Requires the `fs_permissions` entry in foundry.toml.
        string memory label = vm.envOr("DEPLOY_LABEL", string("unlabeled"));
        string memory obj = "deployment";
        vm.serializeString(obj, "label", label);
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeUint(obj, "block", block.number);
        vm.serializeAddress(obj, "deployer", deployer);
        vm.serializeAddress(obj, "settlement", address(settlement));
        vm.serializeAddress(obj, "resolver", address(resolver));
        vm.serializeAddress(obj, "autocycler", address(cycler));
        vm.serializeAddress(obj, "relayer", relayer);
        vm.serializeAddress(obj, "treasury", treasury);
        vm.serializeAddress(obj, "keeperForwarder", keeperForwarder);
        vm.serializeAddress(obj, "usdt", usdt);
        vm.serializeAddress(obj, "verifierProxy", verifierProxy);
        string memory record = vm.serializeAddress(obj, "pendingOwner", newOwner);
        vm.writeJson(record, string.concat("deployments/", label, "-", vm.toString(block.number), ".json"));
        console.log("Deployment record: deployments/%s-%s.json", label, vm.toString(block.number));

        console.log("");
        if (newOwner != address(0) && newOwner != deployer) {
            console.log("Ownership handoff PENDING. From the new owner, run:");
            console.log("  cast send %s 'acceptOwnership()'", address(settlement));
            console.log("  cast send %s 'acceptOwnership()'", address(resolver));
            console.log("  cast send %s 'acceptOwnership()'", address(cycler));
        } else {
            console.log("WARNING: owner is still the deployer key. Set OWNER_ADDRESS to hand off.");
        }
        console.log("Next: authorize this resolver with Chainlink for the configured stream ids,");
        console.log("      fund it with LINK if verify fees are non-zero, verify on Arbiscan.");
    }
}
