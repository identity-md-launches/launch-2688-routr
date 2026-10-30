// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Routr} from "../src/Routr.sol";

/// @dev All balances remain within four test actors, allowing a complete conservation check.
contract RoutrHandler is Test {
    Routr private immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(Routr token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
        expectedBalance[actors_[0]] = 1_000_000_000 * 10 ** 18;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) public {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        amount = infinite ? type(uint256).max : bound(amount, 0, 1_000_000_000 * 10 ** 18);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 fromSeed, uint256 toSeed, uint256 spenderSeed, uint256 amount) public {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 allowed = expectedAllowance[from][spender];
        uint256 limit = expectedBalance[from] < allowed ? expectedBalance[from] : allowed;
        amount = bound(amount, 0, limit);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        if (allowed != type(uint256).max) expectedAllowance[from][spender] -= amount;
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function rejectOverdraw(uint256 fromSeed, uint256 toSeed) public {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        vm.prank(from);
        (bool succeeded,) = address(token).call(abi.encodeCall(token.transfer, (to, expectedBalance[from] + 1)));
        assertFalse(succeeded);
        assertEq(token.balanceOf(from), expectedBalance[from]);
        assertEq(token.balanceOf(to), expectedBalance[to]);
    }
}

contract RoutrInvariantTest is StdInvariant, Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    Routr private token;
    RoutrHandler private handler;

    function setUp() public {
        token = new Routr();
        address[4] memory actors = [makeAddr("actor0"), makeAddr("actor1"), makeAddr("actor2"), makeAddr("actor3")];
        handler = new RoutrHandler(token, actors);
        token.transfer(actors[0], SUPPLY);

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = RoutrHandler.transfer.selector;
        selectors[1] = RoutrHandler.approve.selector;
        selectors[2] = RoutrHandler.transferFrom.selector;
        selectors[3] = RoutrHandler.rejectOverdraw.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_fixedSupplyAndBalancesMatchModel() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.expectedBalance(actor));
            sum += balance;
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function invariant_allowancesMatchModel() public view {
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 4; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
        }
    }
}
