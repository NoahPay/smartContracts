// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../utils/ERC20.sol";

import "../Frankencoin.sol";
import "../PositionFactory.sol";
import "../MintingHub.sol";
import "../interface/IReserve.sol";

import "../FlashLoanRoller/FlashLoanProvider.sol";
import "../FlashLoanRoller/FlashLoanRoller.sol";
import "../FlashLoanRoller/FlashLoanRollerFactory.sol";

contract XCoin is ERC20 {
    constructor() ERC20(18) {
        _mint(msg.sender, 2_000_000 ether);
        _mint(tx.origin, 2_000_000 ether);
    }

    function name() external pure override returns (string memory) {
        return "Supercoin";
    }

    function symbol() external pure override returns (string memory) {
        return "SUP";
    }
}

contract DeployerRollerTest {
    string public constant NAME = "DeployerRollerTestV0";
    Frankencoin public zchf;
    MintingHub public mintingHub;
    FlashLoanRollerFactory public factory;
    FlashLoanProvider public flash;
    FlashLoanRoller public roller;
    ERC20 public coin;
    Position public posFrom;
    Position public posTo;

    event Log(address sender, string message);

    // constructor(address _zchf, address _mintingHub, address _flash, address _xcoin) {
    constructor() {
        address _zchf = 0xdACF32cdfA3E8deB39bCAcC1eea471539A98F5De;
        address _mintingHub = 0x3FCf6D4a9E2EeaB4E603992FD5257CbeBD29C393;

        zchf = Frankencoin(_zchf);
        mintingHub = MintingHub(_mintingHub);
        flash = new FlashLoanProvider(_zchf);
        roller = FlashLoanRoller(flash.createRoller());
        coin = new XCoin();
    }

    function addPosition(uint256 size) public returns (address) {
        coin.approve(address(mintingHub), size);
        address pos = mintingHub.openPosition(
            address(coin),
            1 ether,
            size,
            2_000_000 ether,
            1, // needs adjustment in Position.sol (_initPeriod) for testing
            1000000,
            1000,
            30000,
            6000 ether,
            100000
        );

        return pos;
    }

    function initA_Minter() public {
        // zchf.transferFrom(msg.sender, address(this), 10_000 ether); // give more, for testing
        zchf.transferFrom(msg.sender, address(this), 3_000 ether); // 1_000 suggestMinter, 2_000 positions (2 pos)
        zchf.suggestMinter(address(flash), 1, 1000 ether, flash.NAME());
    }

    function initB_Positions() public {
        posFrom = Position(addPosition(100 ether));
        posTo = Position(addPosition(100 ether));
    }

    function initC_Minting() public {
        posFrom.adjust(600000 ether, coin.balanceOf(address(posFrom)), posFrom.price()); // get own zchf, SC balance should be 10_000 ether
        posTo.adjust(600000 ether, coin.balanceOf(address(posTo)), posTo.price()); // testing merging from "from" into "to" position
    }

    function initD_Flashloan() public {
        coin.transfer(address(roller), 2 ether);

        posFrom.transferOwnership(address(roller));
        posTo.transferOwnership(address(roller));

        roller.prepareAndExecute(address(posFrom), address(posTo));
    }
}
