// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface INodeTickets {
    function mint(address to) external returns (uint256);
}

contract AuctionHouseNodes is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ---------------- 角色 ---------------- */
    bytes32 public constant ADMIN_ROLE    = keccak256("ADMIN_ROLE");
    bytes32 public constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE");

    /* ---------------- 外部合约 ---------------- */
    address public superNodeNft;
    address public normalNodeNft;
    IERC20  public usdt;

    /* ---------------- 拍卖结构 ---------------- */
    enum AuctionStatus { Created, Active, Ended }

    struct Auction {
        uint64  startTime;
        uint64  bidExtendWindow;
        uint256 usdtFixed;
        uint256 nativeFixed;
        uint256 step;
        AuctionStatus status;
        address currentBidder;
        uint256 currentNative;
        uint64  lastBidTime;
        bool    nftClaimed;
    }

    Auction[] private _auctions;

    uint256 public withdrawableUSDT;
    uint256 public withdrawableNative;

    uint256 public usdtNeeded;
    uint256 public nativeNeeded;

    /* ---------------- 构造函数 ---------------- */
    constructor(address superNodeNft_, address normalNodeNft_, address usdt_) {
        require(superNodeNft_ != address(0) && normalNodeNft_ != address(0) && usdt_ != address(0), "zero addr");
        superNodeNft = superNodeNft_;
        normalNodeNft = normalNodeNft_;
        usdt = IERC20(usdt_);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    receive() external payable {}

    /* ---------------- 工具 ---------------- */
    function auctionsCount() external view returns (uint256) { return _auctions.length; }

    function getAuction(uint256 auctionId) external view returns (Auction memory) {
        require(auctionId < _auctions.length, "bad id");
        return _auctions[auctionId];
    }

    function _isAuctionExpired(Auction memory a) internal view returns (bool) {
        if (a.lastBidTime == 0) return false;
        return (block.timestamp > a.lastBidTime + a.bidExtendWindow);
    }

    /* ---------------- 拍卖上架 ---------------- */
    function createAuction(
        uint64  startTime,
        uint256 usdtFixed,
        uint256 startNativePrice,
        uint256 step,
        uint64  bidExtendWindow
    ) external onlyRole(ADMIN_ROLE) returns (uint256 auctionId) {
        require(usdtFixed > 0, "usdt=0");
        require(startNativePrice > 0, "start=0");
        require(step > 0, "step=0");
        require(bidExtendWindow > 0, "window=0");

        Auction memory a;
        a.startTime       = startTime;
        a.usdtFixed       = usdtFixed;
        a.nativeFixed     = startNativePrice;
        a.currentNative   = startNativePrice;
        a.step            = step;
        a.bidExtendWindow = bidExtendWindow;
        a.status          = AuctionStatus.Created;

        _auctions.push(a);
        auctionId = _auctions.length - 1;

        emit AuctionCreated(auctionId, startTime, usdtFixed, startNativePrice, step, bidExtendWindow);
    }

    /* ---------------- 出价 ---------------- */
    function bid(uint256 auctionId) external payable nonReentrant {
        require(auctionId < _auctions.length, "bad id");
        Auction storage a = _auctions[auctionId];

        require(a.status <= AuctionStatus.Active, "not active");
        require(block.timestamp >= a.startTime, "not started");
        require(!_isAuctionExpired(a), "expired");

        if (a.status == AuctionStatus.Created) {
            require(msg.value >= a.currentNative, "bid too low");
            a.status = AuctionStatus.Active;
            emit AuctionActivated(auctionId);
        } else {
            require(msg.value > a.currentNative, "bid too low");
        }
        require((msg.value - a.currentNative) % a.step == 0, "step multiple");

        address prev = a.currentBidder;
        uint256 prevNative = a.currentNative;

        a.currentBidder = msg.sender;
        a.currentNative = msg.value;
        a.lastBidTime   = uint64(block.timestamp);

        usdt.safeTransferFrom(msg.sender, address(this), a.usdtFixed);

        // === 退款给上一个出价人 ===
        if (prev != address(0)) {
            (bool ok1, ) = address(usdt).call(
                abi.encodeWithSelector(IERC20.transfer.selector, prev, a.usdtFixed)
            );
            if (!ok1) emit RefundFailed(prev, 0); // 0=USDT

            (bool ok2, ) = payable(prev).call{value: prevNative}("");
            if (!ok2) emit RefundFailed(prev, 1); // 1=Native

            emit PreviousBidRefunded(auctionId, prev, a.usdtFixed, prevNative);
        }

        emit BidPlaced(auctionId, msg.sender, a.usdtFixed, msg.value, uint64(block.timestamp));
    }

    /* ---------------- 拍卖完成，结算铸造nft ---------------- */
    function settleAuction(uint256 auctionId) public nonReentrant {
        require(auctionId < _auctions.length, "bad id");
        Auction storage a = _auctions[auctionId];

        require(a.status == AuctionStatus.Active, "bad status");
        require(_isAuctionExpired(a), "not expired");

        a.status = AuctionStatus.Ended;
        withdrawableUSDT   += a.usdtFixed;
        withdrawableNative += a.currentNative;

        uint256 nftId;
        try INodeTickets(superNodeNft).mint(a.currentBidder) returns (uint256 tokenId) {
            nftId = tokenId;
        } catch {
            nftId = 0;
        }

        a.nftClaimed = true;
        emit AuctionEnded(auctionId, a.currentBidder, a.usdtFixed, a.currentNative, nftId);
    }

    /* ---------------- 普通节点设置价格 ---------------- */
    function setNormal(uint256 _usdtNeeded, uint256 _nativeNeeded) public onlyRole(ADMIN_ROLE) {
        usdtNeeded = _usdtNeeded;
        nativeNeeded = _nativeNeeded;
        emit NormalSeted(usdtNeeded, nativeNeeded);
    }

    /* ---------------- 购买普通节点 ---------------- */
    function buyNormal() external payable nonReentrant {
        if (usdtNeeded > 0) {
            usdt.safeTransferFrom(msg.sender, address(this), usdtNeeded);
            withdrawableUSDT += usdtNeeded;
        }
        if (nativeNeeded > 0) {
            require(msg.value == nativeNeeded, "native mismatch");
            withdrawableNative += nativeNeeded;
        }

        uint256 nftId;
        try INodeTickets(normalNodeNft).mint(msg.sender) returns (uint256 tokenId) {
            nftId = tokenId;
        } catch {
            nftId = 0;
        }

        emit NormalPurchased(msg.sender, usdtNeeded, nativeNeeded, nftId);
    }

    /* ---------------- 提现 ---------------- */
    function withdrawUSDT(address to, uint256 amount)
        external
        onlyRole(WITHDRAW_ROLE)
        nonReentrant
    {
        require(to != address(0), "zero");
        require(amount <= withdrawableUSDT, "exceed");
        withdrawableUSDT -= amount;
        usdt.safeTransfer(to, amount);
    }

    function withdrawNative(address payable to, uint256 amount)
        external
        onlyRole(WITHDRAW_ROLE)
        nonReentrant
    {
        require(to != address(0), "zero");
        require(amount <= withdrawableNative, "exceed");
        withdrawableNative -= amount;
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw native failed");
    }

    /* ---------------- 事件 ---------------- */
    event AuctionCreated(uint256 indexed auctionId, uint64 startTime, uint256 usdtFixed, uint256 startNativePrice, uint256 step, uint64 bidExtendWindow);
    event AuctionActivated(uint256 indexed auctionId);
    event BidPlaced(uint256 indexed auctionId, address indexed bidder, uint256 usdtAmount, uint256 nativeAmount, uint64 time);
    event PreviousBidRefunded(uint256 indexed auctionId, address indexed prevBidder, uint256 usdtAmount, uint256 nativeAmount);
    event RefundFailed(address indexed user, uint8 assetType); // 0=USDT, 1=Native
    event AuctionEnded(uint256 indexed auctionId, address winner, uint256 usdtFixed, uint256 nativeAmount, uint256 nftId);

    event NormalSeted(uint256 usdtNeeded, uint256 nativeNeeded);
    event NormalPurchased(address indexed buyer, uint256 usdtPaid, uint256 nativePaid, uint256 nftId);
}
