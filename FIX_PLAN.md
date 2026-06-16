# RAIN UpDown — Hacken Audit Fix Plan

**Audit:** Hacken — Smart Contract Code Review and Security Analysis Report for RAIN (UpDown)
**Report date:** 2026‑06‑08 (Preliminary)
**Audited commit:** `fccb622c`
**Scope:** `UpDownSettlement.sol`, `UpDownAutoCycler.sol`, `ChainlinkResolver.sol`
**Findings:** 22 total — 2 High, 10 Medium, 6 Low, 4 Info
**Plan date:** 2026‑06‑09 · **Remediation V2:** 2026‑06‑15

> ## ✅ STATUS — ALL 22 RESOLVED (Remediation V2, 2026‑06‑15)
> The PM chose **Option A — full auditor recommendations** ("we accept we aren't fully trustless given
> the off‑chain order book, so make it as safe as possible"). Every `Needs‑decision` finding in Part B
> below has now been **implemented to the auditor's recommended fix** via a custodial→non‑custodial
> inversion (on‑chain per‑user shares, two‑sided signed fills, signed fee caps, trustless redemption,
> keeper access‑control, tightened oracle window, rolling treasury budget). The 9 Part A fixes are
> retained. The design memo is **`REMEDIATION_V2.md`**; the lock‑step backend changes shipped in
> `updown-backend`.
>
> **Verification (V2):** `forge test` → **138 pass / 0 fail**; conservation invariant **128k fuzz calls
> / 0 reverts**; `forge build` clean. Backend: `tsc` clean, **514 jest tests pass**.
>
> The Part B sections below are preserved as the *engineering record of why each was gated*; each now
> carries a **DECIDED + IMPLEMENTED** note. The live per‑finding tracker is in
> `Hacken_RAIN_UpDown_Audit_Report.md`.

## How this plan was built

Every finding was independently re‑derived against the live code and tests, then run through an
adversarial verification pass (each "safe to fix now" verdict was attacked by a second reviewer that
tried to prove the fix changes an economic invariant, the EIP‑712 `Order` shape, the
`enterPosition`/`FillInputs` calldata ABI, the relayer trust model, or breaks the existing test
suite). A fix was only applied automatically when it was **localized, economically inert on the valid
path, required no lock‑step change to the off‑chain relayer/matching engine, and kept the full suite
green**. Everything else is documented below with a concrete recommended remediation and the specific
reason it needs a product/eng decision before it lands.

Baseline before changes: **145 tests pass**. After changes: **160 tests pass** (15 new regression
tests added; the audit explicitly noted negative‑case coverage was missing), `forge build` clean,
conservation invariants hold over 128k fuzz calls.

---

## Status at a glance

Legend: ✅ **Fixed (Part A)** = landed in the first localized pass · 🟢 **Resolved (V2)** = implemented
in Remediation V2 per Option A.

| # | ID | Sev | Title | Status |
|---|----|-----|-------|--------|
| 1 | F‑2026‑17726 | High | Permissionless upkeep fail‑forward corrupts slot pointer | 🟢 **Resolved (V2)** — forwarder gating + transient‑skip policy (recovery hatch from Part A kept) |
| 2 | F‑2026‑17756 | High | Fees always charged to buyer (taker‑pays violated) | 🟢 **Resolved (V2)** — taker pays, two‑sided signed fill |
| 3 | F‑2026‑17729 | Med | Permissionless strike capture drains LINK via per‑second keys | ✅ **Fixed (Part A)** (+ V2 authorized‑caller gate) |
| 4 | F‑2026‑17731 | Med | Relayer can charge arbitrary fees (no on‑chain bound) | 🟢 **Resolved (V2)** — signed `Order.maxFee` cap |
| 5 | F‑2026‑17757 | Med | Taker funds pulled without taker consent | 🟢 **Resolved (V2)** — on‑chain taker signature |
| 6 | F‑2026‑17760 | Med | Observation window allows favorable report selection | 🟢 **Resolved (V2)** — authorized callers + 3s tunable window |
| 7 | F‑2026‑17771 | Med | Backing reused across fills (non‑cumulative check) | 🟢 **Resolved (V2)** — per‑user share debit |
| 8 | F‑2026‑17772 | Med | Mint/burn lack per‑user accounting + user auth | 🟢 **Resolved (V2)** — `userShares` + `MintAuth` |
| 9 | F‑2026‑17776 | Med | Verified backing withdrawable via burn pre‑resolution | 🟢 **Resolved (V2)** — complete‑set burn gate |
| 10 | F‑2026‑17777 | Med | Filled positions have no on‑chain share accounting | 🟢 **Resolved (V2)** — `userShares` / `sharesOf` |
| 11 | F‑2026‑17778 | Med | No on‑chain settlement/redemption path for winners | 🟢 **Resolved (V2)** — trustless `redeem`/`redeemFor` |
| 12 | F‑2026‑17780 | Med | `performUpkeep` not idempotent, can skip slots | 🟢 **Resolved (V2)** — `plannedStart` idempotency |
| 13 | F‑2026‑17730 | Low | `makerFee` trapped when recipient is zero | ✅ **Fixed (Part A)** (V2 removed the field → structural) |
| 14 | F‑2026‑17759 | Low | `getPrice` can return zero/negative oracle value | ✅ **Fixed (Part A)** + V2 extended sign guard to live Streams `captureStrike`/`resolve`; per‑feed staleness Accepted (legacy view only) |
| 15 | F‑2026‑17774 | Low | `complementaryBurn` lacks market‑active guard | ✅ **Fixed (Part A)** |
| 16 | F‑2026‑17779 | Low | Relayer can drain treasury via unbounded rebate | 🟢 **Resolved (V2)** — rolling rebate budget |
| 17 | F‑2026‑17781 | Low | Missing `nonReentrant` on token‑moving functions | ✅ **Fixed (Part A)** |
| 18 | F‑2026‑17782 | Low | No mechanism to remove/deactivate a pair | ✅ **Fixed (Part A)** |
| 19 | F‑2026‑17727 | Info | Floating pragma | ✅ **Fixed (Part A)** |
| 20 | F‑2026‑17728 | Info | Missing two‑step ownership | ✅ **Fixed (Part A)** |
| 21 | F‑2026‑17739 | Info | Redundant `marketId`/`option` in `FillInputs` | 🟢 **Resolved (V2)** — `FillInputs` redesigned |
| 22 | F‑2026‑17746 | Info | Unused fee bps variables can mislead | 🟢 **Resolved (V2)** — bps + `setFees` removed |

**Resolved: 22 / 22.** (9 in the localized Part A pass; 13 in Remediation V2 per Option A.)

---

## Part A — Fixes applied (in this branch)

All changes carry inline `F-2026-…` references. Diff: `src/ChainlinkResolver.sol`,
`src/UpDownAutoCycler.sol`, `src/UpDownSettlement.sol`, plus `test/AuditFixes.t.sol` (new) and a
one‑line precondition alignment in `test/UpDownPROInvariant.t.sol`.

### F‑2026‑17729 — Strike‑capture LINK drain (Medium) ✅
`captureStrike` was permissionless and paid a LINK verify fee on every cache miss, keyed by
`(pairId, startTime)` with no alignment requirement — so one valid report (observation `T`) was
reusable across the 61 integer seconds in `[T-30, T+30]`, each a distinct paid verify.
**Fix:** require `startTime % STRIKE_ALIGNMENT == 0` (`STRIKE_ALIGNMENT = 300`, the smallest
timeframe and the GCD of `{300, 900, 3600}`) as the very first statement in `captureStrike`, before
the dedup‑cache check. Every legitimate `plannedStart` is already 300‑aligned, so the cycler is
unaffected, and the 61× amplification collapses to the single real boundary in any window.
**Why this and not the audit's "restrict to authorized callers":** the resolve/capture paths are
*permissionless by design* (mirrors `resolve()`); alignment closes the drain without changing that
design contract. Restricting access is still available as defense‑in‑depth (see F‑17760) but is a
design change, not a localized fix. Regression: `test_F17729_unalignedStartReverts`,
`test_F17729_alignedStartPassesAlignmentGate`.

### F‑2026‑17730 — `makerFee` trapped when recipient is zero (Low) ✅
A fill with `makerFee > 0` and `makerFeeRecipient == address(0)` still pulled the fee from the buyer,
but the outflow was skipped and the fee was never added to `marketRetained` → stranded, breaking the
`balanceOf(this) == Σ marketRetained` conservation invariant.
**Fix:** add `if (f.makerFee > 0 && f.makerFeeRecipient == address(0)) revert ZeroAddress();` right
beside the existing `platformFee`/`treasury` guard, before any token movement. Reuses the existing
error; rejects only an already‑malformed input. Regression: `test_F17730_makerFeeWithZeroRecipientReverts`
(+ positive control).

### F‑2026‑17759 — `getPrice` can return zero/negative (Low) ✅
`_getLatestPrice` returned the Data Feeds answer after a staleness check only. A broken/circuit‑broken
feed (or one clamped at `min/maxAnswer`) could surface `0` or a negative value as a valid price.
**Fix:** add `if (price <= 0) revert InvalidPrice();` after the staleness check.
Note: `getPrice` is documented **legacy** (the live strike path is Data Streams `captureStrike`), so
this is hardening of an external view with no production caller today.
**V2 / post‑review extension (so the finding is defensibly closed on the path that matters):** the
post‑remediation review flagged that the sign guard sat *only* on the dead legacy view while the
production strike/settlement reads `report.price` directly. The same `if (report.price <= 0) revert
InvalidPrice();` guard was therefore added to the live Streams paths — `captureStrike` (before
`strikePrice = int256(report.price)`) and `resolve` (before the UP/DOWN threshold). New regressions:
`test_F17759_resolve_revertsZeroStreamsPrice`, `test_F17759_resolve_revertsNegativeStreamsPrice`,
`test_F17759_captureStrike_revertsNonPositiveStreamsPrice` (+ the original legacy‑view
`test_F17759_zeroPriceReverts` / `_negativePriceReverts` / `_positivePricePasses`).
**Per‑feed staleness — Accepted (by design):** the `MAX_STALENESS` heartbeat concern applies to
`_getLatestPrice` (Data Feeds), which has no production caller post‑migration. The live Streams path
enforces freshness via the tightened observation window (`maxStrikeReportLag` / `maxReportObservationLag`,
default 3s, F‑17760), not `MAX_STALENESS`, so a per‑feed staleness map on the dead path was not
implemented. Documented in the Hacken response.

### F‑2026‑17774 — `complementaryBurn` missing market‑active guard (Low) ✅
`complementaryMint` requires the market be open (`block.timestamp < endTime`); `complementaryBurn`
only checked `startTime != 0 && !resolved`, leaving the guaranteed expiry‑to‑resolution window open
for the relayer to burn the entire `marketRetained` to an arbitrary address — after which
`withdrawSettlement` transfers `0` to pay winners.
**Fix:** add the symmetric `if (block.timestamp >= uint256(m.endTime)) revert MarketNotOpen();` to
`complementaryBurn`. Burns, like mints, are only valid while the market is open. The invariant handler
`fuzzBurn` now skips expired markets to match the new precondition. Regression:
`test_F17774_burnAfterExpiryReverts` (+ positive control).

### F‑2026‑17781 — Missing `nonReentrant` (Low) ✅
`UpDownSettlement` did not inherit `ReentrancyGuard`, and in `enterPosition` three outbound transfers
run *before* `cashUpFlow/cashDownFlow` and `marketRetained` are updated (a CEI ordering gap). Not
exploitable with plain USDT, but it materializes for any future callback‑capable collateral token.
**Fix:** inherit OpenZeppelin `ReentrancyGuard`; add `nonReentrant` to the five token‑moving externals
(`enterPosition`, `complementaryMint`, `complementaryBurn`, `withdrawSettlement`, `claimRebate`) and to
`executeEmergencyWithdraw`. `accumulateRebate` is intentionally left unguarded (no token movement).
`enterPosition` gas stays well under the test budget (~126k vs 230k cap).
**V2 update:** the V2 fee/redemption redesign removed `withdrawSettlement` and added
`mint`/`burn`/`redeem`/`redeemFor`, so the final guarded set is the **nine** token‑moving externals —
`enterPosition`, `complementaryMint`, `mint`, `complementaryBurn`, `burn`, `redeem`, `redeemFor`,
`claimRebate`, `executeEmergencyWithdraw` (`accumulateRebate` still unguarded, no token movement). The
guard is now also covered by PoC regression tests (`SettlementReentrancyTest` in `test/AuditFixes.t.sol`:
same‑function and cross‑function re‑entry during a payout both revert `ReentrancyGuardReentrantCall`),
in addition to the structural defense (CEI ordering + a balance‑neutral `enterPosition`).

### F‑2026‑17782 — No way to remove/deactivate a pair (Low) ✅
`addPair` had no inverse, so a pair that must be halted (deprecated stream feed, misconfig, incident)
could not be stopped without deprecating the whole cycler.
**Fix:** add owner‑only `removePair(bytes32)` that sets `supportedPairs[pairId] = false` and
swap‑and‑pops it from `_cyclingPairs` (clearing `isCyclingPair` so a later `addPair` re‑adds cleanly),
emitting `PairRemoved`. `checkUpkeep` and `_createMarket` already gate on `supportedPairs`, so creation
stops immediately; existing open markets still resolve normally. Regression:
`test_F17782_removePairDeactivatesAndReAdds`, `test_F17782_removePairOnlyOwner`.

### F‑2026‑17727 — Floating pragma (Info) ✅
Pinned `^0.8.29` → `0.8.29` in all three core contracts (matches `foundry.toml solc = "0.8.29"`).

### F‑2026‑17728 — Two‑step ownership (Info) ✅
Switched all three contracts from `Ownable` to `Ownable2Step` (kept the `Ownable` import for the
constructor base‑call). A new owner must now call `acceptOwnership()`, preventing an irreversible
mistyped transfer. **Ops note:** any post‑deploy ownership handoff is now a two‑step
`transferOwnership` → `acceptOwnership`; update deploy/ops runbooks. Regression:
`test_F17728_twoStepOwnership`.

### F‑2026‑17726 — Permissionless upkeep fail‑forward (High) ⚠️ Partial → 🟢 Closed in V2
**Applied now (safe):** owner‑only `setPairTfLastCreated(pairId, tfIdx, value)` recovery hatch +
`PairTfLastCreatedReset` event. Before this, a corrupted `pairTfLastCreated` pointer could only be
repaired by `deprecate()` + a full bundle redeploy; now the owner can reset it and let `checkUpkeep`
re‑schedule the skipped boundaries. Regression: `test_F17726_setPairTfLastCreated*` (3 tests).
**Access‑control prong landed in Remediation V2** (see Part B / `REMEDIATION_V2.md`): `performUpkeep`
gated on `forwarder || owner`, and the pointer now advances only on permanent `PlannedStartTooStale`
skips. The recovery hatch is retained as defense‑in‑depth. **The High is now fully closed.**

---

## Part B — ~~Needs decision~~ → 🟢 RESOLVED in Remediation V2

> **All of Part B is now implemented.** The PM chose **Option A — full auditor recommendations**
> (2026‑06‑15), so every gated item below was built to the auditor's recommended fix. Each subsection
> keeps its original "why it was gated" analysis as the engineering record and is prefixed with a
> **✅ IMPLEMENTED (V2)** line describing what actually shipped. The coupled trust‑model decision
> (`COWORK.md`'s "explicitly custodial" note) was **reversed** — on‑chain `userShares` are now the
> source of truth and the off‑chain ledger derives from chain events. Full design: `REMEDIATION_V2.md`.

These were real findings with concrete fixes, but each changed an economic invariant, the signed
`Order`/calldata ABI, the relayer trust model, or conflicted with the (now‑superseded) custodial
architecture. They were decided with the off‑chain/matching‑engine owners and re‑tested before merge.

### F‑2026‑17726 — Restrict `performUpkeep` access (High)
> **✅ IMPLEMENTED (V2):** added owner‑settable `forwarder` + `setForwarder`; `performUpkeep` requires
> `msg.sender == forwarder || owner()`. The catch advances `pairTfLastCreated` **only** on
> `PlannedStartTooStale` (a genuine permanent skip); transient report failures no longer advance it.
> Deploy seeds `forwarder = relayer` (cron wallet); rotate to the Automation forwarder once registered.
> Tests `test_F17726_*`.

**The core of the High.** `performUpkeep` is permissionless and its fail‑forward catch advances
`pairTfLastCreated` on any `_createMarketExternal` revert. An attacker submits many `CreateSlot`s with
an empty `signedReport` (→ `captureStrike` reverts) in one tx and pushes the pointer arbitrarily far
forward, halting market creation for the targeted pair/timeframe (5‑min pointer ~25h per 300 iters;
60‑min ~12d). Zero capital, gas only.
**Recommended fix:** gate `performUpkeep` on the Chainlink Automation forwarder — add an owner‑settable
`forwarder` and require `msg.sender == forwarder || msg.sender == owner()`. Pair it with *not* advancing
the pointer on transient (invalid/unavailable report) failures vs. genuine permanent skips.
**Why gated:** the forwarder address only exists *after* the upkeep is registered, so this introduces a
post‑deploy `setForwarder` step and a keeper‑wiring dependency (if unset, only the owner can drive the
cycler — fail‑safe but it must be in the runbook). Distinguishing transient vs. permanent failures
re‑interprets the intentionally‑documented F‑06 fail‑forward semantics and edits ~3 existing
fail‑forward tests. **Decision needed:** confirm the Automation wiring (forwarder gating) and the
transient‑failure policy. The recovery hatch (Part A) is already in to bound the blast radius.

### F‑2026‑17756 — Taker‑pays fee model (High)
> **✅ IMPLEMENTED (V2):** `enterPosition` is now a two‑sided signed match (`makerOrder` +
> `takerOrder`); `cashPart` moves buyer→seller peer‑to‑peer and `platformFee + makerFee` are pulled
> from the **taker** (`takerOrder.maker`) regardless of direction. Backend `SettlementService` builds
> the dual‑order fill (maker = `makerFeeRecipient`, taker = the other side). Tests
> `test_F17756_takerPaysFees_{makerIsSeller,makerIsBuyer}`. (Also resolves F‑17746 — bps removed.)

Fees are charged by trade **direction** (`enterPosition` pulls `cashPart + platformFee + makerFee` from
whoever is the buyer) instead of trade **role**. For a BUY‑maker fill, the resting maker(buyer) wrongly
pays both fees and the aggressor taker(seller) pays nothing — the team‑confirmed model is "all fees
paid by taker."
**Recommended fix:** split the pull — `safeTransferFrom(buyer, this, cashPart)`, then
`feePayer = f.taker == address(0) ? buyer : f.taker; if (feeTotal > 0) safeTransferFrom(feePayer, this, platformFee + makerFee)`.
**Why gated:** (1) changes who‑pays (real economic incidence); (2) requires the off‑chain relayer to
ensure the *taker* wallet holds USDT and has approved the contract (today only the buyer's allowance is
assumed) — lock‑step off‑chain change; (3) needs a `taker == address(0)` fallback for the
initial‑issuance path or it reverts. The conservation invariant suite hard‑codes zero fees, so it would
**not** catch a botched change — new both‑direction + `taker==0` tests are required. **Decision needed:**
confirm taker‑pays is final, then ship contract + relayer + tests together. (Resolves F‑17746 too.)

### F‑2026‑17731 — Signed fee caps (Medium)
> **✅ IMPLEMENTED (V2):** chose a single `maxFee` added to the `Order` struct → new `ORDER_TYPEHASH`.
> `enterPosition` enforces `platformFee + makerFee <= takerOrder.maxFee`. Lock‑step signer change
> shipped (config `EIP712_ORDER_TYPES`, `signOrder`, SDK `eip712.ts`, `Order` model, `/orders`); the
> signer sets `maxFee` to the full‑amount taker fee at the order's price (a safe per‑fill ceiling).
> Test `test_F17731_feeCap_enforced`.

`platformFee`/`makerFee` are unbounded relayer calldata; the signed `Order` has no fee field, so a
malicious/compromised relayer can pull up to a buyer's full USDT approval per fill.
**Recommended fix:** add `maxPlatformFee`/`maxMakerFee` (or a single `maxFee`) to the `Order` struct so
the ceiling is part of the maker's EIP‑712 signature; check the relayer‑supplied fees against it in
`enterPosition`.
**Why gated:** changes `ORDER_TYPEHASH` and the signed typed‑data shape → the off‑chain signer/verifier
must change in lock‑step or every fill reverts on `InvalidSignature`. **Decision needed:** coordinate the
typed‑data change with the matching engine; bundle with F‑17756/F‑17746 as one fee‑model PR.

### F‑2026‑17757 — Taker consent (Medium)
> **✅ IMPLEMENTED (V2):** `FillInputs` now carries `takerOrder` + `takerSignature`; both maker and
> taker EIP‑712 orders are verified on‑chain before any taker funds/shares move. Reuses the order the
> taker already signs into the book — no new signing flow. Test `test_F17757_invalidTakerSignature_reverts`.

Only the maker signs; `f.taker` is relayer calldata and never authorizes the trade, so any address with
an open approval can be forced into a position at the relayer's discretion.
**Recommended fix:** verify a taker EIP‑712 signature on‑chain before pulling taker funds.
**Why gated:** adds a new typehash + a `FillInputs` field + taker replay bookkeeping, and the matching
engine must start collecting/forwarding taker signatures — a relayer trust‑model shift. **Decision
needed:** product call on whether to move taker consent on‑chain (vs. the documented custodial v1 trust
assumption) and the matching‑engine work to support it.

### F‑2026‑17760 — Observation‑window favorable selection (Medium)
> **✅ IMPLEMENTED (V2):** took **both** prongs. `resolve`/`captureStrike` are now `onlyAuthorized`
> (cycler + resolver service), removing the permissionless front‑run; and the window is an
> owner‑tunable `maxReportObservationLag` (default **3s**, hard‑capped ≤30s). Reliably hittable since
> `ChainlinkResolverService` fetches the report by `timestamp = endTime`. No backend timing change needed.

`resolve` (and `captureStrike`) accept any DON report whose observation timestamp falls in a ±30s
window, then decide a binary outcome by strict threshold. A position holder can front‑run the relayer
with the most favorable still‑valid report when spot oscillates around strike in the final seconds.
**Recommended fix:** tighten the window toward `obs == endTime` (a few seconds), and/or move
resolution/capture to a commit‑or‑authorized path. The ±30s "essentially the same price" premise is the
flaw — in a binary market a 1‑cent cross flips the whole payout.
**Why gated:** tightening interacts with the off‑chain `ChainlinkResolverService` fetch timing (too
tight → legitimate resolves fail and markets stall), and any authorization prong contradicts the
permissionless design and the cycler's permissionless `captureStrike` call. **Decision needed:** the
tolerance the off‑chain service can reliably hit, and whether to accept submitter discretion within it
or adopt a commit/authorized resolver. (Cheapest hardening: combine alignment from F‑17729 — already in
— with a tighter `MAX_REPORT_OBSERVATION_LAG`, tuned against the live fetcher.)

### F‑2026‑17771 / F‑2026‑17776 — Backing reuse & withdrawable backing (Medium ×2)
> **✅ IMPLEMENTED (V2):** chose the auditor's *preferred* alternative — per‑user complete‑set
> accounting — over the `upReserved`/`marketAllocated` earmark (which carried the flagged lock‑in risk).
> A fill debits the **seller's own** `userShares` (no pooled reuse → F‑17771), and `burn`/`complementaryBurn`
> require the holder own a complete set (`UP & DOWN ≥ amount`), so a maker who sold their UP can no
> longer pull the backing under a live position (→ F‑17776). New invariant
> `marketRetained == optionShares[UP] == optionShares[DOWN]` holds over 128k fuzz calls. Tests `test_F17771_*`,
> `test_F17776_*`. The lock‑in concern is moot — burns consume the holder's own set, not a global earmark.

The `NoBackingForSeller` guard checks `marketRetained` per fill, but under Option B (`sellerReceives ==
cashPart`) `marketRetained` is never decremented by a fill — so the same pooled backing satisfies every
fill independently (17771), and the snapshot backing a position can later be withdrawn via
`complementaryBurn` before resolution (17776), leaving winners under‑collateralized.
**Recommended fix:** track allocated/reserved backing on‑chain — e.g. `upReserved`/`downReserved` per
market (17771) and/or a `marketAllocated` earmark incremented by `mintBackingDelta` on each fill, with
`complementaryBurn` releasing only the unallocated remainder (17776).
**Why gated:** both introduce a *new* conservation invariant (`marketRetained >= allocated`) that changes
`enterPosition` acceptance semantics (a fill that reused committed backing previously succeeded and now
reverts), and a naive `marketAllocated` that only ever increments creates a **new lock‑in bug** —
allocated backing can never be burned before resolution, permanently stranding makers' legitimate
pre‑resolution burns (verified: it needs a relayer de‑allocate/position‑exit entrypoint + lock‑step
matching‑engine signaling). The on‑chain reservation must become authoritative for the off‑chain ledger.
**Decision needed:** adopt on‑chain backing reservation as system‑of‑record (couples with F‑17772/17777),
or keep the documented relayer‑trust v1 and accept the risk explicitly. *(Note: the existing test suite
stays green under a naive patch — the danger is exactly that it hides the lock‑in; do not auto‑apply.)*

### F‑2026‑17772 / F‑2026‑17777 / F‑2026‑17778 — On‑chain share accounting, provability & redemption (Medium ×3)
> **✅ IMPLEMENTED (V2) — the central decision was made: invert to trust‑minimized on‑chain accounting.**
> `userShares[marketId][user][option]` is now authoritative and updated atomically in
> `enterPosition`/mint/burn (→ F‑17772/17777, provable from `sharesOf` + events). Mint/burn require the
> user's EIP‑712 `MintAuth` (replay‑protected) **plus** self‑service `mint`/`burn`. Trustless
> `redeem(marketId)` + relayer‑assisted `redeemFor(marketId, holders[])` (pays each holder's own wallet)
> replace the removed `withdrawSettlement` (→ F‑17778). Backend re‑architected: `SettlementService`
> signs `MintAuth`; `ClaimService` uses `redeemFor`; the off‑chain ledger now derives from chain.
> Tests `test_F17772_*`, `test_F17778_*` + the conservation invariant.

`enterPosition`/`complementaryMint`/`complementaryBurn` record no per‑user share balances on‑chain;
`complementaryBurn` checks only aggregate `marketRetained` and takes no user authorization; and there is
no trustless on‑chain redemption — `withdrawSettlement` pushes the entire pool to the relayer, which
pays winners off‑chain. A relayer DB loss/desync/compromise leaves positions unprovable and winners with
no on‑chain recourse.
**Recommended fix:** persist `userShares[marketId][user][option]` updated atomically in
enter/mint/burn, gate burns on per‑user balances, require user authorization (EIP‑712 mint/burn intent),
and add a trustless `redeem()` against on‑chain balances after `resolve`.
**Why gated — this is the central product decision.** It directly contradicts the **locked custodial
design** (off‑chain Mongo ledger is system‑of‑record; on‑chain positions belong to the relayer wallet).
Implementing it inverts the trust model, requires the matching engine to derive from indexed events
instead of Mongo, and would break ~12+ tests that assert the custodial payout flow. **Decision needed:**
does RAIN want to move (partially) to a trust‑minimized on‑chain model, or formally accept and document
the custodial trust assumption (and mitigate operationally — relayer key management, ledger backups,
solvency monitoring)? If staying custodial, mark these *Accepted (by design)* in the audit response with
this rationale.

### F‑2026‑17780 — `performUpkeep` idempotency (Medium)
> **✅ IMPLEMENTED (V2):** `slot.plannedStart` is threaded through `_createMarketExternal`/`_createMarket`
> and validated against the expected next slot; a replayed/duplicate `performData` is a clean no‑op
> (emits `SlotAlreadyProcessed`, no double‑create, no fail‑forward). Test `test_F17780_stalePlannedStart_isNoOp`.

`_createMarket` ignores `slot.plannedStart` and recomputes the next slot from `pairTfLastCreated`, so a
duplicate/replayed `performData` skips a valid future slot (the carried report no longer matches the
recomputed boundary → `captureStrike` reverts → fail‑forward advances again).
**Recommended fix:** thread `slot.plannedStart` through `_createMarketExternal`/`_createMarket`,
validate it equals the expected next slot, and no‑op (don't advance) when already processed.
**Why gated:** `plannedStart` already exists in `CreateSlot` (no ABI change), but a robust fix against an
adversarial `plannedStart == 0` reinterprets the F‑06 fail‑forward semantics and requires editing ~5
`plannedStart: 0` tests + the harness wrappers. Best decided **together with F‑17726** (access control
largely removes the adversarial‑replay surface). **Decision needed:** the idempotency/sentinel policy,
alongside the keeper access‑control decision.

### F‑2026‑17779 — Treasury drain via unbounded rebate (Low)
> **✅ IMPLEMENTED (V2):** `claimRebate` is now capped by an owner‑set rolling window budget
> (`rebateBudgetPerWindow` / `rebateWindowDuration`, via `setRebateBudget`); even with a standing
> treasury approval a compromised relayer drains at most one window's budget. Default budget `0`
> (fail‑safe); deploy seeds 5,000 USDT / 7‑day. Tests `test_F17779_*`.

`accumulateRebate` (onlyRelayer) increments any maker's accumulator by an unbounded amount; `claimRebate`
pulls from the treasury EOA, which holds a standing **unlimited** approval — so a compromised relayer can
accrue then drain the treasury in one tx.
**Scope note (verified):** *user collateral is already segregated* — the treasury only ever receives
`platformFee`; buyer `cashPart` and mint deposits stay in the settlement contract as `marketRetained`. So
the exposure is **protocol‑owned treasury funds**, not user funds.
**Recommended fix (operational):** drop the standing unlimited approval in favor of a rolling, periodically
re‑issued rebate budget (weekly allowance), so a compromised relayer can drain at most one budget window.
Optionally add an owner‑settable per‑accrual / per‑window cap as a cheap on‑chain circuit‑breaker.
**Why gated:** the real fix is a treasury approval/ops change, not a contract one; the optional cap is a
default‑disabled lever (no‑op until configured) and doesn't close the finding alone, so it's offered, not
auto‑applied. **Decision needed:** treasury approval policy + whether to add the cap lever.

### F‑2026‑17739 — Redundant `marketId`/`option` in `FillInputs` (Info)
> **✅ IMPLEMENTED (V2):** folded into the fee‑model ABI revision. `FillInputs` is fully redesigned —
> `marketId`, `option`, `taker`, `sellerReceives`, and `makerFeeRecipient` are all removed; every value
> is derived from the two signed orders.

These duplicate `order.market`/`order.option`, which the signature already binds — the
`MarketMismatch`/`OptionMismatch` checks add no security.
**Recommended fix:** drop the two fields and use `f.order.market`/`f.order.option`.
**Why gated:** mutates the `enterPosition`/`FillInputs` calldata tuple the off‑chain relayer encodes — a
lock‑step ABI change for a cosmetic/gas gain. Low priority; fold into the next relayer ABI revision (with
F‑17731). The current code comments document these as intentional backend‑shape matches.

### F‑2026‑17746 — Unused fee bps variables (Info)
> **✅ IMPLEMENTED (V2):** chose **remove** (the p(1−p) fee formula isn't a fixed bps, so on‑chain
> enforcement wasn't meaningful — the signed `maxFee` cap is the real protection). `platformFeeBps`,
> `makerFeeBps`, `setFees`, and the two constructor params are gone; `Deploy.s.sol` updated.

`platformFeeBps`/`makerFeeBps` are stored/settable but never read by `enterPosition` (fees are
relayer‑supplied absolutes), so on‑chain config can diverge from enforced fees and mislead monitors.
**Recommended fix:** either enforce the configured bps on‑chain (recompute expected fees, revert on
mismatch) or remove the variables.
**Why gated:** enforcement changes economics + needs the off‑chain fee base/rounding to match exactly;
removal changes the constructor ABI (breaks `Deploy.s.sol` + deploy sites). **Decision needed:** resolve
as part of the fee‑model PR (F‑17756/F‑17731).

---

## Sequencing — as executed

The plan below was the *proposed* order; Remediation V2 executed it as one coordinated change (the
trust‑model inversion couples Blocks 1–2). For the record:

1. **Done (Part A):** the 9 localized fixes — independent, low‑risk, green.
2. **Keeper hardening:** F‑17726 (forwarder gating) + F‑17780 (idempotency) — contract‑local + deploy `setForwarder`.
3. **Fee model:** F‑17756 + F‑17731 + F‑17746 + F‑17739 — one EIP‑712/ABI change, coordinated with the
   matching engine. (`taker == 0` is unreachable in practice — every fill has a real two‑sided match —
   so the bootstrap fallback wasn't needed.)
4. **Oracle window:** F‑17760 — authorized callers + 3s tunable window (no live‑fetcher change needed,
   it fetches by `timestamp = endTime`).
5. **Trust model:** F‑17772/17777/17778/17771/17776/17757 — inverted to trust‑minimized on‑chain
   accounting. F‑17779 treasury budget rode along.

## Open decisions for the team — all resolved (2026‑06‑15)

- [x] **Custodial vs. trust‑minimized?** → **Trust‑minimized.** Inverted to on‑chain `userShares` + trustless `redeem`.
- [x] **Taker‑pays fee model** confirmed final → shipped F‑17756/17731/17746 + dual‑order relayer change.
- [x] **Keeper access control:** forwarder gating + transient‑failure policy (F‑17726/17780).
- [x] **Oracle observation tolerance:** 3s default, owner‑tunable, hard‑capped 30s + authorized callers (F‑17760).
- [x] **Treasury approval policy:** rolling per‑window rebate budget (F‑17779).

## Verification (Remediation V2)

```
# Contracts
forge build                          # clean (only pre-existing style lints)
forge test --no-match-contract Fork
# 138 passed, 0 failed (9 suites)
# invariant_balanceEqualsSumOfRetained      : 256 runs / 128000 calls / 0 reverts
# invariant_retainedBacksOutstandingShares  : 256 runs / 128000 calls / 0 reverts

# Backend (updown-backend) — lock-step changes
npx tsc --noEmit                     # clean
npx jest                             # 514 passed, 0 failed (59 suites)
```

> Note on the test count vs. Part A's "160": Remediation V2 replaced the obsolete single‑order
> settlement suites (which asserted the now‑removed `withdrawSettlement` / fee‑on‑buyer / pooled‑backing
> behavior) with a new `RemediationV2.t.sol` proof suite + a rewritten conservation invariant; the
> post‑remediation review then added regression tests (cumulative fee cap, Streams‑only `registerMarket`,
> keeper access‑control + idempotency, tightened oracle window, and the F‑17759 zero/negative‑price
> guard on the live Streams `captureStrike`/`resolve` paths), bringing the headline number to 124. A
> later regression pass then added reentrancy PoC tests (`SettlementReentrancyTest` — same- and
> cross-function re-entry during a payout), the tightened 3s observation-window boundary (accept at
> `endTime-3`, reject at `endTime-4`, default-asserted), and dual-order binding negative cases
> (`MarketMismatch`/`OptionMismatch`/`NotBuySellPair`/`OrdersNotCrossed`/invalid-maker-sig), plus
> signature/order probe suites, bringing it to **138**.
> The backend likewise dropped the obsolete `admin` route + `FeeWithdrawalService` suites (which tested
> the removed `withdrawSettlement` flow), so its count settled at 514.
