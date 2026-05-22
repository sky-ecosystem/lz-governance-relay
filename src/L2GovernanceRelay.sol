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

    IGovernanceOAppReceiver public l2Oapp;
    address                 public l1GovernanceRelay;
    uint256                 public actionsCount;               // Number of actions
    uint256                 public delay;                      // Time between queuing and execution
    uint256                 public gracePeriod;                // Time after delay during which an action can be executed

    mapping(uint256 => Action) private _actions;            // Map of registered actions (id => Action)
    mapping(address usr => uint256 whitelisted) public bud; // Guardians that can cancel scheduled proposals

    struct Action {
        address target;
        bytes   targetData;
        uint256 executionTime;
        bool    executed;
        bool    canceled;
    }

    // --- immutables ---

    uint32 immutable public l1Eid;

    // --- constants ---

    uint256 public constant MINIMUM_GRACE_PERIOD = 10 minutes;

    // --- enums ---

    enum ActionState {
        Queued,
        Executed,
        Canceled,
        Expired
    }

    // --- events ---

    event Kiss(address indexed usr);
    event Diss(address indexed usr);
    event File(bytes32 indexed what, address data);
    event File(bytes32 indexed what, uint256 data);
    event ActionQueued(uint256 indexed id, address target, bytes   targetData, uint256 executionTime);
    event ActionExecuted(uint256 indexed id, address indexed initiatorExecution, bytes returnedData);
    event ActionCanceled(uint256 indexed id);

    // --- modifiers ---

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
    constructor(uint32 _l1Eid, address _l2Oapp, address _l1GovernanceRelay) {
        l1Eid             = _l1Eid;
        l2Oapp            = IGovernanceOAppReceiver(_l2Oapp);
        l1GovernanceRelay = _l1GovernanceRelay;
        gracePeriod       = MINIMUM_GRACE_PERIOD;
    }

    // --- administration ---

    // These are not a standard `kiss`, `diss` and `file` functions, do not copy elsewhere.

    function kiss(address usr) external {
        require(msg.sender == address(this), "L2GovernanceRelay/sender-not-this");
        bud[usr] = 1;
        emit Kiss(usr);
    }

    function diss(address usr) external {
        require(msg.sender == address(this), "L2GovernanceRelay/sender-not-this");
        bud[usr] = 0;
        emit Diss(usr);
    }

    // Use caution when changing parameters, as a wrong value can brick remote governance.
    function file(bytes32 what, address data) external {
        require(msg.sender == address(this), "L2GovernanceRelay/sender-not-this");
        if      (what == "l2Oapp")            l2Oapp            = IGovernanceOAppReceiver(data);
        else if (what == "l1GovernanceRelay") l1GovernanceRelay = data;
        else revert("L2GovernanceRelay/file-unrecognized-param");
        emit File(what, data);
    }

    function file(bytes32 what, uint256 data) external {
        require(msg.sender == address(this), "L2GovernanceRelay/sender-not-this");
        if      (what == "delay")       delay       = data;
        else if (what == "gracePeriod") {
            require(data >= MINIMUM_GRACE_PERIOD, "L2GovernanceRelay/grace-period-too-short");
            gracePeriod = data;
        }
        else revert("L2GovernanceRelay/file-unrecognized-param");
        emit File(what, data);
    }

    // --- relay ---

    // Not expected/needed to get eth, hence not payable.
    function relay(address target, bytes calldata targetData) external messageAuth {
        uint256 actionId      = actionsCount;
        uint256 executionTime = block.timestamp + delay;

        unchecked { ++actionsCount; }

        Action storage action = _actions[actionId];

        action.target        = target;
        action.targetData    = targetData;
        action.executionTime = executionTime;

        emit ActionQueued(
            actionId,
            target,
            targetData,
            executionTime
        );
    }

    function exec(uint256 actionId) external {
        require(getActionState(actionId) == ActionState.Queued, "L2GovernanceRelay/not-queued");

        Action storage action = _actions[actionId];

        require(block.timestamp >= action.executionTime, "L2GovernanceRelay/timelock-not-finished");

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

    function cancel(uint256 actionId) external toll {
        require(getActionState(actionId) == ActionState.Queued, "L2GovernanceRelay/not-queued");

        Action storage action = _actions[actionId];
        action.canceled = true;

        emit ActionCanceled(actionId);
    }

    /******************************************************************************************************************/
    /*** External view functions                                                                                    ***/
    /******************************************************************************************************************/

    function getActionById(uint256 actionId) external view returns (Action memory) {
        return _actions[actionId];
    }

    function getActionState(uint256 actionId) public view returns (ActionState) {
        require(actionId < actionsCount, "L2GovernanceRelay/invalid-action-id");

        Action storage action = _actions[actionId];

        if      (action.canceled) return ActionState.Canceled;
        else if (action.executed) return ActionState.Executed;
        else if (block.timestamp > action.executionTime + gracePeriod) return ActionState.Expired;
        else return ActionState.Queued;
    }
}
