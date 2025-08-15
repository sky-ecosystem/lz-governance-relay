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

// Note: we assume that if used, the LZ token is examined to be standard and revert on failure
interface TokenLike {
    function approve(address spender, uint256 amount) external;
    function transfer(address recipient, uint256 amount) external;
}

// https://github.com/sky-ecosystem/sky-oapp-oft/blob/08e5065815a9b7ecff62656aed3fb843b4cf387f/contracts/GovernanceControllerOApp.sol
interface GovernanceControllerLike {
    function sendEVMAction(
        GovernanceMessage calldata _message,
        uint32                     _dstEid,
        bytes calldata             _extraOptions,
        MessagingFee calldata      _fee,
        address                    _refundAddress
    ) external payable;

    function sendRawBytesAction(
        bytes calldata        _message,
        uint32                _dstEid,
        bytes calldata        _extraOptions,
        MessagingFee calldata _fee,
        address               _refundAddress
    ) external payable;

    enum GovernanceAction {
        UNDEFINED,
        EVM_CALL
    }
}

interface L2GovernanceRelayLike {
    function relay(address target, bytes calldata targetData) external;
}

// https://github.com/sky-ecosystem/sky-oapp-oft/blob/08e5065815a9b7ecff62656aed3fb843b4cf387f/contracts/GovernanceMessageEVMCodec.sol#L20
struct GovernanceMessage {
    uint8 action;
    bytes32 originCaller;
    address governedContract;
    bytes callData;
}

// https://github.com/LayerZero-Labs/LayerZero-v2/blob/200cda254120375f40ed0a7e89931afb897b8891/packages/layerzero-v2/evm/protocol/contracts/interfaces/ILayerZeroEndpointV2.sol#L24
struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

contract L1GovernanceRelay {
    // --- storage variables ---

    mapping(address => uint256) public wards;
    TokenLike                   public lzToken;
    GovernanceControllerLike    public l1Oapp;

    // --- events ---

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, address data);

    // --- modifiers ---

    modifier auth() {
        require(wards[msg.sender] == 1, "L1GovernanceRelay/not-authorized");
        _;
    }

    // --- constructor ---

    constructor() {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    // --- administration ---

    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }

    function file(bytes32 what, address data) external auth {
        if      (what == "lzToken") lzToken = TokenLike(data);
        else if (what == "l1Oapp")  l1Oapp  = GovernanceControllerLike(data);
        else revert("L1GovernanceRelay/file-unrecognized-param");
        emit File(what, data);
    }

    // --- logic ---

    receive() external payable {}

    function reclaim(address receiver, uint256 amount) external auth {
        (bool sent, ) = receiver.call{value: amount}("");
        require(sent, "L1GovernanceRelay/failed-to-send-ether");
    }

    function reclaimLzToken(address receiver, uint256 amount) external auth {
        lzToken.transfer(receiver, amount);
    }

    // It is not likely that lzTokenFee is used, but if so, governance is assumed to monitor LZ for token changes.
    // If deemed needed, this includes a check in the spell itself and fallback code.
    // Note that just reading the token from the endpoint might pose a security risk if the token is malicious.
    // The above is relevant also to relayRawBytes.
    function relayEVM(
        uint32                dstEid,
        bytes calldata        extraOptions,
        MessagingFee calldata fee,
        address               refundAddress,
        address               l2GovernanceRelay,
        address               target,
        bytes calldata        targetData
    ) external payable auth {
        GovernanceMessage memory message = GovernanceMessage({
            action           : uint8(GovernanceControllerLike.GovernanceAction.EVM_CALL),
            originCaller     : bytes32(uint256(uint160(address(this)))),
            governedContract : l2GovernanceRelay,
            callData         : abi.encodeCall(L2GovernanceRelayLike.relay, (target, targetData))
        });

        if (fee.nativeFee > 0) {
            l1Oapp.sendEVMAction{value: fee.nativeFee}(message, dstEid, extraOptions, fee, refundAddress);
        } else if (fee.lzTokenFee > 0) {
            lzToken.approve(address(l1Oapp), fee.lzTokenFee);
            l1Oapp.sendEVMAction(message, dstEid, extraOptions, fee, refundAddress);
        } else revert("L1GovernanceRelay/zero-fee");
    }

    function relayRawBytes(
        uint32                dstEid,
        bytes calldata        extraOptions,
        MessagingFee calldata fee,
        address               refundAddress,
        bytes calldata        message
    ) external payable auth {
        if (fee.nativeFee > 0) {
            l1Oapp.sendRawBytesAction{value: fee.nativeFee}(message, dstEid, extraOptions, fee, refundAddress);
        } else if (fee.lzTokenFee > 0) {
            lzToken.approve(address(l1Oapp), fee.lzTokenFee);
            l1Oapp.sendRawBytesAction(message, dstEid, extraOptions, fee, refundAddress);
        } else revert("L1GovernanceRelay/zero-fee");
    }
}
