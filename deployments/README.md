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
