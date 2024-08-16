// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IFlashLoanExecuteRolling {
    // This function is called by the FlashLoanProvider contract during the flash loan process.
    function executeRolling(address _from, address _to, uint256 amount) external;
}