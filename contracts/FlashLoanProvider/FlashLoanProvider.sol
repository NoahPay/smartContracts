// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interface/IFrankencoin.sol";
import "../interface/IReserve.sol";
import "./FlashLoanRollerFactory.sol";
import "./IFlashLoanExecuteRolling.sol";

contract FlashLoanProvider {
    // ---------------------------------------------------------------------------------------------------
    // immutable
    IFrankencoin public immutable zchf;
    FlashLoanRollerFactory public immutable factory;

    // ---------------------------------------------------------------------------------------------------
    // constant
    string public constant NAME = "FlashLoanV0";
    uint256 public constant FLASHLOAN_TOTALMAX = 10_000_000 ether;
    uint256 public constant FLASHLOAN_MAX = 1_000_000 ether;
    uint256 public constant FLASHLOAN_FEEPPM = 1_000;
    uint256 public constant FLASHLOAN_DELAY = 1; // 10sec for testing

    // ---------------------------------------------------------------------------------------------------
    // changeable
    address[] public registeredRollers;
    uint256 public totalMinted;
    uint256 public cooldown;

    // ---------------------------------------------------------------------------------------------------
    // Mappings
    mapping(address roller => bool isRoller) public isRegisteredRoller;
    mapping(address => uint256) public rollerMinted;
    mapping(address => uint256) public rollerRepaid;
    mapping(address => uint256) public rollerFees;

    // ---------------------------------------------------------------------------------------------------
    // Events
    event NewRoller(address owner, address roller);
    event Shutdown(address indexed denier, string message);
    event LoanTaken(address indexed to, uint256 amount, uint256 totalMint);
    event Repaid(address indexed from, uint256 total, uint256 repay, uint256 fee);
    event Completed(address indexed from, uint256 amount);
    event Log(address sender, string message);


    // ---------------------------------------------------------------------------------------------------
    // Errors
    error NotRegistered();
    error Cooldown();
    error ExceedsLimit();
    error ExceedsTotalLimit();
    error NotPaidBack();
    error DelegateCallFailed();
    error PaidTooMuch();

    // ---------------------------------------------------------------------------------------------------
    // Modifier
    modifier noCooldown() {
       if (block.timestamp <= cooldown) revert Cooldown();
        _;
    }

    modifier onlyRegisteredRoller() {
       if (!isRegisteredRoller[msg.sender]) revert NotRegistered();
        _;
    }

    // ---------------------------------------------------------------------------------------------------
    constructor(address _zchf, address _factory) {
        zchf = IFrankencoin(_zchf);
        factory = new FlashLoanRollerFactory();
        cooldown = block.timestamp + FLASHLOAN_DELAY;
        totalMinted = 0;
    }

    // ---------------------------------------------------------------------------------------------------
    function shutdown(address[] calldata helpers, string calldata message) external noCooldown returns (bool) {
        IReserve(zchf.reserve()).checkQualified(msg.sender, helpers);
        cooldown = type(uint256).max;
        emit Shutdown(msg.sender, message);
        return true;
    }

    // ---------------------------------------------------------------------------------------------------
    function createRoller() external noCooldown returns (address) {
        address roller = factory.createRoller(msg.sender, address(zchf), address(this));
        isRegisteredRoller[roller] = true;
        registeredRollers.push(roller);
        emit NewRoller(msg.sender, roller);
        return roller;
    }

    // ---------------------------------------------------------------------------------------------------
    function _verify(address sender) internal view noCooldown {
        uint256 total = rollerMinted[sender] * (1_000_000 + FLASHLOAN_FEEPPM);
        uint256 repaid = rollerRepaid[sender] * 1_000_000;
        uint256 fee = rollerFees[sender] * 1_000_000;
        if (repaid + fee < total) revert NotPaidBack();
    }

    // ---------------------------------------------------------------------------------------------------
    function takeLoan(address _from, address _to, uint256 amount) external noCooldown onlyRegisteredRoller returns (bool) {
        if (amount + totalMinted > FLASHLOAN_TOTALMAX) revert ExceedsTotalLimit();
        if (amount > FLASHLOAN_MAX) revert ExceedsLimit();

        // verify before
        _verify(msg.sender);

        // mint flash loan
        totalMinted += amount;
        rollerMinted[msg.sender] += amount;
        zchf.mint(msg.sender, amount);
        emit LoanTaken(msg.sender, amount, totalMinted);

        // execute
        IFlashLoanExecuteRolling(msg.sender).executeRolling(_from, _to, amount);

        // verify after
        _verify(msg.sender);
        emit Completed(msg.sender, amount);
    }

    // This function will be called my the roller contract within the "executeRolling" function
    // This function is callable multiple times to repay within a tx (atomic), in the end _verify needs to pass.
    // ---------------------------------------------------------------------------------------------------
    function repayLoan(uint256 amount) public noCooldown onlyRegisteredRoller {
        if (rollerRepaid[msg.sender] + amount > rollerMinted[msg.sender]) revert PaidTooMuch();
        uint256 fee = amount * FLASHLOAN_FEEPPM / 1_000_000;
        uint256 total = amount + fee;

        zchf.burnFrom(msg.sender, amount);
        zchf.transferFrom(msg.sender, address(zchf.reserve()), fee); 

        rollerRepaid[msg.sender] += amount;
        rollerFees[msg.sender] += fee;
        
        emit Repaid(msg.sender, total, amount, fee);
    }
}