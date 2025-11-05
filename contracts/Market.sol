// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/* ------------ Factory (market path) ------------ */
interface IFactoryMarket {
    function isMap(address map) external view returns (bool);
    function marketLockPoint(address map, int32 x, int32 y, bool lock_) external;
    function marketReplacePointOwner(address map, int32 x, int32 y, address newOwner) external;
}

/* ------------ MapGrid read-only (light) ------------ */
interface IMapGridLight {
    function getPointOwner(int32 x, int32 y) external view returns (address);
    function getPointNativeStake(int32 x, int32 y) external view returns (uint256);
    function isPointLocked(int32 x, int32 y) external view returns (bool);
}

contract Market is ReentrancyGuard, ERC721Holder, AccessControl {
    using SafeERC20 for IERC20;

    /* ---------------- 基础配置 ---------------- */
    address public immutable superNodeNft;   // 超级节点 NFT
    address public immutable normalNodeNft;  // 节点 NFT
    IERC20  public immutable usdt;           // USDT (ERC20)
    IFactoryMarket public immutable factory; // MapFactory（固定 market 地址）

    bytes32 public constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ===== 新增：手续费设置（仅两项） =====
    // 默认 10% ： feeRate=10, feeBase=100
    uint256 public feeRate = 10;
    uint256 public feeBase = 100;

    // kind：0=超级节点NFT, 1=普通节点NFT, 2=地图点位
    struct Listing {
        uint256 id;
        address nft;         // kind 0/1 使用；kind 2 置为 address(0)
        uint256 tokenId;     // kind 0/1 使用；kind 2 为 0
        address seller;
        uint256 usdtPrice;   // USDT 最小单位
        uint256 nativePrice; // 原生币 wei（AGI）
        uint64  startTime;
        uint8   kind;        // 0/1/2
        // ---- 地图点位专用 ----
        address map;         // 地图地址（kind=2 必填）
        int32   x;
        int32   y;
    }

    // 全局进行中（对象数组）
    Listing[] public activeListings;
    // id => activeListings 中的 index+1（0 表示不存在）
    mapping(uint256 => uint256) private _idxOfActivePlus1;

    // 卖家进行中（仅存 id）
    mapping(address => uint256[]) public sellerActiveIds;
    // id => sellerActiveIds[seller] 中的 index+1
    mapping(uint256 => uint256) private _idxOfSellerPlus1;

    // 通过 id 读取快照（上架时写入；下架/成交不删除，便于追溯）
    mapping(uint256 => Listing) private _byId;

    // 自增 id
    uint256 private _idNonce;

    /* ---------------- 事件 ---------------- */
    event Listed(
        uint256 indexed id,
        address indexed seller,
        uint8   kind,
        address nft,
        uint256 tokenId,
        address map,
        int32   x,
        int32   y,
        uint256 usdtPrice,
        uint256 nativePrice,
        uint64  startTime
    );
    event ListedBatch(address indexed seller, uint256 count);
    event Delisted(uint256 indexed id, address indexed seller);

    // ===== 事件仅在末尾追加两个新参数（保持前面顺序不变） =====
    event Purchased(
        uint256 indexed id,
        address indexed seller,
        address indexed buyer,
        uint8 kind,
        uint256 usdtAmount,  // USDT 成交额（未扣手续费的成交总额）
        uint256 agiAmount    // 原生币成交额（未扣手续费的成交总额）
    );

    event ActiveArrayCompacted(uint256 removedIndex);
    event SellerArrayCompacted(address indexed seller, uint256 removedIndex);

    /* ---------------- 构造 ---------------- */
    constructor(address _superNodeNft, address _normalNodeNft, address _usdt, address _factory) {
        require(_superNodeNft != address(0) && _normalNodeNft != address(0) && _usdt != address(0) && _factory != address(0), "zero addr");
        superNodeNft  = _superNodeNft;
        normalNodeNft = _normalNodeNft;
        usdt          = IERC20(_usdt);
        factory       = IFactoryMarket(_factory);

        // 新增：权限初始化（默认管理员为部署者）
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    /* ---------------- 视图 ---------------- */
    function activeCount() external view returns (uint256) { return activeListings.length; }
    function sellerActiveCount(address seller) external view returns (uint256) { return sellerActiveIds[seller].length; }
    function getListingById(uint256 id) external view returns (Listing memory) { return _byId[id]; }

    function getActiveSlice(uint256 start, uint256 limit) external view returns (Listing[] memory slice) {
        uint256 total = activeListings.length;
        if (start >= total) return new Listing[](0);
        uint256 end = start + limit; if (end > total) end = total;
        uint256 size = end - start;  slice = new Listing[](size);
        for (uint256 i=0; i<size; i++) slice[i] = activeListings[start + i];
    }
    function getSellerActiveSlice(address seller, uint256 start, uint256 limit)
        external view returns (uint256[] memory ids)
    {
        uint256 total = sellerActiveIds[seller].length;
        if (start >= total) return new uint256[](0);
        uint256 end = start + limit; if (end > total) end = total;
        uint256 size = end - start;  ids = new uint256[](size);
        for (uint256 i=0; i<size; i++) ids[i] = sellerActiveIds[seller][start + i];
    }

    /* ---------------- 上架（函数名保留：listOne） ---------------- */
    function listOne(
        address nft,
        uint256 tokenId,
        uint8   kind,
        uint256 usdtPrice,
        uint256 nativePrice,
        address map,
        int32   x,
        int32   y
    ) external nonReentrant returns (uint256 id) {
        if (kind == 0 || kind == 1) {
            if (kind == 0) require(nft == superNodeNft, "nft!=super");
            if (kind == 1) require(nft == normalNodeNft, "nft!=normal");
            IERC721(nft).safeTransferFrom(msg.sender, address(this), tokenId);
        } else if (kind == 2) {
            require(map != address(0), "map=0");
            require(factory.isMap(map), "map not registered");
            address owner = IMapGridLight(map).getPointOwner(x, y);
            require(owner == msg.sender, "not point owner");
            uint256 stake = IMapGridLight(map).getPointNativeStake(x, y);
            require(stake > 0, "stake=0");               // ★ nativeStake 必须 > 0
            bool locked = IMapGridLight(map).isPointLocked(x, y);
            require(!locked, "point locked");
            // 锁定点位（严格模式：失败即 revert）
            factory.marketLockPoint(map, x, y, true);
        } else {
            revert("bad kind");
        }

        id = ++_idNonce;
        Listing memory it = Listing({
            id: id,
            nft: nft,
            tokenId: tokenId,
            seller: msg.sender,
            usdtPrice: usdtPrice,
            nativePrice: nativePrice,
            startTime: uint64(block.timestamp),
            kind: kind,
            map: map,
            x: x,
            y: y
        });

        _idxOfActivePlus1[id] = activeListings.length + 1;
        activeListings.push(it);

        _idxOfSellerPlus1[id] = sellerActiveIds[msg.sender].length + 1;
        sellerActiveIds[msg.sender].push(id);

        _byId[id] = it;
        emit Listed(id, msg.sender, kind, nft, tokenId, map, x, y, usdtPrice, nativePrice, it.startTime);
    }

    /* ---------------- 下架 ---------------- */
    function delist(uint256 id) external nonReentrant {
        uint256 idx1 = _idxOfActivePlus1[id];
        require(idx1 > 0, "not active");
        uint256 idx = idx1 - 1;

        Listing memory it = activeListings[idx];
        require(it.seller == msg.sender, "not seller");

        _removeFromActive(idx);
        _removeFromSeller(it.seller, id);

        if (it.kind == 0 || it.kind == 1) {
            IERC721(it.nft).safeTransferFrom(address(this), it.seller, it.tokenId);
        } else {
            // 地图点位：解锁
            factory.marketLockPoint(it.map, it.x, it.y, false);
        }

        emit Delisted(id, it.seller);
    }

    /* ---------------- 购买 ---------------- */
    function buy(uint256 id, bool useUsdt) external payable nonReentrant {
        uint256 idx1 = _idxOfActivePlus1[id];
        require(idx1 > 0, "not active");
        uint256 idx = idx1 - 1;

        Listing memory it = activeListings[idx];
        require(msg.sender != it.seller, "self buy");

        if (useUsdt) {
            require(it.usdtPrice > 0, "usdt=0");

            // ===== 新增：手续费扣除（USDT）=====
            uint256 fee = (it.usdtPrice * feeRate) / feeBase;
            uint256 toSeller = it.usdtPrice - fee;

            // 卖家实收
            usdt.safeTransferFrom(msg.sender, it.seller, toSeller);
            // 手续费归合约（后续可新增提取函数）
            if (fee > 0) {
                usdt.safeTransferFrom(msg.sender, address(this), fee);
            }
        } else {
            require(it.nativePrice > 0, "native=0");
            require(msg.value == it.nativePrice, "bad native");

            // ===== 新增：手续费扣除（原生币/AGI）=====
            uint256 fee = (it.nativePrice * feeRate) / feeBase;
            uint256 toSeller = it.nativePrice - fee;

            (bool ok, ) = payable(it.seller).call{value: toSeller}("");
            require(ok, "native transfer failed");
            // fee 留在合约余额
        }

        _removeFromActive(idx);
        _removeFromSeller(it.seller, id);

        if (it.kind == 0 || it.kind == 1) {
            IERC721(it.nft).safeTransferFrom(address(this), msg.sender, it.tokenId);
        } else {
            // 地图点位：仅替换 owner（不改 tokenId/nativeStake/coef/progress 等），并解锁
            factory.marketReplacePointOwner(it.map, it.x, it.y, msg.sender);
        }

        // 事件末尾新增成交额（哪个币成交，另一个填 0）
        emit Purchased(
            id,
            it.seller,
            msg.sender,
            it.kind,
            useUsdt ? it.usdtPrice : 0,
            useUsdt ? 0 : it.nativePrice
        );
    }

    /* ---------------- 管理（新增） ---------------- */
    // 仅允许管理员改手续费比例（两个值：rate/base）
    function setFee(uint256 rate, uint256 base) external onlyRole(ADMIN_ROLE) {
        require(base > 0, "base=0");
        require(rate <= base, "rate>base");
        feeRate = rate;
        feeBase = base;
    }

    /* ---------------- 内部工具 ---------------- */
    function _removeFromActive(uint256 i) internal {
        uint256 n = activeListings.length;
        uint256 last = n - 1;

        if (i != last) {
            Listing memory tail = activeListings[last];
            activeListings[i] = tail;
            _idxOfActivePlus1[tail.id] = i + 1;
        }
        activeListings.pop();
        delete _idxOfActivePlus1[_byId[activeListings.length].id]; // 清理不是必须，但不影响
        emit ActiveArrayCompacted(i);
    }

    function _removeFromSeller(address seller, uint256 id) internal {
        uint256 idx1 = _idxOfSellerPlus1[id];
        if (idx1 == 0) return;
        uint256 i = idx1 - 1;

        uint256[] storage arr = sellerActiveIds[seller];
        uint256 n = arr.length;
        uint256 last = n - 1;

        if (i != last) {
            uint256 tailId = arr[last];
            arr[i] = tailId;
            _idxOfSellerPlus1[tailId] = i + 1;
        }
        arr.pop();
        delete _idxOfSellerPlus1[id];
        emit SellerArrayCompacted(seller, i);
    }

    /// @notice 提取合约内累计的 USDT 手续费
    function withdrawUSDT(address to, uint256 amount) external onlyRole(WITHDRAW_ROLE) nonReentrant {
        require(to != address(0), "to=0");
        usdt.safeTransfer(to, amount);
    }

    /// @notice 提取合约内累计的原生币手续费
    function withdrawNative(address to, uint256 amount) external onlyRole(WITHDRAW_ROLE) nonReentrant {
        require(to != address(0), "to=0");
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "native withdraw failed");
    }
}
