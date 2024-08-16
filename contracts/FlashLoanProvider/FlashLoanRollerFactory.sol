// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./FlashLoanRoller.sol";

contract FlashLoanRollerFactory {
    function createRoller(address _owner, address _zchf, address _flash) external returns (address) {
        return address(
            new FlashLoanRoller(
                _owner,
                _zchf,
                _flash
            )
        );
    }
}