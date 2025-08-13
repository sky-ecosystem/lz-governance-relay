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

import { GemMock } from "test/mocks/GemMock.sol";

struct GovernanceMessage {
    uint8 action;
    bytes32 originCaller;
    address governedContract;
    bytes callData;
}

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

struct MessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    MessagingFee fee;
}

struct GovernanceOrigin {
    uint32 eid; // LayerZero Endpoint ID
    bytes32 caller; // Caller on the source chain
}

contract OappMock {

    GemMock public lzToken;
    GovernanceOrigin public messageOrigin;

    constructor(address _lzToken) {
        lzToken = GemMock(_lzToken);
    }

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

    function sendEVMAction(
        GovernanceMessage calldata _message,
        uint32 _dstEid,
        bytes calldata _extraOptions,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable /* onlyValidCaller */ returns (MessagingReceipt memory receipt) {

        require(msg.value == _fee.nativeFee, "OappMock/NotEnoughNative");
        if (_fee.lzTokenFee > 0) lzToken.transferFrom(msg.sender, address(this), _fee.lzTokenFee);

        emit SentMessageEVM(
            _message.action, // logging only the first field
            _message.originCaller,
            _message.governedContract,
            _message.callData,
            _dstEid,
            _extraOptions,
            _fee.nativeFee,
            _fee.lzTokenFee,
            _refundAddress
        );

        // Note that this should actually happen on the receiving chain, but added here for testing purposes
        (bool success, bytes memory returnData) = _message.governedContract.call{value: 0}(_message.callData);
        if (!success) {
            if (returnData.length == 0) revert("OappMock/length-error");
            assembly ("memory-safe") {
                revert(add(32, returnData), mload(returnData))
            }
        }
    }

    function sendRawBytesAction(
        bytes calldata _message,
        uint32 _dstEid,
        bytes calldata _extraOptions,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable /* onlyValidCaller */ returns (MessagingReceipt memory receipt) {

        require(msg.value == _fee.nativeFee, "OappMock/NotEnoughNative");
        if (_fee.lzTokenFee > 0) lzToken.transferFrom(msg.sender, address(this), _fee.lzTokenFee);

        emit SentMessageRaw(
            _message,
            _dstEid,
            _extraOptions,
            _fee.nativeFee,
            _fee.lzTokenFee,
            _refundAddress
        );
    }

    function setMessageOrigin(uint32 _eid, bytes32 _caller) external {
        messageOrigin = GovernanceOrigin({
            eid: _eid,
            caller: _caller
        });
    }
}
