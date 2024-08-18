// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// @dev: Member "minters" not found or not visible after argument-dependent lookup in contract IFrankencoin.(9582)
import "../interface/IFrankencoin.sol"; 
import "../interface/IReserve.sol";
import "./FlashLoanRollerFactory.sol";
import "./IFlashLoanRollerExecute.sol";

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
    uint256 public constant FLASHLOAN_DELAY = 0; // 0sec for testing

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
    event Shutdown(address indexed denier, string message); // denier: who initiates the shutdown
    event NewRoller(address indexed roller, address owner); // indexed for roller
    event LoanTaken(address indexed to, uint256 amount, uint256 totalMint); // to: address(roller)
    event Repaid(address indexed from, uint256 total, uint256 repay, uint256 fee); // from: address(roller)
    event LoanCompleted(address indexed from, uint256 amount); // from: address(roller)

    // ---------------------------------------------------------------------------------------------------
    // Errors
    error Cooldown();
    error ProposalNotPassed();
    error NotRegistered();
    error ExceedsLimit();
    error ExceedsTotalLimit();
    error NotPaidBack();
    error PaidTooMuch();

    // ---------------------------------------------------------------------------------------------------
    // Modifier
    modifier noCooldown() {
        if (block.timestamp < cooldown) revert Cooldown(); // safe guard, for delayed start or shutdown
        _;
    }

    modifier proposalPassed() {
        if (block.timestamp < zchf.minters(address(this))) revert ProposalNotPassed(); // safe guard, for proposal passed
        _;
    }

    modifier onlyRegisteredRoller() {
       if (!isRegisteredRoller[msg.sender]) revert NotRegistered();
        _;
    }

    // ---------------------------------------------------------------------------------------------------
    constructor(address _zchf) {
        zchf = IFrankencoin(_zchf);
        factory = new FlashLoanRollerFactory();
        cooldown = block.timestamp + FLASHLOAN_DELAY;
        totalMinted = 0;
    }

    // ---------------------------------------------------------------------------------------------------
    function shutdown(address[] calldata helpers, string calldata message) external noCooldown proposalPassed returns (bool) {
        IReserve(zchf.reserve()).checkQualified(msg.sender, helpers);
        cooldown = type(uint256).max;
        emit Shutdown(msg.sender, message);
        return true;
    }

    // ---------------------------------------------------------------------------------------------------
    // @dev: could use modifier "proposalPassed", however, let users create rollers before proposal passed
    function createRoller() external noCooldown returns (address) { 
        address roller = factory.createRoller(msg.sender, address(zchf), address(this));
        isRegisteredRoller[roller] = true;
        registeredRollers.push(roller);
        emit NewRoller(roller, msg.sender);
        return roller;
    }

    // ---------------------------------------------------------------------------------------------------
    // @dev: "middleware" alike. returns nothing. pass or revert
    function _verify(address sender) internal view noCooldown proposalPassed { 
        uint256 total = rollerMinted[sender] * (1_000_000 + FLASHLOAN_FEEPPM);
        uint256 repaid = rollerRepaid[sender] * 1_000_000;
        uint256 fee = rollerFees[sender] * 1_000_000;
        if (repaid + fee < total) revert NotPaidBack();
    }

    // ---------------------------------------------------------------------------------------------------
    function takeLoanAndExecute(address _from, address _to, uint256 amount, uint256 flashFee) external noCooldown proposalPassed onlyRegisteredRoller returns (bool) {
        // @dev: guards could be adjusted to a quorum (%) of the totalSupply of zchf instead
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
        IFlashLoanRollerExecute(msg.sender).execute(_from, _to, amount, flashFee);

        // verify after
        _verify(msg.sender);
        emit LoanCompleted(msg.sender, amount);
        return true;
    }

    // This function will be called my the roller contract within the "execute" function
    // This function is callable multiple times to repay within a tx (atomic), in the end _verify needs to pass.
    // ---------------------------------------------------------------------------------------------------
    function repayLoan(uint256 amount) public noCooldown proposalPassed onlyRegisteredRoller returns (bool) {
        if (rollerRepaid[msg.sender] + amount > rollerMinted[msg.sender]) revert PaidTooMuch();
        uint256 fee = amount * FLASHLOAN_FEEPPM / 1_000_000;
        uint256 total = amount + fee;

        zchf.burnFrom(msg.sender, amount);
        zchf.collectProfits(msg.sender, fee); // @dev: would trigger event "Frankencoin:Profit"

        rollerRepaid[msg.sender] += amount;
        rollerFees[msg.sender] += fee;
        
        emit Repaid(msg.sender, total, amount, fee);
        return true;
    }
}