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

import { L1GovernanceRelay, MessagingFee, GovernanceControllerLike, GovernanceAction } from "src/L1GovernanceRelay.sol";
import { L2GovernanceRelay } from "src/L2GovernanceRelay.sol";
import { GovernanceControllerOApp } from "lib/sky-oapp-oft/contracts/GovernanceControllerOApp.sol";


import { OappMock } from "test/mocks/OappMock.sol";
import { GemMock } from "test/mocks/GemMock.sol";

// Fake callee on L1 for OappMock to call, in practice the call would be on L2 but this checks relayEVM's message.calldata encoding
contract Callee {
    event Relay(address target, bytes targetData);

    // Same signature as L2GovernanceRelay.relay
    function relay(address target, bytes calldata targetData) external {
        emit Relay(target, targetData);
    }
}

contract L1GovernanceRelayTest is DssTest {
    L1GovernanceRelay relay;
    address l2GovRelay = address(0x222);
    address l1Oapp;
    GemMock lzToken;
    Callee callee;

    event SentMessageEVM(
        uint8 action,
        bytes32 originCaller,
        address governedContract,
        bytes callData,
        uint32 dstEid,
        bytes extraOptions,
        uint256 nativeFee,
        uint256 lzTokenFee,
        address refundAddress
    );

    event SentMessageRaw(
        bytes message,
        uint32 dstEid,
        bytes extraOptions,
        uint256 nativeFee,
        uint256 lzTokenFee,
        address refundAddress
    );

    event Relay(address target, bytes targetData);

    function setUp() public {
        relay = new L1GovernanceRelay();
        lzToken = new GemMock(100 ether);
        l1Oapp = address(new OappMock(address(lzToken)));
        callee = new Callee();

        relay.file("lzToken", address(lzToken));
        relay.file("l1Oapp", l1Oapp);
    }

    function testConstructor() public {
        vm.expectEmit(true, true, true, true);
        emit Rely(address(this));
        L1GovernanceRelay r = new L1GovernanceRelay();

        assertEq(r.wards(address(this)), 1);
    }

    function testAuth() public {
        checkAuth(address(relay), "L1GovernanceRelay");
    }

    function testFile() public {
        checkFileAddress(address(relay), "L1GovernanceRelay", ["lzToken", "l1Oapp"]);
    }

    function testAuthModifiers() public virtual {
        relay.deny(address(this));

        checkModifier(address(relay), string(abi.encodePacked("L1GovernanceRelay", "/not-authorized")), [
            relay.reclaim.selector,
            relay.reclaimLzToken.selector,
            relay.relayRawBytes.selector,
            relay.relayRawBytes.selector
        ]);
    }

    function testReceive() public {
        vm.deal(address(this), 1 ether);
        (bool sent, ) = address(relay).call{value: 1 ether}("");
        assertEq(sent, true);
        assertEq(address(relay).balance, 1 ether);
    }

    function testReclaim() public {
        uint256 initialReceiverBalance = address(0x123).balance;
        vm.deal(address(relay), 1 ether);

        relay.reclaim(address(0x123), 1 ether);

        assertEq(address(0x123).balance, initialReceiverBalance + 1 ether);
        assertEq(address(relay).balance, 0);
    }

    function testReclaimLzToken() public {
        uint256 initialReceiverBalance = lzToken.balanceOf(address(0x123));
        lzToken.transfer(address(relay), 1 ether);

        relay.reclaimLzToken(address(0x123), 1 ether);

        assertEq(lzToken.balanceOf(address(0x123)), initialReceiverBalance + 1 ether);
        assertEq(lzToken.balanceOf(address(relay)), 0);
    }

    function _checkRelayEvm(uint256 sendValue, uint256 nativeFee, uint256 lzTokenFee, bool expectSuccess) internal {
        if (expectSuccess) {
            vm.expectEmit(true, true, true, true);
            emit SentMessageEVM(
                /* action */            uint8(GovernanceAction.EVM_CALL),
                /* originCaller */      bytes32(uint256(uint160(address(relay)))),
                /* governedContract */  address(callee),
                /* callData */          abi.encodeCall(L2GovernanceRelay.relay, (address(0x666), "789")),
                /* dstEid */            5,
                /* extraOptions */      "1234",
                /* nativeFee */         nativeFee,
                /* lzTokenFee */        lzTokenFee,
                /* refundAddress */     address(0x444)
            );
            vm.expectEmit(true, true, true, true);
            emit Relay(address(0x666), "789");
        }
        relay.relayEVM{value: sendValue}({
            dstEid            : 5,
            extraOptions      : "1234",
            fee : MessagingFee({
                nativeFee  : nativeFee,
                lzTokenFee : lzTokenFee
            }),
            refundAddress     : address(0x444),
            l2GovernanceRelay : address(callee), //address(0x555),
            target            : address(0x666),
            targetData        : "789"
        });
    }

    function testRelayEvmWithSentEth() public {
        vm.deal(address(this), 1 ether);
        _checkRelayEvm({ sendValue: 1 ether, nativeFee: 1 ether, lzTokenFee: 0, expectSuccess: true });
    }

    function testRelayEvmWithExistingEth() public {
        vm.deal(address(relay), 1 ether);
        _checkRelayEvm({ sendValue: 0, nativeFee: 1 ether, lzTokenFee: 0, expectSuccess: true });
    }

    function testRelayEvmNotEnoughEth() public {
        vm.deal(address(relay), 1 ether / 2);
        vm.expectRevert();
        _checkRelayEvm({ sendValue: 0, nativeFee: 1 ether, lzTokenFee: 0, expectSuccess: false });
    }

    function testRelayEvmWithLzToken() public {
        deal(address(lzToken), address(relay), 2 ether);
        _checkRelayEvm({ sendValue: 0, nativeFee: 0, lzTokenFee: 2 ether, expectSuccess: true });
    }

    function testRelayEvmWithNotEnoughToken() public {
        deal(address(lzToken), address(relay), 1 ether);
        vm.expectRevert("Gem/insufficient-balance");
        _checkRelayEvm({ sendValue: 0, nativeFee: 0, lzTokenFee: 2 ether, expectSuccess: false });
    }

    function testRelayEvmZeroFee() public {
        vm.expectRevert("L1GovernanceRelay/zero-fee");
        _checkRelayEvm({ sendValue: 0, nativeFee: 0, lzTokenFee: 0, expectSuccess: false });
    }

    function _checkRelayRawBytes(uint256 sendValue, uint256 nativeFee, uint256 lzTokenFee, bool expectSuccess) internal {
        if (expectSuccess) {
            vm.expectEmit(true, true, true, true);
            emit SentMessageRaw(
                /* message */           "message",
                /* dstEid */            5,
                /* extraOptions */      "1234",
                /* nativeFee */         nativeFee,
                /* lzTokenFee */        lzTokenFee,
                /* refundAddress */     address(0x444)
            );
        }
        relay.relayRawBytes{value: sendValue}({
            dstEid       : 5,
            extraOptions : "1234",
            fee : MessagingFee({
                nativeFee  : nativeFee,
                lzTokenFee : lzTokenFee
            }),
            refundAddress : address(0x444),
            message       : "message"
        });
    }

    function testRelayRawBytesWithSentEth() public {
        vm.deal(address(this), 1 ether);
        _checkRelayRawBytes({ sendValue: 1 ether, nativeFee: 1 ether, lzTokenFee: 0, expectSuccess: true });
    }

    function testRelayRawBytesWithExistingEth() public {
        vm.deal(address(relay), 1 ether);
        _checkRelayRawBytes({ sendValue: 0, nativeFee: 1 ether, lzTokenFee: 0, expectSuccess: true });
    }

    function testRelayRawBytesWithNotEnoughEth() public {
        vm.deal(address(relay), 1 ether / 2);
        vm.expectRevert();
        _checkRelayRawBytes({ sendValue: 0, nativeFee: 1 ether, lzTokenFee: 0, expectSuccess: false });
    }

    function testRelayRawBytesWithLzToken() public {
        deal(address(lzToken), address(relay), 2 ether);
        _checkRelayRawBytes({ sendValue: 0, nativeFee: 0, lzTokenFee: 2 ether, expectSuccess: true });
    }

    function testRelayRawBytesWithNotEnoughToken() public {
        deal(address(lzToken), address(relay), 1 ether);
        vm.expectRevert("Gem/insufficient-balance");
        _checkRelayRawBytes({ sendValue: 0, nativeFee: 0, lzTokenFee: 2 ether, expectSuccess: false });
    }

    function testRelayRawBytesZeroFee() public {
        vm.expectRevert("L1GovernanceRelay/zero-fee");
        _checkRelayRawBytes({ sendValue: 0, nativeFee: 0, lzTokenFee: 0, expectSuccess: false });
    }
}
