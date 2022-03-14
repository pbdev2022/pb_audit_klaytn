// SPDX-License-Identifier: MIT
pragma solidity ^0.5.6;

contract UintSafeConvert {
    function safe224(uint256 n) pure internal returns (uint224) {
        require(n < 2**224, "UintSafeCheck: greater than or equal to 2**224");
        return uint224(n);
    }

    function safe32(uint256 n) pure internal returns (uint32) {
        require(n < 2**32, "UintSafeCheck: greater than or equal to 2**32");
        return uint32(n);
    }
}