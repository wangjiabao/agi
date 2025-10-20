// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title SecondaryMarketStrict
 * @notice 二级市场（严格模式：任何对外转出失败都会 revert）
 * - 支持上架/批量上架 超级节点/节点 NFT（仅限构造传入的两种 NFT）
 * - 支持下架（退还 NFT）
 * - 支持购买（USDT + 原生币；把 NFT 转给买家；把款项转给卖家）
 * - 维护全局进行中对象数组 & 个人进行中 id 数组（均为 swap-with-last + pop 的 O(1) 移除）
 */
contract SecondaryMarketStrict is ReentrancyGuard, ERC721Holder {
    using SafeERC20 for IERC20;

    /* ----------------------------------------------------------- */
    /* ---------------------- 基础配置与状态 ---------------------- */
    /* ----------------------------------------------------------- */

    address public immutable superNodeNft;   // 超级节点 NFT
    address public immutable normalNodeNft;  // 节点 NFT
    IERC20  public immutable usdt;           // USDT (ERC20)

    // kind：0=超级节点, 1=节点
    struct Listing {
        uint256 id;
        address nft;
        uint256 tokenId;
        address seller;
        uint256 usdtPrice;    // USDT 最小单位
        uint256 nativePrice;  // 原生币 wei
        uint64  startTime;
        uint8   kind;         // 0/1
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

    /* ----------------------------------------------------------- */
    /* ---------------------------- 事件 -------------------------- */
    /* ----------------------------------------------------------- */

    event Listed(
        uint256 indexed id,
        address indexed seller,
        address indexed nft,
        uint256 tokenId,
        uint8 kind,
        uint256 usdtPrice,
        uint256 nativePrice,
        uint64  startTime
    );

    event ListedBatch(address indexed seller, uint256 count);

    event Delisted(uint256 indexed id, address indexed seller);

    event Purchased(
        uint256 indexed id,
        address indexed seller,
        address indexed buyer,
        uint256 usdtPaid,
        uint256 nativePaid
    );

    event ActiveArrayCompacted(uint256 removedIndex);
    event SellerArrayCompacted(address indexed seller, uint256 removedIndex);

    /* ----------------------------------------------------------- */
    /* -------------------------- 构造函数 ------------------------ */
    /* ----------------------------------------------------------- */

    constructor(address _superNodeNft, address _normalNodeNft, address _usdt) {
        require(_superNodeNft != address(0) && _normalNodeNft != address(0) && _usdt != address(0), "zero addr");
        superNodeNft  = _superNodeNft;
        normalNodeNft = _normalNodeNft;
        usdt          = IERC20(_usdt);
    }

    /* ----------------------------------------------------------- */
    /* --------------------------- 视图 --------------------------- */
    /* ----------------------------------------------------------- */

    function activeCount() external view returns (uint256) {
        return activeListings.length;
    }

    function sellerActiveCount(address seller) external view returns (uint256) {
        return sellerActiveIds[seller].length;
    }

    function getListingById(uint256 id) external view returns (Listing memory) {
        return _byId[id];
    }

    // 全局分页切片
    function getActiveSlice(uint256 start, uint256 limit) external view returns (Listing[] memory slice) {
        uint256 total = activeListings.length;
        if (start >= total) return new Listing[](0);
        uint256 end = start + limit;
        if (end > total) end = total;
        uint256 size = end - start;
        slice = new Listing[](size);
        for (uint256 i = 0; i < size; i++) {
            slice[i] = activeListings[start + i];
        }
    }

    // 卖家分页切片（返回 id 列表；详情可用 getListingById 查询）
    function getSellerActiveSlice(address seller, uint256 start, uint256 limit)
        external
        view
        returns (uint256[] memory ids)
    {
        uint256 total = sellerActiveIds[seller].length;
        if (start >= total) return new uint256[](0);
        uint256 end = start + limit;
        if (end > total) end = total;
        uint256 size = end - start;
        ids = new uint256[](size);
        for (uint256 i = 0; i < size; i++) {
            ids[i] = sellerActiveIds[seller][start + i];
        }
    }

    /* ----------------------------------------------------------- */
    /* ---------------------- 上架 / 批量上架 --------------------- */
    /* ----------------------------------------------------------- */

    /**
     * @dev 上架单个 NFT
     * @param nft  必须是 superNodeNft 或 normalNodeNft
     * @param tokenId NFT id
     * @param kind 0=超级节点, 1=节点
     * @param usdtPrice USDT 价格（最小单位）
     * @param nativePrice 原生币价格（wei）
     */
    function listOne(
        address nft,
        uint256 tokenId,
        uint8   kind,
        uint256 usdtPrice,
        uint256 nativePrice
    ) public nonReentrant returns (uint256 id) {
        require(nft == superNodeNft || nft == normalNodeNft, "nft not allowed");
        require(kind == 0 || kind == 1, "bad kind");

        // 将 NFT 转入本合约（失败 revert）
        IERC721(nft).safeTransferFrom(msg.sender, address(this), tokenId);

        id = ++_idNonce;

        Listing memory it = Listing({
            id: id,
            nft: nft,
            tokenId: tokenId,
            seller: msg.sender,
            usdtPrice: usdtPrice,
            nativePrice: nativePrice,
            startTime: uint64(block.timestamp),
            kind: kind
        });

        // 写入全局数组
        _idxOfActivePlus1[id] = activeListings.length + 1;
        activeListings.push(it);

        // 写入个人数组
        _idxOfSellerPlus1[id] = sellerActiveIds[msg.sender].length + 1;
        sellerActiveIds[msg.sender].push(id);

        // 缓存快照
        _byId[id] = it;

        emit Listed(id, msg.sender, nft, tokenId, kind, usdtPrice, nativePrice, it.startTime);
    }

    /**
     * @dev 批量上架；数组长度必须一致
     */
    function listBatch(
        address[] calldata nfts,
        uint256[] calldata tokenIds,
        uint8[]   calldata kinds,
        uint256[] calldata usdtPrices,
        uint256[] calldata nativePrices
    ) external nonReentrant returns (uint256 firstId, uint256 count) {
        uint256 n = nfts.length;
        require(
            n == tokenIds.length &&
            n == kinds.length &&
            n == usdtPrices.length &&
            n == nativePrices.length,
            "len mismatch"
        );

        for (uint256 i = 0; i < n; i++) {
            uint256 id = listOne(nfts[i], tokenIds[i], kinds[i], usdtPrices[i], nativePrices[i]);
            if (i == 0) firstId = id;
        }
        emit ListedBatch(msg.sender, n);
        return (firstId, n);
    }

    /* ----------------------------------------------------------- */
    /* --------------------------- 下架退款 ------------------------ */
    /* ----------------------------------------------------------- */

    function delist(uint256 id) external nonReentrant {
        uint256 idx1 = _idxOfActivePlus1[id];
        require(idx1 > 0, "not active");
        uint256 idx = idx1 - 1;

        Listing memory it = activeListings[idx];
        require(it.seller == msg.sender, "not seller");

        // 从两个数组移除（O(1)）
        _removeFromActive(idx);
        _removeFromSeller(it.seller, id);

        // 退还 NFT —— 严格模式：失败必须 revert
        IERC721(it.nft).safeTransferFrom(address(this), it.seller, it.tokenId);

        emit Delisted(id, it.seller);
    }

    /* ----------------------------------------------------------- */
    /* ------------------------------ 购买 ------------------------ */
    /* ----------------------------------------------------------- */

    function buy(uint256 id) external payable nonReentrant {
        uint256 idx1 = _idxOfActivePlus1[id];
        require(idx1 > 0, "not active");
        uint256 idx = idx1 - 1;

        Listing memory it = activeListings[idx];
        require(msg.sender != it.seller, "self buy");
        require(msg.value == it.nativePrice, "bad native");

        // 1) 买家 USDT -> 合约（失败回滚）
        if (it.usdtPrice > 0) {
            usdt.safeTransferFrom(msg.sender, address(this), it.usdtPrice);
        }

        // 2) 成交：先移除数组项（若后续转账失败会整体 revert，状态回滚，不会残留脏状态）
        _removeFromActive(idx);
        _removeFromSeller(it.seller, id);

        // 3) 向卖家“转出”款项（严格模式：失败必须 revert）
        if (it.usdtPrice > 0) {
            usdt.safeTransfer(it.seller, it.usdtPrice);
        }
        if (it.nativePrice > 0) {
            (bool ok, ) = payable(it.seller).call{value: it.nativePrice}("");
            require(ok, "native transfer failed");
        }

        // 4) 把 NFT 交付给买家（失败 revert）
        IERC721(it.nft).safeTransferFrom(address(this), msg.sender, it.tokenId);

        emit Purchased(id, it.seller, msg.sender, it.usdtPrice, it.nativePrice);
    }

    /* ----------------------------------------------------------- */
    /* --------------------------- 内部工具 ------------------------ */
    /* ----------------------------------------------------------- */

    // 全局 activeListings：swap-with-last + pop
    function _removeFromActive(uint256 i) internal {
        uint256 n = activeListings.length;
        uint256 last = n - 1;

        Listing memory removed = activeListings[i];

        if (i != last) {
            Listing memory tail = activeListings[last];
            activeListings[i] = tail;
            _idxOfActivePlus1[tail.id] = i + 1;
        }
        activeListings.pop();
        delete _idxOfActivePlus1[removed.id];

        emit ActiveArrayCompacted(i);
    }

    // 卖家 sellerActiveIds：swap-with-last + pop
    function _removeFromSeller(address seller, uint256 id) internal {
        uint256 idx1 = _idxOfSellerPlus1[id];
        if (idx1 == 0) return; // 容错
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
}
