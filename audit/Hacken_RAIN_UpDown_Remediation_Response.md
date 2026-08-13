# RAIN UpDown — Remediation Response

**Client response to the Hacken Smart Contract Code Review & Security Analysis Report.**
This document is the changelog of everything changed since the audited revision, provided to support
Hacken's remediation re-review. It is written to be read alongside the original report
(`Hacken_RAIN_SCA_Rain_UpDown_Jun2026...`).

## Metadata

| Field | Value |
|---|---|
| **Customer** | RAIN |
| **Product** | UpDown — binary prediction market (Arbitrum) |
| **Original report** | 08/06/2026 — Preliminary Report (22 findings) |
| **Audited commit (baseline)** | `fccb622` |
| **Remediation branch** | `audit/hacken-remediation-v2` |
| **Remediation commit (please re-review)** | `a6cda62` |
| **In-scope contracts** | `src/UpDownSettlement.sol`, `src/UpDownAutoCycler.sol`, `src/ChainlinkResolver.sol` |
| **Findings addressed** | 22 / 22 — all marked Resolved |
| **Remediation date** | 16/06/2026 |

## How to re-review

```bash
git checkout audit/hacken-remediation-v2          # HEAD = a6cda62

# full remediation diff vs the audited baseline (in-scope contracts only)
git diff fccb622 a6cda62 -- src/UpDownSettlement.sol src/UpDownAutoCycler.sol src/ChainlinkResolver.sol

# per-finding diff for any single commit (see commit log below)
git show <commit>

# regression suite + conservation/solvency invariant
forge test
```

Every code reference below (`file:line`) is at remediation commit `a6cda62`.

---

## Remediation summary

| ID | Severity | Status | Remediation (one line) | Primary location |
|---|---|---|---|---|
| F-2026-17726 | High | Resolved | `performUpkeep` gated to forwarder/owner; pointer advances only on permanent `PlannedStartTooStale`, not transient report failures; owner repair hatch retained | `UpDownAutoCycler.sol` |
| F-2026-17756 | High | Resolved | Fill is now a two-signed-order match; fees pulled from the **taker** regardless of direction; cash moves buyer→seller peer-to-peer | `UpDownSettlement.enterPosition` |
| F-2026-17729 | Medium | Resolved | `captureStrike` is `onlyAuthorized` **and** requires `startTime % 300 == 0` before any paid verify | `ChainlinkResolver.captureStrike` |
| F-2026-17731 | Medium | Resolved | Signed `maxFee` added to `Order`/`ORDER_TYPEHASH`; taker fees capped **cumulatively across partial fills** via `orderFeesPaid` | `UpDownSettlement.enterPosition` |
| F-2026-17757 | Medium | Resolved | Taker's EIP-712 order + signature verified on-chain before any taker funds/shares move | `UpDownSettlement.enterPosition` |
| F-2026-17760 | Medium | Resolved | `resolve`/`captureStrike` restricted to authorized callers; window tightened to owner-tunable `maxReportObservationLag` (default 3s, hard-capped ≤30s) | `ChainlinkResolver` |
| F-2026-17771 | Medium | Resolved | Pooled-backing check replaced by on-chain `userShares`; a fill debits the **seller's own** shares — backing reuse structurally impossible | `UpDownSettlement` |
| F-2026-17772 | Medium | Resolved | Per-user `userShares` recorded on every mint/burn/fill; relayer mint/burn require signed `MintAuth` (nonce-replay-protected); self-service `mint`/`burn` added | `UpDownSettlement` |
| F-2026-17776 | Medium | Resolved | `burn` requires the holder own a **complete set** (UP ≥ amount && DOWN ≥ amount) | `UpDownSettlement._burn` |
| F-2026-17777 | Medium | Resolved | Positions recorded in `userShares` + `sharesOf` getter + `FillSettled` event; reconstructable from chain | `UpDownSettlement` |
| F-2026-17778 | Medium | Resolved | Trustless `redeem`/`redeemFor` (pays each holder's own wallet); `withdrawSettlement` removed | `UpDownSettlement` |
| F-2026-17780 | Medium | Resolved | `plannedStart` threaded into `_createMarket` and validated against the expected slot; replayed `performData` is a clean no-op | `UpDownAutoCycler` |
| F-2026-17730 | Low | Resolved | `makerFeeRecipient` removed; maker fee flows to `makerOrder.maker` (verified signer, never zero) | `UpDownSettlement.enterPosition` |
| F-2026-17759 | Low | Resolved | `price <= 0` guard added to `_getLatestPrice` **and** the live Streams paths `captureStrike`/`resolve` | `ChainlinkResolver` |
| F-2026-17774 | Low | Resolved | `_burn` now reverts at/after `endTime`, symmetric with mint | `UpDownSettlement._burn` |
| F-2026-17779 | Low | Resolved | `claimRebate` capped by an owner-set rolling per-window budget (`setRebateBudget`); default 0 disables claims | `UpDownSettlement` |
| F-2026-17781 | Low | Resolved | `ReentrancyGuard` inherited; `nonReentrant` on all token-moving externals | `UpDownSettlement` |
| F-2026-17782 | Low | Resolved | Owner `removePair` (flag clear + swap-and-pop); re-`addPair` clean | `UpDownAutoCycler` |
| F-2026-17727 | Info | Resolved | Pragma pinned to `0.8.29` in all three in-scope contracts | all 3 |
| F-2026-17728 | Info | Resolved | `Ownable2Step` in all three in-scope contracts | all 3 |
| F-2026-17739 | Info | Resolved | Redundant `FillInputs` fields removed; all derived from the two signed orders | `UpDownSettlement` |
| F-2026-17746 | Info | Resolved | `platformFeeBps`/`makerFeeBps` + `setFees` removed (constructor signature change) | `UpDownSettlement` |

## Commit log (since `fccb622`)

| Commit | Scope | Findings |
|---|---|---|
| `c1c8344` | `fix(settlement)`: invert trust model to non-custodial on-chain shares | 17756, 17731, 17757, 17739, 17746, 17730, 17771, 17772, 17776, 17777, 17778, 17774, 17779, 17781 (+27/28 on settlement) |
| `e912e87` | `fix(cycler)`: harden keeper — forwarder gating, idempotent upkeep, removePair | 17726, 17780, 17782 (+27/28 on cycler) |
| `410c05f` | `fix(resolver)`: gate resolve/captureStrike, tighten window, guard non-positive price | 17729, 17760, 17759 (+27/28 on resolver) |
| `2665cb9` | `deploy`: wire V2 constructor, rebate budget, forwarder, resolver auth | supports 17729, 17760, 17726, 17779, 17746 |
| `8c11ee6`, `2cc5ff1`, `a6cda62` | `test`: V2 share-model + keeper/oracle + negative-case regression suites | all |
| `c35cd73`, `2b25f0d` | docs + testnet deploy scaffolding | — |

---

## Architectural changes (context for the per-finding entries)

Thirteen of the findings are addressed by **two structural redesigns** rather than independent patches.
Understanding them explains why several findings share the same code.

### A. Non-custodial on-chain share ledger — `c1c8344`
*(F-17771, 17772, 17776, 17777, 17778; underpins 17774, 17781)*

The V1 custodial model (single pooled `marketRetained` per market; per-user positions held only in the
relayer's off-chain DB) is replaced by an authoritative on-chain ledger
`userShares[marketId][user][option]` (`option ∈ {1=UP, 2=DOWN}`), USDT-denominated 1:1.

| Operation | Shares | Backing (`marketRetained`) |
|---|---|---|
| `mint`/`complementaryMint(amount)` | `+amount` UP **and** `+amount` DOWN to minter | `+amount` |
| `enterPosition(fillAmount)` | `−fillAmount` option from **seller**, `+fillAmount` to **buyer** | **unchanged** (cash moves peer-to-peer) |
| `burn`/`complementaryBurn(amount)` | `−amount` UP **and** `−amount` DOWN (complete set required) | `−amount` |
| `redeem`/`redeemFor` | `−shares` of the winning option | `−shares` |

**Conservation invariant** (enforced by fuzz, see Verification): for every unresolved market
`marketRetained == optionShares[UP] == optionShares[DOWN]`, and globally
`usdt.balanceOf(settlement) == Σ marketRetained`. Because `enterPosition` is balance-neutral for the
contract, F-17771 (backing reuse) is structurally impossible.

### B. Dual-signed fill with signed fee cap — `c1c8344`
*(F-17756, 17731, 17757, 17739, 17746, 17730)*

`enterPosition` now settles a match of **two EIP-712-signed orders** (resting `makerOrder` + aggressing
`takerOrder`), both verified on-chain. Fees are pulled from the taker; the cash leg moves buyer→seller.
The `Order` struct gains a signed `maxFee`, and `FillInputs` drops every redundant relayer-supplied field.

---

## Remediation detail

> Format per finding — **Status**, **Remediation** (what changed + mechanism), **Location** (`file:line`
> at `a6cda62`), **Regression** (new tests), and **Note** where a recommendation was partially deferred.

### High

#### F-2026-17726 — Permissionless Upkeep Fail-Forward Corrupts Slot Pointer and Halts Market Creation
- **Status:** Resolved (`e912e87`)
- **Remediation:** Three changes. (1) `performUpkeep` now reverts `NotForwarder` unless `msg.sender` is the registered Automation forwarder or the owner. (2) The fail-forward catch advances `pairTfLastCreated` **only** when the revert selector is `PlannedStartTooStale` (the one genuinely-permanent skip), classified via `_isSelector`; all transient failures (empty/invalid report, resolver hiccup) leave the pointer untouched so the next cycle retries the same slot. (3) The owner repair hatch `setPairTfLastCreated` is retained. The pointer now has exactly three writers (permanent-skip catch, legitimate create, owner repair).
- **Location:** `UpDownAutoCycler.sol:372` (gate), `:385-403` (selective advance), `:413-420` (`_isSelector`), `:586-590` (`setForwarder`), `:576-580` (`setPairTfLastCreated`).
- **Regression:** `test_F17726_performUpkeep_onlyForwarderOrOwner`, `test_F17726_transientFailure_doesNotAdvance`, `test_F17726_permanentStaleSkip_advancesAndEmits` (`test/UpDownUnit.t.sol`); `test_F17726_setPairTfLastCreated{Recovers,RejectsBadTfIdx,OnlyOwner}` (`test/AuditFixes.t.sol`).
- **Note:** Operationally, the forwarder is seeded to the relayer at deploy (`script/Deploy.s.sol:165`) and must be rotated to the real Automation forwarder via `setForwarder` once the upkeep is registered.

#### F-2026-17756 — Fees Are Always Charged to the Buyer, Violating the Intended Taker-Pays Model
- **Status:** Resolved (`c1c8344`)
- **Remediation:** `enterPosition` was rewritten to settle a two-signed-order match (see Architectural change B). Fee responsibility is decoupled from trade direction: the taker is `takerOrder.maker`, and `platformFee`/`makerFee` are pulled from the taker via separate `safeTransferFrom` calls regardless of which side the taker holds. `cashPart` moves buyer→seller directly; the maker fee/rebate is paid to the resting maker.
- **Location:** `UpDownSettlement.sol:440-443` (role resolution), `:456-467` (cash peer-to-peer + fees from taker), `:374-382` (`FillInputs`).
- **Regression:** `test_F17756_takerPaysFees_makerIsSeller`, `test_F17756_takerPaysFees_makerIsBuyer` (`test/RemediationV2.t.sol`) — the latter is the previously-mischarged maker-is-buyer direction.
- **Note:** Fee **amounts** remain relayer-supplied (the off-chain `p(1−p)` quote is non-linear); the contract enforces the signed **cap** (F-17731), not the exact amount.

### Medium

#### F-2026-17729 — Permissionless Strike Capture Drains Resolver LINK Through Per-Second Cache Keys
- **Status:** Resolved (`410c05f`)
- **Remediation:** `captureStrike` is now `onlyAuthorized`, and additionally rejects any non-clock-aligned `startTime` (`startTime % STRIKE_ALIGNMENT != 0`, `STRIKE_ALIGNMENT = 300`) **before** the dedup-cache lookup and any paid verification. This collapses the previously-abusable 61 per-second keys to the single legitimate boundary and removes anonymous callers entirely.
- **Location:** `ChainlinkResolver.sol:406-415` (`onlyAuthorized` + alignment guard), `:200` (`STRIKE_ALIGNMENT`), `:322-325` (modifier).
- **Regression:** `test_F17729_unalignedStartReverts`, `test_F17729_alignedStartPassesAlignmentGate` (`test/AuditFixes.t.sol`); `test_F17760_captureStrike_revertsForUnauthorizedCaller` (`test/UpDownUnit.t.sol`).
- **Note:** The cycler is authorized at deploy (`script/Deploy.s.sol:159`); all timeframe durations {300, 900, 3600} are multiples of `STRIKE_ALIGNMENT`.

#### F-2026-17731 — Relayer Can Charge Arbitrary Fees to Buyers Due to Missing On-Chain Fee Validation
- **Status:** Resolved (`c1c8344`)
- **Remediation:** A signed `maxFee` field was added to the `Order` struct and to `ORDER_TYPEHASH`. In `enterPosition`, the taker's `platformFee + makerFee` is accumulated against the taker order hash in a new ledger `orderFeesPaid` and checked **cumulatively across all partial fills** of that order: `orderFeesPaid[takerHash] + feeTotal > takerOrder.maxFee` reverts `FeeExceedsTakerCap`. This closes the per-fill-only weakness whereby a relayer could split one order into N fills to charge up to N×`maxFee`.
- **Location:** `UpDownSettlement.sol:98-116` (`maxFee` + `ORDER_TYPEHASH`), `:214-220` (`orderFeesPaid`), `:425-433` (cumulative cap).
- **Regression:** `test_F17731_feeCap_enforced`, `test_F17731_feeCap_cumulativeAcrossPartialFills` (`test/RemediationV2.t.sol`).
- **Note:** `ORDER_TYPEHASH` changed — off-chain signers must include `maxFee` (coordinated off-chain change, out of scope; see end of document).

#### F-2026-17757 — Taker Funds Pulled Without Taker Consent
- **Status:** Resolved (`c1c8344`)
- **Remediation:** `FillInputs` now carries the taker's own EIP-712-signed `takerOrder` + `takerSignature`. `enterPosition` verifies **both** order signatures (EOA + ERC-1271 via `SignatureChecker`) and reverts `InvalidSignature` before any funds/shares move. The taker whose funds are pulled is `takerOrder.maker` — the verified signer — not a relayer-supplied address.
- **Location:** `UpDownSettlement.sol:410-418` (both signatures), `:441` (`taker = to.maker`).
- **Regression:** `test_F17757_invalidTakerSignature_reverts`, `test_orderBinding_invalidMakerSignature_reverts` (`test/RemediationV2.t.sol`).

#### F-2026-17760 — Observation Window Tolerance Allows Favorable Report Selection in Binary Settlement
- **Status:** Resolved (`410c05f`)
- **Remediation:** (1) `resolve` and `captureStrike` are restricted to authorized callers (`onlyAuthorized`), removing the permissionless front-run. (2) The hard-coded ±30s window is replaced by owner-tunable `maxReportObservationLag` / `maxStrikeReportLag`, defaulting to **3 seconds** and hard-capped at `OBSERVATION_LAG_CAP = 30 seconds` (`setObservationLag` reverts `ObservationLagTooLarge` above the cap). The owner can tighten or tune within `[0, 30s]` but can never re-widen past the cap.
- **Location:** `ChainlinkResolver.sol:505` (`resolve onlyAuthorized`), `:541-545` (settlement window), `:439-443` (strike window), `:176`/`:190` (defaults), `:194` (`OBSERVATION_LAG_CAP`), `:330-336` (`setObservationLag`).
- **Regression:** `test_F17760_resolve_revertsForUnauthorizedCaller`, `_observationLagDefaultsToThreeSeconds`, `_setObservationLag_enforcesCap`, `_resolve_rejectsObservationOneSecondPastWindow`, `_resolve_acceptsObservationAtWindowEdge` (`test/UpDownUnit.t.sol`).
- **Note:** The 3s default is a state-variable initializer, not a constructor argument; the current deploy script does not override it. The off-chain resolver fetches the report by `timestamp = endTime`, so the observation lands within ~1s of close. Ops may pre-tune via `setObservationLag` if measured Data Streams fetch latency requires it.

#### F-2026-17771 — Backing Collateral Can Be Reused Across Multiple Fills
- **Status:** Resolved (`c1c8344`)
- **Remediation:** The pooled `marketRetained >= mintBackingDelta` check (which never decremented the pool) is removed. A fill now requires `userShares[market][seller][option] >= fillAmount` and debits the seller's own shares, crediting the buyer (Architectural change A). Backing reuse is structurally impossible; the conservation invariant is fuzz-proven.
- **Location:** `UpDownSettlement.sol:446-454` (seller-holds-shares check + transfer), `:227-236` (`optionShares`/`marketRetained` semantics).
- **Regression:** `test_F17771_backingNotReusableAcrossFills`, `test_F17771_sellerWithoutShares_cannotSell` (`test/RemediationV2.t.sol`); `invariant_retainedBacksOutstandingShares`, `invariant_balanceEqualsSumOfRetained` (`test/UpDownPROInvariant.t.sol`, 128k calls, 0 reverts).

#### F-2026-17772 — Complementary Mint/Burn Lack Per-User Share Accounting and User Authorization
- **Status:** Resolved (`c1c8344`)
- **Remediation:** Both recommendations implemented. (1) Per-user shares are recorded on every mint/burn. (2) The relayer-submitted `complementaryMint`/`complementaryBurn` now require a user-signed EIP-712 `MintAuth` (new `MINT_AUTH_TYPEHASH`), validated by `_checkMintAuth` (field binding, expiry, per-account nonce replay protection, `SignatureChecker` recovery to the account). Self-service `mint(marketId, amount)` / `burn(marketId, amount)` (`msg.sender` = account) are also exposed so a user can always exit without the relayer.
- **Location:** `UpDownSettlement.sol:495-503` (`complementaryMint`), `:507-526` (`mint`/`_mint`), `:529-568` (`complementaryBurn`/`burn`/`_burn`), `:570-588` (`_checkMintAuth`), `:130-132` (`MINT_AUTH_TYPEHASH`).
- **Regression:** `test_F17772_relayerMint_requiresSignedAuth`, `_relayerMint_rejectsWrongSigner`, `_selfMint_recordsPerUserShares` (`test/RemediationV2.t.sol`).

#### F-2026-17776 — Position Backing Verified at Entry Can Be Withdrawn via complementaryBurn Before Resolution
- **Status:** Resolved (`c1c8344`)
- **Remediation:** `_burn` now requires the holder own a **complete set** — `userShares[holder][UP] >= amount && userShares[holder][DOWN] >= amount` — before any collateral is released. A maker who has sold one leg no longer holds a complete set and cannot burn the backing underpinning a counterparty's live position. The guard is in the shared `_burn`, so both the self-service and relayer paths are covered.
- **Location:** `UpDownSettlement.sol:552-564`.
- **Regression:** `test_F17776_cannotBurnBackingUnderLivePosition` (`test/RemediationV2.t.sol`); `invariant_retainedBacksOutstandingShares` (`test/UpDownPROInvariant.t.sol`).

#### F-2026-17777 — Filled Positions Record No On-Chain Share Accounting
- **Status:** Resolved (`c1c8344`)
- **Remediation:** Fills update the authoritative `userShares` ledger (debit seller, credit buyer); a public `sharesOf(marketId, user, option)` getter exposes positions; and the `FillSettled` event records both parties plus the cash/fee flow. Positions are reconstructable from chain state and events; the off-chain ledger derives from chain rather than being the source of truth.
- **Location:** `UpDownSettlement.sol:453-454` (share writes), `:776` (`sharesOf`), `:162-172` (`FillSettled`).
- **Regression:** `test_F17756_takerPaysFees_makerIsSeller` (asserts `sharesOf` post-fill), `test_F17772_selfMint_recordsPerUserShares` (`test/RemediationV2.t.sol`).

#### F-2026-17778 — Absence of On-Chain Settlement Path Forces Winners to Depend on the Off-Chain Relayer
- **Status:** Resolved (`c1c8344`)
- **Remediation:** The whole-pool-to-relayer `withdrawSettlement` is **removed**. Winners call `redeem(marketId)` and pull exactly their own winning shares directly from `marketRetained`. A permissionless batch `redeemFor(marketId, holders[])` pays each holder their own wallet (operator-paid gas, but funds can only reach the rightful holder). Both follow checks-effects-interactions (shares zeroed before transfer) and are `nonReentrant`.
- **Location:** `UpDownSettlement.sol:608-610` (`redeem`), `:615-620` (`redeemFor`), `:627-641` (`_redeemToAllowZero`).
- **Regression:** `test_F17778_redeem_trustless`, `_redeemFor_paysHolderNotCaller`, `_loserCannotRedeem` (`test/RemediationV2.t.sol`).

#### F-2026-17780 — performUpkeep Is Not Idempotent and Can Skip Market Slots
- **Status:** Resolved (`e912e87`)
- **Remediation:** The keeper-supplied `plannedStart` is threaded through `_createMarketExternal` into `_createMarket` and validated against the contract's independently-computed expected next slot. On mismatch — exactly what a stale/replayed `performData` produces — the function emits `SlotAlreadyProcessed` and returns without creating a market or advancing the pointer. `checkUpkeep` computes `plannedStart` with the identical formula, so honest requests always match.
- **Location:** `UpDownAutoCycler.sol:385` (thread), `:469-472` (idempotency no-op), `:455-463` (expected-slot computation; matches `checkUpkeep` `:335-338`).
- **Regression:** `test_F17780_stalePlannedStart_isNoOp` (`test/UpDownUnit.t.sol`).

### Low

#### F-2026-17730 — makerFee Can Be Silently Trapped When makerFeeRecipient Is Zero
- **Status:** Resolved (`c1c8344`)
- **Remediation:** Structural — `makerFeeRecipient` is no longer a relayer-supplied field. The maker fee is paid to `makerOrder.maker`, the recovered signer of the resting order, which can never be the zero address. The trap condition (fee charged but skipped on zero recipient) is no longer expressible.
- **Location:** `UpDownSettlement.sol:465-467` (fee to `mo.maker`), `:413-415` (signer recovery).
- **Regression:** Dedicated test removed (condition structurally impossible; see `test/AuditFixes.t.sol` header note). Destination exercised as a value assertion in `test_F17756_takerPaysFees_makerIsSeller`.

#### F-2026-17759 — Missing Price Validation Can Return Zero or Negative Oracle Values
- **Status:** Resolved (`410c05f`)
- **Remediation:** A non-positive-price guard `if (price <= 0) revert InvalidPrice()` was added to the legacy Data Feeds reader `_getLatestPrice`, and — because the legacy view has no production caller after the Data Streams migration — the same `report.price <= 0` guard was added to the **live** strike/settlement paths `captureStrike` and `resolve` before the price is consumed.
- **Location:** `ChainlinkResolver.sol:636` (`_getLatestPrice`), `:450` (`captureStrike`), `:552` (`resolve`).
- **Regression:** `test_F17759_{zero,negative}PriceReverts`, `_positivePricePasses` (`test/AuditFixes.t.sol`); `test_F17759_resolve_reverts{Zero,Negative}StreamsPrice`, `_captureStrike_revertsNonPositiveStreamsPrice` (`test/UpDownUnit.t.sol`).
- **Note (accepted by design):** The secondary per-feed staleness recommendation was **not** implemented. The single global `MAX_STALENESS` is retained only for the legacy Data Feeds view (no production caller). Freshness on the live Data Streams path is enforced by the tightened observation window (F-17760), not `MAX_STALENESS`. See *Accepted-by-design deviations* below.

#### F-2026-17774 — complementaryBurn Lacks Market-Active Guard
- **Status:** Resolved (`c1c8344`)
- **Remediation:** `_burn` now applies the same active-market guard as mint — `if (block.timestamp >= m.endTime) revert MarketNotOpen()` — closing the expiry-to-resolution drain window. Symmetric across both burn entrypoints via the shared `_burn`.
- **Location:** `UpDownSettlement.sol:549` (burn guard), `:516` (matching mint guard).
- **Regression:** `test_F17774_burnAfterExpiryReverts`, `test_F17774_burnWhileOpenSucceeds` (`test/AuditFixes.t.sol`).

#### F-2026-17779 — Relayer Can Drain Treasury via Unbounded Rebate Accumulation
- **Status:** Resolved (`c1c8344`, deploy wiring `2665cb9`)
- **Remediation:** `claimRebate` is now bounded by an owner-configured rolling per-window budget (`rebateBudgetPerWindow` / `rebateWindowDuration`, set via `setRebateBudget`). The window rolls forward lazily; claims exceeding the remaining budget revert `RebateBudgetExceeded`. Even with a standing treasury approval, a compromised relayer can extract at most one window's budget. Default budget is 0 (claims disabled until ops configures it — fail-safe).
- **Location:** `UpDownSettlement.sol:656-681` (`claimRebate` window/budget logic), `:720` (`setRebateBudget`), `:199-206` (state).
- **Regression:** `test_F17779_rebateBudgetCapsClaims`, `test_F17779_rebateWithinBudget_works_andWindowRolls` (`test/RemediationV2.t.sol`).
- **Note (residual, accepted by design):** the bound caps a compromised-relayer loss to one window's budget rather than eliminating relayer trust on rebates. The broader recommendation to separate user collateral from the treasury is addressed by Architectural change A — user collateral now leaves only via trustless `redeem`, never via the treasury/relayer path.

#### F-2026-17781 — Missing nonReentrant Modifier on Functions That Perform External Token Transfers
- **Status:** Resolved (`c1c8344`)
- **Remediation:** `UpDownSettlement` now inherits OpenZeppelin `ReentrancyGuard`, and `nonReentrant` is applied to every token-moving external function: `enterPosition`, `mint`, `complementaryMint`, `burn`, `complementaryBurn`, `redeem`, `redeemFor`, `claimRebate`, `executeEmergencyWithdraw`. `accumulateRebate` (no token movement) is intentionally unguarded.
- **Location:** `UpDownSettlement.sol:10` (import), `:23` (inheritance), `:389/495/507/529/540/608/615/656/744` (guarded functions).
- **Regression:** `test_F17781_reentrancyGuardBlocksReentrantRedeem`, `_reentrancyGuardBlocksCrossFunctionReentry`, `_redeemSucceedsWithoutReentry` (`test/AuditFixes.t.sol`, using a synthetic callback token).

#### F-2026-17782 — No Mechanism to Remove or Deactivate a Pair
- **Status:** Resolved (`e912e87`)
- **Remediation:** Owner `removePair` added as the inverse of `addPair`: sets `supportedPairs[pair] = false` (both `checkUpkeep` and `_createMarket` gate on this), clears `isCyclingPair`, swap-and-pops from `_cyclingPairs`, and emits `PairRemoved`. Clearing `isCyclingPair` lets a later `addPair` re-add the pair cleanly. Open markets for a removed pair are untouched and resolve normally.
- **Location:** `UpDownAutoCycler.sol:543-557` (`removePair`), `:109` (`PairRemoved`), `:526-532` (`addPair` re-add).
- **Regression:** `test_F17782_removePairDeactivatesAndReAdds`, `test_F17782_removePairOnlyOwner` (`test/AuditFixes.t.sol`).

### Info

#### F-2026-17727 — Floating Pragma
- **Status:** Resolved (`c1c8344` / `e912e87` / `410c05f`)
- **Remediation:** All three in-scope contracts pin `pragma solidity 0.8.29;` (caret removed).
- **Location:** `UpDownSettlement.sol:2`, `UpDownAutoCycler.sol:2`, `ChainlinkResolver.sol:2`.

#### F-2026-17728 — Missing Two-Step Ownership Pattern
- **Status:** Resolved (`c1c8344` / `e912e87` / `410c05f`)
- **Remediation:** All three contracts inherit `Ownable2Step`; `transferOwnership` now nominates a pending owner who must call `acceptOwnership()`. (`Ownable` is also imported because the constructors invoke `Ownable(owner)`, which `Ownable2Step` extends.)
- **Location:** `UpDownSettlement.sol:5,23`; `UpDownAutoCycler.sol:5,15`; `ChainlinkResolver.sol:5,36`.
- **Regression:** `test_F17728_twoStepOwnership` (`test/AuditFixes.t.sol`).

#### F-2026-17739 — Redundant marketId and option Fields in FillInputs
- **Status:** Resolved (`c1c8344`)
- **Remediation:** `FillInputs` was slimmed to the two signed orders, their two signatures, `fillAmount`, and the two fee fields. The redundant `marketId`, `option`, `taker`, `sellerReceives`, and `makerFeeRecipient` are removed; market/option/buyer/seller/taker are derived from the two orders, which are cross-checked to agree on market/option/side/price.
- **Location:** `UpDownSettlement.sol:374-382` (struct), `:393-396` (cross-checks).
- **Regression:** `test_orderBinding_marketMismatch_reverts`, `test_orderBinding_optionMismatch_reverts` (`test/RemediationV2.t.sol`).

#### F-2026-17746 — Unused Fee Basis Point Variables Can Misrepresent Enforced Trading Fees
- **Status:** Resolved (`c1c8344`, deploy `2665cb9`)
- **Remediation:** The unused `platformFeeBps` / `makerFeeBps` state variables and `setFees` were removed, and the constructor no longer accepts the two bps parameters. Fees are governed by the signed-and-capped per-order model (`maxFee`). The only remaining bps value, `dmmRebateBps`, is documented as an off-chain reference, not an enforced on-chain fee.
- **Location:** `UpDownSettlement.sol:279` (2-arg constructor `(IERC20, address)`), `:193-196` (removal note). Deploy updated at `script/Deploy.s.sol:121`.

---

## New regression tests

The audit noted 57.76% branch coverage with missing negative-case coverage. This remediation adds a
dedicated negative-case + invariant suite (`8c11ee6`, `2cc5ff1`, `a6cda62`):

- `test/RemediationV2.t.sol` — 16 tests for the share model, dual-signed fill, fee cap, redemption, rebate budget.
- `test/UpDownUnit.t.sol` — keeper access-control/idempotency + oracle window/price-guard regressions (13 `F-` tests).
- `test/AuditFixes.t.sol` — 16 `F-` tests for the localized guards (price sign, alignment, burn-after-expiry, removePair, reentrancy, two-step ownership, pointer recovery).
- `test/UpDownPROInvariant.t.sol` — stateful fuzz of the conservation/solvency invariant.

45 findings-tagged (`test_F17*`) tests in total, each named for the finding it locks.

## Coordinated off-chain changes (out of audit scope)

Two remediations change the on-chain ABI/typed-data and require matching off-chain updates, which ship in
the same release but are outside the audited contract scope: the `Order` EIP-712 type gains `maxFee`
(F-17731), `enterPosition` takes two signed orders (F-17756/17739), `complementaryMint`/`Burn` require a
signed `MintAuth` (F-17772), and `withdrawSettlement` is replaced by `redeem`/`redeemFor` (F-17778). The
backend relayer, frontend signer, and SDK have been updated accordingly.

## Verification

`forge test` at `a6cda62` (excluding `UpDownForkTest`, which requires an Arbitrum RPC):

```
135 tests passed, 0 failed, 0 skipped (8 suites)
  · 45 findings-tagged regression tests (test_F17*) — all pass
  · conservation/solvency invariant fuzz — 0 reverts across ~128,000 calls
    (marketRetained == optionShares[UP] == optionShares[DOWN]; balance == Σ marketRetained)
```
