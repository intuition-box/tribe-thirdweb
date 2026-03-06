// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Deploy MemeLaunchpad with TREASURY and DEX_ROUTER from environment.
//
// Option 1 - Use .env (recommended):
//   make deploy-foundry
//   or: ./scripts/run-deploy-foundry.sh
//
// Option 2 - Export then run:
//   source .env   # or: export TREASURY=0x... DEX_ROUTER=0x...
//   forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
//
// Option 3 - Inline env (no .env):
//   TREASURY=0x... DEX_ROUTER=0x... forge script script/Deploy.s.sol:Deploy --rpc-url <RPC> --private-key <KEY> --broadcast

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/MemeLaunchpad.sol";
import "../src/DEXMigrationLib.sol";

contract Deploy is Script {
    function run() external returns (MemeLaunchpad launchpad) {
        address treasury = vm.envAddress("TREASURY");
        address dexRouter = vm.envAddress("DEX_ROUTER");

        vm.startBroadcast();
        address lib = deployCode("src/DEXMigrationLib.sol:DEXMigrationLib");
        launchpad = new MemeLaunchpad(treasury, dexRouter, lib);
        vm.stopBroadcast();

        console.log("DEXMigrationLib at:", lib);
        console.log("MemeLaunchpad deployed at:", address(launchpad));
        console.log("  treasury:  ", treasury);
        console.log("  dexRouter:", dexRouter);
    }
}
