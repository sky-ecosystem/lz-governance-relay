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

import { IGovernanceController } from "lib/sky-oapp-oft/contracts/IGovernanceController.sol";

contract L2GovernanceRelay {
    // --- storage variables ---

    IGovernanceController public l2Oapp;
    address               public l1GovernanceRelay;

    // --- immutables ---

    uint32 immutable public l1Eid;

    // --- events ---

    event File(bytes32 indexed what, address data);

    // --- modifiers ---

    modifier messageAuth() {
        (uint32 originEid, bytes32 originCaller) = l2Oapp.messageOrigin();
        require(
            msg.sender                              == address(l2Oapp) &&
            originEid                               == l1Eid &&
            address(uint160(uint256(originCaller))) == l1GovernanceRelay,
            "L2GovernanceRelay/bad-message-auth"
        );
        _;
    }

    // --- constructor ---

    constructor(uint32 _l1Eid, address _l2Oapp, address _l1GovernanceRelay) {
        l1Eid             = _l1Eid;
        l2Oapp            = IGovernanceController(_l2Oapp);
        l1GovernanceRelay = _l1GovernanceRelay;
    }

    // --- administration ---

    // This is not a standard `file` function, do not copy elsewhere.
    function file(bytes32 what, address data) external {
        require(msg.sender == address(this), "L2GovernanceRelay/sender-not-this");
        if      (what == "l2Oapp")            l2Oapp            = IGovernanceController(data);
        else if (what == "l1GovernanceRelay") l1GovernanceRelay = data;
        else revert("L2GovernanceRelay/file-unrecognized-param");
        emit File(what, data);
    }

    // --- relay ---

    function relay(address target, bytes calldata targetData) external messageAuth {
        (bool success, bytes memory result) = target.delegatecall(targetData);
        if (!success) {
            if (result.length == 0) revert("L2GovernanceRelay/delegatecall-error");
            assembly ("memory-safe") {
                revert(add(32, result), mload(result))
            }
        }
    }
}
