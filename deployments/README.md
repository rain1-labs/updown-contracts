# Deployment records

Written by `script/Deploy.s.sol` via `vm.writeJson`, one file per deploy:
`<DEPLOY_LABEL>-<l1Block>.json`.

Keyed on `DEPLOY_LABEL` rather than chain id because dev and prod both run on
Arbitrum One (42161), so a chainid-keyed name would have dev clobbering prod.

## Only real deploys are recorded

The write is gated on `WRITE_DEPLOYMENT_RECORD`, which the `deploy:*` npm
targets set and `simulate:*` deliberately does not. A dry run produces a file
byte-identical to a real deploy's, so without the gate this directory fills
with records for deploys that never happened. `verify:*` does not write either
— it re-verifies an existing deployment and mints no new addresses.

## On the block number

Solidity's `block.number` on Arbitrum returns the **L1** block number, not the
Arbitrum block. It is recorded for provenance but **cannot be used to find the
deploy transaction on Arbiscan** — search by contract address instead.

Records written before 2026-08-10 use the key `block` for this value; newer
ones use `l1Block`. Same number, clearer name.

## Contents

Public addresses only — no keys, no RPC URLs, no API keys. Safe to commit, and
committed on purpose: this is the audit trail of which addresses replaced which,
and the only place the deployer / relayer / treasury / keeper-forwarder set for
a given deploy is written down.

## A record proves a deploy FINISHED, not that contracts exist

`vm.writeJson` runs at the END of `Deploy.s.sol`. A run that is interrupted
partway still creates contracts, and — because `setResolver` / `setAutocycler`
come well before the write — can repoint Settlement at them, without ever
producing a file here. **This directory is therefore a lower bound on what has
been deployed, not the full set.**

To enumerate everything a deployer has ever created, derive the CREATE
addresses from its nonces rather than trusting this directory:

```sh
N=$(cast nonce "$DEPLOYER" --rpc-url "$ARBITRUM_RPC_URL")
for n in $(seq 0 $((N-1))); do
  a=$(cast compute-address "$DEPLOYER" --nonce "$n" --rpc-url "$ARBITRUM_RPC_URL" | awk '{print $NF}')
  [ "$(cast codesize "$a" --rpc-url "$ARBITRUM_RPC_URL")" != "0" ] && echo "nonce $n -> $a"
done
```

### Known unrecorded prod stack (2026-08-13)

| | Address | Deployer nonce |
|---|---|---|
| Resolver | `0x589118a9dba1F863BB0579D728b1ac7ce2F6e673` | 34 |
| AutoCycler | `0x7D4fA2f9d054E4d818b3B83cDe947Facbc06bDA7` | 35 |

Created during the TWAP cutover by a `deploy:prod` run that aborted partway. It
got as far as creating both contracts and repointing Settlement at the resolver,
then stopped: `streamsFeedId` is zero for both pairs, `forwarder` is
`address(0)`, and `cyclingPairCount` is 0 — so it never reached
`configureStreamsFeed`, `setForwarder` or `addPair`.

For a short window prod's Settlement pointed at a resolver with **no stream
configuration**, which would have opened markets it could never settle. It was
harmless only because the paired cycler had no pairs, so nothing could be
created. The run that succeeded immediately afterwards is `prod-25747248.json`.

The cycler was deprecated on 2026-08-13 (tx
`0x5da91b5ae75e12ca62e544532ad1c22718b2c01e9b23d6dd8f6415b5fd22e296`) so it can
never accept keeper work. Both contracts are inert; they are listed here only so
an audit run against this directory does not conclude they were never deployed.

## `safe/` — owner batches

`script/safe-batch.mjs` (`npm run safe:pending:<env>`, `npm run safe:call:<env>`) writes one
Safe{Wallet} Transaction Builder file per proposed owner batch here:
`<label>-<name>-<UTC stamp>.json`. Public calldata only. Commit them — they are the record of
what was *proposed*; the Safe's transaction history is the record of what *executed*, and
the two can legitimately differ (a batch can be edited or dropped in the UI).

## Prod stack lineage

| Resolver | AutoCycler | Record | State |
|---|---|---|---|
| `0xC906714a…654Bf` | `0x86f9020e…0288` | `prod-25724175.json` | Retired, cycler deprecated |
| `0x4583B912…4996` | `0x027822Ce…f9C2` | `prod-25746267.json` | Retired, cycler deprecated |
| `0x589118a9…e673` | `0x7D4fA2f9…bDA7` | *(none — see above)* | Aborted, cycler deprecated |
| `0x9B524376…885a` | `0xF2DBC8C5…3544` | `prod-25747248.json` | Retired, cycler deprecated |
| `0x8fae4F24…2076c` | `0x38288B85…49688` | `prod-25755446.json` | **Live** (TWAP 60s) |

Settlement `0x4B662f68…754e` is unchanged across all of them — every migration
ran in `EXISTING_SETTLEMENT_ADDRESS` mode, so positions and collateral never
moved.

### 2026-08-14 — TWAP 30s → 60s

Chainlink granted the account entitlement for the `TWAP: 60s` streams on
2026-08-14 (both ids had returned HTTP 401 "feeds not authorized" on 08-13 and
again earlier on 08-14). The cutover deployed `prod-25755446.json` and the new
resolver holds the 60s ids for both pairs.

The old cycler `0xF2DBC8C5…3544` was deprecated after the cutover (tx
`0x37c79ed53db36955d8423e7bc4ed951ecb152352fb5286a7cb8bc8f407a287aa`).

**Six markets were orphaned by this run and later recovered.** The upgrade ran
with `--skip-drain`, so `setResolver` fired while 2523, 2526, 2540, 2542, 2545
and 2546 were still open. All six were re-adopted on the new resolver with
`registerMarket` and resolved normally — the resolver service picked them up on
its own once registered, with no `ResolveFailed`.

One of them held real money, and the timeline is the point:

```
19:43:30  drain scan records market 2542 notional 0
19:43:49  two users enter opposite sides, 31.25 USDT each
19:44:15  deploy repoints Settlement -> 2542 orphaned
19:45:00  market 2542 ends, unresolvable by either resolver
```

The preflight was correct when it ran; the collateral arrived 19 seconds later.
`--skip-drain`'s "safe when the open markets are empty" check reads one instant,
and open markets keep taking positions after it. Market 2542 settled 1875.874 ->
1877.725 (option 1), and the 62.50 USDT became redeemable again.

## Owner actions (not deploys)

Owner-gated state changes that alter live behaviour but mint no addresses, so
`Deploy.s.sol` writes no record for them. Logged here because this directory is
the audit trail for "who changed what on the live stack".

### 2026-08-18 — 60-minute timeframe disabled on both environments

`toggleTimeframe(2, false)` on the AutoCycler. Timeframe index 2 is the
3600s / 7200s-dispute slot; indices 0 (5m) and 1 (15m) were left `active`.

| Env | Cycler | Tx | Arbitrum block |
|---|---|---|---|
| dev | `0x8495c2d3…325172` | `0x75919bb325f66cca24db760df6c0612361f4ed6702bfad94a2cf5e46be3a8b6e` | 495453890 |
| prod | `0x38288B85…49688` | `0x272656188ec4d509801b9a39176d994a82556b28e9501371bec8c92e42fc0944` | 495792252 |

Both sent from the deployer/owner EOA of their environment (dev
`0x1B4320cC…26E6a`, prod `0xCEcEF153…f3c32`) — neither stack has completed an
`OWNER_ADDRESS` handoff, so `pendingOwner` is zero on both.

One call covers **both cycling pairs**: the flag lives on the timeframe, not the
pair, so BTC/USD and ETH/USD stopped together.

Prod landed at 10:10 UTC. The next hourly slot (start 11:00) would not have
become eligible until 10:55 — `next_start − preStartWindowSec`, the window
being 300s — so the 11:00 market was never created. Markets 5479 and 5482 were
already open for the 10:00–11:00 slot and were deliberately left alone; nothing
about this flag touches an existing market, so both stay on the normal resolver
path and settle at their 11:00 UTC `endTime` (unverified at the time of writing
— they were still `resolved=false` 47 min ahead of the boundary; confirm with
`getMarket` rather than assuming). All six active prod markets carried
**0.00 USDT** notional at the time of the call, so no user collateral was in
scope. Contrast the 2026-08-14
cutover above, where an owner action did strand open markets.

**The pointers freeze.** `pairTfLastCreated[<pair>][2]` stops advancing while
the timeframe is off, at `1787047200` (2026-08-18 10:00 UTC) on prod and
`1786744800` (2026-08-14 22:00 UTC) on dev. It does not resume from "now" on
re-enable — see the re-enable procedure in
[`../docs/operations.md`](../docs/operations.md#timeframes). Flipping the flag
back on alone makes the cycler grind one skipped hour per `performUpkeep`.

### 2026-09-03 — prod live stack handed to the Safe

Ownership of all three live prod contracts (`prod-25890279.json`) moved from the deployer
EOA `0xCEcEF153…f3c32` to the client Safe **`0x26dA6f5D8062a700aE01da2616e78F2132FCaBd8`**
(Safe 1.4.1+L2, 2-of-4). Two steps, per Ownable2Step:

1. `npm run handoff:prod` — `transferOwnership(safe)` x3 from the deployer.
2. Safe batch `safe/prod-pending-20260903-121915.json` — `acceptOwnership()` x3 via
   MultiSendCallOnly, the Safe's first ever transaction (nonce 0), 2 confirmations:
   tx `0x8fb68e4b8edf7aa46e1d40a3cf5b572bb75b7ebaed331490c650700d4f08d5b9`, Arbitrum block 501319218 (2026-09-03 12:26 UTC).

| Contract | Address | owner() after |
|---|---|---|
| UpDownSettlement | `0x9eaFEEC6…476e` | Safe |
| ChainlinkResolver | `0x8C7634dE…b5a6` | Safe |
| UpDownAutoCycler | `0x882F8365…Adb0` | Safe |

`pendingOwner` is zero on all three. Nothing operational changed: resolver, cycler, forwarder,
relayer and pairs are as deployed and `paused == false`. From here every owner call on prod is
a Safe batch (`npm run safe:call:prod`), and `upgrade:prod` runs in owner-batch mode — see
[`../docs/operations.md`](../docs/operations.md#ownership).

**Still on the deployer key, by decision (see the next entry):** the retired Settlement
`0x4B662f68…754e`, its resolver/cycler pair, and every older resolver/cycler pair. All are inert.

### 2026-09-03 — retired prod Settlement emptied and its cycler deprecated

Follow-up to the handoff above. The retired Settlement `0x4B662f68…754e` was still holding
**68.306446 USDT** of unredeemed winnings, all of it in four resolved markets and all owned by
one wallet, `0x6b434001…4847`. Paid out with the permissionless `redeemFor` from the deployer
key (gas only — `redeemFor` can pay nobody but the share holder):

| Market | Winner | Paid (USDT) | Tx |
|---|---|---|---|
| 10072 | UP | 2.173913 | `0x6ac762f06c70ecb9a41c338856745a8188fe0ee74749e4e1f47fcb32ea4ba1d5` |
| 10190 | UP | 43.103448 | `0xf0b8905c786c1732ddca2d6652505cea2d109f4bdd44cbcde09a22cf2136108e` |
| 10198 | DOWN | 22.388059 | `0x9358a2ae22435f1ba7893621b5672fd9dd727ae37a7b2021745200612f955b3c` |
| 10216 | UP | 0.641026 | `0x43ec38b21de8f993bfd5e467c8c63effcaafb2b866d1fc17d3a6ec03a9ed44b0` |

`usdt.balanceOf(settlement)` is now **0** and `marketRetained` is 0 on all four.

The retired cycler `0x38288B85…49688` was then deprecated (tx
`0x2da10e90da8b2101b93c5e1cc1519ec876a82c388a0ccd3a9042658f22a4c8a8`, Arbitrum block
501327910), closing the last live door on the old stack: its owner could otherwise `addPair`
and resume minting markets against the old Settlement.

**Ownership of the retired stack was deliberately NOT transferred to the Safe.** With zero
collateral, a deprecated cycler and no Settlement trusting its resolver, the deployer key's
ownership of these contracts controls nothing — the emergency-withdraw path has nothing to
withdraw. Same reasoning as for the eight older resolver/cycler pairs. The deployer key now
owns only inert contracts.

Tooling added for this: `script/UnredeemedSweep.s.sol` (find markets still holding collateral)
and `script/redeem-for.mjs` (find holders from events and push `redeemFor`). Note the sweep
script is too slow for a 17k-market Settlement over a remote RPC; the market ids above were
found from `MintMatched` logs instead, then checked with `marketRetained`.

### 2026-09-02 — dev redeployed twice for the fee buyback

Dev only. Prod is untouched and still runs the pre-buyback Settlement, so
`platformFee` there continues to go to the treasury on each fill.

| Record | Settlement | Resolver | AutoCycler |
|---|---|---|---|
| `dev-25882680.json` | `0xE607dD4b…72fFa9` | `0xEe8254C5…aa90aa` | `0x6a87A81C…bdCFEA` |
| `dev-25889013.json` | `0xB1c5b4A4…a2313b` | `0x48fD463D…555ADf` | `0xbCC639e7…bd8982` |

`dev-25889013` is live. Both are fresh Settlements, not migrations: the
Settlement is not upgradeable and `ChainlinkResolver.trustedSettlement` /
`UpDownAutoCycler.settlement`+`resolver` are immutable, so one Settlement change
replaces all three addresses. The pre-buyback dev stack
(`0x8EA9Cdc4…d055F4`) and `dev-25882680` are both orphaned.

**Why twice.** The first deploy ran the buyback inside `resolve`. That coupling
broke resolution for every fee-bearing round:

| resolve | gas |
|---|---|
| round with no fee (burn short-circuits) | ~122,650 |
| round with a fee (quoter + swap + burn) | ~489,750 |

The relayer sized gas from an estimate plus ~3%, which was correct while
`resolve` was deterministic. With a Uniswap swap inside, the cost moves with
pool state, and one tx came up **37 gas short** — limit 489,625, needed
489,662. Market 11 retried six times and never resolved; it lapsed past the
resolver's 1h `MAX_STALENESS` and is permanently unresolvable on the orphaned
contract. Rounds with no fee resolved normally throughout, which is why only
some markets stalled.

try/catch did not save it: **it catches reverts, not gas exhaustion.** The
`resolve` frame's own OOG rolled back every state write in it and no inner
`catch` ran. `ChainlinkResolver` caught the failure one level up and emitted
`ResolveFailed` with an empty reason, so the outer tx reported success while
the round stayed unresolved.

The second deploy takes the swap off that path entirely. `resolve` makes no
external calls and needs no reentrancy guard; the burn is now keeper-driven via
`buybackAndBurn(marketIds)`, eligible on `endTime` rather than resolution.
`buybackExecutor` also became an allow-list (`buybackExecutors` mapping) so a
backup keeper can be added without displacing the primary.

**Stranded fees were retired before the redeploy.** `buybackAndBurn([11, 17])`
on `0xE607dD4b…72fFa9` from the owner EOA, tx
`0xb13b1767038c503fa18761e9bc1a4323e51a99dc231679bbdbe7de8415e5fd38` —
2.134995 dev USDT spent, **14.2898 dev RAIN burned**, `feesAccrued` back to 0.
That is also the first end-to-end proof of the buyback on a live chain.

**Timeframes reset on each fresh cycler.** The constructor enables all three
(5m / 15m / 60m) and `Deploy.s.sol` never touches them, so the 2026-08-18
`toggleTimeframe(2, false)` above does **not** carry across a redeploy. It was
re-applied to both dev cyclers:

| Cycler | Tx |
|---|---|
| `0x6a87A81C…bdCFEA` (orphaned) | `0xc2ea5f19f8773c071ff7c48b11aca44a6192378a8a7c7671fe6d614b84793660` |
| `0xbCC639e7…bd8982` (live) | `0xd5f2ea66486e84c40e5dbdb62cfc9f9b9bdde669c04a6e88ac4b8e3a00877392` |

Both from the deployer/owner EOA. Any future redeploy needs this call again —
it is not part of `Deploy.s.sol`.

**Ownership.** Neither dev deploy set `OWNER_ADDRESS`, so the deployer EOA
`0x1B4320cC…26E6a` owns all three and `pendingOwner` is zero — same posture as
the earlier stacks recorded above.

### 2026-09-02 — prod cutover to the fee buyback

`prod-25890279.json` is live:

| | Address |
|---|---|
| UpDownSettlement | `0x9eaFEEC65C74CE98DA62C6f6b154880e6c64476e` |
| ChainlinkResolver | `0x8C7634dEfaC202491d7842C0CC174610E158b5a6` |
| UpDownAutoCycler | `0x882F83659DFd6e0E2705F696F8d0F49F3d7CAdb0` |

A fresh Settlement, not a migration — the buyback cannot ship any other way, so
`EXISTING_SETTLEMENT_ADDRESS` was deliberately left empty. Note this also means
`npm run preflight:prod` and `npm run upgrade:prod` were both unusable here:
each hard-requires that variable, because each exists for the resolver/cycler
upgrade path where the Settlement genuinely is preserved.

**Sequence used.** Both pairs were `removePair`d on the old cycler
`0x38288B85…49688` first (txs `0xfa4e4a14…` BTC, `0x57bc31a2…` ETH), which
stopped market creation immediately; the four markets still open then drained
to resolution over ~10 minutes and the deploy ran against a fully settled old
stack. That ordering costs a short window with no tradeable markets — the
alternative (deploy first, repoint the keeper, retire the old cycler after)
avoids the gap but runs both stacks briefly. The gap was accepted here.

**The old stack is untouched and still works.** A fresh Settlement deploy never
writes to the previous one, so `0x4B662f68…0C754e` keeps its own resolver and
cycler, old markets stay resolvable, and holders can still `redeem()`. It held
**68.306446 USDT** of unredeemed winnings at cutover — not stranded, but it does
not migrate either. Users can claim it themselves, or the backend can push it
with the permissionless `redeemFor(marketId, holders[])`.

**Two more things do not carry across a Settlement replacement:** every user's
USDT allowance points at the old address and must be re-approved before their
first trade, and the 60m timeframe is re-enabled by the fresh cycler's
constructor and needs `toggleTimeframe(2, false)` again.


