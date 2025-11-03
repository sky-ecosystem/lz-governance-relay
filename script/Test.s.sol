// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "forge-std/Script.sol";

import { L1GovernanceRelay, TxParams, MessagingFee } from "src/L1GovernanceRelay.sol";

interface GovOappLike {
    function setCanCallTarget(address _srcSender, uint32 _dstEid, bytes32 _dstTarget, bool _canCall) external;
    function quoteTx(TxParams calldata _params, bool _payInLzToken) external view returns (MessagingFee memory fee);
}

contract TestScript is Script {

    L1GovernanceRelay constant l1GovernanceRelay = L1GovernanceRelay(payable(address(0x2beBFe397D497b66cB14461cB6ee467b4C3B7D61)));
    GovOappLike       constant l1Oapp            = GovOappLike(address(0x0)); // TODO: fill in L1 Oapp address

    bytes constant dstCallData = ""; // TODO: fill in target data

    function run() external {

        vm.startBroadcast();

        (,address deployerAddress, ) = vm.readCallers();

        l1GovernanceRelay.file("l1Oapp", address(l1Oapp));

        // TODO: make sure we can call it or this is set, since only the l1Oapp owner can do it
        //l1Oapp.setCanCallTarget(address(l1GovernanceRelay), 30168, /* TODO addressToBytes32(address(bRelay)) */ , true);

        uint128 gas = 0;   // TODO: fill in gas amount
        uint128 value = 0; // TODO: fill in value amount

        // The following yields the same result as doing:
        // bytes memory extraOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gas, value);
        // but without the need to import OptionsBuilder
        bytes memory extraOptions = abi.encodePacked( // see addExecutorLzReceiveOption() in @layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol
            abi.encodePacked(uint16(3)),                                        // Options Type "3" (TYPE_3), the only options type currently supported by LZ
            uint8(1),                                                           // ExecutorOptions.WORKER_ID
            value == 0 ? uint16(17) : uint16(33),                               // ExecutorOptions.encodeLzReceiveOption(gas, value).length.toUint16() + 1
            uint8(1),                                                           // ExecutorOptions.OPTION_TYPE_LZRECEIVE
            value == 0 ? abi.encodePacked(gas) : abi.encodePacked(gas, value)   // ExecutorOptions.encodeLzReceiveOption(gas, value)
        );

        TxParams memory txParams = TxParams({
            dstEid       : 30168,
            dstTarget    : bytes32(""), // TODO: fill in target address
            dstCallData  : dstCallData,
            extraOptions : extraOptions
        });

        MessagingFee memory fee = l1Oapp.quoteTx({ _params : txParams, _payInLzToken : false });
        l1GovernanceRelay.relayRaw(txParams, fee, deployerAddress);

        // TODO: clean up:
        //  - l1GovernanceRelay.l1Oapp
        //  - l1Oapp mapping using setCanCallTarget
    }
}
