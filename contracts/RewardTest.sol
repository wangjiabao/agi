// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* ====== 基础库：Owner / Reentrancy / SafeERC20 / IERC20 ====== */

abstract contract Ownable {
    event OwnershipTransferred(address indexed prev, address indexed next);
    address public owner;
    constructor() { owner = msg.sender; emit OwnershipTransferred(address(0), msg.sender); }
    modifier onlyOwner() { require(msg.sender == owner, "NOT_OWNER"); _; }
    function transferOwnership(address next) external onlyOwner {
        require(next != address(0), "ZERO_ADDR");
        emit OwnershipTransferred(owner, next);
        owner = next;
    }
}

abstract contract ReentrancyGuard {
    uint256 private _entered = 1;
    modifier nonReentrant() {
        require(_entered == 1, "REENTRANCY");
        _entered = 2; _;
        _entered = 1;
    }
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address,uint256) external returns (bool);
    function transferFrom(address,address,uint256) external returns (bool);
    function approve(address,uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

library SafeERC20 {
    function safeTransfer(IERC20 t, address to, uint256 v) internal {
        (bool ok, bytes memory data) = address(t).call(abi.encodeWithSelector(t.transfer.selector, to, v));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FAIL");
    }
    function safeTransferFrom(IERC20 t, address f, address to, uint256 v) internal {
        (bool ok, bytes memory data) = address(t).call(abi.encodeWithSelector(t.transferFrom.selector, f, to, v));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAIL");
    }
}

/// @title SingleTokenLinearStaking
/// @notice 单币 A 质押并以 A 分红：按秒线性、时间×份额加权分配
/// @dev 适配常见“drip”式分红；池子为空时不计提；内置奖励金库 rewardReserves
contract SingleTokenLinearStaking is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant PRECISION = 1e18;

    IERC20  public immutable A;          // A 既是质押币也是奖励币
    uint256 public rewardRate;           // 每秒发放的 A 数量（例如 10000 A/s）

    // --- 全局累计 ---
    uint256 public totalStaked;          // 全局质押
    uint256 public rewardPerTokenStored; // 全局累计（每个质押单位的累计奖励，1e18 精度）
    uint256 public lastUpdateTime;       // 上次更新时刻（unix 秒）

    // --- 奖励金库（避免动用用户本金） ---
    uint256 public rewardReserves;       // 管理员提前注入、用于发放奖励的 A 数量

    // --- 用户账本 ---
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards; // 已结算未提

    // --- 事件 ---
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event Funded(uint256 amount, address indexed from);
    event RewardRateUpdated(uint256 newRate);
    event Sweep(address indexed to, uint256 amount);

    constructor(address aToken, uint256 initialRate) {
        require(aToken != address(0), "ZERO_TOKEN");
        A = IERC20(aToken);
        rewardRate = initialRate;
        lastUpdateTime = block.timestamp;
        emit RewardRateUpdated(initialRate);
    }

    // ========= 读方法 =========

    /// @notice 预览到“此刻”的全局每份奖励
    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        uint256 delta = block.timestamp - lastUpdateTime;
        // 仅当池里有人时才增长；空池不计提
        return rewardPerTokenStored + (delta * rewardRate * PRECISION) / totalStaked;
    }

    /// @notice 预览某账户的可领取奖励（到“此刻”）
    function earned(address account) public view returns (uint256) {
        uint256 rpt = rewardPerToken();
        return rewards[account] + (balanceOf[account] * (rpt - userRewardPerTokenPaid[account])) / PRECISION;
    }

    // ========= 写方法 =========

    /// @dev 先结算全局与用户，再执行主体逻辑
    modifier updateReward(address account) {
        // 1) 结算全局
        uint256 rpt = rewardPerToken();
        rewardPerTokenStored = rpt;
        lastUpdateTime = block.timestamp;

        // 2) 结算用户
        if (account != address(0)) {
            rewards[account] = rewards[account] + (balanceOf[account] * (rpt - userRewardPerTokenPaid[account])) / PRECISION;
            userRewardPerTokenPaid[account] = rpt;
        }
        _;
    }

    /// @notice 质押 A（进入算力池）
    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "ZERO_AMOUNT");
        balanceOf[msg.sender] += amount;
        totalStaked += amount;
        A.safeTransferFrom(msg.sender, address(this), amount); // 用户本金进入合约
        emit Staked(msg.sender, amount);
    }

    /// @notice 退出部分/全部质押（拿回本金）
    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "ZERO_AMOUNT");
        uint256 bal = balanceOf[msg.sender];
        require(bal >= amount, "INSUFFICIENT_STAKE");
        balanceOf[msg.sender] = bal - amount;
        totalStaked -= amount;
        A.safeTransfer(msg.sender, amount); // 归还本金
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice 领取已累计的奖励 A（不影响本金与算力）
    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "NO_REWARD");
        rewards[msg.sender] = 0;

        // 仅能动用 rewardsReserves，不会动到用户本金
        require(rewardReserves >= reward, "INSUFFICIENT_REWARD_RESERVES");
        rewardReserves -= reward;
        A.safeTransfer(msg.sender, reward);
        emit RewardPaid(msg.sender, reward);
    }

    /// @notice 一次性提走本金+奖励
    function exit() external {
        withdraw(balanceOf[msg.sender]);
        getReward();
    }

    // ========= 管理员（Owner） =========

    /// @notice 注资奖励金库（管理员准备足够的 A 供提取）
    function fundRewards(uint256 amount) external onlyOwner {
        require(amount > 0, "ZERO_AMOUNT");
        rewardReserves += amount;
        A.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(amount, msg.sender);
    }

    /// @notice 设置每秒分红速率（单位：A / 秒）
    function setRewardRate(uint256 newRate) external onlyOwner updateReward(address(0)) {
        rewardRate = newRate;
        emit RewardRateUpdated(newRate);
    }

    /// @notice 清理“多余”A（非本金非奖励金库的那一部分）
    function sweepExcess(address to) external onlyOwner {
        require(to != address(0), "ZERO_TO");
        uint256 bal = A.balanceOf(address(this));
        // 不得动用本金与奖励金库
        uint256 minNeeded = totalStaked + rewardReserves;
        require(bal > minNeeded, "NO_EXCESS");
        uint256 excess = bal - minNeeded;
        A.safeTransfer(to, excess);
        emit Sweep(to, excess);
    }
}
