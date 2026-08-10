# Manual E2E checklist (UpDown)

Use a **test wallet** on the dev environment (Arbitrum One, valueless dev-USDT).

> Settlement is **non-custodial**: shares live on-chain in `UpDownSettlement.userShares` and
> winners redeem directly. Confirm the deposit/approval step below against the current backend
> — the contracts pull USDT from the user at fill time via allowance, not from a relayer float.

1. Connect wallet (MetaMask / WalletConnect / Coinbase).
2. Fund the wallet with dev-USDT and ensure it has an **allowance to the Settlement address**
   from `GET /config`; wait for balance in the app.
3. Open a **5 min** **BTC-USD** market; confirm **chart** shows BTC spot.
4. Place **$10 UP** (or min size); confirm **position** appears.
5. Confirm the on-chain share was recorded:
   `cast call $SETTLEMENT "sharesOf(uint256,address,uint8)(uint256)" <marketId> <wallet> 1`
6. Wait for expiry; the **cron keeper** drives `performUpkeep` and the **ChainlinkResolver**
   resolves from Data Streams; position shows win/loss.
   (Not Chainlink Automation — neither environment is registered with it.)
7. **Redeem** if you won — `redeem(marketId)` is permissionless and pays the holder directly.
   Confirm USDT lands in the user's own wallet, not a relayer wallet.

## Paths to verify

- [ ] UP wins (settlement > strike)
- [ ] DOWN wins (settlement < strike)
- [ ] **Tie** (settlement == strike) → **DOWN** wins (`ChainlinkResolver.sol:557` uses a
      strict `>` for UP; exact equality falls to DOWN, no tolerance band)
- [ ] **Self-service exit**: `mint` a complete set, then `burn` it back before `endTime`
- [ ] **Redeem without the operator**: winner calls `redeem` directly, relayer uninvolved
- [ ] **5m / 15m / 60m** timeframes
- [ ] **ETH-USD** market: chart shows **ETH**, correct pair label
- [ ] Multiple concurrent positions
- [ ] Zero balance → order rejected with clear message
- [ ] Max position / limits per backend rules
- [ ] Market expires during pending tx → sensible error

## Automated smoke

- Foundry: `forge test` (unit tests including tie → DOWN).
- Optional: run `sdk/typescript` example against a local API.
