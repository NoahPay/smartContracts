// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IFlashLoanRollerExecute {
    // This function is called by the FlashLoanProvider contract during the flash loan process.
    function execute(address _from, address _to, uint256 amount, uint256 flashFee) external;
}