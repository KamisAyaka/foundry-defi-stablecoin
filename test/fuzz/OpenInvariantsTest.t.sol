// SPDX-License-Identifier: MIT

// Have our invariants aka properties

// What are our invariants?

// 1. The total supply of DSC should be less than the total value of collateral
// 2. Getter view function should never revert <-- this is a good one to add

pragma solidity ^0.8.19;

// import {Test, console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// contract OpenInvariantsTest is StdInvariant, Test {
//     DeployDSC deployer;
//     DSCEngine dsce;
//     DecentralizedStableCoin dsc;
//     HelperConfig helperConfig;
//     address weth;
//     address wbtc;

//     function setup() external {
//         deployer = new DeployDSC();
//         (dsc, dsce, helperConfig) = deployer.run();
//         (, , weth, wbtc, ) = helperConfig.activeNetworkConfig();
//         targetContract(address(dsce));
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
//         // get the value of all the collateral in the protocol
//         // compare it to the all the debt dsc
//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalwethDeposited = IERC20(weth).balanceOf(address(dsce));
//         uint256 totalwbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

//         uint256 totalwethValue = dsce.getUsdValue(weth, totalwethDeposited);
//         uint256 totalwbtcValue = dsce.getUsdValue(wbtc, totalwbtcDeposited);
//         uint256 totalValue = totalwethValue + totalwbtcValue;
//         assert(totalValue >= totalSupply);
//     }
// }
