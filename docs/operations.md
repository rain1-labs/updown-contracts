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

> **Source and chain disagree right now.** `NUM_TIMEFRAMES` is **2** in this repo — the
> 60-minute slot was deleted on 2026-08-18. The **deployed** dev and prod cyclers still carry
> the 3-slot layout with index 2 merely disabled via `toggleTimeframe(2, false)`. Until a
> redeploy, that disable flag is the only thing holding prod, with the soft-gate caveat below.
> Read the "removed" wording as describing the source; read the toggle procedure as describing
> the live stack.

`UpDownAutoCycler` cycles fixed timeframes seeded in the constructor and toggled by the owner
with `toggleTimeframe(uint256 index, bool active)`:

| Index | Duration | Dispute | Market | In source | On chain |
|---|---|---|---|---|---|
| 0 | 300s | 600s | 5-minute | yes | yes, active |
| 1 | 900s | 1800s | 15-minute | yes | yes, active |
| 2 | 3600s | 7200s | 60-minute | **removed** | present, **disabled** |

Indices 0 and 1 keep their values across the removal, so `pairTfLastCreated` and every
off-chain consumer keyed on `tfIdx` survive a redeploy unrenumbered.

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

A timeframe cannot be removed **on a deployed contract**. `NUM_TIMEFRAMES` is a `constant`,
`timeframes` is a fixed-size array, and durations are written only in the constructor — the
whole owner surface can set `.active` and nothing else. That is why removal required a source
change and why it is not yet live.

Shipping it needs new bytecode. Prefer a **cycler-only** redeploy against the existing resolver
and settlement: `Deploy.s.sol` always mints a fresh resolver too (it only supports reusing the
settlement, via `EXISTING_SETTLEMENT_ADDRESS`), and swapping the resolver is the step that
orphaned six markets on 2026-08-14 — plus a new resolver address needs Chainlink allow-listing
with external lead time. A cycler-only swap needs `settlement.setAutocycler`,
`resolver.setAuthorizedCaller(new, true)`, then `setForwarder` / `addPair` ×2 /
`setPreStartWindowSec(300)` on the new cycler, and `deprecate` on the old one. See
[`../deployments/README.md`](../deployments/README.md).

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
