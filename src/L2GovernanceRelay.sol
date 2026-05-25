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

import { IGovernanceOAppReceiver, MessageOrigin } from "lib/sky-oapp-oft/contracts/interfaces/IGovernanceOAppReceiver.sol";

contract L2GovernanceRelay {
    // --- storage variables ---

    IGovernanceOAppReceiver public l2Oapp;                  // Sender address which queues actions
    address                 public l1GovernanceRelay;       // L1 counterpart of this contract (L1 sender)
    uint256                 public actionsCount;            // Number of actions ever created
    uint256                 public canceledId;              // Cancelation checkpoint Id (every action not executed up to this id is canceled)
    uint256                 public delay;                   // Time between queuing and execution
    uint256                 public gracePeriod;             // Time after delay during which an action can be executed, otherwise gets expired

    mapping(uint256 => Action) private _actions;            // Map of actions created (id => Action)
    mapping(address usr => uint256 whitelisted) public bud; // Guardians that can cancel queued proposals

    struct Action {
        address target;
        bytes   targetData;
        uint256 executionTime;
        bool    executed;
    }

    // --- immutables ---

    uint32 immutable public l1Eid;

    // --- constants ---

    uint256 public constant MINIMUM_GRACE_PERIOD = 10 minutes;

    // --- enums ---

    enum ActionState {
        Queued,
        Ready,
        Executed,
        Canceled,
        Expired
    }

    // --- events ---

    event Kiss(address indexed usr);
    event Diss(address indexed usr);
    event File(bytes32 indexed what, address data);
    event File(bytes32 indexed what, uint256 data);
    event ActionQueued(uint256 indexed id, address target, bytes targetData, uint256 executionTime);
    event ActionExecuted(uint256 indexed id, address indexed initiatorExecution, bytes returnedData);
    event ActionsCanceled(uint256 indexed id);

    // --- modifiers ---

    modifier onlySelf() {
        require(msg.sender == address(this), "L2GovernanceRelay/sender-not-this");
        _;
    }

    modifier messageAuth() {
        MessageOrigin memory messageOrigin = l2Oapp.messageOrigin();
        require(
            msg.sender                                         == address(l2Oapp) &&
            messageOrigin.srcEid                               == l1Eid &&
            address(uint160(uint256(messageOrigin.srcSender))) == l1GovernanceRelay,
            "L2GovernanceRelay/bad-message-auth"
        );
        _;
    }

    modifier toll {
        require(bud[msg.sender] == 1, "L2GovernanceRelay/not-whitelisted");
        _;
    }

    // --- constructor ---

    // Initial setting are passed on construction to allow self-configuration
    constructor(
        uint32 l1Eid_,
        address l2Oapp_,
        address l1GovernanceRelay_,
        uint256 delay_,
        uint256 gracePeriod_
    ) {
        require(gracePeriod_ >= MINIMUM_GRACE_PERIOD, "L2GovernanceRelay/grace-period-too-short");

        l1Eid             = l1Eid_;
        l2Oapp            = IGovernanceOAppReceiver(l2Oapp_);
        l1GovernanceRelay = l1GovernanceRelay_;
        delay             = delay_;
        gracePeriod       = gracePeriod_;

        emit File("delay", delay_);
        emit File("gracePeriod", gracePeriod_);
    }

    // --- administration functions ---

    // These are not a standard authed `kiss`, `diss` and `file` functions, do not copy elsewhere.

    function kiss(address usr) external onlySelf {
        bud[usr] = 1;

        emit Kiss(usr);
    }

    function diss(address usr) external onlySelf {
        bud[usr] = 0;

        emit Diss(usr);
    }

    // Use caution when changing parameters, as a wrong value can brick remote governance.
    function file(bytes32 what, address data) external onlySelf {
        if      (what == "l2Oapp")            l2Oapp            = IGovernanceOAppReceiver(data);
        else if (what == "l1GovernanceRelay") l1GovernanceRelay = data;
        else revert("L2GovernanceRelay/file-unrecognized-param");

        emit File(what, data);
    }

    function file(bytes32 what, uint256 data) external onlySelf {
        if      (what == "delay") delay = data;
        else if (what == "gracePeriod") {
            require(data >= MINIMUM_GRACE_PERIOD, "L2GovernanceRelay/grace-period-too-short");
            gracePeriod = data;
        }
        else revert("L2GovernanceRelay/file-unrecognized-param");

        emit File(what, data);
    }

    // --- view functions ---

    function getActionById(uint256 actionId) external view returns (Action memory) {
        require(actionId > 0 && actionId <= actionsCount, "L2GovernanceRelay/invalid-action-id");

        return _actions[actionId];
    }

    function getActionState(uint256 actionId) public view returns (ActionState) {
        require(actionId > 0 && actionId <= actionsCount, "L2GovernanceRelay/invalid-action-id");

        Action memory action = _actions[actionId];
        if      (action.executed) return ActionState.Executed;
        else if (actionId <= canceledId) return ActionState.Canceled; // It is fine that expired ones could be "converted" to canceled
        else if (block.timestamp >  action.executionTime + gracePeriod) return ActionState.Expired;
        else if (block.timestamp >= action.executionTime) return ActionState.Ready;
        else return ActionState.Queued;
    }

    // --- relay functions ---

    // Not expected/needed to get eth, hence not payable.
    function relay(address target, bytes calldata targetData) external messageAuth {
        uint256 executionTime = block.timestamp + delay;
        uint256 actionId = ++actionsCount;

        Action storage action = _actions[actionId];
        action.target         = target;
        action.targetData     = targetData;
        action.executionTime  = executionTime;

        emit ActionQueued(
            actionId,
            target,
            targetData,
            executionTime
        );
    }

    function exec(uint256 actionId) external {
        require(getActionState(actionId) == ActionState.Ready, "L2GovernanceRelay/not-ready");

        Action storage action = _actions[actionId];
        action.executed = true;

        (bool success, bytes memory result) = action.target.delegatecall(action.targetData);
        if (!success) {
            if (result.length == 0) revert("L2GovernanceRelay/delegatecall-error");
            assembly ("memory-safe") {
                revert(add(32, result), mload(result))
            }
        }

        emit ActionExecuted(actionId, msg.sender, result);
    }

    function cancel(uint256 canceledId_) external toll {
        require(canceledId_ > 0 && canceledId_ <= actionsCount, "L2GovernanceRelay/invalid-action-id");
        require(canceledId_ > canceledId, "L2GovernanceRelay/already-included");

        canceledId = canceledId_;

        emit ActionsCanceled(canceledId_);
    }
}
