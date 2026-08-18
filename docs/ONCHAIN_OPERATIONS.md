# On-chain operations (deployment and pair configuration)

Rewritten from code + live on-chain state on 2026-08-10. The previous version documented the
legacy Data Feeds path (`configureFeed`); strike and resolution now come from Chainlink Data
Streams.

## New deployments

[`script/Deploy.s.sol`](../script/Deploy.s.sol) deploys `UpDownSettlement`,
`ChainlinkResolver` and `UpDownAutoCycler`, then wires everything inside one broadcast:

- Settlement pointers: `setResolver`, `setAutocycler`, `setRelayer`, `setTreasury`
- Rebate budget: `setRebateBudget(5_000e6, 7 days)`
- Resolver auth: `setAuthorizedCaller(cycler, true)` and `setAuthorizedCaller(relayer, true)`
- **Streams feeds: `configureStreamsFeed` for BTC/USD and ETH/USD**
- Cycler: `setForwarder(keeper)`, `addPair(BTC/USD)`, `addPair(ETH/USD)`,
  `setPreStartWindowSec(300)`
- Optional ownership handoff to `OWNER_ADDRESS` (Ownable2Step — sets `pendingOwner` only)

Run via `npm run simulate:dev|prod` first, then `npm run deploy:dev|prod`.

### Why the Streams feeds are configured in-script

`registerMarket` gates on `priceFeeds[pairId] != 0 || streamsFeedId[pairId] != 0`. The
deploy populates `priceFeeds` from the constructor, so **that gate passes even with no
Streams config**. But `resolve` / `captureStrike` read `streamsFeedId`. A resolver missing it
would open markets, take collateral, and never be able to settle them — and since `redeem`
reverts `NotResolved` and `burn` requires a complete set before `endTime`, that collateral
would be permanently locked. `STREAMS_FEED_ID_BTC_USD` / `_ETH_USD` are therefore required
env vars, and an unset value aborts the deploy before anything is broadcast.

## Existing deployments (manual)

Configure a Streams feed for a pair (owner only):

```bash
PAIR=$(cast keccak "ETH/USD")
cast send <RESOLVER> "configureStreamsFeed(bytes32,bytes32)" "$PAIR" <FEED_ID> \
  --rpc-url $ARBITRUM_RPC_URL --account <OWNER>
```

Enable a pair on the cycler (owner only; idempotent):

```bash
PAIR=$(cast keccak "ETH/USD")
cast send <CYCLER> "addPair(bytes32)" "$PAIR" --rpc-url $ARBITRUM_RPC_URL --account <OWNER>
```

`removePair` is the inverse — it stops new markets for the pair while leaving open ones to
resolve normally.

Stop one timeframe across every cycling pair (owner only). On the **currently deployed**
cyclers the indices are 0 = 5m, 1 = 15m, 2 = 60m; in source the 60m slot has been removed and
`NUM_TIMEFRAMES` is 2, so index 2 reverts `InvalidTimeframeIndex` on anything deployed from
`main` after 2026-08-18:

```bash
cast send <CYCLER> "toggleTimeframe(uint256,bool)" 2 false \
  --rpc-url $ARBITRUM_RPC_URL --account <OWNER>
```

Like `removePair`, this gates creation only; open markets still resolve. Re-enabling needs
`setPairTfLastCreated` on each pair first or the cycler grinds through every skipped slot one
`performUpkeep` at a time — full procedure and the current disabled state in
[`operations.md`](./operations.md#timeframes).

The legacy push-feed setter `configureFeed(bytes32,address)` still exists but only feeds
`priceFeeds`, which the strike/resolve lifecycle no longer reads.

## Authorization

`ChainlinkResolver` gates `registerMarket`, `resolve` and `captureStrike` on
`authorizedCallers` (F-2026-17760) — resolution is **not** permissionless. Both the cycler
(captures strikes, registers markets) and the relayer (submits resolutions) must be
authorized. The deploy does this; verify it on any hand-built deployment.

`registerMarket` additionally requires `settlement == trustedSettlement`, an immutable set in
the resolver's constructor. A resolver can only ever serve the settlement it was built for.

## Post-deploy spot check

```bash
cast call $RESOLVER "trustedSettlement()(address)"
cast call $RESOLVER "streamsFeedId(bytes32)(bytes32)" $(cast keccak "BTC/USD")
cast call $RESOLVER "authorizedCallers(address)(bool)" $CYCLER
cast call $CYCLER   "forwarder()(address)"
cast call $CYCLER   "preStartWindowSec()(uint256)"
cast call $SETTLEMENT "treasury()(address)"
cast call $SETTLEMENT "paused()(bool)"
cast call $SETTLEMENT "nextMarketId()(uint256)"
```

Expect: `trustedSettlement` = the new settlement, both feed ids non-zero, cycler authorized,
`forwarder` = your keeper (**on prod, distinct from the relayer**), `preStartWindowSec` = 300,
treasury non-zero, not paused, `nextMarketId` = 0 on a fresh deploy.

## Reference addresses (Arbitrum One)

| Item | Address |
|---|---|
| Chainlink ETH/USD (strike-side, legacy) | `0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612` |
| Chainlink BTC/USD (strike-side, legacy) | `0x6ce185860a4963106506C203335A2910413708e9` |
| Chainlink sequencer uptime | `0xFdB631F5EE196F0ed6FAa767959853A9F217697D` |
| Data Streams VerifierProxy (real) | `0x478Aa2aC9F6D65F84e09D9185d126c3a17c2a93C` |
| LINK token | `0xf97f4df75117a78c1A5a0DBb814Af92458539FB4` |
| USDT (prod) | `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9` |
| dev-USDT (mock, owner-gated mint) | `0xCa4f77A38d8552Dd1D5E44e890173921B67725F4` |

A new resolver address must be **allow-listed by Chainlink** for the stream ids it uses
before `verify` will succeed. This has external lead time — start it before deploying.
