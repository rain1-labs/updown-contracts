# Hacken delta-review request — Complementary MINT / MERGE matching

> Cover note for the next Hacken submission. The delta is committed on
> `audit/hacken-remediation-v2` as `1a6ed13`. **Before sending:** push the branch to
> `origin` so Hacken can fetch the commit (as with `5204fe8`).

---

## What's new — complementary MINT / MERGE matching

Two relayer-only, dual-signed entrypoints that let the two option books cross without either party
pre-holding shares (the Polymarket CTF-Exchange MINT/MERGE operations), so buy-side demand alone can
seed a cold-start book:

- **`mintMatch(FillInputs)`** (`src/UpDownSettlement.sol:559`) — crosses two **BUY** orders on
  opposite options priced so `p_up + p_down ≥ 10000`. A fresh complete set is minted: each buyer is
  credited their own option's shares and their combined cash (`== fillAmount`) is retained as backing.
- **`mergeMatch(FillInputs)`** (`:654`) — crosses two **SELL** orders on opposite options priced so
  `p_up + p_down ≤ 10000`. Both share-covered sellers burn a complete set; the released `fillAmount`
  USDT is split by the two signed prices. Zero-fee (both parties receive cash, so there is no taker
  inflow to source a fee from — `platformFee`/`makerFee` must be 0).

Supporting additions: `_requireComplementary` helper (`:532`); errors `NotBothBuys` / `NotBothSells`
/ `NotComplementary` / `PriceOutOfRange` (`:73–80`); events `MintMatched` / `MergeMatched`
(`:196`, `:210`). No other function was changed.

## What is unchanged (kept frozen to bound the delta)

- **No EIP-712 signed struct or typehash changed.** `Order`, `ORDER_TYPEHASH`, `FillInputs`,
  `MintAuth`, `MINT_AUTH_TYPEHASH` are byte-for-byte untouched (verified: the diff contains no `+/-`
  line touching any of them). A BUY/SELL order a user already signs today is directly valid for a
  mint/merge match — **no SDK change and no re-audit of the signing path.** The only semantic
  broadening is that an already-signed BUY (resp. SELL) can now also settle as a mint (resp. merge)
  against the opposite option; it is economically equivalent for the signer (fills at ≤ their signed
  price, receives their option's shares, fully backed).
- **Collateral / reservation model unchanged.** A mint-match is two BUYs (cash-locked); a merge-match
  is two share-covered SELLs. The share-holding requirement for SELL (`enterPosition`'s `:452`
  `InsufficientShares` check) is enforced identically in `mergeMatch`.
- `enterPosition`, `mint`/`_mint`, `burn`/`_burn`, `complementaryMint`/`complementaryBurn`, `resolve`,
  `redeem`/`redeemFor`, and the rebate path are all unchanged.

## Invariants preserved by construction

The three conservation invariants from your re-audit hold across the new functions:

1. `usdt.balanceOf(settlement) == Σ marketRetained` — a MINT raises both by exactly `fillAmount`; a
   MERGE lowers both by exactly `fillAmount`.
2. Unresolved market: `marketRetained == optionShares[UP] == optionShares[DOWN]` — MINT `+= fillAmount`
   on all three, MERGE `-= fillAmount` on all three, so they never diverge.
3. The trading window (`startTime ≤ block.timestamp < endTime`, with the F-2026-17953 lower bound and
   the F-2026-17952 existence check both replicated) makes a mint/merge after `resolve()` unreachable,
   so no post-resolution supply change is possible.

These are exercised by a stateful invariant suite: `test/UpDownPROInvariant.t.sol` fuzzes `mintMatch`
and `mergeMatch` alongside mint/burn/fill/resolve/redeem and asserts (1)–(3) at every call boundary —
**128,000 calls per invariant, 0 reverts.**

## Our own pre-submission review (findings + disposition)

We ran an internal adversarial review of the new surface. No Critical/High/Medium issues; three
Low/Info items, two already fixed in this delta:

| # | Sev | Item | Disposition |
|---|---|---|---|
| F1 | Low/Info | `mintMatch`/`mergeMatch` enforce only the **sum-crossing** (`p_up+p_down`), not each leg's own signed price as a hard cap. Because the maker leg is floored, the complement party absorbs the residual — bounded to **exactly ≤ 1 base unit per fill** (`ceil(x) − floor(x)`), flows into backing (never the platform), solvency-safe. | **Documented as intentional** (the rounding direction is *mandated* by solvency — flooring the taker leg instead would under-back the set). Regression test added (`test_mintMatch_subUnitRoundingBornByTaker`, non-round `9999/1` prices, `fill=1`). We would welcome your view on whether an explicit per-leg cap is warranted. |
| F2 | Info | `mintMatch` issued the two cash-leg `safeTransferFrom` calls unconditionally, unlike the `> 0` guards in `enterPosition`/`mergeMatch` — a latent liveness edge at a boundary price of 0 on a revert-on-zero token. | **Fixed** — guarded `if (makerCash > 0)` / `if (takerCash > 0)`. Test: `test_mintMatch_zeroPriceLegSkipsTransfer`. |
| F3 | Info | `MintMatched` omitted `platformFee`/`makerFee`, so mint-fill fee flow was not reconstructable from the settlement event alone. | **Fixed** — added both fields to `MintMatched`. Test: `test_mintMatch_eventCarriesFees`. |

## Centralization posture — unchanged

The trusted-role surface is **unchanged** from your original report's acknowledged findings
(instant role setters; owner emergency-withdraw reaching backing collateral; relayer as the sole
authorized executor). We are handling these operationally via **multisig + Timelock ownership at
mainnet deploy** and are not modifying the contract's authority model in this delta.

## Test evidence

- New suite `test/ComplementaryMatch.t.sol` — **22/22** (mint/merge crossing, price improvement,
  fee cap, partial fills, share-cover, self-match geometry, rounding bound, zero-price boundary,
  event fields, full mint→merge→redeem round-trips).
- Conservation invariants — **128k calls each, 0 reverts**, with mint/merge firing.
- Full non-fork Foundry suite — **165/165** (was 143 at `5204fe8`; +22 for this feature, no
  regression).

## Repo

- github.com/Quecko-Org/updown-contracts, branch `audit/hacken-remediation-v2`
- Delta commit: `1a6ed13` — all changes confined to `src/UpDownSettlement.sol`
  (+ `test/ComplementaryMatch.t.sol`, `test/UpDownPROInvariant.t.sol`).

Could you please review `mintMatch` / `mergeMatch` and the supporting additions at
`1a6ed13`? Happy to answer any questions — in particular on the F1 rounding decision.

Thanks,
