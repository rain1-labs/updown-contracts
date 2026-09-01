// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UpDownSettlement} from "../src/UpDownSettlement.sol";
import {IQuoter} from "../src/interfaces/IQuoter.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";
import {IERC20Burnable} from "../src/interfaces/IERC20Burnable.sol";
import {
    ARBITRUM_ONE,
    QUOTER,
    RAIN_TOKEN as RAIN_DEFAULT,
    RAIN_WETH_FEE,
    SWAP_ROUTER,
    USDT as USDT_DEFAULT,
    USDT_WETH_FEE,
    WETH
} from "./utils/Constants.sol";
import {ForkSafeWallet} from "./utils/ForkSafeWallet.sol";

/// @title Fee buyback-and-burn proof suite.
/// @notice The platform's fee revenue no longer leaves for a treasury EOA on each fill. It accrues
///         inside the settlement, booked to the round that earned it, and is spent buying RAIN on
///         Uniswap V3 and burning it the moment that round resolves — the same swap-then-burn the
///         RAIN protocol runs in `LibUtils.swapAndBurn`, moved from "first claim" to "round end"
///         because an UpDown round's fee is already final at `endTime` (fills revert there).
///
///         ── Run this FORKED ──
///         Structured like `rain-contracts/test/RainPool.t.sol`: no mock router, no mock quoter, no
///         mock RAIN. Every counterparty is the REAL Arbitrum One contract, and balances come from
///         `deal`. A mock can only ever prove our own wiring; it cannot prove that RAIN implements
///         `burn`, that the USDT → WETH → RAIN route exists at the fee tiers `Deploy.s.sol` encodes,
///         or that the quoter-derived floor is satisfiable on that route — which is precisely the
///         half of this feature that lives outside our code.
///
///             npm run test:buyback
///             forge test --fork-url https://arb1.arbitrum.io/rpc --match-contract FeeBuybackBurn
///
///         Unforked, every test self-skips (the audited default `forge test` stays green).
///
///         Failure branches are driven with `vm.mockCallRevert` / `vm.mockCall` against those same
///         real addresses, so a test for "the router reverted" exercises the real settlement code
///         path with only the one external answer replaced.
///
///         Two properties carry the design, and most of this file exists to pin them:
///
///         1. FEES AND BACKING NEVER MIX. `feesAccrued` and `marketRetained` are disjoint claims on
///            the same USDT balance. A burn spends only the former, so it can never consume the
///            collateral a winner is owed — nor be starved by it.
///         2. THE BURN CAN NEVER BLOCK A RESOLUTION. Resolution is what unlocks redemptions, so a
///            dry pool, an unset route, a reverting quoter or a token that refuses to burn must all
///            degrade to a treasury forward, never to a revert. Every failure branch is exercised.
contract FeeBuybackBurnTest is Test {
    bytes32 internal constant PAIR = keccak256("BTC/USD");
    uint8 internal constant UP = 1;
    uint8 internal constant DOWN = 2;
    uint8 internal constant BUY = 0;
    uint8 internal constant SELL = 1;

    /// @dev USDT is 6 decimals on Arbitrum. 5 USDT is a realistic 5-minute round's fee; 100 USDT a
    ///      realistic complete-set size.
    uint256 internal constant ROUND_FEE = 5e6;
    uint256 internal constant SET_SIZE = 100e6;

    UpDownSettlement internal s;

    /// @dev Which chain's tokens to run against. Defaults to the Arbitrum One production pair;
    ///      point them at the dev pair to prove a dev round burns dev RAIN through the very same
    ///      code path. The dev tokens live in the SAME pools at the SAME fee tiers, so nothing else
    ///      changes — see `rain-contracts/script/WhiteListDevNewToken.s.sol`, which encodes the
    ///      identical `USDT --500--> WETH --100--> RAIN` route for dev.
    ///
    ///          BUYBACK_TEST_USDT=0xCa4f…25F4 BUYBACK_TEST_RAIN=0x4397…38DA npm run test:buyback
    address internal usdtAddr;
    address internal rainAddr;

    IERC20 internal usdt;
    IERC20 internal rain;

    address internal owner = address(this);
    address internal autocycler = makeAddr("autocycler");
    address internal resolver = makeAddr("resolver");
    address internal relayer = makeAddr("relayer");
    address internal treasury = makeAddr("treasury");
    address internal executor = makeAddr("buyback-executor");

    Vm.Wallet internal alice;
    Vm.Wallet internal bob;

    bool internal _skipUnforked;
    uint256 internal nonceSeed;

    /// @dev The settlement's USDT balance at deploy time. NOT zero on a fork: Foundry's
    ///      deterministic CREATE address already holds a small USDT balance on Arbitrum One,
    ///      because someone sent tokens to it on mainnet. Assertions are deltas against this —
    ///      which doubles as evidence that the settlement's accounting is driven by its own
    ///      `marketRetained` / `feesAccrued` ledger rather than by `balanceOf`, so a donated
    ///      balance is inert: neither burned as fee revenue nor payable as backing.
    uint256 internal settlementUsdt0;

    // Events under assertion (mirrored from the settlement).
    event PlatformFeeAccrued(uint256 indexed marketId, uint256 amount, uint256 marketTotal);
    event FeesBoughtBackAndBurned(uint256 indexed marketId, uint256 tokenBurned);
    event BuybackFallbackToTreasury(uint256 indexed marketId, address indexed token, uint256 amount, bytes reason);
    event BuybackDeferred(uint256 indexed marketId, uint256 amount, bytes reason);

    function setUp() public {
        // Forked via `--fork-url` (rain-contracts style) rather than `vm.createSelectFork`, so one
        // flag runs the whole suite against the live chain.
        if (block.chainid != ARBITRUM_ONE) {
            _skipUnforked = true;
            return;
        }

        usdtAddr = vm.envOr("BUYBACK_TEST_USDT", USDT_DEFAULT);
        rainAddr = vm.envOr("BUYBACK_TEST_RAIN", RAIN_DEFAULT);
        usdt = IERC20(usdtAddr);
        rain = IERC20(rainAddr);
        s = _newSettlement();
        s.setBuybackRoute(rainAddr, SWAP_ROUTER, QUOTER, _path());
        settlementUsdt0 = usdt.balanceOf(address(s));

        alice = _fundedWallet("alice");
        bob = _fundedWallet("bob");
    }

    /// @dev Every test begins with this. Foundry has no suite-level skip, and a silent pass on an
    ///      unforked run would be worse than a loud skip.
    modifier forked() {
        if (_skipUnforked) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    /// @dev The exact path `Deploy.s.sol` composes for production: USDT → WETH → RAIN.
    function _path() internal view returns (bytes memory) {
        return abi.encodePacked(usdtAddr, USDT_WETH_FEE, WETH, RAIN_WETH_FEE, rainAddr);
    }

    /// @dev A settlement wired for markets and fills, with no buyback route yet.
    function _newSettlement() internal returns (UpDownSettlement n) {
        n = new UpDownSettlement(usdt, owner);
        n.setAutocycler(autocycler);
        n.setResolver(resolver);
        n.setRelayer(relayer);
        n.setTreasury(treasury);
        n.setBuybackExecutor(executor);
    }

    function _fundedWallet(string memory name) internal returns (Vm.Wallet memory w) {
        w = ForkSafeWallet.derive(name);
        deal(usdtAddr, w.addr, 1_000_000e6);
        _approve(w, s);
    }

    function _approve(Vm.Wallet memory w, UpDownSettlement target) internal {
        vm.prank(w.addr);
        usdt.approve(address(target), type(uint256).max);
    }

    function _market() internal returns (uint256 mid) {
        vm.prank(autocycler);
        mid = s.createMarket(PAIR, 3600, 50_000e8);
    }

    function _order(
        Vm.Wallet memory w,
        uint256 mid,
        uint8 side,
        uint256 price,
        uint256 amount,
        uint256 maxFee,
        uint256 nonce
    ) internal view returns (UpDownSettlement.Order memory) {
        return UpDownSettlement.Order({
            maker: w.addr,
            market: mid,
            option: UP,
            side: side,
            orderType: 0,
            price: price,
            amount: amount,
            maxFee: maxFee,
            nonce: nonce,
            expiry: block.timestamp + 3600
        });
    }

    function _sign(Vm.Wallet memory w, UpDownSettlement.Order memory o) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(w.privateKey, s.orderDigest(o));
        return abi.encodePacked(r, ss, v);
    }

    /// @dev Builds a fee-bearing fill: alice sells her UP leg to bob, and bob (the taker) pays
    ///      `platformFee`. Returned rather than executed — it makes external `orderDigest` calls
    ///      while signing, so a test that wants `vm.expectEmit` on `enterPosition` must get the
    ///      signing out of the way first or the cheatcode is consumed by the digest call.
    function _buildFill(uint256 mid, uint256 platformFee) internal returns (UpDownSettlement.FillInputs memory) {
        UpDownSettlement.Order memory makerO = _order(alice, mid, SELL, 6000, SET_SIZE, 0, ++nonceSeed);
        UpDownSettlement.Order memory takerO = _order(bob, mid, BUY, 6000, SET_SIZE, platformFee, ++nonceSeed);

        return UpDownSettlement.FillInputs({
            makerOrder: makerO,
            makerSignature: _sign(alice, makerO),
            takerOrder: takerO,
            takerSignature: _sign(bob, takerO),
            fillAmount: SET_SIZE,
            platformFee: platformFee,
            makerFee: 0
        });
    }

    /// @dev Mint alice a complete set, then run one fee-bearing fill against it.
    function _fillWithFee(uint256 mid, uint256 platformFee) internal returns (uint256) {
        vm.prank(alice.addr);
        s.mint(mid, SET_SIZE);

        UpDownSettlement.FillInputs memory f = _buildFill(mid, platformFee);
        vm.prank(relayer);
        s.enterPosition(f);
        return platformFee;
    }

    function _endRound(uint256 mid) internal {
        vm.warp(uint256(s.getMarket(mid).endTime));
    }

    function _resolve(uint256 mid) internal {
        vm.prank(resolver);
        s.resolve(mid, 51_000e8, UP);
    }

    /// @dev Contract-held USDT above whatever was already sitting at the deploy address.
    function _heldUsdt() internal view returns (uint256) {
        return usdt.balanceOf(address(s)) - settlementUsdt0;
    }

    // ── 1. The happy path, against the real route ───────────────────────

    /// The whole feature end to end on the live chain: a round's fee accrues, resolution swaps it
    /// through the production path, and RAIN's real total supply actually goes down.
    ///
    /// This is the assertion a mock cannot make. If RAIN did not implement `burn`, or the route did
    /// not exist at the configured tiers, `burned` would be 0 and the fee would sit in the treasury.
    function test_resolveBurnsRealRainThroughTheProductionRoute() public forked {
        uint256 mid = _market();
        uint256 fee = _fillWithFee(mid, ROUND_FEE);

        assertEq(s.marketFeeAccrued(mid), fee, "fee booked to the round");
        assertEq(s.feesAccrued(), fee, "aggregate tracks it");
        assertEq(usdt.balanceOf(treasury), 0, "treasury is no longer the fee sink");

        uint256 supplyBefore = rain.totalSupply();
        _endRound(mid);
        _resolve(mid);

        uint256 burned = supplyBefore - rain.totalSupply();
        console.log("USDT spent:       ", fee);
        console.log("RAIN burned (wei):", burned);

        assertGt(burned, 0, "real RAIN supply fell -- the token burns and the route fills");
        assertEq(s.marketFeeAccrued(mid), 0, "round's bucket spent");
        assertEq(s.feesAccrued(), 0, "aggregate cleared");
        assertEq(rain.balanceOf(address(s)), 0, "settlement kept no RAIN");
        assertEq(usdt.balanceOf(treasury), 0, "no fallback was taken");
    }

    /// The burn spends fee money only. A resolved round's collateral must still be sitting there,
    /// untouched, for the winner to redeem — property (1) at its sharpest, through a real swap.
    function test_burnNeverTouchesBacking() public forked {
        uint256 mid = _market();
        uint256 fee = _fillWithFee(mid, ROUND_FEE);

        assertEq(s.marketRetained(mid), SET_SIZE, "one minted set is backed");
        assertEq(_heldUsdt(), SET_SIZE + fee, "contract holds backing + fee");

        _endRound(mid);
        _resolve(mid);

        assertEq(s.marketRetained(mid), SET_SIZE, "backing survives the burn untouched");
        assertEq(_heldUsdt(), SET_SIZE, "only the fee left; backing intact");

        vm.prank(bob.addr);
        assertEq(s.redeem(mid), SET_SIZE, "winner redeems the full backing after the burn");

        // The pre-existing donated balance is untouched by all of it — never burned as fee revenue,
        // never paid out as backing.
        assertEq(usdt.balanceOf(address(s)), settlementUsdt0, "donated balance is inert");
        assertEq(s.feesAccrued(), 0);
        assertEq(s.marketRetained(mid), 0);
    }

    /// Fees are per-round, not a global pot: resolving round A must not spend round B's budget.
    function test_feeBucketsAreIsolatedPerRound() public forked {
        uint256 midA = _market();
        uint256 midB = _market();
        _fillWithFee(midA, ROUND_FEE);
        _fillWithFee(midB, ROUND_FEE * 2);

        assertEq(s.marketFeeAccrued(midA), ROUND_FEE, "A's own fee");
        assertEq(s.marketFeeAccrued(midB), ROUND_FEE * 2, "B's own fee");
        assertEq(s.feesAccrued(), ROUND_FEE * 3, "aggregate is the sum");

        _endRound(midA);
        vm.expectEmit(true, false, false, false, address(s));
        emit FeesBoughtBackAndBurned(midA, 0); // amount unchecked; the live route prices it
        _resolve(midA);

        assertEq(s.marketFeeAccrued(midB), ROUND_FEE * 2, "B's budget untouched");
        assertEq(s.feesAccrued(), ROUND_FEE * 2, "aggregate dropped by exactly A's fee");

        _endRound(midB);
        _resolve(midB);
        assertEq(s.feesAccrued(), 0, "both budgets retired");
    }

    /// Several fills in one round pool into a single burn at resolution.
    function test_multipleFillsAccrueThenBurnOnce() public forked {
        uint256 mid = _market();
        _fillWithFee(mid, ROUND_FEE);
        _fillWithFee(mid, ROUND_FEE);

        assertEq(s.marketFeeAccrued(mid), ROUND_FEE * 2, "fills accumulate into one bucket");

        _endRound(mid);
        _resolve(mid);
        assertEq(s.feesAccrued(), 0, "one burn for the round's whole fee");
    }

    /// The accrual event carries the running per-round total, so an indexer can rebuild each
    /// round's burn budget from logs alone.
    function test_platformFeeAccruedEventCarriesRunningTotal() public forked {
        uint256 mid = _market();
        _fillWithFee(mid, ROUND_FEE);

        vm.prank(alice.addr);
        s.mint(mid, SET_SIZE);
        UpDownSettlement.FillInputs memory f = _buildFill(mid, ROUND_FEE);

        vm.expectEmit(true, false, false, true, address(s));
        emit PlatformFeeAccrued(mid, ROUND_FEE, ROUND_FEE * 2);
        vm.prank(relayer);
        s.enterPosition(f);
    }

    /// A round that took no fee resolves without touching the router at all.
    function test_resolveWithNoFeeIsANoOp() public forked {
        uint256 mid = _market();
        uint256 supplyBefore = rain.totalSupply();
        _endRound(mid);
        _resolve(mid);

        assertEq(rain.totalSupply(), supplyBefore, "nothing bought, nothing burned");
        assertEq(s.feesAccrued(), 0);
    }

    // ── 2. The route itself ─────────────────────────────────────────────

    /// The production path and fee tiers must actually quote. A zero or reverting quote here means
    /// `Deploy.s.sol` would ship a route that takes the treasury fallback on every single round —
    /// the failure this test exists to catch before it reaches mainnet.
    function test_productionPathQuotesNonZero() public forked {
        console.log("route USDT:", usdtAddr);
        console.log("route RAIN:", rainAddr);
        uint256 quoted = IQuoter(QUOTER).quoteExactInput(_path(), ROUND_FEE);
        console.log("Quote for 5 USDT (RAIN wei):", quoted);
        assertGt(quoted, 0, "USDT -> WETH -> RAIN quotes at the configured fee tiers");

        uint256 floor = (quoted * (10000 - s.buybackSlippageBps())) / 10000;
        assertGt(floor, 0, "slippage floor is a real bound, not a no-op");
    }

    /// Depth check: a whole day of one pair's 5-minute rounds burned at once still fills within
    /// tolerance. Ops information about how often to burn, not a correctness property — so the
    /// impact is logged and only the quote's existence is asserted.
    function test_routeHasDepthForADaysFees() public forked {
        uint256 daysFees = ROUND_FEE * 288;
        uint256 quotedLarge = IQuoter(QUOTER).quoteExactInput(_path(), daysFees);
        assertGt(quotedLarge, 0, "a day's fees still quote");

        uint256 unitSmall = (IQuoter(QUOTER).quoteExactInput(_path(), ROUND_FEE) * 1e18) / ROUND_FEE;
        uint256 unitLarge = (quotedLarge * 1e18) / daysFees;
        console.log("RAIN per USDT, 5 USDT size:   ", unitSmall);
        console.log("RAIN per USDT, 1440 USDT size:", unitLarge);
        if (unitSmall > unitLarge) {
            console.log("price impact (bps):", ((unitSmall - unitLarge) * 10000) / unitSmall);
        }
    }

    // ── 3. The burn can never block a resolution ────────────────────────

    /// No route configured yet: the fee is forwarded to the treasury and the round still resolves.
    function test_unconfiguredRoute_forwardsToTreasuryAndStillResolves() public forked {
        s = _newSettlement(); // no setBuybackRoute
        settlementUsdt0 = usdt.balanceOf(address(s));
        _approve(alice, s);
        _approve(bob, s);

        uint256 mid = _market();
        _fillWithFee(mid, ROUND_FEE);
        _endRound(mid);
        _resolve(mid);

        assertTrue(s.getMarket(mid).resolved, "resolution succeeded without a route");
        assertEq(usdt.balanceOf(treasury), ROUND_FEE, "fee forwarded to treasury instead of burned");
        assertEq(s.feesAccrued(), 0, "accounting cleared");
        assertEq(s.marketFeeAccrued(mid), 0);
    }

    /// A reverting quoter must not take the resolution down with it.
    function test_quoterRevert_fallsBackToTreasury() public forked {
        uint256 mid = _market();
        _fillWithFee(mid, ROUND_FEE);
        _endRound(mid);

        vm.mockCallRevert(QUOTER, abi.encodeWithSelector(IQuoter.quoteExactInput.selector), "quote failed");
        _resolve(mid);

        assertTrue(s.getMarket(mid).resolved, "resolved despite the quoter reverting");
        assertEq(usdt.balanceOf(treasury), ROUND_FEE, "fee forwarded, not stranded");
        assertEq(s.feesAccrued(), 0);
    }

    /// A reverting router (dry pool) likewise degrades, and must not leave a standing USDT
    /// allowance behind for the failed spender.
    function test_swapRevert_fallsBackAndLeavesNoAllowance() public forked {
        uint256 mid = _market();
        _fillWithFee(mid, ROUND_FEE);
        _endRound(mid);

        vm.mockCallRevert(SWAP_ROUTER, abi.encodeWithSelector(ISwapRouter.exactInput.selector), "swap failed");
        _resolve(mid);

        assertTrue(s.getMarket(mid).resolved, "resolved despite the swap reverting");
        assertEq(usdt.balanceOf(treasury), ROUND_FEE, "fee forwarded");
        assertEq(usdt.allowance(address(s), SWAP_ROUTER), 0, "failed swap left no allowance");
        assertEq(s.feesAccrued(), 0);
    }

    /// A route with no depth quotes zero. Swapping into it would hand the pool the fee for nothing,
    /// so the burn bails out rather than executing a swap with a zero (i.e. absent) floor.
    function test_zeroQuote_refusesTheUnprotectedSwap() public forked {
        uint256 mid = _market();
        _fillWithFee(mid, ROUND_FEE);
        _endRound(mid);

        vm.mockCall(QUOTER, abi.encodeWithSelector(IQuoter.quoteExactInput.selector), abi.encode(uint256(0)));
        uint256 supplyBefore = rain.totalSupply();
        _resolve(mid);

        assertEq(rain.totalSupply(), supplyBefore, "no swap attempted against a dry route");
        assertEq(usdt.balanceOf(treasury), ROUND_FEE, "fee forwarded instead");
    }

    /// A token that refuses to burn: the RAIN was already bought with real USDT, so it is the RAIN
    /// — not the USDT — that gets forwarded, and the round still resolves.
    function test_burnRevert_forwardsTheBoughtTokenToTreasury() public forked {
        uint256 mid = _market();
        _fillWithFee(mid, ROUND_FEE);
        _endRound(mid);

        vm.mockCallRevert(rainAddr, abi.encodeWithSelector(IERC20Burnable.burn.selector), "burn disabled");
        _resolve(mid);

        assertTrue(s.getMarket(mid).resolved, "resolved despite the token refusing to burn");
        assertGt(rain.balanceOf(treasury), 0, "the bought RAIN went to the treasury");
        assertEq(rain.balanceOf(address(s)), 0, "settlement retains none of it");
        assertEq(usdt.balanceOf(treasury), 0, "the USDT was genuinely spent on the swap");
        assertEq(s.feesAccrued(), 0);
    }

    /// The slippage floor is real: quote high enough that the live pool cannot meet the floor, and
    /// the REAL router rejects the fill ("Too little received"). The settlement degrades rather
    /// than eating the loss — this is the sandwich-protection path.
    function test_slippageFloorIsEnforcedByTheRealRouter() public forked {
        uint256 mid = _market();
        _fillWithFee(mid, ROUND_FEE);
        _endRound(mid);

        uint256 honest = IQuoter(QUOTER).quoteExactInput(_path(), ROUND_FEE);
        // 10x the honest quote → a floor no real fill can reach.
        vm.mockCall(QUOTER, abi.encodeWithSelector(IQuoter.quoteExactInput.selector), abi.encode(honest * 10));

        uint256 supplyBefore = rain.totalSupply();
        _resolve(mid);

        assertEq(rain.totalSupply(), supplyBefore, "no RAIN bought at the bad price");
        assertEq(usdt.balanceOf(treasury), ROUND_FEE, "unfillable floor rejected, fee forwarded");
    }

    /// A treasury that cannot receive is the nastiest version of the problem: real USDT can
    /// blacklist an address, and a bare `safeTransfer` on the fallback path would let a blacklisted
    /// treasury brick every resolution — and every redemption behind it. It degrades to a deferral.
    function test_unreceivableTreasury_defersInsteadOfBrickingResolution() public forked {
        uint256 mid = _market();
        _fillWithFee(mid, ROUND_FEE);
        _endRound(mid);

        vm.mockCallRevert(QUOTER, abi.encodeWithSelector(IQuoter.quoteExactInput.selector), "quote failed");
        vm.mockCallRevert(usdtAddr, abi.encodeCall(IERC20.transfer, (treasury, ROUND_FEE)), "blacklisted");

        vm.expectEmit(true, false, false, false, address(s));
        emit BuybackDeferred(mid, ROUND_FEE, "");
        _resolve(mid);

        assertTrue(s.getMarket(mid).resolved, "resolution survived an unreceivable treasury");
        assertEq(s.marketFeeAccrued(mid), ROUND_FEE, "fee deferred back to its round");
        assertEq(s.feesAccrued(), ROUND_FEE, "accounting stays exact");
        assertEq(_heldUsdt(), SET_SIZE + ROUND_FEE, "backing + fee both still held");

        // Winners are unaffected — the whole point of not reverting.
        vm.prank(bob.addr);
        assertEq(s.redeem(mid), SET_SIZE, "winner still redeems in full");

        // And once the treasury is healthy the deferred fee is retrievable and really burns.
        vm.clearMockedCalls();
        uint256[] memory ids = new uint256[](1);
        ids[0] = mid;
        uint256 supplyBefore = rain.totalSupply();
        vm.prank(executor);
        s.buybackAndBurn(ids);
        assertEq(s.feesAccrued(), 0, "retry retired the deferred fee");
        assertLt(rain.totalSupply(), supplyBefore, "and burned real RAIN");
    }

    // ── 4. The manual retry ─────────────────────────────────────────────

    /// A round that ended but was never resolved still has a final fee bucket, so the executor can
    /// retire it without waiting on resolution.
    function test_buybackAndBurn_worksOnAnEndedButUnresolvedRound() public forked {
        uint256 mid = _market();
        _fillWithFee(mid, ROUND_FEE);
        _endRound(mid);

        uint256[] memory ids = new uint256[](1);
        ids[0] = mid;
        assertEq(s.pendingBuyback(ids), ROUND_FEE, "pending view reports the bucket");

        uint256 supplyBefore = rain.totalSupply();
        vm.prank(executor);
        s.buybackAndBurn(ids);

        assertFalse(s.getMarket(mid).resolved, "round is still unresolved");
        assertEq(s.feesAccrued(), 0, "yet its fee was retired");
        assertLt(rain.totalSupply(), supplyBefore, "real RAIN burned");
    }

    function test_buybackAndBurn_ownerMayAlsoCall() public forked {
        uint256 mid = _market();
        _fillWithFee(mid, ROUND_FEE);
        _endRound(mid);

        uint256[] memory ids = new uint256[](1);
        ids[0] = mid;
        s.buybackAndBurn(ids); // owner == address(this)
        assertEq(s.feesAccrued(), 0);
    }

    function test_buybackAndBurn_rejectsStrangers() public forked {
        uint256 mid = _market();
        _fillWithFee(mid, ROUND_FEE);
        _endRound(mid);

        uint256[] memory ids = new uint256[](1);
        ids[0] = mid;
        vm.expectRevert(UpDownSettlement.OnlyBuybackExecutor.selector);
        vm.prank(makeAddr("stranger"));
        s.buybackAndBurn(ids);
    }

    /// An in-flight round's fee is not final — a fill can still land — so it cannot be burned early.
    function test_buybackAndBurn_rejectsAnInFlightRound() public forked {
        uint256 mid = _market();
        _fillWithFee(mid, ROUND_FEE);

        UpDownSettlement.Market memory m = s.getMarket(mid);
        uint256[] memory ids = new uint256[](1);
        ids[0] = mid;
        vm.expectRevert(
            abi.encodeWithSelector(UpDownSettlement.RoundNotEnded.selector, mid, uint256(m.endTime), block.timestamp)
        );
        vm.prank(executor);
        s.buybackAndBurn(ids);
    }

    function test_buybackAndBurn_revertsWhenThereIsNothingToBurn() public forked {
        uint256 mid = _market();
        _endRound(mid);

        uint256[] memory ids = new uint256[](1);
        ids[0] = mid;
        vm.expectRevert(UpDownSettlement.NothingToBuyback.selector);
        vm.prank(executor);
        s.buybackAndBurn(ids);
    }

    /// A round already burned at resolution cannot be burned twice — the bucket is zeroed before
    /// any external call, so there is nothing left to double-spend.
    function test_feeCannotBeBurnedTwice() public forked {
        uint256 mid = _market();
        _fillWithFee(mid, ROUND_FEE);
        _endRound(mid);
        _resolve(mid);

        uint256[] memory ids = new uint256[](1);
        ids[0] = mid;
        vm.expectRevert(UpDownSettlement.NothingToBuyback.selector);
        vm.prank(executor);
        s.buybackAndBurn(ids);
    }

    /// Batching several finished rounds burns each one's own bucket.
    function test_buybackAndBurn_batchesRounds() public forked {
        uint256 midA = _market();
        uint256 midB = _market();
        _fillWithFee(midA, ROUND_FEE);
        _fillWithFee(midB, ROUND_FEE * 2);
        _endRound(midB); // both windows are identical length, so this ends A too

        uint256[] memory ids = new uint256[](2);
        ids[0] = midA;
        ids[1] = midB;
        assertEq(s.pendingBuyback(ids), ROUND_FEE * 3);

        vm.prank(executor);
        s.buybackAndBurn(ids);

        assertEq(s.feesAccrued(), 0, "both retired");
        assertEq(s.marketFeeAccrued(midA), 0);
        assertEq(s.marketFeeAccrued(midB), 0);
    }

    function test_buybackAndBurn_rejectsAnUnknownMarket() public forked {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 9999;
        vm.expectRevert(UpDownSettlement.MarketNotOpen.selector);
        vm.prank(executor);
        s.buybackAndBurn(ids);
    }

    // ── 5. Route configuration ──────────────────────────────────────────

    /// The path must start at the fee asset and end at the token being burned. Anything else would
    /// let the unattended swap spend or produce the wrong asset.
    function test_setBuybackRoute_rejectsAPathNotStartingAtUsdt() public forked {
        bytes memory bad = abi.encodePacked(WETH, RAIN_WETH_FEE, rainAddr);
        vm.expectRevert(UpDownSettlement.InvalidBuybackPath.selector);
        s.setBuybackRoute(rainAddr, SWAP_ROUTER, QUOTER, bad);
    }

    function test_setBuybackRoute_rejectsAPathNotEndingAtTheBurnToken() public forked {
        bytes memory bad = abi.encodePacked(usdtAddr, USDT_WETH_FEE, WETH);
        vm.expectRevert(UpDownSettlement.InvalidBuybackPath.selector);
        s.setBuybackRoute(rainAddr, SWAP_ROUTER, QUOTER, bad);
    }

    function test_setBuybackRoute_rejectsAMalformedPathLength() public forked {
        bytes memory bad = abi.encodePacked(usdtAddr, rainAddr); // missing the fee tier
        vm.expectRevert(UpDownSettlement.InvalidBuybackPath.selector);
        s.setBuybackRoute(rainAddr, SWAP_ROUTER, QUOTER, bad);
    }

    /// The single-hop shape is accepted too, for a future direct USDT/RAIN pool.
    function test_setBuybackRoute_acceptsASingleHopPath() public forked {
        bytes memory p = abi.encodePacked(usdtAddr, RAIN_WETH_FEE, rainAddr);
        s.setBuybackRoute(rainAddr, SWAP_ROUTER, QUOTER, p);
        assertEq(s.buybackPath(), p, "single-hop path stored verbatim");
    }

    /// A codeless target would make the `try` blocks decode empty returndata, which reverts
    /// UNCAUGHT and would put the failure back on the resolve path. Reject it at config time.
    function test_setBuybackRoute_rejectsCodelessTargets() public forked {
        address eoa = makeAddr("not-a-contract");
        vm.expectRevert(abi.encodeWithSelector(UpDownSettlement.NotAContract.selector, eoa));
        s.setBuybackRoute(rainAddr, eoa, QUOTER, _path());
    }

    function test_setBuybackRoute_rejectsZeroAddresses() public forked {
        vm.expectRevert(UpDownSettlement.ZeroAddress.selector);
        s.setBuybackRoute(address(0), SWAP_ROUTER, QUOTER, _path());
    }

    function test_setBuybackRoute_isOwnerOnly() public forked {
        vm.expectRevert();
        vm.prank(makeAddr("stranger"));
        s.setBuybackRoute(rainAddr, SWAP_ROUTER, QUOTER, _path());
    }

    /// 10000 bps would disable slippage protection entirely on a swap that runs unattended.
    function test_setBuybackSlippageBps_rejectsUnboundedAndZero() public forked {
        vm.expectRevert(abi.encodeWithSelector(UpDownSettlement.InvalidSlippageBps.selector, uint256(10000)));
        s.setBuybackSlippageBps(10000);
        vm.expectRevert(abi.encodeWithSelector(UpDownSettlement.InvalidSlippageBps.selector, uint256(0)));
        s.setBuybackSlippageBps(0);
    }

    function test_defaultSlippageMatchesRainProtocol() public forked {
        assertEq(s.buybackSlippageBps(), 300, "3%, as in LibUtils.swapAndBurn");
    }

    // ── 6. Conservation ─────────────────────────────────────────────────

    /// The global solvency statement, restated for the two-pot world and checked across a full
    /// round-trip against the real route: accrue, burn, redeem.
    function test_balanceEqualsBackingPlusFeesThroughout() public forked {
        uint256 mid = _market();
        _fillWithFee(mid, ROUND_FEE);
        assertEq(_heldUsdt(), s.marketRetained(mid) + s.feesAccrued(), "after the fill");

        _endRound(mid);
        _resolve(mid);
        assertEq(_heldUsdt(), s.marketRetained(mid) + s.feesAccrued(), "after the burn");

        vm.prank(bob.addr);
        s.redeem(mid);
        assertEq(_heldUsdt(), s.marketRetained(mid) + s.feesAccrued(), "after the redemption");
        assertEq(_heldUsdt(), 0, "and everything is settled");
    }
}
