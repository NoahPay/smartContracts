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
    event Rolled(address owner, address from, address to, uint256 flashAmount, uint256 fee);
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
    // @dev: needs allowance for flash fee transfer from msg.sender -> this (owned roller)
    function prepareAndExecute(address _from, address _to) external onlyOwner returns (bool) {
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

        // TODO: make a collateral/price/ratios check --> revert CollateralInsufficient()

        // claim flashFees from msg.sender (roller owner, original owner of positions)
        zchf.transferFrom(msg.sender, address(this), flashFee); // needs allowance

        flash.takeLoan(_from, _to, toMint); // @dev: this will also invoke function "execute"

        // done, finalize
        redeemOwnership(_from, msg.sender);
        redeemOwnership(_to, msg.sender);

        emit Rolled(msg.sender, _from, _to, toMint, flashFee);
        return true;
    }

    // ---------------------------------------------------------------------------------------------------
            /**
        Lets define an approach.

        Position A:
        - minted 1000 zchf
        - interest paid
        - 10% in reserve
        - rest paid out

        Position B (needs to be open):
        - should be able to have ajusted parameters
        - the "only" same things are
            - owner
            - collateral
        
        Process:
        - mint 1000 zchf
        - pay back loan
        - mint as much as needed
          to receive 1000 zchf after costs and reserve
        - consequece would be the collateral size
        - how much collateral is needed fot the new position
         */
    function execute(address _from, address _to, uint256 amount) external {
        if (msg.sender != address(flash)) revert NotFlashLoanProvider();

        Position from = Position(_from);
        Position to = Position(_to);
        IERC20 collateral = from.collateral();

        // repay position
        from.adjust(0, 0, from.price());

        // FIXME: Calculation is off, rounding error
        // FIXME: minted must be adjusted so after cost output matches flash loan amount

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
        uint256 k = 1_000_000;
        uint256 r = to.reserveContribution();
        uint256 f = to.calculateCurrentFee();
        uint256 toMint = amount * k / (k - r - f);

        uint256 collBalThis = collateral.balanceOf(address(this));
        uint256 collBalTo = collateral.balanceOf(_to);
        uint256 toBalance = collBalTo + collBalThis;
        
        // @trash: remove after testing
        emit Log("TO MINT AMOUNT", toMint);
        emit Log("FLASH LOAN AMOUNT", amount);

        collateral.approve(_to, collBalThis);
        to.adjust(toMint + 1, toBalance, to.price()); // FIXME: Rounding Error, manual added 1 to pass flashloan repayment

        flash.repayLoan(amount);

        uint256 zchfInRoller = zchf.balanceOf(address(this));
        if (zchfInRoller > 0) zchf.transfer(msg.sender, zchfInRoller); // @dev: transfer all remaining zchf

        // @trash: remove after testing
        emit Log("minted from", from.minted());
        emit Log("minted to", to.minted());
        emit Log("roller", zchf.balanceOf(address(this)));
        
        emit Log("coin from", collateral.balanceOf(_from));
        emit Log("coin to", collateral.balanceOf(_to));
        emit Log("roller coin", collateral.balanceOf(address(this)));
    }
}