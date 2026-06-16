# RAIN UpDown — Remediation V2 (full auditor recommendations)

**Decision (PM, 2026-06-15):** *"Go A — full auditor recommendations. We accept we aren't fully
trustless (off-chain order book), so make it as safe as possible."*

This is the design memo for the trust-minimized inversion. It implements the 13 `Needs-decision`
findings to the auditor's recommended fix (not the cheaper accept-and-document path). The 9 already-fixed
findings (Part A of `FIX_PLAN.md`) are retained. Companion to the contract diffs; every change carries an
inline `F-2026-…` reference.

---

## Trust model: custodial → non-custodial on principal (Polymarket parity)

The boundary moves from *"the company database is the source of truth"* to *"the smart contract is the
source of truth; the off-chain ledger derives from chain events."* The operator stays centralized for
**matching liveness** and **resolution correctness** (an off-chain order book cannot be otherwise) but
loses the power to **steal funds, force positions, inflate fees, or withhold winnings**.

### Share model (the keystone — F-17772 / 17777 / 17771 / 17776 / 17778)

`userShares[marketId][user][option]` (`option ∈ {1=UP, 2=DOWN}`) is now authoritative on-chain.
Shares are USDT-denominated 1:1 — minting `amount` USDT yields `amount` UP **and** `amount` DOWN shares;
the winning side redeems 1 USDT per share.

| Op | Shares | Backing (`marketRetained`) | Conservation |
|---|---|---|---|
| `complementaryMint(amount)` | `+amount` UP **and** `+amount` DOWN to minter | `+amount` | both option totals and retained rise together |
| `enterPosition(fillAmount)` | transfer: `-fillAmount` option from **seller**, `+fillAmount` to **buyer** | **unchanged** | totals unchanged; cash moves peer-to-peer, never pooled |
| `complementaryBurn(amount)` | `-amount` UP **and** `-amount` DOWN from holder (must own a complete set) | `-amount` | both totals and retained fall together |
| `redeem(marketId)` | `-shares` of the winning option | `-shares` | winning total and retained fall together to 0 |

**Invariant (replaces the old pooled-backing check):** for every unresolved market
`marketRetained == optionShares[UP] == optionShares[DOWN]`, and globally
`usdt.balanceOf(settlement) == Σ marketRetained` (held across the boundary of every external call).
`enterPosition` is balance-neutral for the contract (pure peer-to-peer), so it cannot perturb the
invariant — this is what makes F-17771 (backing reuse) structurally impossible: a fill consumes the
**seller's own** shares, never a shared pool.

- **F-17772 / 17777** — per-user shares recorded in `enterPosition` / `complementaryMint` /
  `complementaryBurn`; positions are now provable and reconstructable from chain events.
- **F-17776** — `complementaryBurn` is gated on the holder owning a **complete set** (`UP ≥ amount &&
  DOWN ≥ amount`), so a maker who already sold their UP can no longer withdraw the backing under a
  still-live buyer position.
- **F-17771** — backing reuse impossible: `enterPosition` debits the seller's actual shares.
- **F-17778** — trustless `redeem(marketId)` lets any winner claim directly from `marketRetained`;
  `redeemFor(marketId, holders[])` lets the relayer/keeper batch-redeem **to each holder's own wallet**
  (gas-paid-by-operator UX, but funds can only ever reach the rightful holder).
  `withdrawSettlement` (the whole-pool-to-relayer trust hole) is **removed**.

### User authorization (F-17772, second prong)

`complementaryMint` / `complementaryBurn` now require an EIP-712 `MintAuth` signed by the
minter/holder (relayer submits, user consents cryptographically; replay-protected by a per-account
nonce). Self-service `mint(marketId, amount)` / `burn(marketId, amount)` (msg.sender = account) are
also exposed so a user can always exit a complete set even if the relayer is gone.

### Taker consent + signed fee cap (F-17757 / F-17731 / F-17756 / F-17739)

`enterPosition` now takes **both** the resting maker order and the aggressing taker order, both
EIP-712-signed and verified on-chain. Reuses the orders both sides already sign into the book — no new
signing flow.

- **F-17757** — taker funds move only against the taker's own signature.
- **F-17731** — `Order` gains a signed `maxFee`; the taker's `platformFee + makerFee` is capped by
  `takerOrder.maxFee`. `ORDER_TYPEHASH` changes (lock-step signer change).
- **F-17756** — fees are pulled from the **taker** regardless of trade direction; `cashPart` moves
  buyer→seller. (Resolves F-17746: the unused `platformFeeBps`/`makerFeeBps` are removed.)
- **F-17739** — redundant `marketId`/`option`/`taker`/`sellerReceives`/`makerFeeRecipient` fields are
  dropped from `FillInputs`; everything is derived from the two signed orders.

## Keeper hardening (F-17726 High / F-17780)

- **F-17726** — `performUpkeep` gated on `msg.sender == forwarder || owner()` (`setForwarder` post-deploy
  step). The catch advances `pairTfLastCreated` **only** on a genuinely-permanent skip
  (`PlannedStartTooStale`); transient failures (bad/stale report, resolver hiccup) no longer advance the
  pointer, so a legit retry recreates the slot. (Recovery hatch `setPairTfLastCreated` from Part A kept.)
- **F-17780** — `slot.plannedStart` is threaded into `_createMarket` and validated against the expected
  next slot; a replayed/duplicate `performData` is a clean no-op (no double-create, no slot skip).

## Oracle window (F-17760)

`resolve` / `captureStrike` are restricted to authorized callers (the cycler + the resolver service),
removing the permissionless favorable-report front-run. The observation window is also tightened from a
hard-coded ±30s to an owner-settable `maxReportObservationLag` (default **3s**, hard-capped ≤ 30s),
which the backend reliably hits because it fetches the report *by timestamp = endTime*.

## Treasury (F-17779)

`claimRebate` is capped by a rolling window budget (`rebateBudgetPerWindow` / `rebateWindowDuration`,
owner-set). Even with a standing treasury approval, a compromised relayer can drain at most one window's
budget. Default budget `0` (fail-safe: rebates disabled until ops configure).

---

## Lock-step backend changes (`updown-backend`)

1. `EIP712_ORDER_TYPES` + `signOrder` + `SignatureService` + SDK: add `maxFee` to the signed `Order`.
2. `Order` model + `/orders` route: accept/store `maxFee`.
3. `SettlementService.enterPositionViaRelayer`: build the dual-order `FillInputs` (fetch both buy & sell
   orders + signatures; maker = `makerFeeRecipient`, taker = the other side).
4. `SettlementService` mint/burn: sign + submit `MintAuth`.
5. `ClaimService`: replace `withdrawSettlement` + off-chain distribution with `redeemFor(marketId,
   winningHolders[])`.
6. ABIs regenerated; `ChainlinkResolverService` relayer authorized as resolver caller; cron note: set
   `forwarder` = the upkeep wallet.

*Frontend (`updown-frontend`) order signing must add `maxFee` to its EIP-712 payload in the same release
— out of this repo's scope but flagged for the coordinated deploy.*
