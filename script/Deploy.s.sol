// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Leash} from "../src/Leash.sol";

/// forge script script/Deploy.s.sol --rpc-url arc --broadcast --interactives 1
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        Leash leash = new Leash();
        vm.stopBroadcast();
        console.log("Leash deployed at", address(leash));
    }
}
