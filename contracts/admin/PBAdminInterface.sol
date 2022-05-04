// SPDX-License-Identifier: MIT
pragma solidity ^0.5.6;

contract PBAdminInterface {
    bool public constant isPBAdmin = true;

    function enterMarkets(address[] calldata pTokenAddrs) external returns (uint[] memory);
    function exitMarket(address pTokenAddr) external returns (uint);

    function mintAllowed(address pTokenAddr, address minter, uint mintAmount) external returns (uint);

    function redeemAllowed(address pTokenAddr, address redeemer, uint redeemTokens) external returns (uint);
    function redeemVerify(address pTokenAddr, address redeemer, uint redeemAmount, uint redeemTokens) external;

    function borrowAllowed(address pTokenAddr, address borrower, uint borrowAmount) external returns (uint);
    function repayBorrowAllowed(address pTokenAddr, address payer, address borrower, uint repayAmount) external returns (uint);
    function liquidateBorrowAllowed(address pTokenAddrBorrowed, address pTokenAddrCollateral, address liquidator, address borrower, uint repayAmount) external returns (uint);
    function seizeAllowed(address pTokenAddrCollateral, address pTokenAddrBorrowed, address liquidator, address borrower, uint seizeTokens) external returns (uint);
    function transferAllowed(address pTokenAddr, address src, address dst, uint transferTokens) external returns (uint);

    function liquidateCalculateSeizeTokens(address pTokenAddrBorrowed, address pTokenAddrCollateral, uint repayAmount) external view returns (uint, uint);

    function getAccruedTokens(address pTokenAddr, address holder) external view returns (uint);
    function getClankBalance(address holder) external view returns (uint);
    function clankTransferIn(address pTokenAddr, address payer, uint interestAmount) external returns (bool);
}
