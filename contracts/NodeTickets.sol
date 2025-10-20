// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Pausable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract NodeTickets is ERC721, ERC721Pausable, AccessControl {
    // 角色
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // BaseURI（单一）
    string private _baseTokenURI;

    // 自增 ID 与供应
    uint256 private _nextTokenId;
    uint256 public totalSupply;

    // 自定义错误
    error BurnDisabled();

    constructor(
        address initialAdmin,
        string memory name_,
        string memory symbol_,
        string memory baseURI_
    ) ERC721(name_, symbol_) {
        require(initialAdmin != address(0), "zero admin");

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);

        _baseTokenURI = baseURI_;
        _nextTokenId = 1;
    }

    // --- 管理 ---
    function setBaseURI(string calldata baseURI_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _baseTokenURI = baseURI_;
    }

    function pause()   external onlyRole(PAUSER_ROLE) { _pause();   }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

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

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Pausable)
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
