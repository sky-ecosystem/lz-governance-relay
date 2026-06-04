// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2025 Dai Foundation
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.8.22;

import "dss-test/DssTest.sol";

import { L2GovernanceRelay } from "src/L2GovernanceRelay.sol";
import { GovernanceRelayDeploy } from "deploy/GovernanceRelayDeploy.sol";
import { OappReceiverMock } from "test/mocks/OappReceiverMock.sol";

contract StorageMock {
    bool public didRun;

    function markRun() external {
        didRun = true;
    }
}

contract L2SpellMock {
    function run(address store) external returns (uint256) {
        StorageMock(store).markRun();

        return 123;
    }
    function revt() pure external { revert("L2SpellMock/revt"); }
}

contract L2GovernanceRelayTest is DssTest {
    uint256 constant DELAY        = 1 days;
    uint256 constant GRACE_PERIOD = 1 hours;

    L2GovernanceRelay relay;
    address l1GovernanceRelay = address(0x111);
    address l2Oapp;
    address spell;
    address store;
    address bud = address(0xb0b);

    event Kiss(address indexed usr);
    event Diss(address indexed usr);
    event ActionQueued(uint256 indexed id, address target, bytes targetData, uint256 executionTime);
    event ActionExecuted(uint256 indexed id, address indexed initiatorExecution, bytes returnedData);
    event ActionsCanceled(uint256 indexed id);

    function setUp() public {
        l2Oapp = address(new OappReceiverMock());
        spell = address(new L2SpellMock());
        store = address(new StorageMock());
        relay = L2GovernanceRelay(GovernanceRelayDeploy.deployL2(1, l2Oapp, l1GovernanceRelay, DELAY, GRACE_PERIOD, new address[](0)));
        OappReceiverMock(l2Oapp).setMessageOrigin(1, bytes32(uint256(uint160(l1GovernanceRelay))));
    }

    function testConstructor() public {
        address[] memory initialBud = new address[](2);
        initialBud[0] = address(0xb01);
        initialBud[1] = address(0xb02);

        uint256 minGrace = relay.MINIMUM_GRACE_PERIOD();
        vm.expectRevert("L2GovernanceRelay/grace-period-too-short");
        new L2GovernanceRelay(123, address(0x1), address(0x2), 2 days, minGrace - 1, initialBud);

        vm.expectEmit();
        emit File("l2Oapp", address(0x1));
        vm.expectEmit();
        emit File("l1GovernanceRelay", address(0x2));
        vm.expectEmit();
        emit File("delay", uint256(2 days));
        vm.expectEmit();
        emit File("gracePeriod", uint256(2 hours));
        vm.expectEmit();
        emit Kiss(address(0xb01));
        vm.expectEmit();
        emit Kiss(address(0xb02));
        L2GovernanceRelay r = new L2GovernanceRelay(123, address(0x1), address(0x2), 2 days, 2 hours, initialBud);

        assertEq(r.l1Eid(), 123);
        assertEq(address(r.l2Oapp()), address(0x1));
        assertEq(r.l1GovernanceRelay(), address(0x2));
        assertEq(r.delay(), 2 days);
        assertEq(r.gracePeriod(), 2 hours);
        assertEq(r.actionsCount(), 0);
        assertEq(r.canceledCount(), 0);
        assertEq(r.bud(address(0xb01)), 1);
        assertEq(r.bud(address(0xb02)), 1);
        assertEq(r.bud(address(0xb03)), 0);
    }

    function testFile() public {
        vm.expectRevert("L2GovernanceRelay/sender-not-this");
        relay.file("l2Oapp", address(0x1));
        vm.expectEmit();
        emit File("l2Oapp", address(0x1));
        vm.prank(address(relay)); relay.file("l2Oapp", address(0x1));
        assertEq(address(relay.l2Oapp()), address(0x1));

        vm.expectRevert("L2GovernanceRelay/sender-not-this");
        relay.file("l1GovernanceRelay", address(0x2));
        vm.expectEmit();
        emit File("l1GovernanceRelay", address(0x2));
        vm.prank(address(relay)); relay.file("l1GovernanceRelay", address(0x2));
        assertEq(relay.l1GovernanceRelay(), address(0x2));

        vm.expectRevert("L2GovernanceRelay/file-unrecognized-param");
        vm.prank(address(relay)); relay.file("bad", address(0x1));
    }

    function testFileUint256() public {
        vm.expectRevert("L2GovernanceRelay/sender-not-this");
        relay.file("delay", uint256(2 days));

        vm.expectEmit();
        emit File("delay", uint256(2 days));
        vm.prank(address(relay)); relay.file("delay", uint256(2 days));
        assertEq(relay.delay(), 2 days);

        uint256 minGrace = relay.MINIMUM_GRACE_PERIOD();
        vm.expectRevert("L2GovernanceRelay/grace-period-too-short");
        vm.prank(address(relay)); relay.file("gracePeriod", minGrace - 1);

        vm.expectEmit();
        emit File("gracePeriod", uint256(2 hours));
        vm.prank(address(relay)); relay.file("gracePeriod", uint256(2 hours));
        assertEq(relay.gracePeriod(), 2 hours);

        vm.expectRevert("L2GovernanceRelay/file-unrecognized-param");
        vm.prank(address(relay)); relay.file("bad", uint256(1));
    }

    function testKiss() public {
        vm.expectRevert("L2GovernanceRelay/sender-not-this");
        relay.kiss(bud);

        vm.expectEmit();
        emit Kiss(bud);
        vm.prank(address(relay)); relay.kiss(bud);
        assertEq(relay.bud(bud), 1);
    }

    function testDiss() public {
        vm.prank(address(relay)); relay.kiss(bud);
        assertEq(relay.bud(bud), 1);

        vm.expectRevert("L2GovernanceRelay/sender-not-this");
        relay.diss(bud);

        vm.expectEmit();
        emit Diss(bud);
        vm.prank(address(relay)); relay.diss(bud);
        assertEq(relay.bud(bud), 0);
    }

    function testRelay() public {
        bytes memory data = abi.encodeCall(L2SpellMock.run, (address(store)));
        uint256 executionTime = block.timestamp + relay.delay();

        vm.expectEmit();
        emit ActionQueued(0, spell, data, executionTime);
        vm.prank(l2Oapp); relay.relay(spell, data);

        assertEq(relay.actionsCount(), 1);
        L2GovernanceRelay.Action memory action = relay.getActionById(0);
        assertEq(action.target, spell);
        assertEq(action.targetData, data);
        assertEq(action.executionTime, executionTime);
        assertFalse(action.executed);
        assertEq(uint8(relay.getActionState(0)), uint8(L2GovernanceRelay.ActionState.Queued));
    }

    function testGetActionByIdInvalidId() public {
        vm.expectRevert("L2GovernanceRelay/invalid-action-id");
        relay.getActionById(0);
    }

    function testRelayNotFromL2Oapp() public {
        vm.expectRevert("L2GovernanceRelay/bad-message-auth");
        relay.relay(spell, abi.encodeCall(L2SpellMock.run, (address(store))));
    }

    function testRelayNotFromEid() public {
        OappReceiverMock(l2Oapp).setMessageOrigin(2, bytes32(uint256(uint160(l1GovernanceRelay))));

        vm.expectRevert("L2GovernanceRelay/bad-message-auth");
        vm.prank(l2Oapp); relay.relay(spell, abi.encodeCall(L2SpellMock.run, (address(store))));
    }

    function testRelayNotFromL1GovRelay() public {
        OappReceiverMock(l2Oapp).setMessageOrigin(1, bytes32(uint256(uint160(address(0)))));

        vm.expectRevert("L2GovernanceRelay/bad-message-auth");
        vm.prank(l2Oapp); relay.relay(spell, abi.encodeCall(L2SpellMock.run, (address(store))));
    }

    function _queue(address target, bytes memory data) internal returns (uint256 id) {
        vm.prank(l2Oapp); relay.relay(target, data);
        id = relay.actionsCount() - 1;
    }

    function testExec() public {
        assertFalse(StorageMock(store).didRun());

        uint256 id = _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));
        assertEq(uint8(relay.getActionState(id)), uint8(L2GovernanceRelay.ActionState.Queued));

        vm.expectRevert("L2GovernanceRelay/not-ready");
        relay.exec(id);

        vm.warp(block.timestamp + relay.delay());
        assertEq(uint8(relay.getActionState(id)), uint8(L2GovernanceRelay.ActionState.Ready));

        vm.expectEmit();
        emit ActionExecuted(id, address(this), abi.encode(123));
        relay.exec(id);

        assertTrue(relay.getActionById(id).executed);
        assertEq(uint8(relay.getActionState(id)), uint8(L2GovernanceRelay.ActionState.Executed));
        assertTrue(StorageMock(store).didRun());
    }

    function testExecAfterDelayChange() public {
        uint256 newDelay = 2 days;
        vm.prank(address(relay)); relay.file("delay", newDelay);
        uint256 id = _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));

        // Still Queued at original delay window
        vm.warp(block.timestamp + DELAY);
        assertEq(uint8(relay.getActionState(id)), uint8(L2GovernanceRelay.ActionState.Queued));
        vm.expectRevert("L2GovernanceRelay/not-ready");
        relay.exec(id);

        vm.warp(block.timestamp + (newDelay - DELAY));
        assertEq(uint8(relay.getActionState(id)), uint8(L2GovernanceRelay.ActionState.Ready));
        relay.exec(id);
        assertTrue(relay.getActionById(id).executed);
    }

    function testExecZeroDelay() public {
        vm.prank(address(relay)); relay.file("delay", uint256(0));

        // Queue and exec in the same block/tx — action becomes Ready immediately.
        uint256 blockTimeAtQueue = block.timestamp;
        uint256 id = _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));

        assertEq(relay.getActionById(id).executionTime, blockTimeAtQueue);
        assertEq(uint8(relay.getActionState(id)), uint8(L2GovernanceRelay.ActionState.Ready));

        relay.exec(id);
        assertEq(block.timestamp, blockTimeAtQueue);
        assertTrue(relay.getActionById(id).executed);
    }

    function testExecAlreadyExecuted() public {
        uint256 id = _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));
        vm.warp(block.timestamp + relay.delay());
        relay.exec(id);

        vm.expectRevert("L2GovernanceRelay/not-ready");
        relay.exec(id);
    }

    function testExecCanceled() public {
        vm.prank(address(relay)); relay.kiss(bud);
        uint256 id = _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));
        vm.prank(bud); relay.cancel(id);

        assertEq(uint8(relay.getActionState(id)), uint8(L2GovernanceRelay.ActionState.Canceled));
        vm.expectRevert("L2GovernanceRelay/not-ready");
        relay.exec(id);
    }

    function testExecExpired() public {
        uint256 id = _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));
        vm.warp(block.timestamp + relay.delay() + relay.gracePeriod() + 1);

        assertEq(uint8(relay.getActionState(id)), uint8(L2GovernanceRelay.ActionState.Expired));
        vm.expectRevert("L2GovernanceRelay/not-ready");
        relay.exec(id);
    }

    function testExecInvalidId() public {
        vm.expectRevert("L2GovernanceRelay/invalid-action-id");
        relay.exec(0);

        vm.expectRevert("L2GovernanceRelay/invalid-action-id");
        relay.exec(1);
    }

    function testExecDelegateCallError() public {
        uint256 id = _queue(spell, abi.encodeWithSignature("bad()"));
        vm.warp(block.timestamp + relay.delay());

        vm.expectRevert("L2GovernanceRelay/delegatecall-error");
        relay.exec(id);
    }

    function testExecRevert() public {
        uint256 id = _queue(spell, abi.encodeCall(L2SpellMock.revt, ()));
        vm.warp(block.timestamp + relay.delay());

        vm.expectRevert("L2SpellMock/revt");
        relay.exec(id);
    }

    function testCancel() public {
        vm.prank(address(relay)); relay.kiss(bud);
        uint256 id1 = _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));
        uint256 id2 = _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));
        uint256 id3 = _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));

        vm.expectEmit();
        emit ActionsCanceled(id2);
        vm.prank(bud); relay.cancel(id2);

        assertEq(relay.canceledCount(), id3);
        assertEq(uint8(relay.getActionState(id1)), uint8(L2GovernanceRelay.ActionState.Canceled));
        assertEq(uint8(relay.getActionState(id2)), uint8(L2GovernanceRelay.ActionState.Canceled));
        assertEq(uint8(relay.getActionState(id3)), uint8(L2GovernanceRelay.ActionState.Queued));

        // Queue an action that will be executed, then another that will be left to expire.
        uint256 id4 = _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));
        vm.warp(block.timestamp + relay.delay());
        relay.exec(id4);
        assertEq(uint8(relay.getActionState(id4)), uint8(L2GovernanceRelay.ActionState.Executed));

        uint256 id5 = _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));
        vm.warp(block.timestamp + relay.delay() + relay.gracePeriod() + 1);
        assertEq(uint8(relay.getActionState(id5)), uint8(L2GovernanceRelay.ActionState.Expired));

        // A later checkpoint covering both: Executed survives, Expired folds into Canceled.
        vm.prank(bud); relay.cancel(id5);
        assertEq(uint8(relay.getActionState(id4)), uint8(L2GovernanceRelay.ActionState.Executed));
        assertEq(uint8(relay.getActionState(id5)), uint8(L2GovernanceRelay.ActionState.Canceled));
    }

    function testCancelNotWhitelisted() public {
        uint256 id = _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));

        vm.expectRevert("L2GovernanceRelay/not-whitelisted");
        relay.cancel(id);
    }

    function testCancelInvalidId() public {
        vm.prank(address(relay)); relay.kiss(bud);

        // No actions queued yet: any id (including 0) is invalid.
        vm.expectRevert("L2GovernanceRelay/invalid-action-id");
        vm.prank(bud); relay.cancel(0);

        _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));

        // One action queued (id 0): id 1 is above actionsCount.
        vm.expectRevert("L2GovernanceRelay/invalid-action-id");
        vm.prank(bud); relay.cancel(1);
    }

    function testCancelAlreadyIncluded() public {
        vm.prank(address(relay)); relay.kiss(bud);
        _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));
        _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));

        vm.prank(bud); relay.cancel(1);

        vm.expectRevert("L2GovernanceRelay/already-included");
        vm.prank(bud); relay.cancel(1);

        vm.expectRevert("L2GovernanceRelay/already-included");
        vm.prank(bud); relay.cancel(0);
    }

    function testGetActionStateInvalidId() public {
        vm.expectRevert("L2GovernanceRelay/invalid-action-id");
        relay.getActionState(0);

        vm.expectRevert("L2GovernanceRelay/invalid-action-id");
        relay.getActionState(1);

        _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));

        relay.getActionState(0);

        vm.expectRevert("L2GovernanceRelay/invalid-action-id");
        relay.getActionState(1);

        vm.expectRevert("L2GovernanceRelay/invalid-action-id");
        relay.getActionState(2);
    }
}
