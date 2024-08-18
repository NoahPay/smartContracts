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
    event LogA(address addr, string msg);
    
    // ---------------------------------------------------------------------------------------------------
    // errors
    error PositionNotOwned();
    error PositionInsuffMint();
    error NotFlashLoanProvider();
    error CollateralNotMatching();
    error CollateralInsufficient();

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
        
        // @dev: gives the owner the ability to roll/merge into an already minted position.
        // (could be helpful to roll a bigger position into a smaller one, or the other way around)
        uint256 toMint = to.minted() + (numerator / denominator) + (numerator % denominator > 0 ? 1 : 0);
        

        // @dev: Division causes rounding error
        // Rounding Error, manually added "1" to pass flashloan repayment
        //uint256 toMint = to.minted() + (amount + flashFee) * k / (k - r - f) + 1; 

        /** Hint!!!
        Error provided by the contract:
        ERC20InsufficientBalance
        Parameters:
        {
        "sender": {
        "value": "0x6a76acaab56C1777De41a5A131E5F63ab4B73834"
        },
        "balance": {
        "value": "8999999999999999999"
        },
        "needed": {
        "value": "9000000000000000000"
        }
        }
         */

        // @trash: remove after testing
        emit Log("Already minted in _to", to.minted());
        emit Log("To mint amount for _to", toMint);

        // @dev: gives the owner the ability to transfer collateral into the roller contract, before flash loan,
        // and adds it on top of the rolling/merging process towards the "new" (to) position. Aka: adds additional funds.
        // This is needed, because we give the owner the ability to have **adjusted parameters** including the loan duration for the "new" position.
        // Also interest of the new mint needs to be covered by someone (aka. owner) in form of a higher collateral balance.
        // The "new" position provided will be already open, so there is already additional collateral and should allow to cover the additional interest.
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
    }
}