// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../utils/Ownable.sol";

import "../interface/IERC20.sol";
import "../interface/IFrankencoin.sol";
import "../Position.sol";

import "./FlashLoanProvider.sol";
import "./IFlashLoanRollerExecute.sol";

contract FlashLoanRoller is IFlashLoanRollerExecute, Ownable {
    IFrankencoin public immutable zchf;
    FlashLoanProvider public immutable flash;

    // ---------------------------------------------------------------------------------------------------
    // events
    event Rolled(address owner, address from, address to, uint256 flashAmount, uint256 flashFee);

    // @trash: remove after testing
    event Log(string msg, uint256 num);
    
    // ---------------------------------------------------------------------------------------------------
    // errors
    error PositionNotOwned();
    error PositionInsuffMint();
    error NotFlashLoanProvider();
    error CollateralNotMatching();
    // error CollateralInsufficient(); // let the "Position.sol" decide if collateral is sufficient

    // ---------------------------------------------------------------------------------------------------
    constructor (address _owner, address _zchf, address _flash) {
        _setOwner(_owner);
        zchf = IFrankencoin(_zchf);
        flash = FlashLoanProvider(_flash);
    }

    // ---------------------------------------------------------------------------------------------------
    function redeemOwnership(address toTransfer, address owner) public onlyOwner {
        Ownable(toTransfer).transferOwnership(owner);
    }

    // ---------------------------------------------------------------------------------------------------
    function redeemToken(address _token, address to) public onlyOwner { // fail safe, don't be stupid. :)
        IERC20 token = IERC20(_token);
        token.transfer(to, token.balanceOf(address(this)));
    }

    // ---------------------------------------------------------------------------------------------------
    function prepareAndExecute(address _from, address _to) external onlyOwner returns (bool) {
        Position from = Position(_from);
        Position to = Position(_to);

        if (from.owner() != address(this)) revert PositionNotOwned();
        if (to.owner() != address(this)) revert PositionNotOwned();
        if (from.collateral() != to.collateral()) revert CollateralNotMatching();

        uint256 minted = from.minted();
        if (minted == 0) revert PositionInsuffMint();

        uint256 inReserve = minted * from.reserveContribution() / 1_000_000;
        uint256 flashAmount = minted - inReserve;
        uint256 flashFee = flashAmount * flash.FLASHLOAN_FEEPPM() / 1_000_000;

        // @dev: this will also invoke function "execute"
        flash.takeLoanAndExecute(_from, _to, flashAmount, flashFee); 

        // finalize, return ownership
        redeemOwnership(_from, msg.sender);
        redeemOwnership(_to, msg.sender);

        emit Rolled(msg.sender, _from, _to, flashAmount, flashFee);
        return true;
    }

    // ---------------------------------------------------------------------------------------------------
    
    function execute(address _from, address _to, uint256 amount, uint256 flashFee) external {
        if (msg.sender != address(flash)) revert NotFlashLoanProvider(); // safe guard

        Position from = Position(_from);
        Position to = Position(_to);
        IERC20 collateral = from.collateral();

        // repay position
        from.adjust(0, 0, from.price());

        uint256 k = 1_000_000;
        uint256 r = to.reserveContribution();
        uint256 f = to.calculateCurrentFee();
        uint256 numerator = (amount + flashFee) * k;
        uint256 denominator = k - (r + f);
        
        /**
            @dev: Division causes rounding error
            uint256 toMint = to.minted() + (amount + flashFee) * k / (k - r - f); // original calculated 
            
            Hint!!!
            Error provided by the contract: ERC20InsufficientBalance
            "balance": "8999999999999999999"
            "needed": "9000000000000000000"
            
            @dev: Rounding Error, manually added "1" to pass flashloan repayment
            uint256 toMint = to.minted() + (amount + flashFee) * k / (k - r - f);

            @dev: A working work around: (numerator % denominator > 0 ? 1 : 0)
         */

        // @dev: gives the owner the ability to roll/merge into an already minted position.
        uint256 toMint = to.minted() + (numerator / denominator) + (numerator % denominator > 0 ? 1 : 0);

        // @dev: Allows the owner to transfer additional collateral into the roller contract before the flash loan.
        // This collateral is added to the "new" (to) position during the rolling/merging process, enabling adjustments to parameters like loan duration.
        // The additional collateral helps cover the interest of the new mint, ensuring the "new" position is sufficiently backed.
        uint256 collBalThis = collateral.balanceOf(address(this));
        uint256 collBalTo = collateral.balanceOf(_to);
        collateral.approve(_to, collBalThis);
        to.adjust(toMint, collBalTo + collBalThis, to.price()); 

        // @trash: remove after testing
        emit Log("minted from", from.minted());
        emit Log("minted to", to.minted());
        emit Log("roller", zchf.balanceOf(address(this)));

        flash.repayLoan(amount);

        // @trash: remove after testing
        emit Log("minted from", from.minted()); // should be 0
        emit Log("minted to", to.minted()); // should be "toMint"
        emit Log("zchf of roller after", zchf.balanceOf(address(this))); // should be 0

        // @dev: refunds remaining zchf in roller
        uint256 zchfInRoller = zchf.balanceOf(address(this));
        if (zchfInRoller > 0) zchf.transfer(msg.sender, zchfInRoller); 

        // @trash: remove after testing
        emit Log("zchf of roller finalized", zchf.balanceOf(address(this))); // for sure, its 0.
        emit Log("coin of roller finalized", collateral.balanceOf(address(this))); // for sure, its 0.
    }
}