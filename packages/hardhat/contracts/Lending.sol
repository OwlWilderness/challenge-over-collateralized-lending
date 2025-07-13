// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./Corn.sol";
import "./CornDEX.sol";

//buidlguidl https://speedrunethereum.com/challenge/over-collateralized-lending challenge
//quantumtekh.eth

error Lending__InvalidAmount();
error Lending__TransferFailed();
error Lending__UnsafePositionRatio();
error Lending__BorrowingFailed();
error Lending__RepayingFailed();
error Lending__PositionSafe();
error Lending__NotLiquidatable();
error Lending__InsufficientLiquidatorCorn();
error Lending__FlashLoanOperationUnsuccesfull();

contract Lending is Ownable {
    uint256 private constant COLLATERAL_RATIO = 120; // 120% collateralization required
    uint256 private constant LIQUIDATOR_REWARD = 10; // 10% reward for liquidators

    Corn private i_corn;
    CornDEX private i_cornDEX;

    mapping(address => uint256) public s_userCollateral; // User's collateral balance
    mapping(address => uint256) public s_userBorrowed; // User's borrowed corn balance

    event CollateralAdded(address indexed user, uint256 indexed amount, uint256 price);
    event CollateralWithdrawn(address indexed user, uint256 indexed amount, uint256 price);
    event AssetBorrowed(address indexed user, uint256 indexed amount, uint256 price);
    event AssetRepaid(address indexed user, uint256 indexed amount, uint256 price);
    event Liquidation(
        address indexed user,
        address indexed liquidator,
        uint256 amountForLiquidator,
        uint256 liquidatedUserDebt,
        uint256 price
    );

    constructor(address _cornDEX, address _corn) Ownable(msg.sender) {
        i_cornDEX = CornDEX(_cornDEX);
        i_corn = Corn(_corn);
        i_corn.approve(address(this), type(uint256).max);
    }

    /**
     * @notice Allows users to add collateral to their account
     */
    function addCollateral() public payable {
        //validate
        if (msg.value == 0){
            revert Lending__InvalidAmount();
        }
        
        //manage collateral map for sender
        s_userCollateral[msg.sender] += msg.value;

        emit CollateralAdded(msg.sender,msg.value,i_cornDEX.currentPrice());
    }

    /**
     * @notice Allows users to withdraw collateral as long as it doesn't make them liquidatable
     * @param amount The amount of collateral to withdraw
     */
    function withdrawCollateral(uint256 amount) public {
        //validate
        if (amount == 0 || amount > s_userCollateral[msg.sender]){
            revert Lending__InvalidAmount();
        }

        //manage colateral map for sender
        s_userCollateral[msg.sender] -= amount;
    
        //validate will not make unsafe position if user has borrowed
        if(s_userBorrowed[msg.sender] > 0){
            _validatePosition(msg.sender);
        }

        //xfer withdrawn collateral to sender
        (bool success, ) = msg.sender.call{value: amount}("");
        if(!success){
            revert Lending__TransferFailed();
        }

        emit CollateralWithdrawn(msg.sender,amount,i_cornDEX.currentPrice());
    }

    /**
     * @notice Calculates the total collateral value for a user based on their collateral balance
     * @param user The address of the user to calculate the collateral value for
     * @return uint256 The collateral value
     */
    function calculateCollateralValue(address user) public view returns (uint256) {
        return (s_userCollateral[user] * i_cornDEX.currentPrice()) / 1e18;  
    }

    /**
     * @notice Calculates the position ratio for a user to ensure they are within safe limits
     * @param user The address of the user to calculate the position ratio for
     * @return uint256 The position ratio
     */
    function _calculatePositionRatio(address user) internal view returns (uint256) {
        if(s_userBorrowed[user]==0){
            return type(uint256).max;
        }
        return (calculateCollateralValue(user) * 1e18 )/ s_userBorrowed[user] ;
    }

    /**
     * @notice Checks if a user's position can be liquidated
     * @param user The address of the user to check
     * @return bool True if the position is liquidatable, false otherwise
     */
    function isLiquidatable(address user) public view returns (bool) {
        return (_calculatePositionRatio(user) * 100) < COLLATERAL_RATIO * 1e18;
    }

    /**
     * @notice Internal view method that reverts if a user's position is unsafe
     * @param user The address of the user to validate
     */
    function _validatePosition(address user) internal view {
        if (isLiquidatable(user)){
            revert Lending__UnsafePositionRatio();
        }
    }

    /**
     * @notice Allows users to borrow corn based on their collateral
     * @param borrowAmount The amount of corn to borrow
     */
    function borrowCorn(uint256 borrowAmount) public {
        //validate
        if(borrowAmount==0){
            revert Lending__InvalidAmount();
        }
        
        //manage borrowed map for sender
        s_userBorrowed[msg.sender] += borrowAmount;

        //verify safe position
        _validatePosition(msg.sender);

        //transfer corn to sender
        try i_corn.transferFrom(address(this), msg.sender, borrowAmount) returns (bool success) {
            if(!success){
                revert Lending__BorrowingFailed();
            }
        } catch {
            revert Lending__BorrowingFailed();
        }

        emit AssetBorrowed(msg.sender, borrowAmount, i_cornDEX.currentPrice());
    }

    /**
     * @notice Allows users to repay corn and reduce their debt
     * @param repayAmount The amount of corn to repay
     */
    function repayCorn(uint256 repayAmount) public {
        //validate
        if(repayAmount == 0 || repayAmount > s_userBorrowed[msg.sender]){
            revert Lending__InvalidAmount();    
        }
        if(i_corn.balanceOf(msg.sender) < repayAmount){
            revert Lending__RepayingFailed();
        }

        //xfer corn to contract
        try i_corn.transferFrom(msg.sender,address(this),repayAmount) returns (bool success) {
            if(!success){
                revert Lending__RepayingFailed();
            } 
        } catch {
            revert Lending__RepayingFailed();
        }

        //manage borrowed map for sender
        s_userBorrowed[msg.sender] -= repayAmount;

        emit AssetRepaid(msg.sender,repayAmount,i_cornDEX.currentPrice());
    }

    /**
     * @notice Allows liquidators to liquidate unsafe positions
     * @param user The address of the user to liquidate
     * @dev The caller must have enough CORN to pay back user's debt
     * @dev The caller must have approved this contract to transfer the debt
     */
    function liquidate(address user) public {
        //validate
        if(!isLiquidatable(user)){
            revert Lending__NotLiquidatable();
        }
        uint256 bcornamt = s_userBorrowed[user];
        if(i_corn.balanceOf(msg.sender) < bcornamt){
            revert Lending__InsufficientLiquidatorCorn();
        }

        //repay corn and set borrowed for user to 0
        try i_corn.transferFrom(msg.sender, address(this), bcornamt) returns (bool _success){
            if(!_success){
                revert Lending__RepayingFailed();
            }
        } catch {
            revert Lending__RepayingFailed();
        }
        s_userBorrowed[user] = 0;

        //calculate and send collateral to sender
        uint256 camt = bcornamt * i_cornDEX.currentPrice();
        uint256 tamt = camt + (LIQUIDATOR_REWARD / camt); 
        if(tamt > s_userCollateral[user]){
            tamt = s_userCollateral[user];
        }
        s_userCollateral[user] -= tamt;
        (bool success, ) = msg.sender.call{value: tamt}("");
        if(!success){
            revert Lending__TransferFailed();
        }

        emit Liquidation(user, msg.sender, tamt, bcornamt, i_cornDEX.currentPrice());
    }
}
