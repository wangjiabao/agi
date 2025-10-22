// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title HighPrecisionMathExample
 * @notice 使用 PRBMath 实现高精度 log / sqrt 运算
 * @dev 所有数值为 18 位定点（1e18 = 1.0）
 */

import { PRBMathSD59x18 } from "prb-math/contracts/PRBMathSD59x18.sol";

contract HighPrecisionMathExample {
    using PRBMathSD59x18 for int256;

    /**
     * @notice 高精度平方根
     * @param x 输入值（18 位定点）
     * @return result 平方根（18 位定点）
     */
    function sqrtExample(int256 x) external pure returns (int256 result) {
        // x=16e18 => result=4e18
        result = x.sqrt();
    }

    /**
     * @notice 高精度 log₂
     * @param x 输入值（18 位定点）
     * @return result log₂(x)（18 位定点）
     */
    function log2Example(int256 x) external pure returns (int256 result) {
        // x=8e18 => result=3e18
        result = x.log2();
    }

    /**
     * @notice 高精度 log₁₀
     * @param x 输入值（18 位定点）
     * @return result log₁₀(x)（18 位定点）
     */
    function log10Example(int256 x) external pure returns (int256 result) {
        // x=100e18 => result=2e18
        result = x.log10();
    }

    /**
     * @notice 高精度自然对数 ln(x)
     * @param x 输入值（18 位定点）
     * @return result ln(x)（18 位定点）
     */
    function lnExample(int256 x) external pure returns (int256 result) {
        // x=e (≈2.71828e18) => result≈1e18
        result = x.ln();
    }
}
