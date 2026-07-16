// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title UpDownSettlement
/// @notice Single contract holding all UpDown markets as storage entries (no per-market proxy).
///
///         REMEDIATION V2 (Hacken full-recommendation pass, 2026-06-15): the trust model is moved
///         from custodial (Mongo = source of truth, relayer = custodian) to **non-custodial on
///         principal** (Polymarket parity). Positions are on-chain per-user share balances
///         (`userShares`); both the maker and the taker of every fill sign EIP-712 orders verified
///         on-chain; fees are capped by the taker's signed `maxFee` and pulled from the taker;
///         winners redeem trustlessly via `redeem` / `redeemFor`. The operator stays centralized only
///         for matching liveness and resolution correctness — it can no longer steal funds, force
///         positions, inflate fees, or withhold winnings. See `REMEDIATION_V2.md`.
contract UpDownSettlement is Ownable2Step, EIP712, ReentrancyGuard {
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
    error EmergencyProposalNotFound();
    error EmergencyTimelockActive();
    error EmergencyProposalAlreadyExists();
    error InvalidSide();
    error MarketMismatch();
    error OptionMismatch();
    error FeeBreakdownInvalid();
    error TreasuryNotConfigured();
    error TreasuryUnderFunded(uint256 want, uint256 have);
    /// @notice F-2026-17756 / 17757 / 17731: the two signed orders of a fill must be opposite sides
    ///         (one BUY, one SELL) at crossing prices for the same (market, option).
    error OrdersNotCrossed();
    error NotBuySellPair();
    /// @notice F-2026-17731: relayer-supplied fees exceed the cap the taker signed in `maxFee`.
    error FeeExceedsTakerCap(uint256 supplied, uint256 cap);
    /// @notice F-2026-17772 / 17777 / 17771 / 17776: the seller / holder does not hold enough of the
    ///         relevant on-chain share balance for the requested transfer / burn / redemption.
    /// @param  marketId  the market the operation targets
    /// @param  option    the share option that is short (0 when both legs of a complete set matter)
    /// @param  needed    shares required by the operation
    /// @param  held      `userShares[marketId][account][option]` at the time of the check
    error InsufficientShares(uint256 marketId, uint8 option, uint256 needed, uint256 held);
    /// @notice F-2026-17772: `MintAuth` signature did not recover to `account`, or its fields /
    ///         action / nonce / expiry are invalid.
    error InvalidMintAuth();
    error MintAuthNonceUsed(address account, uint256 nonce);
    /// @notice F-2026-17779: a `claimRebate` would exceed the rolling per-window rebate budget.
    error RebateBudgetExceeded(uint256 want, uint256 remaining);
    error NothingToRedeem();
    /// @notice Complementary matching: `mintMatch` requires two BUY orders; `mergeMatch` two SELL
    ///         orders. Raised when a leg has the wrong side for the requested complementary match.
    error NotBothBuys();
    error NotBothSells();
    /// @notice Complementary matching: the two legs must be on opposite options — exactly one UP
    ///         (1) and one DOWN (2). Raised when they are equal or not a valid {UP,DOWN} pair.
    error NotComplementary();
    /// @notice Complementary matching: a signed price is outside the valid bps range [0, 10000],
    ///         which would break the maker/taker cash split. Prices are basis points of $1.
    error PriceOutOfRange();

    // ── Types ───────────────────────────────────────────────────────────
    /// @dev Packed for cheaper `createMarket`. Layout is UNCHANGED from V1 so the
    ///      `IUpDownSettlement.Market` ABI (read by `ChainlinkResolver` and the backend's
    ///      `getMarket` decode) keeps working. `cashUpFlow`/`cashDownFlow` remain analytics-only
    ///      cumulative cash notional; `settled` is retained for layout stability (no longer written
    ///      now that `withdrawSettlement` is removed).
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
    ///      Side is 0=BUY, 1=SELL. `maxFee` (F-2026-17731) is the maximum total fee
    ///      (`platformFee + makerFee`) this signer agrees to pay **when filled as the taker**;
    ///      it is part of the signed payload so the relayer can never charge more than the user
    ///      committed to. A pure maker (resting) order pays no fee, but still carries `maxFee` so
    ///      the typed-data shape is uniform across both sides of a fill.
    struct Order {
        address maker;
        uint256 market;
        uint256 option;
        uint8 side;
        uint8 orderType;
        uint256 price;
        uint256 amount;
        uint256 maxFee;
        uint256 nonce;
        uint256 expiry;
    }

    /// @notice F-2026-17731: `maxFee` added → new typehash. The off-chain signer/verifier and SDK
    ///         change in lock-step. The EIP-712 field name is "type" (not `orderType`) to match the
    ///         backend's signed payloads verbatim.
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,uint256 market,uint256 option,uint8 side,uint8 type,uint256 price,uint256 amount,uint256 maxFee,uint256 nonce,uint256 expiry)"
    );

    /// @dev EIP-712 authorization a user signs to consent to a relayer-submitted complementary
    ///      mint or burn (F-2026-17772). `action` is 1 = mint, 2 = burn. Replay-protected by a
    ///      per-account nonce.
    struct MintAuth {
        address account;
        uint256 market;
        uint8 action;
        uint256 amount;
        uint256 nonce;
        uint256 expiry;
    }

    bytes32 public constant MINT_AUTH_TYPEHASH = keccak256(
        "MintAuth(address account,uint256 market,uint8 action,uint256 amount,uint256 nonce,uint256 expiry)"
    );

    uint8 internal constant OPTION_UP = 1;
    uint8 internal constant OPTION_DOWN = 2;
    uint8 internal constant SIDE_BUY = 0;
    uint8 internal constant SIDE_SELL = 1;
    uint8 internal constant MINT_ACTION_MINT = 1;
    uint8 internal constant MINT_ACTION_BURN = 2;

    // ── Events ──────────────────────────────────────────────────────────
    event MarketCreated(
        uint256 indexed marketId,
        bytes32 indexed pairId,
        uint256 duration,
        int256 strikePrice,
        uint256 startTime,
        uint256 endTime
    );
    event PositionEntered(uint256 indexed marketId, uint8 option, uint256 amount, address indexed buyer);
    event MarketResolved(uint256 indexed marketId, uint8 winner, int256 settlementPrice);
    event RebateAccumulated(address indexed maker, uint256 amount);
    event RebateClaimed(address indexed claimant, uint256 amount);
    event RebateBudgetSet(uint256 budgetPerWindow, uint256 windowDuration);
    event PausedSet(bool paused);
    event DmmRebateBpsUpdated(uint256 bps);
    event EmergencyWithdrawProposed(address indexed token, address indexed to, uint256 amount, uint256 unlocksAt);
    event EmergencyWithdrawExecuted(address indexed token, address indexed to, uint256 amount);
    event EmergencyWithdrawCancelled(bytes32 indexed proposalId);
    /// @notice F-2026-17756: emitted on every atomic fill. Carries both signed parties and the fee
    ///         flow so off-chain indexers reconstruct settlement without joining ERC20 logs.
    event FillSettled(
        bytes32 indexed makerOrderHash,
        bytes32 indexed takerOrderHash,
        address buyer,
        address seller,
        address indexed taker,
        uint256 fillAmount,
        uint256 cashPart,
        uint256 platformFee,
        uint256 makerFee
    );
    event TreasurySet(address indexed previous, address indexed current);
    /// @notice F-2026-17772: complementary mint now records per-user shares for both legs.
    event ComplementaryMinted(uint256 indexed marketId, address indexed minter, uint256 amount);
    /// @notice F-2026-17772: complementary burn now gated on a complete set the holder owns.
    event ComplementaryBurned(uint256 indexed marketId, address indexed holder, uint256 amount);
    /// @notice F-2026-17778: trustless redemption. `to` is always the share owner — never the relayer.
    event Redeemed(uint256 indexed marketId, address indexed holder, uint8 winner, uint256 payout);
    /// @notice Complementary matching: two BUY orders on opposite options crossed by MINTING a fresh
    ///         complete set. `upCash` / `downCash` are what each buyer paid into backing (they sum to
    ///         `fillAmount`). `platformFee` / `makerFee` are the taker-paid fees (peer-to-peer, never
    ///         touching backing), included so a mint-fill's full settlement — including fee flow — is
    ///         reconstructable from this event alone, matching the `FillSettled` guarantee for
    ///         `enterPosition`. Emitted alongside a `PositionEntered` per leg so share indexers stay uniform.
    event MintMatched(
        uint256 indexed marketId,
        address indexed upBuyer,
        address indexed downBuyer,
        uint256 fillAmount,
        uint256 upCash,
        uint256 downCash,
        address taker,
        uint256 platformFee,
        uint256 makerFee
    );
    /// @notice Complementary matching: two SELL orders on opposite options crossed by BURNING a
    ///         complete set. `upProceeds` / `downProceeds` are what each seller received (they sum to
    ///         `fillAmount`).
    event MergeMatched(
        uint256 indexed marketId,
        address indexed upSeller,
        address indexed downSeller,
        uint256 fillAmount,
        uint256 upProceeds,
        uint256 downProceeds,
        address taker
    );

    // ── Immutables / roles ─────────────────────────────────────────────
    IERC20 public immutable usdt;

    address public resolver;
    address public autocycler;
    address public relayer;
    /// @notice Destination for `platformFee`, paid by the taker atomically inside `enterPosition`.
    address public treasury;

    uint256 public nextMarketId;
    mapping(uint256 => Market) public markets;

    /// @notice DMM rebate rate (basis points). Off-chain reference for the rebate amount the relayer
    ///         accrues via `accumulateRebate`. (F-2026-17746: the unused `platformFeeBps`/`makerFeeBps`
    ///         were removed — fees are signed-and-capped per order, not computed from on-chain bps.)
    uint256 public dmmRebateBps;
    mapping(address => uint256) public dmmRebateAccumulated;

    // ── F-2026-17779: rolling rebate budget (treasury circuit-breaker) ──
    /// @notice Maximum total rebate that can be claimed per rolling window. `0` (default) disables
    ///         all rebate claims — fail-safe until ops configures a budget. Caps a compromised-relayer
    ///         treasury drain to at most one window's budget even with a standing treasury approval.
    uint256 public rebateBudgetPerWindow;
    uint256 public rebateWindowDuration;
    uint256 public rebateWindowStart;
    uint256 public rebateClaimedInWindow;

    bool public paused;

    /// @notice Cumulative filled amount per signed order hash (maker AND taker). Caps at
    ///         `order.amount`; over-fill replays revert.
    mapping(bytes32 => uint256) public orderFills;

    /// @notice F-2026-17731: cumulative fees already pulled against a taker order hash across ALL of
    ///         its partial fills. `maxFee` is the maximum TOTAL fee the taker signed for the whole
    ///         order, so it must be enforced cumulatively: a per-fill-only check would let the relayer
    ///         split one taker order into N partial fills and charge up to N×`maxFee`, draining the
    ///         taker's standing approval far beyond the signed cap. Keyed by the taker order hash
    ///         (the signer who actually pays the fee).
    mapping(bytes32 => uint256) public orderFeesPaid;

    /// @notice F-2026-17772 / 17777: authoritative per-user share ledger.
    ///         `userShares[marketId][user][option]`, option ∈ {1=UP, 2=DOWN}. The off-chain ledger
    ///         derives from the events these writes emit; on-chain is the source of truth.
    mapping(uint256 => mapping(address => mapping(uint8 => uint256))) public userShares;

    /// @notice F-2026-17771: aggregate outstanding shares per option per market. The conservation
    ///         invariant is `marketRetained == optionShares[UP] == optionShares[DOWN]` for every
    ///         unresolved market. Maintained on mint / burn / redeem; unchanged by `enterPosition`
    ///         (which only transfers existing shares).
    mapping(uint256 => mapping(uint8 => uint256)) public optionShares;

    /// @notice Per-market backing collateral. Now changes ONLY on mint / burn / redeem; fills move
    ///         cash peer-to-peer and never touch the pool, so `enterPosition` is balance-neutral for
    ///         the contract and cannot perturb `usdt.balanceOf(this) == Σ marketRetained`.
    mapping(uint256 => uint256) public marketRetained;

    /// @notice F-2026-17772: consumed MintAuth nonces (replay protection), per account.
    mapping(address => mapping(uint256 => bool)) public mintAuthNonceUsed;

    // ── Emergency-withdraw timelock (Part A, retained) ─────────────────
    uint256 public constant EMERGENCY_TIMELOCK = 24 hours;

    struct EmergencyProposal {
        address token;
        address to;
        uint256 amount;
        uint256 unlocksAt;
    }

    mapping(bytes32 => EmergencyProposal) public emergencyProposals;
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
    /// @notice F-2026-17746: the `_platformFeeBps`/`_makerFeeBps` constructor params were removed
    ///         (the on-chain bps were never enforced and only misled monitoring; fees are now signed
    ///         and capped per order). Deploy scripts updated in lock-step.
    constructor(IERC20 _usdt, address initialOwner)
        Ownable(initialOwner)
        EIP712("UpDown Exchange", "1")
    {
        if (address(_usdt) == address(0)) revert ZeroAddress();
        usdt = _usdt;
    }

    // ── Market creation ─────────────────────────────────────────────────

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

    // ── EIP-712 helpers ─────────────────────────────────────────────────

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
                order.maxFee,
                order.nonce,
                order.expiry
            )
        );
    }

    /// @notice EIP-712 digest including domain separator. Exposed for off-chain tooling.
    function orderDigest(Order memory order) public view returns (bytes32) {
        return _hashTypedDataV4(hashOrder(order));
    }

    function hashMintAuth(MintAuth memory a) public pure returns (bytes32) {
        return keccak256(
            abi.encode(MINT_AUTH_TYPEHASH, a.account, a.market, a.action, a.amount, a.nonce, a.expiry)
        );
    }

    // ── Fill settlement (F-2026-17756 / 17757 / 17731 / 17739) ──────────

    /// @notice Inputs for an atomic two-sided fill. Both orders are EIP-712-signed and verified
    ///         on-chain: the resting `makerOrder` and the aggressing `takerOrder`. The redundant
    ///         V1 fields (`marketId`, `option`, `taker`, `sellerReceives`, `makerFeeRecipient`) are
    ///         gone (F-2026-17739) — every value is derived from the two signed orders. `platformFee`
    ///         and `makerFee` stay relayer-supplied (the off-chain Polymarket p(1−p) formula is
    ///         non-linear) but are hard-capped on-chain by `takerOrder.maxFee` (F-2026-17731) and
    ///         pulled from the taker (F-2026-17756).
    struct FillInputs {
        Order makerOrder; // resting side
        bytes makerSignature;
        Order takerOrder; // aggressing side
        bytes takerSignature;
        uint256 fillAmount; // shares filled now (≤ remaining on both orders)
        uint256 platformFee; // paid by taker → treasury
        uint256 makerFee; // paid by taker → makerOrder.maker (the resting maker's rebate)
    }

    /// @notice Settle a matched fill between two signed orders. Shares of `option` transfer from the
    ///         seller to the buyer on-chain; the buyer pays `cashPart` to the seller peer-to-peer; the
    ///         taker pays `platformFee + makerFee` (capped by its signed `maxFee`). The contract's own
    ///         USDT balance is untouched, so the conservation invariant
    ///         `usdt.balanceOf(this) == Σ marketRetained` is preserved by construction.
    function enterPosition(FillInputs calldata f) external nonReentrant whenNotPaused onlyRelayer {
        Order calldata mo = f.makerOrder;
        Order calldata to = f.takerOrder;

        // ── Order consistency: same market & option, one BUY + one SELL, crossing prices. ──
        if (mo.market != to.market) revert MarketMismatch();
        if (mo.option != to.option) revert OptionMismatch();
        if (mo.option != OPTION_UP && mo.option != OPTION_DOWN) revert InvalidOption();
        if (mo.side == to.side) revert NotBuySellPair();
        if (mo.side != SIDE_BUY && mo.side != SIDE_SELL) revert InvalidSide();
        if (to.side != SIDE_BUY && to.side != SIDE_SELL) revert InvalidSide();
        if (block.timestamp > mo.expiry || block.timestamp > to.expiry) revert OrderExpired();
        if (f.fillAmount == 0) revert FillExceedsOrderAmount();

        // ── F-2026-17952 + F-2026-17953: market existence & open-window check, hoisted ABOVE
        //     signature verification and all order-fill state writes. A fill against a
        //     nonexistent / not-yet-open / ended market now reverts before any ECRECOVER or SSTORE,
        //     and the added lower bound (`block.timestamp < startTime`) closes the pre-start window
        //     so fills cannot execute before the published market start. ──
        Market storage m = markets[mo.market];
        if (m.startTime == 0) revert MarketNotOpen();
        if (block.timestamp < uint256(m.startTime)) revert MarketNotOpen(); // F-2026-17953
        if (block.timestamp >= uint256(m.endTime)) revert MarketNotOpen();

        // Execution price is the resting maker's price (price-time priority). Crossing check:
        // the buy side must be willing to pay ≥ the sell side's ask.
        uint256 buyPrice = mo.side == SIDE_BUY ? mo.price : to.price;
        uint256 sellPrice = mo.side == SIDE_SELL ? mo.price : to.price;
        if (buyPrice < sellPrice) revert OrdersNotCrossed();
        uint256 cashPart = (mo.price * f.fillAmount) / 10000;

        // ── F-2026-17757: verify BOTH signatures (EOA + ERC-1271 via SignatureChecker). ──
        bytes32 makerHash = hashOrder(mo);
        bytes32 takerHash = hashOrder(to);
        if (!SignatureChecker.isValidSignatureNow(mo.maker, _hashTypedDataV4(makerHash), f.makerSignature)) {
            revert InvalidSignature();
        }
        if (!SignatureChecker.isValidSignatureNow(to.maker, _hashTypedDataV4(takerHash), f.takerSignature)) {
            revert InvalidSignature();
        }

        // ── F-2026-17731: fees pulled from the taker, capped CUMULATIVELY by the taker's signed
        //     maxFee. The cap is the maximum TOTAL fee across ALL partial fills of this taker order,
        //     not per-fill: a per-fill-only check would let the relayer split one taker order into N
        //     fills and charge up to N×maxFee, defeating the signed cap (the relayer must instead
        //     budget the signed maxFee across the order's partial fills). ──
        uint256 feeTotal = f.platformFee + f.makerFee;
        uint256 takerFeesPaid = orderFeesPaid[takerHash] + feeTotal;
        if (takerFeesPaid > to.maxFee) revert FeeExceedsTakerCap(takerFeesPaid, to.maxFee);
        if (f.platformFee > 0 && treasury == address(0)) revert TreasuryNotConfigured();

        // ── Partial-fill bookkeeping for BOTH orders (shares) + cumulative taker fees. ──
        _consumeOrder(makerHash, mo.amount, f.fillAmount);
        _consumeOrder(takerHash, to.amount, f.fillAmount);
        orderFeesPaid[takerHash] = takerFeesPaid;

        // ── Resolve roles. taker is the aggressor (takerOrder.maker); buyer/seller by side. ──
        address taker = to.maker;
        address buyer = mo.side == SIDE_BUY ? mo.maker : to.maker;
        address seller = mo.side == SIDE_SELL ? mo.maker : to.maker;
        uint8 option = uint8(mo.option);

        // ── F-2026-17771 / 17776 / 17777: the seller must actually hold the shares being sold.
        //     This replaces the V1 pooled `marketRetained >= mintBackingDelta` check — backing can
        //     no longer be reused across fills, and a fill consumes the seller's own shares. ──
        uint256 sellerHeld = userShares[mo.market][seller][option];
        if (sellerHeld < f.fillAmount) {
            revert InsufficientShares(mo.market, option, f.fillAmount, sellerHeld);
        }
        userShares[mo.market][seller][option] = sellerHeld - f.fillAmount;
        userShares[mo.market][buyer][option] += f.fillAmount;

        // ── Money movement (peer-to-peer; contract balance untouched). ──
        // Buyer pays the seller for the shares.
        if (cashPart > 0) {
            usdt.safeTransferFrom(buyer, seller, cashPart);
        }
        // F-2026-17756: fees are pulled from the TAKER, not the buyer-by-direction.
        if (f.platformFee > 0) {
            usdt.safeTransferFrom(taker, treasury, f.platformFee);
        }
        if (f.makerFee > 0) {
            usdt.safeTransferFrom(taker, mo.maker, f.makerFee);
        }

        // Analytics-only cash-flow counters (not load-bearing for settlement).
        if (option == OPTION_UP) {
            m.cashUpFlow += uint128(f.fillAmount);
        } else {
            m.cashDownFlow += uint128(f.fillAmount);
        }

        emit PositionEntered(mo.market, option, f.fillAmount, buyer);
        emit FillSettled(makerHash, takerHash, buyer, seller, taker, f.fillAmount, cashPart, f.platformFee, f.makerFee);
    }

    function _consumeOrder(bytes32 orderHash, uint256 signedAmount, uint256 fillAmount) internal {
        uint256 newFilled = orderFills[orderHash] + fillAmount;
        if (newFilled > signedAmount) revert FillExceedsOrderAmount();
        orderFills[orderHash] = newFilled;
    }

    /// @dev The two legs of a complementary match must be on OPPOSITE options — exactly one UP (1)
    ///      and one DOWN (2). Reverts otherwise (equal options, or an out-of-range option value).
    function _requireComplementary(uint256 optA, uint256 optB) internal pure {
        bool ok = (optA == OPTION_UP && optB == OPTION_DOWN) || (optA == OPTION_DOWN && optB == OPTION_UP);
        if (!ok) revert NotComplementary();
    }

    // ── Complementary matching: MINT / MERGE (buy-UP ⇄ buy-DOWN, sell-UP ⇄ sell-DOWN) ───
    //
    // These make the two option books trade against each other so pure buy-side (or sell-side)
    // demand can cross without either party pre-holding shares — the "buy UP = sell DOWN" duality
    // realised in the engine. They are the Polymarket CTF-Exchange MINT/MERGE operations:
    //
    //   MINT  : one BUY UP + one BUY DOWN, priced so `p_up + p_down ≥ 10000`. A fresh complete set
    //           is minted; the UP buyer gets UP shares, the DOWN buyer gets DOWN shares, and their
    //           combined cash (== `fillAmount`) backs the set. Mirror of `enterPosition`'s consent /
    //           fee model: both Orders are EIP-712-verified, execution is pegged to the resting
    //           maker's price (price-time priority), and the taker pays the fee capped by `maxFee`.
    //   MERGE : one SELL UP + one SELL DOWN, priced so `p_up + p_down ≤ 10000`. Both sellers'
    //           shares burn a complete set; the released `fillAmount` USDT is split by price. Both
    //           sellers must already hold the shares (share-covered, like every SELL).
    //
    // Balance invariant is preserved by construction: MINT raises `usdt.balanceOf(this)` by exactly
    // `fillAmount` (== the `marketRetained` increase); MERGE lowers both by exactly `fillAmount`.

    /// @notice Settle a MINT match between two signed BUY orders on opposite options. `f.makerOrder`
    ///         is the resting BUY, `f.takerOrder` the aggressing BUY (either may be the UP leg).
    ///         Fees are pulled from the taker and capped cumulatively by `takerOrder.maxFee`, exactly
    ///         as in `enterPosition`; a resting maker pays no fee.
    function mintMatch(FillInputs calldata f) external nonReentrant whenNotPaused onlyRelayer {
        Order calldata mo = f.makerOrder;
        Order calldata to = f.takerOrder;

        // ── Geometry: both BUY, same market, opposite options, crossing, unexpired, nonzero fill. ──
        if (mo.market != to.market) revert MarketMismatch();
        if (mo.side != SIDE_BUY || to.side != SIDE_BUY) revert NotBothBuys();
        _requireComplementary(mo.option, to.option);
        if (mo.price > 10000 || to.price > 10000) revert PriceOutOfRange();
        // MINT crossing: the two buyers together must fund the full $1 set.
        if (mo.price + to.price < 10000) revert OrdersNotCrossed();
        if (block.timestamp > mo.expiry || block.timestamp > to.expiry) revert OrderExpired();
        if (f.fillAmount == 0) revert FillExceedsOrderAmount();

        // ── Market existence & open window (hoisted above sigs/state, mirroring enterPosition). ──
        Market storage m = markets[mo.market];
        if (m.startTime == 0) revert MarketNotOpen();
        if (block.timestamp < uint256(m.startTime)) revert MarketNotOpen();
        if (block.timestamp >= uint256(m.endTime)) revert MarketNotOpen();

        // ── Verify BOTH order signatures (EOA + ERC-1271). No MintAuth: the Orders are the consent. ──
        bytes32 makerHash = hashOrder(mo);
        bytes32 takerHash = hashOrder(to);
        if (!SignatureChecker.isValidSignatureNow(mo.maker, _hashTypedDataV4(makerHash), f.makerSignature)) {
            revert InvalidSignature();
        }
        if (!SignatureChecker.isValidSignatureNow(to.maker, _hashTypedDataV4(takerHash), f.takerSignature)) {
            revert InvalidSignature();
        }

        // ── Fees: taker pays, capped CUMULATIVELY by the taker's signed maxFee (F-2026-17731). ──
        uint256 feeTotal = f.platformFee + f.makerFee;
        uint256 takerFeesPaid = orderFeesPaid[takerHash] + feeTotal;
        if (takerFeesPaid > to.maxFee) revert FeeExceedsTakerCap(takerFeesPaid, to.maxFee);
        if (f.platformFee > 0 && treasury == address(0)) revert TreasuryNotConfigured();

        // ── Partial-fill bookkeeping for BOTH orders (shared with enterPosition via orderFills). ──
        _consumeOrder(makerHash, mo.amount, f.fillAmount);
        _consumeOrder(takerHash, to.amount, f.fillAmount);
        orderFeesPaid[takerHash] = takerFeesPaid;

        // ── Execution pegged to the resting maker's price (price-time priority). The maker pays its
        //     signed price; the taker covers the complement so the set is fully backed. Any sub-unit
        //     rounding lands on the taker and flows into backing — never to the platform. ──
        uint256 makerCash = (mo.price * f.fillAmount) / 10000;
        uint256 takerCash = f.fillAmount - makerCash;

        // ── Pull both buyers' cash into the pool; retain the whole set as backing. Guard the
        //     zero-value legs (a boundary price of 0 makes one leg 0) so a settlement token that
        //     reverts on zero-value transfers cannot brick an otherwise-valid match — mirroring the
        //     `> 0` guards in enterPosition and mergeMatch. ──
        if (makerCash > 0) usdt.safeTransferFrom(mo.maker, address(this), makerCash);
        if (takerCash > 0) usdt.safeTransferFrom(to.maker, address(this), takerCash);
        marketRetained[mo.market] += f.fillAmount;

        // ── Credit each buyer their own option's shares; both option supplies grow by the set size. ──
        userShares[mo.market][mo.maker][uint8(mo.option)] += f.fillAmount;
        userShares[mo.market][to.maker][uint8(to.option)] += f.fillAmount;
        optionShares[mo.market][OPTION_UP] += f.fillAmount;
        optionShares[mo.market][OPTION_DOWN] += f.fillAmount;

        // ── Fees pulled from the taker (contract balance untouched by the fee transfers). ──
        if (f.platformFee > 0) usdt.safeTransferFrom(to.maker, treasury, f.platformFee);
        if (f.makerFee > 0) usdt.safeTransferFrom(to.maker, mo.maker, f.makerFee);

        // ── Resolve UP vs DOWN leg for events / analytics. ──
        address upBuyer;
        address downBuyer;
        uint256 upCash;
        uint256 downCash;
        if (mo.option == OPTION_UP) {
            upBuyer = mo.maker;
            upCash = makerCash;
            downBuyer = to.maker;
            downCash = takerCash;
        } else {
            upBuyer = to.maker;
            upCash = takerCash;
            downBuyer = mo.maker;
            downCash = makerCash;
        }

        m.cashUpFlow += uint128(f.fillAmount);
        m.cashDownFlow += uint128(f.fillAmount);

        emit PositionEntered(mo.market, OPTION_UP, f.fillAmount, upBuyer);
        emit PositionEntered(mo.market, OPTION_DOWN, f.fillAmount, downBuyer);
        emit MintMatched(mo.market, upBuyer, downBuyer, f.fillAmount, upCash, downCash, to.maker, f.platformFee, f.makerFee);
    }

    /// @notice Settle a MERGE match between two signed SELL orders on opposite options. `f.makerOrder`
    ///         is the resting SELL, `f.takerOrder` the aggressing SELL (either may be the UP leg). A
    ///         complete set is burned and the released $1/share is split by the two signed prices.
    ///         Zero-fee: both parties receive cash, so there is no taker inflow to source a fee from;
    ///         `platformFee` / `makerFee` MUST be zero.
    function mergeMatch(FillInputs calldata f) external nonReentrant whenNotPaused onlyRelayer {
        Order calldata mo = f.makerOrder;
        Order calldata to = f.takerOrder;

        // ── Geometry: both SELL, same market, opposite options, crossing, unexpired, nonzero fill. ──
        if (mo.market != to.market) revert MarketMismatch();
        if (mo.side != SIDE_SELL || to.side != SIDE_SELL) revert NotBothSells();
        _requireComplementary(mo.option, to.option);
        if (mo.price > 10000 || to.price > 10000) revert PriceOutOfRange();
        // MERGE crossing: the two sellers together may claim at most the $1 the burn releases.
        if (mo.price + to.price > 10000) revert OrdersNotCrossed();
        if (block.timestamp > mo.expiry || block.timestamp > to.expiry) revert OrderExpired();
        if (f.fillAmount == 0) revert FillExceedsOrderAmount();
        // MERGE pays both sellers from released backing — there is no taker cash inflow to fee.
        if (f.platformFee != 0 || f.makerFee != 0) revert FeeBreakdownInvalid();

        Market storage m = markets[mo.market];
        if (m.startTime == 0) revert MarketNotOpen();
        if (block.timestamp < uint256(m.startTime)) revert MarketNotOpen();
        if (block.timestamp >= uint256(m.endTime)) revert MarketNotOpen();

        bytes32 makerHash = hashOrder(mo);
        bytes32 takerHash = hashOrder(to);
        if (!SignatureChecker.isValidSignatureNow(mo.maker, _hashTypedDataV4(makerHash), f.makerSignature)) {
            revert InvalidSignature();
        }
        if (!SignatureChecker.isValidSignatureNow(to.maker, _hashTypedDataV4(takerHash), f.takerSignature)) {
            revert InvalidSignature();
        }

        _consumeOrder(makerHash, mo.amount, f.fillAmount);
        _consumeOrder(takerHash, to.amount, f.fillAmount);

        // ── Each seller must hold their own option's shares; burn the complete set. ──
        uint8 makerOpt = uint8(mo.option);
        uint8 takerOpt = uint8(to.option);
        uint256 makerHeld = userShares[mo.market][mo.maker][makerOpt];
        if (makerHeld < f.fillAmount) revert InsufficientShares(mo.market, makerOpt, f.fillAmount, makerHeld);
        uint256 takerHeld = userShares[mo.market][to.maker][takerOpt];
        if (takerHeld < f.fillAmount) revert InsufficientShares(mo.market, takerOpt, f.fillAmount, takerHeld);

        userShares[mo.market][mo.maker][makerOpt] = makerHeld - f.fillAmount;
        userShares[mo.market][to.maker][takerOpt] = takerHeld - f.fillAmount;
        optionShares[mo.market][OPTION_UP] -= f.fillAmount;
        optionShares[mo.market][OPTION_DOWN] -= f.fillAmount;
        marketRetained[mo.market] -= f.fillAmount;

        // ── Payout pegged to the resting maker's price; taker receives the complement. Sum == fill. ──
        uint256 makerProceeds = (mo.price * f.fillAmount) / 10000;
        uint256 takerProceeds = f.fillAmount - makerProceeds;
        if (makerProceeds > 0) usdt.safeTransfer(mo.maker, makerProceeds);
        if (takerProceeds > 0) usdt.safeTransfer(to.maker, takerProceeds);

        address upSeller;
        address downSeller;
        uint256 upProceeds;
        uint256 downProceeds;
        if (mo.option == OPTION_UP) {
            upSeller = mo.maker;
            upProceeds = makerProceeds;
            downSeller = to.maker;
            downProceeds = takerProceeds;
        } else {
            upSeller = to.maker;
            upProceeds = takerProceeds;
            downSeller = mo.maker;
            downProceeds = makerProceeds;
        }

        emit MergeMatched(mo.market, upSeller, downSeller, f.fillAmount, upProceeds, downProceeds, to.maker);
    }

    // ── Complementary mint / burn (F-2026-17772) ────────────────────────
    //
    // Polymarket-parity share creation: deposit `amount` USDT, receive `amount` UP + `amount` DOWN
    // shares. Exactly one option pays $1 at resolution, so the deposit backs exactly one redemption.
    // Per-user shares are now recorded on-chain, and both relayer-submitted entrypoints require the
    // user's EIP-712 `MintAuth` consent. Self-service `mint` / `burn` need no signature (msg.sender
    // is the account) so a user can always exit a complete set even if the relayer is gone.

    /// @notice Relayer-submitted complementary mint with the minter's signed consent (F-2026-17772).
    function complementaryMint(uint256 marketId, uint256 amount, address minter, MintAuth calldata auth, bytes calldata sig)
        external
        nonReentrant
        whenNotPaused
        onlyRelayer
    {
        _checkMintAuth(auth, sig, minter, marketId, MINT_ACTION_MINT, amount);
        _mint(marketId, amount, minter);
    }

    /// @notice Self-service complementary mint. The depositor authorizes their own deposit by being
    ///         `msg.sender`; no relayer, no signature.
    function mint(uint256 marketId, uint256 amount) external nonReentrant whenNotPaused {
        _mint(marketId, amount, msg.sender);
    }

    function _mint(uint256 marketId, uint256 amount, address minter) internal {
        if (amount == 0) revert FillExceedsOrderAmount();
        if (minter == address(0)) revert ZeroAddress();
        Market storage m = markets[marketId];
        if (m.startTime == 0) revert MarketNotOpen();
        if (block.timestamp < uint256(m.startTime)) revert MarketNotOpen(); // F-2026-17953
        if (block.timestamp >= uint256(m.endTime)) revert MarketNotOpen();

        usdt.safeTransferFrom(minter, address(this), amount);
        marketRetained[marketId] += amount;
        userShares[marketId][minter][OPTION_UP] += amount;
        userShares[marketId][minter][OPTION_DOWN] += amount;
        optionShares[marketId][OPTION_UP] += amount;
        optionShares[marketId][OPTION_DOWN] += amount;

        emit ComplementaryMinted(marketId, minter, amount);
    }

    /// @notice Relayer-submitted complementary burn with the holder's signed consent (F-2026-17772).
    function complementaryBurn(uint256 marketId, uint256 amount, address holder, MintAuth calldata auth, bytes calldata sig)
        external
        nonReentrant
        whenNotPaused
        onlyRelayer
    {
        _checkMintAuth(auth, sig, holder, marketId, MINT_ACTION_BURN, amount);
        _burn(marketId, amount, holder);
    }

    /// @notice Self-service complementary burn. The holder burns their own complete set.
    function burn(uint256 marketId, uint256 amount) external nonReentrant whenNotPaused {
        _burn(marketId, amount, msg.sender);
    }

    function _burn(uint256 marketId, uint256 amount, address holder) internal {
        if (amount == 0) revert FillExceedsOrderAmount();
        if (holder == address(0)) revert ZeroAddress();
        Market storage m = markets[marketId];
        if (m.startTime == 0) revert MarketNotOpen();
        if (block.timestamp < uint256(m.startTime)) revert MarketNotOpen(); // F-2026-17953
        if (block.timestamp >= uint256(m.endTime)) revert MarketNotOpen(); // F-2026-17774
        if (m.resolved) revert AlreadyResolved();

        // F-2026-17776 / 17772: the holder must own a COMPLETE set. This is what makes the V1
        // "withdraw backing that underpins another participant's live position" attack impossible:
        // a maker who sold their UP no longer holds it, so they can't burn the set.
        uint256 heldUp = userShares[marketId][holder][OPTION_UP];
        uint256 heldDown = userShares[marketId][holder][OPTION_DOWN];
        if (heldUp < amount) revert InsufficientShares(marketId, OPTION_UP, amount, heldUp);
        if (heldDown < amount) revert InsufficientShares(marketId, OPTION_DOWN, amount, heldDown);

        userShares[marketId][holder][OPTION_UP] = heldUp - amount;
        userShares[marketId][holder][OPTION_DOWN] = heldDown - amount;
        optionShares[marketId][OPTION_UP] -= amount;
        optionShares[marketId][OPTION_DOWN] -= amount;
        marketRetained[marketId] -= amount;

        usdt.safeTransfer(holder, amount);
        emit ComplementaryBurned(marketId, holder, amount);
    }

    function _checkMintAuth(
        MintAuth calldata auth,
        bytes calldata sig,
        address account,
        uint256 marketId,
        uint8 action,
        uint256 amount
    ) internal {
        if (
            auth.account != account || auth.market != marketId || auth.action != action
                || auth.amount != amount
        ) revert InvalidMintAuth();
        if (block.timestamp > auth.expiry) revert InvalidMintAuth();
        if (mintAuthNonceUsed[account][auth.nonce]) revert MintAuthNonceUsed(account, auth.nonce);
        if (!SignatureChecker.isValidSignatureNow(account, _hashTypedDataV4(hashMintAuth(auth)), sig)) {
            revert InvalidMintAuth();
        }
        mintAuthNonceUsed[account][auth.nonce] = true;
    }

    // ── Resolution & trustless redemption (F-2026-17778) ────────────────

    function resolve(uint256 marketId, int256 settlementPrice, uint8 winner) external onlyResolver whenNotPaused {
        Market storage m = markets[marketId];
        if (m.startTime == 0) revert MarketNotOpen();
        if (m.resolved) revert AlreadyResolved();
        if (block.timestamp < uint256(m.endTime)) revert MarketNotOpen();
        if (winner != OPTION_UP && winner != OPTION_DOWN) revert InvalidWinner();

        m.settlementPrice = int128(settlementPrice);
        m.winner = winner;
        m.resolved = true;

        // F-2026-17954: the losing option's aggregate shares are worthless and unredeemable
        // after resolution, but nothing else ever clears them. Zero the loser side here so
        // off-chain consumers reading `optionShares` do not misread it as live supply. The
        // winner side is decremented per redemption in `_redeemToAllowZero`.
        uint8 loser = winner == OPTION_UP ? OPTION_DOWN : OPTION_UP;
        optionShares[marketId][loser] = 0;

        emit MarketResolved(marketId, winner, int256(settlementPrice));
    }

    /// @notice F-2026-17778: trustless redemption. A winner claims `userShares[m][msg.sender][winner]`
    ///         USDT directly from `marketRetained`, with no dependence on the relayer remaining live,
    ///         honest, or solvent. The whole-pool-to-relayer `withdrawSettlement` of V1 is removed.
    function redeem(uint256 marketId) external nonReentrant whenNotPaused returns (uint256 payout) {
        return _redeemTo(marketId, msg.sender);
    }

    /// @notice F-2026-17778: relayer/keeper-assisted batch redemption that pays each holder THEIR OWN
    ///         winnings to THEIR OWN wallet. Permissionless and funds can only ever reach the rightful
    ///         holder, so it preserves the gas-paid-by-operator UX without re-introducing custody.
    function redeemFor(uint256 marketId, address[] calldata holders) external nonReentrant whenNotPaused {
        uint256 len = holders.length;
        for (uint256 i; i < len; ++i) {
            _redeemToAllowZero(marketId, holders[i]);
        }
    }

    function _redeemTo(uint256 marketId, address holder) internal returns (uint256 payout) {
        payout = _redeemToAllowZero(marketId, holder);
        if (payout == 0) revert NothingToRedeem();
    }

    function _redeemToAllowZero(uint256 marketId, address holder) internal returns (uint256 payout) {
        Market storage m = markets[marketId];
        if (!m.resolved) revert NotResolved();
        uint8 winner = m.winner;
        payout = userShares[marketId][holder][winner];
        if (payout == 0) return 0;
        if (holder == address(0)) revert ZeroAddress();

        userShares[marketId][holder][winner] = 0;
        optionShares[marketId][winner] -= payout;
        marketRetained[marketId] -= payout;

        usdt.safeTransfer(holder, payout);
        emit Redeemed(marketId, holder, winner, payout);
    }

    // ── Rebates (F-2026-17779: rolling-window budget) ───────────────────

    /// @notice Credit `maker`'s rebate accumulator. No fund movement — a counter increment, claimed
    ///         later via `claimRebate`. Called by the relayer after off-chain fills.
    function accumulateRebate(address maker, uint256 amount) external onlyRelayer whenNotPaused {
        dmmRebateAccumulated[maker] += amount;
        emit RebateAccumulated(maker, amount);
    }

    /// @notice Claim accumulated rebate, pulling from the treasury EOA via `transferFrom`.
    ///         F-2026-17779: the total claimable per rolling window is capped by
    ///         `rebateBudgetPerWindow`, so even a standing treasury approval bounds a compromised
    ///         relayer to one window's budget. `rebateBudgetPerWindow == 0` (default) disables claims.
    function claimRebate() external nonReentrant {
        uint256 accrued = dmmRebateAccumulated[msg.sender];
        if (accrued == 0) return;
        if (treasury == address(0)) revert TreasuryUnderFunded(accrued, 0);

        // Roll the window forward lazily before checking the budget.
        uint256 windowDuration = rebateWindowDuration;
        if (windowDuration != 0 && block.timestamp >= rebateWindowStart + windowDuration) {
            rebateWindowStart = block.timestamp;
            rebateClaimedInWindow = 0;
        }
        uint256 remaining = rebateBudgetPerWindow > rebateClaimedInWindow
            ? rebateBudgetPerWindow - rebateClaimedInWindow
            : 0;

        // F-2026-17975: claim PARTIALLY up to the remaining window budget instead of an
        // all-or-nothing revert. Previously, any accumulator larger than `rebateBudgetPerWindow`
        // could never fit under `remaining` and became permanently unclaimable. Now the caller
        // draws down as much as the window allows; the unclaimed remainder stays accrued for the
        // next window. `remaining == 0` (budget disabled or window exhausted) still reverts.
        uint256 amt = accrued < remaining ? accrued : remaining;
        if (amt == 0) revert RebateBudgetExceeded(accrued, remaining);

        uint256 balance = usdt.balanceOf(treasury);
        uint256 allowance = usdt.allowance(treasury, address(this));
        uint256 have = balance < allowance ? balance : allowance;
        if (have < amt) revert TreasuryUnderFunded(amt, have);

        dmmRebateAccumulated[msg.sender] = accrued - amt;
        rebateClaimedInWindow += amt;
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

    function setTreasury(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        address prev = treasury;
        treasury = a;
        emit TreasurySet(prev, a);
    }

    function setDmmRebateBps(uint256 bps) external onlyOwner {
        dmmRebateBps = bps;
        emit DmmRebateBpsUpdated(bps);
    }

    /// @notice F-2026-17779: configure the rolling rebate budget circuit-breaker. `budgetPerWindow`
    ///         is the max rebate claimable per window; `windowDuration` is the window length in
    ///         seconds (e.g. 7 days). Setting `budgetPerWindow = 0` disables rebate claims entirely.
    function setRebateBudget(uint256 budgetPerWindow, uint256 windowDuration) external onlyOwner {
        rebateBudgetPerWindow = budgetPerWindow;
        rebateWindowDuration = windowDuration;
        // F-2026-17975: do NOT reset the rolling-window counters on every reconfiguration.
        // The old unconditional `rebateClaimedInWindow = 0` forgot rebates already claimed in the
        // active window, letting the per-window cap be exceeded within the same period. Only seed
        // `rebateWindowStart` the first time a budget is configured; thereafter `claimRebate` rolls
        // the window forward lazily once `windowDuration` elapses.
        if (rebateWindowStart == 0) {
            rebateWindowStart = block.timestamp;
        }
        emit RebateBudgetSet(budgetPerWindow, windowDuration);
    }

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
        emergencyProposals[proposalId] = EmergencyProposal({token: token, to: to, amount: amount, unlocksAt: unlocksAt});
        emit EmergencyWithdrawProposed(token, to, amount, unlocksAt);
    }

    function executeEmergencyWithdraw(bytes32 proposalId) external nonReentrant onlyOwner {
        EmergencyProposal memory p = emergencyProposals[proposalId];
        if (p.unlocksAt == 0) revert EmergencyProposalNotFound();
        if (block.timestamp < p.unlocksAt) revert EmergencyTimelockActive();
        delete emergencyProposals[proposalId];
        IERC20(p.token).safeTransfer(p.to, p.amount);
        emit EmergencyWithdrawExecuted(p.token, p.to, p.amount);
    }

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

    /// @notice Convenience getter for a holder's on-chain shares (F-2026-17777 provability).
    function sharesOf(uint256 marketId, address user, uint8 option) external view returns (uint256) {
        return userShares[marketId][user][option];
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
