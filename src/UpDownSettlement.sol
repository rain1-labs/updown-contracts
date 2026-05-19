// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title UpDownSettlement
/// @notice Single contract holding all UpDown markets as storage entries (no per-market proxy).
///         Orders are signed by makers off-chain via EIP-712; any caller may submit a signed
///         fill through `enterPosition`, which verifies the signature, tracks cumulative fills
///         against the signed amount (partial fills allowed), and pulls USDT from the maker.
///         Resolver sets outcomes after expiry; relayer withdraws settled pools.
contract UpDownSettlement is Ownable, EIP712 {
    using SafeERC20 for IERC20;

    // ── Errors ──────────────────────────────────────────────────────────
    error OnlyAutocycler();
    error OnlyRelayer();
    error OnlyResolver();
    error InvalidOption();
    error InvalidWinner();
    error MarketNotOpen();
    error NotResolved();
    error AlreadySettled();
    error AlreadyResolved();
    error ZeroAddress();
    error Paused();
    error InvalidMarketWindow();
    error OrderExpired();
    error InvalidSignature();
    error FillExceedsOrderAmount();
    // PR-16 (P1-15 + P1-16 + P1-17): cleanup batch
    error EmergencyProposalNotFound();
    error EmergencyTimelockActive();
    error EmergencyProposalAlreadyExists();
    error InvalidSide();
    error MarketMismatch();
    error OptionMismatch();
    // PR-5-bundle (P0-7 + P0-13 + P0-17): atomic settlement
    error FeeBreakdownInvalid();
    error TreasuryNotConfigured();
    /// @notice DMM rebate rebuild (2026-05-12 backend gate 4): `claimRebate`
    ///         pulls from the treasury EOA via `transferFrom`. If treasury
    ///         is unset, has insufficient USDT balance, or has insufficient
    ///         allowance to this contract, the claim reverts loudly so
    ///         DMMs and ops can tell a treasury problem apart from a
    ///         "you have no accumulated rebate" no-op. `have` reflects
    ///         the smaller of treasury balance and allowance — whichever
    ///         constraint is binding.
    error TreasuryUnderFunded(uint256 want, uint256 have);
    /// @notice PR-O Step 2 (FLAG-3 / R-6): a SELL filled against this market
    ///         must be backed by a prior `complementaryMint` of the same
    ///         maker. Concretely: `marketRetained[marketId] >= mintBackingDelta`
    ///         where `mintBackingDelta = (10000 - price) * fillAmount / 10000`.
    ///         The buyer pays only the cash side (`price * fillAmount / 10000`);
    ///         the residual `mintBackingDelta` is the share-creation
    ///         obligation that must already be funded in the pool.
    /// @param  marketId  the market the fill is targeting
    /// @param  needed    `mintBackingDelta` — the residual the buyer is NOT paying
    /// @param  available `marketRetained[marketId]` at the time of the check
    error NoBackingForSeller(uint256 marketId, uint256 needed, uint256 available);

    // ── Types ───────────────────────────────────────────────────────────
    /// @dev Packed for cheaper `createMarket` (fewer cold storage slots on first write).
    ///
    /// PR-O Step 2 rename: `totalUp` / `totalDown` → `cashUpFlow` / `cashDownFlow`.
    /// Under PR-O, these no longer track "outstanding shares" — they track the
    /// cumulative *cash-side* notional that flowed through fills on each option.
    /// Outstanding shares live off-chain in `Position.sharesBought - sharesSold`
    /// per the relayer's Mongo ledger; the on-chain counters are analytics
    /// only. Renaming removes the audit ambiguity that "totalUp" might be
    /// interpreted as a share or backing total.
    struct Market {
        bytes32 pairId;
        uint128 cashUpFlow;
        uint128 cashDownFlow;
        uint64 startTime;
        uint64 endTime;
        uint32 duration; // 300, 900, 3600
        uint8 winner; // 0 = unresolved, 1 = UP, 2 = DOWN
        bool resolved;
        bool settled;
        int128 strikePrice;
        int128 settlementPrice;
    }

    /// @dev EIP-712 Order struct mirroring the off-chain matching engine's typed-data shape.
    ///      `orderType` is named to avoid Solidity's `type` keyword collision; the EIP-712
    ///      typehash string below uses "type" to match the backend's signed payloads verbatim.
    ///      Side is 0=BUY, 1=SELL. Only BUY orders enter positions — sellers are settled
    ///      off-chain via the backend's Mongo ledger.
    struct Order {
        address maker;
        uint256 market;
        uint256 option;
        uint8 side;
        uint8 orderType;
        uint256 price;
        uint256 amount;
        uint256 nonce;
        uint256 expiry;
    }

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,uint256 market,uint256 option,uint8 side,uint8 type,uint256 price,uint256 amount,uint256 nonce,uint256 expiry)"
    );

    // ── Events ──────────────────────────────────────────────────────────
    event MarketCreated(
        uint256 indexed marketId,
        bytes32 indexed pairId,
        uint256 duration,
        int256 strikePrice,
        uint256 startTime,
        uint256 endTime
    );
    event PositionEntered(uint256 indexed marketId, uint8 option, uint256 amount, address indexed maker);
    event MarketResolved(uint256 indexed marketId, uint8 winner, int256 settlementPrice);
    event SettlementWithdrawn(uint256 indexed marketId, uint256 netToRelayer, uint256 fees);
    /// @notice 2026-05-12 backend gate 4 (DMM rebate rebuild): event now
    ///         emits for ANY maker that earns a rebate. The pre-rebuild
    ///         `DMMAdded`/`DMMRemoved`/`NotDMM` whitelist gate has been
    ///         removed — every maker accrues a rebate proportional to
    ///         their maker fee. The parameter is named `maker` (not
    ///         `dmm`) to reflect the broader semantic.
    event RebateAccumulated(address indexed maker, uint256 amount);
    event RebateClaimed(address indexed claimant, uint256 amount);
    event PausedSet(bool paused);
    event FeesUpdated(uint256 platformFeeBps, uint256 makerFeeBps);
    event DmmRebateBpsUpdated(uint256 bps);
    // PR-16 (P1-17): two-step emergency withdraw with 24h timelock.
    event EmergencyWithdrawProposed(address indexed token, address indexed to, uint256 amount, uint256 unlocksAt);
    event EmergencyWithdrawExecuted(address indexed token, address indexed to, uint256 amount);
    event EmergencyWithdrawCancelled(bytes32 indexed proposalId);
    /// @notice PR-5-bundle (P0-7 + P0-13 + P0-17): emitted on every atomic
    ///         fill. Carries every transfer destination so off-chain
    ///         indexers see the entire settlement flow without joining
    ///         to ERC20 Transfer logs.
    event FillSettled(
        bytes32 indexed orderHash,
        address indexed buyer,
        address indexed seller,
        uint256 fillAmount,
        uint256 sellerReceives,
        uint256 platformFee,
        uint256 makerFee,
        address makerFeeRecipient
    );
    event TreasurySet(address indexed previous, address indexed current);
    /// @notice PR-O Step 2: emitted on `complementaryMint`. `marketId` and
    ///         `minter` are indexed for the SUBMITTED-stuck recovery path in
    ///         SettlementService — the off-chain poller filters
    ///         `(marketId, minter)` and checks the amount field to
    ///         disambiguate which intent the log corresponds to.
    event ComplementaryMinted(uint256 indexed marketId, address indexed minter, uint256 amount);
    /// @notice PR-O Step 2: emitted on `complementaryBurn`.
    event ComplementaryBurned(uint256 indexed marketId, address indexed holder, uint256 amount);

    // ── Immutables / roles ─────────────────────────────────────────────
    IERC20 public immutable usdt;

    address public resolver;
    address public autocycler;
    address public relayer;
    /// @notice PR-5-bundle (P0-7): destination for `platformFee` paid out
    ///         atomically inside `enterPosition`. Configurable by owner.
    ///         Pre-fix fees accumulated in the contract via
    ///         `totalAccumulatedFees`; under atomic settlement they leave
    ///         the contract immediately so off-chain dashboards can see
    ///         them via `usdt.balanceOf(treasury)` rather than a Mongo
    ///         row that has no API surface.
    address public treasury;

    uint256 public nextMarketId;
    mapping(uint256 => Market) public markets;

    uint256 public platformFeeBps;
    uint256 public makerFeeBps;

    /// @notice 2026-05-12 backend gate 4: `isDMM` whitelist + `dmmCount` +
    ///         `totalAccumulatedFees` removed. Rebates are now treasury-
    ///         funded (pulled at claim time via `usdt.transferFrom`); the
    ///         per-maker accumulator below is the only rebate-side state.
    ///         Bps still configurable by owner.
    uint256 public dmmRebateBps;
    mapping(address => uint256) public dmmRebateAccumulated;

    bool public paused;

    /// @notice Cumulative filled amount per signed order hash. Caps at `order.amount` to
    ///         prevent over-fill; replays that would push total past the signed max revert.
    mapping(bytes32 => uint256) public orderFills;

    /// @notice Per-market retained collateral (PR-Gap-bundle, supersedes pre-bundle
    ///         parimutuel `(totalPool × (1 − feeBps/10000))` math in `withdrawSettlement`).
    ///         Under formula (c) atomic settlement the contract retains exactly
    ///         `fillAmount − sellerReceives − platformFee − makerFee` per fill; that's
    ///         the only money the contract holds for this market and it's the only
    ///         money `withdrawSettlement` should hand to the relayer at resolution.
    ///
    ///         Pre-fix, `withdrawSettlement` recomputed `totalPool × (1 − feeBps/10000)`
    ///         from `m.cashUpFlow + m.cashDownFlow` — a number that has no relationship to the
    ///         actual residual under price-aware atomic settlement. The relayer was
    ///         either short-paid (drained its own USDT to cover winners) or over-paid
    ///         (drained backing of unrelated open markets).
    mapping(uint256 => uint256) public marketRetained;

    // ── PR-16 (P1-17) emergency-withdraw timelock ─────────────────────
    /// @notice 24h delay between proposing and executing an emergency withdraw.
    uint256 public constant EMERGENCY_TIMELOCK = 24 hours;

    struct EmergencyProposal {
        address token;
        address to;
        uint256 amount;
        uint256 unlocksAt;
    }

    /// @notice Active proposals keyed by `keccak256(abi.encode(token, to, amount, nonce))`.
    ///         Owner may have multiple in flight (different tokens / amounts).
    mapping(bytes32 => EmergencyProposal) public emergencyProposals;
    /// @notice Per-owner monotonic nonce so two identical proposals don't collide.
    uint256 public emergencyProposalNonce;

    // ── Modifiers ───────────────────────────────────────────────────────
    modifier onlyAutocycler() {
        if (msg.sender != autocycler) revert OnlyAutocycler();
        _;
    }

    modifier onlyRelayer() {
        if (msg.sender != relayer) revert OnlyRelayer();
        _;
    }

    modifier onlyResolver() {
        if (msg.sender != resolver) revert OnlyResolver();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────
    constructor(IERC20 _usdt, address initialOwner, uint256 _platformFeeBps, uint256 _makerFeeBps)
        Ownable(initialOwner)
        EIP712("UpDown Exchange", "1")
    {
        if (address(_usdt) == address(0)) revert ZeroAddress();
        usdt = _usdt;
        platformFeeBps = _platformFeeBps;
        makerFeeBps = _makerFeeBps;
    }

    // ── Core ────────────────────────────────────────────────────────────

    function createMarket(bytes32 pairId, uint256 duration, int256 strikePrice)
        external
        onlyAutocycler
        whenNotPaused
        returns (uint256 marketId)
    {
        uint64 start = uint64(block.timestamp);
        uint64 end = start + uint64(duration);
        return _createMarket(pairId, duration, strikePrice, start, end);
    }

    function createMarket(bytes32 pairId, uint256 duration, int256 strikePrice, uint64 startTime, uint64 endTime)
        external
        onlyAutocycler
        whenNotPaused
        returns (uint256 marketId)
    {
        return _createMarket(pairId, duration, strikePrice, startTime, endTime);
    }

    function _createMarket(bytes32 pairId, uint256 duration, int256 strikePrice, uint64 startTime, uint64 endTime)
        internal
        returns (uint256 marketId)
    {
        if (uint256(endTime) < uint256(startTime)) revert InvalidMarketWindow();
        if (uint256(endTime) - uint256(startTime) != duration) revert InvalidMarketWindow();

        marketId = ++nextMarketId;
        markets[marketId] = Market({
            pairId: pairId,
            cashUpFlow: 0,
            cashDownFlow: 0,
            startTime: startTime,
            endTime: endTime,
            duration: uint32(duration),
            winner: 0,
            resolved: false,
            settled: false,
            strikePrice: int128(strikePrice),
            settlementPrice: 0
        });
        emit MarketCreated(marketId, pairId, duration, strikePrice, startTime, endTime);
    }

    /// @notice EIP-712 struct hash for a given Order. Exposed for off-chain tooling.
    function hashOrder(Order memory order) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.maker,
                order.market,
                order.option,
                order.side,
                order.orderType,
                order.price,
                order.amount,
                order.nonce,
                order.expiry
            )
        );
    }

    /// @notice EIP-712 digest including domain separator. Exposed for off-chain tooling.
    function orderDigest(Order memory order) public view returns (bytes32) {
        return _hashTypedDataV4(hashOrder(order));
    }

    /// @notice Submit a signed BUY order as a fill against a market. Anyone may call.
    ///         Signature must recover to `order.maker`. Cumulative fills per signed order are
    ///         tracked on-chain and cannot exceed `order.amount`.
    /// @param order      The EIP-712 Order the maker signed off-chain.
    /// @param signature  65-byte secp256k1 signature by `order.maker`.
    /// @param marketId   Must equal `order.market`. Redundant in args but matches the
    ///                   backend's existing calldata shape for simpler migration.
    /// @param option     Must equal `order.option`. Same reason as `marketId`.
    /// @param fillAmount Amount to enter for this call. May be less than `order.amount`
    ///                   (partial fill); subsequent calls with same signature may top up.
    /// @notice PR-5-bundle (P0-7 + P0-13 + P0-17) inputs. Backed by a
    ///         struct rather than positional args so future fields don't
    ///         break ABI consumers and so calldata is laid out
    ///         predictably.
    struct FillInputs {
        Order order;          // signed by maker (= seller for SELL maker, buyer for BUY maker)
        bytes signature;      // maker's EIP-712 sig over Order
        uint256 marketId;     // explicit redundant copy of order.market for arg/sig pinning
        uint8 option;         // explicit redundant copy of order.option
        uint256 fillAmount;   // amount being filled now (not the signed total)
        address taker;        // counterparty wallet (the OTHER side of the maker)
        uint256 sellerReceives;    // pre-computed by relayer using same fee math as the engine
        uint256 platformFee;       // pre-computed; sent to `treasury`
        uint256 makerFee;          // pre-computed; sent to `makerFeeRecipient`
        address makerFeeRecipient; // typically = order.maker (the resting side)
    }

    /// @notice PR-O Step 2: atomic Polymarket-parity fill settlement.
    ///
    ///         Buyer pays ONLY the cash side of the fill
    ///         (`price * fillAmount / 10000`) plus fees ON TOP — the
    ///         residual `(10000 - price) * fillAmount / 10000` backing for
    ///         the buyer's $1-redemption-at-resolution must already be in
    ///         `marketRetained[marketId]` from a prior `complementaryMint`
    ///         by the seller. The `NoBackingForSeller` guard checks this
    ///         invariant before any token movement; failure means the
    ///         contract would otherwise issue an unbacked $1 share, which
    ///         would drain the pool at resolution.
    ///
    ///         Fee model = Option B (Phase 1 Section 3 conservation proof):
    ///         buyer pulls `cashPart + platformFee + makerFee`; seller
    ///         receives `sellerReceives` (typically `= cashPart`); treasury
    ///         and `makerFeeRecipient` receive their fees atomically. The
    ///         `sellerReceives <= cashPart` defense-in-depth check is via
    ///         `FeeBreakdownInvalid` — any excess (`cashPart - sellerReceives`)
    ///         flows into `marketRetained` as additional backing (typically
    ///         zero under Option B; non-zero only if the relayer ever
    ///         routes maker-side haircuts through the pool).
    ///
    ///         Pre-bundle this pulled `fillAmount` and the contract held
    ///         the residual. Under PR-O the seller's mint deposit is the
    ///         residual backing — fills are balance-neutral for the pool
    ///         when `sellerReceives = cashPart`. This is the audit-critical
    ///         conservation invariant: `usdt.balanceOf(this) ==
    ///         sum(marketRetained) over un-settled markets`, holds at the
    ///         boundary of every external call.
    function enterPosition(FillInputs calldata f) external whenNotPaused onlyRelayer {
        // Arg/order consistency (prevents calldata from asking for one market while sig
        // was for another, even though sig itself ties those fields).
        if (f.marketId != f.order.market) revert MarketMismatch();
        if (uint256(f.option) != f.order.option) revert OptionMismatch();

        if (block.timestamp > f.order.expiry) revert OrderExpired();
        if (f.order.option != 1 && f.order.option != 2) revert InvalidOption();
        if (f.order.side != 0 && f.order.side != 1) revert InvalidSide();
        if (f.fillAmount == 0) revert FillExceedsOrderAmount();

        // PR-O Step 2: Option B fee bound. The seller can never receive
        // more than the cash side — fees flow on top, NOT out of cashPart.
        // sellerReceives + makerFee + platformFee would have been the
        // pre-PR-O bound against `fillAmount`; under Option B the bound is
        // `sellerReceives <= cashPart`. Defense-in-depth: a malformed
        // relayer call that tries to overpay the seller from pool funds
        // is rejected before any transfer.
        uint256 cashPart = (f.order.price * f.fillAmount) / 10000;
        if (f.sellerReceives > cashPart) revert FeeBreakdownInvalid();
        if (f.platformFee > 0 && treasury == address(0)) revert TreasuryNotConfigured();

        // Verify maker's EIP-712 signature over the Order. SignatureChecker
        // handles BOTH plain EOAs (via ECDSA.recover internally) AND contract
        // accounts that implement ERC-1271. Path-1 today has order.maker == EOA;
        // ERC-1271 path retained so a future SA-as-maker upgrade is a config
        // change, not a contract one.
        bytes32 structHash = hashOrder(f.order);
        bytes32 digest = _hashTypedDataV4(structHash);
        if (!SignatureChecker.isValidSignatureNow(f.order.maker, digest, f.signature)) {
            revert InvalidSignature();
        }

        // Partial-fill bookkeeping: cumulative filled must not exceed signed amount.
        uint256 already = orderFills[structHash];
        uint256 newFilled = already + f.fillAmount;
        if (newFilled > f.order.amount) revert FillExceedsOrderAmount();
        orderFills[structHash] = newFilled;

        // Market must be active.
        Market storage m = markets[f.marketId];
        if (m.startTime == 0) revert MarketNotOpen();
        if (block.timestamp >= uint256(m.endTime)) revert MarketNotOpen();

        // PR-O Step 2 (FLAG-3 / R-6): the seller's share-creation obligation
        // — the `(10000 - price) * fillAmount / 10000` residual the buyer
        // is NOT paying — MUST already be in `marketRetained` from a prior
        // complementaryMint. This is a pure guard: no mutation here. Per
        // the Phase 1 conservation proof, fills are balance-neutral for
        // the pool; `marketRetained` only changes on mint / burn /
        // withdrawSettlement. The check catches the "SELL without backing"
        // failure mode where the pool would otherwise be implicitly debited
        // at resolution.
        uint256 mintBackingDelta = f.fillAmount - cashPart;
        if (marketRetained[f.marketId] < mintBackingDelta) {
            revert NoBackingForSeller(f.marketId, mintBackingDelta, marketRetained[f.marketId]);
        }

        // Identify buyer / seller. `taker` is the counterparty to the
        // maker; the BUYER is whichever side has order.side == BUY.
        address buyer;
        address seller;
        if (f.order.side == 0) {
            buyer = f.order.maker;
            seller = f.taker;
        } else {
            buyer = f.taker;
            seller = f.order.maker;
        }

        // PR-O Step 2 (Option B): pull cashPart + fees from buyer. Single
        // transfer-from keeps the gas down vs. three separate calls; the
        // contract then distributes downstream. Buyer must have approved
        // this contract for at least cashPart + platformFee + makerFee.
        usdt.safeTransferFrom(buyer, address(this), cashPart + f.platformFee + f.makerFee);

        // Atomic outflows. Seller may be address(0) for genuine first-issuance
        // legs that have no counterparty (e.g. DMM bootstrap); seller == 0
        // skips the seller payout but still pays fees, and the excess
        // (= cashPart) settles into marketRetained below.
        if (seller != address(0) && f.sellerReceives > 0) {
            usdt.safeTransfer(seller, f.sellerReceives);
        }
        if (f.platformFee > 0) {
            usdt.safeTransfer(treasury, f.platformFee);
        }
        if (f.makerFee > 0 && f.makerFeeRecipient != address(0)) {
            usdt.safeTransfer(f.makerFeeRecipient, f.makerFee);
        }

        // PR-O Step 2 rename: cash-flow counters. NOT outstanding shares —
        // outstanding lives off-chain in Position.netShares. Bookkeeping /
        // analytics for indexers; not load-bearing for settlement.
        if (f.order.option == 1) {
            m.cashUpFlow += uint128(f.fillAmount);
        } else {
            m.cashDownFlow += uint128(f.fillAmount);
        }

        // PR-O Step 2: marketRetained delta from this fill = cashPart - sellerReceives.
        // Under Option B the relayer sets sellerReceives = cashPart, so the
        // delta is 0 (fill is balance-neutral for the pool). The mint
        // deposit (already in marketRetained) provides the buyer's $1
        // backing. The unchecked subtraction is safe by the
        // FeeBreakdownInvalid check above which enforces
        // `sellerReceives <= cashPart`.
        unchecked {
            marketRetained[f.marketId] += cashPart - f.sellerReceives;
        }

        emit PositionEntered(f.marketId, uint8(f.order.option), f.fillAmount, f.order.maker);
        emit FillSettled(
            structHash,
            buyer,
            seller,
            f.fillAmount,
            f.sellerReceives,
            f.platformFee,
            f.makerFee,
            f.makerFeeRecipient
        );
    }

    // ── Complementary mint / burn (PR-O Step 2) ─────────────────────────
    //
    // Polymarket-parity share-creation primitive: deposit `amount` USDT and
    // receive (off-chain) `amount` UP shares + `amount` DOWN shares for the
    // market. Exactly one option pays $1 at resolution, so the deposit
    // covers exactly one redemption — conservation by construction.
    //
    // The contract holds the deposit in `marketRetained[marketId]` until
    // `withdrawSettlement`. The off-chain side credits both
    // `Position(maker, market, UP).sharesBought` and `Position(maker,
    // market, DOWN).sharesBought` by `amount`; that credit is gated on the
    // on-chain `ComplementaryMinted` event being indexed by the relayer.

    /// @notice PR-O Step 2: deposit `amount` USDT for `minter` and increment
    ///         the market's retained backing by the same amount. Off-chain
    ///         the relayer credits Position(minter, market, UP).sharesBought
    ///         AND Position(minter, market, DOWN).sharesBought by `amount`.
    ///         Market must be ACTIVE (same `m.endTime` gate as enterPosition).
    function complementaryMint(uint256 marketId, uint256 amount, address minter)
        external
        whenNotPaused
        onlyRelayer
    {
        if (amount == 0) revert FillExceedsOrderAmount();
        if (minter == address(0)) revert ZeroAddress();
        Market storage m = markets[marketId];
        if (m.startTime == 0) revert MarketNotOpen();
        if (block.timestamp >= uint256(m.endTime)) revert MarketNotOpen();

        usdt.safeTransferFrom(minter, address(this), amount);
        marketRetained[marketId] += amount;

        emit ComplementaryMinted(marketId, minter, amount);
    }

    /// @dev TRUST-ASSUMPTION-V1: relayer can complementaryBurn any maker's
    ///      locked collateral. Same trust level as accumulateRebate. v2 path
    ///      = maker-signed permit; deferred. The off-chain MintIntent layer
    ///      mediates burn requests so this entrypoint never fires
    ///      unsolicited in production. Documented in audit handoff.
    /// @notice PR-O Step 2: inverse of complementaryMint. Pulls `amount`
    ///         from `marketRetained[marketId]` and transfers it to `holder`.
    ///         Off-chain the relayer must have already verified that
    ///         Position(holder, market, UP).available >= amount AND
    ///         Position(holder, market, DOWN).available >= amount (off-chain
    ///         proof; relayer-trust v1).
    function complementaryBurn(uint256 marketId, uint256 amount, address holder)
        external
        whenNotPaused
        onlyRelayer
    {
        if (amount == 0) revert FillExceedsOrderAmount();
        if (holder == address(0)) revert ZeroAddress();
        Market storage m = markets[marketId];
        if (m.startTime == 0) revert MarketNotOpen();
        if (m.resolved) revert AlreadyResolved();

        // Conservation guard: cannot burn more backing than is retained.
        // Reverts with the same NoBackingForSeller error used by enterPosition
        // so off-chain consumers can lump the two failure modes.
        if (marketRetained[marketId] < amount) {
            revert NoBackingForSeller(marketId, amount, marketRetained[marketId]);
        }
        marketRetained[marketId] -= amount;
        usdt.safeTransfer(holder, amount);

        emit ComplementaryBurned(marketId, holder, amount);
    }

    function resolve(uint256 marketId, int256 settlementPrice, uint8 winner) external onlyResolver whenNotPaused {
        Market storage m = markets[marketId];
        if (m.startTime == 0) revert MarketNotOpen();
        if (m.resolved) revert AlreadyResolved();
        if (block.timestamp < uint256(m.endTime)) revert MarketNotOpen();
        if (winner != 1 && winner != 2) revert InvalidWinner();

        m.settlementPrice = int128(settlementPrice);
        m.winner = winner;
        m.resolved = true;
        emit MarketResolved(marketId, winner, int256(settlementPrice));
    }

    /// @notice Hand the market's actual retained collateral to the relayer
    ///         so it can pay winners off-chain via `Position.netShares × $1`.
    ///         PR-Gap-bundle: pre-fix this used parimutuel `totalPool × (1 −
    ///         feeBps/10000)` math, which has no relationship to what the
    ///         contract actually holds under formula (c). The relayer would
    ///         end up either short-paid (eating the gap from its own USDT
    ///         balance) or over-paid (draining backing of unrelated open
    ///         markets). Now we transfer exactly `marketRetained[marketId]`,
    ///         which was accumulated atomically inside `enterPosition`.
    ///
    ///         `totalAccumulatedFees` is intentionally NOT incremented here.
    ///         Pre-fix it was incremented by a phantom `fees` figure (fees
    ///         had already left the contract atomically to `treasury` and
    ///         `makerFeeRecipient`). Subsequent calls to `accumulateRebate`
    ///         and `withdrawFees` would then "spend" that phantom — actually
    ///         draining real per-market backing for open markets. Dropping
    ///         the increment fully closes that drain. As a side-effect,
    ///         `accumulateRebate` and `withdrawFees` now revert with
    ///         `InsufficientAccumulatedFees` until a follow-up funds rebates
    ///         from `treasury` rather than the contract.
    function withdrawSettlement(uint256 marketId) external onlyRelayer whenNotPaused {
        Market storage m = markets[marketId];
        if (!m.resolved) revert NotResolved();
        if (m.settled) revert AlreadySettled();

        uint256 retained = marketRetained[marketId];
        m.settled = true;
        delete marketRetained[marketId];

        if (retained > 0) {
            usdt.safeTransfer(relayer, retained);
        }
        emit SettlementWithdrawn(marketId, retained, 0);
    }

    // ── Rebates ─────────────────────────────────────────────────────────
    //
    // 2026-05-12 backend gate 4 (post-Gap-#2 rebuild):
    //
    // Pre-Gap-#2: rebates were funded by the contract's `totalAccumulatedFees`
    // counter — `accumulateRebate` decremented it, `claimRebate` paid out
    // from the contract's USDT balance. Gap #2 fix routed `platformFee`
    // atomically to `treasury` per fill (so off-chain dashboards could see
    // fees via `usdt.balanceOf(treasury)` instead of a Mongo counter), and
    // the fee counter was intentionally left un-incremented. That made the
    // rebate path structurally unreachable.
    //
    // Rebuild design (Option D, approved 2026-05-12):
    //
    // - `accumulateRebate(maker, amount)` is now a pure accumulator-increment.
    //   No balance constraint on the contract; no `isDMM` whitelist gate
    //   (consistent with the broader "anyone market-makes, anyone earns
    //   rebates" principle from the 2026-05-04 Decisions log).
    // - `claimRebate()` pulls from the `treasury` EOA via
    //   `usdt.safeTransferFrom(treasury, msg.sender, amt)`. Treasury holds
    //   a standing `usdt.approve(address(this), MAX_UINT256)` as an
    //   operational precondition (set once at deploy, re-issued if treasury
    //   rotates).
    //
    // Value flow is one-direction: fills → treasury (via atomic `enterPosition`)
    // → DMM claims. The contract holds no rebate pool of its own.
    //
    // Trust assumption (documented for the auditor): treasury's standing
    // approval means if this settlement contract is compromised, treasury
    // can be drained via crafted `claimRebate` calls (the attacker accrues
    // arbitrary amounts via a compromised `accumulateRebate` path, then
    // claims). For v1 this is the right tradeoff — settlement and treasury
    // are co-deployed by the same team under a consistent trust assumption.
    // Post-v1: consider rolling-cap allowance (treasury periodically
    // re-approves a weekly rebate budget) if the threat model shifts.

    /// @notice Credit `maker`'s rebate accumulator. Any maker, not just
    ///         whitelisted DMMs (whitelist removed 2026-05-12). Called by
    ///         the relayer after off-chain fills via the matching engine's
    ///         post-fill hook; the rebate amount is computed off-chain as
    ///         `(makerFee * dmmRebateBps) / 10_000`. No fund movement here
    ///         — just a counter increment. Pull-from-treasury happens at
    ///         `claimRebate` time.
    function accumulateRebate(address maker, uint256 amount) external onlyRelayer whenNotPaused {
        dmmRebateAccumulated[maker] += amount;
        emit RebateAccumulated(maker, amount);
    }

    /// @notice Claim accumulated rebate. Pulls `amt` from the treasury EOA
    ///         via `usdt.transferFrom`. Treasury must hold sufficient USDT
    ///         balance AND have approved this contract to spend it. The
    ///         `TreasuryUnderFunded(want, have)` revert distinguishes a
    ///         treasury problem from a "no accumulated rebate" no-op
    ///         (which is the `amt == 0` early-return below).
    function claimRebate() external {
        uint256 amt = dmmRebateAccumulated[msg.sender];
        if (amt == 0) return;
        if (treasury == address(0)) revert TreasuryUnderFunded(amt, 0);

        // Binding constraint is `min(balance, allowance)` — whichever is
        // smaller is what `transferFrom` would actually succeed with.
        // Surfacing it in the error gives ops a clear "fund treasury" vs
        // "re-approve allowance" signal.
        uint256 balance = usdt.balanceOf(treasury);
        uint256 allowance = usdt.allowance(treasury, address(this));
        uint256 have = balance < allowance ? balance : allowance;
        if (have < amt) revert TreasuryUnderFunded(amt, have);

        dmmRebateAccumulated[msg.sender] = 0;
        usdt.safeTransferFrom(treasury, msg.sender, amt);
        emit RebateClaimed(msg.sender, amt);
    }

    // ── Admin ───────────────────────────────────────────────────────────

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit PausedSet(p);
    }

    function setResolver(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        resolver = a;
    }

    function setAutocycler(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        autocycler = a;
    }

    function setRelayer(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        relayer = a;
    }

    /// @notice PR-5-bundle (P0-7): set the treasury EOA. `enterPosition`
    ///         now sends `platformFee` here directly per fill instead of
    ///         accumulating in `totalAccumulatedFees`.
    function setTreasury(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        address prev = treasury;
        treasury = a;
        emit TreasurySet(prev, a);
    }

    function setFees(uint256 platformBps, uint256 makerBps) external onlyOwner {
        platformFeeBps = platformBps;
        makerFeeBps = makerBps;
        emit FeesUpdated(platformBps, makerBps);
    }

    function setDmmRebateBps(uint256 bps) external onlyOwner {
        dmmRebateBps = bps;
        emit DmmRebateBpsUpdated(bps);
    }

    // 2026-05-12 backend gate 4: `withdrawFees(uint256)` and
    // `getAccumulatedFees()` removed. They read/decremented
    // `totalAccumulatedFees`, which was structurally dead post-Gap-#2
    // (fees flow atomically to `treasury` per fill via `enterPosition` —
    // the contract no longer holds fee accumulation). The functions
    // confused the storage model and would have reverted on any call;
    // their `FeesWithdrawn` event and `InsufficientAccumulatedFees`
    // error are also gone. Treasury withdraws happen off-chain by the
    // treasury EOA's owner — settlement is not in that path.

    /// @notice Step 1 of emergency withdraw (PR-16 / P1-17). Records intent
    ///         and a 24-hour unlock timestamp; nothing transfers yet. Audit
    ///         signal: any unexpected proposal is visible on-chain immediately
    ///         and operators have a full day to react before funds can move.
    function proposeEmergencyWithdraw(address token, address to, uint256 amount)
        external
        onlyOwner
        returns (bytes32 proposalId)
    {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        unchecked {
            ++emergencyProposalNonce;
        }
        proposalId = keccak256(abi.encode(token, to, amount, emergencyProposalNonce));
        if (emergencyProposals[proposalId].unlocksAt != 0) revert EmergencyProposalAlreadyExists();
        uint256 unlocksAt = block.timestamp + EMERGENCY_TIMELOCK;
        emergencyProposals[proposalId] = EmergencyProposal({
            token: token,
            to: to,
            amount: amount,
            unlocksAt: unlocksAt
        });
        emit EmergencyWithdrawProposed(token, to, amount, unlocksAt);
    }

    /// @notice Step 2 of emergency withdraw — executes the transfer iff at
    ///         least 24 hours have passed since the proposal landed.
    function executeEmergencyWithdraw(bytes32 proposalId) external onlyOwner {
        EmergencyProposal memory p = emergencyProposals[proposalId];
        if (p.unlocksAt == 0) revert EmergencyProposalNotFound();
        if (block.timestamp < p.unlocksAt) revert EmergencyTimelockActive();
        delete emergencyProposals[proposalId];
        IERC20(p.token).safeTransfer(p.to, p.amount);
        emit EmergencyWithdrawExecuted(p.token, p.to, p.amount);
    }

    /// @notice Cancel a pending emergency-withdraw proposal. Owner-only —
    ///         the timelock is for human operator review, not a separate
    ///         signer set.
    function cancelEmergencyWithdraw(bytes32 proposalId) external onlyOwner {
        if (emergencyProposals[proposalId].unlocksAt == 0) revert EmergencyProposalNotFound();
        delete emergencyProposals[proposalId];
        emit EmergencyWithdrawCancelled(proposalId);
    }

    // ── Views ───────────────────────────────────────────────────────────

    function getMarket(uint256 marketId) external view returns (Market memory) {
        return markets[marketId];
    }

    /// @notice Remaining signed amount available for further fills on this order.
    function orderRemaining(Order calldata order) external view returns (uint256) {
        bytes32 h = hashOrder(order);
        uint256 filled = orderFills[h];
        if (filled >= order.amount) return 0;
        unchecked {
            return order.amount - filled;
        }
    }

    /// @notice Public getter matching the EIP-712 domain separator spec. Useful for
    ///         off-chain signing libraries that want to verify the domain they'll hash.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
