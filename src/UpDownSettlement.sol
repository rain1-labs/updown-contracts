// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Burnable} from "./interfaces/IERC20Burnable.sol";
import {IQuoter} from "./interfaces/IQuoter.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

/// @title UpDownSettlement
/// @notice Single contract holding all UpDown markets as storage entries (no per-market proxy).
///
///         REMEDIATION V2 (Hacken full-recommendation pass, 2026-06-15): the trust model is moved
///         from custodial (Mongo = source of truth, relayer = custodian) to **non-custodial on
///         principal** (Polymarket parity). Positions are on-chain per-user share balances
///         (`userShares`); both the maker and the taker of every fill sign EIP-712 orders verified
///         on-chain; fees are capped by the taker's signed `maxFee` and pulled from the taker;
///         winners redeem trustlessly via `redeem` / `redeemFor`.
///
///         FEE BUYBACK-AND-BURN: `platformFee` no longer leaves for a treasury EOA on each fill. It
///         accrues to the round that earned it (`marketFeeAccrued`, aggregated in `feesAccrued`) and
///         `resolve` spends that round's bucket buying `buybackToken` (RAIN) on Uniswap V3 and
///         burning every unit received — the same swap-then-burn the RAIN protocol runs in
///         `LibUtils.swapAndBurn`, triggered at round end rather than at first claim. Fee USDT and
///         backing USDT are disjoint claims on one balance, so the global solvency statement becomes
///         `usdt.balanceOf(this) == Σ marketRetained + feesAccrued` and a burn can never spend the
///         collateral a winner is owed. The burn is wrapped end-to-end and degrades to a treasury
///         forward on any failure: resolution is what unlocks redemptions and must never be held
///         hostage to a DEX. The operator stays centralized only
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
    /// @notice Buyback-and-burn: caller of the manual retry is neither `buybackExecutor` nor the
    ///         owner. (The automatic burn inside `resolve` has no caller check — it runs on the
    ///         resolver's authority.)
    error OnlyBuybackExecutor();
    /// @notice Buyback-and-burn: `setBuybackRoute` was given a `path` that is not a well-formed
    ///         Uniswap V3 path (`token(20) [fee(3) token(20)]+`), or whose first hop is not `usdt`
    ///         / last hop is not `token`. Validating at configuration time means the burn can never
    ///         spend something other than the accrued fee or retire the wrong asset — the route is
    ///         storage, never a call argument.
    error InvalidBuybackPath();
    /// @notice Buyback-and-burn: `setBuybackRoute` was pointed at an address with no code. A silent
    ///         EOA "router" would make every `try` below decode garbage rather than fail cleanly.
    error NotAContract(address target);
    /// @notice Buyback-and-burn: slippage tolerance outside (0, 10000] bps.
    error InvalidSlippageBps(uint256 bps);
    /// @notice Buyback-and-burn: the manual retry named only rounds that are still in-flight,
    ///         already burned, or took no platform fee.
    error NothingToBuyback();
    /// @notice Buyback-and-burn: the round has not ended yet (`block.timestamp < endTime`), so its
    ///         platform fee is not final — a fill can still land and accrue more.
    error RoundNotEnded(uint256 marketId, uint256 endTime, uint256 nowTs);
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

    bytes32 public constant MINT_AUTH_TYPEHASH =
        keccak256("MintAuth(address account,uint256 market,uint8 action,uint256 amount,uint256 nonce,uint256 expiry)");

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

    // ── Fee buyback-and-burn ────────────────────────────────────────────
    /// @notice Platform fee accrued to a round's buyback bucket by a single fill. Emitted alongside
    ///         `FillSettled` / `MintMatched` so an indexer can reconstruct each round's burn budget
    ///         from events alone, without reading `marketFeeAccrued`.
    event PlatformFeeAccrued(uint256 indexed marketId, uint256 amount, uint256 marketTotal);
    /// @notice A resolved round's accrued platform fee was swapped for `buybackToken` and burned.
    ///         `tokenBurned` is what the swap returned and `IERC20Burnable.burn` then destroyed —
    ///         mirroring the RAIN protocol's own `RainTokenBurned(uint256 amountBurned)`.
    ///
    ///         `marketId` is carried because, unlike RAIN (where every pool is its own diamond, so
    ///         the emitting address identifies it), all UpDown markets live in THIS one contract —
    ///         without the id a burn could not be attributed to the round that funded it.
    ///
    ///         The USDT spent is deliberately NOT emitted: it is the sum of this round's
    ///         `PlatformFeeAccrued` events, so an indexer that wants the revenue figure or the
    ///         effective execution price can derive both.
    event FeesBoughtBackAndBurned(uint256 indexed marketId, uint256 tokenBurned);
    /// @notice The burn could not complete (route unset, quote reverted, swap reverted, or the token
    ///         rejected `burn`), so the round's value was forwarded to `treasury` instead of being
    ///         left stranded. `token` / `amount` say what was forwarded and at which stage — USDT if
    ///         the quote or swap failed, `buybackToken` if only the final `burn` failed. `reason` is
    ///         the raw revert data, for ops triage. Resolution itself always succeeds regardless.
    event BuybackFallbackToTreasury(uint256 indexed marketId, address indexed token, uint256 amount, bytes reason);
    /// @notice The burn failed AND no `treasury` is configured to forward to, so the round's fee was
    ///         left credited to its own bucket for a later `buybackAndBurn` retry. Value is never
    ///         stranded and `feesAccrued` stays exact.
    event BuybackDeferred(uint256 indexed marketId, uint256 amount, bytes reason);
    event BuybackRouteSet(address indexed token, address indexed router, address quoter, bytes path);
    event BuybackSlippageBpsSet(uint256 previous, uint256 current);
    event BuybackExecutorSet(address indexed previous, address indexed current);
    /// @notice F-2026-17772: complementary mint now records per-user shares for both legs.
    event ComplementaryMinted(uint256 indexed marketId, address indexed minter, uint256 amount);
    /// @notice F-2026-17772: complementary burn now gated on a complete set the holder owns.
    event ComplementaryBurned(uint256 indexed marketId, address indexed holder, uint256 amount);
    /// @notice F-2026-17778: trustless redemption. `to` is always the share owner — never the relayer.
    event Redeemed(uint256 indexed marketId, address indexed holder, uint8 winner, uint256 payout);
    /// @notice Complementary matching: two BUY orders on opposite options crossed by MINTING a fresh
    ///         complete set. `upCash` / `downCash` are what each buyer paid into backing (they sum to
    ///         `fillAmount`). `platformFee` / `makerFee` are the taker-paid fees — `makerFee` goes
    ///         peer-to-peer to the maker, `platformFee` is retained for the round's buyback; neither
    ///         touches backing — included so a mint-fill's full settlement, fee flow and all, is
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
    /// @notice Destination for DMM rebate claims (`claimRebate` pulls from here via `transferFrom`).
    ///         NOTE: as of the fee buyback-and-burn change this is no longer the sink for
    ///         `platformFee` — that now accrues inside this contract per round and is retired via
    ///         `buybackAndBurn`. The treasury is still required for rebates.
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

    // ── Fee buyback-and-burn ────────────────────────────────────────────
    /// @notice Per-round platform fee held by this contract, awaiting buyback. Credited by every
    ///         fee-bearing fill on `marketId`, zeroed when `buybackAndBurn` spends it. A round's
    ///         bucket is final once `block.timestamp >= endTime`, because both `_enterPosition` and
    ///         `_mintMatch` refuse to fill a market at or past its `endTime`.
    mapping(uint256 => uint256) public marketFeeAccrued;

    /// @notice Aggregate of every unspent `marketFeeAccrued` bucket. Fee USDT now sits in this
    ///         contract next to the backing collateral, so the global solvency invariant becomes
    ///         `usdt.balanceOf(this) == Σ marketRetained + feesAccrued`. Every backing path
    ///         (`mint` / `burn` / `redeem`) is untouched by fees and vice versa, so the two sums
    ///         never borrow from each other and winner redemptions can never be funded by, or
    ///         starved by, the burn budget.
    uint256 public feesAccrued;

    /// @notice The ERC-20 the protocol buys back and burns with its fee revenue (RAIN,
    ///         `0x25118290e6A5f4139381D072181157035864099d` on Arbitrum One). Must expose
    ///         `ERC20Burnable.burn`; zero until ops configures the route, during which time fees
    ///         simply accrue and every resolve forwards them to `treasury` instead.
    address public buybackToken;

    /// @notice Uniswap V3 `SwapRouter` used to convert accrued USDT fees into `buybackToken`
    ///         (`0xE592427A0AEce92De3Edee1F18E0157C05861564` on Arbitrum One).
    address public swapRouter;

    /// @notice Uniswap V3 `Quoter` used to price the buyback so `resolve` can compute its own
    ///         `amountOutMinimum` (`0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6` on Arbitrum One).
    ///         The burn is triggered by resolution, not by a user transaction, so there is no
    ///         caller to supply a trustworthy slippage floor — it has to be derived on-chain.
    address public quoter;

    /// @notice Encoded Uniswap V3 path for the buyback swap: `token(20) [fee(3) token(20)]+`,
    ///         constrained by `setBuybackRoute` to start at `usdt` and end at `buybackToken`. Held
    ///         as configuration (never a call argument) so the burn cannot be redirected. Typical
    ///         Arbitrum route is USDT → WETH → RAIN, matching the RAIN protocol's own
    ///         `LibUtils.swapAndBurn` hop through WETH.
    bytes public buybackPath;

    /// @notice Slippage tolerance applied to the quoter's answer, in bps of the quote. The floor
    ///         handed to the router is `quote * (10000 - buybackSlippageBps) / 10000`. Defaults to
    ///         300 (3%), matching the RAIN protocol's `(quotedAmount * 970) / 1000`.
    uint256 public buybackSlippageBps = 300;

    /// @notice Keeper permitted to call the manual `buybackAndBurn` retry (the owner may always
    ///         call it). It chooses only *which finished rounds* to retry — the route, the amount,
    ///         the slippage floor and the destination of the output are all fixed by storage, so a
    ///         compromised executor can never divert funds.
    address public buybackExecutor;

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
    constructor(IERC20 _usdt, address initialOwner) Ownable(initialOwner) EIP712("UpDown Exchange", "1") {
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
        return keccak256(abi.encode(MINT_AUTH_TYPEHASH, a.account, a.market, a.action, a.amount, a.nonce, a.expiry));
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
        _enterPosition(f);
    }

    /// @notice Batch-settle up to N `enterPosition` fills in ONE transaction. The guard modifiers
    ///         (`nonReentrant` / `whenNotPaused` / `onlyRelayer`) are evaluated ONCE for the whole
    ///         batch; every fill is validated and settled independently by `_enterPosition`, exactly
    ///         as the single-fill path does. All-or-nothing: if ANY fill reverts, the whole batch
    ///         reverts and no state persists — so the relayer bisects the group / falls back to the
    ///         single-fill entrypoint for the poison fill. Emits the same per-fill `PositionEntered`
    ///         / `FillSettled` events as the single path, so off-chain indexers need no change. This
    ///         is the throughput lever: collapsing the tx count (not the gas) is what lifts the
    ///         single-relayer settlement ceiling.
    function enterPositionBatch(FillInputs[] calldata fs) external nonReentrant whenNotPaused onlyRelayer {
        uint256 len = fs.length;
        for (uint256 i; i < len; ++i) {
            _enterPosition(fs[i]);
        }
    }

    /// @dev Body of a single `enterPosition` fill, extracted verbatim so the single-fill wrapper and
    ///      `enterPositionBatch` share one implementation. Carries NO guard modifiers — its callers
    ///      apply `nonReentrant` / `whenNotPaused` / `onlyRelayer` once. Depends only on `f` and
    ///      storage, never on `msg.sender`, so batching is behaviour-preserving.
    function _enterPosition(FillInputs calldata f) internal {
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
        // F-2026-17756: fees are pulled from the TAKER, not the buyer-by-direction. The platform
        // leg now lands in THIS contract and is booked against the round it was earned on, so that
        // once the round ends `buybackAndBurn` can retire exactly that round's revenue.
        if (f.platformFee > 0) {
            usdt.safeTransferFrom(taker, address(this), f.platformFee);
            _accruePlatformFee(mo.market, f.platformFee);
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

    /// @dev Books a fill's `platformFee` against the round that earned it. Shared by
    ///      `_enterPosition` and `_mintMatch` so both fee-bearing paths credit the same bucket.
    ///      The USDT itself has already been pulled into this contract by the caller.
    function _accruePlatformFee(uint256 marketId, uint256 amount) internal {
        uint256 marketTotal = marketFeeAccrued[marketId] + amount;
        marketFeeAccrued[marketId] = marketTotal;
        feesAccrued += amount;
        emit PlatformFeeAccrued(marketId, amount, marketTotal);
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
        _mintMatch(f);
    }

    /// @notice Batch-settle up to N `mintMatch` fills in ONE transaction — the demo's HOT settlement
    ///         path (complementary matching). The guard modifiers run ONCE for the whole batch; each
    ///         fill settles independently via `_mintMatch`. All-or-nothing (see `enterPositionBatch`
    ///         for the rationale and the relayer's bisect/fallback contract). Emits the same per-fill
    ///         `PositionEntered` / `MintMatched` events as the single path.
    function mintMatchBatch(FillInputs[] calldata fs) external nonReentrant whenNotPaused onlyRelayer {
        uint256 len = fs.length;
        for (uint256 i; i < len; ++i) {
            _mintMatch(fs[i]);
        }
    }

    /// @dev Body of a single `mintMatch` fill, extracted verbatim (no guard modifiers — callers apply
    ///      them once). Depends only on `f` and storage.
    function _mintMatch(FillInputs calldata f) internal {
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

        // ── Fees pulled from the taker. The platform leg stays here as this round's burn budget
        //     (tracked in `feesAccrued`, kept strictly disjoint from `marketRetained` backing);
        //     the maker rebate leg is still a direct peer-to-peer transfer. ──
        if (f.platformFee > 0) {
            usdt.safeTransferFrom(to.maker, address(this), f.platformFee);
            _accruePlatformFee(mo.market, f.platformFee);
        }
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
        emit MintMatched(
            mo.market, upBuyer, downBuyer, f.fillAmount, upCash, downCash, to.maker, f.platformFee, f.makerFee
        );
    }

    /// @notice Settle a MERGE match between two signed SELL orders on opposite options. `f.makerOrder`
    ///         is the resting SELL, `f.takerOrder` the aggressing SELL (either may be the UP leg). A
    ///         complete set is burned and the released $1/share is split by the two signed prices.
    ///         Zero-fee: both parties receive cash, so there is no taker inflow to source a fee from;
    ///         `platformFee` / `makerFee` MUST be zero.
    function mergeMatch(FillInputs calldata f) external nonReentrant whenNotPaused onlyRelayer {
        _mergeMatch(f);
    }

    /// @notice Batch-settle up to N `mergeMatch` fills in ONE transaction. The guard modifiers run
    ///         ONCE for the whole batch; each fill settles independently via `_mergeMatch`.
    ///         All-or-nothing (see `enterPositionBatch`). Emits the same per-fill `MergeMatched`
    ///         events as the single path.
    function mergeMatchBatch(FillInputs[] calldata fs) external nonReentrant whenNotPaused onlyRelayer {
        uint256 len = fs.length;
        for (uint256 i; i < len; ++i) {
            _mergeMatch(fs[i]);
        }
    }

    /// @dev Body of a single `mergeMatch` fill, extracted verbatim (no guard modifiers — callers
    ///      apply them once). Depends only on `f` and storage.
    function _mergeMatch(FillInputs calldata f) internal {
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
    function complementaryMint(
        uint256 marketId,
        uint256 amount,
        address minter,
        MintAuth calldata auth,
        bytes calldata sig
    ) external nonReentrant whenNotPaused onlyRelayer {
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
    function complementaryBurn(
        uint256 marketId,
        uint256 amount,
        address holder,
        MintAuth calldata auth,
        bytes calldata sig
    ) external nonReentrant whenNotPaused onlyRelayer {
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
        if (auth.account != account || auth.market != marketId || auth.action != action || auth.amount != amount) {
            revert InvalidMintAuth();
        }
        if (block.timestamp > auth.expiry) revert InvalidMintAuth();
        if (mintAuthNonceUsed[account][auth.nonce]) revert MintAuthNonceUsed(account, auth.nonce);
        if (!SignatureChecker.isValidSignatureNow(account, _hashTypedDataV4(hashMintAuth(auth)), sig)) {
            revert InvalidMintAuth();
        }
        mintAuthNonceUsed[account][auth.nonce] = true;
    }

    // ── Resolution & trustless redemption (F-2026-17778) ────────────────

    /// @dev `nonReentrant` (added with the fee buyback): resolution now makes external calls into
    ///      the Uniswap quoter/router and the burn token. None of them can re-enter a settlement
    ///      path, but the guard makes that structural rather than a property of today's route.
    function resolve(uint256 marketId, int256 settlementPrice, uint8 winner)
        external
        nonReentrant
        onlyResolver
        whenNotPaused
    {
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

        // ── Round end ⇒ buy back and burn this round's fee revenue. The bucket is already final
        //     here: both `_enterPosition` and `_mintMatch` reject a fill at or past `endTime`, and
        //     `resolve` itself requires `block.timestamp >= endTime`. `_swapAndBurnRoundFees` never
        //     reverts — every failure path forwards to `treasury` or re-credits the bucket — so a
        //     dry pool, a stale route, or a paused burn token can never block a resolution and
        //     strand user redemptions behind it. ──
        _swapAndBurnRoundFees(marketId);
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
        uint256 remaining =
            rebateBudgetPerWindow > rebateClaimedInWindow ? rebateBudgetPerWindow - rebateClaimedInWindow : 0;

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

    // ── Fee buyback-and-burn ────────────────────────────────────────────

    /// @notice Retry the buyback for rounds whose automatic burn inside `resolve` fell back or was
    ///         deferred — a route that was not configured yet, a quoter/router revert, a dry pool,
    ///         or a round that ended but was never resolved (its bucket is final all the same, so
    ///         its fee is not held hostage to resolution).
    /// @dev    Reverts only on caller/eligibility errors. Per-round burn failures stay non-reverting
    ///         exactly as in `resolve`, so one dead round cannot block the rest of the batch.
    /// @param  marketIds finished rounds to retry. Duplicates are harmless (the second read is 0).
    function buybackAndBurn(uint256[] calldata marketIds) external nonReentrant whenNotPaused {
        if (msg.sender != buybackExecutor && msg.sender != owner()) revert OnlyBuybackExecutor();

        uint256 len = marketIds.length;
        uint256 total;
        for (uint256 i; i < len; ++i) {
            uint256 marketId = marketIds[i];
            Market storage m = markets[marketId];
            if (m.startTime == 0) revert MarketNotOpen();
            if (block.timestamp < uint256(m.endTime)) {
                revert RoundNotEnded(marketId, uint256(m.endTime), block.timestamp);
            }
            total += marketFeeAccrued[marketId];
            _swapAndBurnRoundFees(marketId);
        }
        if (total == 0) revert NothingToBuyback();
    }

    /// @notice Sum of the still-unburned platform fee across `marketIds`. Off-chain helper for
    ///         picking the batch to hand `buybackAndBurn`.
    function pendingBuyback(uint256[] calldata marketIds) external view returns (uint256 total) {
        uint256 len = marketIds.length;
        for (uint256 i; i < len; ++i) {
            total += marketFeeAccrued[marketIds[i]];
        }
    }

    /// @dev The buyback itself: spend one round's accrued USDT fee on `buybackToken` and destroy
    ///      every unit received. Modelled on the RAIN protocol's `LibUtils.swapAndBurn` (which runs
    ///      on first claim); here the trigger is round resolution instead.
    ///
    ///      MUST NOT REVERT. It sits on the resolution path, and a revert there would leave the
    ///      round unresolved — freezing winners' redemptions over a DEX problem. Every external
    ///      call is therefore wrapped, and each failure stage forwards the value it is holding to
    ///      `treasury` (or, with no treasury set, re-credits the round's bucket for a later retry).
    ///      The bucket is zeroed BEFORE any external call, so a re-entrant path finds nothing left
    ///      to spend twice.
    function _swapAndBurnRoundFees(uint256 marketId) internal {
        uint256 amountIn = marketFeeAccrued[marketId];
        if (amountIn == 0) return;
        marketFeeAccrued[marketId] = 0;
        feesAccrued -= amountIn;

        address token = buybackToken;
        address router = swapRouter;
        address quoterAddr = quoter;
        if (token == address(0) || router == address(0) || quoterAddr == address(0)) {
            _buybackFallback(marketId, address(usdt), amountIn, "");
            return;
        }

        bytes memory path = buybackPath;

        // ── Slippage floor, quoted on-chain. Resolution has no user-supplied `amountOutMinimum` to
        //     lean on, so the floor is derived here: `quote * (10000 - buybackSlippageBps) / 10000`,
        //     the same shape as RAIN's `(quotedAmount * 970) / 1000`. A zero quote means the route
        //     has no depth at this size — swapping against it would hand the pool the fee for
        //     nothing, so bail to the treasury instead of executing an unprotected swap. ──
        uint256 minOut;
        try IQuoter(quoterAddr).quoteExactInput(path, amountIn) returns (uint256 quoted) {
            minOut = (quoted * (10000 - buybackSlippageBps)) / 10000;
        } catch (bytes memory reason) {
            _buybackFallback(marketId, address(usdt), amountIn, reason);
            return;
        }
        if (minOut == 0) {
            _buybackFallback(marketId, address(usdt), amountIn, "");
            return;
        }

        // `deadline: block.timestamp` — the swap is atomic with the resolution that triggered it,
        // so there is no pending-tx window for the deadline to protect against.
        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path: path,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: minOut
        });

        usdt.forceApprove(router, amountIn);

        uint256 amountOut;
        try ISwapRouter(router).exactInput(params) returns (uint256 out) {
            amountOut = out;
        } catch (bytes memory reason) {
            // Leave no standing allowance behind a failed swap.
            usdt.forceApprove(router, 0);
            _buybackFallback(marketId, address(usdt), amountIn, reason);
            return;
        }
        // `exactInput` consumes the whole allowance on success; zero it anyway so a partially
        // consuming router cannot leave this contract approving a spender indefinitely.
        usdt.forceApprove(router, 0);

        // ── Burn. `IERC20Burnable.burn` is required rather than a dead-address transfer: the
        //     protocol reports burned supply, and a token that cannot actually burn must surface as
        //     a fallback event rather than silently park tokens at `0x…dEaD`. ──
        try IERC20Burnable(token).burn(amountOut) {
            emit FeesBoughtBackAndBurned(marketId, amountOut);
        } catch (bytes memory reason) {
            _buybackFallback(marketId, token, amountOut, reason);
        }
    }

    /// @dev Failure sink for `_swapAndBurnRoundFees`. `token` is USDT when the quote or the swap
    ///      failed (the fee never left this contract) and `buybackToken` when only the final `burn`
    ///      failed (the swap already happened). Forwards to `treasury`; with no treasury configured
    ///      the USDT case re-credits the round's bucket so `feesAccrued` stays exact and the value
    ///      remains retrievable by a later `buybackAndBurn`.
    function _buybackFallback(uint256 marketId, address token, uint256 amount, bytes memory reason) internal {
        if (amount == 0) return;

        // The forward itself must not revert. Real USDT can blacklist an address, so a
        // `safeTransfer` here would hand a blacklisted treasury the power to brick every
        // resolution — and with it every redemption. Fall through to the deferral instead.
        address dest = treasury;
        if (dest != address(0) && _tryTransfer(token, dest, amount)) {
            emit BuybackFallbackToTreasury(marketId, token, amount, reason);
            return;
        }

        if (token == address(usdt)) {
            marketFeeAccrued[marketId] += amount;
            feesAccrued += amount;
        }
        // The bought-back-but-unburnable case simply leaves `buybackToken` sitting here; it is not
        // USDT, so no accounting tracks it and the owner's emergency withdraw can recover it.
        emit BuybackDeferred(marketId, amount, reason);
    }

    /// @dev `SafeERC20.safeTransfer` semantics without the revert — returns false instead. Accepts
    ///      both standard (bool-returning) and non-standard (void) ERC-20s, and treats malformed
    ///      return data as failure. Used only on the buyback's failure path, where reverting would
    ///      defeat the entire point of that path.
    function _tryTransfer(address token, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) return false;
        if (ret.length == 0) return token.code.length > 0;
        return ret.length >= 32 && abi.decode(ret, (bool));
    }

    // ── Admin ───────────────────────────────────────────────────────────

    /// @notice Configure the buyback route in one shot: the token to retire, the Uniswap V3 router
    ///         and quoter to price/execute against, and the encoded V3 path connecting them.
    /// @dev    All four move together because they only make sense together — a path is meaningless
    ///         without the router it encodes hops for, and a token swap that does not END at
    ///         `token` would burn the wrong asset. The path is validated here rather than at burn
    ///         time so a misconfiguration surfaces as a failed admin tx, not as a silent stream of
    ///         `BuybackFallbackToTreasury` events during resolution.
    ///
    ///         Arbitrum One production values:
    ///           token   = 0x25118290e6A5f4139381D072181157035864099d  (RAIN)
    ///           router  = 0xE592427A0AEce92De3Edee1F18E0157C05861564  (Uniswap V3 SwapRouter)
    ///           quoter  = 0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6  (Uniswap V3 Quoter)
    ///           path    = abi.encodePacked(USDT, usdtWethFee, WETH, uint24(100), RAIN)
    ///                     (RAIN/WETH is the 0.01% tier, per the RAIN protocol's own constants)
    function setBuybackRoute(address token, address router, address quoterAddr, bytes calldata path)
        external
        onlyOwner
    {
        if (token == address(0) || router == address(0) || quoterAddr == address(0)) revert ZeroAddress();
        // A codeless target would make every `try` in `_swapAndBurnRoundFees` decode empty
        // returndata, which reverts UNCAUGHT and would put the revert back on the resolve path.
        if (token.code.length == 0) revert NotAContract(token);
        if (router.code.length == 0) revert NotAContract(router);
        if (quoterAddr.code.length == 0) revert NotAContract(quoterAddr);
        _validateBuybackPath(path, token);

        buybackToken = token;
        swapRouter = router;
        quoter = quoterAddr;
        buybackPath = path;
        emit BuybackRouteSet(token, router, quoterAddr, path);
    }

    /// @notice Set the slippage tolerance the burn allows against the quoter's answer, in bps.
    ///         `10000` disables protection entirely and is rejected — resolution executes the swap
    ///         unattended, so an unbounded floor is never the right setting.
    function setBuybackSlippageBps(uint256 bps) external onlyOwner {
        if (bps == 0 || bps >= 10000) revert InvalidSlippageBps(bps);
        uint256 prev = buybackSlippageBps;
        buybackSlippageBps = bps;
        emit BuybackSlippageBpsSet(prev, bps);
    }

    /// @notice Set (or clear, with `address(0)`) the keeper allowed to call `buybackAndBurn`. The
    ///         owner can always call it, so clearing this only narrows the surface.
    function setBuybackExecutor(address a) external onlyOwner {
        address prev = buybackExecutor;
        buybackExecutor = a;
        emit BuybackExecutorSet(prev, a);
    }

    /// @dev A Uniswap V3 path is `token(20) [fee(3) token(20)]+`: 43 bytes for one hop, +23 per
    ///      extra hop. Pinning the first hop to `usdt` and the last to `token` is what makes the
    ///      route safe to run unattended — the swap can only ever spend the fee asset and can only
    ///      ever produce the asset that `burn` is then called on.
    function _validateBuybackPath(bytes calldata path, address token) internal view {
        uint256 len = path.length;
        if (len < 43 || (len - 20) % 23 != 0) revert InvalidBuybackPath();
        if (address(bytes20(path[0:20])) != address(usdt)) revert InvalidBuybackPath();
        if (address(bytes20(path[len - 20:len])) != token) revert InvalidBuybackPath();
    }

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
