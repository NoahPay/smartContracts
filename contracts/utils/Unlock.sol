// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./FPSWrapper.sol";
import "../Frankencoin.sol";
import "../Equity.sol";

contract Unlock {
    Frankencoin private immutable zchf;
    Equity private immutable fps;
    FPSWrapper private immutable wfps;

    constructor(address _zchf, address _fps, address _wfps) {
        zchf = Frankencoin(_zchf);
        fps = Equity(_fps);
        wfps = FPSWrapper(_wfps);
    }

    function unlockAndRedeem(uint256 amount) public {
        fps.transferFrom(msg.sender, address(this), amount);
        fps.approve(address(wfps), amount);

        wfps.depositFor(address(this), amount);
        wfps.unwrapAndSell(amount);

        zchf.transfer(msg.sender, zchf.balanceOf(address(this)));
    }
}
