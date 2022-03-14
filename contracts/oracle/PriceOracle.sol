// SPDX-License-Identifier: MIT
pragma solidity ^0.5.6;

import "../asset/PToken.sol";

contract PriceOracle {
    bool public constant isPriceOracle = true;

    function getDirectPrice(address asset) external view returns (uint256);
    function getUnderlyingPrice(PToken pToken) external view returns (uint256);
}
