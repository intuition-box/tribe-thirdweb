// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IDEXRouterLib {
    function addLiquidity(address,address,uint,uint,uint,uint,address,uint) external returns(uint,uint,uint);
    function factory() external view returns(address);
}
interface IDEXFactoryLib {
    function getPair(address,address) external view returns(address);
    function createPair(address,address) external returns(address);
}
library DEXMigrationLib {
    function getOrCreatePair(address f,address t,address w) external returns(address p) {
        p=IDEXFactoryLib(f).getPair(t,w);
        if(p==address(0)){
            try IDEXFactoryLib(f).createPair(t,w) returns(address np){ if(np==address(0))revert("Zero"); p=np; }
            catch Error(string memory r){ revert(string(abi.encodePacked("Pair: ",r))); }
            catch{ revert("Pair failed"); }
        }
    }
    function addLiquidity(address r,address t,address w,uint256 tok,uint256 nat,uint256 minT,uint256 minW) external returns(uint256 liq) {
        try IDEXRouterLib(r).addLiquidity(t,w,tok,nat,minT,minW,address(this),block.timestamp+300) returns(uint256,uint256,uint256 l) {
            if(l==0)revert("Zero"); return l;
        } catch Error(string memory reason){ revert(string(abi.encodePacked("Router: ",reason))); }
        catch(bytes memory d){
            if(d.length>=68){ bytes4 sel=bytes4(0x08c379a0); bytes4 got; assembly{got:=mload(add(d,0x20))}
                if(got==sel){ (string memory m)=abi.decode(d,(string)); revert(string(abi.encodePacked("Router: ",m))); } }
            revert("AddLiq failed");
        }
    }
    function getLPToken(address f,address t,address w) external view returns(address){ address p=IDEXFactoryLib(f).getPair(t,w); if(p==address(0))revert("No pair"); return p; }
}
