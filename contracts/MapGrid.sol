// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable}   from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC721}         from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address}         from "@openzeppelin/contracts/utils/Address.sol";
import {PRBMathSD59x18}  from "prb-math/contracts/PRBMathSD59x18.sol";

/* -------- Factory view for params & pools -------- */
interface IFactoryView {
    function powerA() external view returns (uint256);
    function powerB() external view returns (int256);
    function isMap(address) external view returns (bool);
    function dividendAll() external view returns (address);
    function dividendSuper() external view returns (address);
}

/* -------- Dividend pool interfaces (map-only) -------- */
interface IDivAll {
    function stakeFromMap(address user, uint256 amount) external;
    function withdrawFromMap(address user, uint256 amount) external;
    function harvestFromMap(address user) external;
    function fullReplaceFromMap(address oldUser, address newUser, uint256 newUserStake) external;
    // 新增：仅迁移台账（不触发分红）
    function transferOwnerFromMap(address oldUser, address newUser) external;
}
interface IDivSuperOnly {
    function stakeFromMap(address user, uint256 amount) external;
    function withdrawFromMap(address user, uint256 amount) external;
    function harvestFromMap(address user) external;
    function fullReplaceFromMap(address oldUser, address newUser, uint256 newUserStake) external;
    // 新增：仅迁移台账（不触发分红）
    function transferOwnerFromMap(address oldUser, address newUser) external;
}

contract MapGrid is Initializable, IERC721Receiver, ReentrancyGuard {
    using Address for address payable;

    uint256 public constant LOCK_SECONDS = 500 days;
    uint256 public constant LOCK_TWO_SECONDS = 3 days;
    int256  public constant ONE_18 = 1e18;

    address public factory;
    address public superNodeNFT;
    address public nodeNFT;

    struct PointClaim {
        // identity
        address owner;
        address nft;
        uint256 tokenId;
        // geometry
        int32   x;
        int32   y;
        bool    isSuper;
        // economics
        int256  power;        // 1e18
        uint256 nativeStake;  // wei
        int256  totalPower;   // 1e18（负值=0后用于分红）
        // div-sync snapshots（已同步到分红池的“虚拟份额”）
        uint256 lastStakedAll;
        uint256 lastStakedSuper;
        // lifecycle
        uint64  startTime;
        bool    exists;
        bool    locked;       // 市场上架时锁定
        // upgrade state
        uint32  coef;
        uint32  progress;
    }

    struct StakeRecord {
        uint256 timestamp; // 记录时间
        uint256 amount;    // 记录金额（wei）
        bool    withdrawn; // 是否已提取
    }

    mapping(bytes32 => PointClaim) public pointByCoord;
    mapping(address => mapping(uint256 => bool)) public staked;
    mapping(address => bytes32) public userToCoord;

    mapping(bytes32 => StakeRecord[]) private _stakeRecords;

    event Initialized(address factory, address superNodeNFT, address nodeNFT);
    event Claimed(address user, address nft, uint256 tokenId, int32 x, int32 y, bool isSuper, int256 totalPower);
    event NativeDeposited(address user, int32 x, int32 y, uint256 i, uint256 amount, uint256 newBalance, int256 newTotalPower);
    event NativeWithdrawn(address user, int32 x, int32 y, uint256 i, uint256 amount, uint256 newBalance, int256 newTotalPower);
    event Replaced(address newUser, address nft, uint256 newTokenId, int32 x, int32 y,
                   address oldUser, address oldNft, uint256 oldTokenId, int256 newTotalPower);
    event OldNftReturnAttempt(address to, address nft, uint256 tokenId, bool success);

    // 市场路径事件
    event PointLockChanged(int32 x, int32 y, bool locked);
    event OwnerReplacedByMarket(int32 x, int32 y, address indexed oldOwner, address indexed newOwner);

    event ScanProgress(int32 x, int32 y, uint32 radius, uint32 checked, uint32 nextIndex, bool upgraded, bool hitUnclaimed, int32 hitX, int32 hitY);

    error OnlyFactory();
    error NFTNotAllowed();
    error OriginRequiresSuper();
    error NonOriginRequiresNode();
    error CoordAlreadyClaimed();
    error CoordNotClaimed();
    error NFTNotHere();
    error NFTAlreadyStaked();
    error UserAlreadyHasPointInThisMap();
    error NotOwner();
    error Locked();
    error PointLocked();
    error NativeStakeNotZero();
    error AmountInvalid();
    error MustUseSameNFTAddress();

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory(); _;
    }

    constructor() { _disableInitializers(); }

    function initialize(address factory_, address superNodeNFT_, address nodeNFT_) external initializer {
        require(factory_ != address(0) && superNodeNFT_ != address(0) && nodeNFT_ != address(0), "zero");
        factory      = factory_;
        superNodeNFT = superNodeNFT_;
        nodeNFT      = nodeNFT_;
        emit Initialized(factory_, superNodeNFT_, nodeNFT_);
    }

    /* ---------------- utils ---------------- */
    function _coordKey(int32 x, int32 y) internal pure returns (bytes32) { return keccak256(abi.encodePacked(x, y)); }
    function _checkNFTCoordRule(address nft, int32 x, int32 y) internal view {
        bool atOrigin = (x == 0 && y == 0);
        if (atOrigin) { if (nft != superNodeNFT) revert OriginRequiresSuper(); }
        else { if (nft != nodeNFT) revert NonOriginRequiresNode(); }
    }

    function _getAB() internal view returns (uint256 A, int256 B) {
        A = IFactoryView(factory).powerA();
        B = IFactoryView(factory).powerB();
    }

    /// 总算力：(coef+1)*(power + log2(nativeStake/A)) + B；nativeStake==0 => log2项=0
    function _recalcTotalPower(PointClaim storage p) internal view returns (int256) {
        (uint256 A, int256 B) = _getAB();
        int256 logTerm = 0;
        if (p.nativeStake > 0) {
            int256 ratio = int256((p.nativeStake * 1e18) / A);
            if (ratio > 0) logTerm = PRBMathSD59x18.log2(ratio);
        }
        int256 inner = p.power + logTerm;
        int256 coefPlus = int256(uint256(p.coef) + 1);
        return inner * coefPlus + B;
    }

    /* ---- diamond ---- */
    function ringLen(uint32 r) public pure returns (uint32) { require(r>=1,"r>=1"); return 4*r; }
    function diamondIndexCoord(int32 x0,int32 y0,uint32 r,uint32 idx) public pure returns(int32 xi,int32 yi){
        require(r>=1,"r>=1"); uint32 per=4*r; idx%=per;
        int64 X=int64(x0); int64 Y=int64(y0); int64 R=int64(uint64(r));
        if(idx<r){int64 k=int64(uint64(idx)); xi=int32(X+(R-k)); yi=int32(Y-k);}
        else if(idx<2*r){int64 k=int64(uint64(idx-r)); xi=int32(X-k); yi=int32(Y-R+k);}
        else if(idx<3*r){int64 k=int64(uint64(idx-2*r)); xi=int32(X-R+k); yi=int32(Y+k);}
        else{int64 k=int64(uint64(idx-3*r)); xi=int32(X+k); yi=int32(Y+R-k);}
    }
    function isClaimedCoord(int32 x,int32 y) public view returns(bool){ return pointByCoord[_coordKey(x,y)].exists; }

    /* ---- dividend helpers ---- */
    function _poolAll()   internal view returns (address){ return IFactoryView(factory).dividendAll(); }
    function _poolSuper() internal view returns (address){ return IFactoryView(factory).dividendSuper(); }
    function _stakeAmt(int256 tp) internal pure returns (uint256){ return tp>0 ? uint256(tp) : 0; }

    function _syncPoolsOnNewTP(PointClaim storage p, int256 newTP) internal {
        uint256 newAmt = _stakeAmt(newTP);

        // ALL pool delta
        address allPool = _poolAll();
        if (allPool != address(0)) {
            if (newAmt > p.lastStakedAll) {
                uint256 addAmt = newAmt - p.lastStakedAll;
                IDivAll(allPool).stakeFromMap(p.owner, addAmt); // 失败必须回滚
                p.lastStakedAll = newAmt;
            } else if (newAmt < p.lastStakedAll) {
                uint256 subAmt = p.lastStakedAll - newAmt;
                IDivAll(allPool).withdrawFromMap(p.owner, subAmt); // 失败必须回滚
                p.lastStakedAll = newAmt;
            }
        } else {
            p.lastStakedAll = newAmt; // 无池也更新镜像
        }

        // SUPER pool delta（仅超级点位）
        address superPool = _poolSuper();
        if (p.isSuper && superPool != address(0)) {
            if (newAmt > p.lastStakedSuper) {
                uint256 addAmtS = newAmt - p.lastStakedSuper;
                IDivSuperOnly(superPool).stakeFromMap(p.owner, addAmtS); // 失败必须回滚
                p.lastStakedSuper = newAmt;
            } else if (newAmt < p.lastStakedSuper) {
                uint256 subAmtS = p.lastStakedSuper - newAmt;
                IDivSuperOnly(superPool).withdrawFromMap(p.owner, subAmtS); // 失败必须回滚
                p.lastStakedSuper = newAmt;
            }
        } else {
            p.lastStakedSuper = p.isSuper ? newAmt : 0;
        }
    }

    /* ============== Claim ============== */
    function acceptClaim(address staker, address nft, uint256 tokenId, int32 x, int32 y)
        external onlyFactory nonReentrant
    {
        require(staker!=address(0),"staker=0");
        if (nft!=superNodeNFT && nft!=nodeNFT) revert NFTNotAllowed();
        _checkNFTCoordRule(nft,x,y);

        bytes32 ck=_coordKey(x,y);
        if (pointByCoord[ck].exists) revert CoordAlreadyClaimed();
        if (IERC721(nft).ownerOf(tokenId)!=address(this)) revert NFTNotHere();
        if (staked[nft][tokenId]) revert NFTAlreadyStaked();
        if (userToCoord[staker]!=bytes32(0)) revert UserAlreadyHasPointInThisMap();

        PointClaim storage p = pointByCoord[ck];
        p.owner=staker; p.nft=nft; p.tokenId=tokenId;
        p.x=x; p.y=y; p.isSuper=(nft==superNodeNFT);
        p.power=ONE_18; p.nativeStake=0;
        p.coef=0; p.progress=0;
        p.startTime=uint64(block.timestamp); p.exists=true; p.locked=false;
        p.totalPower=_recalcTotalPower(p);
        p.lastStakedAll=0; p.lastStakedSuper=0;

        staked[nft][tokenId]=true; userToCoord[staker]=ck;
        emit Claimed(staker,nft,tokenId,x,y,p.isSuper,p.totalPower);

        _syncPoolsOnNewTP(p, p.totalPower);
    }

    /* ============== Replacement (token 替换) ============== */
    function acceptReplacement(address newStaker, address newNft, uint256 newTokenId, int32 x, int32 y)
        external onlyFactory nonReentrant
        returns (address oldOwner, address oldNft, uint256 oldTokenId)
    {
        require(newStaker!=address(0),"new=0");
        if (newNft!=superNodeNFT && newNft!=nodeNFT) revert NFTNotAllowed();

        bytes32 ck=_coordKey(x,y);
        PointClaim storage p = pointByCoord[ck];
        if (!p.exists) revert CoordNotClaimed();
        if (p.locked) revert PointLocked(); // 锁定中不允许 token 替换
        if (newNft!=p.nft) revert MustUseSameNFTAddress();
        _checkNFTCoordRule(newNft,x,y);

        if (block.timestamp < uint256(p.startTime) + LOCK_SECONDS + LOCK_TWO_SECONDS) revert Locked();

        if (p.nativeStake!=0) revert NativeStakeNotZero();
        if (IERC721(newNft).ownerOf(newTokenId)!=address(this)) revert NFTNotHere();
        if (staked[newNft][newTokenId]) revert NFTAlreadyStaked();
        if (userToCoord[newStaker]!=bytes32(0)) revert UserAlreadyHasPointInThisMap();

        // 分红侧：旧人全部解压并发放，新人准备份额（失败必须回滚）
        uint256 newAmt = _stakeAmt(_recalcTotalPower(p));
        address allPool = _poolAll();
        if (allPool != address(0)) { IDivAll(allPool).fullReplaceFromMap(p.owner,newStaker,newAmt); }
        address superPool = _poolSuper();
        if (p.isSuper && superPool != address(0)) { IDivSuperOnly(superPool).fullReplaceFromMap(p.owner,newStaker,newAmt); }

        // 退旧 NFT（必须成功，否则回滚）
        oldOwner=p.owner; oldNft=p.nft; oldTokenId=p.tokenId;
        if (oldOwner!=address(0)) userToCoord[oldOwner]=bytes32(0);
        if (oldNft!=address(0)) staked[oldNft][oldTokenId]=false;
        if (oldOwner!=address(0) && oldNft!=address(0)) {
            IERC721(oldNft).safeTransferFrom(address(this),oldOwner,oldTokenId);
            emit OldNftReturnAttempt(oldOwner,oldNft,oldTokenId,true);
        }

        // 替换 owner/tokenId/startTime/nativeStake，其余保留
        p.owner=newStaker; p.tokenId=newTokenId; p.startTime=uint64(block.timestamp); p.nativeStake=0;
        staked[newNft][newTokenId]=true; userToCoord[newStaker]=ck;

        // 重算 & 更新本地“已同步份额”镜像
        p.totalPower=_recalcTotalPower(p);
        p.lastStakedAll = newAmt;
        p.lastStakedSuper = p.isSuper ? newAmt : 0;

        emit Replaced(newStaker,newNft,newTokenId,x,y,oldOwner,oldNft,oldTokenId,p.totalPower);
        return (oldOwner,oldNft,oldTokenId);
    }

    /* ============== Native stake ============== */
    function depositNative(int32 x,int32 y,uint256 maxChecks) external payable nonReentrant {
        if (msg.value==0) revert AmountInvalid();
        bytes32 ck=_coordKey(x,y); PointClaim storage p=pointByCoord[ck];
        if (!p.exists) revert CoordNotClaimed();
        if (p.locked) revert PointLocked();
        if (p.owner!=msg.sender) revert NotOwner();

        _stakeRecords[ck].push(StakeRecord({
            timestamp: block.timestamp,
            amount: msg.value,
            withdrawn: false
        }));

        p.nativeStake += msg.value;
        p.totalPower=_recalcTotalPower(p);
        emit NativeDeposited(msg.sender, x, y, _stakeRecords[ck].length - 1, msg.value, p.nativeStake, p.totalPower);

        // 分红同步：失败必须回滚（内部已强制回滚）
        _syncPoolsOnNewTP(p, p.totalPower);

        if (maxChecks>0) { try this.queryUpgrade(x,y,maxChecks) {} catch {} }
    }

    /// @notice amount 参数改为“记录下标”；只能提取已到期（timestamp + LOCK_SECONDS）的记录；提取后按该记录金额解压
    function withdrawNative(int32 x,int32 y,uint256 index,uint256 maxChecks) external nonReentrant {
        bytes32 ck=_coordKey(x,y); PointClaim storage p=pointByCoord[ck];
        if (!p.exists) revert CoordNotClaimed();
        if (p.locked) revert PointLocked();
        if (p.owner!=msg.sender) revert NotOwner();

        require(index < _stakeRecords[ck].length, "bad index");
        StakeRecord storage rec = _stakeRecords[ck][index];
        require(!rec.withdrawn, "already withdrawn");
        require(block.timestamp >= rec.timestamp + LOCK_SECONDS, "locked record");

        uint256 amt = rec.amount;
        if (amt == 0) revert AmountInvalid();

        // 标记提取
        rec.withdrawn = true;

        // 本地余额与转账
        p.nativeStake -= amt;
        payable(msg.sender).sendValue(amt);

        p.totalPower=_recalcTotalPower(p);
        emit NativeWithdrawn(msg.sender,x,y,index,amt,p.nativeStake,p.totalPower);

        // 分红同步：失败必须回滚
        _syncPoolsOnNewTP(p, p.totalPower);

        if (maxChecks>0) { try this.queryUpgrade(x,y,maxChecks) {} catch {} }
    }

    /* ============== Upgrade scanning ============== */
    function queryUpgrade(int32 x,int32 y,uint256 maxChecks)
        external returns (bool upgraded,uint32 newCoef,bool hitUnclaimed,int32 hitX,int32 hitY,uint32 checked,uint32 radius,uint32 nextIndex)
    {
        bytes32 k=_coordKey(x,y); PointClaim storage p=pointByCoord[k];
        if (!p.exists) revert CoordNotClaimed();
        if (p.locked) revert PointLocked();

        radius=p.coef+1; uint32 total=ringLen(radius); uint32 idx=p.progress;
        uint32 budget=total; if (maxChecks>0 && maxChecks<total) budget=uint32(maxChecks);

        while(checked<budget && idx<total){
            (int32 cx,int32 cy)=diamondIndexCoord(p.x,p.y,radius,idx);
            if(!isClaimedCoord(cx,cy)){
                hitUnclaimed=true; hitX=cx; hitY=cy; p.progress=idx; checked+=1;
                emit ScanProgress(p.x,p.y,radius,checked,p.progress,false,true,hitX,hitY);
                newCoef=p.coef; nextIndex=p.progress;
                return (false,newCoef,true,hitX,hitY,checked,radius,nextIndex);
            }
            idx+=1; checked+=1;
        }

        if (idx>=total){
            p.coef+=1; p.progress=0; upgraded=true;
            newCoef=p.coef; nextIndex=0;
            emit ScanProgress(p.x,p.y,radius,checked,0,true,false,0,0);

            // 升级影响算力 -> 同步分红（失败必须回滚）
            p.totalPower=_recalcTotalPower(p);
            _syncPoolsOnNewTP(p, p.totalPower);
            return (true,newCoef,false,0,0,checked,radius,0);
        }

        p.progress=idx; newCoef=p.coef; nextIndex=p.progress;
        emit ScanProgress(p.x,p.y,radius,checked,nextIndex,false,false,0,0);
        return (false,newCoef,false,0,0,checked,radius,nextIndex);
    }

    /* ============== Harvest (Map 代用户领取) ============== */
    function harvestDividends(int32 x,int32 y,uint256 maxChecks) external nonReentrant {
        bytes32 ck=_coordKey(x,y); PointClaim storage p=pointByCoord[ck];
        require(p.exists, "no point");
        if (p.locked) revert PointLocked();
        require(p.owner==msg.sender, "not owner");

        address allPool = _poolAll();
        if (allPool != address(0)) { IDivAll(allPool).harvestFromMap(p.owner); } // 失败必须回滚
        address superPool = _poolSuper();
        if (p.isSuper && superPool != address(0)) { IDivSuperOnly(superPool).harvestFromMap(p.owner); } // 失败必须回滚

        if (maxChecks>0) { try this.queryUpgrade(x,y,maxChecks) {} catch {} }
    }

    /* ============== Market path ============== */

    /// @notice 市场上/下架时锁定或解锁点位
    function marketLockPoint(int32 x, int32 y, bool lock_) external onlyFactory {
        bytes32 ck=_coordKey(x,y); PointClaim storage p=pointByCoord[ck];
        if (!p.exists) revert CoordNotClaimed();
        p.locked = lock_;
        emit PointLockChanged(x, y, lock_);
    }

    /// @notice 仅替换点位 owner（不更改其他字段），并解锁；同时迁移分红池台账（不触发分红）
    function marketReplaceOwner(int32 x, int32 y, address newOwner)
        external onlyFactory nonReentrant
        returns (address oldOwner)
    {
        require(newOwner != address(0), "new=0");
        bytes32 ck=_coordKey(x,y); PointClaim storage p=pointByCoord[ck];
        if (!p.exists) revert CoordNotClaimed();
        if (!p.locked) revert PointLocked(); // 仅允许在锁定期间替换

        oldOwner = p.owner;

        // Map 内部 owner 索引迁移
        if (oldOwner != address(0)) userToCoord[oldOwner]=bytes32(0);
        userToCoord[newOwner]=ck;

        // 分红池台账迁移（不触发分红，不改 totalStaked）——失败必须回滚
        address allPool = _poolAll();
        if (allPool != address(0)) { IDivAll(allPool).transferOwnerFromMap(oldOwner, newOwner); }
        address superPool = _poolSuper();
        if (p.isSuper && superPool != address(0)) { IDivSuperOnly(superPool).transferOwnerFromMap(oldOwner, newOwner); }

        // 写 owner 并解锁；其余字段不动（tokenId/nativeStake/coef/progress/lastStaked* 等）
        p.owner = newOwner;
        p.locked = false;

        emit OwnerReplacedByMarket(x, y, oldOwner, newOwner);
        return oldOwner;
    }

    /* ---- views & receiver ---- */
    function getPoint(int32 x,int32 y) external view returns (PointClaim memory pc){ pc=pointByCoord[_coordKey(x,y)]; }
    function getUserPoint(address user) external view returns(bool ok,int32 x,int32 y,PointClaim memory pc){
        bytes32 ck=userToCoord[user]; if(ck==bytes32(0)) return(false,0,0,pc); pc=pointByCoord[ck]; return(pc.exists,pc.x,pc.y,pc);
    }
    function getPointOwner(int32 x, int32 y) external view returns (address) {
        return pointByCoord[_coordKey(x,y)].owner;
    }
    function getPointNativeStake(int32 x, int32 y) external view returns (uint256) {
        return pointByCoord[_coordKey(x,y)].nativeStake;
    }
    function isPointLocked(int32 x, int32 y) external view returns (bool) {
        return pointByCoord[_coordKey(x,y)].locked;
    }

    function getStakeRecordCount(int32 x, int32 y) external view returns (uint256) {
        return _stakeRecords[_coordKey(x,y)].length;
    }

    function getStakeRecords(int32 x, int32 y, uint256 start, uint256 limit)
        external view returns (StakeRecord[] memory slice)
    {
        bytes32 ck=_coordKey(x,y);
        uint256 total = _stakeRecords[ck].length;
        if (start >= total) return new StakeRecord[](0);
        uint256 end = start + limit; if (end > total) end = total;
        uint256 size = end - start;
        slice = new StakeRecord[](size);
        for (uint256 i; i < size; i++) {
            slice[i] = _stakeRecords[ck][start + i];
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
    receive() external payable {}
}
