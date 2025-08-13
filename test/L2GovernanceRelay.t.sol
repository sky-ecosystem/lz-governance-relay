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

pragma solidity ^0.8.21;

import "dss-test/DssTest.sol";

import { L2GovernanceRelay } from "src/L2GovernanceRelay.sol";
import { OappMock } from "test/mocks/OappMock.sol";

contract L2SpellMock {
    function exec() external {}
    function revt() pure external { revert("L2SpellMock/revt"); }
}

contract L2GovernanceRelayTest is DssTest {

    L2GovernanceRelay relay;
    address l1GovernanceRelay = address(0x222);
    address l2Oapp;
    address spell;

    function setUp() public {
        relay = new L2GovernanceRelay(1);
        l2Oapp = address(new OappMock(address(0)));
        spell = address(new L2SpellMock());

        relay.file("l2Oapp", l2Oapp);
        relay.file("l1GovernanceRelay", l1GovernanceRelay);
    }

    function testConstructor() public {
        vm.expectEmit(true, true, true, true);
        emit Rely(address(this));
        L2GovernanceRelay r = new L2GovernanceRelay(123);

        assertEq(r.l1Eid(), 123);
        assertEq(r.wards(address(this)), 1);
    }

    function testAuth() public {
        checkAuth(address(relay), "L2GovernanceRelay");
    }

    function testFile() public {
        checkFileAddress(address(relay), "L2GovernanceRelay", ["l2Oapp", "l1GovernanceRelay"]);
    }

    function testRelay() public {
        OappMock(l2Oapp).setMessageOrigin(1, bytes32(uint256(uint160(l1GovernanceRelay))));

        vm.prank(l2Oapp); relay.relay(spell, abi.encodeCall(L2SpellMock.exec, ()));
    }

    function testRelayNotFromL2Oapp() public {
        OappMock(l2Oapp).setMessageOrigin(1, bytes32(uint256(uint160(l1GovernanceRelay))));

        vm.expectRevert("L2GovernanceRelay/bad-message-auth");
        relay.relay(spell, abi.encodeCall(L2SpellMock.exec, ()));
    }

    function testRelayNotFromEid() public {
        OappMock(l2Oapp).setMessageOrigin(2, bytes32(uint256(uint160(l1GovernanceRelay))));

        vm.expectRevert("L2GovernanceRelay/bad-message-auth");
        vm.prank(l2Oapp); relay.relay(spell, abi.encodeCall(L2SpellMock.exec, ()));
    }

    function testRelayNotFromL1GovRelay() public {
        OappMock(l2Oapp).setMessageOrigin(1, bytes32(uint256(uint160(address(0)))));

        vm.expectRevert("L2GovernanceRelay/bad-message-auth");
        vm.prank(l2Oapp); relay.relay(spell, abi.encodeCall(L2SpellMock.exec, ()));
    }

    function testRelayDelegateCallError() public {
        OappMock(l2Oapp).setMessageOrigin(1, bytes32(uint256(uint160(l1GovernanceRelay))));

        vm.expectRevert("L2GovernanceRelay/delegatecall-error");
        vm.prank(l2Oapp); relay.relay(spell, abi.encodeWithSignature("bad()"));
    }

    function testRelayRevert() public {
        OappMock(l2Oapp).setMessageOrigin(1, bytes32(uint256(uint160(l1GovernanceRelay))));

        vm.expectRevert("L2SpellMock/revt");
        vm.prank(l2Oapp); relay.relay(spell, abi.encodeCall(L2SpellMock.revt, ()));
    }
}