# UpDown Markets — Cowork Context

Read this entire file before doing anything.

**Source of truth:** for anything concerning the contracts in this repo, the CODE is authoritative and this file describes it. If they disagree, this file is stale — fix it here, do not "fix" the contracts to match. The contract sections below were rewritten from the code on 2026-08-10 (branch `dev`) after the Hacken remediation inverted several decisions that this file previously recorded as locked.

Product decisions that live outside the contracts (backend matching behaviour, UI, SDK) are still locked here.

---

## What This Project Is

UpDown is a Polymarket-style UP/DOWN price prediction market built on RAIN Protocol on Arbitrum. Users predict if an asset goes UP or DOWN within a fixed window. Architecture: **off-chain order matching (centralized, like Polymarket), on-chain settlement.** Goal: ship before Hyperliquid's HIP-4 hits mainnet as the first decentralized up/down prediction market.

Built for bots — market maker bots (posting two-sided quotes, earning 0.8% maker fee) and taker bots (latency arb, signal-based trading). Pure order book, no LP pool, no AMM.

---

## Monorepo Structure

```
/contracts     — UpDownSettlement + ChainlinkResolver + UpDownAutoCycler (153 tests, 11 fork-skipped)
/backend       — Phase 2+3: Matching engine, API, services
/frontend      — Phase 4: Next.js frontend
/sdk/typescript — Phase 5: TypeScript bot SDK
/sdk/python    — Phase 5: Python bot SDK
/docs          — API docs, bot guide, operations, e2e checklist
```

All 5 phases are complete. **This repository is `/contracts` only** — backend/frontend/SDK
sections below are carried over as product context and are not verifiable from here.

---

## Locked Decisions — These Are Not Variables

### Order Book
- **Pure order book like Polymarket. No LP pool. No AMM backstop. No passive liquidity.**
- Market makers provide all liquidity by posting limit orders on both sides of the book.
- Matching is off-chain in the backend matching engine. NOT on-chain.
- Cancel priority enforced by the matching engine: cancels process before taker orders in each batch.
- Price-time priority for matching.

**On-chain settlement entrypoints** (`UpDownSettlement`, all `onlyRelayer whenNotPaused`).
RAIN's TradePool / `enterOption()` is no longer used — the protocol owns its settlement:

| Entrypoint | Crosses |
|---|---|
| `enterPosition` | a BUY against a SELL of the same option — shares transfer between them |
| `mintMatch` | two BUYs on opposite options — mints a fresh complete set from their combined cash |
| `mergeMatch` | two SELLs on opposite options — burns a complete set and pays out proceeds |
| `enterPositionBatch` / `mintMatchBatch` / `mergeMatchBatch` | batched variants of the above |

Both order signatures are verified on-chain per fill via OpenZeppelin `SignatureChecker`,
so an EOA or **any ERC-1271 account** can be a maker. Order-session keys reach this path
through rain.trade's Alchemy Modular Account v2 (see `test/OrderSessionForkTest.t.sol`).

### Fees
- **0.7% platform fee + 0.8% maker fee = 1.5% total** — the product target, enforced
  **off-chain by the backend**, not by the contracts.
- **There are no fee-rate variables on-chain.** F-2026-17746 removed `platformFeeBps` /
  `makerFeeBps`. The contracts never compute a percentage; the relayer supplies the exact
  `platformFee` and `makerFee` amounts per fill.
- **The on-chain protection is a signed cap, not a rate.** Every `Order` carries `maxFee`
  — the maximum TOTAL fee that signer accepts across all fills of that order. Relayer-supplied
  fees exceeding it revert `FeeExceedsTakerCap` (F-2026-17731). `orderFeesPaid` accumulates
  per order hash so partial fills cannot be split to charge the cap N times.
- Fees are **taker-paid and peer-to-peer**: `platformFee` → `treasury`, `makerFee` → the maker.
  Neither ever touches market backing. A pure resting maker order pays no fee.
- Market-maker rebates are separate: `accumulateRebate` credits a counter (relayer-called),
  claimed later via permissionless `claimRebate`, bounded by a rolling
  `rebateBudgetPerWindow` / `rebateWindowDuration` circuit-breaker (F-2026-17779).
  `dmmRebateBps` is 0 on both live deployments.
- Creator fee: 0% — markets are auto-generated, no creator entity exists.

### Timeframes
- **5 minutes, 15 minutes, 60 minutes**
- NOT 5/10/15. NOT 1 minute.
- UI labels: "5 min", "15 min", "1 hour"
- Contract durations: 300s, 900s, 3600s

### Dispute Windows — VESTIGIAL on-chain
- `UpDownAutoCycler.TimeframeConfig.disputeDuration` still holds 600 / 1800 / 7200
  (2x the prediction time), set in the constructor.
- **Nothing reads it.** It is written once and never consumed by any contract. There is no
  dispute mechanism in `UpDownSettlement` — resolution is final once `resolve` lands.
- `oracleEndTime` was a RAIN TradePool parameter and no longer exists anywhere.
- If disputes are still a product requirement, they are a backend concern today.

### Pairs
- **BTC/USD and ETH/USD both cycle.** `UpDownAutoCycler` adds BTC/USD in its constructor;
  `Deploy.s.sol` calls `addPair` for both, so a fresh deploy cycles both from block one.
- Pair id = `keccak256("BTC/USD")` / `keccak256("ETH/USD")`.
- Strike and resolution prices come from **Chainlink Data Streams** (per-pair `streamsFeedId`),
  not the push aggregators. The AggregatorV3 addresses are still stored for legacy readers.
- Pairs shown as tabs within each timeframe section, not separate rows

### Options
- 1-indexed: **UP = option 1, DOWN = option 2** (`OPTION_UP` / `OPTION_DOWN` in both contracts)
- Resolution sequence: `ChainlinkResolver.resolve(...)` → `UpDownSettlement.resolve(marketId,
  settlementPrice, winner)`. RAIN's `closePool()` / `chooseWinner()` no longer exist.
- **Tie → DOWN wins.** `ChainlinkResolver.sol:557` uses a strict `>`:
  `settlementPrice > strikePrice ? OPTION_UP : OPTION_DOWN`. Exact equality falls to DOWN.
  There is no 0.001% tolerance band — the comparison is exact.
- On resolve, the losing side's `optionShares` is zeroed (F-2026-17954) so off-chain readers
  do not mistake dead shares for live supply.

### Settlement (NON-CUSTODIAL — inverted from the original design)

This section previously described a custodial model. The Hacken remediation inverted it
(`c1c8344`, "invert trust model to non-custodial on-chain shares"). The contracts now hold
per-user shares directly and users exit without the relayer.

- **Shares are on-chain and per-user**: `userShares[marketId][holder][option]`. They are NOT
  a MongoDB-only record, and they do NOT belong to the relayer.
- **Collateral is held by `UpDownSettlement`**, tracked per market in `marketRetained`.
  Users approve the Settlement and their USDT is pulled at fill time — no deposit-to-relayer step.
- **Redemption is trustless and permissionless** (F-2026-17778). A winner calls `redeem(marketId)`
  and receives their own USDT directly. `redeemFor(marketId, holders[])` is a
  permissionless convenience so the operator can pay gas, but funds can only ever reach the
  rightful holder. The V1 whole-pool-to-relayer `withdrawSettlement` was **removed**.
- **The relayer cannot take user funds.** Its powers are limited to submitting matched fills
  (which require both parties' signatures) and crediting rebate counters.
- **Self-service exits without the relayer**: `mint(marketId, amount)` buys a complete set for
  cash; `burn(marketId, amount)` returns a complete set for cash before `endTime`. `burn`
  requires the holder to own a COMPLETE set (F-2026-17776/17772) — that is what stops a maker
  who already sold their UP from withdrawing backing under someone else's live position.
- **Owner powers are bounded**: `proposeEmergencyWithdraw` → 24h `EMERGENCY_TIMELOCK` →
  `executeEmergencyWithdraw`. `setPaused` blocks fills, redeem and burn.
- Backend still runs the order book, balances-for-order-acceptance, and submits fills — but it
  is no longer the custodian of settled positions.

### Market Creation
- Markets are created by `UpDownAutoCycler.performUpkeep`, gated to `forwarder`
  (F-2026-17726). Driven by a **cron keeper EOA**, not Chainlink Automation.
- **No seed liquidity and no factory.** The RAIN factory model is gone — `UpDownAutoCycler`'s
  constructor takes only `(owner, resolver, settlement)`. There is no `initialLiquidity`,
  no `liquidityPercentages`, no `isPublic`, no `poolResolver`, no `oracleEndTime`.
  Markets open empty; all liquidity comes from market makers.
- Boundaries are **clock-aligned** to the timeframe (`ts / duration * duration`).
- `preStartWindowSec` (max 300, **300 on both live deployments**) lets the next slot's market
  be created up to that many seconds early so makers can pre-position before the cross opens.
  The contract default is 0 and the constructor does not set it — `Deploy.s.sol` does.
- `registerMarket` on the resolver requires the caller be authorized, the settlement match
  `trustedSettlement`, and the pair have `priceFeeds` **or** `streamsFeedId` configured.
- Strike is captured by the cycler via the resolver (`captureStrike`), from Data Streams.

### Data Sources
- MongoDB is the source of truth for the ORDER BOOK, trades and balances.
- It is **no longer** the source of truth for positions — settled shares live on-chain in
  `userShares` and are readable via `sharesOf(marketId, user, option)`. MongoDB mirrors them.
- Price history proxied from speed-market API at `rain-speed-markets-dev-api.quecko.org`

### Contracts (Arbitrum One — chainId 42161)

**Both dev and prod run on Arbitrum One.** Dev is not a testnet: it differs only by using a
valueless dev-USDT and a mock Data Streams verifier. Nothing runs on Sepolia.

Live as of 2026-08-10 (these are the OUTGOING deployments being replaced in the key rotation):

| | Dev | Prod |
|---|---|---|
| UpDownSettlement | `0x9d1298C0124E0DF23c0DeD9121E530Fb7269c9CE` | `0x7978871Ebd82511d2f27da02507AD97b65f734e3` |
| ChainlinkResolver | `0xCe53c30c95b58fD01145159A889e9D2Ae613837d` | `0xE1D74Ea6d3024dc52e66B5707Eb6D00BABf08301` |
| UpDownAutoCycler | `0x4997a2a31a9c597a00ad6aecf2b4263562c65c12` | `0x9872bb8197b3052d0c9fe1a57e83b19f9319787c` |
| USDT | `0xCa4f77A38d8552Dd1D5E44e890173921B67725F4` (mock) | `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9` |
| Data Streams VerifierProxy | `0x9c8BA5dE25aB2fd183704c354Edf118fa3dA81b4` (mock) | `0x478Aa2aC9F6D65F84e09D9185d126c3a17c2a93C` (real) |

Shared Arbitrum One infrastructure:
```
Chainlink BTC/USD (strike-side, legacy):  0x6ce185860a4963106506C203335A2910413708e9
Chainlink ETH/USD (strike-side, legacy):  0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612
Chainlink Sequencer uptime:               0xFdB631F5EE196F0ed6FAa767959853A9F217697D
LINK token:                               0xf97f4df75117a78c1A5a0DBb814Af92458539FB4
```

**RAIN protocol addresses (TradingFacet, Market Factories, RAIN token, Paymaster,
RainEntryPoint) are no longer used by these contracts** and have been removed from this list.
The protocol owns its settlement; nothing calls into RAIN.

---

## Reference Repos (patterns only — NOT our product)

- `github.com/Quecko-Org/speed-market` — frontend reference (wallet connection, smart accounts, UI patterns)
- `github.com/saifr0/rain-speed-markets` — contract reference (IEntryPoint, subgraph scaffold, fork test patterns)
- `github.com/Quecko-Org/rain-speed-markets` — backend reference (contract service, smart account executor, bet model)
- `github.com/rain1-labs/rain-sdk` — ABIs, transaction builders, market/position queries

---

## How to Report Findings

For every issue found:

```
PHASE: 1-5
FILE: path/to/file
FUNCTION: functionName()
ISSUE: Description of what's wrong
SEVERITY: Critical / High / Medium / Low
FIX: What the fix should be
```

Severity levels:
- **Critical** — funds lost, double-spent, incorrect payouts, or system completely broken
- **High** — system gets into broken state requiring manual intervention
- **Medium** — edge case that will eventually hit in production
- **Low** — missing error handling, logging gaps, code quality

---

## Phase 1 — Contracts

**Status: COMPLETE, post-Hacken-remediation (153 tests passing, 11 fork tests skipped without an RPC)**
**Folder: this repository**
**Stack: Solidity 0.8.29 (viaIR, optimizer 200), Foundry, Chainlink Data Streams**

### What Was Built
- `UpDownSettlement` — the protocol's own settlement contract. Holds collateral, tracks
  per-user shares, verifies both order signatures per fill (EOA or ERC-1271), settles fills
  via `enterPosition` / `mintMatch` / `mergeMatch` (+ batch variants), and pays winners
  through permissionless `redeem`. Owner powers bounded by a 24h emergency timelock.
- `ChainlinkResolver` — captures strikes and resolves markets from **Chainlink Data Streams**
  (verified through the VerifierProxy, LINK fees paid from the resolver's own balance).
  Validates Arbitrum sequencer uptime with a 1hr grace period. **Resolution is access-gated**
  to authorized callers (F-2026-17760) — it is NOT permissionless.
- `UpDownAutoCycler` — keeper contract. Creates clock-aligned markets on 5/15/60 min
  boundaries and captures strikes. `performUpkeep` is gated to `forwarder` (F-2026-17726),
  driven by a cron keeper EOA. **Neither environment uses Chainlink Automation.** No seed
  liquidity — markets open empty. Prunes resolved markets; per-timeframe try-catch so one
  failure doesn't halt the others. BTC + ETH cycle concurrently.
- Mocks (`MockUSDT`, `MockAggregatorV3`, `MockVerifierProxy`) for the dev/mock-DON path.
- `ITradePool` / `IFactory` (RAIN SDK interfaces) and `ThinWallet` / `ThinWalletFactory`
  have been **removed** — nothing referenced them.

---

## Phase 2 — Backend Matching Engine

**Status: COMPLETE (32 tests passing)**
**Folder: `backend/`**
**Stack: Node.js, TypeScript, Express, MongoDB, ethers.js, WebSocket (ws)**

### What Was Built
- Off-chain matching engine with price-time priority order book and cancel-before-taker priority
- `DepositService` — monitors USDT Transfer events, deduplicates by txHash, credits MongoDB balances
- `SettlementService` — submits matched fills with exponential backoff retry (max 5), atomic
  status transitions. **Contract API changed:** `enterOption()` is gone. The entrypoints are
  `enterPosition` / `mintMatch` / `mergeMatch` and their `*Batch` variants on
  `UpDownSettlement`, each taking both parties' signed orders.
- `ClaimService` — **contract API changed and the model inverted.** There are no pools to
  claim and no relayer distribution: winners hold on-chain shares and call permissionless
  `redeem(marketId)` themselves. The operator's only role is optional gas-paying via
  `redeemFor(marketId, holders[])`, which can pay each holder only their own winnings.
  Dust-to-relayer no longer applies.
- `SignatureService` — EIP-712 order/cancel/withdraw verification
- `MarketSyncer` — polls UpDownAutoCycler, syncs markets + strike prices to MongoDB, broadcasts via WebSocket
- Balance model with atomic `$inc` operations (no read-modify-write race conditions)
- Rate limiting on order submission

### API Endpoints
```
GET    /config              — chain, fees, relayer, EIP-712 domain
GET    /markets             — list markets (?timeframe=300|900|3600, ?pair=BTC-USD|ETH-USD)
GET    /markets/:address    — market detail with best bid/ask, volume, time remaining
POST   /markets/:address/claim — trigger claim for resolved market
GET    /orderbook/:marketId — current order book snapshot
POST   /orders              — place signed order
DELETE /orders/:id          — cancel signed order
GET    /positions/:wallet   — user positions
GET    /trades/:wallet      — trade history (?limit, ?offset)
GET    /balance/:wallet     — balance (available, inOrders, total, withdrawNonce)
POST   /balance/withdraw    — withdraw USDT (signed)
GET    /prices/history/:symbol — proxied price history
GET    /stats               — protocol stats (volume, markets, traders)
WS     /stream              — channels: orderbook:, trades:, markets, orders:, balance:
```

---

## Phase 3 — API Layer

**Status: COMPLETE (merged into Phase 2 backend)**

Added: price history proxy, timeframe/pair filtering on markets, market detail enrichment (best bid/ask, time remaining, strike price), trades endpoint with pagination, stats endpoint, /config endpoint. All in `backend/`.

---

## Phase 4 — Frontend

**Status: COMPLETE**
**Folder: `frontend/`**
**Stack: Next.js 15, React, TypeScript, Tailwind, wagmi, Jotai, Alchemy Account Kit**

### What Was Built
- Home page with 5 min / 15 min / 1 hour sections, BTC/ETH pair tabs
- Market detail page with TradingChart (real price history), TradeForm (UP/DOWN, slider, EIP-712 signing), OrderBook, positions panel
- Wallet connection (MetaMask, WalletConnect, Coinbase) — mirrors speed-market pattern
- Deposit modal (relayer address + QR), withdraw modal (EIP-712 signed)
- Positions page, trade history page
- WebSocket integration for real-time updates with polling fallback
- Kraken design system from DESIGN.md (purple #7132f5, 12px radius, IBM Plex Sans)

### Known Issue
- WalletConnect connection flow doesn't complete reliably — needs debugging. Speed-market's flow works, this one partially works (gets to confirmation but doesn't finish).

---

## Phase 5 — Expand + Harden

**Status: COMPLETE**
**Folders: `sdk/`, `docs/`, updates across all folders**

### What Was Built
- Multi-pair support in UpDownAutoCycler (BTC + ETH cycling concurrently)
- TypeScript bot SDK (`sdk/typescript/`) — HTTP client, WebSocket client, EIP-712 helpers, types
- Python bot SDK (`sdk/python/`) — httpx + websockets client, example taker script
- Rate limiting middleware on backend
- ClaimService retry with exponential backoff
- Frontend: WebSocket stale detection, pair labels, error mapping
- Playwright E2E test scaffolding
- Documentation: `docs/api.md`, `docs/bots/README.md`, `docs/operations.md`, `docs/e2e-checklist.md`
- `contracts/docs/ONCHAIN_OPERATIONS.md` — deployment and configuration guide
