# RAIN UpDown — Concerns & Decisions for Product Sign-off

> ## ✅ DECIDED & IMPLEMENTED (2026‑06‑15)
> The PM made the call: **"Go A — full auditor recommendations. We accept we aren't fully trustless
> given the off‑chain order book, so make it as safe as possible."** All 5 concerns / 13 gated findings
> below have been **implemented to the auditor's recommended fix** — including the big one (Concern #1):
> the trust model was **inverted from custodial to non‑custodial on principal** (positions are now
> on‑chain per‑user shares; winners redeem trustlessly). The operator keeps only the two powers an
> off‑chain order book inherently requires — **matching liveness** and **resolution correctness** — and
> can no longer **steal funds, force positions, inflate fees, or withhold winnings** (exactly the
> Polymarket‑parity boundary in the table below).
>
> Engineering: contracts **138 tests + 128k‑call invariant**, backend **514 tests**, all green. Design
> memo: **`REMEDIATION_V2.md`**. Per‑finding tracker: `Hacken_RAIN_UpDown_Audit_Report.md`.
>
> *The original decision framing is preserved below as the record of how the call was reached; each
> concern now carries a **DECISION** note.*

**What this is (as originally written):** The Hacken security audit surfaced 22 findings. We'd already
fixed the 9 that were safe to fix without changing the product. The remaining 13 were not "bugs we can
quietly patch" — they were **product/architecture decisions that needed a founder/PM call** before they
could land, because each changes how money moves, what the backend is trusted to do, or what we promise
users.

This document collects all of those concerns in plain language, ordered by importance. **Concern #1 was
the one that mattered most and was raised first** — it's written as a ready-to-send message. The rest
are framed enough to turn into follow-up messages.

**Audit:** Hacken — Smart Contract Code Review for RAIN (UpDown) · commit `fccb622c` · 2 High, 10 Medium,
6 Low, 4 Info.

---

## At a glance

| # | Concern | Plain-English risk | Decision owner | Audit findings | Decision (2026‑06‑15) |
|---|---------|--------------------|----------------|----------------|----------------------|
| **1** | **Who controls user funds** | All user money + positions sit under one wallet + one database we run. Key theft or DB loss = users can lose everything with no on-chain recourse. | **Founder/PM** (architecture) | F-17772, 17777, 17778, 17757, 17771, 17776 | ✅ **Inverted to non‑custodial** — on‑chain per‑user shares + trustless `redeem` |
| 2 | Fee model | Fees charged to the wrong side; no cap on fee size — a bug/compromise could charge a user their whole balance. | PM + backend | F-17756, 17731, 17746, 17739 | ✅ **Taker pays + signed `maxFee` cap** |
| 3 | Keeper griefing | Anyone can spam the market-creation function for free and freeze new markets for hours/days. | Eng (contract-fixable) | F-17726, 17780 | ✅ **Forwarder‑gated + idempotent** |
| 4 | Oracle timing window | Resolution accepts any price within ±30s of close; in a binary market a 1¢ move flips the whole payout. | PM + oracle ops | F-17760 | ✅ **Authorized callers + 3s window** |
| 5 | Treasury approval | Backend has *unlimited* permission to pull from the treasury wallet — key theft drains it in one tx (protocol money, not user funds). | PM + ops | F-17779 | ✅ **Rolling per‑window rebate budget** |

**All 22 now resolved.** The first 9 (Part A): strike-capture LINK drain, trapped maker fee, zero/negative
price guard, burn market-active guard, reentrancy guards, pair deactivation, pinned compiler, two-step
ownership, and an owner recovery hatch for the keeper. The remaining 13 (the 5 concerns above) landed in
Remediation V2. (See `FIX_PLAN.md` for the per-finding plan + `REMEDIATION_V2.md` for the design.)

---

# Concern #1 (raise now): Who controls user funds

This is the most important finding in the audit and the only one that's a pure product decision. Below
is a short **first-touch WhatsApp message** — it just names the issue and proposes how to go deeper (a
quick call, or a written doc first). The supporting detail and the exact decision follow it, for when
that conversation actually happens.

## 📩 Message to [PM] (first WhatsApp — opener only)

> Hi [name] — wanted to introduce myself and flag one thing. The security audit on the contracts came
> back. Most of it is stuff we can just fix on our end, but there's one finding I want to raise on its
> own, because it's not really a bug — it's a product decision, and it's yours to make.
>
> Short version: right now all user funds and positions sit under one wallet + one database that we run,
> so the blockchain doesn't actually track who owns what. It's the same root issue behind about six of
> the findings, and there's a real call to make on how we handle it before launch. (For context —
> Polymarket runs the same kind of centralized backend we do, and last month they had a backend key
> stolen and ~$500–700K drained, but zero user funds were lost because of how they set this part up.
> Worth us deciding deliberately.)
>
> It's too much for a text and I'd rather not get it wrong. Could we grab ~30 min to talk it through?
> Or if you'd prefer to read first, I can write it up as a short doc and send it over ahead of a call —
> whatever's easiest for you.

*Why this shape:* it's a cold first contact, so it earns attention without dumping the whole decision on
someone with no context. It names the topic, gives just enough ("six findings", the Polymarket incident)
to signal this is real and not routine, and hands them the choice of format. The full two-direction
decision, recommendation, and Polymarket parity table below are what you bring to the call — or fold into
the doc if [name] picks that route.

## Supporting detail: how Polymarket solves this (verified against their live contracts)

The key insight: **centralized matching ≠ custodial.** Polymarket's backend is centralized for
*matching*, but the trust boundary is drawn at the smart contract, not at the company database. Every
mechanism below is enforced by their deployed contracts (Gnosis Conditional Tokens `0x4d97…6045` and the
`ctf-exchange`), not marketing claims:

| Protection | How Polymarket does it (contract-enforced) | What RAIN did (pre‑V2) | What RAIN does now (V2) ✅ |
|---|---|---|---|
| **Positions on-chain, per-user** | Each position is an ERC-1155 token in the *user's own* wallet; anyone can prove holdings; user can redeem with only their key even if Polymarket is offline. No company ledger. | Positions live only in MongoDB; chain holds one pooled relayer balance. | `userShares[market][user][option]` on‑chain + `sharesOf` getter; Mongo derives from events. |
| **Both sides sign every trade** | The taker is a fully signed order, validated on-chain before any funds move. The backend can't force anyone into a position. | Only the maker signs; the taker is unsigned backend data → anyone with an approval can be conscripted. | `enterPosition` verifies **both** the maker and taker EIP‑712 orders on‑chain. |
| **Trustless redemption** | After resolution, any winner claims their payout directly from the contract — no dependence on the operator paying out. | Backend pushes the whole pool to itself and pays winners off-chain. | `redeem(marketId)` (self) + `redeemFor(holders[])` (pays each holder's own wallet); `withdrawSettlement` removed. |
| **Fees signed + hard-capped** | Fee rate is inside the user's signed order *and* capped on-chain at 10% with no override. Backend can only refund *down*. | Fee is unbounded backend data; no cap the user agreed to. | Signed `Order.maxFee`; `platformFee + makerFee <= takerOrder.maxFee` enforced on‑chain; fees pulled from the taker. |
| **Backing locked 1:1** | Collateral is locked into the contract when tokens are minted; no admin sweep; can't be reused or pulled from under another holder. | Pooled backing is never reserved per trade; can be reused or withdrawn pre-resolution. | A fill debits the seller's own shares; `burn` needs a complete set; invariant `marketRetained == optionShares[UP] == optionShares[DOWN]`. |

**Honest caveat (so we don't over-promise):** even at full Polymarket parity, the operator is *not*
trustless — it's *non-custodial*. The backend can still censor/reorder/pause trading and influence which
outcome a market resolves to (Polymarket's biggest real-world problems are contested resolutions, not
theft). Adopting this removes the power to *steal funds, force positions, inflate fees, or withhold
winnings* — it does **not** remove the power to *degrade service* or *get a resolution wrong*. That last
part is the analog of our own oracle-window concern (#4).

## The decision we need (technical framing)

> **🟢 DECISION (2026‑06‑15): Option A — invert to on‑chain accounting now.** The PM chose the
> trust‑minimized model over custodial‑v1. All three sub‑questions resolved in that direction and shipped:

- **Q1 — Trust model:** ~~Recommended: custodial v1~~ → **DECIDED: invert to on‑chain accounting.**
  `userShares[market][user][option]` is authoritative; the Mongo ledger now *derives* from chain events.
  The `balanceOf == Σ marketRetained` invariant still holds (128k fuzz calls), now alongside
  `marketRetained == optionShares[UP] == optionShares[DOWN]`.
- **Q2 — Cheap protections:** all adopted — taker signature (F-17757), signed fee cap (F-17731), rolling
  treasury budget (F-17779). The "middle path" on-chain reserved backing (F-17771/17776) was superseded
  by the stronger per-user complete-set model (the auditor's *preferred* alternative).
- **Q3 — Roadmap:** the "v2" non-custodial work was pulled forward into this release. The
  `ThinWallet`/`ThinWalletFactory` + ERC-1271 primitives we already ship are what made it feasible now.

**~~Why not full parity now~~ — superseded:** the original recommendation was to defer the inversion (it
breaks ~12+ tests and is a multi-PR contract+backend migration). The PM elected to take that cost now for
maximum safety. In practice the obsolete custodial-flow tests were *replaced* (not just fixed) by a new
proof suite, and the matching engine now reads on-chain shares — exactly the coupled
F-17772/17777/17778 change, shipped as one piece. Trade-off accepted deliberately.

---

# The remaining concerns (to detail in follow-up messages)

These still need decisions but are narrower than #1. Each gets its own short PM message when we're ready.

## #2 — Fee model is wrong, and fees have no cap
*Findings: F-17756 (High), F-17731, F-17746, F-17739*

**Plain English:** Two problems. (a) Fees are charged by *trade direction* (whoever is buying), not by
*role* — so a market maker resting a buy order ends up paying the fees that the aggressor should pay. You
told us the rule is "all fees paid by the taker," but the code doesn't do that. (b) The *size* of the fee
is whatever our backend says, with no limit the user agreed to — so a bug or a compromised backend could
charge a user their entire approved balance as "fee."

**Decision needed:** Confirm "taker pays all fees" is final, and approve adding a **signed fee cap** (the
user signs the maximum fee they'll accept). Both require the backend's signing/matching to change in
lock-step (one coordinated release). Also decide: enforce the configured fee % on-chain, or remove the
unused fee-% settings that currently mislead monitoring.

> **🟢 DECIDED & SHIPPED:** taker-pays confirmed final; `enterPosition` pulls fees from the taker via a
> two-sided signed match. Signed `Order.maxFee` cap added (new `ORDER_TYPEHASH`, lock-step backend +
> SDK change). Unused `platformFeeBps`/`makerFeeBps` + `setFees` **removed** from the contract (the
> p(1−p) fee curve isn't a fixed bps, so on-chain enforcement wasn't meaningful — the signed cap is the
> real protection). Redundant `FillInputs` fields dropped (F-17739).

## #3 — Anyone can freeze new market creation for free
*Findings: F-17726 (High), F-17780*

**Plain English:** The function that automatically creates new markets can be called by anyone. It has a
"skip ahead on failure" design, so an attacker who sends it junk (costing only gas, no capital) can push
the schedule pointer far forward and **stop new markets from being created** for a given pair/timeframe
for hours to days. We've already added an owner "reset" button to recover, but the real fix is to
restrict triggering to the official Chainlink automation.

**Decision needed:** Approve gating market creation to the Chainlink keeper (adds one post-deploy setup
step). **This one is contract-fixable and doesn't need an architecture change** — it's the most
self-contained of the remaining items.

> **🟢 DECIDED & SHIPPED:** `performUpkeep` gated on `forwarder || owner` (`setForwarder`; deploy seeds
> `forwarder = relayer`, rotate to the Automation forwarder once registered). The fail-forward now
> advances the pointer **only** on a permanent `PlannedStartTooStale` skip — not on transient report
> failures. Idempotent via `plannedStart` validation (F-17780). Owner recovery hatch retained.

## #4 — Resolution can be gamed in the final seconds
*Finding: F-17760*

**Plain English:** When a market resolves, the contract accepts any official price reading within a ±30
second window around the close time. In an UP/DOWN market, a 1-cent difference flips the *entire* payout,
so within that window someone can submit the most favorable still-valid reading. Tightening the window
fixes it — but too tight and legitimate resolutions could fail and markets stall.

**Decision needed:** How fast can our price service *reliably* deliver a reading after close? (That sets
how tight we can make the window.) And: do we accept the small remaining discretion, or move to a
stricter "only an authorized resolver can submit" design?

> **🟢 DECIDED & SHIPPED — both prongs.** `resolve`/`captureStrike` are now restricted to authorized
> callers (the cycler + the resolver service), removing the public front-run entirely; and the window
> is tightened to an owner-tunable `maxReportObservationLag` (default **3s**, hard-capped ≤30s). No
> backend timing change was required — `ChainlinkResolverService` fetches the report by
> `timestamp = endTime`, so it reliably lands inside the tight window.

## #5 — Treasury hands the backend unlimited spending power
*Finding: F-17779*

**Plain English:** The treasury wallet currently gives our backend *unlimited* permission to pull money
from it (used to pay market-maker rebates). If the backend key is stolen, the attacker drains the whole
treasury in one transaction. Important: this is **protocol/company money, not user funds** — user
collateral is held separately in the settlement contract.

**Decision needed:** Approve switching from unlimited approval to a **rolling weekly rebate budget** (caps
a compromise to one week's budget). Optionally add an owner-settable hard cap as a circuit-breaker. This
is mostly an operational change, not a contract rewrite.

> **🟢 DECIDED & SHIPPED:** the cap is now enforced **on-chain**. `claimRebate` is bounded by an
> owner-set rolling window budget (`setRebateBudget(perWindow, windowDuration)`); even with a standing
> treasury approval, a compromised relayer drains at most one window. Default budget `0` (fail-safe);
> the deploy seeds 5,000 USDT / 7-day.

---

# Appendix A — Full decision checklist (technical / for eng + auditor)

> **🟢 ALL ANSWERED (2026‑06‑15).** Every question below was decided in favor of the auditor's
> recommendation (Option A) and implemented. Q1 → trust‑minimized; Q2 → per‑user complete‑set model
> (not the `upReserved` earmark); Q3 → on‑chain taker signature; Q4 → taker‑pays (the `taker == 0`
> bootstrap leg of Q4a is unreachable in practice, so no fallback was needed); Q5 → single `maxFee`;
> Q6 → remove the unused bps; Q7 → dropped redundant fields; Q8/Q9/Q10 → forwarder gating +
> advance‑only‑on‑permanent‑skip + `plannedStart` idempotency; Q11 → 3s window (owner‑tunable) +
> authorized resolver (Q11a); Q12/Q12a → rolling per‑window rebate budget. See `REMEDIATION_V2.md`.

Exact questions, each mapping to a concrete code change. Recommended answers marked **▸**.

### Block 1 — Trust model → F-17772, 17777, 17778, 17757, 17771, 17776
- **Q1.** Custodial v1 (▸ recommended) vs. trust-minimized on-chain accounting?
  - If custodial: mark F-17772/17777/17778/17757 *Accepted (by design)*; confirm operational mitigations
    (relayer key mgmt, ledger backups, solvency monitoring).
- **Q2.** Backing reservation (F-17771/17776): accept under relayer trust, or add on-chain earmark
  (`upReserved`/`downReserved` or `marketAllocated`)? ⚠️ Earmark needs a relayer de-allocate / position-exit
  entrypoint or it creates a pre-resolution burn lock-in bug the green fuzz suite *hides*.
- **Q3.** Taker consent (F-17757): keep off-chain, or ▸ add an on-chain taker EIP-712 signature
  (new typehash + `FillInputs` field + taker replay nonce)?

### Block 2 — Fee model → F-17756, 17731, 17746, 17739
- **Q4.** Is "all fees paid by taker" final? ▸ Yes → split the pull (`cashPart` from buyer, fees from
  `taker == 0 ? buyer : taker`); needs taker USDT approval (lock-step backend change) + both-direction tests.
  - **Q4a.** For the bootstrap leg where `taker == address(0)`, who pays fees — buyer fallback, or zero-fee?
- **Q5.** Add a signed fee cap to the `Order` (F-17731)? ▸ Yes — single `maxFee` or split
  `maxPlatformFee`/`maxMakerFee`? Changes `ORDER_TYPEHASH` → lock-step signer change.
- **Q6.** Unused `platformFeeBps`/`makerFeeBps` (F-17746): enforce on-chain, or remove (constructor ABI change)?
- **Q7.** Drop redundant `marketId`/`option` from `FillInputs` (F-17739)? ▸ Fold into the fee-model ABI revision.

### Block 3 — Keeper hardening → F-17726, 17780
- **Q8.** ▸ Gate `performUpkeep` on the Chainlink Automation forwarder (`msg.sender == forwarder || owner`)?
  Adds a post-deploy `setForwarder` step.
- **Q9.** Transient-vs-permanent failure policy: stop advancing the pointer on transient (invalid/unavailable
  report) failures, only advance on genuine permanent skips? (Edits ~3 fail-forward tests.)
- **Q10.** ▸ Make `performUpkeep` idempotent — thread `slot.plannedStart`, validate it equals the expected next
  slot, no-op when already processed. Sub-decision: sentinel policy for adversarial `plannedStart == 0`.

### Block 4 — Oracle window → F-17760
- **Q11.** What `MAX_REPORT_OBSERVATION_LAG` can the off-chain resolver service reliably hit (currently ±30s)?
  - **Q11a.** Accept submitter discretion within that window, or move to a commit/authorized resolver?

### Block 5 — Treasury → F-17779
- **Q12.** ▸ Rolling weekly rebate allowance vs. standing unlimited approval?
  - **Q12a.** Add an owner-settable per-accrual / per-window cap as a circuit-breaker?

### Recommended sequencing
1. **Now (done):** the 9 applied fixes — independent, green, re-audit-ready.
2. **Keeper PR (Block 3):** most self-contained; no backend coupling. F-17726 + F-17780.
3. **Fee-model PR (Block 2):** one coordinated EIP-712/ABI/backend change. F-17756 + 17731 + 17746 + 17739.
4. **Cheap trust protections:** taker signature (F-17757) + treasury budget (F-17779) + optional reserved
   backing (F-17771/17776).
5. **Oracle window (Block 4):** tune the tolerance against the live fetcher.
6. **Trust-model decision (Block 1):** custodial-accept-and-document for v1; full non-custodial → v2 roadmap.

---

# Appendix B — Polymarket research (sources)

Researched and adversarially verified against primary sources (Jun 2026). Load-bearing facts:

- **Architecture (`hybrid-decentralized`):** off-chain operator matches; on-chain settlement is
  non-custodial. `github.com/Polymarket/ctf-exchange`, `docs.polymarket.com/developers/CLOB/introduction`.
- **Positions = ERC-1155 in user wallets:** Gnosis Conditional Tokens, Polygon `0x4d97dcd97ec945f40cf65f87097ace5ea0476045`.
  `docs.polymarket.com/concepts/positions-tokens`.
- **Both sides sign; operator can't fabricate trades:** `matchOrders(Order takerOrder, …)` +
  `Signatures.validateOrderSignature`. `ctf-exchange/src/exchange/mixins/Trading.sol`, `…/Signatures.sol`.
- **Trustless redemption:** `redeemPositions` has no access control; `UmaCtfAdapter.resolve()` is permissionless.
  `gnosis/conditional-tokens-contracts`, `Polymarket/uma-ctf-adapter`.
- **Signed + capped fees:** `feeRateBps` in `ORDER_TYPEHASH`; `MAX_FEE_RATE_BIPS = 1000` constant, no setter.
  `ctf-exchange/src/exchange/libraries/OrderStructs.sol`.
- **May 22, 2026 incident (validates the boundary):** ~$520K–$700K drained from an *internal top-up/rewards
  operational wallet* via private-key compromise; **contracts, user funds, and resolutions untouched**.
  Sources: ZachXBT; CoinDesk (`/markets/2026/05/22/zachxbt-flags-usd520k-polymarket-exploit-on-polygon`);
  Decrypt (`/368740/polymarket-hit-by-internal-top-up-wallet-exploit-700k-drained`); BeInCrypto.
- **Residual trust (not eliminated):** operator can censor/reorder/pause; UMA adapter admin can force-resolve
  an outcome after a safety period; Circle can blacklist USDC. Non-custodial on *principal*, trustless on
  *redemption*, still centralized on *matching liveness* and *outcome correctness*.

---

*Last updated: 2026-06-15. Companion to `FIX_PLAN.md` (engineering plan) and `REMEDIATION_V2.md`
(implementation design). **Status: all 5 concerns / 22 findings decided (Option A) and implemented** —
contracts 138 tests + 128k-call invariant, backend 514 tests, all green. The decision framing above is
retained as the record of how the call was reached.*
