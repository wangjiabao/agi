// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address}         from "@openzeppelin/contracts/utils/Address.sol";

interface IFactorySuper {
    function dividendRateSuper() external view returns (uint256);
    function isMap(address) external view returns (bool);
}

/**
 * @title NativeDividendSuperOnly
 * @notice 超级节点分红池（原生币）。仅对“注册地图”开放 map-only 方法。
 */
contract NativeDividendSuperOnly is ReentrancyGuard {
    using Address for address payable;

    uint256 public constant PRECISION = 1e18;

    address public immutable factory;

    uint256 public totalStaked;
    uint256 public rewardPerTokenStored;
    uint256 public lastUpdateTime;

    uint256 public rewardReserves;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event Funded(address indexed from, uint256 amount);
    event Staked(address indexed user, uint256 amount);    // map-only
    event Withdrawn(address indexed user, uint256 amount); // map-only
    event RewardPaid(address indexed user, uint256 amount);
    event Replaced(address indexed oldUser, address indexed newUser, uint256 newUserStake);
    event OwnerTransferred(address indexed oldUser, address indexed newUser);

    error ZeroFactory();
    error NotMap();
    error ZeroAmount();
    error InsufficientStake();
    error NewUserNotEmpty();

    modifier onlyMap() {
        if (!IFactorySuper(factory).isMap(msg.sender)) revert NotMap();
        _;
    }

    constructor(address factory_) {
        if (factory_ == address(0)) revert ZeroFactory();
        factory = factory_;
        lastUpdateTime = block.timestamp;
    }

    function _rate() internal view returns (uint256) {
        return IFactorySuper(factory).dividendRateSuper();
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        uint256 delta = block.timestamp - lastUpdateTime;
        return rewardPerTokenStored + (delta * _rate() * PRECISION) / totalStaked;
    }

    function earned(address account) public view returns (uint256) {
        uint256 rpt = rewardPerToken();
        return rewards[account] + (balanceOf[account] * (rpt - userRewardPerTokenPaid[account])) / PRECISION;
    }

    modifier updateReward(address account) {
        uint256 rpt = rewardPerToken();
        rewardPerTokenStored = rpt;
        lastUpdateTime = block.timestamp;
        if (account != address(0)) {
            rewards[account] = rewards[account] + (balanceOf[account] * (rpt - userRewardPerTokenPaid[account])) / PRECISION;
            userRewardPerTokenPaid[account] = rpt;
        }
        _;
    }

    /* ---- map-only ---- */

    function stakeFromMap(address user, uint256 amount) external onlyMap nonReentrant updateReward(user) {
        if (amount == 0) revert ZeroAmount();
        balanceOf[user] += amount;
        totalStaked += amount;
        emit Staked(user, amount);
    }

    function withdrawFromMap(address user, uint256 amount) external onlyMap nonReentrant updateReward(user) {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = balanceOf[user];
        if (bal < amount) revert InsufficientStake();
        balanceOf[user] = bal - amount;
        totalStaked -= amount;

        _claimTo(user, payable(user));
        emit Withdrawn(user, amount);
    }

    function harvestFromMap(address user) external onlyMap nonReentrant updateReward(user) {
        _claimTo(user, payable(user));
    }

    function fullReplaceFromMap(address oldUser, address newUser, uint256 newUserStake)
        external onlyMap nonReentrant updateReward(oldUser) updateReward(newUser)
    {
        uint256 oldStake = balanceOf[oldUser];
        if (oldStake > 0) {
            balanceOf[oldUser] = 0;
            totalStaked -= oldStake;
            _claimTo(oldUser, payable(oldUser));
        }
        if (newUserStake > 0) {
            balanceOf[newUser] += newUserStake;
            totalStaked += newUserStake;
            emit Staked(newUser, newUserStake);
        }
        emit Replaced(oldUser, newUser, newUserStake);
    }

    /// @notice 仅迁移地址：不更新 acc、不发放、不改 totalStaked
    function transferOwnerFromMap(address oldUser, address newUser) external onlyMap nonReentrant {
        require(oldUser != address(0) && newUser != address(0) && oldUser != newUser, "bad users");
        if (balanceOf[newUser] != 0 || rewards[newUser] != 0 || userRewardPerTokenPaid[newUser] != 0) {
            revert NewUserNotEmpty();
        }
        balanceOf[newUser] = balanceOf[oldUser];
        userRewardPerTokenPaid[newUser] = userRewardPerTokenPaid[oldUser];
        rewards[newUser] = rewards[oldUser];

        balanceOf[oldUser] = 0;
        userRewardPerTokenPaid[oldUser] = 0;
        rewards[oldUser] = 0;

        emit OwnerTransferred(oldUser, newUser);
    }

    /* ---- claim & funding ---- */
    function _claimTo(address user, address payable to) internal {
        uint256 amt = rewards[user];
        if (amt == 0) return;
        uint256 pay = amt;
        if (rewardReserves < pay) pay = rewardReserves;
        if (pay > 0) {
            rewards[user] = amt - pay;
            rewardReserves -= pay;
            to.sendValue(pay);
            emit RewardPaid(user, pay);
        }
    }

    function fund() external payable {
        require(msg.value > 0, "ZERO_FUND");
        rewardReserves += msg.value;
        emit Funded(msg.sender, msg.value);
    }
    receive() external payable {
        rewardReserves += msg.value;
        emit Funded(msg.sender, msg.value);
    }
}
