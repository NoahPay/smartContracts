// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../utils/Ownable.sol";

import "../interface/IERC20.sol";
import "../interface/IFrankencoin.sol";
import "../Position.sol";

import "./FlashLoanProvider.sol";
import "./IFlashLoanExecuteRolling.sol";

contract FlashLoanRoller is IFlashLoanExecuteRolling, Ownable {
    IFrankencoin public immutable zchf;
    FlashLoanProvider public immutable flash;

    // ---------------------------------------------------------------------------------------------------
    // events
    event LogInt(address from, string message, uint256 value);
    event LogAddress(address from, string message);
    event Rolled(address owner, address from, address to, uint256 flashAmount, uint256 fee);
    
    // ---------------------------------------------------------------------------------------------------
    // errors
    error PositionNotOwned();
    error PositionInsuffMint();
    error NotFlashLoanProvider();
    error CollateralNotMatching();

    // ---------------------------------------------------------------------------------------------------
    constructor (address _owner, address _zchf, address _flash) {
        zchf = IFrankencoin(_zchf);
        flash = FlashLoanProvider(_flash);

        _setOwner(_owner);
    }

    // ---------------------------------------------------------------------------------------------------
    function redeemOwnership(address toTransfer, address owner) public onlyOwner {
        Ownable(toTransfer).transferOwnership(owner);
    }

    // ---------------------------------------------------------------------------------------------------
    function redeemCollateral(address _collateral, address to) public onlyOwner {
        IERC20 collateral = IERC20(_collateral);
        collateral.transfer(to, collateral.balanceOf(address(this)));
    }

    // ---------------------------------------------------------------------------------------------------
    function preparePolling(address _from, address _to) external onlyOwner {
        Position from = Position(_from);
        Position to = Position(_to);

        if (from.owner() != address(this)) revert PositionNotOwned();
        if (to.owner() != address(this)) revert PositionNotOwned();
        if (from.collateral() != to.collateral()) revert CollateralNotMatching();

        uint256 minted = from.minted();
        if (minted < 1 ether) revert PositionInsuffMint();

        uint256 inReserve = minted * from.reserveContribution() / 1_000_000;
        uint256 toMint = minted - inReserve;
        uint256 flashFee = toMint * flash.FLASHLOAN_FEEPPM() / 1_000_000;

        zchf.transferFrom(msg.sender, address(this), flashFee); // needs allowance
        flash.takeLoan(_from, _to, toMint);
        redeemOwnership(_from, msg.sender);

        emit Rolled(msg.sender, _from, _to, toMint, flashFee);
    }

    // ---------------------------------------------------------------------------------------------------
    function executeRolling(address _from, address _to, uint256 amount) external {
        if (msg.sender != address(flash)) revert NotFlashLoanProvider();

        Position from = Position(_from);
        Position to = Position(_to);
        IERC20 collateral = IERC20(from.collateral());

        // repay position
        from.adjust(0, 0, from.price());

        uint256 k = 1_000_000;
        uint256 r = to.reserveContribution();
        uint256 f = to.calculateCurrentFee();
        uint256 toMint = amount * k / (k - r - f);
        uint256 toPrice = to.price();
        uint256 toBalance = toMint * 10**(36 - collateral.decimals()) / toPrice;

        to.adjust(toMint, toBalance, toPrice);
        flash.repayLoan(amount);
    }
}