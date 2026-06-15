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

import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { PacketV1Codec } from "@layerzerolabs/lz-evm-protocol-v2/contracts/messagelib/libs/PacketV1Codec.sol";
import { GovernanceOAppSender, TxParams, MessagingFee } from "lib/sky-oapp-oft/contracts/GovernanceOAppSender.sol";
import { GovernanceOAppReceiver } from "lib/sky-oapp-oft/contracts/GovernanceOAppReceiver.sol";
import { MockControlledContract } from "lib/sky-oapp-oft/test/mocks/MockControlledContract.sol";
import { MockSpell } from "lib/sky-oapp-oft/test/mocks/MockSpell.sol";
import { TestHelperOz5WithRevertAssertions } from "lib/sky-oapp-oft/test/foundry/helpers/TestHelperOz5WithRevertAssertions.sol";
import { L1GovernanceRelay } from "src/L1GovernanceRelay.sol";
import { L2GovernanceRelay } from "src/L2GovernanceRelay.sol";
import { GovernanceRelayDeploy } from "deploy/GovernanceRelayDeploy.sol";
import { GovernanceRelayInit } from "deploy/GovernanceRelayInit.sol";

contract FileSpell {
    function cast() public {
        FileLike(address(this)).file("l2Oapp", address(0x11));
        FileLike(address(this)).file("l1GovernanceRelay", address(0x22));
    }
}

// Read-only view of the LayerZero endpoint's inbound channel state, used to assert suppression effects.
interface IEndpointChannel {
    function lazyInboundNonce(address oapp, uint32 srcEid, bytes32 sender) external view returns (uint64);
    function inboundNonce(address oapp, uint32 srcEid, bytes32 sender) external view returns (uint64);
    function inboundPayloadHash(address oapp, uint32 srcEid, bytes32 sender, uint64 nonce) external view returns (bytes32);
    function delegates(address oapp) external view returns (address);
}

contract GovernanceTest is TestHelperOz5WithRevertAssertions, DssTest {
    using OptionsBuilder for bytes;
    using PacketV1Codec for bytes;

    DssInstance dss;

    uint32 aEid = 1;
    uint32 bEid = 2;

    address                pauseProxy;
    GovernanceOAppSender   aGov;
    GovernanceOAppReceiver bGov;
    L1GovernanceRelay      aRelay;
    L2GovernanceRelay      bRelay;

    address guardian = address(0x6a44d);
    bytes32 constant NIL_PAYLOAD_HASH = bytes32(type(uint256).max);

    uint256 constant DELAY        = 1 days;
    uint256 constant GRACE_PERIOD = 1 hours;

    MockControlledContract bControlledContract;

    /// @notice Calls setUp from TestHelper and initializes contract instances for testing.
    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        super.setUp();

        dss = MCD.loadFromChainlog(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);
        pauseProxy = dss.chainlog.getAddress("MCD_PAUSE_PROXY");

        // Setup function to initialize 2 Mock Endpoints with Mock MessageLib.
        setUpEndpoints(2, LibraryType.UltraLightNode);

        aGov = new GovernanceOAppSender({
            _endpoint : endpoints[aEid],
            _owner    : address(this)
        });

        bGov = new GovernanceOAppReceiver({
            _governanceOAppSenderEid     : aEid,
            _governanceOAppSenderAddress : addressToBytes32(address(aGov)),
            _endpoint                    : endpoints[bEid],
            _owner                       : address(this)
        });

        aGov.setPeer(bEid, addressToBytes32(address(bGov)));
        bGov.setPeer(aEid, addressToBytes32(address(aGov)));

        aRelay = L1GovernanceRelay(GovernanceRelayDeploy.deployL1(address(this), pauseProxy));
        vm.startPrank(pauseProxy);
        GovernanceRelayInit.init(dss, address(aRelay), address(aGov));
        vm.stopPrank();

        address[] memory buds = new address[](1);
        buds[0] = guardian;
        bRelay = L2GovernanceRelay(GovernanceRelayDeploy.deployL2(aEid, address(bGov), address(aRelay), DELAY, GRACE_PERIOD, buds));

        // bRelay is bGov's endpoint delegate, so it can manage bGov's inbound channel (skip/nilify/burn/clear).
        bGov.setDelegate(address(bRelay));

        bControlledContract = new MockControlledContract(address(bRelay));

        aGov.setCanCallTarget(address(aRelay), bEid, addressToBytes32(address(bRelay)), true);
    }

    function testRelayEvm() public {
        string memory dataBefore = bControlledContract.data();

        // Generates 1 lzReceive execution option via the OptionsBuilder library.
        // Estimating message gas fees via the quote function.
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);

        MockSpell spell = new MockSpell(bControlledContract);

        TxParams memory txParams = TxParams({
            dstEid       : bEid,
            dstTarget    : addressToBytes32(address(bRelay)),
            dstCallData  : abi.encodeWithSelector(bRelay.relay.selector, address(spell), abi.encodeWithSelector(spell.cast.selector)),
            extraOptions : options
        });
        MessagingFee memory fee = aGov.quoteTx(txParams, false);

        vm.deal(address(aRelay), fee.nativeFee);

        vm.prank(pauseProxy); aRelay.relayEVM({
            dstEid            : bEid,
            l2GovernanceRelay : address(bRelay),
            target            : address(spell),
            targetData        : abi.encodeWithSelector(spell.cast.selector),
            extraOptions      : options,
            fee               : fee,
            refundAddress     : address(this)
        });

        // Asserting that the receiving OApps have NOT had data manipulated.
        assertEq(bControlledContract.data(), dataBefore, "shouldn't be changed until lzReceive packet is verified");
        assertNotEq(bControlledContract.data(), "test message", "shouldn't be equal to expected result");

        // Deliver packet to bGov manually. This queues the action on bRelay but does NOT execute it.
        verifyAndExecutePackets(bEid, addressToBytes32(address(bGov)));

        assertEq(bRelay.actionsCount(), 1, "action should be queued");
        assertEq(bControlledContract.data(), dataBefore, "shouldn't be changed until bRelay.exec is called");

        // Warp past the configured delay before executing the queued action.
        vm.warp(block.timestamp + bRelay.delay());
        bRelay.exec(0);

        // Asserting that the data variable has updated in the receiving OApp.
        assertEq(bControlledContract.data(), "test message", "exec data assertion failure");
    }

    function testFileSpell() public {
        assertNotEq(address(bRelay.l2Oapp()), address(0x11));
        assertNotEq(bRelay.l1GovernanceRelay(), address(0x22));

        // Generates 1 lzReceive execution option via the OptionsBuilder library.
        // Estimating message gas fees via the quote function.
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);

        FileSpell spell = new FileSpell();

        TxParams memory txParams = TxParams({
            dstEid       : bEid,
            dstTarget    : addressToBytes32(address(bRelay)),
            dstCallData  : abi.encodeWithSelector(bRelay.relay.selector, address(spell), abi.encodeWithSelector(spell.cast.selector)),
            extraOptions : OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0)
        });
        MessagingFee memory fee = aGov.quoteTx(txParams, false);

        vm.deal(address(aRelay), fee.nativeFee);

        vm.prank(pauseProxy); aRelay.relayEVM({
            dstEid            : bEid,
            l2GovernanceRelay : address(bRelay),
            target            : address(spell),
            targetData        : abi.encodeWithSelector(spell.cast.selector),
            extraOptions      : options,
            fee               : fee,
            refundAddress     : address(this)
        });

        // Deliver packet to bGov manually. This queues the action on bRelay but does NOT execute it.
        verifyAndExecutePackets(bEid, addressToBytes32(address(bGov)));

        assertEq(bRelay.actionsCount(), 1, "action should be queued");
        assertNotEq(address(bRelay.l2Oapp()), address(0x11));
        assertNotEq(bRelay.l1GovernanceRelay(), address(0x22));

        // Warp past the configured delay before executing the queued action.
        vm.warp(block.timestamp + bRelay.delay());
        bRelay.exec(0);

        assertEq(address(bRelay.l2Oapp()), address(0x11));
        assertEq(bRelay.l1GovernanceRelay(), address(0x22));
    }

    // --- LayerZero channel suppression against the real endpoint ---
    // bRelay is seeded with `guardian` as a bud and set as bGov's endpoint delegate in setUp.

    // Sends one governance message L1 -> L2 and verifies (commits) it WITHOUT executing lzReceive, leaving a
    // verified-but-undelivered inbound packet at nonce 1 — the "stuck message" these functions exist to clear.
    function _sendAndVerifyOnly() internal returns (bytes32 guid, bytes memory message) {
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        MockSpell spell = new MockSpell(bControlledContract);

        TxParams memory txParams = TxParams({
            dstEid       : bEid,
            dstTarget    : addressToBytes32(address(bRelay)),
            dstCallData  : abi.encodeWithSelector(bRelay.relay.selector, address(spell), abi.encodeWithSelector(spell.cast.selector)),
            extraOptions : options
        });
        MessagingFee memory fee = aGov.quoteTx(txParams, false);
        vm.deal(address(aRelay), fee.nativeFee);

        vm.prank(pauseProxy); aRelay.relayEVM({
            dstEid            : bEid,
            l2GovernanceRelay : address(bRelay),
            target            : address(spell),
            targetData        : abi.encodeWithSelector(spell.cast.selector),
            extraOptions      : options,
            fee               : fee,
            refundAddress     : address(this)
        });

        bytes memory packetBytes = getNextInflightPacket(uint16(bEid), addressToBytes32(address(bGov)));
        this.validatePacket(packetBytes, "");
        guid    = this.packetGuid(packetBytes);
        message = this.packetMessage(packetBytes);
    }

    // PacketV1Codec slices calldata, so expose external helpers to decode an in-memory packet.
    function packetGuid(bytes calldata p) external pure returns (bytes32) { return p.guid(); }
    function packetMessage(bytes calldata p) external pure returns (bytes memory) { return p.message(); }

    function testEndpointSkip() public {
        IEndpointChannel ep = IEndpointChannel(endpoints[bEid]);
        bytes32 peer = addressToBytes32(address(aGov));

        assertEq(ep.lazyInboundNonce(address(bGov), aEid, peer), 0);

        // Non-bud is rejected at the relay before reaching the endpoint.
        vm.expectRevert("L2GovernanceRelay/not-whitelisted");
        bRelay.skip(1);

        vm.prank(guardian); bRelay.skip(1);
        assertEq(ep.lazyInboundNonce(address(bGov), aEid, peer), 1);
    }

    function testEndpointNilify() public {
        IEndpointChannel ep = IEndpointChannel(endpoints[bEid]);
        bytes32 peer = addressToBytes32(address(aGov));

        // Nilify an unverified future nonce by passing the empty payload hash.
        assertEq(ep.inboundPayloadHash(address(bGov), aEid, peer, 1), bytes32(0));
        vm.prank(guardian); bRelay.nilify(1, bytes32(0));
        assertEq(ep.inboundPayloadHash(address(bGov), aEid, peer, 1), NIL_PAYLOAD_HASH);
    }

    function testEndpointClear() public {
        IEndpointChannel ep = IEndpointChannel(endpoints[bEid]);
        bytes32 peer = addressToBytes32(address(aGov));

        (bytes32 guid, bytes memory message) = _sendAndVerifyOnly();

        // Verified but not yet delivered: payload hash present, lazy nonce not advanced.
        assertNotEq(ep.inboundPayloadHash(address(bGov), aEid, peer, 1), bytes32(0));
        assertEq(ep.lazyInboundNonce(address(bGov), aEid, peer), 0);

        vm.prank(guardian); bRelay.clear(1, guid, message);

        // Consumed without delivery: payload cleared, lazy nonce advanced past it.
        assertEq(ep.inboundPayloadHash(address(bGov), aEid, peer, 1), bytes32(0));
        assertEq(ep.lazyInboundNonce(address(bGov), aEid, peer), 1);
    }

    function testEndpointBurn() public {
        IEndpointChannel ep = IEndpointChannel(endpoints[bEid]);
        bytes32 peer = addressToBytes32(address(aGov));

        _sendAndVerifyOnly();
        bytes32 payloadHash = ep.inboundPayloadHash(address(bGov), aEid, peer, 1);
        assertNotEq(payloadHash, bytes32(0));

        // burn() only applies to nonces at or below the lazy nonce, so skip past nonce 1 first.
        vm.prank(guardian); bRelay.skip(2);
        assertEq(ep.lazyInboundNonce(address(bGov), aEid, peer), 2);

        vm.prank(guardian); bRelay.burn(1, payloadHash);
        assertEq(ep.inboundPayloadHash(address(bGov), aEid, peer, 1), bytes32(0));
    }

    function testEndpointSuppressionRevertsWhenNotDelegate() public {
        IEndpointChannel ep = IEndpointChannel(endpoints[bEid]);

        // Point the delegate away from bRelay so it is no longer authorized on the endpoint.
        bGov.setDelegate(address(0xdead));
        assertNotEq(ep.delegates(address(bGov)), address(bRelay));

        // The relay is a bud, so it passes `toll`, but the endpoint rejects the unauthorized caller.
        vm.expectRevert(abi.encodeWithSignature("LZ_Unauthorized()"));
        vm.prank(guardian); bRelay.skip(1);
    }
}
