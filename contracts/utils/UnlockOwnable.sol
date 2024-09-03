// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./FPSWrapper.sol";
import "./Ownable.sol";
import "../Frankencoin.sol";
import "../Equity.sol";

contract Unlock is Ownable {
    Frankencoin private immutable zchf;
    Equity private immutable fps;
    FPSWrapper private immutable wfps;

    constructor() {
        _setOwner(msg.sender);
        zchf = Frankencoin(0xB58E61C3098d85632Df34EecfB899A1Ed80921cB);
        fps = Equity(0x1bA26788dfDe592fec8bcB0Eaff472a42BE341B2);
        wfps = FPSWrapper(0x5052D3Cc819f53116641e89b96Ff4cD1EE80B182);
    }

    function unlockAndRedeem(uint256 amount) public onlyOwner {
        fps.transferFrom(msg.sender, address(this), amount);

        fps.approve(address(wfps), amount);
        wfps.depositFor(address(this), amount);
        wfps.unwrapAndSell(amount);

        zchf.transfer(msg.sender, zchf.balanceOf(address(this)));
    }
}
