// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UpDownSettlement} from "../src/UpDownSettlement.sol";
import {UpDownAutoCycler} from "../src/UpDownAutoCycler.sol";
import {ChainlinkResolver} from "../src/ChainlinkResolver.sol";
import {MockAggregatorV3} from "../src/mocks/MockAggregatorV3.sol";

/// @title Regression tests for the Hacken 2026-06 audit fixes.
/// @notice Negative-case coverage for every guard added in response to the
///         audit (the report flagged that negative-case coverage was missing).
///         Each test maps to a finding id.

// ── Settlement-side fixes (F-17774, F-17728) ─────────────────────────────────
// NOTE: F-17730 (makerFee stranded when recipient is zero) is now STRUCTURALLY
// resolved — `makerFeeRecipient` is no longer a relayer-supplied field; the maker
// fee always flows to `makerOrder.maker`, which carries a valid signature and can
// never be the zero address. Its dedicated tests are removed. The full V2 fee
// model is covered in RemediationV2.t.sol.
contract AuditFixesSettlementTest is Test {
    bytes32 internal constant PAIR = keccak256("BTC/USD");

    ERC20Mock internal usdt;
    UpDownSettlement internal s;
    address internal owner = address(this);
    address internal autocycler = makeAddr("autocycler");
    address internal resolver = makeAddr("resolver");
    address internal relayer = makeAddr("relayer");
    address internal treasury = makeAddr("treasury");
    address internal backer = makeAddr("backer");

    function setUp() public {
        vm.warp(1_700_000_400);
        usdt = new ERC20Mock();
        s = new UpDownSettlement(usdt, owner);
        s.setAutocycler(autocycler);
        s.setResolver(resolver);
        s.setRelayer(relayer);
        s.setTreasury(treasury);

        usdt.mint(backer, 10_000e18);
        vm.prank(backer);
        usdt.approve(address(s), type(uint256).max);
    }

    function _createMarket() internal returns (uint256 mid) {
        vm.prank(autocycler);
        mid = s.createMarket(PAIR, 300, 50_000e8);
    }

    /// F-2026-17774: a complementary burn must revert once the market has expired
    /// (the expiry-to-resolution window), matching complementaryMint. Exercised via
    /// the self-service `burn` entrypoint (F-2026-17772 user authorization).
    function test_F17774_burnAfterExpiryReverts() public {
        uint256 mid = _createMarket();
        vm.prank(backer);
        s.mint(mid, 50e18);

        UpDownSettlement.Market memory m = s.getMarket(mid);
        vm.warp(uint256(m.endTime)); // exactly at endTime: market no longer open

        vm.prank(backer);
        vm.expectRevert(UpDownSettlement.MarketNotOpen.selector);
        s.burn(mid, 50e18);
    }

    /// F-2026-17774 positive control: burning a complete set while the market is open works.
    function test_F17774_burnWhileOpenSucceeds() public {
        uint256 mid = _createMarket();
        vm.prank(backer);
        s.mint(mid, 50e18);
        vm.prank(backer);
        s.burn(mid, 50e18);
        assertEq(s.marketRetained(mid), 0);
    }

    /// F-2026-17728: ownership transfer is now two-step.
    function test_F17728_twoStepOwnership() public {
        address newOwner = makeAddr("newOwner");
        s.transferOwnership(newOwner);
        assertEq(s.owner(), owner, "owner unchanged until accepted");
        assertEq(s.pendingOwner(), newOwner, "pending owner set");

        vm.prank(newOwner);
        s.acceptOwnership();
        assertEq(s.owner(), newOwner, "owner finalized after accept");
        assertEq(s.pendingOwner(), address(0), "pending cleared");
    }
}

// ── Resolver-side fixes (F-17729, F-17759) ───────────────────────────────────
contract AuditFixesResolverTest is Test {
    bytes32 internal constant BTCUSD = keccak256("BTC/USD");

    ChainlinkResolver internal r;
    MockAggregatorV3 internal feed;
    address internal owner = address(this);

    function setUp() public {
        vm.warp(1_700_000_400); // % 300 == 0
        MockAggregatorV3 seq = new MockAggregatorV3(0, 8, block.timestamp - 2 hours); // up, past grace
        feed = new MockAggregatorV3(50_000e8, 8, 0); // fresh updatedAt
        r = new ChainlinkResolver(
            owner,
            address(seq),
            BTCUSD,
            address(feed),
            bytes32(0),
            address(0),
            makeAddr("settlement"), // trustedSettlement (unused by these paths)
            makeAddr("verifierProxy"),
            makeAddr("linkToken")
        );
    }

    /// F-2026-17759: a zero feed answer must revert InvalidPrice, not be
    /// forwarded as a valid price.
    function test_F17759_zeroPriceReverts() public {
        feed.setPrice(0);
        vm.expectRevert(ChainlinkResolver.InvalidPrice.selector);
        r.getPrice(BTCUSD);
    }

    /// F-2026-17759: a negative feed answer must revert InvalidPrice.
    function test_F17759_negativePriceReverts() public {
        feed.setPrice(-1);
        vm.expectRevert(ChainlinkResolver.InvalidPrice.selector);
        r.getPrice(BTCUSD);
    }

    /// F-2026-17759 positive control: a positive answer passes through.
    function test_F17759_positivePricePasses() public {
        feed.setPrice(60_000e8);
        assertEq(r.getPrice(BTCUSD), 60_000e8);
    }

    /// F-2026-17729: an unaligned startTime is rejected before any paid verify.
    function test_F17729_unalignedStartReverts() public {
        uint64 unaligned = 1_700_000_401; // % 300 == 1
        vm.expectRevert(abi.encodeWithSelector(ChainlinkResolver.StrikeStartNotAligned.selector, unaligned));
        r.captureStrike(BTCUSD, "", unaligned);
    }

    /// F-2026-17729: an aligned startTime passes the alignment gate (and then
    /// reverts later, here for the unconfigured streams feed) — proving the
    /// alignment guard let it through.
    function test_F17729_alignedStartPassesAlignmentGate() public {
        uint64 aligned = 1_700_000_400; // % 300 == 0
        vm.expectRevert(ChainlinkResolver.StreamsFeedNotConfigured.selector);
        r.captureStrike(BTCUSD, "", aligned);
    }
}

// ── Cycler-side fixes (F-17782, F-17726) ─────────────────────────────────────
contract AuditFixesCyclerTest is Test {
    bytes32 internal constant BTCUSD = keccak256("BTC/USD");
    bytes32 internal constant ETHUSD = keccak256("ETH/USD");

    UpDownAutoCycler internal c;
    address internal owner = address(this);

    function setUp() public {
        c = new UpDownAutoCycler(owner, makeAddr("resolver"), makeAddr("settlement"));
    }

    /// F-2026-17782: removePair deactivates a pair and removes it from the
    /// cycling list (swap-and-pop), and a later addPair re-adds it cleanly.
    function test_F17782_removePairDeactivatesAndReAdds() public {
        c.addPair(ETHUSD);
        assertTrue(c.supportedPairs(BTCUSD));
        assertEq(c.cyclingPairCount(), 2);

        vm.expectEmit(true, false, false, false);
        emit UpDownAutoCycler.PairRemoved(BTCUSD);
        c.removePair(BTCUSD);

        assertFalse(c.supportedPairs(BTCUSD), "pair deactivated");
        assertFalse(c.isCyclingPair(BTCUSD), "cycling flag cleared");
        assertEq(c.cyclingPairCount(), 1, "removed from cycling list");
        assertEq(c.cyclingPairAt(0), ETHUSD, "swap-and-pop kept ETHUSD");

        // Re-add: must push again (not silently skip).
        c.addPair(BTCUSD);
        assertTrue(c.supportedPairs(BTCUSD));
        assertEq(c.cyclingPairCount(), 2, "re-added cleanly");
    }

    /// F-2026-17782: removePair is owner-only.
    function test_F17782_removePairOnlyOwner() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        c.removePair(BTCUSD);
    }

    /// F-2026-17726: owner can repair a corrupted pairTfLastCreated pointer
    /// (the recovery hatch) without a redeploy.
    function test_F17726_setPairTfLastCreatedRecovers() public {
        c.setPairTfLastCreated(BTCUSD, 0, 1_700_000_000);
        assertEq(c.pairTfLastCreated(BTCUSD, 0), 1_700_000_000);
    }

    /// F-2026-17726: the recovery hatch validates the timeframe index.
    function test_F17726_setPairTfLastCreatedRejectsBadTfIdx() public {
        vm.expectRevert(UpDownAutoCycler.InvalidTimeframeIndex.selector);
        c.setPairTfLastCreated(BTCUSD, 3, 0);
    }

    /// F-2026-17726: the recovery hatch is owner-only.
    function test_F17726_setPairTfLastCreatedOnlyOwner() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        c.setPairTfLastCreated(BTCUSD, 0, 0);
    }
}

// ── Reentrancy (F-17781) ─────────────────────────────────────────────────────

/// @notice A callback-capable ERC-20 — the exact "future collateral token" threat model the
///         F-2026-17781 finding calls out (plain USDT has no transfer hook). On the settlement
///         contract's OUTBOUND payout transfer it re-enters a chosen guarded entrypoint, letting
///         the test prove the global `nonReentrant` lock fires.
contract ReentrantToken is ERC20 {
    address public target; // settlement under attack
    uint256 public attackMarket; // market id to re-enter
    uint8 public mode; // 0 = re-enter redeem, 1 = re-enter mint (cross-function)
    bool public armed;
    bool internal entered;

    constructor() ERC20("Reentrant", "RENT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address t, uint256 market, uint8 m) external {
        target = t;
        attackMarket = market;
        mode = m;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        // Re-enter only on the settlement contract's own outbound transfer (the redeem payout),
        // and only once, to avoid unbounded recursion if the guard were ever absent.
        if (armed && !entered && from == target) {
            entered = true;
            if (mode == 0) {
                UpDownSettlement(target).redeem(attackMarket);
            } else {
                UpDownSettlement(target).mint(attackMarket, 1);
            }
        }
    }
}

/// F-2026-17781: prove the `nonReentrant` guard is wired and active on the token-moving externals.
/// USDT can't trigger it (no callback), so the guard is defense-in-depth for a future
/// callback-capable collateral token — this models exactly that token and shows the global
/// reentrancy lock blocks BOTH same-function and cross-function re-entry during a payout.
contract SettlementReentrancyTest is Test {
    bytes32 internal constant PAIR = keccak256("BTC/USD");
    uint8 internal constant UP = 1;

    ReentrantToken internal token;
    UpDownSettlement internal s;
    address internal owner = address(this);
    address internal autocycler = makeAddr("autocycler");
    address internal resolver = makeAddr("resolver");
    address internal relayer = makeAddr("relayer");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_700_000_400);
        token = new ReentrantToken();
        s = new UpDownSettlement(IERC20(address(token)), owner);
        s.setAutocycler(autocycler);
        s.setResolver(resolver);
        s.setRelayer(relayer);
        s.setTreasury(treasury);

        token.mint(alice, 1_000e18);
        vm.prank(alice);
        token.approve(address(s), type(uint256).max);
    }

    function _resolvedWinningMarket() internal returns (uint256 mid) {
        vm.prank(autocycler);
        mid = s.createMarket(PAIR, 300, 50_000e8);
        vm.prank(alice);
        s.mint(mid, 100e18); // alice holds 100 UP + 100 DOWN; pool = 100
        UpDownSettlement.Market memory m = s.getMarket(mid);
        vm.warp(uint256(m.endTime) + 1);
        vm.prank(resolver);
        s.resolve(mid, 60_000e8, UP); // UP wins → alice's UP shares are the winner
    }

    /// Same-function re-entry: redeem → (payout transfer) → redeem must hit the guard.
    function test_F17781_reentrancyGuardBlocksReentrantRedeem() public {
        uint256 mid = _resolvedWinningMarket();
        token.arm(address(s), mid, 0);

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        s.redeem(mid);
    }

    /// Cross-function re-entry: redeem → (payout transfer) → mint must hit the SAME global lock.
    function test_F17781_reentrancyGuardBlocksCrossFunctionReentry() public {
        uint256 mid = _resolvedWinningMarket();
        token.arm(address(s), mid, 1);

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        s.redeem(mid);
    }

    /// Positive control: the same callback-capable token redeems fine when NOT re-entering,
    /// proving the reverts above are the reentrancy guard and not the token itself.
    function test_F17781_redeemSucceedsWithoutReentry() public {
        uint256 mid = _resolvedWinningMarket();
        uint256 alice0 = token.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = s.redeem(mid);
        assertEq(payout, 100e18, "winner redeems 1:1");
        assertEq(token.balanceOf(alice), alice0 + 100e18);
        assertEq(s.marketRetained(mid), 0);
    }
}
