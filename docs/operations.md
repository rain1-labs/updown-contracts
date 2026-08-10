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
