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

import { Origin } from "src/L2GovernanceRelay.sol";

// Records the last call made to each suppression method so tests can assert forwarding.
contract EndpointMock {
    bytes public lastSkip;
    bytes public lastNilify;
    bytes public lastBurn;
    bytes public lastClear;

    function skip(address oapp, uint32 srcEid, bytes32 sender, uint64 nonce) external {
        lastSkip = abi.encode(oapp, srcEid, sender, nonce);
    }

    function nilify(address oapp, uint32 srcEid, bytes32 sender, uint64 nonce, bytes32 payloadHash) external {
        lastNilify = abi.encode(oapp, srcEid, sender, nonce, payloadHash);
    }

    function burn(address oapp, uint32 srcEid, bytes32 sender, uint64 nonce, bytes32 payloadHash) external {
        lastBurn = abi.encode(oapp, srcEid, sender, nonce, payloadHash);
    }

    function clear(address oapp, Origin calldata origin, bytes32 guid, bytes calldata message) external {
        lastClear = abi.encode(oapp, origin, guid, message);
    }
}
