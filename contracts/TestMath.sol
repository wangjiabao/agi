// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title MathExample
 * @notice 演示 Solidity 中 sqrt() 与 log2() 的多种实现方式
 */

import "@openzeppelin/contracts/utils/math/Math.sol"; // 基础整数运算库

contract MathExample {
    using Math for uint256;

    /**
     * @notice 示例 1：整数平方根
     * @dev 使用 OpenZeppelin Math.sqrt()
     */
    function sqrtExample(uint256 x) external pure returns (uint256 result) {
        result = Math.sqrt(x);
        // 示例：
        // x = 16 => result = 4
        // x = 20 => result = 4 (向下取整)
    }

    /**
     * @notice 示例 2：整数 log₂
     * @dev 使用 OpenZeppelin Math.log2()
     */
    function log2Example(uint256 x) external pure returns (uint256 result) {
        require(x > 0, "x=0");
        result = Math.log2(x);
        // 示例：
        // x = 8 => result = 3
        // x = 9 => result = 3 (floor(log₂(9)) = 3)
    }
}
