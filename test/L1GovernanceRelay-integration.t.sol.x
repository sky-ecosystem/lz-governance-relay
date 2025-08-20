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

// TODO: check what's needed
import { L1GovernanceRelay, MessagingFee, GovernanceControllerLike } from "src/L1GovernanceRelay.sol";
import { L2GovernanceRelay } from "src/L2GovernanceRelay.sol";
import { OappMock } from "test/mocks/OappMock.sol";
import { GemMock } from "test/mocks/GemMock.sol";

import { GovernanceControllerOApp } from "lib/sky-oapp-oft/contracts/GovernanceControllerOApp.sol";

import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { IOAppOptionsType3, EnforcedOptionParam } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import { SendParam /*, MessagingFee */ } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { SetConfigParam, IMessageLibManager } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import { UlnConfig } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import { ExecutorConfig } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/SendLibBase.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

interface ChainlogLike {
    function getAddress(bytes32) external view returns (address);
}

// Fake callee on L1 for OappMock to call, in practice the call would be on L2 but this checks relayEVM's message.calldata encoding
contract Callee {
    event Relay(address target, bytes targetData);

    // Same signature as L2GovernanceRelay.relay
    function relay(address target, bytes calldata targetData) external {
        emit Relay(target, targetData);
    }
}

contract L1GovernanceRelayIntegrationTest is DssTest {
    using OptionsBuilder for bytes;

    L1GovernanceRelay relay;
    address l2GovRelay = address(0x222);
    address l1Oapp;
    GemMock lzToken;
    Callee callee;

    address pauseProxy;

    ChainlogLike public chainlog = ChainlogLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);
    address constant ETH_LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    uint32 constant AVAX_EID = 30106;


//    function setUp() public {
//        relay = new L1GovernanceRelay();
//        lzToken = new GemMock(100 ether);
//        l1Oapp = address(new OappMock(address(lzToken)));
//        callee = new Callee();
//
//        relay.file("lzToken", address(lzToken));
//        relay.file("l1Oapp", l1Oapp);
//    }

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        relay = new L1GovernanceRelay();

        pauseProxy = chainlog.getAddress("MCD_PAUSE_PROXY");
    }

    function _initOapp(address oapp, bytes32 peer) internal {
        IOAppCore(oapp).setPeer(AVAX_EID, peer);

        ExecutorConfig memory execCfg = ExecutorConfig({
            maxMessageSize: 1_000_000,
            executor:       0x2CCA08ae69E0C44b18a57Ab2A87644234dAebaE4 // LZ Executor
        });
        UlnConfig memory ulnCfg = UlnConfig({
            confirmations:        15,
            requiredDVNCount:     1,
            optionalDVNCount:     type(uint8).max,
            optionalDVNThreshold: 0,
            requiredDVNs:         new address[](1),
            optionalDVNs:         new address[](0)
        });
        ulnCfg.requiredDVNs[0] = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b; // LayerZero Labs DVN

        SetConfigParam[] memory cfgParams = new SetConfigParam[](2);
        cfgParams[0] = SetConfigParam(AVAX_EID, 1, abi.encode(execCfg));
        cfgParams[1] = SetConfigParam(AVAX_EID, 2, abi.encode(ulnCfg));

        IMessageLibManager(ETH_LZ_ENDPOINT).setConfig(
            oapp,
            0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1, // SendUln302 message lib // TODO: make constant?
            cfgParams
        );

        EnforcedOptionParam[] memory opts = new EnforcedOptionParam[](1);
        opts[0] = EnforcedOptionParam(AVAX_EID, 1, OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 2_500_000));
        IOAppOptionsType3(oapp).setEnforcedOptions(opts);
    }

    function _initGovOapp() internal {
        GovernanceControllerOApp l1Oapp = new GovernanceControllerOApp({
            _endpoint: ETH_LZ_ENDPOINT,
            _delegate: pauseProxy,
            _addInitialValidTarget: false,
            _initialValidTargetSrcEid: 0,
            _initialValidTargetOriginCaller: bytes32(0),
            _initialValidTargetGovernedContract: address(0)
        });
        vm.startPrank(pauseProxy);
        l1Oapp.addValidCaller(address(relay));
        _initOapp(address(l1Oapp), bytes32("peer")); // TODO: is it fine to be made up
        vm.stopPrank();

        // TODO: this should be controlled by the PP
        relay.file("l1Oapp", address(l1Oapp));
    }

    function _checkRelayEvm(uint256 sendValue, uint256 nativeFee, uint256 lzTokenFee, bool expectSuccess) internal {
        relay.relayEVM{value: sendValue}({
            dstEid            : AVAX_EID,
            extraOptions      : "",
            fee : MessagingFee({
                nativeFee  : nativeFee,
                lzTokenFee : lzTokenFee
            }),
            refundAddress     : address(0x444),
            l2GovernanceRelay : address(callee),
            target            : address(0x666),
            targetData        : "789"
        });
    }

    function testRelayEvmWithSentEth() public {
        _initGovOapp();

        vm.deal(address(this), 1 ether);
        _checkRelayEvm({ sendValue: 1 ether, nativeFee: 1 ether, lzTokenFee: 0, expectSuccess: true });
    }
}
