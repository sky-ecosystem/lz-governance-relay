// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "forge-std/Script.sol";

import { L1GovernanceRelay, TxParams, MessagingFee } from "src/L1GovernanceRelay.sol";

interface GovOappLike {
    function canCallTarget(address srcSender, uint32 dstEid, bytes32 dstTarget) external view returns (bool);
    function quoteTx(TxParams calldata _params, bool _payInLzToken) external view returns (MessagingFee memory fee);
}

contract TestScript is Script {

    L1GovernanceRelay constant l1GovernanceRelay = L1GovernanceRelay(payable(0x2beBFe397D497b66cB14461cB6ee467b4C3B7D61));
    GovOappLike       constant l1Oapp            = GovOappLike(0x27FC1DD771817b53bE48Dc28789533BEa53C9CCA);

    // base58 -d <<< "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr" | xxd -p -c 32
    bytes32 constant dstTarget = 0x054a535a992921064d24e87160da387c7c35b5ddbc92bb81e41fa8404105448d;
    // base58 -d <<< $(solana find-program-derived-address SKYGRikJcGSa3jC5HDyzDrVsmkCk3e5SqAurycny8PW string:CpiAuthority pubkey:$(solana find-program-derived-address SKYGRikJcGSa3jC5HDyzDrVsmkCk3e5SqAurycny8PW string:Governance u64be:0) u32be:30101 hex:"0000000000000000000000002bebfe397d497b66cb14461cb6ee467b4c3b7d61") | xxd -p -c 32
    bytes32 constant govRelayCpiAuthority = 0x8dc412529f876c9f3bc01d7c3095bcd6cd1d6d5177b59aa03f04e5c5b422147b;

    function run() external {

        vm.startBroadcast();

        (,address deployerAddress, ) = vm.readCallers();

        l1GovernanceRelay.file("l1Oapp", address(l1Oapp));

        // Sanity check
        require(l1Oapp.canCallTarget(address(l1GovernanceRelay), 30168, dstTarget), "l1Oapp.canCallTarget not set");

        uint128 gas = 200_000;   // TODO: make sure this is enough
        uint128 value = 0;

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

        bytes memory dstCallData = abi.encodePacked(
            uint16(1),                       // accounts_length (big-endian u16)
            govRelayCpiAuthority,            // account pubkey (32 bytes)
            uint8(1),                        // is_signer:true
            uint8(0),                        // is_writable:false
            bytes("SkyGovTest")              // data (raw bytes of the string to log)
        );

        TxParams memory txParams = TxParams({
            dstEid       : 30168,
            dstTarget    : dstTarget,
            dstCallData  : dstCallData,
            extraOptions : extraOptions
        });

        MessagingFee memory fee = l1Oapp.quoteTx({ _params : txParams, _payInLzToken : false });
        l1GovernanceRelay.relayRaw(txParams, fee, deployerAddress);
    }
}
