// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Clones}        from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC721}       from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Address}       from "@openzeppelin/contracts/utils/Address.sol";

/* ------------ Map interface (扩展) ------------ */
interface IMapGrid {
    function initialize(address factory, address superNodeNFT, address nodeNFT) external;
    function acceptClaim(address staker, address nft, uint256 tokenId, int32 x, int32 y) external;
    function acceptReplacement(address newStaker, address newNft, uint256 newTokenId, int32 x, int32 y)
        external returns (address oldOwner, address oldNft, uint256 oldTokenId);
    function marketLockPoint(int32 x, int32 y, bool lock_) external;
    function marketReplaceOwner(int32 x, int32 y, address newOwner) external returns (address oldOwner);
}

contract MapFactory is AccessControl {
    using Address for address payable;

    /* ---------------- Roles ---------------- */
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /* -------------- Template & NFT -------------- */
    address public immutable mapGridTemplate;
    address public immutable superNodeNFT;
    address public immutable nodeNFT;

    /* ---------------- Market 固定地址 ---------------- */
    address public market; // 仅能设置一次

    /* ---------------- Maps ---------------- */
    address[] public allMaps;
    mapping(address => bool) public isMap;
    mapping(address => string) public mapNames;

    /* -------------- Global uniqueness -------------- */
    mapping(address => address) public userToMap; // user => map
    mapping(address => bool)    public userActive;

    /* -------------- Replacement fee -------------- */
    uint256 public replaceBurnAmount;

    /* -------------- Total power params -------------- */
    uint256 public powerA = 1e18;
    int256  public powerB = 0;

    /* -------------- Dividend rates & pools -------------- */
    uint256 public dividendRateAll;      // wei / sec
    uint256 public dividendRateSuper;    // wei / sec
    address public dividendAll;          // NativeDividendAll
    address public dividendSuper;        // NativeDividendSuperOnly
    bool    public poolsLocked;

    struct RateRecord { uint256 rate; uint256 timestamp; }
    RateRecord[] public allRateHistory;
    RateRecord[] public superRateHistory;

    /* ---------------- Events ---------------- */
    event MapCreated(address indexed by, address indexed map, string name);
    event MapNameUpdated(address indexed map, string oldName, string newName);

    event ClaimedThroughFactory(address indexed user, address indexed map, address indexed nft, uint256 tokenId, int32 x, int32 y);
    event ReplacedThroughFactory(address indexed newUser, address indexed map, address indexed nft, uint256 tokenId, int32 x, int32 y,
                                 address oldUser, address oldNft, uint256 oldTokenId, uint256 burnAmount);
    event GlobalCleared(address indexed oldUser);

    event MarketSet(address market);
    event ReplaceBurnAmountChanged(uint256 oldAmt, uint256 newAmt);
    event PowerAChanged(uint256 oldA, uint256 newA);
    event PowerBChanged(int256 oldB, int256 newB);
    event DividendRateAllChanged(uint256 oldRate, uint256 newRate);
    event DividendRateSuperChanged(uint256 oldRate, uint256 newRate);
    event DividendPoolsLocked(address allPool, address superPool);

    event MarketLocked(address indexed map, int32 x, int32 y, bool locked);
    event MarketOwnerReplaced(address indexed map, int32 x, int32 y, address indexed oldOwner, address indexed newOwner);

    /* ---------------- Errors ---------------- */
    error NotRegisteredMap();
    error NFTNotAllowed();
    error UserAlreadyActive();
    error IncorrectMsgValue();
    error AlreadySet();

    /* ---------------- Ctor ---------------- */
    constructor(address _mapGridTemplate, address _superNodeNFT, address _nodeNFT) {
        require(_mapGridTemplate != address(0), "template=0");
        require(_superNodeNFT != address(0) && _nodeNFT != address(0), "nft=0");
        mapGridTemplate = _mapGridTemplate;
        superNodeNFT    = _superNodeNFT;
        nodeNFT         = _nodeNFT;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    /* ---------------- Admin ops ---------------- */
    function setMarket(address _market) external onlyRole(ADMIN_ROLE) {
        if (market != address(0)) revert AlreadySet();
        require(_market != address(0), "zero");
        market = _market;
        emit MarketSet(_market);
    }

    function setReplaceBurnAmount(uint256 newAmt) external onlyRole(ADMIN_ROLE) {
        emit ReplaceBurnAmountChanged(replaceBurnAmount, newAmt);
        replaceBurnAmount = newAmt;
    }
    function setPowerA(uint256 newA) external onlyRole(ADMIN_ROLE) {
        require(newA > 0, "A>0");
        emit PowerAChanged(powerA, newA);
        powerA = newA;
    }
    function setPowerB(int256 newB) external onlyRole(ADMIN_ROLE) {
        emit PowerBChanged(powerB, newB);
        powerB = newB;
    }

    /* ---------------- Dividend Rates 拆分 ---------------- */
    function setDividendRateAll(uint256 newRate) external onlyRole(ADMIN_ROLE) {
        emit DividendRateAllChanged(dividendRateAll, newRate);
        dividendRateAll = newRate;
        allRateHistory.push(RateRecord({rate: newRate, timestamp: block.timestamp}));
    }

    function setDividendRateSuper(uint256 newRate) external onlyRole(ADMIN_ROLE) {
        emit DividendRateSuperChanged(dividendRateSuper, newRate);
        dividendRateSuper = newRate;
        superRateHistory.push(RateRecord({rate: newRate, timestamp: block.timestamp}));
    }

    function getAllRateHistory() external view returns (RateRecord[] memory) { return allRateHistory; }
    function getSuperRateHistory() external view returns (RateRecord[] memory) { return superRateHistory; }

    function setDividendPools(address newAll, address newSuper) external onlyRole(ADMIN_ROLE) {
        require(!poolsLocked, "pools locked");
        dividendAll  = newAll;
        dividendSuper= newSuper;
        poolsLocked  = true;
        emit DividendPoolsLocked(newAll, newSuper);
    }

    /* ---------------- Maps create ---------------- */
    function createMap(uint256 count, string[] calldata names) external onlyRole(ADMIN_ROLE) returns (address[] memory maps) {
        require(count > 0, "count=0");
        require(names.length == count, "names!=count");

        maps = new address[](count);
        for (uint256 i; i < count; ++i) {
            address map = Clones.clone(mapGridTemplate);
            IMapGrid(map).initialize(address(this), superNodeNFT, nodeNFT);
            isMap[map] = true;
            allMaps.push(map);
            mapNames[map] = names[i];
            maps[i] = map;
            emit MapCreated(msg.sender, map, names[i]);
        }
    }

    function setMapName(address map, string calldata newName) external onlyRole(ADMIN_ROLE) {
        require(isMap[map], "not map");
        string memory old = mapNames[map];
        mapNames[map] = newName;
        emit MapNameUpdated(map, old, newName);
    }

    function getAllMaps() external view returns (address[] memory) { return allMaps; }

    /* ---------------- Global uniqueness ---------------- */
    function _ensureUserFree(address user) internal view {
        if (userActive[user]) revert UserAlreadyActive();
    }
    function _bindUserToMap(address user, address map) internal {
        userToMap[user] = map; userActive[user] = true;
    }
    function _clearUser(address user) internal {
        userToMap[user] = address(0); userActive[user] = false;
        emit GlobalCleared(user);
    }

    /* ---------------- Claim / Replace ---------------- */
    function claim(address map, address nft, uint256 tokenId, int32 x, int32 y) external {
        if (!isMap[map]) revert NotRegisteredMap();
        if (nft != superNodeNFT && nft != nodeNFT) revert NFTNotAllowed();
        _ensureUserFree(msg.sender);

        IERC721(nft).safeTransferFrom(msg.sender, map, tokenId);
        IMapGrid(map).acceptClaim(msg.sender, nft, tokenId, x, y);

        _bindUserToMap(msg.sender, map);
        emit ClaimedThroughFactory(msg.sender, map, nft, tokenId, x, y);
    }

    function replaceHolder(address map, address nft, uint256 tokenId, int32 x, int32 y) external payable {
        if (!isMap[map]) revert NotRegisteredMap();
        if (nft != superNodeNFT && nft != nodeNFT) revert NFTNotAllowed();
        _ensureUserFree(msg.sender);
        if (msg.value != replaceBurnAmount) revert IncorrectMsgValue();

        IERC721(nft).safeTransferFrom(msg.sender, map, tokenId);
        (address oldUser, address oldNft, uint256 oldTokenId) =
            IMapGrid(map).acceptReplacement(msg.sender, nft, tokenId, x, y);

        _bindUserToMap(msg.sender, map);
        if (oldUser != address(0)) _clearUser(oldUser);

        if (msg.value > 0) payable(address(0)).sendValue(msg.value);
        emit ReplacedThroughFactory(msg.sender, map, nft, tokenId, x, y, oldUser, oldNft, oldTokenId, msg.value);
    }

    /* ---------------- Market path ---------------- */
    modifier onlyMarket() {
        require(msg.sender == market, "not market");
        _;
    }

    function marketLockPoint(address map, int32 x, int32 y, bool lock_) external onlyMarket {
        if (!isMap[map]) revert NotRegisteredMap();
        IMapGrid(map).marketLockPoint(x, y, lock_);
        emit MarketLocked(map, x, y, lock_);
    }

    function marketReplacePointOwner(address map, int32 x, int32 y, address newOwner)
        external onlyMarket
    {
        if (!isMap[map]) revert NotRegisteredMap();
        require(newOwner != address(0), "new=0");
        _ensureUserFree(newOwner);

        address oldOwner = IMapGrid(map).marketReplaceOwner(x, y, newOwner);

        if (oldOwner != address(0)) _clearUser(oldOwner);
        _bindUserToMap(newOwner, map);

        emit MarketOwnerReplaced(map, x, y, oldOwner, newOwner);
    }
}
