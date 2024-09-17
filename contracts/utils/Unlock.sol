// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function balanceOf(address account) external returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IWFPS {
    function depositFor(address account, uint256 amount) external returns (bool);
    function unwrapAndSell(uint256 amount) external;
}

contract Unlock {
    IERC20 private immutable zchf = IERC20(0xB58E61C3098d85632Df34EecfB899A1Ed80921cB);
    IERC20 private immutable fps = IERC20(0x1bA26788dfDe592fec8bcB0Eaff472a42BE341B2);
    IWFPS private immutable wfps = IWFPS(0x5052D3Cc819f53116641e89b96Ff4cD1EE80B182);

    function approveInfinity() external {
        fps.approve(address(wfps), 1 << 255); // withlist the wrapper contract
    }

    function unlockAndRedeem(uint256 amount) external {
        fps.transferFrom(msg.sender, address(this), amount);

        wfps.depositFor(address(this), amount);
        wfps.unwrapAndSell(amount);

        zchf.transfer(msg.sender, zchf.balanceOf(address(this)));
    }
}
