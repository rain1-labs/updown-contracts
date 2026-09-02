# Operations

Describes the contracts in this repo as deployed. Rewritten from code + live on-chain state
on 2026-08-10; the previous version described a Chainlink Automation setup that neither
environment uses.

## Keeper

`UpDownAutoCycler` exposes `checkUpkeep` / `performUpkeep`, but **it is not registered with
Chainlink Automation on either environment.** Both are driven by a cron keeper calling
`performUpkeep` from an EOA.

- `performUpkeep` is gated to `forwarder` (F-2026-17726). Only that address can drive it.
- Set at deploy from `KEEPER_FORWARDER_ADDRESS`; changed later with `setForwarder`.
- **Dev** shares one wallet for relayer and keeper. **Prod** uses a separate keeper EOA —
  keep it that way; collapsing them widens the blast radius of the hot relayer key.
- If you later register a Chainlink Automation upkeep, call `setForwarder(<forwarder>)` with
  the Automation forwarder address afterwards, or the upkeep's calls will be rejected.

### Monitoring

- Gas per `performUpkeep` on Arbiscan (scales with resolutions + creations in the batch).
- Alert on: keeper wallet ETH balance, upkeep transactions reverting, markets passing
  `endTime` without a `MarketResolved`, and `activeMarketCount` growing without bound.
- The keeper is a single EOA — if it stops, **markets stop resolving and users cannot
  redeem**, because `redeem` reverts `NotResolved` until `resolve` lands. Treat keeper
  liveness as a funds-availability concern, not just a freshness one.

## LINK

`ChainlinkResolver` pays Data Streams verification fees **from its own balance** (Option A
funding). Top up by direct transfer:

```bash
cast send $LINK_TOKEN "transfer(address,uint256)" $RESOLVER <amount> --rpc-url $ARBITRUM_RPC_URL
```

Owner clawback is `withdrawLink(amount)`. `Deploy.s.sol` cites a 5 LINK floor.

> **Open question:** both live resolvers currently hold **0 LINK**, including prod on the real
> DON. Either the FeeManager returns a zero fee for this account or Streams verification is not
> on the live resolution path. Resolve this before relying on the funding guidance above.

## Pause and emergency

- `setPaused(true)` on `UpDownSettlement` blocks fills, `mint`, `burn`, `resolve`, `redeem`,
  and `accumulateRebate`. Note it blocks **user exits** too — pausing is not a neutral action.
- `proposeEmergencyWithdraw(token, to, amount)` → wait `EMERGENCY_TIMELOCK` (24h) →
  `executeEmergencyWithdraw(proposalId)`. Cancel with `cancelEmergencyWithdraw`.

## Fee buyback-and-burn

`platformFee` no longer lands in the treasury on each fill. It accrues to the round that earned
it (`marketFeeAccrued[marketId]`, summed in `feesAccrued`). A **keeper** then calls
`buybackAndBurn(marketIds)`, which spends those buckets on RAIN via Uniswap V3 and burns
everything it receives. A round's bucket is final once `block.timestamp >= endTime`, because
fills revert there.

- **The burn is NOT on the resolve path, and that is deliberate.** See the incident note below.
- **Cadence is the keeper's call.** Nothing on-chain schedules the burn: if the keeper never runs
  it, fees simply accumulate (safely, and stay retirable). Prefer batching — hourly, say — over
  one call per round. Several rounds through one swap is cheaper in gas and better priced than a
  dust swap each. `pendingBuyback(marketIds)` sizes a batch before sending, so the keeper can
  skip a call that would revert `NothingToBuyback`.
- **Eligibility is `endTime`, not resolution.** A round that ended but never resolved can still be
  retired, so fee revenue is never hostage to a resolution failure.
- **Access is gated** to an allow-list (`buybackExecutors`, managed with
  `setBuybackExecutor(addr, bool)`) or the owner. A list rather than one slot so a backup keeper
  can be authorised before the primary is retired — rotation with no gap where nobody can burn.
  This is a
  security property, not bookkeeping: the caller picks *when* the swap runs, and the slippage
  floor is quoted in the same transaction. A permissionless caller could move the pool, trigger
  the burn — the quoter would then report the manipulated price, so the floor would track the
  manipulation and protect nothing — and reverse, atomically. The owner path is the manual
  fallback if a keeper dies.
- **Configure once:** `setBuybackRoute(rainToken, router, quoter, path)`. The path must start at
  USDT and end at the burn token or the call reverts `InvalidBuybackPath` — a misconfiguration
  fails here rather than as a silent stream of fallback events. `Deploy.s.sol` composes the
  USDT → WETH → RAIN path from env and calls this when `RAIN_TOKEN_ADDRESS` is set.
- **Slippage:** derived on-chain per burn as `quote × (10000 − buybackSlippageBps) / 10000`
  (default 300 = 3%). Tune with `setBuybackSlippageBps`.
- **A failing burn degrades, never reverts the batch.** An unset route, a reverting quoter or
  router, a dry pool (zero quote), a token that refuses to burn, or a treasury that cannot
  receive all forward or defer instead, so one dead round cannot block the rest.

### Why the burn is not inside `resolve` (dev incident, 2026-09-02)

It was, briefly, and it took dev down. Numbers from the live chain:

| resolve | gas |
|---|---|
| round with no fee (burn short-circuits) | ~122,650 |
| round with a fee (quoter + swap + burn) | ~489,750 |

The relayer sized its gas limit from an estimate plus ~3% (126,290 on a 122,650 call). That was
fine while `resolve` was deterministic. With a Uniswap swap inside, the cost moves with pool
state, and one tx came up **37 gas short**: limit 489,625, needed 489,662. Every fee-bearing
round then failed to resolve, and `redeem` reverts `NotResolved` until it does.

Wrapping the swap in try/catch did not help, and the reason is worth remembering: **try/catch
catches a revert, not gas exhaustion.** When the `resolve` frame itself ran out, every state
write in it was rolled back and no `catch` inside it ever ran. `ChainlinkResolver` caught the
failure one level up and emitted `ResolveFailed` with an empty reason — so the outer tx reported
success while the round stayed unresolved.

Moving the swap off the path is what makes "the burn can never block a resolution" true rather
than merely intended. `test_resolveIsUnaffectedByATotallyBrokenRoute` pins it.

### Monitoring

| Event | Meaning | Action |
|---|---|---|
| `FeesBoughtBackAndBurned` | Normal path — the round's fee became burned RAIN. Carries the burned amount only; the USDT spent is the sum of that round's `PlatformFeeAccrued`. | none |
| `BuybackFallbackToTreasury` | Burn failed; value forwarded to the treasury. `token` says which stage failed: USDT = quote/swap, RAIN = the burn itself. `reason` carries the raw revert. | triage the route; the forwarded value is in the treasury, not recoverable by `buybackAndBurn` |
| `BuybackDeferred` | Burn failed AND the forward failed (or no treasury set). The fee is re-credited to its own round and is still in the contract. | fix the route, then `buybackAndBurn([marketId])` |

Nothing to monitor on `resolve` any more — it no longer touches the buyback.

A steady stream of either fallback event means the route is wrong or the pool is too thin for
the fee sizes being burned — not that funds are lost.

### Route health (measured on Arbitrum One, 2026-09-01)

Verified against the live chain by `test/FeeBuybackBurn.t.sol`. That suite uses **no mocks** — real
USDT, real RAIN, the real `SwapRouter` and `Quoter` — mirroring how `rain-contracts` tests its own
`swapAndBurn`. Failure branches (dry pool, reverting router, unburnable token, unreceivable
treasury) are injected with `vm.mockCallRevert` against those same real addresses, so each one
exercises the real settlement path with exactly one external answer replaced.

- RAIN `0x25118290e6A5f4139381D072181157035864099d` **does** implement `burn(uint256)` — a
  `buybackAndBurn` burned ~298 RAIN for a 5 USDT round fee and the token's `totalSupply` fell by
  exactly that amount. Dev RAIN `0x43976a124e6834b541840Ce741243dAD3dd538DA` behaves identically
  (`npm run test:buyback:dev`).
- The `USDT --500--> WETH --100--> RAIN` path (the tiers `Deploy.s.sol` encodes) quotes and fills.
- **Depth is comfortable.** Price impact from a 5 USDT burn to a 1,440 USDT burn (one pair's
  whole day of 5-minute rounds) is **8 bps** — far inside the 300 bps default tolerance. Batching
  burns via `buybackAndBurn` is therefore safe if per-resolve gas ever becomes the binding cost.

```bash
npm run test:buyback          # buyback suite only
npm run test:fork             # whole suite, forked (invariants excluded)
```

Both default to the public `https://arb1.arbitrum.io/rpc` and use `ARBITRUM_RPC_URL` when set. CI
runs the forked suite on every branch (`buyback-fork-test`), falling through a list of RPCs. Run
unforked, the buyback tests **skip** rather than pass silently — `forge test` alone does not cover
this feature.

Re-run this after any route change (a new fee tier, a migrated pool) — a route that quotes zero
sends every round to the treasury fallback silently.

### Gas

`resolve` is back to ~122k and deterministic — it makes no external calls. Size the burn job's own
gas from the batch: one swap is ~370k on top of the per-round bookkeeping, so a batch of N rounds
is roughly `370k + N × 30k`. Give it real headroom rather than estimate-plus-a-few-percent: the
swap's cost moves with pool state, which is exactly what caught the relayer out above.

## Rebates

- `accumulateRebate(maker, amount)` — relayer-only, credits a counter, moves no funds.
- `claimRebate()` — permissionless, pays the caller their accrued rebate.
- Bounded by `rebateBudgetPerWindow` / `rebateWindowDuration` (seeded to 5,000 USDT / 7 days
  by `Deploy.s.sol`). A **$0 budget disables rebates entirely** — deliberate fail-safe.
- `dmmRebateBps` is 0 on both live deployments.

## Ownership

All three contracts are `Ownable2Step`. Transfers require `transferOwnership` from the current
owner, then `acceptOwnership` from the target — a wrong address cannot lock you out.
Use a Safe multisig on prod: the owner can rewire the resolver and reach collateral.

## Pruning

`performUpkeep` calls `_pruneResolved()` to drop finalized markets from the in-contract active
array. The owner may also call `pruneResolved()` manually, or `evictUnresolved(marketIds)`.

## Timeframes

`UpDownAutoCycler` cycles three fixed timeframes, seeded in the constructor and toggled by the
owner with `toggleTimeframe(uint256 index, bool active)`:

| Index | Duration | Dispute | Market | State |
|---|---|---|---|---|
| 0 | 300s | 600s | 5-minute | active |
| 1 | 900s | 1800s | 15-minute | active |
| 2 | 3600s | 7200s | 60-minute | **disabled 2026-08-18 on dev + prod** |

```bash
cast send $CYCLER "toggleTimeframe(uint256,bool)" 2 false \
  --rpc-url $ARBITRUM_RPC_URL --account <OWNER>
```

The flag lives on the **timeframe, not the pair** — one call covers every cycling pair at
once.

**It is a policy flag, not an on-chain invariant.** `tf.active` is read only in `checkUpkeep`;
`_createMarket` never checks it. `checkUpkeep` is a `view` and the keeper builds `performData`
itself, so the `forwarder` or `owner` can still mint a market for a disabled timeframe by
hand-crafting a `CreateSlot`. That is not reachable by accident — an honest keeper derives
`performData` from `checkUpkeep`, and `performUpkeep` is gated to forwarder/owner (F-2026-17726)
— and the frozen `pairTfLastCreated` plus the `PlannedStartTooStale` guard narrow it to one
slot that expires `RESOLVER_MAX_STALENESS` after its `endTime`. But do not treat the toggle as
a hard block when the threat model includes a compromised keeper key.

A timeframe cannot be *removed* from a deployed contract. `NUM_TIMEFRAMES` is a `constant`,
`timeframes` is a fixed-size array, and durations are written only in the constructor — the
whole owner surface can set `.active` and nothing else. Index 2 therefore stays as a dormant
slot, costing one `SLOAD` per pair inside an off-chain `view`.

Deleting it was evaluated on 2026-08-18 and **deliberately not pursued**: it needs new
bytecode, and the scripted path (`Deploy.s.sol`) always mints a fresh resolver alongside the
cycler — it only supports reusing the settlement, via `EXISTING_SETTLEMENT_ADDRESS`. Swapping
the resolver is the step that orphaned six markets on 2026-08-14, and a new resolver address
needs Chainlink allow-listing with external lead time. That is a live-stack migration in
exchange for deleting a dormant array entry.

If it is ever revisited, prefer a **cycler-only** redeploy against the existing resolver and
settlement — the cycler constructor takes both as addresses, and leaving the resolver alone
avoids the orphaning failure mode entirely. It needs `settlement.setAutocycler`,
`resolver.setAuthorizedCaller(new, true)`, then `setForwarder` / `addPair` ×2 /
`setPreStartWindowSec(300)` on the new cycler, and `deprecate` on the old one. Removing the
last index leaves 0 and 1 unrenumbered, so `pairTfLastCreated` and off-chain consumers keyed on
`tfIdx` survive. See [`../deployments/README.md`](../deployments/README.md).

**It stops creation only.** Markets already open keep trading and still need the resolver
service to settle them at their `endTime` — do not pair this with disabling the resolver, or
you strand them (`redeem` reverts `NotResolved`). There is no per-timeframe trading halt;
`setPaused` is global and blocks user exits too (see [Pause and emergency](#pause-and-emergency)).

Timing: a slot becomes eligible at `next_start − preStartWindowSec`, not at `next_start`. With
the deployed 300s window, disabling the 60-minute timeframe at 10:56 is already too late to
stop the 11:00 market. Check before assuming you have until the boundary:

```bash
LAST=$(cast call $CYCLER "pairTfLastCreated(bytes32,uint256)(uint256)" $(cast keccak "BTC/USD") 2 --rpc-url $ARBITRUM_RPC_URL)
WIN=$(cast call $CYCLER "preStartWindowSec()(uint256)" --rpc-url $ARBITRUM_RPC_URL)
echo "next slot eligible at $(( LAST + 3600 - WIN ))"
```

### Re-enabling: bump the pointers first

`pairTfLastCreated[pair][index]` freezes while a timeframe is off. On re-enable, every missed
slot is retried and rejected with `PlannedStartTooStale`, and `performUpkeep` advances the
pointer **one slot per call** — a day of downtime on the 60-minute timeframe is 24 upkeep
rounds; on the 5-minute timeframe it is 288. Set the pointers to the current boundary first,
**for every cycling pair**, then flip the flag:

```bash
BTC=$(cast keccak "BTC/USD"); ETH=$(cast keccak "ETH/USD")
BOUNDARY=$(( $(date -u +%s) / 3600 * 3600 ))   # match the timeframe's duration

cast send $CYCLER "setPairTfLastCreated(bytes32,uint256,uint256)" $BTC 2 $BOUNDARY --rpc-url $ARBITRUM_RPC_URL --account <OWNER>
cast send $CYCLER "setPairTfLastCreated(bytes32,uint256,uint256)" $ETH 2 $BOUNDARY --rpc-url $ARBITRUM_RPC_URL --account <OWNER>
cast send $CYCLER "toggleTimeframe(uint256,bool)" 2 true --rpc-url $ARBITRUM_RPC_URL --account <OWNER>
```

Enumerate the pairs with `cyclingPairCount` / `cyclingPairAt` rather than trusting the two
above — `addPair` may have added more.

Related, narrower controls: `removePair` stops **all** timeframes for one pair;
`deprecate(replacement)` stops the whole cycler permanently (one-shot, irreversible).

The 60-minute timeframe is disabled on both dev and prod as of 2026-08-18 — see
[`../deployments/README.md`](../deployments/README.md#owner-actions-not-deploys) for the
transactions and the frozen pointer values.

## Deploy and configuration

See [`ONCHAIN_OPERATIONS.md`](./ONCHAIN_OPERATIONS.md) for the deploy path, and the
`.env.dev.example` / `.env.prod.example` templates at the repo root. Common tasks:

```bash
npm run simulate:dev     # dry run, no broadcast — always first
npm run deploy:dev
npm run simulate:prod
npm run deploy:prod      # prompts for confirmation
```

Each deploy writes a JSON record to `deployments/<label>-<block>.json`.

## Funding dev wallets (dev-USDT)

Manual, by design — not an npm target, so the mint authority key is never sourced into a
deploy shell.

The dev collateral token `0xCa4f77A38d8552Dd1D5E44e890173921B67725F4` ("USDT Mock", USDTm,
6 decimals) is **not** the repo's `MockUSDT` and its `mint()` is **owner-gated**, not
permissionless — calling it from any other key reverts `OwnableUnauthorizedAccount`. The mint
authority is `0xAff5289591653038340645FDc1e1Ed3a3B52E436`.

That wallet already holds ~10^13 USDTm, so a plain transfer is normally enough and no minting
is needed:

```bash
# 5,000 USDTm (6 decimals) to a test wallet
cast send 0xCa4f77A38d8552Dd1D5E44e890173921B67725F4 \
  "transfer(address,uint256)" <RECIPIENT> 5000000000 \
  --rpc-url $ARBITRUM_RPC_URL --account <minter-keystore-account>
```

Swap `transfer` for `mint(address,uint256)` if the balance is ever exhausted. Prefer a Foundry
keystore (`cast wallet import <name> --interactive`) over `--private-key` so the key stays out
of shell history.

Users must also approve the Settlement before trading — collateral is pulled from the user at
fill time, there is no deposit-to-relayer step.

## Environments

**Both dev and prod are on Arbitrum One (chainId 42161).** Dev is not a testnet — it uses a
valueless dev-USDT and a mock Data Streams verifier, but real gas. There is no chain-level
guard against pointing a dev command at prod; the env file is the only separation, which is
why the npm targets bind one file per target.
