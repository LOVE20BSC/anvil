// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {Vm} from "@forge-std/Vm.sol";

// Imported only so their bytecode is compiled into this project's out/ directory: the deployment
// below uses the raw creation code (vm.getCode) rather than `new`, and forge only emits an artifact
// for a contract that some source unit actually references.
import {GroupActionJoin} from "action/src/GroupActionJoin.sol";
import {GroupActionManager} from "action/src/GroupActionManager.sol";
import {GroupActionVerify} from "action/src/GroupActionVerify.sol";
import {GroupRecipients} from "action/src/GroupRecipients.sol";

/// @title DeployLibraries
/// @notice Deploys the four EXTERNAL linked libraries that GroupActionExecutor and
///         GroupServiceExecutor delegatecall into.
///
/// Why this is a separate script and a separate broadcast:
///
/// `GroupActionExecutor` has three unresolved link placeholders (GroupActionJoin, GroupActionManager,
/// GroupActionVerify) and `GroupServiceExecutor` has one (GroupRecipients). Solidity substitutes those
/// placeholders at COMPILE time, so the addresses must be known before DeployLocal.s.sol is compiled.
/// Solidity cannot be compiled and run in the same forge invocation, therefore:
///
///   1. `script/local.sh` runs this script first and reads the four addresses from
///      export/libraries.json (also printed here and recorded in the broadcast JSON);
///   2. it passes them back as `forge script --libraries "<source unit>:<lib>:<address>,..."` when
///      it runs DeployLocal.s.sol, which recompiles with the placeholders filled.
///
/// Deploying them ourselves (instead of letting forge auto-deploy the link targets during the main
/// broadcast) is what makes the addresses part of the exported address book and lets `make verify`
/// check code at them: forge's implicit link-target deployment does not show up in the script's
/// broadcast JSON, so a frontend could never learn those addresses.
///
/// Nonce/order: this run consumes four ordinary CREATE nonces of the deploy account before the main
/// deployment. That is safe: DeployCore._predictAddresses() reads the nonce live at deploy time
/// (vm.getNonce inside the broadcast) and only depends on the *relative* order Phase -> Launch ->
/// MemberNFT -> Stake -> Submit -> Vote -> Mint, which this script does not touch. Nothing is created
/// between the four libraries and Phase, so the +2/+5/+6 predictions still hold - and if they did
/// not, DeployCore's own `require` would revert before any core contract was broadcast.
contract DeployLibraries is Script {
    struct LibraryDeployment {
        string name;
        address deployed;
    }

    /// @dev Artifact identifiers as accepted by vm.getCode: "<File>.sol:<Contract>". The source unit
        ///      name in the link references is resolved by script/export.py, not hardcoded here.
    function runLibraries() external returns (LibraryDeployment[] memory libraries) {
        string[4] memory artifactNames = [
            "GroupActionJoin.sol:GroupActionJoin",
            "GroupActionManager.sol:GroupActionManager",
            "GroupActionVerify.sol:GroupActionVerify",
            "GroupRecipients.sol:GroupRecipients"
        ];
        string[4] memory names = ["GroupActionJoin", "GroupActionManager", "GroupActionVerify", "GroupRecipients"];

        libraries = new LibraryDeployment[](4);

        vm.startBroadcast();
        for (uint256 i = 0; i < 4; i++) {
            bytes memory creationCode = vm.getCode(artifactNames[i]);
            require(creationCode.length != 0, string.concat("missing artifact for ", names[i]));
            address deployed = _create(creationCode);
            require(deployed.code.length != 0, string.concat("library deployment failed: ", names[i]));
            libraries[i] = LibraryDeployment({name: names[i], deployed: deployed});
            console2.log(names[i], deployed);
        }
        vm.stopBroadcast();

        _writeLibraries(libraries);
    }

    function _create(bytes memory code) internal returns (address addr) {
        assembly {
            addr := create(0, add(code, 0x20), mload(code))
        }
    }

    /// @dev Flat {name: address} JSON, consumed by script/local.sh (--libraries) and merged into
    ///      export/deployments/anvil31337_dev.json by script/export.py.
    function _writeLibraries(LibraryDeployment[] memory libraries) internal {
        string memory out = "libraries";
        for (uint256 i = 0; i < libraries.length; i++) {
            vm.serializeAddress(out, libraries[i].name, libraries[i].deployed);
        }
        string memory json = vm.serializeUint(out, "chainId", block.chainid);
        vm.writeFile(vm.envString("LIBRARIES_JSON_FILE"), json);
    }
}
