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

    /* ---------------- 普通节点结构 ---------------- */
    struct NormalListing {
        uint256 id;
        uint256 usdtNeeded;
        uint256 nativeNeeded;
    }

    NormalListing[] private _normalListings;
    mapping(uint256 => uint256) private _idxOf;
    uint256 private _normalIdNonce;

    /* ---------------- 构造函数 ---------------- */
    constructor(address superNodeNft_, address normalNodeNft_, address usdt_) {
        require(superNodeNft_ != address(0) && normalNodeNft_ != address(0) && usdt_ != address(0), "zero addr");
        superNodeNft = superNodeNft_;
        normalNodeNft = normalNodeNft_;
        usdt = IERC20(usdt_);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    /* ---------------- 管理 ---------------- */
    function setSuperNodeNft(address a) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(a != address(0), "zero");
        superNodeNft = a;
    }

    function setNormalNodeNft(address a) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(a != address(0), "zero");
        normalNodeNft = a;
    }

    function setUSDT(address a) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(a != address(0), "zero");
        usdt = IERC20(a);
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

    /* ---------------- 拍卖结算 ---------------- */
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

    /* ---------------- 普通节点上架 ---------------- */
    function listNormal(uint256 usdtNeeded, uint256 nativeNeeded)
        public
        onlyRole(ADMIN_ROLE)
        returns (uint256 id)
    {
        require(usdtNeeded > 0 || nativeNeeded > 0, "empty price");
        id = ++_normalIdNonce;

        NormalListing memory it = NormalListing({
            id: id,
            usdtNeeded: usdtNeeded,
            nativeNeeded: nativeNeeded
        });

        _idxOf[id] = _normalListings.length + 1;
        _normalListings.push(it);

        emit NormalListed(id, usdtNeeded, nativeNeeded);
    }

    function listNormalBatch(uint256[] calldata usdtList, uint256[] calldata nativeList)
        external
        onlyRole(ADMIN_ROLE)
    {
        require(usdtList.length == nativeList.length, "len mismatch");
        uint256 n = usdtList.length;
        for (uint256 i = 0; i < n; i++) {
            listNormal(usdtList[i], nativeList[i]);
        }
        emit NormalBatchListed(n);
    }

    // ========== 模块二：分页查询正在上架的普通节点 ==========
    function normalListingsCount() external view returns (uint256) {
        return _normalListings.length;
    }

    function getNormalListings(uint256 start, uint256 limit)
        external
        view
        returns (NormalListing[] memory slice)
    {
        uint256 total = _normalListings.length;
        if (start >= total) return new NormalListing[](0);
        uint256 end = start + limit;
        if (end > total) end = total;
        uint256 size = end - start;

        slice = new NormalListing[](size);
        for (uint256 i = 0; i < size; i++) {
            slice[i] = _normalListings[start + i];
        }
    }

    /* ---------------- 购买普通节点 ---------------- */
    function buyNormal(uint256 id) external payable nonReentrant {
        uint256 idx1 = _idxOf[id];
        require(idx1 > 0, "not listed");
        uint256 idx = idx1 - 1;
        NormalListing memory it = _normalListings[idx];

        if (it.usdtNeeded > 0) {
            usdt.safeTransferFrom(msg.sender, address(this), it.usdtNeeded);
            withdrawableUSDT += it.usdtNeeded;
        }
        if (it.nativeNeeded > 0) {
            require(msg.value == it.nativeNeeded, "native mismatch");
            withdrawableNative += it.nativeNeeded;
        }

        uint256 nftId;
        try INodeTickets(normalNodeNft).mint(msg.sender) returns (uint256 tokenId) {
            nftId = tokenId;
        } catch {
            nftId = 0;
        }

        _removeNormalByIndex(idx);
        emit NormalPurchased(id, msg.sender, it.usdtNeeded, it.nativeNeeded, nftId);
    }

    /* ---------------- 下架与内部工具 ---------------- */
    function delistNormal(uint256 id) external onlyRole(ADMIN_ROLE) {
        uint256 idx1 = _idxOf[id];
        require(idx1 > 0, "not listed");
        uint256 idx = idx1 - 1;
        _removeNormalByIndex(idx);
        emit NormalDelisted(id);
    }

    function _removeNormalByIndex(uint256 i) internal {
        uint256 n = _normalListings.length;
        require(i < n, "bad index");
        uint256 removedId = _normalListings[i].id;
        uint256 last = n - 1;
        if (i != last) {
            NormalListing memory tail = _normalListings[last];
            _normalListings[i] = tail;
            _idxOf[tail.id] = i + 1;
        }
        _normalListings.pop();
        delete _idxOf[removedId];
        emit NormalArrayCompacted(i);
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

    event NormalListed(uint256 indexed id, uint256 usdtNeeded, uint256 nativeNeeded);
    event NormalBatchListed(uint256 count);
    event NormalDelisted(uint256 indexed id);
    event NormalPurchased(uint256 indexed id, address indexed buyer, uint256 usdtPaid, uint256 nativePaid, uint256 nftId);
    event NormalArrayCompacted(uint256 removedIndex);
}
