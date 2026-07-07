# Hacken UpDown Audit — Remaining Work After Re-Audit

**Source:** `Hacken_RAIN_[SCA]_Rain_UpDown_Final.pdf` (Final Report, 03/07/2026)
**Audit commit:** `fccb622` · **Retest commit:** `e6621a4`
**Scope:** `UpDownSettlement.sol`, `UpDownAutoCycler.sol`, `ChainlinkResolver.sol`

## Status summary

| Metric | Count |
|--------|-------|
| Total findings | 26 |
| Fixed (Resolved) | 21 |
| Mitigated (partial) | 1 |
| **Pending Fix (open)** | **4** |
| Critical / High open | **0** |

Both High findings and 8 of 10 Medium findings are fully resolved. Nothing Critical
existed. Every item below is Medium-or-lower.

> Note: the four Pending-Fix items are exactly the four *new* findings the retest
> surfaced (the `F-2026-179xx` IDs). All 22 original-audit findings are resolved
> except F-2026-17731, which is mitigated.

---

## Implementation status (2026-07-06)

The **four Pending-Fix items are IMPLEMENTED** in `src/UpDownSettlement.sol` (uncommitted).
F-2026-17731 (already Hacken-accepted as *Mitigated*) is **deferred** — it needs cross-repo
DMM-bot `maxFee` alignment and is optional (see the caveat below).

| Finding | Change | Site |
|---------|--------|------|
| 17952 | Market existence/open-window check hoisted above signature verification and all order-fill SSTOREs | `enterPosition` |
| 17953 | Added `block.timestamp < startTime → MarketNotOpen` lower bound | `enterPosition`, `_mint`, `_burn` |
| 17954 | `optionShares[marketId][loser] = 0` at resolution | `resolve` |
| 17975 | Partial `claimRebate` up to remaining budget; `setRebateBudget` no longer resets the rolling window | `claimRebate`, `setRebateBudget` |

**Tests: 143/143 non-fork pass** (`forge test`). New/updated coverage:
`test_F17952_marketCheckPrecedesSignatureVerification`, `test_F17953_preStartInteractionsRevert`,
`test_F17954_resolveZerosLoserOptionShares`, `test_F17975_oversizedAccumulatorDrainsAcrossWindows`,
`test_F17975_reconfigureDoesNotReopenWindowCap`, rewritten `test_F17779_*` for partial-claim
semantics, and the `UpDownPROInvariant` fuzz invariant strengthened to assert the loser side is
zeroed for every resolved market. No off-chain (backend/frontend/SDK) changes were required.

**Adversarial review (6-lens, each finding refuted by 3 independent skeptics):** no contract
defects found. One test-quality gap was confirmed and fixed — the F-17952 test originally used
valid signatures, so it reverted `MarketNotOpen` on *both* the hoisted and un-hoisted orderings
(a tautology). It now signs with the wrong keys so pre-fix code reverts `InvalidSignature` and
only the hoisted code reverts `MarketNotOpen` — verified to fail on the pre-fix source and pass
on the fixed source, making it a genuine regression guard for the reorder.

---

## Blast radius & safety (contracts / backend / frontend / SDK)

All five fixes are **contract-internal**. **None of them change the signed EIP-712 `Order`
or `MintAuth` structs** — `maxFee` is already a signed field (`UpDownSettlement.sol:106`,
`ORDER_TYPEHASH` at `:114`), and `orderFills[takerHash]` already tracks cumulative filled
shares. Therefore **no signing-path change is required** in the backend
(`config.ts` / `SignatureService.ts`), the frontend (`src/lib/eip712.ts`), or the SDK
(`wt-ub-sdk/sdk/typescript/src/eip712.ts`). Verified against the live code.

| Fix | Contract | Backend | Frontend / SDK | Safe to apply |
|-----|----------|---------|----------------|---------------|
| **17952** reorder market check | trivial reorder, no state semantics change | none — retry logic keys on 3 ERC-20/backing selectors, not error order | none | ✅ yes |
| **17953** start-time lower bound | adds a revert guard (dormant while `preStartWindowSec == 0`) | none — matcher already refuses to fill/mint before `startTime` (`MarketSyncer.ts` status = `WAITING_TO_START`); never burns | none — FE never renders pre-start markets as tradeable ("Opening Soon" is unclickable) | ✅ yes |
| **17975** rebate accounting | more-permissive claim + no window reset; update unit tests that assert all-or-nothing | none — backend only calls `accumulateRebate` (writes) + reads `dmmRebateAccumulated`; never claims/sets budget | none — FE refetches after claim (no optimistic zeroing), SDK doesn't expose claim | ✅ yes |
| **17954** zero loser `optionShares` | one assignment in `resolve()`; verify no on-chain reader of `optionShares[loser]` post-resolve | none — backend never reads `optionShares` (not in `getMarket`) | none — FE/SDK never read `optionShares`; volume/prices come from other fields | ✅ yes |
| **17731** pro-rata fee cap | tightens an existing check | **alignment needed** — see caveat below | none for FE users (already sign peak `maxFee`); DMM bots need the same | ⚠️ optional; needs bot alignment |

**Bottom line:** four of the five fixes (17952, 17953, 17954, 17975) are safe, cheap, and
**invisible** to backend/frontend/SDK — they can be applied and re-tested with no off-chain
changes. Only **17731** has any integration cost, and note that Hacken already accepted it
as *Mitigated* — the pro-rata refinement below is **optional hardening**, not a required fix.

### F-17731 caveat — the maxFee-signing convention must match the tighter cap
Fills execute at the **resting maker's price** (price improvement for the taker), and the
fee weight `w(p) = p·(1−p)·4` peaks at price `= 0.5`. So if a taker signs `maxFee` at its
*own* limit price and the fill lands *nearer* 0.5, the actual per-share fee can exceed a
pro-rata cap computed from that signed `maxFee` → **a legitimate fill would revert**.

- The **frontend already signs the worst-case peak** (`TradeForm.tsx`:
  `maxFee = amount · (platformFeeBps + makerFeeBps) / 10000`, weight 1.0) → pro-rata can
  only ever charge *less*; **FE orders never revert**. No change.
- The **DMM reference bot signs `maxFee` at the order price** (`signOrder.ts` →
  `estimateTotalFee(amount, orderPrice)`, probability-weighted) → under pro-rata a
  near-0.5 fill can revert. **If 17731 is implemented, the bot must sign `maxFee` at the
  peak weight (price 0.5 / w = 1.0)**, and the backend's pre-broadcast mirror
  (`SettlementService.ts`) must switch from the absolute cap to the pro-rata formula so a
  would-be-reverting fill is caught before broadcast. Value-only change; no struct change.

---

## 1. F-2026-17731 — Relayer Can Charge Arbitrary Fees to Buyers (Medium — **Mitigated, partial**)

**File:** `UpDownSettlement.sol` → `enterPosition`

**What was done:** A signed `maxFee` field was added to the `Order` struct and fees are
now tracked cumulatively via `orderFeesPaid[takerHash]`, so the relayer can no longer
charge more than the taker's signed cap across the *whole* taker order.

**Residual gap (why it is only Mitigated):** The cap is enforced as a **fixed total
amount**, not as a fee *rate* or a pro-rata limit on the filled quantity. The relayer can
therefore charge the entire signed `maxFee` on a **minimal partial fill**.

> Example: taker signs an order for 100 shares with `maxFee = 10 USDT`. The relayer fills
> only 1 share and charges the full 10 USDT. This passes the current cumulative-cap check
> even though the fee is disproportionate to the executed amount.

**Recommended fix — make the cap pro-rata to the fill amount.** The check currently at
`UpDownSettlement.sol:426-427` runs *before* `_consumeOrder`, so `orderFills[takerHash]`
still holds the cumulative filled amount from prior fills:
```solidity
// current (absolute cumulative cap):
//   uint256 takerFeesPaid = orderFeesPaid[takerHash] + feeTotal;
//   if (takerFeesPaid > to.maxFee) revert FeeExceedsTakerCap(takerFeesPaid, to.maxFee);

// tightened (fill-proportional ceiling). maxFee is the cap for the FULL order (to.amount);
// the allowed fee for the cumulative filled quantity is maxFee * (filledInclThis / amount).
uint256 takerFeesPaid  = orderFeesPaid[takerHash] + feeTotal;
uint256 filledInclThis = orderFills[takerHash] + f.fillAmount; // orderFills not yet incremented here
uint256 proRataCap     = (to.maxFee * filledInclThis) / to.amount;
if (takerFeesPaid > proRataCap) revert FeeExceedsTakerCap(takerFeesPaid, proRataCap);
```
`proRataCap <= to.maxFee` whenever `filledInclThis <= to.amount` (guaranteed — `_consumeOrder`
reverts otherwise), so this is strictly stricter than the current absolute cap.

> ⚠️ **Do not ship this in isolation.** Because fills execute at the resting maker's price
> and the fee weight peaks at 0.5, this cap can revert *legitimate* fills unless every
> signer commits `maxFee` at the worst-case (peak) weight. The frontend already does; the
> DMM reference bot does not. See "F-17731 caveat" in the Blast-radius section above. Hacken
> already accepted this finding as **Mitigated**, so treat the pro-rata change as optional
> hardening and only ship it together with the bot/mirror alignment.

---

## 2. F-2026-17953 — Missing Market Start-Time Validation (Low — **Pending Fix**)

**File:** `UpDownSettlement.sol` → `enterPosition`, `_mint`, `_burn`

**Problem:** When the `UpDownAutoCycler` pre-start window is active, markets are created
with a future `startTime`. The affected functions check that the market *exists* and has
*not ended*, but none verify `block.timestamp >= m.startTime`. As a result, during the
pre-start window the relayer can fill, and users/relayer can mint or burn complete
UP/DOWN sets and withdraw collateral, **before the market officially opens**.

**Recommended fix — add the lower-bound check to all three functions:**
```solidity
if (m.startTime == 0 || block.timestamp < uint256(m.startTime) || block.timestamp >= uint256(m.endTime))
    revert MarketNotOpen();
```

---

## 3. F-2026-17975 — Rebate Budget Accounting Can Freeze Claims / Bypass Window Cap (Low — **Pending Fix**)

**File:** `UpDownSettlement.sol` → `claimRebate`, `setRebateBudget`

**Problem (two parts):**
1. **Frozen claims:** `claimRebate` is all-or-nothing — it reverts if the caller's entire
   `dmmRebateAccumulated` exceeds the remaining window budget. Any account whose
   accumulated balance grows larger than `rebateBudgetPerWindow` becomes **permanently
   unable to claim**, because `remaining` can never exceed the per-window cap.
2. **Cap bypass:** `setRebateBudget` resets `rebateWindowStart` and
   `rebateClaimedInWindow = 0` on **every** call, so already-claimed rebates in the active
   window are forgotten and the intended per-window outflow cap can be exceeded within the
   same period.

**Recommended fix:**
```solidity
// (1) Allow PARTIAL claims up to the remaining window budget.
function claimRebate() external {
    uint256 accrued   = dmmRebateAccumulated[msg.sender];
    uint256 remaining = _remainingWindowBudget(); // rebuild window if elapsed
    uint256 amt       = accrued > remaining ? remaining : accrued;
    require(amt > 0, "NothingClaimable");

    dmmRebateAccumulated[msg.sender] -= amt;   // reduce by claimed amount, not full balance
    rebateClaimedInWindow            += amt;
    // ... transferFrom(treasury, msg.sender, amt) ...
}

// (2) Do NOT reset window accounting on a budget-config change.
function setRebateBudget(uint256 budgetPerWindow, uint256 windowDuration) external onlyOwner {
    rebateBudgetPerWindow = budgetPerWindow;
    rebateWindowDuration  = windowDuration;
    // preserve rebateWindowStart and rebateClaimedInWindow for the active window
    emit RebateBudgetSet(budgetPerWindow, windowDuration);
}
```

---

## 4. F-2026-17952 — Suboptimal Validation Order Wastes Gas on Reverts (Info — **Pending Fix**)

**File:** `UpDownSettlement.sol` → `enterPosition`

**Problem:** The market existence/liveness check runs *after* two `_consumeOrder` SSTOREs,
the `orderFeesPaid` SSTORE, and two `SignatureChecker.isValidSignatureNow` ECRECOVER
calls. A fill against a non-existent or expired market reverts only after that gas is
already spent. Gas-only; no security impact.

**Recommended fix — hoist the cheap market check before signature verification and state writes:**
```solidity
function enterPosition(FillInputs calldata f) external nonReentrant whenNotPaused onlyRelayer {
    // basic order-field validation ...

    // market existence + liveness FIRST (inexpensive SLOAD)
    Market storage m = markets[f.order.market];
    if (m.startTime == 0) revert MarketNotOpen();
    if (block.timestamp >= uint256(m.endTime)) revert MarketNotOpen();

    // ... then signature verification, _consumeOrder writes, transfers ...
}
```
(Combine with the F-2026-17953 lower-bound check so the single early guard covers both
existence and the full open-window.)

---

## 5. F-2026-17954 — Stale `optionShares` for Losing Side After Full Redemption (Info — **Pending Fix**)

**File:** `UpDownSettlement.sol` → `resolve`

**Problem:** `optionShares[marketId][option]` is only decremented for the redeemable
(winner) side. After a market fully resolves and all winning shares are claimed,
`optionShares[marketId][winnerOption]` reaches zero but
`optionShares[marketId][loserOption]` retains its peak value forever. No effect on
settlement or fund accounting — but off-chain consumers reading `optionShares` as
outstanding supply would misread the loser side as still live. Analytics concern only.

**Recommended fix — zero the loser side when the winner is set in `resolve()`:**
```solidity
function resolve(/* ... */) external {
    // ... determine winner ...
    m.winner   = winner;
    m.resolved = true;

    uint8 loser = winner == 1 ? 0 : 1;
    optionShares[marketId][loser] = 0; // clear stale losing-side supply
    // ...
}
```

---

## Recommended handling order

1. **F-2026-17731** (Medium) — the only item with real, though bounded, economic risk.
   Decide whether to ship the pro-rata cap.
2. **F-2026-17953** (Low) — one-line invariant hardening; pairs naturally with #4.
3. **F-2026-17975** (Low) — rebate claim UX + window-cap correctness.
4. **F-2026-17952** (Info) — gas optimization; fold into the #2 change.
5. **F-2026-17954** (Info) — cosmetic/analytics; lowest priority.

All fixes are localized to `UpDownSettlement.sol` except none touch the other two contracts.
Re-run `forge test` (authoritative correctness check) after each change; add negative-case
coverage, which the final report noted is currently missing (branch coverage 49.29%).
