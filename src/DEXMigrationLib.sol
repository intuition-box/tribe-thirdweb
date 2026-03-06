// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Library for DEX addLiquidity step (factory + pair + addLiquidity). Caller must hold WETH and token and have approved router.
interface IDEXRouterLib {
    function addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256) external returns (uint256,uint256,uint256);
    function factory() external view returns (address);
}
interface IDEXFactoryLib {
    function getPair(address,address) external view returns (address);
    function createPair(address,address) external returns (address);
}

library DEXMigrationLib {
    /// @param router DEX router
    /// @param token Token address
    /// @param weth WETH address
    /// @param tokAmt Token amount for liquidity
    /// @param natAmt WETH amount (caller must have approved router and hold WETH)
    /// @return pair LP pair address
    /// @return liq LP tokens minted (sent to address(this); use via delegatecall so caller receives LPs)
    function addLiquidity(
        address router,
        address token,
        address weth,
        uint256 tokAmt,
        uint256 natAmt
    ) external returns (address pair, uint256 liq) {
        address f = IDEXRouterLib(router).factory();
        if (f == address(0)) revert();
        pair = IDEXFactoryLib(f).getPair(token, weth);
        if (pair == address(0)) {
            try IDEXFactoryLib(f).createPair(token, weth) returns (address p) {
                if (p == address(0)) revert();
                pair = p;
            } catch { revert(); }
        }
        uint256 minT = (tokAmt * 99) / 100;
        uint256 minW = (natAmt * 99) / 100;
        if (minT == 0 || minW == 0) revert();
        try IDEXRouterLib(router).addLiquidity(token, weth, tokAmt, natAmt, minT, minW, address(this), block.timestamp + 300)
            returns (uint256, uint256, uint256 l) {
            if (l == 0) revert();
            liq = l;
        } catch { revert(); }
    }
}
