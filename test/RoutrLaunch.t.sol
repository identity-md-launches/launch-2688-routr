// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Routr} from "../src/Routr.sol";

/// @dev Stands in for the launch factory: deploys the token by CREATE2 and performs the launch flows,
/// all within one call, as `launchCustom` does in one transaction.
contract Create2Launcher {
    uint256 private constant SWARM_BPS = 1_000;

    function predict(bytes32 salt) external view returns (address) {
        bytes32 codeHash = keccak256(type(Routr).creationCode);
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash)))));
    }

    function deploy(bytes32 salt) public returns (Routr token) {
        token = new Routr{salt: salt}();
        require(token.totalSupply() == token.INITIAL_SUPPLY(), "supply");
        require(token.balanceOf(address(this)) == token.INITIAL_SUPPLY(), "mint recipient");
    }

    /// @dev Deploys and runs swarm, pool and remainder flows in one call, returning what each arrived with.
    function launch(bytes32 salt, address distributor, address pool, address remainder, uint256 poolBps)
        external
        returns (Routr token, uint256 swarmArrived, uint256 poolArrived, uint256 remainderArrived)
    {
        token = deploy(salt);
        uint256 supply = token.totalSupply();
        uint256 swarm = supply * SWARM_BPS / 10_000;
        uint256 seed = supply * poolBps / 10_000;
        require(token.transfer(distributor, swarm), "swarm");
        swarmArrived = token.balanceOf(distributor);
        require(token.transfer(pool, seed), "seed");
        poolArrived = token.balanceOf(pool);
        uint256 rest = token.balanceOf(address(this));
        require(token.transfer(remainder, rest), "remainder");
        remainderArrived = token.balanceOf(remainder);
    }
}

contract RoutrLaunchTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    Routr private token;
    address private holder = makeAddr("holder");
    address private stranger = makeAddr("stranger");

    function setUp() public {
        token = new Routr();
        token.transfer(holder, SUPPLY / 1_000);
    }

    function test_create2DeploymentLandsAtPredictedAddressAndMintsToFactory() public {
        Create2Launcher launcher = new Create2Launcher();
        bytes32 salt = bytes32(uint256(42));
        address predicted = launcher.predict(salt);
        vm.prank(stranger, stranger);
        Routr deployed = launcher.deploy(salt);
        assertEq(address(deployed), predicted);
        assertEq(deployed.balanceOf(address(launcher)), SUPPLY);
        assertEq(deployed.balanceOf(stranger), 0);
        assertEq(deployed.totalSupply(), SUPPLY);
    }

    function test_create2SameSaltTwiceReverts() public {
        Create2Launcher launcher = new Create2Launcher();
        launcher.deploy(bytes32(0));
        vm.expectRevert();
        launcher.deploy(bytes32(0));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_launchFlowsArriveWhole(bytes32 salt, uint256 poolBps) public {
        poolBps = bound(poolBps, 0, 9_000);
        Create2Launcher launcher = new Create2Launcher();
        address distributor = makeAddr("distributor");
        address pool = makeAddr("pool");
        address remainder = makeAddr("remainder");
        (Routr deployed, uint256 swarm, uint256 seeded, uint256 rest) =
            launcher.launch(salt, distributor, pool, remainder, poolBps);

        uint256 expectedSeed = SUPPLY * poolBps / 10_000;
        assertEq(swarm, SUPPLY / 10);
        assertEq(seeded, expectedSeed);
        assertEq(rest, SUPPLY - SUPPLY / 10 - expectedSeed);
        assertEq(deployed.balanceOf(address(launcher)), 0);
        assertEq(swarm + seeded + rest, SUPPLY);

        // A claimant receives the swarm share whole from the distributor.
        address claimant = makeAddr("claimant");
        vm.prank(distributor);
        assertTrue(deployed.transfer(claimant, swarm));
        assertEq(deployed.balanceOf(claimant), swarm);
        assertEq(deployed.balanceOf(distributor), 0);
        assertEq(deployed.totalSupply(), SUPPLY);
    }

    /// @dev The selectors the launch floor tries, with the same oversized arguments, from both a stranger
    /// and the deployer. None may exist; none may change supply or a holder's balance.
    function test_floorAdminSelectorsDoNothing() public {
        string[21] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "seize(address)"
        ];
        uint256 held = token.balanceOf(holder);
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], holder, type(uint128).max);
            vm.prank(stranger);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(holder), held, signatures[i]);
            assertEq(token.balanceOf(stranger), 0, signatures[i]);
        }
        // burnFrom by the deployer, then an unapproved pull from the holder.
        (bool burned,) = address(token).call(abi.encodeWithSignature("burnFrom(address,uint256)", holder, 1));
        assertFalse(burned);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(holder, address(this), 1);
        assertEq(token.balanceOf(holder), held);

        vm.prank(holder);
        assertTrue(token.transfer(stranger, held / 2));
        assertEq(token.balanceOf(stranger), held / 2);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_unknownCalldataRevertsAndChangesNothing(bytes calldata data, address caller) public {
        bytes4 selector = data.length >= 4 ? bytes4(data[:4]) : bytes4(0);
        // Skip the token's own ABI; everything else must fail.
        bool known = selector == token.transfer.selector || selector == token.transferFrom.selector
            || selector == token.approve.selector || selector == token.balanceOf.selector
            || selector == token.allowance.selector || selector == token.totalSupply.selector
            || selector == token.name.selector || selector == token.symbol.selector
            || selector == token.decimals.selector || selector == token.INITIAL_SUPPLY.selector;
        if (known) return;
        uint256 held = token.balanceOf(holder);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assertFalse(ok);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(holder), held);
    }

    /// @dev Mirrors the floor's reachable-opcode walk over the deployed runtime.
    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        bool reachable = true;
        for (uint256 i; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += op - 0x5F;
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    function test_tokensSentToTheTokenContractAreStuck() public {
        vm.prank(holder);
        assertTrue(token.transfer(address(token), 1 ether));
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
        // The token has no way to move its own balance: it never approves or transfers on its own behalf.
        assertEq(token.allowance(address(token), holder), 0);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, holder, 0, 1));
        token.transferFrom(address(token), holder, 1);
    }

    function test_approveFromZeroAddressCallerIsImpossible() public {
        // A prank as address(0) reaches _approve's owner check.
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.approve(holder, 1);
    }

    function test_transferFromZeroAddressCallerIsImpossible() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        token.transfer(holder, 0);
    }

    function test_allowanceOneBelowMaxIsDecremented() public {
        uint256 nearMax = type(uint256).max - 1;
        vm.prank(holder);
        token.approve(stranger, nearMax);
        vm.prank(stranger);
        assertTrue(token.transferFrom(holder, stranger, 1));
        assertEq(token.allowance(holder, stranger), nearMax - 1);
    }

    function test_transferFromWithExactAllowanceAndExactBalance() public {
        uint256 held = token.balanceOf(holder);
        vm.prank(holder);
        token.approve(stranger, held);
        vm.prank(stranger);
        assertTrue(token.transferFrom(holder, stranger, held));
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(stranger), held);
        assertEq(token.allowance(holder, stranger), 0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, 1));
        token.transferFrom(holder, stranger, 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_approveStoresExactValue(address owner, address spender, uint256 amount) public {
        vm.assume(owner != address(0) && spender != address(0));
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(owner, spender), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromOverBalanceRevertsWithBalanceError(uint256 held, uint256 amount) public {
        held = bound(held, 0, token.balanceOf(address(this)));
        amount = bound(amount, held + 1, type(uint256).max);
        address owner = makeAddr("owner");
        token.transfer(owner, held);
        vm.prank(owner);
        token.approve(stranger, type(uint256).max);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount));
        token.transferFrom(owner, stranger, amount);
        assertEq(token.balanceOf(owner), held);
        assertEq(token.balanceOf(stranger), 0);
        assertEq(token.allowance(owner, stranger), type(uint256).max);
    }
}

/// @dev Drives the token with an open set of actors, including contracts and the token itself, and
/// mixes in calls that must fail. Every success and failure is checked against a ghost ledger.
contract RoutrOpenHandler is Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    Routr public immutable token;
    address[] public actors;
    mapping(address => bool) private known;
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    uint256 public ghostFailures;
    uint256 public ghostMoved;

    constructor(Routr token_, address seedHolder) {
        token = token_;
        _track(seedHolder);
        _track(address(token_));
        ghostBalance[seedHolder] = SUPPLY;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _track(address a) private {
        if (!known[a]) {
            known[a] = true;
            actors.push(a);
        }
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _newOrKnown(uint256 seed, address fresh) private returns (address a) {
        // One in four picks a fresh address, so balances spread over an open set.
        if (seed % 4 == 0 && fresh != address(0) && actors.length < 64) {
            _track(fresh);
            return fresh;
        }
        return _actor(seed);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, address fresh, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _newOrKnown(toSeed, fresh);
        amount = bound(amount, 0, ghostBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostMoved += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (amount % 5 == 0) amount = type(uint256).max;
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        ghostAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 fromSeed, uint256 toSeed, uint256 spenderSeed, address fresh, uint256 amount)
        external
    {
        address from = _actor(fromSeed);
        address spender = _actor(spenderSeed);
        address to = _newOrKnown(toSeed, fresh);
        uint256 allowed = ghostAllowance[from][spender];
        uint256 limit = ghostBalance[from] < allowed ? ghostBalance[from] : allowed;
        amount = bound(amount, 0, limit);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        if (allowed != type(uint256).max) ghostAllowance[from][spender] = allowed - amount;
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostMoved += amount;
    }

    /// @dev A pull larger than the allowance must fail and leave everything untouched.
    function overspendAllowance(uint256 fromSeed, uint256 spenderSeed, uint256 extra) external {
        address from = _actor(fromSeed);
        address spender = _actor(spenderSeed);
        uint256 allowed = ghostAllowance[from][spender];
        if (allowed == type(uint256).max) return;
        uint256 amount = allowed + bound(extra, 1, type(uint256).max - allowed);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
        token.transferFrom(from, spender, amount);
        ghostFailures++;
    }

    /// @dev Sending to the zero address, from either path, must fail whatever the amount.
    function sendToZero(uint256 fromSeed, uint256 amount, bool delegated) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        if (delegated) {
            vm.prank(from);
            token.approve(from, type(uint256).max);
            ghostAllowance[from][from] = type(uint256).max;
            vm.prank(from);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            token.transferFrom(from, address(0), amount);
        } else {
            vm.prank(from);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            token.transfer(address(0), amount);
        }
        ghostFailures++;
    }

    function overdraw(uint256 fromSeed, uint256 toSeed, uint256 extra) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = ghostBalance[from];
        uint256 amount = held + bound(extra, 1, type(uint256).max - held);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
        token.transfer(to, amount);
        ghostFailures++;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), amount);
        ghostFailures++;
    }
}

contract RoutrOpenInvariantTest is StdInvariant, Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    Routr private token;
    RoutrOpenHandler private handler;

    function setUp() public {
        token = new Routr();
        address whale = makeAddr("whale");
        handler = new RoutrOpenHandler(token, whale);
        token.transfer(whale, SUPPLY);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = RoutrOpenHandler.transfer.selector;
        selectors[1] = RoutrOpenHandler.approve.selector;
        selectors[2] = RoutrOpenHandler.transferFrom.selector;
        selectors[3] = RoutrOpenHandler.overspendAllowance.selector;
        selectors[4] = RoutrOpenHandler.sendToZero.selector;
        selectors[5] = RoutrOpenHandler.overdraw.selector;
        selectors[6] = RoutrOpenHandler.approveZeroSpender.selector;
        selectors[7] = RoutrOpenHandler.transfer.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_supplyIsFixedAndFullyAccounted() public view {
        assertEq(token.totalSupply(), SUPPLY);
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            uint256 balance = token.balanceOf(a);
            assertEq(balance, handler.ghostBalance(a));
            sum += balance;
        }
        assertEq(sum, SUPPLY, "balances outside the tracked set");
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_allowancesMatchGhost() public view {
        uint256 n = handler.actorCount();
        if (n > 16) n = 16;
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender));
            }
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_noAllowanceForZeroAddress() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            assertEq(token.allowance(handler.actors(i), address(0)), 0);
            assertEq(token.allowance(address(0), handler.actors(i)), 0);
        }
    }
}
