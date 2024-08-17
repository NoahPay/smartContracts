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

        emit Log("minted", from.minted());
        emit Log("roller", zchf.balanceOf(address(this)));

        zchf.transferFrom(msg.sender, address(this), flashFee); // needs allowance

        emit Log("minted", from.minted());
        emit Log("roller", zchf.balanceOf(address(this)));

        flash.takeLoan(_from, _to, toMint); // @dev: this will also invoke function "execute"

        // done, finalize
        redeemOwnership(_from, msg.sender);
        redeemOwnership(_to, msg.sender);

        emit Rolled(msg.sender, _from, _to, toMint, flashFee);
        return true;
    }

    // ---------------------------------------------------------------------------------------------------
    function execute(address _from, address _to, uint256 amount) external {
        if (msg.sender != address(flash)) revert NotFlashLoanProvider();

        Position from = Position(_from);
        Position to = Position(_to);
        IERC20 collateral = from.collateral();

        // repay position
        from.adjust(0, 0, from.price());

        // FIXME: bug here

        /**
        transact to DeployerRollerTest.initD_Flashloan errored: Error occurred: revert.

            revert
                The transaction has been reverted to the initial state.
            Error provided by the contract:
            ERC20InsufficientBalance
            Parameters:
            {
            "sender": {
            "value": "0x5c56e3B2E7bcC28d995f33922F8784443F39Cf83" <-- Roller Contract
            },
            "balance": {
            "value": "8997699000000000000" <-- a calculation is wrong, i just interest adjusted?
            },
            "needed": {
            "value": "9000000000000000000"
            }
            }
         */

        emit Log("minted", from.minted());
        emit Log("roller", zchf.balanceOf(address(this)));
        // emit Log("price", from.price());

        // from.adjust(10001 ether, collateral.balanceOf(_from), from.price());
        // from.adjust(10000 ether, collateral.balanceOf(_from), from.price());

        emit Log("minted", from.minted());
        emit Log("roller", zchf.balanceOf(address(this)));

        // uint256 k = 1_000_000;
        // uint256 r = to.reserveContribution();
        // uint256 f = to.calculateCurrentFee();
        // uint256 toMint = amount * k / (k - r - f);
        // uint256 toPrice = to.price();
        // uint256 toBalance = toMint * 10**(36 - collateral.decimals()) / toPrice;

        // to.adjust(toMint, toBalance, toPrice);
        flash.repayLoan(amount);

        emit Log("minted", from.minted());
        emit Log("roller", zchf.balanceOf(address(this)));
    }
}