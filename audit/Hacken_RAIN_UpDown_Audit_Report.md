# Hacken Smart Contract Audit — RAIN UpDown

> **Working copy of the Hacken Smart Contract Code Review & Security Analysis Report**, converted to Markdown for internal tracking and remediation. Source: `Hacken_RAIN_SCA_Rain_UpDown_Jun2026_P_2026_2156_1_20260608_10_47.pdf`.

## Report Metadata

| Field | Value |
|---|---|
| **Customer** | RAIN |
| **Product** | UpDown — binary prediction market |
| **Report Date** | 08/06/2026 |
| **Document** | Smart Contract Code Review and Security Analysis Report for RAIN |
| **Audited By** | Kornel Światłowski, Seher Saylık |
| **Approved By** | Ivan Bondar |
| **Website** | https://www.rain.one/ |
| **Changelog** | 08/06/2026 — Preliminary Report |
| **Platform** | Arbitrum |
| **Language** | Solidity |
| **Tags** | Signatures; Oracle; Centralization; Prediction Market |
| **Methodology** | https://docs.hacken.io/methodologies/smart-contracts |
| **Repository** | https://github.com/Quecko-Org/updown-contracts |
| **Commit** | `fccb622c` |

**What UpDown is:** a binary prediction market protocol deployed on Arbitrum that allows users to take UP or DOWN positions on asset pairs (e.g. BTC/USD, ETH/USD) across fixed-duration market windows (5, 15, and 60 minutes). Positions are entered via EIP-712 signed orders matched by an off-chain relayer, with on-chain atomic settlement in USDT; market outcomes are determined by comparing a Chainlink Data Streams settlement price against a strike price captured at market creation.

---

## Audit Summary

| Metric | Count |
|---|---|
| **Total Findings** | 22 |
| Resolved | 22 |
| Accepted | 0 |
| Mitigated | 0 |

> **Remediation V2 (2026-06-15):** all 22 findings resolved to the auditor's recommended fix (PM
> decision "Option A — full auditor recommendations"). The 9 localized fixes from the first pass are
> retained; the 13 `Needs-decision` findings are now implemented via a custodial→non-custodial
> inversion (on-chain per-user shares, dual-signed fills, signed fee caps, trustless redemption,
> keeper access-control, tightened oracle window, rolling treasury budget). Contracts: 138 Foundry
> tests pass + conservation invariant over 128k fuzz calls. Backend changed in lock-step: 514 jest
> tests pass. See `REMEDIATION_V2.md` and the per-finding notes in the tracker below.
>
> **Post-remediation review (2026-06-15):** an independent adversarial re-review re-verified all 22
> fixes (all CORRECT) and closed two newly-surfaced gaps: (1) **F-2026-17731 was incomplete** — the
> taker's signed `maxFee` was enforced per-fill rather than cumulatively, so a relayer could split one
> taker order into N partial fills and charge up to N×`maxFee`; now bounded cumulatively via the
> `orderFeesPaid` ledger (regression `test_F17731_feeCap_cumulativeAcrossPartialFills`). (2) A
> **deploy footgun**: `ChainlinkResolver.registerMarket` gated on the vestigial Data Feeds
> `priceFeeds[pair]` after the Streams-strike migration, stranding any Streams-only pair; the gate now
> accepts EITHER feed source (regression `test_streams_registerMarket_streamsOnlyPair_succeeds`). (3)
> **F-2026-17759 sign guard extended to the live path** — the original `price <= 0` guard sat only in
> the legacy `_getLatestPrice` (Data Feeds) view, which the post-migration strike/settlement lifecycle
> no longer uses; the same guard is now applied to the production `report.price` reads in `captureStrike`
> and `resolve` (regressions `test_F17759_resolve_revertsZeroStreamsPrice`,
> `test_F17759_resolve_revertsNegativeStreamsPrice`, `test_F17759_captureStrike_revertsNonPositiveStreamsPrice`).
> The finding's secondary per-feed-staleness recommendation is **Accepted (by design)** — it applies only
> to the legacy Data Feeds view (no production caller); the live Streams path enforces freshness via the
> tightened observation window (`maxStrikeReportLag` / `maxReportObservationLag`), not `MAX_STALENESS`.
> Added F-2026-17760 access-control coverage (`NotAuthorizedCaller` on `resolve`/`captureStrike`,
> `setObservationLag` cap). Lock-step note: the relayer must budget the signed `maxFee` across an
> order's partial fills (charge fees that sum to ≤ `maxFee`), not the full fee on each.

**Findings by severity**

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 2 |
| Medium | 10 |
| Low | 6 |
| Info | 4 |

> ~~All 22 findings are currently **Pending Fix**~~ — superseded: all 22 **Resolved** as of the
> Remediation V2 pass (2026-06-15). See tracker.

### Codebase quality notes (from the report)

**Documentation quality — has gaps:**
- Project description and architecture provided (off-chain order book, on-chain settlement, custodial relayer model); actor roles described (DMM bots, taker bots, relayer, resolver/keeper); settlement model documented (deposit flow, matching engine, claim service); backend API endpoint inventory and phase-by-phase completion status included.
- **Missing:** consolidated role-permission matrix; whitepaper / protocol specification document; end-to-end interaction flow documentation for core lifecycles.
- Technical description is **inadequate**: `README.md` is the default unmodified Foundry template (zero project-specific content); NatSpec absent on admin setter functions (`setResolver`, `setAutocycler`, `setRelayer`); no technical specification for the off-chain ↔ on-chain interface (what the relayer must supply and guarantee); dev environment cannot be configured without manual discovery of required environment variables.
- NatSpec present in all three in-scope contracts but thinner in `UpDownAutoCycler` (35 tags / 16 functions) and `ChainlinkResolver` (24 tags / 11 functions); `UpDownSettlement` has 41 NatSpec tags / 25 functions.

**Code quality — generally good:**
- Solidity `0.8.29` across all contracts (built-in overflow protection).
- **Floating pragma** (`pragma solidity ^0.8.29;`) used in all three core contracts instead of a pinned version (see F-2026-17727).
- OpenZeppelin `SafeERC20`, `EIP712`, and `SignatureChecker` used throughout — no reimplementation of cryptographic or token primitives.
- Custom errors on all revert paths; `unchecked` arithmetic blocks each accompanied by an inline justification comment.

**Test coverage:** **57.76%** (branch coverage). Deployment and basic user interactions are covered; **negative-case coverage is missing**.

---

## System Overview

> **⚠️ Reflects the audited commit `fccb622c` (V1), not the remediated code.** This section is Hacken's
> verbatim description of the audited snapshot and is preserved unchanged for fidelity. The Remediation V2
> pass changed several mechanisms named below — most notably: `withdrawSettlement` (whole-pool-to-relayer)
> was **removed** and replaced by trustless `redeem` / `redeemFor` against on-chain per-user `userShares`
> (F-17778/17772/17777); fees are now pulled from the **taker** and capped by a signed `Order.maxFee`,
> and `setFees`/`platformFeeBps`/`makerFeeBps` were **removed** (F-17756/17731/17746); the ±30s
> observation window is tightened to an owner-tunable 3s and `resolve`/`captureStrike` are
> authorized-caller-only (F-17760). For the as-shipped behavior see the **Remediation Tracker** and the
> per-finding notes above, plus `docs/REMEDIATION_V2.md`.

The protocol is composed of three tightly coupled, **non-upgradeable** contracts deployed as a single bundle: **UpDownSettlement**, **UpDownAutoCycler**, and **ChainlinkResolver**. Cross-contract references between the cycler and the resolver are immutable, preventing mid-life pointer rotation that could orphan unresolved markets. The settlement contract serves as the central ledger, holding all market state and user collateral in a single instance (no per-market proxy deployment). Orders are signed off-chain by makers using EIP-712 typed data and submitted by a privileged relayer via `enterPosition`, which verifies signatures (supporting both EOA and ERC-1271 contract wallets), enforces partial-fill caps, and performs atomic fee distribution — platform fees flow to a configurable treasury address, maker fees to a designated recipient, and the seller receives the cash portion of the fill. A Polymarket-parity complementary-mint/burn mechanism allows participants to deposit USDT and receive paired UP + DOWN shares (tracked off-chain), with the deposit held in per-market retained collateral that backs $1 redemptions at resolution.

Market lifecycle is automated by **UpDownAutoCycler**, a Chainlink Automation-compatible keeper that creates new markets on clock-aligned slot boundaries across all active timeframe/pair combinations. The cycler supports a configurable pre-start window for early market creation, fail-forward slot skipping on creation errors, and an owner-gated deprecation mechanism for safe contract rotation. Resolution is driven off-chain: the backend fetches a signed Chainlink Data Streams report near the market's close time and submits it to **ChainlinkResolver**, which verifies the DON signature via the Verifier Proxy, validates observation-timestamp freshness within a 30-second bracket, and determines the winning option (UP if settlement price exceeds strike, DOWN otherwise). The resolver pays per-report LINK fees from its own balance and includes Arbitrum L2 sequencer-uptime checks before any price read. After resolution, the relayer calls `withdrawSettlement` to claim the market's retained collateral for off-chain winner payouts. A maker-rebate system accumulates per-fill rebate credits on-chain, claimable by any maker via a pull-from-treasury pattern using `transferFrom`. Administrative safeguards include a global pause toggle and a two-step emergency-withdraw mechanism with a 24-hour timelock.

### Files in Scope

- **`UpDownSettlement.sol`** — Core settlement contract that stores all market state, holds USDT collateral, and processes position entry. Responsible for EIP-712 order verification and partial-fill tracking via `enterPosition`, complementary share minting and burning via `complementaryMint` / `complementaryBurn`, market resolution via `resolve`, post-resolution collateral release via `withdrawSettlement`, maker rebate accumulation and claiming via `accumulateRebate` / `claimRebate`, and a timelocked emergency-withdraw mechanism gated by `proposeEmergencyWithdraw` / `executeEmergencyWithdraw`.
- **`UpDownAutoCycler.sol`** — Chainlink Automation-compatible keeper that automatically creates prediction markets on clock-aligned slot boundaries for each active pair/timeframe combination. Implements `checkUpkeep` and `performUpkeep` for keeper-driven scheduling, manages an internal active-market index with swap-and-pop pruning of resolved entries, and provides owner controls for timeframe toggling, pair registration, pre-start window configuration, manual eviction of provably-unresolvable markets via `evictUnresolved`, and one-shot deprecation via `deprecate`.
- **`ChainlinkResolver.sol`** — Oracle and resolution contract that integrates both Chainlink Data Feeds (legacy aggregator for strike-time price reads) and Chainlink Data Streams (pull-based verified reports for settlement). Captures per-slot strike prices via `captureStrike` using verified Data Streams reports with a symmetric ±30-second observation window, resolves markets via `resolve` using a Data Streams report with an asymmetric observation bracket anchored at market close, and registers market metadata via `registerMarket` with cross-contract consistency checks against **UpDownSettlement**. Includes Arbitrum sequencer-uptime validation, per-pair feed-id configuration, and LINK fee payment to the Chainlink Verifier Proxy.

### Privileged Roles

**`UpDownSettlement.sol`**
- **owner** (inherited from `Ownable`): full administrative control over contract configuration, role assignments, fee parameters, and emergency fund recovery.
  - `setPaused` — pause/unpause all state-changing operations guarded by `whenNotPaused`.
  - `setResolver` / `setAutocycler` / `setRelayer` — replace the addresses authorized to resolve markets, create markets, and submit fills/mint/burn/withdraw/rebate respectively.
  - `setTreasury` — replace the treasury address that receives platform fees atomically per fill and funds rebate claims.
  - `setFees` — update `platformFeeBps` and `makerFeeBps`.
  - `setDmmRebateBps` — update the DMM rebate basis-point rate.
  - `proposeEmergencyWithdraw` / `executeEmergencyWithdraw` / `cancelEmergencyWithdraw` — timelocked (24-hour) emergency withdrawal of any ERC-20 token held by the contract.
  - `transferOwnership` / `renounceOwnership`.
- **autocycler**: sole address permitted to create new prediction markets — `createMarket` (3-parameter and 5-parameter overloads) with a given pair, duration, strike price, and optional explicit start/end times.
- **relayer**: sole address permitted to submit order fills, manage complementary shares, withdraw settlement proceeds, and credit maker rebates.
  - `enterPosition` — submit a signed EIP-712 fill, pulling USDT from the buyer and distributing proceeds atomically to seller, treasury, and maker-fee recipient.
  - `complementaryMint` — deposit USDT on behalf of a minter, incrementing the market's retained backing for share creation.
  - `complementaryBurn` — withdraw retained backing on behalf of a holder, reducing the market's retained collateral.
  - `withdrawSettlement` — transfer the full retained collateral of a resolved market to the relayer address for off-chain winner payouts.
  - `accumulateRebate` — credit a maker's on-chain rebate accumulator by an arbitrary amount.
- **resolver**: sole address permitted to set market outcomes — `resolve` records the settlement price and winning option (UP or DOWN) for an expired market.

**`UpDownAutoCycler.sol`**
- **owner** (inherited from `Ownable`): full administrative control over timeframe configuration, pair management, market lifecycle housekeeping, fund recovery, and cycler deprecation.
  - `toggleTimeframe` — enable/disable any of the three timeframe configurations (5 min, 15 min, 1 hour).
  - `setPreStartWindowSec` — configure the pre-positioning window (seconds before a slot boundary at which market creation becomes eligible), capped at 300 seconds.
  - `addPair` — whitelist a new trading pair and include it in automated market cycling.
  - `deprecate` — permanently disable the cycler (one-shot), causing `checkUpkeep` to return false and `performUpkeep` to revert, recording a replacement address in the emitted event.
  - `withdrawFunds` — withdraw any ERC-20 token held by the contract.
  - `pruneResolved` — remove resolved markets from the internal active-markets array.
  - `evictUnresolved` — manually remove provably-unresolvable markets (past the resolver's staleness window) from the active-markets array.
  - `transferOwnership` / `renounceOwnership`.

**`ChainlinkResolver.sol`**
- **owner** (inherited from `Ownable`): full administrative control over price-feed configuration, Data Streams feed-id assignment, authorized-caller management, LINK fund recovery, and market registration.
  - `configureFeed` — set/replace the Chainlink Data Feeds aggregator address for a given pair.
  - `configureStreamsFeed` — set/replace the Chainlink Data Streams feed-id for a given pair.
  - `withdrawLink` — withdraw LINK tokens held by the contract (verification-fee funding rotation or emergency recovery).
  - `setAuthorizedCaller` — grant/revoke authorized-caller status for any address.
  - `registerMarket` — register a market with a validated strike price against the trusted settlement contract.
  - `transferOwnership` / `renounceOwnership`.
- **authorizedCaller**: any address flagged as `authorizedCallers[addr] == true` by the owner — can call `registerMarket` to register a market in the resolver, binding a market ID to a settlement address, pair, and strike price (validated against the on-chain market state in the trusted settlement contract).

---

## Potential Risks

These are systemic risks and trust assumptions identified by the auditors. They are **context for the findings below** — several findings are concrete instantiations of these risks.

### Out-of-Scope Components and Third-Party Dependencies
- **Dependency on Chainlink Data Streams infrastructure:** Market resolution in `ChainlinkResolver` depends on the Chainlink-deployed Verifier Proxy (`IVerifierProxy`) to validate DON-signed `ReportV3` blobs via `verifierProxy.verify`, and on the associated `IFeeManager` for LINK fee computation and reward-manager approval. Strike capture via `captureStrike` follows the same verification path. These external contracts are operated by Chainlink and are **not covered by this audit**. Changes to the Verifier Proxy's validation logic, fee model, or the `ReportV3` schema would directly affect both market creation and resolution flows across all pairs.
- **Arbitrum L2 sequencer uptime feed dependency:** Both `resolve` and `captureStrike` invoke `_checkSequencer`, which reads the Arbitrum L2 sequencer uptime feed via `AggregatorV3Interface.latestRoundData` at the immutable `sequencerFeed`. A 1-hour grace period (`SEQUENCER_GRACE_PERIOD`) blocks all price operations after the sequencer restarts. Extended sequencer downtime or a stale uptime feed could halt market creation and resolution for the duration of the outage plus the grace period, potentially pushing markets past the `MAX_STALENESS` boundary and rendering them permanently unresolvable through the normal `resolve` path.
- **Scope definition:** The audit does not cover all code in the repository. Contracts outside the audit scope may introduce vulnerabilities, potentially impacting overall security due to the interconnected nature of smart contracts.

### Permissions, Authorization, and Access
- **Arbitrary oracle and data source reconfiguration:** The `owner` of `ChainlinkResolver` can call `configureFeed` to replace the AggregatorV3 price feed address or `configureStreamsFeed` to change the Data Streams feed-id for any pair, at any time, without timelock, validation, or multi-signature controls. A compromised owner key could point a pair's streams feed to an attacker-controlled feed-id, causing all subsequent markets on that pair to resolve from a manipulated settlement price extracted from a crafted report.
- **Unrestricted fee and rebate parameter modification:** The `owner` of `UpDownSettlement` can call `setFees` to set `platformFeeBps` and `makerFeeBps` to arbitrary values without upper-bound validation or timelock; similarly `setDmmRebateBps` imposes no cap. While `enterPosition` does not itself compute fees from these parameters (fee amounts are relayer-supplied), the stored values serve as the reference for the off-chain matching engine's fee computation. A sudden parameter change without coordination could cause fee mismatches between on-chain state and the off-chain engine, or be exploited by a compromised owner to signal inflated fee extraction to a colluding relayer.
- **Absence of timelock on role and parameter changes:** Apart from the 24-hour timelocked emergency withdraw, all other owner-gated functions in `UpDownSettlement` (`setRelayer`, `setResolver`, `setAutocycler`, `setTreasury`, `setFees`, `setDmmRebateBps`, `setPaused`) execute immediately. In `ChainlinkResolver`, `configureFeed`, `configureStreamsFeed`, and `setAuthorizedCaller` are also instant. A compromised owner key could simultaneously redirect the relayer address, swap oracle feeds, pause the contract, and set fees to extractive levels before users or operators can observe and react.
- **Relayer-initiated operations without on-chain user consent:** The `relayer` in `UpDownSettlement` can call `complementaryBurn` to withdraw any amount from a market's `marketRetained` balance and transfer it to a specified `holder` address, with no on-chain user signature or approval required — the contract documents this as "TRUST-ASSUMPTION-V1." Additionally, in `enterPosition`, the `taker` address (the fill counterparty) is specified entirely by the relayer in the `FillInputs` struct and is not bound by any signed data; the taker's only on-chain protection is the ceiling of their ERC-20 approval to the settlement contract. The relayer also unilaterally calls `accumulateRebate` to credit arbitrary rebate amounts to any maker address, which are subsequently claimable from the treasury.
- **Emergency and rescue withdrawal authority over user-backing collateral:** The `owner` of `UpDownSettlement` can propose an emergency withdrawal of any ERC-20 token — including USDT that backs active market positions via `marketRetained` — to any destination address, subject only to a 24-hour timelock with no on-chain mechanism restricting the amount to surplus funds or exempting collateral backing unsettled markets. Separately, `withdrawFunds` in `UpDownAutoCycler` allows the owner to extract any held ERC-20 balance immediately without timelock, and `withdrawLink` in `ChainlinkResolver` allows immediate withdrawal of the LINK balance that funds Data Streams verification fees.
- **Signature verification (no on-chain cancellation):** Signed orders remain executable until they are fully filled or reach their expiry timestamp. Although the nonce is included in the signed Order hash to uniquely identify each order, the contract does not provide an on-chain cancellation mechanism to invalidate a specific order or nonce. As a result, makers cannot independently revoke a previously signed order once it has been shared with the off-chain system. This creates reliance on the centralized relayer or matching engine to honor cancellation requests. If the relayer is compromised, misconfigured, unavailable, or fails to process a cancellation in time, a maker's stale order may still be submitted on-chain and filled before expiry.

### Centralization
- **Single points of failure across the contract bundle:** The `owner` role in `UpDownSettlement` (OpenZeppelin `Ownable`) unilaterally controls pausing, all role assignments (`setRelayer`, `setResolver`, `setAutocycler`, `setTreasury`), fee configuration (`setFees`, `setDmmRebateBps`), and emergency fund extraction. The `owner` of `ChainlinkResolver` controls feed configuration, authorized-caller management, and LINK withdrawal. The `owner` of `UpDownAutoCycler` controls timeframe activation, pair management, pre-start window, deprecation, and fund withdrawal. Whether these three owner roles converge to the same address cannot be determined from the contract code alone, and the safety of private key storage for all privileged addresses cannot be verified during a smart contract audit.
- **Relayer key as a centralized trusted execution layer:** The `relayer` address in `UpDownSettlement` is the sole entity authorized to execute `enterPosition`, `complementaryMint`, `complementaryBurn`, `withdrawSettlement`, and `accumulateRebate`. All user-facing market operations — position entry, share creation and destruction, post-resolution fund distribution, and rebate crediting — flow exclusively through this single address with no multi-signature or on-chain governance requirement. Compromise of the relayer key would grant an attacker the ability to drain `marketRetained` balances across all active markets via `complementaryBurn`, inflate rebate accumulators via `accumulateRebate`, and extract the treasury's USDT via `claimRebate`.
- **Single oracle provider with no fallback:** All pricing data — both strike-time captures via `captureStrike` and resolution-time settlements via `resolve` — is sourced exclusively from Chainlink infrastructure (Data Streams for prices, AggregatorV3 for sequencer uptime). No secondary oracle, fallback mechanism, or on-chain dispute path exists in `ChainlinkResolver`. A Chainlink-side outage, Data Streams API disruption, or feed deprecation would simultaneously halt market creation and resolution with no on-chain alternative for price discovery.

### Off-Chain Dependency and Liveness
- **Protocol liveness tied to relayer, resolver service, and keeper:** Market creation depends on the Chainlink Automation keeper calling `performUpkeep` on `UpDownAutoCycler`; if keeper registration lapses, the LINK subscription is exhausted, or the keeper node is offline, no new markets are created. Market resolution requires the off-chain resolver service to fetch a Data Streams report within the 30-second `MAX_REPORT_OBSERVATION_LAG` window around each market's `endTime` and submit it to `resolve`. Position entry and settlement withdrawals require the relayer to submit transactions to `UpDownSettlement` on behalf of users. Downtime of any of these three off-chain components halts the corresponding lifecycle phase with no on-chain fallback until the component is restored.
- **Off-chain position accounting as settlement source of truth:** The on-chain `cashUpFlow` and `cashDownFlow` fields in `UpDownSettlement`'s `Market` struct are explicitly documented as "analytics only" and "not load-bearing for settlement." Outstanding share balances per user reside off-chain in the relayer's database. The `withdrawSettlement` function transfers the entire `marketRetained` balance to the relayer, which then distributes to winning positions based on its off-chain records. On-chain state alone is insufficient to reconstruct individual user entitlements or to independently verify that the relayer's payout distribution to winners is correct and complete.

### Data Availability and Verification
- **Relayer-supplied fee breakdown with limited on-chain validation:** The `FillInputs` struct passed to `enterPosition` in `UpDownSettlement` includes `sellerReceives`, `platformFee`, `makerFee`, and `makerFeeRecipient` — all pre-computed by the relayer off-chain. The contract validates only that `sellerReceives <= cashPart` (where `cashPart = price × fillAmount / 10000`) and that `treasury` is set when `platformFee > 0`. The on-chain `platformFeeBps` and `makerFeeBps` state variables are never referenced within `enterPosition`; the actual fee-to-BPS computation is entirely off-chain and unverified on-chain. A malfunctioning or compromised relayer could submit fee breakdowns that deviate from the configured BPS parameters — overcharging buyers or undercharging fees — without triggering an on-chain revert.

---

## Findings

The table below indexes all 22 findings. Detailed write-ups (description, recommendation, and proof-of-concept summary) follow. A remediation tracker is provided immediately after the index for ongoing status tracking.

### Findings Index

| ID | Severity | Status | Title |
|---|---|---|---|
| [F-2026-17726](#f-2026-17726--permissionless-upkeep-fail-forward-corrupts-slot-pointer-and-halts-market-creation) | High | Resolved | Permissionless Upkeep Fail-Forward Corrupts Slot Pointer and Halts Market Creation |
| [F-2026-17756](#f-2026-17756--fees-are-always-charged-to-the-buyer-violating-the-intended-taker-pays-model) | High | Resolved | Fees Are Always Charged to the Buyer, Violating the Intended Taker-Pays Model |
| [F-2026-17729](#f-2026-17729--permissionless-strike-capture-drains-resolver-link-through-per-second-cache-keys) | Medium | Resolved | Permissionless Strike Capture Drains Resolver LINK Through Per-Second Cache Keys |
| [F-2026-17731](#f-2026-17731--relayer-can-charge-arbitrary-fees-to-buyers-due-to-missing-on-chain-fee-validation) | Medium | Resolved | Relayer Can Charge Arbitrary Fees to Buyers Due to Missing On-Chain Fee Validation |
| [F-2026-17757](#f-2026-17757--taker-funds-pulled-without-taker-consent) | Medium | Resolved | Taker Funds Pulled Without Taker Consent |
| [F-2026-17760](#f-2026-17760--observation-window-tolerance-allows-favorable-report-selection-in-binary-settlement) | Medium | Resolved | Observation Window Tolerance Allows Favorable Report Selection in Binary Settlement |
| [F-2026-17771](#f-2026-17771--backing-collateral-can-be-reused-across-multiple-fills-due-to-non-cumulative-marketretained-check) | Medium | Resolved | Backing Collateral Can Be Reused Across Multiple Fills Due to Non-Cumulative marketRetained Check |
| [F-2026-17772](#f-2026-17772--complementary-mint-burn-lack-per-user-share-accounting-and-user-authorization) | Medium | Resolved | Complementary Mint/Burn Lack Per-User Share Accounting and User Authorization |
| [F-2026-17776](#f-2026-17776--position-backing-verified-at-entry-can-be-withdrawn-via-complementaryburn-before-resolution) | Medium | Resolved | Position Backing Verified at Entry Can Be Withdrawn via complementaryBurn Before Resolution |
| [F-2026-17777](#f-2026-17777--filled-positions-in-enterposition-record-no-on-chain-share-accounting-and-cannot-be-reconstructed-from-chain-state) | Medium | Resolved | Filled Positions in enterPosition Record No On-Chain Share Accounting and Cannot Be Reconstructed From Chain State |
| [F-2026-17778](#f-2026-17778--absence-of-on-chain-settlement-path-forces-winners-to-depend-on-the-off-chain-relayer-for-redemption) | Medium | Resolved | Absence of On-Chain Settlement Path Forces Winners to Depend on the Off-Chain Relayer for Redemption |
| [F-2026-17780](#f-2026-17780--performupkeep-is-not-idempotent-and-can-skip-market-slots) | Medium | Resolved | performUpkeep Is Not Idempotent and Can Skip Market Slots |
| [F-2026-17730](#f-2026-17730--makerfee-can-be-silently-trapped-when-makerfeerecipient-is-zero) | Low | Resolved | makerFee Can Be Silently Trapped When makerFeeRecipient Is Zero |
| [F-2026-17759](#f-2026-17759--missing-price-validation-in-getprice-can-return-zero-or-negative-oracle-values) | Low | Resolved | Missing Price Validation in getPrice Can Return Zero or Negative Oracle Values |
| [F-2026-17774](#f-2026-17774--complementaryburn-lacks-market-active-guard-allowing-collateral-drain-during-the-expiry-to-resolution-window) | Low | Resolved | complementaryBurn Lacks Market-Active Guard, Allowing Collateral Drain During the Expiry-to-Resolution Window |
| [F-2026-17779](#f-2026-17779--relayer-can-drain-treasury-via-unbounded-rebate-accumulation) | Low | Resolved | Relayer Can Drain Treasury via Unbounded Rebate Accumulation |
| [F-2026-17781](#f-2026-17781--missing-nonreentrant-modifier-on-functions-that-perform-external-token-transfers) | Low | Resolved | Missing nonReentrant Modifier on Functions That Perform External Token Transfers |
| [F-2026-17782](#f-2026-17782--no-mechanism-to-remove-or-deactivate-a-pair) | Low | Resolved | No Mechanism to Remove or Deactivate a Pair |
| [F-2026-17727](#f-2026-17727--floating-pragma) | Info | Resolved | Floating Pragma |
| [F-2026-17728](#f-2026-17728--missing-two-step-ownership-pattern) | Info | Resolved | Missing Two Step Ownership Pattern |
| [F-2026-17739](#f-2026-17739--redundant-marketid-and-option-fields-in-fillinputs-provide-no-additional-security) | Info | Resolved | Redundant marketId and option Fields in FillInputs Provide No Additional Security |
| [F-2026-17746](#f-2026-17746--unused-fee-basis-point-variables-can-misrepresent-enforced-trading-fees) | Info | Resolved | Unused Fee Basis Point Variables Can Misrepresent Enforced Trading Fees |

### Remediation Tracker

> Update this table as fixes land. All findings start as **Pending Fix**.

| ID | Severity | Title | Status | Resolution | Notes |
|---|---|---|---|---|---|
| F-2026-17726 | High | Permissionless Upkeep Fail-Forward Corrupts Slot Pointer and Halts Market Creation | Resolved | `UpDownAutoCycler` | `performUpkeep` gated on `forwarder \|\| owner` (`setForwarder`); pointer advances ONLY on permanent `PlannedStartTooStale` skips, not transient report failures; recovery hatch `setPairTfLastCreated` retained. Tests `test_F17726_*`. |
| F-2026-17756 | High | Fees Are Always Charged to the Buyer, Violating the Intended Taker-Pays Model | Resolved | `UpDownSettlement.enterPosition` | Fill is now a two-sided signed match; fees pulled from the **taker** (`takerOrder.maker`) regardless of direction; `cashPart` moves buyer→seller peer-to-peer. Tests `test_F17756_takerPaysFees_{makerIsSeller,makerIsBuyer}`. |
| F-2026-17729 | Medium | Permissionless Strike Capture Drains Resolver LINK Through Per-Second Cache Keys | Resolved | `ChainlinkResolver.captureStrike` | (Pass 1) `startTime % STRIKE_ALIGNMENT == 0` gate; (Pass 2) `captureStrike` now also `onlyAuthorized`. Tests `test_F17729_*`. |
| F-2026-17731 | Medium | Relayer Can Charge Arbitrary Fees to Buyers Due to Missing On-Chain Fee Validation | Resolved | `Order.maxFee` | Signed `maxFee` added to `ORDER_TYPEHASH`; the taker's `platformFee + makerFee` is capped on-chain by `takerOrder.maxFee`, enforced **cumulatively across all partial fills** of the taker order via the `orderFeesPaid` ledger. (A per-fill-only check let a relayer split one taker order into N fills and charge up to N×maxFee — closed in the 2026-06-15 post-remediation review.) Lock-step signer change shipped. Tests `test_F17731_feeCap_enforced`, `test_F17731_feeCap_cumulativeAcrossPartialFills`. |
| F-2026-17757 | Medium | Taker Funds Pulled Without Taker Consent | Resolved | `FillInputs.takerOrder/takerSignature` | Taker's EIP-712 order is verified on-chain before any taker funds/shares move. Test `test_F17757_invalidTakerSignature_reverts`. |
| F-2026-17760 | Medium | Observation Window Tolerance Allows Favorable Report Selection in Binary Settlement | Resolved | `ChainlinkResolver` | `resolve`/`captureStrike` restricted to authorized callers (no public front-run); window tightened to an owner-tunable `maxReportObservationLag` (default 3s, hard-capped ≤30s). |
| F-2026-17771 | Medium | Backing Collateral Can Be Reused Across Multiple Fills Due to Non-Cumulative marketRetained Check | Resolved | `userShares` | A fill debits the **seller's own** on-chain shares; pooled-backing reuse is structurally impossible. Invariant `marketRetained == optionShares[UP] == optionShares[DOWN]`. Tests `test_F17771_*` + 128k fuzz. |
| F-2026-17772 | Medium | Complementary Mint/Burn Lack Per-User Share Accounting and User Authorization | Resolved | `userShares` + `MintAuth` | Per-user shares recorded on every mint/burn/fill; relayer mint/burn require the user's EIP-712 `MintAuth` (replay-protected); self-service `mint`/`burn` also exposed. Tests `test_F17772_*`. |
| F-2026-17776 | Medium | Position Backing Verified at Entry Can Be Withdrawn via complementaryBurn Before Resolution | Resolved | per-user complete-set burn gate | `burn` requires the holder own a **complete set** (`UP & DOWN ≥ amount`); a maker who sold their UP can no longer pull the backing under a live position. Test `test_F17776_cannotBurnBackingUnderLivePosition`. |
| F-2026-17777 | Medium | Filled Positions Record No On-Chain Share Accounting | Resolved | `userShares` / `sharesOf` | Positions are provable + reconstructable from `userShares` and the events it emits; off-chain ledger derives from chain. Test `test_F17772_selfMint_recordsPerUserShares`. |
| F-2026-17778 | Medium | Absence of On-Chain Settlement Path Forces Winners to Depend on the Off-Chain Relayer | Resolved | `redeem` / `redeemFor` | Trustless `redeem(marketId)` claims a winner's shares directly; `redeemFor(marketId, holders[])` pays each holder their own wallet. `withdrawSettlement` (whole-pool-to-relayer) **removed**. Tests `test_F17778_*`. |
| F-2026-17780 | Medium | performUpkeep Is Not Idempotent and Can Skip Market Slots | Resolved | `UpDownAutoCycler` | `slot.plannedStart` validated against the expected next slot; replayed/duplicate `performData` is a clean no-op. Test `test_F17780_stalePlannedStart_isNoOp`. |
| F-2026-17730 | Low | makerFee Can Be Silently Trapped When makerFeeRecipient Is Zero | Resolved | structural | `makerFeeRecipient` is no longer a relayer field — maker fee flows to `makerOrder.maker`, which carries a valid signature and can't be zero. (Pass-1 guard superseded by the fee-model redesign.) |
| F-2026-17759 | Low | Missing Price Validation in getPrice Can Return Zero or Negative Oracle Values | Resolved | `ChainlinkResolver` — sign guard | `if (price <= 0) revert InvalidPrice()` in `_getLatestPrice` (legacy), **and** the same `report.price <= 0` guard now in the live Streams paths `captureStrike`/`resolve`. Tests `test_F17759_*` (3 legacy + 3 Streams-path). Secondary per-feed-staleness recommendation **Accepted (by design)**: applies only to the unused legacy Data Feeds view; the production Streams path enforces freshness via the tightened observation window, not `MAX_STALENESS`. |
| F-2026-17774 | Low | complementaryBurn Lacks Market-Active Guard | Resolved | `UpDownSettlement._burn` | Symmetric `block.timestamp >= endTime` guard added (mirrors mint). Test `test_F17774_burnAfterExpiryReverts`. |
| F-2026-17779 | Low | Relayer Can Drain Treasury via Unbounded Rebate Accumulation | Resolved | rolling rebate budget | `claimRebate` capped by an owner-set per-window budget (`setRebateBudget`); a compromised relayer drains at most one window. Tests `test_F17779_*`. |
| F-2026-17781 | Low | Missing nonReentrant Modifier | Resolved | `ReentrancyGuard` | `nonReentrant` on all token-moving externals (`enterPosition`, `mint`/`burn`/`complementary*`, `redeem`/`redeemFor`, `claimRebate`, `executeEmergencyWithdraw`). |
| F-2026-17782 | Low | No Mechanism to Remove or Deactivate a Pair | Resolved | `UpDownAutoCycler.removePair` | Owner `removePair` (swap-and-pop + flag clear); re-`addPair` works cleanly. Tests `test_F17782_*`. |
| F-2026-17727 | Info | Floating Pragma | Resolved | all 3 contracts | Pinned `0.8.29`. |
| F-2026-17728 | Info | Missing Two Step Ownership Pattern | Resolved | all 3 contracts | `Ownable2Step`. Test `test_F17728_twoStepOwnership`. |
| F-2026-17739 | Info | Redundant marketId and option Fields in FillInputs | Resolved | `FillInputs` redesign | Redundant `marketId`/`option`/`taker`/`sellerReceives`/`makerFeeRecipient` removed; all derived from the two signed orders. |
| F-2026-17746 | Info | Unused Fee Basis Point Variables Can Misrepresent Enforced Trading Fees | Resolved | removed | `platformFeeBps`/`makerFeeBps` + `setFees` removed from the contract (constructor ABI change); fees are signed-and-capped per order. |

---

## Vulnerability Details

### F-2026-17726 — Permissionless Upkeep Fail-Forward Corrupts Slot Pointer and Halts Market Creation

| Field | Value |
|---|---|
| **Severity** | High |
| **Status** | Resolved |
| **Impact** | 4/5 |
| **Likelihood** | 5/5 |
| **Exploitability** | Independent |
| **Complexity** | Simple |
| **Assets** | /src/UpDownAutoCycler.sol |

**Description**

In **UpDownAutoCycler**, the `performUpkeep` function is permissionless and decodes attacker-supplied `performData`, applying only a `deprecated` check before iterating over caller-chosen create slots. Each slot is processed in a `try`/`catch`, and on any failure of `_createMarketExternal` the catch block advances the per-pair, per-timeframe pointer `pairTfLastCreated` by one duration:

```solidity
for (uint256 i; i < createSlots.length; ++i) {
    CreateSlot memory slot = createSlots[i];
    try this._createMarketExternal(slot.tfIdx, slot.pairId, slot.signedReport)
{}
    catch (bytes memory reason) {
        if (slot.tfIdx < NUM_TIMEFRAMES) {
            TimeframeConfig storage tft = timeframes[slot.tfIdx];
            uint256 lastStart = pairTfLastCreated[slot.pairId][slot.tfIdx];
            uint256 skippedSlotStart = lastStart == 0
                                       ? (block.timestamp / tft.duration)
* tft.duration
                                       : lastStart + tft.duration;
            pairTfLastCreated[slot.pairId][slot.tfIdx] = skippedSlotStart;
            emit SlotSkippedAfterFailure(slot.pairId, slot.tfIdx, skippedSlotS
tart);
        }
        emit MarketCreationFailed(slot.pairId, slot.tfIdx, reason);
    }
}
```

An attacker submits a slot for a supported pair with an empty `signedReport`. The `_createMarket` path computes the next future slot start and calls `captureStrike`, which reverts when verifying the empty report. The catch then advances `pairTfLastCreated` so the next legitimate slot is treated as already created, and `checkUpkeep` will not schedule it. Supplying many duplicate slots in one transaction pushes the pointer arbitrarily far forward. No function other than `_createMarket` and this catch block writes `pairTfLastCreated`, and no owner setter exists to repair it, so new-market creation for the targeted pair and timeframe is halted for an attacker-chosen duration. Recovery requires `deprecate` plus a full redeployment.

The impact scales with the targeted timeframe duration. Each catch iteration advances the pointer by one `tft.duration`. A single transaction with ~300 iterations pushes the 5-minute pointer ~25 hours forward, the 15-minute pointer ~3 days forward, and the 60-minute pointer over 12 days forward. The attacker can target all three timeframes for all active pairs in a single call, and the cost is gas only: the empty `signedReport` causes `captureStrike` to revert before any LINK fee is approved, so the protocol's LINK balance is not touched.

While the attack is in progress, no new prediction markets are created. Users cannot open positions for the affected pair and timeframe. Existing open markets continue resolving normally, so user funds already locked in active positions are not directly at risk. However, the protocol's core value proposition, continuous cycling prediction markets, is completely suspended for the attacker-chosen duration. Once the pointer is corrupted, even a legitimate `performUpkeep` call with a valid report cannot recover the skipped slots: the cycler always computes `plannedStart = pairTfLastCreated + duration`, which points to a future timestamp, and any real report anchored near the current time falls outside the observation window and is rejected. Recovery requires the owner to call `deprecate` and redeploy the full three-contract bundle (settlement, resolver, cycler), an operational disruption that also requires re-registering all active markets and migrating any remaining open positions.

**Recommendation**

Restrict `performUpkeep` to the Automation registry by validating `msg.sender`. Do not advance `pairTfLastCreated` on transient failures (distinguish an unavailable or invalid report from a genuine permanent slot skip). Add an owner-only setter to reset `pairTfLastCreated` so a corrupted pointer can be repaired without redeployment.

**Proof of Concept**

The Foundry test `test_performUpkeep_failForward_corruptsSlotPointer_haltsCreation` (pages 16-19) bootstraps a legitimate market pinning `pairTfLastCreated` to b0, warps to the next slot boundary (checkUpkeep returns true), then has an attacker submit 10 slots with empty signedReport in one tx. It proves the pointer advances by N*duration (3000s blocked), no new market is created, checkUpkeep returns false afterward, and even a legitimate performUpkeep cannot recover the skipped slot.

---

### F-2026-17756 — Fees Are Always Charged to the Buyer, Violating the Intended Taker-Pays Model

| Field | Value |
|---|---|
| **Severity** | High |
| **Status** | Resolved |
| **Impact** | 4/5 |
| **Likelihood** | 4/5 |
| **Exploitability** | Independent |
| **Complexity** | Simple |
| **Assets** | /src/UpDownSettlement.sol |

**Description**

The protocol's intended fee model, as confirmed by the team, is:

> "All fees paid by taker. Anyone buying and selling with market orders is a taker and pays fees. People who put in limit orders and get matched are makers and do not pay any fees while getting a rebate."

In this system, the **maker** is the user who places a resting limit order and signs it as the `Order` struct via EIP-712. The **taker** is the market-order user who fills that resting order and appears in `enterPosition` only as the relayer-supplied `f.taker`. The maker is the limit side; the taker is the aggressor side. These are trade-role concepts, independent of which direction (BUY or SELL) each party is positioned.

The contract, however, charges fees based on trade direction rather than trade role. It identifies the buyer by which side holds `order.side == BUY`, and then unconditionally pulls `cashPart + platformFee + makerFee` from the buyer:

```solidity
function enterPosition(FillInputs calldata f) external whenNotPaused onlyRelayer {
 // ... rest of the code

    if (f.order.side == 0) {
        buyer = f.order.maker;
        seller = f.taker;
    } else {
        buyer = f.taker;
        seller = f.order.maker;
    }
    usdt.safeTransferFrom(buyer, address(this), cashPart + f.platformFee + f.makerFee);

 // ... rest of the code
}
```

This produces two cases:

| Maker side | Buyer (fee payer) | Taker | Correct fee payer? |
| --- | --- | --- | --- |
| `side == SELL` (maker sells) | `f.taker` | `f.taker` | Yes — taker is the buyer |
| `side == BUY` (maker buys) | `f.order.maker` | `f.taker` | No — maker is charged fees instead of taker |

When the maker places a BUY limit order and a taker fills it by selling, the taker is the aggressor and should pay fees. Instead, the contract charges the maker — the passive limit-order placer — who under the protocol design is not only fee-exempt but is supposed to receive a rebate.

- BUY-side limit makers are charged fees they should not owe.
- SELL-side market takers avoid fees they should pay.
- The `makerFee` paid to `makerFeeRecipient` is funded by the wrong party — in this case the maker funds their own rebate source, which is economically circular.
- Maker/taker incentive structure (limit order provision rewarded, market order taking costs fees) is broken for half of all fill directions.

**Recommendation**

Separate fee responsibility from trade direction. Fees should be pulled from `f.taker` regardless of which direction the taker is positioned. `cashPart` should be pulled from the buyer according to trade direction. Concretely:

- Pull `cashPart` from the buyer (as currently determined by `order.side`).
- Pull `platformFee + makerFee` separately from `f.taker`.

**Proof of Concept**

The Foundry test `test_feesChargedToMakerBuyerNotTakerSeller` (pages 22-23) deploys settlement, creates a market, pre-funds backing, then has Alice sign a BUY limit order (`order.side == 0`) which Bob fills as the taker (SELL side). It asserts Alice (maker) is incorrectly drained of `cashPart + platformFee + makerFee` while Bob (taker) receives full `sellerReceives` with zero fee deduction. Test passes.

---

### F-2026-17729 — Permissionless Strike Capture Drains Resolver LINK Through Per-Second Cache Keys

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Status** | Resolved |
| **Impact** | 3/5 |
| **Likelihood** | 4/5 |
| **Exploitability** | Independent |
| **Complexity** | Simple |
| **Assets** | /src/ChainlinkResolver.sol |

**Description**

In **ChainlinkResolver**, the `captureStrike` function is permissionless and pays a LINK verification fee on every cache miss:

```solidity
if (strikeCaptured[pairId][startTime]) {
    return capturedStrike[pairId][startTime];
}
// ...
bytes memory parameterPayload = _payVerificationFee(signedReport);
bytes memory verifierResponse = verifierProxy.verify(signedReport, parameterPayload);
```

The dedup key is `(pairId, startTime)`, not the report, and `startTime` is not required to be a clock-aligned slot boundary. The only constraint is a 30 second tolerance window around the report observation timestamp:

```solidity
if (obs + MAX_STRIKE_REPORT_LAG < startTs || obs > startTs + MAX_STRIKE_REPORT_LAG) {
    revert ReportObservationOutOfStrikeWindow(startTime, obs);
}
```

A single valid report with observation timestamp `T` is therefore reusable across every integer-second `startTime` in `[T-30, T+30]`, yielding 61 distinct cache-miss keys and 61 paid `verify` calls, each funded from the resolver's own LINK balance through `_payVerificationFee`. Reports refresh sub-second, so a handful of fetched reports produces thousands of paid verifications. The attacker pays only gas. Once the resolver's LINK is depleted, `captureStrike` and `resolve` revert at the fee step, stalling strike capture and resolution until the owner re-funds, and locking unresolved-market backing during the depletion window.

**Recommendation**

Require `startTime` to be clock-aligned to the timeframe duration (`startTime % duration == 0`), and restrict `captureStrike` to the cycler or authorized callers. Alternatively, charge the caller for the LINK verification fee so unprivileged callers cannot spend protocol funds.

---

### F-2026-17731 — Relayer Can Charge Arbitrary Fees to Buyers Due to Missing On-Chain Fee Validation

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Status** | Resolved |
| **Impact** | 5/5 |
| **Likelihood** | 3/5 |
| **Exploitability** | Dependent |
| **Complexity** | Simple |
| **Assets** | /src/UpDownSettlement.sol |

**Description**

The `enterPosition` function pulls `cashPart + platformFee + makerFee` from the buyer in a single `transferFrom` call. The values of `platformFee` and `makerFee` are provided by the relayer as calldata and are not validated against any on-chain bound.

```solidity
usdt.safeTransferFrom(buyer, address(this), cashPart + f.platformFee + f.makerFee);
```

The only fee-related check in the function guards the seller's payout, not the buyer's total charge:

```solidity
if (f.sellerReceives > cashPart) revert FeeBreakdownInvalid();
```

The on-chain `platformFeeBps` and `makerFeeBps` state variables are never read inside `enterPosition`. The signed `Order` struct does not include fee fields, so buyers have no signed commitment to any fee level that the contract can enforce. This means the relayer has full discretion over the fees charged per fill, with no contract-level ceiling.

A malicious or compromised relayer can extract up to a buyer's full USDT approval on every fill. No user who has granted a large or unlimited approval to this contract is protected.

**Recommendation**

Include a `maxFee` field (or separate `maxPlatformFee` and `maxMakerFee` fields) in the `Order` struct so that the fee limit becomes part of the maker's EIP-712 signature. Inside `enterPosition`, add a check that the relayer-supplied fees do not exceed what the maker signed.

---

### F-2026-17757 — Taker Funds Pulled Without Taker Consent

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Status** | Resolved |
| **Impact** | 3/5 |
| **Likelihood** | 5/5 |
| **Exploitability** | Independent |
| **Complexity** | Simple |
| **Assets** | /src/UpDownSettlement.sol |

**Description**

The settlement flow only requires a signature from the maker. The taker address, `f.taker`, is supplied directly by the relayer as calldata and is never required to sign or otherwise authorize the trade.

When `order.side == 1`, the maker is the seller and the taker becomes the buyer:

```solidity
function enterPosition(FillInputs calldata f) external whenNotPaused onlyRelayer {

// ... rest of the code

    buyer = f.taker;
    seller = f.order.maker;
    ...
    usdt.safeTransferFrom(buyer, address(this), cashPart + f.platformFee + f.makerFee);

// ... rest of the code
}
```

The contract pulls USDT from the taker with no signed authorization from them. Any address holding an open approval to the settlement contract can be forced into an arbitrary position, at an arbitrary price, for an arbitrary fee, purely at the relayer's discretion. On-chain consent for the taker side does not exist — it relies entirely on relayer honesty.

**Recommendation**

Require explicit taker authorization before pulling funds from the taker. The contract should verify the taker signature on-chain before calling `safeTransferFrom` on taker funds.

---

### F-2026-17760 — Observation Window Tolerance Allows Favorable Report Selection in Binary Settlement

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Status** | Resolved |
| **Impact** | 3/5 |
| **Likelihood** | 4/5 |
| **Exploitability** | Independent |
| **Complexity** | Simple |
| **Assets** | /src/ChainlinkResolver.sol |

**Description**

In **ChainlinkResolver**, the `resolve` function is permissionless and accepts any DON report whose observation timestamp falls within a 30 second bracket before the market end time, then decides the binary outcome with a pure threshold comparison:

```solidity
if (obs > endTs || obs + MAX_REPORT_OBSERVATION_LAG < endTs) {
    revert ReportObservationOutOfWindow(endTs, obs);
}
int256 settlementPrice = int256(report.price);
uint256 winningOption = settlementPrice > info.strikePrice ? OPTION_UP : OPTION_DOWN;
```

Because any observation in `[endTime-30, endTime]` is valid, an actor holding a position can submit the most favorable still-valid report and front-run the relayer. When spot oscillates around the strike in the final 30 seconds, two DON-signed reports such as `R1(obs=endTime-25, price=strike-1)` and `R2(obs=endTime, price=strike+1)` are both accepted; `resolve` with `R1` yields DOWN while `R2` yields UP, and the submitter selects which result settles. The same applies to `captureStrike`, where an attacker pins the most favorable strike within the tolerance window on an idempotent first-writer-wins basis, biasing every timeframe sharing that boundary. The outcome flip transfers value from the rightful winning side to the attacker's side. The LINK verification fee is paid by the contract, so the attacker pays only gas.

**Recommendation**

Tighten the observation window toward `obs == endTime` (a few seconds of tolerance), or require the report whose observation timestamp is closest to `endTime`.

---

### F-2026-17771 — Backing Collateral Can Be Reused Across Multiple Fills Due to Non-Cumulative marketRetained Check

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Status** | Resolved |
| **Impact** | 3/5 |
| **Likelihood** | 3/5 |
| **Exploitability** | Independent |
| **Complexity** | Simple |
| **Assets** | /src/UpDownSettlement.sol |

**Description**

The backing guard in `enterPosition` verifies that the market's retained collateral is sufficient to cover the residual of the current fill:

```solidity
uint256 mintBackingDelta = f.fillAmount - cashPart;
if (marketRetained[f.marketId] < mintBackingDelta) {
    revert NoBackingForSeller(f.marketId, mintBackingDelta, marketRetained[f.marketId]);
}
```

However, `marketRetained` is never decremented in `enterPosition`. The check is a pure read with no state mutation:

```solidity
unchecked {
    marketRetained[f.marketId] += cashPart - f.sellerReceives;
}
```

Under Option B where `sellerReceives == cashPart`, `marketRetained` does not change at all during a fill. This means the same collateral pool is checked — and passes — for every fill independently, regardless of how many fills have already occurred against it.

**Recommendation**

Track cumulative reserved backing separately for each option per market. Introduce two new storage mappings:

```solidity
mapping(uint256 => uint256) public upReserved;
mapping(uint256 => uint256) public downReserved;
```

In `enterPosition`, update the relevant side and check that `marketRetained` covers the two:

```solidity
uint256 mintBackingDelta = f.fillAmount - cashPart;
if (f.order.option == 1) {
    upReserved[f.marketId] += mintBackingDelta;
} else {
    downReserved[f.marketId] += mintBackingDelta;
}
uint256 maxObligated = upReserved[f.marketId] > downReserved[f.marketId]
    ? upReserved[f.marketId]
    : downReserved[f.marketId];
if (marketRetained[f.marketId] < maxObligated) {
    revert NoBackingForSeller(f.marketId, maxObligated, marketRetained[f.marketId]);
}
```

---

### F-2026-17772 — Complementary Mint/Burn Lack Per-User Share Accounting and User Authorization

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Status** | Resolved |
| **Impact** | 5/5 |
| **Likelihood** | 3/5 |
| **Exploitability** | Semi-Dependent |
| **Complexity** | Simple |
| **Assets** | /src/UpDownSettlement.sol |

**Description**

In **UpDownSettlement**, the share-creation primitives `complementaryMint` and `complementaryBurn` move user collateral without recording per-user share balances on-chain and without any user authorization. Both functions are `onlyRelayer`, take no maker signature, and expose no user-callable path.

`complementaryMint` pulls USDT from the `minter` and only increments the per-market aggregate backing — it never records that `minter` now owns shares:

```solidity
function complementaryMint(uint256 marketId, uint256 amount,
                           address minter) external whenNotPaused onlyRelayer
{
    if (amount == 0) revert FillExceedsOrderAmount();
    if (minter == address(0)) revert ZeroAddress();
    Market storage m = markets[marketId];
    if (m.startTime == 0) revert MarketNotOpen();
    if (block.timestamp >= uint256(m.endTime)) revert MarketNotOpen();

    usdt.safeTransferFrom(minter, address(this), amount);
    marketRetained[marketId] += amount;

    emit ComplementaryMinted(marketId, minter, amount);
}
```

`complementaryBurn` debits the same aggregate and pays an arbitrary `holder`, with no on-chain link to the address that actually deposited the backing. The contract explicitly documents this as `TRUST-ASSUMPTION-V1` ("relayer can complementaryBurn any maker's locked collateral"):

```solidity
function complementaryBurn(uint256 marketId, uint256 amount,
                           address holder) external whenNotPaused onlyRelayer
{
    if (amount == 0) revert FillExceedsOrderAmount();
    if (holder == address(0)) revert ZeroAddress();
    Market storage m = markets[marketId];
    if (m.startTime == 0) revert MarketNotOpen();
    if (m.resolved) revert AlreadyResolved();

    if (marketRetained[marketId] < amount) {
        revert NoBackingForSeller(marketId, amount, marketRetained[marketId]);
    }
    marketRetained[marketId] -= amount;
    usdt.safeTransfer(holder, amount);

    emit ComplementaryBurned(marketId, holder, amount);
}
```

Two distinct gaps follow:

1. **No per-user share accounting.** The minted shares the user "receives" exist only in the relayer's off-chain ledger; on-chain state cannot prove or bound any user's holdings. The burn's conservation guard checks only the aggregate `marketRetained[marketId]`, never the depositor's own balance. Nothing prevents returning user A's deposited backing to user B, or burning against a user who never minted, up to the full pool size.
2. **No user authorization or consent.** Neither function verifies a maker signature, and neither can be called by the user directly. `complementaryMint` silently pulls a standing USDT allowance from `minter` at the relayer's chosen time and amount, and `complementaryBurn` returns a user's locked collateral to a relayer-chosen address with zero on-chain involvement of the actual owner.

While exploitation as outright theft requires a relayer error or compromise (the documented v1 trust assumption), the structural absence of per-user accounting and user consent means users have no on-chain protection, no proof of their holdings, and no guarantee that a burn returns funds to the rightful depositor — even under an honest relayer, an off-chain ledger error silently mis-allocates real on-chain collateral with no on-chain check to catch it.

**Recommendation**

Introduce on-chain per-user share accounting and bind both functions to user authorization:

1. Add a `mapping(address => mapping(uint256 => uint256)) public userShares` (user → marketId → amount). Credit `userShares[minter][marketId] += amount` in `complementaryMint` and debit `userShares[holder][marketId] -= amount` in `complementaryBurn`, and add the burn's guard to check `userShares[holder][marketId] >= amount` rather than only the aggregate `marketRetained[marketId]`. This ensures a user can never burn against collateral they did not deposit, and on-chain state stays consistent with the off-chain component.
2. Require user authorization for both operations. Either add an EIP-712 maker-signed mint/burn intent verified via the existing `SignatureChecker` path (the same mechanism already used in `enterPosition`), or expose user-callable `complementaryMint` / `complementaryBurn` entrypoints so the depositor authorizes their own deposit and withdrawal rather than relying solely on the relayer.

---

### F-2026-17776 — Position Backing Verified at Entry Can Be Withdrawn via complementaryBurn Before Resolution

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Status** | Resolved |
| **Impact** | 5/5 |
| **Likelihood** | 3/5 |
| **Exploitability** | Semi-Dependent |
| **Complexity** | Simple |
| **Assets** | /src/UpDownSettlement.sol |

**Description**

In **UpDownSettlement**, `enterPosition` enforces that the buyer's share-creation residual is already backed at the moment of entry. The `NoBackingForSeller` guard requires the market's retained collateral to cover `mintBackingDelta`:

```solidity
uint256 mintBackingDelta = f.fillAmount - cashPart;
if (marketRetained[f.marketId] < mintBackingDelta) {
    revert NoBackingForSeller(f.marketId, mintBackingDelta, marketRetained[f.marketId]);
}
```

This check guarantees the buyer's $1-at-resolution share is backed only at the instant of the fill. The backing it validates is held in the single fungible aggregate `marketRetained[marketId]`, and the fill itself is balance-neutral for the pool under the Option B fee model (`sellerReceives == cashPart`), so `marketRetained` is unchanged by entry — the validated backing simply remains pooled in the aggregate.

Nothing reserves or earmarks that backing for the position that was just entered. While the market is still unresolved, `complementaryBurn` can withdraw the same USDT, with only an aggregate-level check and no link to a complete UP+DOWN set actually held by the recipient:

```solidity
if (marketRetained[marketId] < amount) {
    revert NoBackingForSeller(marketId, amount, marketRetained[marketId]);
}
marketRetained[marketId] -= amount;
usdt.safeTransfer(holder, amount);
```

As a result, the backing precondition enforced by `enterPosition` is not durable: it is a point-in-time snapshot that can be silently invalidated after the user has entered. Concrete sequence (fees omitted, fill price 60%):

1. A maker mints 100 USDT of backing for the market, so `marketRetained = 100`.
2. A buyer fills 100 UP shares at 60%, paying `cashPart = 60`; the seller receives 60 and `marketRetained` stays 100. The L463-466 guard passes (`mintBackingDelta = 40 <= 100`). The buyer now holds 100 UP shares; the maker holds 100 DOWN shares.
3. `complementaryBurn(marketId, 100, maker)` is called before resolution. The aggregate check `100 >= 100` passes, `marketRetained` becomes 0, and 100 USDT leaves the contract — even though the maker no longer holds a complete set and the buyer's UP position is still live.
4. If UP wins, the buyer's 100 UP shares are owed 100 USDT, but `withdrawSettlement` now transfers `marketRetained = 0`. The buyer (who paid 60 and is owed 100) cannot be paid from on-chain funds. The market is under-collateralized by the full redemption obligation.

The only on-chain invariant the contract maintains (`balanceOf(this) == sum of marketRetained`) is preserved by the burn because both sides decrease together, yet it provides no protection here: it does not track whether the remaining share backing still covers outstanding winning shares, since per-user share balances are never stored on-chain. The sole safeguard against this is the off-chain relayer correctly verifying complete-set ownership before calling `complementaryBurn` (documented as relayer-trust v1). Any relayer fault, off-chain ledger desync, or compromise therefore removes backing from an active position with no on-chain check to prevent or detect it. Because `complementaryBurn` is `onlyRelayer`, the trigger is the relayer rather than an arbitrary attacker, but the on-chain backing check creates a false guarantee of durable collateralization that the contract does not actually enforce.

**Recommendation**

Track the collateral that is already allocated to cover live user positions, and allow `complementaryBurn` to withdraw only the unallocated remainder. Maintain a per-market allocated-collateral accumulator (for example `marketAllocated[marketId]`) that is incremented by `mintBackingDelta` whenever a fill in `enterPosition` consumes backing to cover a buyer's position, so it always equals the USDT obligated to outstanding positions for that market. `complementaryBurn` must then only release free collateral — the difference between total retained and allocated:

Alternatively (and preferably, as it also resolves other reported issues), maintain per-user, per-market complete-set balances (`userShares[holder][marketId]`) and gate `complementaryBurn` on `userShares[holder][marketId] >= amount`, so a burn can only ever consume sets the holder actually owns and can never reach the backing that underpins another participant's filled position.

---

### F-2026-17777 — Filled Positions in enterPosition Record No On-Chain Share Accounting and Cannot Be Reconstructed From Chain State

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Status** | Resolved |
| **Impact** | 3/5 |
| **Likelihood** | 5/5 |
| **Exploitability** | Semi-Dependent |
| **Complexity** | Simple |

**Description**

In **UpDownSettlement**, the `enterPosition` function settles a signed BUY fill by pulling USDT from the buyer and distributing it to the seller, treasury, and maker-fee recipient, yet it stores no on-chain state representing the UP or DOWN shares the buyer acquired. The only state a fill writes are the cumulative `orderFills` cap, the per-market `cashUpFlow` / `cashDownFlow` counters, and the aggregate `marketRetained`. None of these key on the buyer's address, and the contract documents that the cash-flow counters are analytics only, with outstanding shares living off-chain:

```solidity
function enterPosition(FillInputs calldata f) external whenNotPaused onlyRelayer {
    // ...

    if (f.order.option == 1) {
        m.cashUpFlow += uint128(f.fillAmount);
    } else {
        m.cashDownFlow += uint128(f.fillAmount);
    }

    unchecked {
        marketRetained[f.marketId] += cashPart - f.sellerReceives;
    }
    // ...
}
```

No mapping keyed on `(marketId, user, option)` exists, so after a fill, the chain holds no record of which address owns how many UP or DOWN shares. A user whose position was filled can rely only on the relayer's off-chain ledger to prove ownership; the entitlement is invisible to chain state. Because the position record is exclusively off-chain, the impact does not require relayer malice (the documented relayer v1 trust assumption). An honest-but-failed relayer, through database loss or corruption, a service outage, or key loss, leaves filled positions unprovable and unreconstructable from on-chain data, with no fallback that can rebuild who is owed what.

**Recommendation**

Persist per-user, per-market, per-option share balances on-chain and update them atomically in every function that creates, transfers, or destroys share entitlements. Introduce the mapping:

```solidity
mapping(uint256 marketId => mapping(address user => mapping(uint8 option => uint256 shares))) public userShares;
```

Update it in three places:

`enterPosition` — credit the buyer after the fill is validated and the buyer's address is resolved:

```solidity
userShares[f.marketId][buyer][uint8(f.order.option)] += f.fillAmount;
```

`complementaryMint` — credit both sides of the complete set so the minter's holdings are on-chain from the moment of deposit:

```solidity
userShares[marketId][minter][1] += amount; // UP
userShares[marketId][minter][2] += amount; // DOWN
```

`complementaryBurn` — debit both sides and enforce the per-user balance rather than the aggregate, so the burn cannot reach backing that belongs to another participant:

```solidity
if (userShares[marketId][holder][1] < amount || userShares[marketId][holder][2] < amount)
    revert NoBackingForSeller(marketId, amount, marketRetained[marketId]);
userShares[marketId][holder][1] -= amount;
userShares[marketId][holder][2] -= amount;
```

Maintain these balances consistent with the off-chain matching engine: every state change on-chain should be the authoritative source of truth, and the off-chain ledger should derive from indexed events rather than being the primary record.

---

### F-2026-17778 — Absence of On-Chain Settlement Path Forces Winners to Depend on the Off-Chain Relayer for Redemption

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Status** | Resolved |
| **Impact** | 4/5 |
| **Likelihood** | 5/5 |
| **Exploitability** | Semi-Dependent |
| **Complexity** | Simple |
| **Assets** | /src/UpDownSettlement.sol |

**Description**

In **UpDownSettlement**, no on-chain settlement path exists for users. After a market is resolved through `resolve`, the only function that moves the market's funds out is `withdrawSettlement`, which is `onlyRelayer` and transfers the entire retained pool to the relayer, which then pays winners off-chain:

```solidity
function resolve(uint256 marketId, int256 settlementPrice, uint8 winner) external onlyResolver whenNotPaused {
    Market storage m = markets[marketId];
    if (m.startTime == 0) revert MarketNotOpen();
    if (m.resolved) revert AlreadyResolved();
    if (block.timestamp < uint256(m.endTime)) revert MarketNotOpen();
    if (winner != 1 && winner != 2) revert InvalidWinner();

    m.settlementPrice = int128(settlementPrice);
    m.winner = winner;
    m.resolved = true;
    emit MarketResolved(marketId, winner, int256(settlementPrice));
}

function withdrawSettlement(uint256 marketId) external onlyRelayer whenNotPaused {
    Market storage m = markets[marketId];
    if (!m.resolved) revert NotResolved();
    if (m.settled) revert AlreadySettled();

    uint256 retained = marketRetained[marketId];
    m.settled = true;
    delete marketRetained[marketId];

    if (retained > 0) {
        usdt.safeTransfer(relayer, retained);
    }
    emit SettlementWithdrawn(marketId, retained, 0);
}
```

A winning user has no on-chain claim and no function to redeem winning shares directly against `marketRetained[marketId]`. Redemption of value depends entirely on the continuous availability and integrity of the off-chain component: the relayer must remain live, retain a correct ledger, and choose to disburse. There is no trustless user exit. If the relayer suffers a database loss, an outage, key loss, or simply declines to pay, the resolved pool has already left the contract to the relayer's address, and winners have no on-chain recourse. The only on-chain fallback is the owner's blunt `executeEmergencyWithdraw`, which moves bulk USDT to a single address and equally cannot distribute to individual winners.

**Recommendation**

Add a trustless, on-chain redemption function that lets a winning holder claim directly from `marketRetained[marketId]` after `resolve`, against on-chain share balances, instead of pushing the whole pool to the relayer.

---

### F-2026-17780 — performUpkeep Is Not Idempotent and Can Skip Market Slots

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Status** | Resolved |
| **Impact** | 3/5 |
| **Likelihood** | 3/5 |
| **Exploitability** | Independent |
| **Complexity** | Simple |
| **Assets** | /src/UpDownAutoCycler.sol |

**Description**

[Chainlink Automation documentation](#) states that `performUpkeep` should be idempotent. This means that calling it again with the same `performData` should not create wrong state changes.

In `UpDownAutoCycler`, `performUpkeep` decodes `performData` and calls `_createMarketExternal`. However, `_createMarket` does not use the `plannedStart` from `performData`. Instead, it calculates the next slot again from `pairTfLastCreated`.

```solidity
function performUpkeep(bytes calldata performData) external {

    //... rest of the code

    for (uint256 i; i < createSlots.length; ++i) {
        CreateSlot memory slot = createSlots[i];
        try this._createMarketExternal(slot.tfIdx, slot.pairId, slot.signedReport) {} catch (bytes memory reason) {

            if (slot.tfIdx < NUM_TIMEFRAMES) {
                TimeframeConfig storage tft = timeframes[slot.tfIdx];
                uint256 lastStart = pairTfLastCreated[slot.pairId][slot.tfIdx];
                uint256 skippedSlotStart = lastStart == 0
                    ? (block.timestamp / tft.duration) * tft.duration
                    : lastStart + tft.duration;
                pairTfLastCreated[slot.pairId][slot.tfIdx] = skippedSlotStart;
                emit SlotSkippedAfterFailure(slot.pairId, slot.tfIdx, skippedSlotStart);
            }
            emit MarketCreationFailed(slot.pairId, slot.tfIdx, reason);
        }
    }
    _pruneResolved();
}
```

If the same `performData` is executed twice, the first call can create the correct market and update `pairTfLastCreated`. The second call then calculates the next slot, but still uses the old signed report. This report belongs to the previous slot, so `captureStrike` can revert. The revert is caught by `performUpkeep`, and the contract advances `pairTfLastCreated` again. As a result, one valid future slot can be skipped.

A replay or duplicate Automation call can cause permanent loss of market slots. The affected market window will not be created, which can break the expected market schedule and reduce protocol availability.

**Recommendation**

Validate `performData` against the current contract state before creating or skipping a slot. If the slot was already processed, the function should return without changing state. Also consider using the `plannedStart` from `performData` and checking that it matches the expected next slot.

---

### F-2026-17730 — makerFee Can Be Silently Trapped When makerFeeRecipient Is Zero

| Field | Value |
|---|---|
| **Severity** | Low |
| **Status** | Resolved |
| **Impact** | 3/5 |
| **Likelihood** | 2/5 |
| **Exploitability** | Dependent |
| **Complexity** | Simple |
| **Assets** | /src/UpDownSettlement.sol |

**Description**

The `enterPosition` function pulls `cashPart + platformFee + makerFee` from the buyer during settlement. While `platformFee` is protected by a check that reverts if the treasury is unset, there is no equivalent validation for `makerFeeRecipient`.

If `makerFee > 0` and `makerFeeRecipient == address(0)`, the buyer is still charged the maker fee, but the transfer to the maker fee recipient is skipped. The skipped fee is not added to `marketRetained`, which is only updated by `cashPart - sellerReceives`.

```solidity
function enterPosition(FillInputs calldata f) external whenNotPaused onlyRelayer {
    // ... rest of the code

    if (f.makerFee > 0 && f.makerFeeRecipient != address(0)) {
        usdt.safeTransfer(f.makerFeeRecipient, f.makerFee);
    }

    // ... rest of the code
}
```

As a result, the collected maker fee remains stranded in the contract without being assigned to any recipient or market accounting bucket. This breaks the contract's intended balance accounting and prevents the funds from being recovered through the normal settlement flow.

**Recommendation**

Add a pre-execution guard that mirrors the existing `platformFee` / `treasury` check:

```solidity
if (f.makerFee > 0 && f.makerFeeRecipient == address(0)) revert ZeroAddress();
if (f.platformFee > 0 && treasury == address(0)) revert TreasuryNotConfigured();
```

---

### F-2026-17759 — Missing Price Validation in getPrice Can Return Zero or Negative Oracle Values

| Field | Value |
|---|---|
| **Severity** | Low |
| **Status** | Resolved |
| **Impact** | 5/5 |
| **Likelihood** | 1/5 |
| **Exploitability** | Independent |
| **Complexity** | Simple |
| **Assets** | /src/ChainlinkResolver.sol |

**Description**

In **ChainlinkResolver**, the `_getLatestPrice` helper reads a legacy Data Feeds aggregator and returns the answer after only a staleness check:

```solidity
(, int256 price,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
if (block.timestamp - updatedAt > MAX_STALENESS) revert StalePrice();
return price;
```

The `price` is returned without any sign or zero validation. A malfunctioning, deprecated, or circuit-broken aggregator can return `0` or a negative value, and a feed clamped at its `minAnswer` / `maxAnswer` bound returns the bound rather than the true price. Any of these is forwarded to callers of the external `getPrice` view as a valid price with no on-chain signal that the value is invalid.

A single global `MAX_STALENESS` of one hour is applied to every configured pair regardless of each feed's actual publishing cadence. Chainlink feeds advertise per-pair heartbeats and deviation thresholds that differ widely (some update on a sub-minute deviation, others only on a multi-hour heartbeat). A one-hour ceiling is simultaneously too loose for fast feeds, where a price already stale by tens of minutes still passes the check, and too tight for slow feeds whose legitimate heartbeat exceeds one hour, where a normally-published value is rejected with `StalePrice` and the read reverts. Because the same constant binds all pairs, the staleness guard cannot be tuned to match the freshness guarantee any individual feed provides, so the returned price can be accepted while materially outdated.

**Recommendation**

Add a positivity guard and surface a typed error before returning the price:

```solidity
(, int256 price,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
if (price <= 0) revert InvalidPrice();
if (block.timestamp - updatedAt > MAX_STALENESS) revert StalePrice();
return price;
```

Replace the single global `MAX_STALENESS` with a per-feed staleness threshold configured from each pair's published heartbeat (for example a `mapping(bytes32 => uint256)` set alongside `priceFeeds`), so each pair is validated against its own freshness guarantee.

**Remediation (V2 + post-review):**

1. **Sign guard — implemented on both paths.** `_getLatestPrice` reverts `InvalidPrice` on a non-positive answer (`ChainlinkResolver.sol`, after the staleness check). The post-remediation review additionally found that the legacy `getPrice`/`_getLatestPrice` (Data Feeds) view is no longer on the production strike/settlement path after the Data Streams migration, so the same positivity guard was added to the live reads: `captureStrike` and `resolve` now `revert InvalidPrice()` when `report.price <= 0` before the value is consumed (strike capture / UP-DOWN threshold). Regressions: `test_F17759_zeroPriceReverts` / `_negativePriceReverts` / `_positivePricePasses` (legacy view) and `test_F17759_resolve_revertsZeroStreamsPrice` / `_resolve_revertsNegativeStreamsPrice` / `_captureStrike_revertsNonPositiveStreamsPrice` (Streams path).
2. **Per-feed staleness — Accepted (by design).** The `MAX_STALENESS` heartbeat concern applies to `_getLatestPrice`, which reads Chainlink **Data Feeds**. Post-migration the production strike and settlement reads consume **Data Streams** `ReportV3` blobs, whose freshness is enforced by the per-call observation-window checks (`maxStrikeReportLag` for `captureStrike`, `maxReportObservationLag` for `resolve` — both default 3s, hard-capped ≤30s, tightened under F-2026-17760), not by `MAX_STALENESS`. The single global `MAX_STALENESS` is retained only for the legacy Data Feeds view, which has no production caller; per-feed staleness on that dead path was therefore not implemented.

---

### F-2026-17774 — complementaryBurn Lacks Market-Active Guard, Allowing Collateral Drain During the Expiry-to-Resolution Window

| Field | Value |
|---|---|
| **Severity** | Low |
| **Status** | Resolved |
| **Impact** | 3/5 |
| **Likelihood** | 2/5 |
| **Exploitability** | Dependent |
| **Complexity** | Simple |
| **Assets** | /src/UpDownSettlement.sol |

**Description**

`complementaryMint` and `complementaryBurn` are intended to be symmetric inverses. `complementaryMint` enforces that the market must be active — both started and not yet expired — before pulling collateral from the minter:

```solidity
Market storage m = markets[marketId];
if (m.startTime == 0) revert MarketNotOpen();
if (block.timestamp >= uint256(m.endTime)) revert MarketNotOpen();
```

`complementaryBurn` applies a weaker and asymmetric guard. It only checks that the market exists (`m.startTime != 0`) and has not been resolved yet (`!m.resolved`). It does **not** check `block.timestamp < m.endTime`:

```solidity
Market storage m = markets[marketId];
if (m.startTime == 0) revert MarketNotOpen();
if (m.resolved) revert AlreadyResolved();
```

Between market expiry (`block.timestamp >= m.endTime`) and the resolver calling `resolve()`, the market sits in a liminal state: it is closed to new activity but has not yet been resolved. During this window, the entire contents of `marketRetained[marketId]` — the collateral that backs every open position — can be burned out to an arbitrary address by the relayer. Once drained, `withdrawSettlement` transfers `marketRetained[marketId] == 0` to the relayer, and the relayer has nothing to pay winning position holders.

The `resolve` function explicitly requires the market to have expired before it can be called:

```solidity
if (block.timestamp < uint256(m.endTime)) revert MarketNotOpen();
```

This means the expiry-to-resolution window is a guaranteed, predictable interval in every market's lifecycle — it is not a theoretical edge case.

**Recommendation**

Add the same expiry check that `complementaryMint` applies:

```solidity
if (block.timestamp >= uint256(m.endTime)) revert MarketNotOpen();
```

This ensures `complementaryBurn` is only callable while the market is actively open.

---

### F-2026-17779 — Relayer Can Drain Treasury via Unbounded Rebate Accumulation

| Field | Value |
|---|---|
| **Severity** | Low |
| **Status** | Resolved |
| **Impact** | 4/5 |
| **Likelihood** | 2/5 |
| **Exploitability** | Dependent |
| **Complexity** | Simple |

**Description**

`accumulateRebate` is restricted to the relayer and increments an arbitrary amount into any maker's `dmmRebateAccumulated` counter with no upper bound. `claimRebate` then pulls that accumulated amount directly from the treasury EOA via `transferFrom`, which holds a standing unlimited approval to this contract as an operational precondition.

```solidity
function accumulateRebate(address maker, uint256 amount) external onlyRelayer whenNotPaused {
    dmmRebateAccumulated[maker] += amount;
    emit RebateAccumulated(maker, amount);
}
```

```solidity
function claimRebate() external {
    uint256 amt = dmmRebateAccumulated[msg.sender];
    if (amt == 0) return;
    if (treasury == address(0)) revert TreasuryUnderFunded(amt, 0);
    // Binding constraint is `min(balance, allowance)` — whichever is
    // smaller is what `transferFrom` would actually succeed with.
    // Surfacing it in the error gives ops a clear "fund treasury" vs
    // "re-approve allowance" signal.
    uint256 balance = usdt.balanceOf(treasury);
    uint256 allowance = usdt.allowance(treasury, address(this));
    uint256 have = balance < allowance ? balance : allowance;
    if (have < amt) revert TreasuryUnderFunded(amt, have);
    dmmRebateAccumulated[msg.sender] = 0;
    usdt.safeTransferFrom(treasury, msg.sender, amt);
    emit RebateClaimed(msg.sender, amt);
}
```

The relayer can call `accumulateRebate` to assign an arbitrary rebate to an address they control, then call `claimRebate` to pull up to the treasury's full USDT balance in a single transaction. The treasury approval is permanent and covers the entire balance, so there is no rate limit or circuit breaker.

Full treasury drainage can be done in one atomic operation.

**Recommendation**

The treasury should not hold funds that belong to users. Separate protocol-owned funds (rebate budgets, fee reserves) from user-owned collateral. Any collateral deposited by users must be tracked per-account and excluded from owner or relayer withdrawal paths

---

### F-2026-17781 — Missing nonReentrant Modifier on Functions That Perform External Token Transfers

| Field | Value |
|---|---|
| **Severity** | Low |
| **Status** | Resolved |
| **Impact** | 3/5 |
| **Likelihood** | 2/5 |
| **Exploitability** | Semi-Dependent |
| **Complexity** | Simple |
| **Assets** | /src/UpDownSettlement.sol |

**Description**

In **UpDownSettlement**, the contract extends `Ownable` and `EIP712` but does not inherit `ReentrancyGuard`. Functions that perform external token transfers, specifically `enterPosition`, `complementaryMint`, and `complementaryBurn`, carry no `nonReentrant` modifier.

In `enterPosition`, three outbound transfers to externally supplied addresses execute before the per-market state variables are updated:

```solidity
function enterPosition(FillInputs calldata f) external whenNotPaused onlyRelayer {
    // ...

    if (seller != address(0) && f.sellerReceives > 0) {
        usdt.safeTransfer(seller, f.sellerReceives);
    }
    if (f.platformFee > 0) {
        usdt.safeTransfer(treasury, f.platformFee);
    }
    if (f.makerFee > 0 && f.makerFeeRecipient != address(0)) {
        usdt.safeTransfer(f.makerFeeRecipient, f.makerFee);
    }

    if (f.order.option == 1) {
        m.cashUpFlow += uint128(f.fillAmount);
    } else {
        m.cashDownFlow += uint128(f.fillAmount);
    }

    unchecked {
        marketRetained[f.marketId] += cashPart - f.sellerReceives;
    }

    // ...
}
```

A reentrant call during any of these transfers would observe stale `marketRetained`, potentially allowing the `NoBackingForSeller` guard to pass against an already-consumed pool and producing under-collateralization at resolution. With USDT as the current collateral the risk is not immediately exploitable, but it materializes if a callback-capable token is introduced as future collateral.

**Recommendation**

It is recommended to extend `UpDownSettlement` with OpenZeppelin's `ReentrancyGuard` and apply `nonReentrant` to all state-mutating external functions.

---

### F-2026-17782 — No Mechanism to Remove or Deactivate a Pair

| Field | Value |
|---|---|
| **Severity** | Low |
| **Status** | Resolved |
| **Impact** | 3/5 |
| **Likelihood** | 2/5 |
| **Exploitability** | Dependent |
| **Complexity** | Simple |
| **Assets** | /src/UpDownAutoCycler.sol |

**Description**

`addPair` appends a pair to `_cyclingPairs` and sets `supportedPairs[pairId] = true`, but there is no inverse operation:

```solidity
function _createMarket(uint256 tfIdx, bytes32 pairId, bytes memory signedReport) internal {
    if (tfIdx >= NUM_TIMEFRAMES) revert InvalidTimeframeIndex();
    if (!supportedPairs[pairId]) revert("pair not supported");
}
```

```solidity
function addPair(bytes32 pairId) external onlyOwner {
    supportedPairs[pairId] = true;
    if (!isCyclingPair[pairId]) {
        isCyclingPair[pairId] = true;
        _cyclingPairs.push(pairId);
    }
}
```

Once a pair is added it is permanent. `_cyclingPairs` has no removal path, and `supportedPairs[pairId]` has no setter to flip it back to `false`. If a pair must be halted — because its Streams feed ID is deprecated, the DON stops publishing it, the feed is misconfigured, or a security incident requires an emergency stop — the pair cannot be deactivated without deprecating the entire cycler.

In practice, every `checkUpkeep` call continues to evaluate the broken pair in the creation loop, and every `performUpkeep` call attempts to create markets for it. Because `resolver.captureStrike` will revert for a pair with no valid feed, each attempt hits the fail-forward catch block, advances `pairTfLastCreated`, emits `SlotSkippedAfterFailure`, and moves on — indefinitely. Gas is wasted on every upkeep cycle, the event log is polluted with spurious skip events, and there is no on-chain way to stop the behavior short of replacing the entire cycler deployment.

**Recommendation**

Add a `removePair` or `setSupportedPair(bytes32 pairId, bool active)` owner function that sets `supportedPairs[pairId] = false` and removes the entry from `_cyclingPairs` (swap-and-pop). Both `checkUpkeep` and `_createMarket` already gate on `supportedPairs[pid]`, so flipping the flag to `false` is sufficient to stop iteration and market creation without requiring a redeployment.

---

### F-2026-17727 — Floating Pragma

| Field | Value |
|---|---|
| **Severity** | Info |
| **Status** | Resolved |
| **Impact** | 1/5 |
| **Likelihood** | 5/5 |
| **Exploitability** | Independent |
| **Complexity** | Simple |
| **Assets** | /src/UpDownSettlement.sol<br>/src/UpDownAutoCycler.sol<br>/src/ChainlinkResolver.sol |

**Description**

In Solidity development, the pragma directive specifies the compiler version to be used, ensuring consistent compilation and reducing the risk of issues caused by version changes. However, using a floating pragma (e.g., `^0.8.xx`) introduces uncertainty, as it allows contracts to be compiled with any version within a specified range. This can result in discrepancies between the compiler used in testing and the one used in deployment, increasing the likelihood of vulnerabilities or unexpected behavior due to changes in compiler versions.

The project currently uses floating pragma declarations (`^0.8.29`) in its Solidity contracts. This increases the risk of deploying with a compiler version different from the one tested, potentially reintroducing known bugs from older versions or causing unexpected behavior with newer versions. These inconsistencies could result in security vulnerabilities, system instability, or financial loss. Locking the pragma version to a specific, tested version is essential to prevent these risks and ensure consistent contract behavior.

**Recommendation**

It is recommended to **lock the pragma version** to the specific version that was used during development and testing. This ensures that the contract will always be compiled with a known, stable compiler version, preventing unexpected changes in behavior due to compiler updates. For example, instead of using `^0.8.24`, explicitly define the version with `pragma solidity 0.8.24;`.

Before selecting a version, review known bugs and vulnerabilities associated with each Solidity compiler release. This can be done by referencing the official Solidity compiler release notes: Solidity GitHub releases or Solidity Bugs by Version. Choose a compiler version with a good track record for stability and security.

---

### F-2026-17728 — Missing Two Step Ownership Pattern

| Field | Value |
|---|---|
| **Severity** | Info |
| **Status** | Resolved |
| **Impact** | 1/5 |
| **Likelihood** | 5/5 |
| **Exploitability** | Dependent |
| **Complexity** | Simple |
| **Assets** | /src/UpDownSettlement.sol<br>/src/UpDownAutoCycler.sol<br>/src/ChainlinkResolver.sol |

**Description**

The ownership model across the market contracts is based on OpenZeppelin's `Ownable`, which performs ownership transfer in a single step. As a result, administrative control may be transferred immediately to an incorrect address, an incompatible contract, or an address that cannot execute privileged functions. If such a transfer occurs, access to owner-only functionality may become permanently unavailable.

In several contracts, in the scope, the ownership is implemented using `Ownable` rather than a two-step ownership model:

```solidity
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ChainlinkResolver is Ownable { ... }
contract UpDownAutoCycler is Ownable { ... }
contract UpDownSettlement is Ownable, EIP712 { ... }
```

The `transferOwnership` function finalizes ownership immediately upon execution, without requiring confirmation from the recipient. No validation is performed to ensure that the new owner is capable of operating the contract.

As a result, administrative control may be assigned to an unintended or non-functional address. If this occurs, critical operations such as market creation, registry configuration, and administrative actions may become inaccessible. Existing markets may be unable to update metadata, modify trading status, or finalize resolution through the intended ownership flow.

**Recommendation**

It is recommended to replace the single-step ownership model with a two-step ownership transfer mechanism, such as `Ownable2Step`, where the new owner must explicitly accept ownership. This ensures that ownership is only finalized after confirmation, reducing the risk of assigning control to incorrect or non-operational addresses.

---

### F-2026-17739 — Redundant marketId and option Fields in FillInputs Provide No Additional Security

| Field | Value |
|---|---|
| **Severity** | Info |
| **Status** | Resolved |
| **Impact** | 1/5 |
| **Likelihood** | 5/5 |
| **Exploitability** | Independent |
| **Complexity** | Simple |
| **Assets** | /src/UpDownSettlement.sol |

**Description**

The `FillInputs` struct contains `marketId` and `option` as top-level fields alongside the signed `Order`, which already contains `order.market` and `order.option` as part of its EIP-712 signed payload.

```solidity
struct FillInputs {
    Order order;
    bytes signature;
    uint256 marketId;      // explicit redundant copy of order.market for arg/sig pinning
    uint8 option;          // explicit redundant copy of order.option
    ...
}
```

The contract checks these against the signed order fields at the top of `enterPosition`:

```solidity
if (f.marketId != f.order.market) revert MarketMismatch();
if (uint256(f.option) != f.order.option) revert OptionMismatch();
```

The stated purpose is to prevent the relayer from routing a signed order against the wrong market. However, this is already guaranteed by the EIP-712 signature verification that follows — `order.market` and `order.option` are both fields inside the signed `Order` struct and are covered by the `structHash`. Any tampered value in those fields would produce an invalid signature and revert at `InvalidSignature`. The redundant fields and their equality checks add no security that the signature verification does not already provide.

The result is two extra `uint256`/`uint8` fields in every `enterPosition` calldata payload, two additional storage reads per call, and two error types (`MarketMismatch`, `OptionMismatch`) that exist solely to duplicate what signature verification enforces.

**Recommendation**

Remove `marketId` and `option` from `FillInputs` and use `f.order.market` and `f.order.option` directly throughout `enterPosition`.

---

### F-2026-17746 — Unused Fee Basis Point Variables Can Misrepresent Enforced Trading Fees

| Field | Value |
|---|---|
| **Severity** | Info |
| **Status** | Resolved |
| **Impact** | 2/5 |
| **Likelihood** | 1/5 |
| **Exploitability** | Independent |
| **Complexity** | Simple |
| **Assets** | /src/UpDownSettlement.sol |

**Description**

In **UpDownSettlement**, `platformFeeBps` and `makerFeeBps` are stored during construction and can be changed later through `setFees`:

```solidity
platformFeeBps = _platformFeeBps;
makerFeeBps = _makerFeeBps;
```

```solidity
function setFees(uint256 platformBps, uint256 makerBps) external onlyOwner {
    platformFeeBps = platformBps;
    makerFeeBps = makerBps;
    emit FeesUpdated(platformBps, makerBps);
}
```

However, these values are not used by `enterPosition` to calculate or validate the actual fees charged during fills. Instead, the relayer supplies absolute `platformFee` and `makerFee` values directly in calldata, and the contract pulls those amounts from the buyer:

```solidity
usdt.safeTransferFrom(buyer, address(this), cashPart + f.platformFee + f.makerFee);
```

As a result, the on-chain fee basis point variables may differ from the fee amounts signed or submitted by the off-chain relayer. This can mislead integrators, users, monitoring systems, or auditors into assuming the configured basis point values are enforced on-chain, while the effective fee charged to users is entirely determined by relayer-provided calldata. A relayer bug, stale off-chain configuration, or malicious relayer can therefore charge fees that do not match the visible on-chain configuration without violating any contract check.

**Recommendation**

Either enforce the configured fee rates on-chain or remove the unused variables to avoid a misleading configuration surface. If the protocol intends to keep relayer-supplied absolute fee amounts, `enterPosition` should validate them against `platformFeeBps` and `makerFeeBps`, for example, by recalculating the expected fees from the fill amount and reverting on mismatch.

---

## Appendices

### Appendix 1 — Definitions (Severities & Potential Risks)

#### Severities

When auditing smart contracts, Hacken is using a risk-based approach that considers **Likelihood**, **Impact**, **Exploitability** and **Complexity** metrics to evaluate findings and score severities.

Reference on how risk scoring is done is available through the repository in our Github organization:

[hknio/severity-formula](https://github.com/hknio/severity-formula)

| Severity | Description |
| --- | --- |
| Critical | Critical vulnerabilities are usually straightforward to exploit and can lead to the loss of user funds or contract state manipulation. |
| High | High vulnerabilities are usually harder to exploit, requiring specific conditions, or have a more limited scope, but can still lead to the loss of user funds or contract state manipulation. |
| Medium | Medium vulnerabilities are usually limited to state manipulations and, in most cases, cannot lead to asset loss. Contradictions and requirements violations. Major deviations from best practices are also in this category. |
| Low | Major deviations from best practices or major Gas inefficiency. These issues will not have a significant impact on code execution. |

#### Potential Risks

The "Potential Risks" section identifies issues that are not direct security vulnerabilities but could still affect the project's performance, reliability, or user trust. These risks arise from design choices, architectural decisions, or operational practices that, while not immediately exploitable, may lead to problems under certain conditions. Additionally, potential risks can impact the quality of the audit itself, as they may involve external factors or components beyond the scope of the audit, leading to incomplete assessments or oversight of key areas. This section aims to provide a broader perspective on factors that could affect the project's long-term security, functionality, and the comprehensiveness of the audit findings.

### Appendix 2 — Scope

The scope of the project includes the following smart contracts from the provided repository:

| Scope Details | |
| --- | --- |
| Repository | https://github.com/Quecko-Org/updown-contracts |
| Commit | fccb622c |
| Whitepaper | - |
| Requirements | NatSpec; COWORK.md |
| Technical Requirements | NatSpec; COWORK.md |

| Asset | Type |
| --- | --- |
| /src/ChainlinkResolver.sol [https://github.com/Quecko-Org/updown-contracts ] | Smart Contract |
| /src/UpDownAutoCycler.sol [https://github.com/Quecko-Org/updown-contracts] | Smart Contract |
| /src/UpDownSettlement.sol [https://github.com/Quecko-Org/updown-contracts ] | Smart Contract |

### Appendix 3 — Additional Valuables

#### Additional Recommendations

The smart contracts in the scope of this audit could benefit from the introduction of automatic emergency actions for critical activities, such as unauthorized operations like ownership changes or proxy upgrades, as well as unexpected fund manipulations, including large withdrawals or minting events. Adding such mechanisms would enable the protocol to react automatically to unusual activity, ensuring that the contract remains secure and functions as intended.

To improve functionality, these emergency actions could be designed to trigger under specific conditions, such as:

- Detecting changes to ownership or critical permissions.
- Monitoring large or unexpected transactions and minting events.
- Pausing operations when irregularities are identified.

These enhancements would provide an added layer of security, making the contract more robust and better equipped to handle unexpected situations while maintaining smooth operations.

#### Frameworks and Methodologies

This security assessment was conducted in alignment with recognised penetration testing standards, methodologies and guidelines, including the [NIST SP 800-115 – Technical Guide to Information Security Testing and Assessment](https://csrc.nist.gov/pubs/sp/800/115/final), and the [Penetration Testing Execution Standard (PTES)](http://www.pentest-standard.org/). These assets provide a structured foundation for planning, executing, and documenting technical evaluations such as vulnerability assessments, exploitation activities, and security code reviews. Hacken's internal penetration testing methodology extends these principles to Web2 and Web3 environments to ensure consistency, repeatability, and verifiable outcomes.

### Disclaimers

**Hacken Disclaimer** — Contracts were analyzed against best industry practices at the time of writing, covering cybersecurity vulnerabilities/issues in the source code, plus compilation, deployment, and functionality. The report makes no warranty of identifying all vulnerabilities; it covers only the code submitted and reviewed and may not be relevant after modifications. It is not a final/sufficient assessment of utility, bug-free status, or safety. Readers should not rely on this report alone — Hacken recommends multiple independent audits and a public bug bounty program. English is the original language; the Consultant is not responsible for translated versions. Hacken may conduct independent re-audits for internal quality control; updated reports are shared privately and published only with client consent. The sole authoritative source for finalized, up-to-date reports is the Audits section at https://hacken.io/audits/.

**Technical Disclaimer** — Smart contracts are deployed and executed on a blockchain platform. The platform, its programming language, and related software can have vulnerabilities leading to hacks, so the Consultant cannot guarantee the explicit security of the audited smart contracts.
