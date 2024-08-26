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
    uint256 public constant MAX_QUORUM_PPM = 200_000; // e.g. 20%
    uint256 public constant FEE_PPM = 1_000; // e.g. 0.1%
    uint256 public constant STARTUP_DELAY = 0; // 0 sec for testing

    // ---------------------------------------------------------------------------------------------------
    // changeable
    address[] public registeredRollers;
    uint256 public totalVolumeMinted;
    uint256 public cooldown;

    // ---------------------------------------------------------------------------------------------------
    // Mappings
    mapping(address roller => bool isRoller) public isRegisteredRoller;

    // ---------------------------------------------------------------------------------------------------
    // Events
    event Shutdown(address indexed denier, string message); // denier: who initiates the shutdown
    event NewRoller(address indexed roller, address owner); // indexed for roller
    event LoanCompleted(address indexed roller, uint256 amount, uint256 fee, uint256 totalVolumeMinted); 

    // ---------------------------------------------------------------------------------------------------
    // Errors
    error Cooldown();
    error ProposalNotPassed();
    error NotRegistered();
    error ExceedsLimit();

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
        cooldown = block.timestamp + STARTUP_DELAY;
        totalVolumeMinted = 0;
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
    function takeLoanAndExecute(address _from, address _to, uint256 amount, uint256 flashFee) external noCooldown proposalPassed onlyRegisteredRoller returns (bool) {
        // @dev: guards could be adjusted to a quorum (%) of the totalSupply of zchf instead
        // if (amount > FLASHLOAN_MAX) revert ExceedsLimit(); 
        if (amount * 1_000_000 > zchf.totalSupply() * MAX_QUORUM_PPM) revert ExceedsLimit();
        
        // tracks the total volume
        totalVolumeMinted += amount;

        // mint flash loan
        zchf.mint(msg.sender, amount);

        // execute
        IFlashLoanRollerExecute(msg.sender).execute(_from, _to, amount, flashFee);

        // repay and collect fee (with minters superpowers)
        zchf.burnFrom(msg.sender, amount);
        zchf.collectProfits(msg.sender, FEE_PPM); // @dev: would trigger event "Frankencoin:Profit"

        // @dev: refunds remaining zchf in roller (fail safe)
        uint256 zchfInRoller = zchf.balanceOf(msg.sender);
        if (zchfInRoller > 0) zchf.transferFrom(msg.sender, FlashLoanRoller(msg.sender).owner(), zchfInRoller); 
        
        // emit all infos
        emit LoanCompleted(msg.sender, amount, flashFee, totalVolumeMinted);
        return true;
    }
}