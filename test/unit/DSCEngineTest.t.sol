// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    event CollateralRedeemed(
        address indexed redeemFrom,
        address indexed redeemTo,
        address indexed token,
        uint256 amount
    ); // if redeemFrom != redeemedTo, then it was liquidated

    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig helperConfig;
    address weth;
    address wbtc;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public amountToMint = 100 ether;
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, ) = helperConfig
            .activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_USER_BALANCE);
    }

    ///////////////////////////////////////
    ////Constructor TESTS/////////////////
    //////////////////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(
            DSCEngine
                .DSCEngine__TokenAddressesAndPriceFeedAddressesLengthMustBeEqual
                .selector
        );
        engine = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(dsc)
        );
    }

    ///////////////////////////
    ////PRICE TESTS////////////
    //////////////////////////
    function testGetUsdValue() public view {
        uint256 ethAmount = 1 ether;
        uint256 expectedUsd = 2000e18;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 1000 ether;
        uint256 expectedWeth = 0.5 ether;
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    ///////////////////////////////////////
    ////depositCollateral TESTS////////////
    //////////////////////////////////////

    function testRevertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom(owner);
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );
        mockDsc.mint(USER, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(
            address(mockDsce),
            AMOUNT_COLLATERAL
        );
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__TokenTransferFailed.selector);
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock token = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        engine.depositCollateral(address(token), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo()
        public
        depositedCollateral
    {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine
            .getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(
            weth,
            collateralValueInUsd
        );
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testCanDepositCollateralWithoutMintingDsc()
        public
        depositedCollateral
    {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ///////////////////////////////////////
    // depositCollateralAndMintDsc Tests //
    ///////////////////////////////////////

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed)
            .latestRoundData();
        amountToMint =
            (AMOUNT_COLLATERAL *
                (uint256(price) * engine.getAdditionalFeedPrecision())) /
            engine.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor = engine.calculateHealthFactor(
            amountToMint,
            engine.getUsdValue(weth, AMOUNT_COLLATERAL)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactor.selector,
                expectedHealthFactor
            )
        );
        engine.depositCollateralAndMintDsc(
            weth,
            AMOUNT_COLLATERAL,
            amountToMint
        );
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(
            weth,
            AMOUNT_COLLATERAL,
            amountToMint
        );
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral()
        public
        depositedCollateralAndMintedDsc
    {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // mintDsc Tests //////////////////
    ///////////////////////////////////

    function testRevertsIfMintFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDsce.depositCollateralAndMintDsc(
            weth,
            AMOUNT_COLLATERAL,
            amountToMint
        );
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(
            weth,
            AMOUNT_COLLATERAL,
            amountToMint
        );
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor()
        public
        depositedCollateral
    {
        // 0xe580cc6100000000000000000000000000000000000000000000000006f05b59d3b20000
        // 0xe580cc6100000000000000000000000000000000000000000000003635c9adc5dea00000
        (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed)
            .latestRoundData();
        amountToMint =
            (AMOUNT_COLLATERAL *
                (uint256(price) * engine.getAdditionalFeedPrecision())) /
            engine.getPrecision();

        vm.startPrank(USER);
        uint256 expectedHealthFactor = engine.calculateHealthFactor(
            amountToMint,
            engine.getUsdValue(weth, AMOUNT_COLLATERAL)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactor.selector,
                expectedHealthFactor
            )
        );
        engine.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        vm.prank(USER);
        engine.mintDsc(amountToMint);

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // burnDsc Tests //////////////////
    ///////////////////////////////////
    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(
            weth,
            AMOUNT_COLLATERAL,
            amountToMint
        );
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.burnDsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        engine.burnDsc(1);
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(engine), amountToMint);
        engine.burnDsc(amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ///////////////////////////////////
    // redeemCollateral Tests ////////
    //////////////////////////////////
    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );
        mockDsc.mint(USER, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(
            address(mockDsce),
            AMOUNT_COLLATERAL
        );
        // Act / Assert
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__TokenTransferFailed.selector);
        mockDsce.redeemCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(
            weth,
            AMOUNT_COLLATERAL,
            amountToMint
        );
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(USER);
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testEmitCollateralRedeemedWithCorrectArgs()
        public
        depositedCollateral
    {
        vm.expectEmit(true, true, true, true, address(engine));
        emit CollateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ///////////////////////////////////
    // redeemCollateralForDsc Tests //
    //////////////////////////////////
    function testMustRedeemMoreThanZero()
        public
        depositedCollateralAndMintedDsc
    {
        vm.startPrank(USER);
        dsc.approve(address(engine), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.redeemCollateralForDsc(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(
            weth,
            AMOUNT_COLLATERAL,
            amountToMint
        );
        dsc.approve(address(engine), amountToMint);
        engine.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////
    function testProperlyReportsHealthFactor()
        public
        depositedCollateralAndMintedDsc
    {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = engine.getHealthFactor(USER);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne()
        public
        depositedCollateralAndMintedDsc
    {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Rememeber, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = engine.getHealthFactor(USER);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
        // 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////
    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethUsdPriceFeed);
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);
        mockDsce.depositCollateralAndMintDsc(
            weth,
            AMOUNT_COLLATERAL,
            amountToMint
        );
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(mockDsce), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockDsce.depositCollateralAndMintDsc(
            weth,
            collateralToCover,
            amountToMint
        );
        mockDsc.approve(address(mockDsce), debtToCover);
        // Act
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act/Assert
        vm.expectRevert(DSCEngine.DSCEngine__LiquidationFailed.selector);
        mockDsce.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }

    function testCantLiquidateGoodHealthFactor()
        public
        depositedCollateralAndMintedDsc
    {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(engine), collateralToCover);
        engine.depositCollateralAndMintDsc(
            weth,
            collateralToCover,
            amountToMint
        );
        dsc.approve(address(engine), amountToMint);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        engine.liquidate(weth, USER, amountToMint);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(
            weth,
            AMOUNT_COLLATERAL,
            amountToMint
        );
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = engine.getHealthFactor(USER);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(engine), collateralToCover);
        engine.depositCollateralAndMintDsc(
            weth,
            collateralToCover,
            amountToMint
        );
        dsc.approve(address(engine), amountToMint);
        engine.liquidate(weth, USER, amountToMint); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    //?????
    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = engine.getTokenAmountFromUsd(
            weth,
            amountToMint
        ) +
            (engine.getTokenAmountFromUsd(weth, amountToMint) /
                engine.getLiquidationBonus());
        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = engine.getTokenAmountFromUsd(
            weth,
            amountToMint
        ) +
            (engine.getTokenAmountFromUsd(weth, amountToMint) /
                engine.getLiquidationBonus());

        uint256 usdAmountLiquidated = engine.getUsdValue(
            weth,
            amountLiquidated
        );
        uint256 expectedUserCollateralValueInUsd = engine.getUsdValue(
            weth,
            AMOUNT_COLLATERAL
        ) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = engine.getAccountInformation(
            USER
        );
        uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted, ) = engine.getAccountInformation(
            liquidator
        );
        assertEq(liquidatorDscMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted, ) = engine.getAccountInformation(USER);
        assertEq(userDscMinted, 0);
    }

    ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////
    function testGetCollateralTokenPriceFeed() public view {
        address priceFeed = engine.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public view {
        address[] memory collateralTokens = engine.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = engine.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public view {
        uint256 liquidationThreshold = engine.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation()
        public
        depositedCollateral
    {
        (, uint256 collateralValue) = engine.getAccountInformation(USER);
        uint256 expectedCollateralValue = engine.getUsdValue(
            weth,
            AMOUNT_COLLATERAL
        );
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralBalance = engine.getCollateralBalanceOfUser(
            USER,
            weth
        );
        assertEq(collateralBalance, AMOUNT_COLLATERAL);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralValue = engine.getAccountCollateralValue(USER);
        uint256 expectedCollateralValue = engine.getUsdValue(
            weth,
            AMOUNT_COLLATERAL
        );
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsc() public view {
        address dscAddress = engine.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public view {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = engine.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }

    // How do we adjust our invariant tests for this?
    // function testInvariantBreaks() public depositedCollateralAndMintedDsc {
    //     MockV3Aggregator(ethUsdPriceFeed).updateAnswer(0);

    //     uint256 totalSupply = dsc.totalSupply();
    //     uint256 wethDeposted = ERC20Mock(weth).balanceOf(address(dsce));
    //     uint256 wbtcDeposited = ERC20Mock(wbtc).balanceOf(address(dsce));

    //     uint256 wethValue = dsce.getUsdValue(weth, wethDeposted);
    //     uint256 wbtcValue = dsce.getUsdValue(wbtc, wbtcDeposited);

    //     console.log("wethValue: %s", wethValue);
    //     console.log("wbtcValue: %s", wbtcValue);
    //     console.log("totalSupply: %s", totalSupply);

    //     assert(wethValue + wbtcValue >= totalSupply);
    // }
}
