// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.22;

import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

import { GovernanceControllerOApp } from "lib/sky-oapp-oft/contracts/GovernanceControllerOApp.sol";
import { GovernanceMessageEVMCodec } from "lib/sky-oapp-oft/contracts/GovernanceMessageEVMCodec.sol";
import { GovernanceAction } from "lib/sky-oapp-oft/contracts/IGovernanceController.sol";
import { MockControlledContract } from "lib/sky-oapp-oft/test/mocks/MockControlledContract.sol";
import { MockSpell } from "lib/sky-oapp-oft/test/mocks/MockSpell.sol";
import { TestHelperOz5WithRevertAssertions } from "lib/sky-oapp-oft/test/foundry/helpers/TestHelperOz5WithRevertAssertions.sol";

import { L1GovernanceRelay } from "src/L1GovernanceRelay.sol";
import { L2GovernanceRelay } from "src/L2GovernanceRelay.sol";

interface FileLike {
    function file(bytes32 what, address data) external;
}

contract FileSpell {
    function cast() public {
        FileLike(address(this)).file("l2Oapp", address(0x55));
        FileLike(address(this)).file("l1GovernanceRelay", address(0x66));
    }
}

contract GovernanceTest is TestHelperOz5WithRevertAssertions {
    using OptionsBuilder for bytes;

    uint32 aEid = 1;
    uint32 bEid = 2;

    GovernanceControllerOApp aGov;
    GovernanceControllerOApp bGov;
    L1GovernanceRelay        aRelay;
    L2GovernanceRelay        bRelay;

    MockControlledContract aControlledContract;
    MockControlledContract bControlledContract;

    /// @notice Calls setUp from TestHelper and initializes contract instances for testing.
    function setUp() public virtual override {
        super.setUp();

        // Setup function to initialize 2 Mock Endpoints with Mock MessageLib.
        setUpEndpoints(2, LibraryType.UltraLightNode);

        aGov = new GovernanceControllerOApp({
            _endpoint                           : endpoints[aEid],
            _delegate                           : address(this),
            _addInitialValidTarget              : false,
            _initialValidTargetSrcEid           : 0,
            _initialValidTargetOriginCaller     : bytes32(0),
            _initialValidTargetGovernedContract : address(0)
        });

        bGov = new GovernanceControllerOApp({
            _endpoint                           : endpoints[bEid],
            _delegate                           : address(this),
            _addInitialValidTarget              : false,
            _initialValidTargetSrcEid           : 0,
            _initialValidTargetOriginCaller     : bytes32(0),
            _initialValidTargetGovernedContract : address(0)
        });

        aGov.setPeer(bEid, addressToBytes32(address(bGov)));
        bGov.setPeer(aEid, addressToBytes32(address(aGov)));

        aRelay = new L1GovernanceRelay();
        aRelay.file("l1Oapp", address(aGov));

        bRelay = new L2GovernanceRelay(aEid, address(bGov), address(aRelay) );

        aControlledContract = new MockControlledContract(address(aRelay));
        bControlledContract = new MockControlledContract(address(bRelay));

        aGov.addValidCaller(address(aRelay));
        bGov.addValidTarget(aEid, addressToBytes32(address(aRelay)), address(bRelay));
    }

    function testRelayEvm() public {
        string memory dataBefore = bControlledContract.data();

        // Generates 1 lzReceive execution option via the OptionsBuilder library.
        // Estimating message gas fees via the quote function.
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(150000, 0);

        MockSpell spell = new MockSpell(bControlledContract);

        GovernanceMessageEVMCodec.GovernanceMessage memory message = GovernanceMessageEVMCodec.GovernanceMessage({
            action           : uint8(GovernanceAction.EVM_CALL),
            originCaller     : addressToBytes32(address(aRelay)),
            governedContract : address(bRelay),
            callData         : abi.encodeWithSelector(bRelay.relay.selector, address(spell), abi.encodeWithSelector(spell.cast.selector))
        });
        MessagingFee memory fee = aGov.quoteEVMAction(message, bEid, options, false);

        vm.deal(address(aRelay), fee.nativeFee);

        aRelay.relayEVM({
            dstEid            : bEid,
            extraOptions      : options,
            fee               : fee,
            refundAddress     : address(this),
            l2GovernanceRelay : address(bRelay),
            target            : address(spell),
            targetData        : abi.encodeWithSelector(spell.cast.selector)
        });

        // Asserting that the receiving OApps have NOT had data manipulated.
        assertEq(bControlledContract.data(), dataBefore, "shouldn't be changed until lzReceive packet is verified");

        // Deliver packet to bGov manually.
        verifyAndExecutePackets(bEid, addressToBytes32(address(bGov)));

        // Asserting that the data variable has updated in the receiving OApp.
        assertEq(bControlledContract.data(), "test message", "lzReceive data assertion failure");
    }

    function testRelayRawBytes() public {
        string memory dataBefore = bControlledContract.data();

        // Generates 1 lzReceive execution option via the OptionsBuilder library.
        // Estimating message gas fees via the quote function.
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(150000, 0);

        MockSpell spell = new MockSpell(bControlledContract);

        GovernanceMessageEVMCodec.GovernanceMessage memory message = GovernanceMessageEVMCodec.GovernanceMessage({
            action           : uint8(GovernanceAction.EVM_CALL),
            originCaller     : addressToBytes32(address(aRelay)),
            governedContract : address(bRelay),
            callData         : abi.encodeWithSelector(bRelay.relay.selector, address(spell), abi.encodeWithSelector(spell.cast.selector))
        });
        bytes memory messageBytes = GovernanceMessageEVMCodec.encode(message);
        MessagingFee memory fee = aGov.quoteRawBytesAction(messageBytes, bEid, options, false);

        vm.deal(address(aRelay), fee.nativeFee);

        aRelay.relayRawBytes({
            dstEid        : bEid,
            extraOptions  : options,
            fee           : fee,
            refundAddress : address(this),
            message       : messageBytes
        });

        // Asserting that the receiving OApps have NOT had data manipulated.
        assertEq(bControlledContract.data(), dataBefore, "shouldn't be changed until lzReceive packet is verified");

        // Deliver packet to bGov manually.
        verifyAndExecutePackets(bEid, addressToBytes32(address(bGov)));

        // Asserting that the data variable has updated in the receiving OApp.
        assertEq(bControlledContract.data(), "test message", "lzReceive data assertion failure");
    }

    function testFile() public {
        assertNotEq(address(bRelay.l2Oapp()), address(0x55));
        assertNotEq(bRelay.l1GovernanceRelay(), address(0x66));

        // Generates 1 lzReceive execution option via the OptionsBuilder library.
        // Estimating message gas fees via the quote function.
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(150000, 0);

        FileSpell spell = new FileSpell();

        GovernanceMessageEVMCodec.GovernanceMessage memory message = GovernanceMessageEVMCodec.GovernanceMessage({
            action           : uint8(GovernanceAction.EVM_CALL),
            originCaller     : addressToBytes32(address(aRelay)),
            governedContract : address(bRelay),
            callData         : abi.encodeWithSelector(bRelay.relay.selector, address(spell), abi.encodeWithSelector(spell.cast.selector))
        });
        MessagingFee memory fee = aGov.quoteEVMAction(message, bEid, options, false);

        vm.deal(address(aRelay), fee.nativeFee);

        aRelay.relayEVM({
            dstEid            : bEid,
            extraOptions      : options,
            fee               : fee,
            refundAddress     : address(this),
            l2GovernanceRelay : address(bRelay),
            target            : address(spell),
            targetData        : abi.encodeWithSelector(spell.cast.selector)
        });

        // Deliver packet to bGov manually.
        verifyAndExecutePackets(bEid, addressToBytes32(address(bGov)));

        assertEq(address(bRelay.l2Oapp()), address(0x55));
        assertEq(bRelay.l1GovernanceRelay(), address(0x66));
    }
}
