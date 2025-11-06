// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

contract NodeTickets is ERC721, AccessControl {
    using Strings for uint256;

    // 角色
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // BaseURI（仅用于在未设置图片时作为 image 的兜底；也可留空）
    string private _baseTokenURI;

    // 自增 ID 与供应
    uint256 private _nextTokenId;
    uint256 public totalSupply;

    // ====== 图片设置（两种方式，链接或字节） ======
    // 每个 token 独立图片链接（如 https://... 或 ipfs://...）
    mapping(uint256 => string) private _imageURIOf;

    // 每个 token 的内联图片字节与 MIME 类型
    mapping(uint256 => bytes)  private _imageBytesOf;
    mapping(uint256 => string) private _imageMimeOf;

    // 图片大小上限（0 表示不限制；由管理员设定，避免误传超大图片）
    uint256 public maxInlineImageBytes;

    // 事件
    event TokenImageURISet(uint256 indexed tokenId, string uri);
    event TokenImageRawSet(uint256 indexed tokenId, string mime, uint256 size);
    event TokenImageCleared(uint256 indexed tokenId);

    // 自定义错误
    error BurnDisabled();
    error NonexistentToken();
    error NotOwnerNorApproved();
    error ImageTooLarge();

    constructor(
        address initialAdmin,
        string memory name_,
        string memory symbol_,
        string memory baseURI_
    ) ERC721(name_, symbol_) {
        require(initialAdmin != address(0), "zero admin");

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _baseTokenURI = baseURI_;
        _nextTokenId = 1;
    }

    // --- 管理（非图片写入，仅全局参数/铸造授权） ---
    function setBaseURI(string calldata baseURI_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _baseTokenURI = baseURI_;
    }

    function setMaxInlineImageBytes(uint256 maxBytes) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxInlineImageBytes = maxBytes; // 0 = 不限制
    }

    function authorizeMarketplaceAsMinter(address market, bool grant_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (grant_) _grantRole(MINTER_ROLE, market);
        else _revokeRole(MINTER_ROLE, market);
    }

    // --- 铸造（仅 MINTER_ROLE）---
    function mint(address to)
        external
        onlyRole(MINTER_ROLE)
        returns (uint256 tokenId)
    {
        tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        unchecked { totalSupply += 1; }
    }

    // ====== 内部：校验“持有者或其授权者” ======
    function _requireTokenController(uint256 tokenId) internal view {
        if (_ownerOf(tokenId) == address(0)) revert NonexistentToken();
        address owner = ownerOf(tokenId);
        if (
            msg.sender != owner &&
            getApproved(tokenId) != msg.sender &&
            !isApprovedForAll(owner, msg.sender)
        ) {
            revert NotOwnerNorApproved();
        }
    }

    // ====== 图片写入接口（由持有者/授权者设置） ======

    /// @notice 为 token 设置图片链接（如 https:// 或 ipfs://）
    function setTokenImageURI(uint256 tokenId, string calldata imageURI) external {
        _requireTokenController(tokenId);
        _imageURIOf[tokenId] = imageURI;
        emit TokenImageURISet(tokenId, imageURI);
    }

    /// @notice 批量设置图片链接（逐个检查控制权）
    function batchSetTokenImageURI(uint256[] calldata tokenIds, string[] calldata imageURIs) external {
        require(tokenIds.length == imageURIs.length, "length mismatch");
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            _requireTokenController(tokenIds[i]);
            _imageURIOf[tokenIds[i]] = imageURIs[i];
            emit TokenImageURISet(tokenIds[i], imageURIs[i]);
        }
    }

    /// @notice 设置内联图片（整张图片字节存链上）
    function setTokenImageRaw(uint256 tokenId, string calldata mime, bytes calldata imageRaw) external {
        _requireTokenController(tokenId);
        if (maxInlineImageBytes != 0 && imageRaw.length > maxInlineImageBytes) revert ImageTooLarge();

        _imageBytesOf[tokenId] = imageRaw;
        _imageMimeOf[tokenId]  = mime;
        emit TokenImageRawSet(tokenId, mime, imageRaw.length);
    }

    /// @notice 批量设置内联图片（逐个检查）
    function batchSetTokenImageRaw(
        uint256[] calldata tokenIds,
        string[] calldata mimes,
        bytes[] calldata imagesRaw
    ) external {
        require(tokenIds.length == mimes.length && mimes.length == imagesRaw.length, "length mismatch");
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            _requireTokenController(tokenIds[i]);
            if (maxInlineImageBytes != 0 && imagesRaw[i].length > maxInlineImageBytes) revert ImageTooLarge();

            _imageBytesOf[tokenIds[i]] = imagesRaw[i];
            _imageMimeOf[tokenIds[i]]  = mimes[i];
            emit TokenImageRawSet(tokenIds[i], mimes[i], imagesRaw[i].length);
        }
    }

    /// @notice 清除图片（同时清空链接与内联字节）
    function clearTokenImage(uint256 tokenId) external {
        _requireTokenController(tokenId);
        delete _imageURIOf[tokenId];
        delete _imageBytesOf[tokenId];
        delete _imageMimeOf[tokenId];
        emit TokenImageCleared(tokenId);
    }

    // ====== 图片读取 ======
    /// @notice 返回最终可用的图片 URI（内联优先）
    function imageOf(uint256 tokenId) public view returns (string memory) {
        if (_ownerOf(tokenId) == address(0)) revert NonexistentToken();

        bytes memory raw = _imageBytesOf[tokenId];
        if (raw.length > 0) {
            string memory mime = _imageMimeOf[tokenId];
            return string.concat(
                "data:",
                bytes(mime).length > 0 ? mime : "application/octet-stream",
                ";base64,",
                Base64.encode(raw)
            );
        }

        string memory uri = _imageURIOf[tokenId];
        if (bytes(uri).length > 0) {
            return uri;
        }

        // 兜底：如未设置任何图片，回退到 baseURI + tokenId（若 base 为空则返回空）
        string memory base = _baseURI();
        return bytes(base).length > 0 ? string(abi.encodePacked(base, tokenId.toString())) : "";
    }

    // --- URI（链上 JSON） ---
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    /// @notice 返回 data:application/json;base64,... 的链上元数据（包含 image 字段）
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (_ownerOf(tokenId) == address(0)) revert NonexistentToken();

        // name 用合约名 + #id，省去额外存储
        string memory name_ = string.concat(name(), " #", tokenId.toString());

        // 优先：用户设置的图片（内联或链接）；否则回退 baseURI+id；仍可能为空字符串
        string memory image_ = imageOf(tokenId);

        // attributes 填满；这里先给一个最小合规 JSON
        bytes memory json = abi.encodePacked(
            '{',
                '"name":"', name_, '",',
                '"description":"NodeTickets - user-set image stored on-chain or by URL.",',
                '"image":"', image_, '"',
            '}'
        );

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(json)
        );
    }

    // --- 内部 ---
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        if (to == address(0)) revert BurnDisabled();
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
