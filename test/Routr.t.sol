// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Routr} from "../src/Routr.sol";

/// @dev A local deployment and transfer probe, never deployed as part of the launch.
contract FactoryProbe {
    function deploy() external returns (Routr) {
        return new Routr();
    }

    function move(Routr token, address recipient, uint256 amount) external {
        require(token.transfer(recipient, amount));
    }
}

contract RoutrTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000_000_000_000_000_000_000;
    Routr private token;
    address private alice;
    address private bob;
    address private spender;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        token = new Routr();
    }

    function test_metadataAndInitialSupply() public view {
        assertEq(token.name(), "Routr");
        assertEq(token.symbol(), "ROUTR");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_constructorEmitsOneMint() public {
        vm.recordLogs();
        Routr deployed = new Routr();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(deployed));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(this)))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    function test_directDeploymentMintsToCaller() public {
        vm.prank(alice);
        Routr deployed = new Routr();
        assertEq(deployed.balanceOf(alice), SUPPLY);
        assertEq(deployed.balanceOf(address(this)), 0);
    }

    function test_factoryReceivesAllSupplyAndLaunchTransfersArriveWhole() public {
        FactoryProbe factory = new FactoryProbe();
        vm.prank(alice, alice);
        Routr deployed = factory.deploy();
        assertEq(deployed.balanceOf(address(factory)), SUPPLY);
        assertEq(deployed.balanceOf(alice), 0, "transaction origin must not receive the mint");

        address distributor = makeAddr("distributor");
        address poolManager = makeAddr("poolManager");
        address remainder = makeAddr("remainder");
        uint256 swarmShare = SUPPLY / 10;
        uint256 poolShare = SUPPLY * 85 / 100;
        uint256 remainderShare = SUPPLY * 5 / 100;

        factory.move(deployed, distributor, swarmShare);
        factory.move(deployed, poolManager, poolShare);
        factory.move(deployed, remainder, remainderShare);
        assertEq(deployed.balanceOf(address(factory)), 0);
        assertEq(deployed.balanceOf(distributor), swarmShare);
        assertEq(deployed.balanceOf(poolManager), poolShare);
        assertEq(deployed.balanceOf(remainder), remainderShare);

        vm.prank(distributor);
        assertTrue(deployed.transfer(bob, swarmShare));
        assertEq(deployed.balanceOf(distributor), 0);
        assertEq(deployed.balanceOf(bob), swarmShare);

        // Exercise both directions at the token boundary; this is not a DEX simulation.
        vm.prank(poolManager);
        assertTrue(deployed.transfer(alice, 100 ether));
        assertEq(deployed.balanceOf(alice), 100 ether);
        vm.prank(alice);
        assertTrue(deployed.transfer(poolManager, 100 ether));
        assertEq(deployed.balanceOf(alice), 0);
        assertEq(deployed.balanceOf(poolManager), poolShare);
        assertEq(deployed.totalSupply(), SUPPLY);
    }

    function test_transferEmitsEventAndMovesExactAmount() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 123 ether);
        assertTrue(token.transfer(alice, 123 ether));
        assertEq(token.balanceOf(alice), 123 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 123 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferEntireSupply() public {
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
        vm.prank(alice);
        assertTrue(token.transfer(bob, SUPPLY));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferPreservesBalanceAndEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), address(this), SUPPLY);
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_transferToContractRequiresNoReceiverCallback() public {
        FactoryProbe receiver = new FactoryProbe();
        assertTrue(token.transfer(address(receiver), 1 ether));
        assertEq(token.balanceOf(address(receiver)), 1 ether);
    }

    function test_transferToZeroRevertsEvenForZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferWithoutBalanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_selfTransferStillChecksBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(alice, 1);
    }

    function test_approveEmitsAndSetsAllowanceWithoutMovingTokens() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, 20 ether);
        assertTrue(token.approve(spender, 20 ether));
        assertEq(token.allowance(address(this), spender), 20 ether);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
    }

    function test_approvalCanBeReplacedAndRevoked() public {
        token.approve(spender, 20 ether);
        token.approve(spender, 7 ether);
        assertEq(token.allowance(address(this), spender), 7 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, 0);
        token.approve(spender, 0);
        assertEq(token.allowance(address(this), spender), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), bob, 1);
    }

    function test_approvalDoesNotRequireCurrentBalance() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, type(uint256).max));
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_approvalToZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        assertEq(token.allowance(address(this), address(0)), 0);
    }

    function test_transferFromConsumesAllowanceAndEmitsTransfer() public {
        token.approve(spender, 10 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 4 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 4 ether));
        assertEq(token.balanceOf(address(this)), SUPPLY - 4 ether);
        assertEq(token.balanceOf(alice), 4 ether);
        assertEq(token.allowance(address(this), spender), 6 ether);

        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 6 ether));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromInfiniteAllowanceIsNotDecremented() public {
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 10 ether));
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 10 ether);
    }

    function test_zeroTransferFromWithoutAllowanceSucceeds() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFromSelfConsumesAllowanceWithoutChangingBalance() public {
        token.approve(spender, SUPPLY);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_transferFromByHolderStillRequiresAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(this), alice, 1);
    }

    function test_transferFromCannotUseAnotherSpendersApproval() public {
        token.approve(spender, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(address(this), bob, 1);
        assertEq(token.allowance(address(this), spender), 10 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_transferFromInsufficientAllowanceRevertsAtomically() public {
        token.approve(spender, 4 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 4 ether, 5 ether)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, 5 ether);
        assertEq(token.allowance(address(this), spender), 4 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_transferFromInsufficientBalanceRestoresAllowance() public {
        vm.prank(alice);
        token.approve(spender, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1 ether));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1 ether);
        assertEq(token.allowance(alice, spender), 10 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFromToZeroRestoresAllowance() public {
        token.approve(spender, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 1 ether);
        assertEq(token.allowance(address(this), spender), 10 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransferFromZeroSenderReverts() public {
        // Allowance validation runs before _transfer and rejects the zero approver.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), alice, 0);
    }

    function test_deployerAndStrangerHaveNoAdministrativeEntryPoints() public {
        token.transfer(alice, 100 ether);
        bytes[] memory calls = new bytes[](14);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", bob, 1 ether);
        calls[1] = abi.encodeWithSignature("mint(uint256)", 1 ether);
        calls[2] = abi.encodeWithSignature("mint()");
        calls[3] = abi.encodeWithSignature("burn(uint256)", 1 ether);
        calls[4] = abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1 ether);
        calls[5] = abi.encodeWithSignature("pause()");
        calls[6] = abi.encodeWithSignature("blacklist(address)", alice);
        calls[7] = abi.encodeWithSignature("freeze(address)", alice);
        calls[8] = abi.encodeWithSignature("seize(address)", alice);
        calls[9] = abi.encodeWithSignature("transferOwnership(address)", bob);
        calls[10] = abi.encodeWithSignature("setMinter(address)", bob);
        calls[11] = abi.encodeWithSignature("initialize(address)", bob);
        calls[12] = abi.encodeWithSignature("upgradeTo(address)", bob);
        calls[13] = abi.encodeWithSignature("owner()");

        for (uint256 i; i < calls.length; ++i) {
            (bool deployerSucceeded,) = address(token).call(calls[i]);
            assertFalse(deployerSucceeded);
            vm.prank(bob);
            (bool strangerSucceeded,) = address(token).call(calls[i]);
            assertFalse(strangerSucceeded);
            assertEq(token.totalSupply(), SUPPLY);
            assertEq(token.balanceOf(alice), 100 ether);
            assertEq(token.balanceOf(bob), 0);
        }

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(alice, address(this), 1);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 100 ether));
        assertEq(token.balanceOf(bob), 100 ether);
    }

    function test_nativeEtherIsRejected() public {
        vm.deal(address(this), 1 ether);
        (bool succeeded,) = address(token).call{value: 1 ether}("");
        assertFalse(succeeded);
        assertEq(address(token).balance, 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferConservesSupply(address recipient, uint256 amount) public {
        vm.assume(recipient != address(0) && recipient != address(this));
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_overdrawRevertsWithoutChangingBalances(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, amount)
        );
        token.transfer(alice, amount);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromMatchesBalanceAndAllowanceModel(uint256 approved, uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        token.approve(spender, approved);
        if (amount > approved) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount)
            );
            vm.prank(spender);
            token.transferFrom(address(this), alice, amount);
            assertEq(token.allowance(address(this), spender), approved);
            assertEq(token.balanceOf(address(this)), SUPPLY);
            assertEq(token.balanceOf(alice), 0);
        } else {
            vm.prank(spender);
            assertTrue(token.transferFrom(address(this), alice, amount));
            assertEq(
                token.allowance(address(this), spender), approved == type(uint256).max ? approved : approved - amount
            );
            assertEq(token.balanceOf(address(this)), SUPPLY - amount);
            assertEq(token.balanceOf(alice), amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }
}
