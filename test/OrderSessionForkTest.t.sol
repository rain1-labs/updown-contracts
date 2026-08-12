// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {UpDownSettlement} from "../src/UpDownSettlement.sol";
import {MockUSDT} from "../src/mocks/MockUSDT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMAv2Factory {
    function createSemiModularAccount(address owner, uint256 salt) external returns (address);
    function getAddressSemiModular(address owner, uint256 salt) external view returns (address);
}

interface IModularAccountV2 {
    function installValidation(
        bytes25 validationConfig,
        bytes4[] calldata selectors,
        bytes calldata installData,
        bytes[] calldata hooks
    ) external;
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

/// @notice **Popup-less order-session fork test** (UPDOWN_RAIN_POPUPLESS_WORK_PLAN.md, Phase 1).
///
///         Proves — against rain.trade's EXACT live Alchemy Modular-Account-v2
///         deployment on an Arbitrum One fork — that a UpDown order signed by the
///         popup-less ORDER-SESSION key is accepted on-chain by the settlement's
///         `SignatureChecker.isValidSignatureNow` (ERC-1271), and fills through
///         `enterPosition` with `order.maker == the shared SCA`.
///
///         The session signature is produced by FFI-ing the SHIPPED SDK export
///         `signWithOrderSession` (the published pulsepairs SDK) via
///         `wt-ub-sdk/sdk/typescript/scripts/sign_order_session.mjs` — so a green
///         run proves the exact code rain.trade calls yields on-chain-valid
///         signatures on their real impl + module. Nothing in the backend or
///         contracts changes; this only verifies the maker-signature path.
///
///         ── rain's exact MA-v2 addresses (Arbitrum One) ──
///         Inspected from their live SCA 0x9704…3559 + a real order tx:
///           impl    0x0000…c5A9…7383  = SemiModularAccountBytecode (semi-modular MA v2)
///           factory 0x0000…17c6…fecd  = MA-v2 account factory (createSemiModularAccount)
///           module  0x0000…99DE…7d83  = SingleSignerValidationModule (our order-session entity)
///
///         ── What this does NOT test ──
///         Whether rain's ROOT-session userOp can send the one-time
///         `installValidation` self-call popup-less (0-vs-1 onboarding popup) is a
///         LIVE Alchemy-bundler question, not an on-chain one — a Foundry fork has
///         no bundler/permission layer. That verdict comes from the companion live
///         probe (scripts/probe-install-popups.mjs); here we install the entity as
///         a self-call (which any userOp is), proving only the contract accepts it.
///
///         ── How to run ──
///           export ARB_FORK_RPC=https://arb-mainnet.g.alchemy.com/v2/<KEY>
///           # optional: ALCHEMY_API_KEY (else offline dummy), ORDER_SIGNER_SCRIPT
///           FOUNDRY_PROFILE=fork forge test --match-contract OrderSessionForkTest -vvv
///         Without ARB_FORK_RPC every test self-skips (CI-safe; never hits network).
contract OrderSessionForkTest is Test {
    // rain.trade's EXACT Alchemy MA-v2 addresses on Arbitrum One.
    address constant FACTORY = 0x00000000000017c61b5bEe81050EC8eFc9c6fecd;
    address constant SINGLE_SIGNER_MODULE = 0x00000000000099DE0BF6fA90dEB851E2A2df7d83;
    address constant IMPL = 0x000000000000c5A9089039570Dd36455b5C07383;

    bytes4 constant ERC1271_MAGIC = 0x1626ba7e;
    bytes4 constant ERC1271_FAIL = 0xffffffff;

    // SingleSignerValidationModule ValidationConfig flag bits:
    // bit0 = isUserOpValidation (execute), bit1 = isSignatureValidation, bit2 = isGlobal.
    uint8 constant FLAG_SIG_ONLY = 0x02; // 1271 only — CANNOT execute a UserOp / move funds.

    uint8 constant OPTION_UP = 1;
    uint8 constant SIDE_BUY = 0;
    uint8 constant SIDE_SELL = 1;

    // EIP-6492 magic suffix.
    bytes32 constant ERC6492_MAGIC = 0x6492649264926492649264926492649264926492649264926492649264926492;

    MockUSDT usdt;
    UpDownSettlement settlement;

    uint256 constant OWNER_PK = 0xA11CE; // SCA owner = semi-modular fallback signer (entity 0)
    uint256 constant SESSION_PK = 0xB0B; // order-session key
    uint32 constant SESSION_ENTITY = 7;
    address ownerAddr;
    address sessionAddr;
    address sca;

    Vm.Wallet takerW;

    bytes32 constant PAIR = keccak256("BTC/USD");
    uint256 marketId;

    bool _skip;

    function setUp() public {
        string memory rpc = vm.envOr("ARB_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            _skip = true;
            return;
        }
        vm.createSelectFork(rpc);
        require(block.chainid == 42161, "ARB_FORK_RPC must fork Arbitrum One (42161)");

        // Sanity: rain's exact impl/module/factory are actually on this fork.
        assertGt(IMPL.code.length, 0, "MA-v2 impl not on fork");
        assertGt(SINGLE_SIGNER_MODULE.code.length, 0, "session module not on fork");
        assertGt(FACTORY.code.length, 0, "MA-v2 factory not on fork");

        ownerAddr = vm.addr(OWNER_PK);
        sessionAddr = vm.addr(SESSION_PK);
        takerW = vm.createWallet("taker");

        // Fresh settlement + market; owner == this test drives every gated entrypoint.
        usdt = new MockUSDT();
        settlement = new UpDownSettlement(IERC20(address(usdt)), address(this));
        settlement.setAutocycler(address(this));
        settlement.setRelayer(address(this));
        settlement.setTreasury(address(this));
        marketId = settlement.createMarket(PAIR, 3600, int256(50_000e8)); // start=now, end=now+3600

        // Deploy rain's exact SCA and install the sig-only order-session entity as a self-call.
        sca = IMAv2Factory(FACTORY).createSemiModularAccount(ownerAddr, 0);
        _installSession(sca, SESSION_ENTITY, sessionAddr);
    }

    /* ─────────────────────────────── tests ─────────────────────────────── */

    /// The crux: a session-key-signed order validates 1271 on rain's exact impl.
    function test_sessionOrder_1271_valid() public {
        if (_skip) return _skipped();
        UpDownSettlement.Order memory o = _mkOrder(sca, SIDE_SELL, 6000, 1e6, 1);
        (bytes32 digest, bytes memory sig) = _ffiSign("session", SESSION_PK, SESSION_ENTITY, o);
        assertEq(digest, settlement.orderDigest(o), "helper digest != on-chain orderDigest (typed-data drift)");
        assertEq(_safeIsValid(sca, digest, sig), ERC1271_MAGIC, "session sig must be 1271-valid");
    }

    /// Full path: a session-signed maker order fills through `enterPosition`; shares move.
    function test_sessionOrder_enterPosition_fills() public {
        if (_skip) return _skipped();

        // Seller = the SCA: fund + self-mint a complete set, so it holds UP shares to sell.
        usdt.mint(sca, 1e6);
        vm.prank(sca);
        usdt.approve(address(settlement), type(uint256).max);
        vm.prank(sca);
        settlement.mint(marketId, 1e6);
        assertEq(settlement.userShares(marketId, sca, OPTION_UP), 1e6, "seller not funded with shares");

        // Buyer/taker = EOA: fund + approve to pay the cash leg.
        usdt.mint(takerW.addr, 1e6);
        vm.prank(takerW.addr);
        usdt.approve(address(settlement), type(uint256).max);

        UpDownSettlement.Order memory mo = _mkOrder(sca, SIDE_SELL, 6000, 1e6, 1); // SCA sells UP, session-signed
        UpDownSettlement.Order memory to = _mkOrder(takerW.addr, SIDE_BUY, 6000, 1e6, 2); // EOA buys UP

        (bytes32 mdig, bytes memory msig) = _ffiSign("session", SESSION_PK, SESSION_ENTITY, mo);
        assertEq(mdig, settlement.orderDigest(mo), "maker typed-data drift");
        bytes memory tsig = _ecdsaSign(takerW, to);

        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            makerOrder: mo,
            makerSignature: msig,
            takerOrder: to,
            takerSignature: tsig,
            fillAmount: 1e6,
            platformFee: 0,
            makerFee: 0
        });
        settlement.enterPosition(f); // relayer == this; MUST NOT revert on the session sig

        assertEq(settlement.userShares(marketId, sca, OPTION_UP), 0, "seller shares not consumed");
        assertEq(settlement.userShares(marketId, takerW.addr, OPTION_UP), 1e6, "buyer did not receive shares");
        assertEq(usdt.balanceOf(sca), 6e5, "seller did not receive the cash leg (6000bps * 1e6)");
    }

    /// Owner-key (semi-modular fallback signer, entity 0) still validates — the
    /// current production maker path is unaffected by installing the session entity.
    function test_ownerKey_1271_stillValid() public {
        if (_skip) return _skipped();
        UpDownSettlement.Order memory o = _mkOrder(sca, SIDE_SELL, 6000, 1e6, 3);
        (bytes32 digest, bytes memory sig) = _ffiSign("owner", OWNER_PK, 0, o);
        assertEq(digest, settlement.orderDigest(o), "owner typed-data drift");
        assertEq(_safeIsValid(sca, digest, sig), ERC1271_MAGIC, "owner fallback sig must still validate");
    }

    /// The session KEY located at the OWNER entity (0) — exactly what rain's
    /// root-session `sessionClient.signTypedData` produces — must NOT validate.
    /// This is why the dedicated order-session entity exists (PoC control B).
    function test_sessionKeyAtEntity0_1271_fails() public {
        if (_skip) return _skipped();
        UpDownSettlement.Order memory o = _mkOrder(sca, SIDE_SELL, 6000, 1e6, 4);
        (bytes32 digest, bytes memory sig) = _ffiSign("session", SESSION_PK, 0, o); // entity 0!
        assertEq(digest, settlement.orderDigest(o), "typed-data drift");
        assertTrue(_safeIsValid(sca, digest, sig) != ERC1271_MAGIC, "session key at entity 0 must fail 1271");
    }

    /// Deploy-before-fill: a session-signed order whose maker SCA is NOT yet
    /// deployed reverts at the maker signature check (SignatureChecker → ECDSA
    /// path on a counterfactual account → false).
    function test_undeployedSca_enterPosition_reverts() public {
        if (_skip) return _skipped();

        address owner2 = vm.addr(0xC0FFEE);
        address sca2 = IMAv2Factory(FACTORY).getAddressSemiModular(owner2, 0);
        assertEq(sca2.code.length, 0, "sca2 must be undeployed for this control");

        // Buyer/taker still valid + funded enough to pass pre-sig guards.
        usdt.mint(takerW.addr, 1e6);
        vm.prank(takerW.addr);
        usdt.approve(address(settlement), type(uint256).max);

        UpDownSettlement.Order memory mo = _mkOrder(sca2, SIDE_SELL, 6000, 1e6, 5);
        UpDownSettlement.Order memory to = _mkOrder(takerW.addr, SIDE_BUY, 6000, 1e6, 6);
        (, bytes memory msig) = _ffiSign("session", SESSION_PK, SESSION_ENTITY, mo); // binds to sca2 (undeployed)
        bytes memory tsig = _ecdsaSign(takerW, to);

        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            makerOrder: mo,
            makerSignature: msig,
            takerOrder: to,
            takerSignature: tsig,
            fillAmount: 1e6,
            platformFee: 0,
            makerFee: 0
        });
        vm.expectRevert(UpDownSettlement.InvalidSignature.selector);
        settlement.enterPosition(f);
    }

    /// An EIP-6492-wrapped signature must NOT validate on a DEPLOYED account (OZ
    /// SignatureChecker v5.6.1 is not 6492-aware) — which is why the SDK strips the
    /// wrapper. The bare inner signature validates, proving the wrapper is the only
    /// difference.
    function test_erc6492Wrapped_1271_fails() public {
        if (_skip) return _skipped();
        UpDownSettlement.Order memory o = _mkOrder(sca, SIDE_SELL, 6000, 1e6, 7);
        (bytes32 digest, bytes memory sig) = _ffiSign("session", SESSION_PK, SESSION_ENTITY, o);
        assertEq(_safeIsValid(sca, digest, sig), ERC1271_MAGIC, "bare session sig must validate (baseline)");

        bytes memory factoryCalldata =
            abi.encodeWithSignature("createSemiModularAccount(address,uint256)", ownerAddr, uint256(0));
        bytes memory wrapped = abi.encodePacked(abi.encode(FACTORY, factoryCalldata, sig), ERC6492_MAGIC);
        assertTrue(
            _safeIsValid(sca, digest, wrapped) != ERC1271_MAGIC, "6492-wrapped sig must not validate on a deployed SCA"
        );
    }

    /// The installed session entity is signature-validation ONLY: it can never
    /// validate a UserOp (execute / move funds). Asserted at the encoding level via
    /// the ValidationConfig flag byte (0x02, bit0/userOp clear).
    function test_sessionEntity_isSignatureOnly() public {
        if (_skip) return _skipped();
        bytes memory packed = abi.encodePacked(SINGLE_SIGNER_MODULE, SESSION_ENTITY, FLAG_SIG_ONLY);
        assertEq(packed.length, 25, "validationConfig must be 25 bytes");
        assertEq(uint8(packed[24]), 0x02, "flag byte must be sig-only (userOp/execute bit clear)");
    }

    /* ────────────────────────────── helpers ────────────────────────────── */

    function _skipped() internal {
        vm.skip(true);
    }

    /// Install a SingleSignerValidationModule entity on `account` as a self-call
    /// (installValidation is guarded onlyEntryPointOrSelf), signature-validation ONLY.
    function _installSession(address account, uint32 entityId, address signer) internal {
        bytes memory packed = abi.encodePacked(SINGLE_SIGNER_MODULE, entityId, FLAG_SIG_ONLY); // 25 bytes
        bytes25 vc;
        assembly {
            vc := mload(add(packed, 0x20))
        }
        bytes memory onInstall = abi.encode(entityId, signer); // (uint32, address)
        bytes4[] memory selectors = new bytes4[](0);
        bytes[] memory hooks = new bytes[](0);
        vm.prank(account);
        IModularAccountV2(account).installValidation(vc, selectors, onInstall, hooks);
    }

    function _mkOrder(address maker, uint8 side, uint256 price, uint256 amount, uint256 nonce)
        internal
        view
        returns (UpDownSettlement.Order memory o)
    {
        o = UpDownSettlement.Order({
            maker: maker,
            market: marketId,
            option: OPTION_UP,
            side: side,
            orderType: 0,
            price: price,
            amount: amount,
            maxFee: 1e6,
            nonce: nonce,
            expiry: block.timestamp + 1800
        });
    }

    /// FFI: sign an Order via the shipped SDK helper (session mode) or the owner
    /// fallback path (owner mode). Returns (digest it hashed, bare 1271 signature).
    /// The account the signature binds to is `o.maker` (the maker IS the SCA).
    function _ffiSign(string memory mode, uint256 pk, uint32 entityId, UpDownSettlement.Order memory o)
        internal
        returns (bytes32 digest, bytes memory sig)
    {
        // All 15 params are static types, so `abi.encode(a..o)` is just the
        // concatenation of their 32-byte words — split into chunks (byte-identical
        // to one 15-tuple encode) to keep the IR encoder off a too-deep stack.
        bytes memory input = bytes.concat(
            abi.encode(bytes32(pk), entityId, o.maker, block.chainid, address(settlement)),
            abi.encode(o.maker, o.market, o.option, o.side, o.orderType),
            abi.encode(o.price, o.amount, o.maxFee, o.nonce, o.expiry)
        );
        string[] memory cmd = new string[](4);
        cmd[0] = "node";
        cmd[1] = vm.envOr("ORDER_SIGNER_SCRIPT", string("../wt-ub-sdk/sdk/typescript/scripts/sign_order_session.mjs"));
        cmd[2] = mode;
        cmd[3] = vm.toString(input);
        (digest, sig) = abi.decode(vm.ffi(cmd), (bytes32, bytes));
    }

    function _ecdsaSign(Vm.Wallet memory w, UpDownSettlement.Order memory o) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(w.privateKey, settlement.orderDigest(o));
        return abi.encodePacked(r, s, v);
    }

    function _safeIsValid(address account, bytes32 h, bytes memory s) internal view returns (bytes4) {
        try IModularAccountV2(account).isValidSignature(h, s) returns (bytes4 r) {
            return r;
        } catch {
            return ERC1271_FAIL;
        }
    }
}
