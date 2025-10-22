// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice 轻量 Ownable（测试用途）
contract Ownable {
    event OwnershipTransferred(address indexed prev, address indexed next);
    address public owner;
    constructor() { owner = msg.sender; emit OwnershipTransferred(address(0), msg.sender); }
    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

/// @title DiamondGridPlaytest (线性扫描版)
/// @notice 线性模式扫描一圈：从0开始，遇到洞停；走到结尾即升级。
contract DiamondGridPlaytest is Ownable {
    /* ========== 数据结构 ========== */
    struct Point {
        address owner;     // 建立者
        int32   x;
        int32   y;
        uint32  coef;      // 当前圈层系数
        uint32  progress;  // 当前圈扫描进度 [0, 4r)
        bool    exists;
    }

    /* ========== 存储 ========== */
    mapping(bytes32 => Point) public points;            // 中心点信息
    mapping(bytes32 => bool)  public unclaimedOverride; // 被打洞的点（默认false=已认领）

    /* ========== 事件 ========== */
    event PointSpawned(address indexed by, int32 x, int32 y);
    event ScanProgress(
        int32 indexed x,
        int32 indexed y,
        uint32 radius,
        uint32 checkedThisCall,
        uint32 nextIndex,
        bool   upgraded,
        bool   hitUnclaimed,
        int32  hitX,
        int32  hitY
    );
    event CoefSetAndReset(int32 indexed x, int32 indexed y, uint32 newCoef);
    event UnclaimedSet(int32 indexed x, int32 indexed y, bool unclaimed);

    /* ========== 工具函数 ========== */
    function _key(int32 x, int32 y) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(x, y));
    }

    /// @dev 计算菱形（Manhattan/L1）半径 r 的圈长：4r
    function ringLen(uint32 r) public pure returns (uint32) {
        require(r >= 1, "r>=1");
        return 4 * r;
    }

    /// @dev 菱形圈顺时针索引 -> 坐标。起点为右顶点 (x+r, y)
    function diamondIndexCoord(
        int32 x0,
        int32 y0,
        uint32 r,
        uint32 idx
    ) public pure returns (int32 xi, int32 yi) {
        require(r >= 1, "r>=1");
        uint32 per = 4 * r;
        idx = idx % per;

        int64 X = int64(x0);
        int64 Y = int64(y0);
        int64 R = int64(uint64(r));

        if (idx < r) {
            // 段1：右→底（西南）
            int64 k = int64(uint64(idx));
            xi = int32(X + (R - k));
            yi = int32(Y - k);
        } else if (idx < 2 * r) {
            // 段2：底→左（西北）
            int64 k = int64(uint64(idx - r));
            xi = int32(X - k);
            yi = int32(Y - R + k);
        } else if (idx < 3 * r) {
            // 段3：左→上（东北）
            int64 k = int64(uint64(idx - 2 * r));
            xi = int32(X - R + k);
            yi = int32(Y + k);
        } else {
            // 段4：上→右（东南）
            int64 k = int64(uint64(idx - 3 * r));
            xi = int32(X + k);
            yi = int32(Y + R - k);
        }
    }

    /// @dev 默认所有点都“已认领”；被打洞的点返回 false。
    function isClaimedCoord(int32 x, int32 y) public view returns (bool) {
        return !unclaimedOverride[_key(x, y)];
    }

    /* ========== 主要逻辑 ========== */

    /// @notice 创建一个测试点
    function spawnPoint(int32 x, int32 y) external {
        bytes32 k = _key(x, y);
        require(!points[k].exists, "exists");
        points[k] = Point({
            owner: msg.sender,
            x: x,
            y: y,
            coef: 0,
            progress: 0,
            exists: true
        });
        emit PointSpawned(msg.sender, x, y);
    }

    /// @notice 标记某坐标为“未认领”或恢复认领
    function setUnclaimed(int32 x, int32 y, bool unclaimed) external onlyOwner {
        unclaimedOverride[_key(x, y)] = unclaimed;
        emit UnclaimedSet(x, y, unclaimed);
    }

    /// @notice 手动设置系数并清空扫描进度
    function setCoefAndReset(int32 x, int32 y, uint32 newCoef) external onlyOwner {
        bytes32 k = _key(x, y);
        require(points[k].exists, "no point");
        points[k].coef = newCoef;
        points[k].progress = 0;
        emit CoefSetAndReset(x, y, newCoef);
    }

    /// @notice 线性扫描版本：从 progress 顺序扫描一圈，遇洞停，扫到结尾升级。
    function queryUpgrade(
        int32 x,
        int32 y,
        uint256 maxChecks
    )
        external
        returns (
            bool upgraded,
            uint32 newCoef,
            bool hitUnclaimed,
            int32 hitX,
            int32 hitY,
            uint32 checked,
            uint32 radius,
            uint32 nextIndex
        )
    {
        bytes32 k = _key(x, y);
        Point storage p = points[k];
        require(p.exists, "no point");

        radius = p.coef + 1;
        uint32 total = ringLen(radius);
        uint32 idx = p.progress;

        uint32 budget = total;
        if (maxChecks > 0 && maxChecks < total) budget = uint32(maxChecks);

        // 从当前进度开始线性扫描
        while (checked < budget && idx < total) {
            (int32 cx, int32 cy) = diamondIndexCoord(p.x, p.y, radius, idx);

            if (!isClaimedCoord(cx, cy)) {
                // 遇洞立即停下
                hitUnclaimed = true;
                hitX = cx;
                hitY = cy;
                p.progress = idx; // 下次从这里继续
                checked += 1;
                emit ScanProgress(p.x, p.y, radius, checked, p.progress, false, true, hitX, hitY);
                newCoef = p.coef;
                nextIndex = p.progress;
                return (false, newCoef, true, hitX, hitY, checked, radius, nextIndex);
            }

            idx += 1;
            checked += 1;
        }

        // 如果扫描到了结尾（代表整圈完成）
        if (idx >= total) {
            p.coef += 1;
            p.progress = 0;
            upgraded = true;
            newCoef = p.coef;
            nextIndex = 0;
            emit ScanProgress(p.x, p.y, radius, checked, 0, true, false, 0, 0);
            return (true, newCoef, false, 0, 0, checked, radius, 0);
        }

        // 没扫描完也没遇洞（正常推进）
        p.progress = idx;
        newCoef = p.coef;
        nextIndex = p.progress;
        emit ScanProgress(p.x, p.y, radius, checked, nextIndex, false, false, 0, 0);
        return (false, newCoef, false, 0, 0, checked, radius, nextIndex);
    }

    /* ========== 只读接口 ========== */
    function getPoint(int32 x, int32 y) external view returns (
        bool exists,
        address owner_,
        uint32 coef,
        uint32 progress,
        uint32 radius,
        uint32 ringLength
    ) {
        Point memory p = points[_key(x, y)];
        if (!p.exists) return (false, address(0), 0, 0, 0, 0);
        return (true, p.owner, p.coef, p.progress, p.coef + 1, ringLen(p.coef + 1));
    }
}
