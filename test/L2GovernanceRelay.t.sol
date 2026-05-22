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
    function run(address store) external {
        StorageMock(store).markRun();
    }
    function revt() pure external { revert("L2SpellMock/revt"); }
}

contract L2GovernanceRelayTest is DssTest {
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
    event ActionCanceled(uint256 indexed id);

    function setUp() public {
        l2Oapp = address(new OappReceiverMock());
        spell = address(new L2SpellMock());
        store = address(new StorageMock());
        relay = L2GovernanceRelay(GovernanceRelayDeploy.deployL2(1, l2Oapp, l1GovernanceRelay));
        OappReceiverMock(l2Oapp).setMessageOrigin(1, bytes32(uint256(uint160(l1GovernanceRelay))));
    }

    function testConstructor() public {
        L2GovernanceRelay r = new L2GovernanceRelay(123, address(0x1), address(0x2));
        assertEq(r.l1Eid(), 123);
        assertEq(address(r.l2Oapp()), address(0x1));
        assertEq(r.l1GovernanceRelay(), address(0x2));
        assertEq(r.delay(), 0);
        assertEq(r.gracePeriod(), r.MINIMUM_GRACE_PERIOD());
        assertEq(r.actionsCount(), 0);
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
        relay.file("delay", uint256(1 days));

        vm.expectEmit();
        emit File("delay", uint256(1 days));
        vm.prank(address(relay)); relay.file("delay", uint256(1 days));
        assertEq(relay.delay(), 1 days);

        uint256 minGrace = relay.MINIMUM_GRACE_PERIOD();
        vm.expectRevert("L2GovernanceRelay/grace-period-too-short");
        vm.prank(address(relay)); relay.file("gracePeriod", minGrace - 1);

        vm.expectEmit();
        emit File("gracePeriod", uint256(1 hours));
        vm.prank(address(relay)); relay.file("gracePeriod", uint256(1 hours));
        assertEq(relay.gracePeriod(), 1 hours);

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
        L2GovernanceRelay.Action memory set = relay.getActionById(0);
        assertEq(set.target, spell);
        assertEq(set.targetData, data);
        assertEq(set.executionTime, executionTime);
        assertFalse(set.executed);
        assertFalse(set.canceled);
        assertEq(uint8(relay.getActionState(0)), uint8(L2GovernanceRelay.ActionState.Queued));
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
        id = relay.actionsCount();
        vm.prank(l2Oapp); relay.relay(target, data);
    }

    function testExec() public {
        assertFalse(StorageMock(store).didRun());

        uint256 id = _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));

        vm.expectEmit();
        emit ActionExecuted(id, address(this), "");
        relay.exec(id);

        assertTrue(relay.getActionById(id).executed);
        assertEq(uint8(relay.getActionState(id)), uint8(L2GovernanceRelay.ActionState.Executed));
        assertTrue(StorageMock(store).didRun());
    }

    function testExecAfterDelay() public {
        vm.prank(address(relay)); relay.file("delay", uint256(1 days));
        uint256 id = _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));

        vm.expectRevert("L2GovernanceRelay/timelock-not-finished");
        relay.exec(id);

        vm.warp(block.timestamp + 1 days);
        relay.exec(id);
        assertTrue(relay.getActionById(id).executed);
    }

    function testExecAlreadyExecuted() public {
        uint256 id = _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));
        relay.exec(id);

        vm.expectRevert("L2GovernanceRelay/not-queued");
        relay.exec(id);
    }

    function testExecCanceled() public {
        vm.prank(address(relay)); relay.kiss(bud);
        uint256 id = _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));
        vm.prank(bud); relay.cancel(id);

        vm.expectRevert("L2GovernanceRelay/not-queued");
        relay.exec(id);
    }

    function testExecExpired() public {
        uint256 id = _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));
        vm.warp(block.timestamp + relay.gracePeriod() + 1);

        assertEq(uint8(relay.getActionState(id)), uint8(L2GovernanceRelay.ActionState.Expired));
        vm.expectRevert("L2GovernanceRelay/not-queued");
        relay.exec(id);
    }

    function testExecInvalidId() public {
        vm.expectRevert("L2GovernanceRelay/invalid-action-id");
        relay.exec(0);
    }

    function testExecDelegateCallError() public {
        uint256 id = _queue(spell, abi.encodeWithSignature("bad()"));

        vm.expectRevert("L2GovernanceRelay/delegatecall-error");
        relay.exec(id);
    }

    function testExecRevert() public {
        uint256 id = _queue(spell, abi.encodeCall(L2SpellMock.revt, ()));

        vm.expectRevert("L2SpellMock/revt");
        relay.exec(id);
    }

    function testCancel() public {
        vm.prank(address(relay)); relay.kiss(bud);
        uint256 id = _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));

        vm.expectEmit();
        emit ActionCanceled(id);
        vm.prank(bud); relay.cancel(id);

        assertTrue(relay.getActionById(id).canceled);
        assertEq(uint8(relay.getActionState(id)), uint8(L2GovernanceRelay.ActionState.Canceled));
    }

    function testCancelNotWhitelisted() public {
        uint256 id = _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));

        vm.expectRevert("L2GovernanceRelay/not-whitelisted");
        relay.cancel(id);
    }

    function testCancelNotQueued() public {
        vm.prank(address(relay)); relay.kiss(bud);
        uint256 id = _queue(spell, abi.encodeCall(L2SpellMock.run, (address(store))));
        relay.exec(id);

        vm.expectRevert("L2GovernanceRelay/not-queued");
        vm.prank(bud); relay.cancel(id);
    }

    function testCancelInvalidId() public {
        vm.prank(address(relay)); relay.kiss(bud);

        vm.expectRevert("L2GovernanceRelay/invalid-action-id");
        vm.prank(bud); relay.cancel(0);
    }

    function testgetActionStateInvalidId() public {
        vm.expectRevert("L2GovernanceRelay/invalid-action-id");
        relay.getActionState(0);
    }
}
