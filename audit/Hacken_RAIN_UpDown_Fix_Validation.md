# RAIN UpDown — Hacken Audit Fix Validation Walkthrough

**Purpose.** A plain-language, per-finding walkthrough of how every issue in
`Hacken_RAIN_UpDown_Audit_Report.md` was fixed, with exact code references and the regression test
that locks each fix — so the team can **validate every remediation before returning the report to
Hacken**. For each finding you get: *what was wrong* (plain words), *what we changed* (plain words),
*where in the code* (file:line), *the test that proves it*, and *what you must double-check*.

> **Independent verification status.** Every entry below was checked against the **actual current
> source** (not just the remediation tracker): each cited line was re-opened and confirmed, and each
> fix was adversarially re-reviewed for "does this genuinely close the finding, or is it cosmetic?"
> **Result: all 22 findings — implemented, code references resolve, fix genuine (high confidence).**
>
> **Test run (this validation).** `forge test` on the working tree: **135 passed, 0 failed** across 8
> suites (only `UpDownForkTest` excluded — it needs an Arbitrum RPC), including all **45** `test_F17*`
> regression tests and the **128,000-call** conservation/solvency invariant fuzz (`marketRetained ==
> optionShares[UP] == optionShares[DOWN]` and `balance == Σ marketRetained`) with **0 reverts**.

---

## How to validate this yourself

| What | Value |
|---|---|
| **Audited baseline (the vulnerable code Hacken reviewed)** | git commit `fccb622` |
| **Where the fixes live** | the **current working tree** (uncommitted edits to `src/`, `test/`, `script/`) |
| **In-scope contracts** | `src/UpDownSettlement.sol`, `src/UpDownAutoCycler.sol`, `src/ChainlinkResolver.sol` |
| **Regression tests** | `test/RemediationV2.t.sol`, `test/AuditFixes.t.sol`, `test/UpDownUnit.t.sol`, `test/UpDownPROInvariant.t.sol` |
| **Design memo (context, not authority)** | `docs/REMEDIATION_V2.md` |

To diff any fix against the audited code:

```bash
# see exactly what changed in a contract vs. what Hacken reviewed
git diff fccb622 -- src/UpDownSettlement.sol

# run all named regression tests
forge test

# run the tests for one finding (e.g. F-2026-17731)
forge test --match-test F17731 -vvv

# run the 128k-call conservation fuzz (share-model solvency)
forge test --match-contract UpDownPROInvariant -vvv
```

All line numbers in this document refer to the **current working-tree** files.

---

## Status summary

| Severity | Findings | All resolved? |
|---|---|---|
| High | F-2026-17726, F-2026-17756 | ✅ 2/2 |
| Medium | F-2026-17729, 17731, 17757, 17760, 17771, 17772, 17776, 17777, 17778, 17780 | ✅ 10/10 |
| Low | F-2026-17730, 17759, 17774, 17779, 17781, 17782 | ✅ 6/6 |
| Info | F-2026-17727, 17728, 17739, 17746 | ✅ 4/4 |
| **Total** | **22** | **✅ 22/22** |

---

## The big picture (read this first)

Most of the Medium findings are **not 13 independent patches** — they are **two coherent redesigns**.
Understanding these two changes makes the per-finding entries obvious.

### Redesign 1 — On-chain per-user share ledger *(closes F-17771, 17772, 17776, 17777, 17778; underpins 17774, 17781)*

The old model held one **shared pool** of collateral per market (`marketRetained`) and kept every user's
actual position **off-chain in the relayer's database**. That single design choice caused five findings:
backing could be reused (17771), there was no per-user accounting or consent (17772/17777), backing could
be pulled out from under a live position (17776), and winners could only be paid by the relayer (17778).

The fix makes the **contract the source of truth**:

- `userShares[marketId][user][option]` (option `1=UP`, `2=DOWN`) is now an **authoritative on-chain ledger**
  (`src/UpDownSettlement.sol:222-225`).
- Shares are USDT-denominated 1:1. Minting `amount` USDT yields `amount` UP **and** `amount` DOWN shares;
  the winning side redeems 1 USDT per share.
- A fill (`enterPosition`) **transfers the seller's own shares to the buyer** and moves cash peer-to-peer —
  it never touches the pool. So the same backing can never satisfy two fills.
- **Conservation invariant**, proven by a 128,000-call fuzz: for every unresolved market
  `marketRetained == optionShares[UP] == optionShares[DOWN]`, and globally
  `usdt.balanceOf(settlement) == Σ marketRetained` (`src/UpDownSettlement.sol:227-236`).

### Redesign 2 — Dual-signed fill with a signed fee cap *(closes F-17756, 17731, 17757, 17739, 17746, 17730)*

The old `enterPosition` took **one** signed maker order plus a pile of relayer-supplied calldata (the taker
address, the fees, the seller payout). That caused: fees charged by direction instead of role (17756),
unbounded relayer-set fees (17731), takers forced in without consent (17757), redundant fields (17739),
misleading unused fee variables (17746), and a trapped-fee edge case (17730).

The fix makes a fill an **atomic match of two EIP-712-signed orders** (`src/UpDownSettlement.sol:374-478`):

- Both the resting `makerOrder` **and** the aggressing `takerOrder` are signed and verified on-chain.
- Fees are pulled from the **taker** (the aggressor) regardless of trade direction.
- The `Order` now carries a signed `maxFee`; the taker's total fees are capped **cumulatively across all
  partial fills** of that order (a new `orderFeesPaid` ledger).
- All redundant fields are gone; everything is derived from the two signed orders.

> **⚠️ Both redesigns are ABI / signature changes.** The backend relayer/matcher, the frontend EIP-712
> payloads, and any SDK must be updated in lock-step or signatures will fail / calls will revert. The
> consolidated checklist is at the end of this document. (Per the team's notes, the FE/BE port already
> added `maxFee` and the dual-order shape — please confirm it matches the exact typehash strings cited
> below before mainnet.)

---

## Findings — detail

Ordered by severity. Each entry is independently validatable from the file:line anchors.

---

### F-2026-17726 — Permissionless Upkeep Fail-Forward Corrupts Slot Pointer & Halts Market Creation · **High** · ✅

**The issue (plain).** The keeper function that creates new markets every few minutes (`performUpkeep`)
could be called by *anyone*. An attacker could call it with a market-creation request carrying an empty/
garbage price report. The price-capture step would fail — and the old error handler reacted to **any**
failure by bumping an internal pointer (`pairTfLastCreated`) forward by one slot. By spamming cheap failing
requests, an attacker could push that pointer arbitrarily far into the future, which **permanently stops new
markets** for that pair/timeframe. The only "repair" setter could itself be re-corrupted because the
function stayed open to everyone.

**The fix (plain).** Three layers: (1) `performUpkeep` now **rejects any caller** that isn't the registered
Chainlink Automation forwarder or the owner. (2) The catch block advances the pointer **only** on one
genuinely-permanent error (`PlannedStartTooStale` — the slot's window has irrecoverably passed); every other
failure (bad/unavailable report, transient hiccup) now leaves the pointer untouched so the next cycle retries
the same slot. (3) An owner-only repair hatch is kept as defense-in-depth.

**Where in the code** (`src/UpDownAutoCycler.sol`):
- `:372` — caller gate: `if (msg.sender != forwarder && msg.sender != owner()) revert NotForwarder();`
- `:385-403` — catch block advances the pointer **only** when `_isSelector(reason, PlannedStartTooStale.selector)` is true.
- `:413-420` — `_isSelector` helper that classifies permanent vs transient reverts.
- `:586-590` — `setForwarder` owner setter (registers/rotates the forwarder post-deploy; `address(0)` deliberately disables all non-owner upkeep as a kill-switch).
- `:576-580` — `setPairTfLastCreated` retained recovery hatch.

**Regression tests:**
- `test/UpDownUnit.t.sol::test_F17726_performUpkeep_onlyForwarderOrOwner` — random caller reverts `NotForwarder`; after `setForwarder`, that address works.
- `test/UpDownUnit.t.sol::test_F17726_transientFailure_doesNotAdvance` — the **exact attack vector** (missing feed → `captureStrike` reverts) now leaves the pointer **unchanged**.
- `test/UpDownUnit.t.sol::test_F17726_permanentStaleSkip_advancesAndEmits` — a genuinely-permanent skip still advances + emits, so the cycler catches up.
- `test/AuditFixes.t.sol::test_F17726_setPairTfLastCreatedRecovers / RejectsBadTfIdx / OnlyOwner` — the recovery hatch.

**Validate / notes.** There are now exactly **three** writes to `pairTfLastCreated` (permanent-skip catch `:401`,
legitimate create `:499`, owner repair `:578`) — no remaining unconditional advance. ⚠️ **Ops dependency:** the
gate is only effective once a forwarder is set. The deploy script seeds `forwarder = relayer`
(`script/Deploy.s.sol:165`) so the stopgap cron keeps working; **ops MUST call `setForwarder` again** to rotate
to the real Chainlink Automation forwarder once the upkeep is registered.

---

### F-2026-17756 — Fees Always Charged to the Buyer, Violating Taker-Pays Model · **High** · ✅

**The issue (plain).** The fee was charged to whoever was *buying* in a trade, regardless of whether they were
the aggressor. The intended rule is fee-by-**role**: the **taker** (the market order that crosses a resting
order) always pays; the **maker** (the resting limit order) pays nothing and earns a rebate. The bug: when a
maker posted a **BUY** limit order and a taker **SOLD** to fill it, the passive maker was wrongly charged.

**The fix (plain).** `enterPosition` now matches **two signed orders** (resting `makerOrder` + aggressing
`takerOrder`). The taker is always `takerOrder.maker`, and **both fees are pulled from the taker** regardless
of direction. Cash for shares moves **buyer → seller** directly; the maker fee/rebate is paid to the resting
maker.

**Where in the code** (`src/UpDownSettlement.sol`):
- `:374-382` — new two-sided `FillInputs` (two orders, two signatures, `fillAmount`, two fees).
- `:440-443` — role resolution: `taker = to.maker`; buyer/seller by side, decoupled from who pays.
- `:456-467` — `cashPart` moves buyer→seller; `platformFee`/`makerFee` pulled from `taker` (`// F-2026-17756: fees are pulled from the TAKER`).

**Regression tests:**
- `test/RemediationV2.t.sol::test_F17756_takerPaysFees_makerIsSeller` — taker pays cash + all fees.
- `test/RemediationV2.t.sol::test_F17756_takerPaysFees_makerIsBuyer` — **the exact case V1 got wrong**: the taker (who is the seller here) pays the fees.

**Validate / notes.** ⚠️ Full ABI redesign — see *Redesign 2* and the lock-step checklist. Fee **amounts** are
still relayer-supplied (off-chain Polymarket `p(1−p)` formula); only the **cap** is on-chain (F-17731). The
contract does not recompute fees, so a relayer can still under-charge or set fee `= 0` — it simply cannot
exceed the taker's signed `maxFee`. Confirm the off-chain engine assigns the taker role to the aggressor
consistently with `takerOrder.maker`.

---

### F-2026-17729 — Permissionless Strike Capture Drains Resolver LINK · **Medium** · ✅

**The issue (plain).** The resolver pays Chainlink a LINK fee every time it verifies a fresh report.
`captureStrike` was callable by anyone and de-duplicated on the raw second-by-second `startTime`. Because a
report is valid anywhere in a ~61-second window, an attacker could call `captureStrike` 61 times for one slot
using 61 different one-second timestamps — each a "new" key forcing a new paid verification — draining the
resolver's LINK.

**The fix (plain).** Two changes: (1) `startTime` must now be **aligned to a real slot boundary** (a multiple
of 300s); any unaligned timestamp is rejected *before* any paid verify, collapsing 61 abusable keys to the one
legitimate boundary. (2) `captureStrike` is now `onlyAuthorized`, so only the cycler/owner can call it at all.

**Where in the code** (`src/ChainlinkResolver.sol`):
- `:200` — `STRIKE_ALIGNMENT = 300`.
- `:406-415` — `captureStrike` is `onlyAuthorized` **and** `if (uint256(startTime) % STRIKE_ALIGNMENT != 0) revert StrikeStartNotAligned(...)` before the cache check.
- `:322-325` — the `onlyAuthorized` modifier.

**Regression tests:**
- `test/AuditFixes.t.sol::test_F17729_unalignedStartReverts` — `%300==1` reverts `StrikeStartNotAligned` before any verify.
- `test/AuditFixes.t.sol::test_F17729_alignedStartPassesAlignmentGate` — aligned `startTime` passes the gate.
- `test/UpDownUnit.t.sol::test_F17760_captureStrike_revertsForUnauthorizedCaller` — non-authorized caller reverts.

**Validate / notes.** ⚠️ **Deploy dependency:** because `captureStrike` is now `onlyAuthorized`, the cycler must
be authorized or market creation breaks — wired at `script/Deploy.s.sol:159` (`setAuthorizedCaller(cycler, true)`).
All timeframe durations `{300, 900, 3600}` are multiples of 300 and the cycler computes a clock-aligned
`plannedStart`, so legitimate captures are unaffected.

---

### F-2026-17731 — Relayer Can Charge Arbitrary Fees (Missing On-Chain Fee Validation) · **Medium** · ✅

**The issue (plain).** Platform/maker fees were just numbers the relayer typed in, with no on-chain ceiling — a
compromised relayer could charge up to a user's full token approval as "fees." Critically, the cap must apply
to the **whole order**, not each partial fill, or a relayer could split one order into N fills and charge the
max fee N times.

**The fix (plain).** A signed `maxFee` was added to the `Order` and its EIP-712 type hash, so the taker commits
to a maximum total fee. `enterPosition` keeps a running total **per taker-order-hash** (`orderFeesPaid`) and
reverts if cumulative fees ever exceed `takerOrder.maxFee` — **cumulative across all partial fills**, so the
N×maxFee split attack is blocked.

**Where in the code** (`src/UpDownSettlement.sol`):
- `:98-116` — `maxFee` in `Order` + baked into `ORDER_TYPEHASH` (note: the EIP-712 field name is `type`, matching the backend payload).
- `:214-220` — `mapping(bytes32 => uint256) public orderFeesPaid` cumulative fee ledger.
- `:425-433` — `takerFeesPaid = orderFeesPaid[takerHash] + feeTotal; if (takerFeesPaid > to.maxFee) revert FeeExceedsTakerCap(...)`, then persists the running total.

**Regression tests:**
- `test/RemediationV2.t.sol::test_F17731_feeCap_enforced` — single fill over the cap reverts `FeeExceedsTakerCap`.
- `test/RemediationV2.t.sol::test_F17731_feeCap_cumulativeAcrossPartialFills` — fill #1 consumes the cap; a second fill charging 1 wei extra reverts; a later zero-fee fill still works. **Directly proves the split attack is blocked.**

**Validate / notes.** ⚠️ `ORDER_TYPEHASH` changed → backend/frontend/SDK must add `maxFee` to the signed payload
or **every signature fails**. The cap is on the **sum** `platformFee + makerFee`, so the relayer must budget the
signed `maxFee` across partial fills off-chain (mis-budgeting causes later fills to revert — a liveness, not
safety, concern). Confirm the FE/BE port uses this exact typehash string.

---

### F-2026-17757 — Taker Funds Pulled Without Taker Consent · **Medium** · ✅

**The issue (plain).** The counterparty (taker) was just an address the relayer put in the transaction — the
taker never signed anything. Anyone who had ever approved the contract could be **forced into a position
against their will**.

**The fix (plain).** `FillInputs` now carries the taker's **own EIP-712-signed order** + signature.
`enterPosition` verifies **both** the maker's and taker's signatures (EOA + ERC-1271 smart wallets, via
`SignatureChecker`) and reverts `InvalidSignature` **before any funds or shares move**. The taker whose funds
are pulled is `takerOrder.maker` — the address that actually signed.

**Where in the code** (`src/UpDownSettlement.sol`):
- `:410-418` — both signatures verified up front; bad signature reverts before any state change.
- `:441` — `address taker = to.maker;` (the signer), not a relayer-supplied address.

**Regression tests:**
- `test/RemediationV2.t.sol::test_F17757_invalidTakerSignature_reverts` — taker order signed by the wrong key reverts `InvalidSignature`.
- `test/RemediationV2.t.sol::test_orderBinding_invalidMakerSignature_reverts` — companion for the maker side.

**Validate / notes.** Not a defect, for awareness: a self-fill where `maker == taker` is allowed (the signer's
own choice, harmless). ERC-1271 support means smart-contract-wallet takers are allowed by design.

---

### F-2026-17760 — Observation Window Tolerance Allows Favorable Report Selection · **Medium** · ✅

**The issue (plain).** These are binary up/down bets where a one-cent move across the strike flips the entire
payout. Both `resolve` and `captureStrike` were callable by anyone, and the accepted report window was a fixed
±30 seconds. A positioned attacker could pick whichever still-valid report in that wide window gave the outcome
they wanted and front-run the legitimate resolver, **flipping who wins**.

**The fix (plain).** (1) `resolve` and `captureStrike` are now `onlyAuthorized` — no outsider can submit a
report. (2) The fixed 30s window is replaced by an **owner-tunable** value defaulting to a tight **3 seconds**
(both strike and settlement windows), **hard-capped at 30s** so the owner can tighten but never re-widen it. A
3s window over sub-second price streams means all acceptable reports carry essentially the same price.

**Where in the code** (`src/ChainlinkResolver.sol`):
- `:176` `maxReportObservationLag = 3 seconds`; `:190` `maxStrikeReportLag = 3 seconds`; `:194` `OBSERVATION_LAG_CAP = 30 seconds`.
- `:330-336` — `setObservationLag` enforces the cap before applying.
- `:505` — `resolve` is `onlyAuthorized`; `:541-545` enforces `obs ∈ [endTime − lag, endTime]`.
- `:439-443` — `captureStrike` strike-window enforcement against the tunable lag.

**Regression tests** (`test/UpDownUnit.t.sol`):
- `test_F17760_resolve_revertsForUnauthorizedCaller` — outsiders can't resolve.
- `test_F17760_observationLagDefaultsToThreeSeconds` — pins the 3s default (catches any silent re-widening to 30s).
- `test_F17760_setObservationLag_enforcesCap` — owner can't exceed the 30s cap.
- `test_F17760_resolve_rejectsObservationOneSecondPastWindow` / `_acceptsObservationAtWindowEdge` — proves the window is the tight 3s, and legitimate close-time reports still pass.

**Validate / notes.** ⚠️ **Ops dependency:** the resolver service and cycler must be authorized callers
(`script/Deploy.s.sol:159-160`), and the off-chain fetcher must request the report by `timestamp = endTime` so
the observation lands inside the 3s window. **The 3s default is aggressive** — confirm live Data Streams fetch
latency supports it before mainnet, or pre-tune via `setObservationLag` (still capped at 30s).

---

### F-2026-17771 — Backing Collateral Reused Across Fills · **Medium** · ✅

**The issue (plain).** On a fill, the contract only checked that the **shared pool** was big enough — it never
subtracted anything. So the same pile of money backed trade after trade; the protocol could sell far more
winning positions than it had money to pay. **A direct path to insolvency.**

**The fix (plain).** See *Redesign 1*. A fill no longer checks the pool — it **moves shares from the seller's
own balance to the buyer's**. If the seller doesn't actually hold the shares, the fill reverts. Because each
fill debits the seller's own shares, backing can never be reused.

**Where in the code** (`src/UpDownSettlement.sol`):
- `:446-454` — seller-must-hold-shares check + debit/credit (replaces the old pooled `marketRetained` check; the old `mintBackingDelta` / `NoBackingForSeller` are gone).
- `:227-236` — `optionShares` aggregate + `marketRetained` now only change on mint/burn/redeem.

**Regression tests:**
- `test/RemediationV2.t.sol::test_F17771_backingNotReusableAcrossFills` — reselling the same 100 UP reverts `InsufficientShares`.
- `test/RemediationV2.t.sol::test_F17771_sellerWithoutShares_cannotSell` — a naked sell reverts.
- `test/UpDownPROInvariant.t.sol::invariant_retainedBacksOutstandingShares` + `invariant_balanceEqualsSumOfRetained` — **128,000-call fuzz, 0 reverts**, proving `marketRetained == optionShares[UP] == optionShares[DOWN]` and global solvency.

**Validate / notes.** Part of *Redesign 1* — a seller MUST hold shares (mint a complete set) before any sell can
fill, so the backend/frontend must mint before selling.

---

### F-2026-17772 — Complementary Mint/Burn Lack Per-User Share Accounting and User Authorization · **Medium** · ✅

**The issue (plain).** The relayer could create/destroy positions for any user with **no record of who owned
what** and **no permission** from that user — it could take user A's money and hand the position to user B, or
destroy a position nobody asked to destroy. (The old code even carried a `TRUST-ASSUMPTION-V1` comment
admitting this.)

**The fix (plain).** Every mint/burn now writes a **per-user share record** on-chain. The relayer-submitted
paths require the user's own **EIP-712 `MintAuth`** (replay-protected by a per-account nonce) — the relayer
can't act without the user's single-use cryptographic consent. Plus, **self-service** `mint(marketId, amount)`
and `burn(marketId, amount)` were added so a user never needs the relayer at all.

**Where in the code** (`src/UpDownSettlement.sol`):
- `:495-503` — `complementaryMint` requires the minter's signed `MintAuth`.
- `:507-526` — self-service `mint` / `_mint` (records per-user UP+DOWN shares, no signature).
- `:570-588` — `_checkMintAuth` (fields match, not expired, nonce unused, signature recovers to the account; nonce burned after use).
- `:130-132` — `MINT_AUTH_TYPEHASH`.

**Regression tests** (`test/RemediationV2.t.sol`):
- `test_F17772_relayerMint_requiresSignedAuth` — valid `MintAuth` works; replaying the nonce reverts `MintAuthNonceUsed`.
- `test_F17772_relayerMint_rejectsWrongSigner` — `account=alice` signed by bob reverts `InvalidMintAuth` (relayer can't forge consent).
- `test_F17772_selfMint_recordsPerUserShares` — self-mint records shares.

**Validate / notes.** ⚠️ **Backend/frontend:** the relayer mint/burn entrypoints have new signatures requiring a
`MintAuth` struct + signature. The frontend must produce EIP-712 `MintAuth` signatures (domain `UpDown
Exchange` v1) and the backend must pass them, or these paths revert. The `MintAuth` nonce is a **separate
namespace** from order nonces — ensure no off-chain logic assumes they share a space.

---

### F-2026-17776 — Position Backing Withdrawn via complementaryBurn Before Resolution · **Medium** · ✅

**The issue (plain).** A maker could deposit money, sell one side of their position to a trader, then — before
resolution — **pull that same money back out via burn**, leaving the buyer holding a winning ticket with no
money behind it. The entry check was only a momentary snapshot of the total pool.

**The fix (plain).** Burning now requires the holder to own a **complete matched set** — at least the burned
amount of **both** UP and DOWN shares. Once a maker sells their UP side, they no longer hold a complete set, so
they can't burn and reclaim the buyer's backing. The buyer's backing stays locked until resolution.

**Where in the code** (`src/UpDownSettlement.sol`):
- `:552-564` — `_burn` requires `userShares[...][UP] >= amount && [...][DOWN] >= amount` before any collateral leaves.

**Regression tests:**
- `test/RemediationV2.t.sol::test_F17776_cannotBurnBackingUnderLivePosition` — alice mints, sells her UP to bob, then her burn reverts `InsufficientShares`; bob's backing (`marketRetained == 100e18`) is preserved. **This is exactly the V1 attack, now blocked.**
- `test/UpDownPROInvariant.t.sol::invariant_retainedBacksOutstandingShares` — fuzz proves backing can't drop below outstanding shares.

**Validate / notes.** The complete-set check lives in the shared `_burn`, so **both** the self-service `burn`
and the relayer `complementaryBurn` are covered.

---

### F-2026-17777 — Filled Positions Record No On-Chain Share Accounting · **Medium** · ✅

**The issue (plain).** When a trade filled, the contract stored **nothing** about who now owned which position
(only off-chain analytics counters). Positions existed only in the relayer's database — if those records were
lost or wrong, users had no on-chain proof or recourse.

**The fix (plain).** Fills now move ownership in the authoritative on-chain `userShares` ledger (debit seller,
credit buyer). A public getter `sharesOf(market, user, option)` lets anyone read a position, and a
`FillSettled` event records both parties + the cash/fee flow. Positions are now fully reconstructable from
chain; the off-chain ledger **derives from** chain instead of being the source of truth.

**Where in the code** (`src/UpDownSettlement.sol`):
- `:453-454` — fill debits seller / credits buyer in `userShares`.
- `:776` — `sharesOf(...)` public getter.
- `:162-172` — `FillSettled` event (both parties + cash/fee flow).

**Regression tests:**
- `test/RemediationV2.t.sol::test_F17756_takerPaysFees_makerIsSeller` — after a fill, `sharesOf(bob, UP)==100e18`, `sharesOf(alice, UP)==0`.
- `test/RemediationV2.t.sol::test_F17772_selfMint_recordsPerUserShares` — `sharesOf` returns recorded balances.

**Validate / notes.** Same `userShares` writes as F-17771 — one coherent change (*Redesign 1*), correctly
implemented, but not an independently separable patch.

---

### F-2026-17778 — No On-Chain Settlement Path; Winners Depend on Relayer · **Medium** · ✅

**The issue (plain).** The only way resolved funds left the contract was a function that sent the **entire
market pool to the relayer**, which then paid winners off-chain at its discretion. If the relayer vanished,
went insolvent, or refused, winners had **no way to get their money**.

**The fix (plain).** That whole-pool-to-relayer function (`withdrawSettlement`) was **removed**. Winners now
call `redeem(marketId)` themselves and pull exactly their own winning shares straight from the contract — no
relayer needed, even if it's gone. A batch helper `redeemFor(marketId, holders[])` lets anyone (e.g. a keeper)
pay gas to push winnings out, but funds **always go to each rightful holder's own wallet, never to the caller**.
State is zeroed before transfer (checks-effects-interactions), so redemptions can't be double-claimed or
reentered.

**Where in the code** (`src/UpDownSettlement.sol`):
- `:608-610` — trustless `redeem`.
- `:627-641` — `_redeemToAllowZero` pays the **holder** (not the caller); zeroes shares before transfer.
- `:615-620` — batch `redeemFor`.

**Regression tests** (`test/RemediationV2.t.sol`):
- `test_F17778_redeem_trustless` — winner self-redeems 1:1; second redeem reverts `NothingToRedeem`.
- `test_F17778_redeemFor_paysHolderNotCaller` — relayer calls it; **the holder** is paid, the caller gets nothing.
- `test_F17778_loserCannotRedeem` — loser gets `NothingToRedeem`; winner still redeems.

**Validate / notes.** ⚠️ **Backend:** any off-chain code that called `withdrawSettlement` must be deleted; payouts
now happen via `redeem`/`redeemFor`. The `settled` struct field is retained only for storage-layout stability
(never written now) — harmless, but the backend should stop relying on it.

---

### F-2026-17780 — performUpkeep Is Not Idempotent and Can Skip Market Slots · **Medium** · ✅

**The issue (plain).** When the keeper asked the contract to create a market, the contract recomputed which
slot to create purely from its internal pointer and **ignored the slot id (`plannedStart`) the keeper actually
sent**. So a replayed/duplicate keeper request (normal with retries) could advance the pointer again and **skip
a still-valid future slot** — a legitimate market silently never created.

**The fix (plain).** The keeper's `plannedStart` is now passed into the creation logic and compared against the
slot the contract expects to create next. On a mismatch (exactly what a stale/replayed request looks like) the
function **does nothing** (emits `SlotAlreadyProcessed`, returns) — no double-create, no pointer advance, no
skip. `checkUpkeep` computes `plannedStart` with the identical formula, so honest requests always match.

**Where in the code** (`src/UpDownAutoCycler.sol`):
- `:385` — `plannedStart` threaded from the keeper payload into `_createMarketExternal`.
- `:469-472` — idempotency guard: `if (uint256(plannedStartArg) != plannedStart) { emit SlotAlreadyProcessed(...); return; }`.
- `:455-463` — the expected-slot computation (matches `checkUpkeep` at `:335-338`).

**Regression tests:**
- `test/UpDownUnit.t.sol::test_F17780_stalePlannedStart_isNoOp` — a stale `plannedStart` emits `SlotAlreadyProcessed`, leaves the pointer unchanged — no create, no skip.

**Validate / notes.** ⚠️ The internal `_createMarket`/`_createMarketExternal` signatures now take `plannedStart`.
A keeper that **forwards `checkUpkeep`'s `performData`** is automatically correct (it already carries
`plannedStart`, `:339-344`). The only risk is a keeper that **rebuilds `performData` by hand** — confirm the
backend coordinator preserves `plannedStart` when it injects the signed report.

---

### F-2026-17730 — makerFee Silently Trapped When makerFeeRecipient Is Zero · **Low** · ✅

**The issue (plain).** The buyer was charged a maker fee, but the contract only forwarded it if the relayer
supplied a non-zero `makerFeeRecipient`. If left blank, the fee was still collected but never sent anywhere —
**stuck in the contract, lost to everyone**.

**The fix (plain).** `makerFeeRecipient` is no longer a relayer-supplied field. The maker fee now always flows
to `makerOrder.maker` — the verified signer of the resting order. A signature can never recover to the zero
address, so the fee can never be trapped. **The bug condition is no longer expressible.**

**Where in the code** (`src/UpDownSettlement.sol`):
- `:465-467` — maker fee always paid to `mo.maker`, no recipient-is-zero branch.
- `:413-415` — `mo.maker` is the recovered signer (guaranteed non-zero before any fee flows).

**Regression tests:**
- `test/RemediationV2.t.sol::test_F17756_takerPaysFees_makerIsSeller` — asserts the resting maker receives cash + `makerFee`.

**Validate / notes.** **No dedicated regression test** — the dedicated tests were removed by design because the
bug is now **structurally impossible** (`test/AuditFixes.t.sol` header note, lines 20-24). The maker-fee
destination is still exercised as a value assertion in the F-17756 test. Confirm you're comfortable that
"structurally impossible" is the justification here.

---

### F-2026-17759 — Missing Price Validation (Zero/Negative Oracle Values) · **Low** · ✅

**The issue (plain).** A malfunctioning/deprecated/circuit-broken feed can return zero or a negative price. The
old reader only checked staleness and returned whatever it got — feeding a 0/negative price into a market could
mis-settle the binary outcome on garbage data.

**The fix (plain).** A `if (price <= 0) revert InvalidPrice()` guard was added to the legacy Data Feeds reader
**and**, more importantly, the same `report.price <= 0` guard was added to the **two live Data Streams paths in
production today** — `captureStrike` (sets the strike) and `resolve` (decides up/down). A malformed DON price
now reverts instead of settling.

**Where in the code** (`src/ChainlinkResolver.sol`):
- `:636` — legacy `_getLatestPrice`: `if (price <= 0) revert InvalidPrice();` after the staleness check.
- `:552` — **live** `resolve`: `if (report.price <= 0) revert InvalidPrice();` before deciding UP/DOWN (settlement price read at `:554`).
- `:450` — **live** `captureStrike`: `if (report.price <= 0) revert InvalidPrice();` before storing the strike.
- `:158` — global `MAX_STALENESS = 1 hours` retained only on the legacy view.

**Regression tests:**
- `test/AuditFixes.t.sol::test_F17759_zeroPriceReverts` / `_negativePriceReverts` / `_positivePricePasses` — legacy path.
- `test/UpDownUnit.t.sol::test_F17759_resolve_revertsZeroStreamsPrice` / `_resolve_revertsNegativeStreamsPrice` / `_captureStrike_revertsNonPositiveStreamsPrice` — **the live production paths**.

**Validate / notes — ⚠️ CONFIRM WITH HACKEN (accepted-by-design):** Hacken's **secondary** recommendation
(replace global `MAX_STALENESS` with a **per-feed** staleness threshold) was **not implemented**. Rationale:
the live production path is **Data Streams**, whose freshness is enforced by the tightened observation window
(`maxReportObservationLag`/`maxStrikeReportLag`, F-17760), **not** by `MAX_STALENESS`. The legacy
`getPrice`/`_getLatestPrice` view has **no production caller** after the Streams migration, so its global
`MAX_STALENESS` is effectively dead code. **Action: get Hacken to agree the staleness sub-recommendation is
closed by design rather than implemented.**

---

### F-2026-17774 — complementaryBurn Lacks Market-Active Guard (Expiry-to-Resolution Drain) · **Low** · ✅

**The issue (plain).** Deposits could be created only while the market was open, but they could be **destroyed
(money pulled out) during the gap between expiry and resolution** — draining collateral out from under
positions about to win.

**The fix (plain).** The burn path now has the **same time guard as mint**: it reverts once the market reaches
its end time. Both creating and destroying backing are restricted to the open trading window.

**Where in the code** (`src/UpDownSettlement.sol`):
- `:549` — `if (block.timestamp >= uint256(m.endTime)) revert MarketNotOpen(); // F-2026-17774` in `_burn`.
- `:516` — the matching mint guard it mirrors.

**Regression tests:**
- `test/AuditFixes.t.sol::test_F17774_burnAfterExpiryReverts` — warping to `endTime` makes burn revert `MarketNotOpen`.
- `test/AuditFixes.t.sol::test_F17774_burnWhileOpenSucceeds` — positive control.

**Validate / notes.** Guard is in the shared `_burn`, so both burn entrypoints are protected.

---

### F-2026-17779 — Relayer Can Drain Treasury via Unbounded Rebate Accumulation · **Low** · ✅

**The issue (plain).** The relayer could credit any address an **unlimited** rebate, and that address could pull
the full amount from the treasury (which grants a standing unlimited approval). **Full treasury drain in one
transaction.**

**The fix (plain).** Rebate **claims** are now capped by an owner-set **rolling per-window budget**. Even with
the standing approval, total claims in any window can't exceed the budget, so a compromised relayer loses at
most one window's budget. The budget defaults to **0** (claims disabled until the owner configures it — a
fail-safe).

**Where in the code** (`src/UpDownSettlement.sol`):
- `:662-670` — `claimRebate` rolls the window forward and rejects claims exceeding the remaining budget.
- `:677-680` — claimed amount added to the window tally before transfer (cumulative cap).
- `:720` — `setRebateBudget(budgetPerWindow, windowDuration)` owner setter.
- `:199-206` — rolling-window state (default 0 disables claims).

**Regression tests** (`test/RemediationV2.t.sol`):
- `test_F17779_rebateBudgetCapsClaims` — a 10,000e18 claim against a 500e18 budget reverts `RebateBudgetExceeded` (V1 full drain blocked).
- `test_F17779_rebateWithinBudget_works_andWindowRolls` — within-budget works; over-budget reverts; after the window rolls, the budget resets.

**Validate / notes.** ⚠️ Default budget is **0** → **rebates are disabled out of the box**; ops MUST call
`setRebateBudget` before any rebate can be claimed (intended fail-safe). **Residual risk accepted by design:** a
compromised relayer can still drain up to **one full window's budget** before the owner intervenes —
`accumulateRebate` itself remains unbounded and `onlyRelayer`; only the claim (fund movement) is capped.
Confirm this residual is acceptable. (Note: Hacken's broader recommendation was to separate user collateral
from the treasury entirely — *Redesign 1* already removes user collateral from the relayer's reach via
`redeem`; the treasury now only holds protocol-owned rebate funds.)

---

### F-2026-17781 — Missing nonReentrant Modifier on Token-Transfer Functions · **Low** · ✅

**The issue (plain).** The settlement contract moves USDT in/out but had **no reentrancy lock**. Plain USDT has
no transfer callback so the real-world risk was low — but if a different collateral token (one that calls back)
is ever used, every money-moving function would be exposed.

**The fix (plain).** The contract now inherits OpenZeppelin `ReentrancyGuard`, and **every token-moving function
carries `nonReentrant`**. The one rebate function that only records numbers (`accumulateRebate`) is correctly
left unguarded.

**Where in the code** (`src/UpDownSettlement.sol`):
- `:10` import + `:23` inherits `ReentrancyGuard` (baseline had neither).
- `nonReentrant` on: `enterPosition` `:389`, `complementaryMint` `:495-499`, `mint` `:507`, `complementaryBurn` `:529-533`, `burn` `:540`, `redeem` `:608`, `redeemFor` `:615`, `claimRebate` `:656`, `executeEmergencyWithdraw` `:744`.

**Regression tests** (`test/AuditFixes.t.sol`):
- `test_F17781_reentrancyGuardBlocksReentrantRedeem` — a callback token re-entering `redeem` reverts `ReentrancyGuardReentrantCall`.
- `test_F17781_reentrancyGuardBlocksCrossFunctionReentry` — re-entering `mint` during a `redeem` payout also reverts (the lock is **global**, not per-function).
- `test_F17781_redeemSucceedsWithoutReentry` — positive control.

**Validate / notes.** Every `SafeERC20` transfer site was cross-checked to live inside a `nonReentrant`
function. `accumulateRebate` (`:647`) is intentionally unguarded (moves no tokens). **No ABI change** — internal
hardening only, no backend/frontend impact.

---

### F-2026-17782 — No Mechanism to Remove or Deactivate a Pair · **Low** · ✅

**The issue (plain).** The owner could **add** a trading pair but never **remove** one. If a pair's feed got
deprecated or broke, the cycler kept trying to create markets for it every cycle forever (wasting gas,
polluting logs), fixable only by deprecating and redeploying the whole cycler.

**The fix (plain).** An owner-only `removePair` was added as the inverse of `addPair`: it sets
`supportedPairs[pair] = false` (both `checkUpkeep` and the create logic gate on this, so iteration/creation stop
immediately), clears `isCyclingPair`, swap-and-pops from the cycling array, and emits `PairRemoved`. A later
`addPair` re-adds the pair cleanly.

**Where in the code** (`src/UpDownAutoCycler.sol`):
- `:543-557` — `removePair` (clears both flags + swap-and-pop).
- `:109` — `PairRemoved` event.
- `:526-532` — `addPair` re-add works because it pushes only when `isCyclingPair` is false.

**Regression tests** (`test/AuditFixes.t.sol`):
- `test_F17782_removePairDeactivatesAndReAdds` — clears flags, shrinks the list via swap-and-pop, emits `PairRemoved`, and re-add works.
- `test_F17782_removePairOnlyOwner` — access-controlled.

**Validate / notes.** Behavioral nuance (not a bug): `removePair` only stops **new** market creation — already-open
markets are untouched and still resolve normally. Swap-and-pop reorders the array, so any off-chain consumer
relying on `cyclingPairAt` index stability must re-read after a `removePair`.

---

### F-2026-17727 — Floating Pragma · **Info** · ✅

**The issue (plain).** Each contract declared `^0.8.29` ("this or any newer 0.8.x"), allowing the deployed
bytecode to differ from the audited bytecode if compiled with a different future compiler.

**The fix (plain).** All three in-scope contracts now pin **`pragma solidity 0.8.29;`** (the caret is removed).

**Where in the code:** `src/UpDownSettlement.sol:2`, `src/UpDownAutoCycler.sol:2`, `src/ChainlinkResolver.sol:2`.

**Validate / notes.** No regression test (a pinned pragma is a compile-time property, not runtime behavior).
Informational: **test files** still use `^0.8.29`, but Hacken's finding only covers the three production
contracts, which are all correctly pinned.

---

### F-2026-17728 — Missing Two-Step Ownership Pattern · **Info** · ✅

**The issue (plain).** Single-step ownership: `transferOwnership` moved control immediately. A mistyped or
incompatible address would lose control permanently. The two-step pattern requires the new owner to actively
**accept** before it takes effect.

**The fix (plain).** All three contracts now inherit `Ownable2Step`. `transferOwnership` only **nominates** a
pending owner; the nominee must call `acceptOwnership()` to take control.

**Where in the code:** imports + inheritance — `src/UpDownSettlement.sol:5, 23`; `src/UpDownAutoCycler.sol:5, 15`;
`src/ChainlinkResolver.sol:5, 36`. (Both `Ownable` and `Ownable2Step` are imported because the constructors
still call `Ownable(owner)`; `Ownable2Step` extends `Ownable` and reuses its constructor — correct.)

**Regression tests:**
- `test/AuditFixes.t.sol::test_F17728_twoStepOwnership` — on Settlement: `transferOwnership` leaves `owner()` unchanged + sets `pendingOwner()`; only `acceptOwnership()` completes the handoff.

**Validate / notes.** The test exercises the flow only on `UpDownSettlement`; AutoCycler and Resolver rely on the
same OZ base class (no per-contract test). ⚠️ **Ops:** any runbook/admin tooling that assumed instant
`transferOwnership` must now have the new owner call `acceptOwnership()`, or ownership appears "stuck" as
pending.

---

### F-2026-17739 — Redundant marketId and option Fields in FillInputs · **Info** · ✅

**The issue (plain).** The old fill struct duplicated values already inside the signed order (market id, option,
taker, etc.) and re-checked them — redundant, more surface for mistakes, bigger calldata.

**The fix (plain).** `FillInputs` was slimmed to just the two signed orders, their signatures, `fillAmount`, and
the two fee numbers. The redundant `marketId`, `option`, `taker`, `sellerReceives`, `makerFeeRecipient` are all
removed; everything is derived from the two orders, which are cross-checked to agree on market/option/side/price.

**Where in the code** (`src/UpDownSettlement.sol`):
- `:374-382` — slimmed `FillInputs`.
- `:393-396` — market/option derived and cross-checked between the two signed orders.

**Regression tests:**
- `test/RemediationV2.t.sol::test_orderBinding_marketMismatch_reverts` / `test_orderBinding_optionMismatch_reverts`.

**Validate / notes.** ⚠️ Same ABI change already flagged under F-17756 (*Redesign 2*) — the relayer call site no
longer passes the removed fields.

---

### F-2026-17746 — Unused Fee Basis Point Variables Misrepresent Enforced Fees · **Info** · ✅

**The issue (plain).** The contract stored `platformFeeBps`/`makerFeeBps` and a `setFees` admin function, making
it look as if fees were computed/enforced on-chain at those rates — but `enterPosition` never used them (fees
were entirely relayer-supplied). Misleading to anyone reading or monitoring the contract.

**The fix (plain).** `platformFeeBps`, `makerFeeBps`, and `setFees` were **removed**, and the constructor no
longer takes the two bps params. Fees are governed solely by the signed-and-capped per-order model (`maxFee`).
The only remaining bps value, `dmmRebateBps`, is documented as an off-chain reference, not an enforced fee.

**Where in the code** (`src/UpDownSettlement.sol`):
- `:279` — constructor is now `constructor(IERC20 _usdt, address initialOwner)` (the two bps params are gone).
- `:193-196` — comment confirms removal; only `dmmRebateBps` remains (off-chain reference only).

**Validate / notes.** ⚠️ **Constructor-signature ABI change** — every deploy script/tool must drop the two bps
args. Confirmed applied in the deploy script: `script/Deploy.s.sol:121` constructs `new
UpDownSettlement(IERC20(usdt), deployer)`. (Per the team's notes, `deploy.js` is stale — `Deploy.s.sol` is
authoritative.) No dedicated regression test (acceptable for Info), so there is no explicit lock guarding
against re-introduction.

---

## Consolidated: items to explicitly confirm with Hacken

These are the only places where the remediation **deviates from, or partially defers, an auditor
recommendation**. Everything else is a full implementation. Surface these to Hacken directly:

1. **F-2026-17759 — per-feed staleness (accepted by design).** The global `MAX_STALENESS` was **not** replaced
   with per-feed thresholds. The live production path is Data Streams (freshness enforced by the tightened
   observation window, F-17760), and the legacy Data Feeds view has no production caller. Get Hacken to agree
   this sub-recommendation is closed by design.
2. **F-2026-17779 — residual one-window drain (accepted by design).** The rolling budget bounds a compromised
   relayer to one window's rebate budget rather than eliminating relayer trust on rebates entirely. Confirm the
   bounded residual is acceptable.
3. **F-2026-17730 / 17739 / 17746 — verified structurally / by absence, not by a dedicated test.** These are
   resolved by removing the vulnerable code path; coverage is via the redesign's tests and grep-confirmed
   absence rather than a finding-specific regression test.

## Consolidated: lock-step off-chain dependencies (must ship together)

The contract fixes change the ABI / signatures. **These off-chain changes must land in the same release** or
the system breaks at runtime:

| # | Change | Affected off-chain code |
|---|---|---|
| 1 | `Order` gains signed `maxFee`; `ORDER_TYPEHASH` changed | Backend signer/verifier, **frontend EIP-712 payload**, SDK |
| 2 | `enterPosition` takes **two signed orders** (`FillInputs` redesigned) | Relayer/matcher must build + submit both maker & taker orders + signatures |
| 3 | Fees pulled from the **taker**; relayer must budget `maxFee` across partial fills | Off-chain fee/matching engine |
| 4 | `complementaryMint`/`Burn` require a signed **`MintAuth`** (new typehash, separate nonce namespace) | Frontend signs `MintAuth`; backend passes struct + sig |
| 5 | `withdrawSettlement` **removed** → payouts via `redeem`/`redeemFor` | Claim/settlement service rewritten |
| 6 | `captureStrike`/`resolve` now `onlyAuthorized` | Cycler + resolver service must be `setAuthorizedCaller(..., true)` (seeded at `script/Deploy.s.sol:159-160`) |
| 7 | `performUpkeep` gated on `forwarder`/owner | Seeded `forwarder = relayer`; **rotate to the real Automation forwarder via `setForwarder` post-registration** |
| 8 | `performUpkeep` idempotency uses `plannedStart` | Keeper must preserve `plannedStart` from `checkUpkeep` in `performData` |
| 9 | Rebate budget defaults to **0** (disabled) | Ops must call `setRebateBudget` before rebates work |
| 10 | Constructor drops the two `*FeeBps` params | Deploy scripts/tooling (✅ `Deploy.s.sol:121` already updated) |
| 11 | Ownership is now two-step | Admin runbooks must call `acceptOwnership()` after `transferOwnership` |

> Per the team's memory notes, the FE/BE port already added `maxFee` and the dual-order/`MintAuth` shapes and
> passed its test suites — this table is the checklist to **confirm** that work matches the exact contract
> shapes cited above before the coordinated mainnet deploy.

---

*Generated as an internal validation aid. The authoritative correctness check is `forge test` against the
working tree; the authoritative diff is `git diff fccb622 -- src/`.*
