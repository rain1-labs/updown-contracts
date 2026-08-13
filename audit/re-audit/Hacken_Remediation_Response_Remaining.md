# RAIN UpDown — Remediation Response for Remaining Findings

**For:** Hacken (retest)
**From:** RAIN
**Re:** `Hacken_RAIN_[SCA]_Rain_UpDown_Final.pdf` (Final Report, 03/07/2026)
**Prior retest commit:** `e6621a4` · **This remediation commit:** `5204fe8`
**Scope:** `src/UpDownSettlement.sol` (single file; the other two in-scope contracts are unchanged)

---

## Summary

The four **Pending Fix** findings from the final report are now addressed. The one **Mitigated**
finding (F-2026-17731) is discussed at the end with the residual and the exact condition to fully
close it.

| Finding | Severity | Status → | Function(s) touched |
|---------|----------|----------|---------------------|
| F-2026-17953 | Low  | Pending Fix → **Fixed** | `enterPosition`, `_mint`, `_burn` |
| F-2026-17975 | Low  | Pending Fix → **Fixed** | `claimRebate`, `setRebateBudget` |
| F-2026-17952 | Info | Pending Fix → **Fixed** | `enterPosition` |
| F-2026-17954 | Info | Pending Fix → **Fixed** | `resolve` |
| F-2026-17731 | Medium | **Mitigated** (unchanged) — see §5 | `enterPosition` |

**All changes are confined to `UpDownSettlement.sol`. No EIP-712 signed struct changed** (`Order`
and `MintAuth` typehashes are untouched), so no off-chain (backend / frontend / SDK) change is
required to accept these fixes.

**Verification:** `forge test` → **143 / 143 non-fork tests pass** (5 new tests + 3
rewritten/strengthened, listed per finding below).

---

## 1. F-2026-17953 — Missing Market Start Time Validation (Low)

**Hacken recommendation:** *Add the missing lower-bound check to all three functions:*
`if (m.startTime == 0 || block.timestamp < uint256(m.startTime) || block.timestamp >= uint256(m.endTime)) revert MarketNotOpen();`

**Resolution:** A `block.timestamp < startTime` lower bound was added to `enterPosition`, `_mint`,
and `_burn`. Fills, complementary mints, and complementary burns now all revert `MarketNotOpen`
during the pre-start window (when `UpDownAutoCycler.preStartWindowSec > 0` creates a market ahead of
its `startTime`). The bound is inclusive at `startTime` (`<`, not `<=`), so it is a no-op for markets
created via `createMarket` (which set `startTime = block.timestamp`).

```solidity
// enterPosition (also applied verbatim in _mint and _burn):
Market storage m = markets[mo.market];
if (m.startTime == 0) revert MarketNotOpen();
if (block.timestamp < uint256(m.startTime)) revert MarketNotOpen(); // F-2026-17953  <-- added
if (block.timestamp >= uint256(m.endTime)) revert MarketNotOpen();
```

**Test evidence:**
- `test_F17953_preStartInteractionsRevert` (`test/UpDownUnit.t.sol`): drives the cycler to
  pre-position a future-start market, asserts a `mint` **before** `startTime` reverts `MarketNotOpen`,
  and that the same `mint` **succeeds at exactly `startTime`**. `enterPosition` / `_mint` / `_burn`
  share the identical guard line.

---

## 2. F-2026-17975 — Rebate Budget Accounting Can Freeze Claims / Bypass Cap (Low)

**Hacken recommendation:** *Allow partial rebate claims up to the available `remaining` budget,
reducing `dmmRebateAccumulated` by the claimed amount instead of requiring the full balance to fit.
Also avoid resetting `rebateClaimedInWindow` on every `setRebateBudget` call. If configuration changes
are required, preserve already-claimed amounts for the active window.*

**Resolution (two parts):**

**(a) `claimRebate` now claims partially** up to the remaining window budget instead of reverting
all-or-nothing. An accumulator larger than `rebateBudgetPerWindow` can no longer become permanently
unclaimable; the unclaimed remainder stays accrued for later windows. The fail-safe is preserved —
`remaining == 0` (budget disabled, or window exhausted) still reverts `RebateBudgetExceeded`.

```solidity
uint256 remaining = rebateBudgetPerWindow > rebateClaimedInWindow
    ? rebateBudgetPerWindow - rebateClaimedInWindow
    : 0;

uint256 amt = accrued < remaining ? accrued : remaining;   // <-- partial draw-down
if (amt == 0) revert RebateBudgetExceeded(accrued, remaining);
// ... treasury balance/allowance check unchanged ...
dmmRebateAccumulated[msg.sender] = accrued - amt;          // <-- was: = 0
rebateClaimedInWindow += amt;
usdt.safeTransferFrom(treasury, msg.sender, amt);
emit RebateClaimed(msg.sender, amt);
```

**(b) `setRebateBudget` no longer resets the rolling window** on every call. The old unconditional
`rebateClaimedInWindow = 0` forgot rebates already claimed in the active window, allowing the
per-window cap to be exceeded within the same period. It now only seeds `rebateWindowStart` on first
configuration; thereafter `claimRebate` rolls the window forward lazily.

```solidity
function setRebateBudget(uint256 budgetPerWindow, uint256 windowDuration) external onlyOwner {
    rebateBudgetPerWindow = budgetPerWindow;
    rebateWindowDuration = windowDuration;
    if (rebateWindowStart == 0) {          // <-- was: rebateWindowStart = block.timestamp;
        rebateWindowStart = block.timestamp; //         rebateClaimedInWindow = 0;  (both removed)
    }
    emit RebateBudgetSet(budgetPerWindow, windowDuration);
}
```

**Test evidence** (`test/RemediationV2.t.sol`):
- `test_F17975_oversizedAccumulatorDrainsAcrossWindows`: 1,200e18 accrued against a 500e18/window
  budget drains 500 + 500 + 200 across three windows (pre-fix: permanently unclaimable).
- `test_F17975_reconfigureDoesNotReopenWindowCap`: after the window is fully consumed, calling
  `setRebateBudget` mid-window preserves `rebateClaimedInWindow`, and a further claim still reverts
  `RebateBudgetExceeded(_, 0)` (pre-fix: the reconfigure reopened the cap).
- `test_F17779_rebateBudgetCapsClaims` and `test_F17779_rebateWithinBudget_works_andWindowRolls`
  were updated to the partial-claim semantics (the per-window cap still bounds a compromised relayer
  to one window's budget — the F-17779 property is retained).

---

## 3. F-2026-17952 — Suboptimal Validation Order in enterPosition (Info)

**Hacken recommendation:** *Move the market existence and liveness checks earlier in `enterPosition`,
before signature verification and order-fill state writes.*

**Resolution:** The market existence / open-window check was hoisted to run immediately after the
basic order-field validation and **before** signature verification, the fee-cap check, and the two
`_consumeOrder` / `orderFeesPaid` SSTOREs. A fill against a nonexistent / not-yet-open / ended market
now reverts before any `ECRECOVER` or storage write. (This change is combined with the F-17953 lower
bound in the same relocated block.)

```solidity
if (block.timestamp > mo.expiry || block.timestamp > to.expiry) revert OrderExpired();
if (f.fillAmount == 0) revert FillExceedsOrderAmount();

// hoisted here, above signature verification and all order-fill state writes:
Market storage m = markets[mo.market];
if (m.startTime == 0) revert MarketNotOpen();
if (block.timestamp < uint256(m.startTime)) revert MarketNotOpen();
if (block.timestamp >= uint256(m.endTime)) revert MarketNotOpen();
// ... crossing check, signature verification, fee cap, _consumeOrder now follow ...
```

The previous late check (formerly after `_consumeOrder`) was removed. No state is written before the
relocated check, so the reorder is behavior-preserving apart from the intended earlier revert.

**Test evidence** (`test/RemediationV2.t.sol`):
- `test_F17952_marketCheckPrecedesSignatureVerification`: submits a fill with **invalid signatures**
  against a nonexistent market and asserts `MarketNotOpen`. This is a true regression guard, not a
  tautology: on the pre-fix ordering signature verification ran first, so the call would revert
  `InvalidSignature`. Confirmed by running the test against the pre-fix source — it fails with
  `InvalidSignature() != MarketNotOpen()` — and passes on the fixed source.

---

## 4. F-2026-17954 — Stale optionShares for the Losing Side After Full Redemption (Info)

**Hacken recommendation:** *Set `optionShares[marketId][loserOption] = 0` inside `resolve()` when the
winner is determined.*

**Resolution:** `resolve()` now zeros the losing option's aggregate share count once the winner is
set. The winning side is unchanged (it is still decremented per redemption in `_redeemToAllowZero`),
so the resolved-market invariant `marketRetained == optionShares[winner]` is preserved; only the
worthless, unredeemable loser aggregate is cleared.

```solidity
m.settlementPrice = int128(settlementPrice);
m.winner = winner;
m.resolved = true;

uint8 loser = winner == OPTION_UP ? OPTION_DOWN : OPTION_UP;  // winner already validated UP/DOWN
optionShares[marketId][loser] = 0;                           // <-- added

emit MarketResolved(marketId, winner, int256(settlementPrice));
```

**Test evidence:**
- `test_F17954_resolveZerosLoserOptionShares` (`test/RemediationV2.t.sol`): after resolve,
  `optionShares[loser] == 0` and `optionShares[winner]` is intact.
- `test/UpDownPROInvariant.t.sol`: the `invariant_retainedBacksOutstandingShares` fuzz invariant was
  strengthened to assert `optionShares[loser] == 0` for every resolved market (holds over the full
  fuzz campaign, 0 reverts).

---

## 5. F-2026-17731 — Relayer Can Charge Arbitrary Fees to Buyers (Medium — remains *Mitigated*)

We have **not** changed this finding for the current retest and believe the **Mitigated** status is
appropriate; we document the residual and the exact closing condition for completeness.

**Current mitigation (commit `e6621a4`, unchanged):** the taker's signed `maxFee` caps the cumulative
fee across all partial fills of a taker order via `orderFeesPaid[takerHash]`, so the relayer cannot
charge more in aggregate than the taker signed.

**Residual (as Hacken noted):** the cap is a fixed **total**, not pro-rata to the filled quantity, so
the full `maxFee` can be charged on a minimal partial fill.

**Why not fixed in this pass:** a pro-rata sub-cap
(`allowed = maxFee * cumulativeFilled / order.amount`) is a one-line contract change, but it is only
safe if **every** signer commits `maxFee` at the worst-case (peak) fee weight. Because a fill executes
at the resting maker's price and the fee weight peaks at price 0.5, a fill landing nearer 0.5 than the
signer's own limit price would otherwise revert. Our frontend already signs the peak `maxFee`; our
market-maker bot does not yet. We would ship the contract sub-cap together with aligning the bot's
`maxFee` and the backend's pre-broadcast fee mirror, as a single coordinated release, if you would
like this closed rather than left Mitigated. Please advise whether that is required for the retest.

---

## Verification

```
# in updown-contracts/
forge build                                   # clean
forge test --no-match-path test/UpDownForkTest.t.sol   # 143 passed / 0 failed
```

Relevant tests by finding:
| Finding | Tests |
|---------|-------|
| F-17953 | `test_F17953_preStartInteractionsRevert` |
| F-17975 | `test_F17975_oversizedAccumulatorDrainsAcrossWindows`, `test_F17975_reconfigureDoesNotReopenWindowCap`, `test_F17779_rebateBudgetCapsClaims`*, `test_F17779_rebateWithinBudget_works_andWindowRolls`* |
| F-17952 | `test_F17952_marketCheckPrecedesSignatureVerification` |
| F-17954 | `test_F17954_resolveZerosLoserOptionShares`, `UpDownPROInvariant` (strengthened) |

*\* rewritten from the earlier all-or-nothing assertions to the partial-claim semantics.*
