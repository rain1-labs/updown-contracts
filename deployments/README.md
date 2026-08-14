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
