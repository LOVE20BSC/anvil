// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";

// ---------------------------------------------------------------------------------------------
// Sibling sources, compiled read-only through remappings.txt. Nothing here is copied or modified.
// ---------------------------------------------------------------------------------------------
// core: we inherit the ORG'S OWN deploy body so the deployment order and the pre-computed CREATE
// addresses are literally the ones DeployCore.s.sol uses (see _deployCore below).
import {DeployCore} from "core/script/deploy/DeployCore.s.sol";
import {ILOVE20Token} from "@core/interfaces/ILOVE20Token.sol";

// dex: WETH comes from the dex repo's own configurable WETH9 source.
import {WETH9Configurable} from "dex/script/WETH9Configurable.sol";

// action
import {ActionTarget} from "action/src/ActionTarget.sol";
import {LpExecutor} from "action/src/LpExecutor.sol";
import {GroupActionExecutor} from "action/src/GroupActionExecutor.sol";
import {GroupServiceExecutor} from "action/src/GroupServiceExecutor.sol";
import {IActionExecutor} from "@action/interfaces/IActionExecutor.sol";
import {IActionTarget} from "@action/interfaces/IActionTarget.sol";
import {IGroupActionExecutor} from "@action/interfaces/IGroupActionExecutor.sol";
import {IGroupServiceExecutor} from "@action/interfaces/IGroupServiceExecutor.sol";

// group-chat
import {GroupAdmin} from "group-chat/src/GroupAdmin.sol";
import {GroupChat} from "group-chat/src/GroupChat.sol";
import {GroupChatBanList} from "group-chat/src/GroupChatBanList.sol";
import {GroupMember} from "group-chat/src/GroupMember.sol";
import {AdminBanSource} from "group-chat/src/sources/ban/AdminBanSource.sol";
import {GovVotedBanSource} from "group-chat/src/sources/ban/GovVotedBanSource.sol";
import {GroupJoinScopeSource} from "group-chat/src/sources/scope/GroupJoinScopeSource.sol";
import {GroupMemberScope} from "group-chat/src/sources/scope/GroupMemberScope.sol";
import {TokenActionGovManager} from "group-chat/src/managers/TokenActionGovManager.sol";
import {TokenActionMainManager} from "group-chat/src/managers/TokenActionMainManager.sol";
import {TokenGovManager} from "group-chat/src/managers/TokenGovManager.sol";
import {TokenMainManager} from "group-chat/src/managers/TokenMainManager.sol";
import {IGroupAdmin} from "@group-chat/interfaces/IGroupAdmin.sol";
import {IGroupChat} from "@group-chat/interfaces/IGroupChat.sol";
import {IGroupChatBanList} from "@group-chat/interfaces/IGroupChatBanList.sol";
import {IGroupMember} from "@group-chat/interfaces/IGroupMember.sol";
import {IAdminBanSource} from "@group-chat/interfaces/sources/ban/IAdminBanSource.sol";
import {IGovVotedBanSource} from "@group-chat/interfaces/sources/ban/IGovVotedBanSource.sol";
import {IGroupJoinScopeSource} from "@group-chat/interfaces/sources/scope/IGroupJoinScopeSource.sol";
import {IGroupMemberScope} from "@group-chat/interfaces/sources/scope/IGroupMemberScope.sol";
import {ITokenActionScopeManagerBase} from "@group-chat/interfaces/managers/ITokenActionScopeManagerBase.sol";
import {ITokenScopeManagerBase} from "@group-chat/interfaces/managers/ITokenScopeManagerBase.sol";

// periphery: LOVE20Hub derives every dependency (router/factory/launch/memberNFT/wrapped native) from
// the Stake address it is constructed with; nothing else is passed in.
import {LOVE20Hub} from "periphery/src/LOVE20Hub.sol";

// tools: BatchTransfer is stateless and takes no constructor arguments.
import {BatchTransfer} from "tools/src/BatchTransfer.sol";

/// @dev Minimal views of the UniswapV2 contracts read from ../dex/build. The published interfaces
///      live under the dex repo's own uniswap-v2 remappings, which are not mounted here; the three
///      functions below are the whole surface this script needs.
interface IUniswapV2FactoryView {
    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);
    function getPair(address tokenA, address tokenB) external view returns (address);
}

interface IUniswapV2RouterView {
    function factory() external view returns (address);
    function WETH() external view returns (address);
}

/// @dev WETH9Configurable views used for the post-deploy binding checks.
interface IWETHView {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
}

/// @dev LOVE20Hub views used for the post-deploy binding checks. The hub's own interface declares
///      ROUTER_ADDRESS() as `IUniswapV2Router02`; every one of these getters is an ABI address or
///      uint256, so the minimal address-typed view decodes identically without pulling the hub's
///      interface (and its Uniswap interface chain) into this script.
interface ILOVE20HubView {
    function STAKE_ADDRESS() external view returns (address);
    function ROUTER_ADDRESS() external view returns (address);
    function PAIR_FACTORY_ADDRESS() external view returns (address);
    function LAUNCH_ADDRESS() external view returns (address);
    function MEMBER_NFT_ADDRESS() external view returns (address);
    function WRAPPED_NATIVE_ADDRESS() external view returns (address);
    function SWAP_FEE_FOR_LP_RATIO() external view returns (uint256);
    function SWAP_FEE_FOR_PROTOCOL_RATIO() external view returns (uint256);
}

/// @title DeployLocal
/// @notice One-shot deployment of the whole local protocol stack against a running anvil node.
///
/// Order (and why it is this order):
///
///   A. Multicall3            - published by script/local.sh BEFORE this script, from the upstream
///                              pre-signed transaction at its canonical address. It is independent
///                              of everything else; this script only asserts its code exists.
///   B. WETH                  - root parent token; Launch reads it from Router.WETH().
///   C. UniswapV2Factory      - feeToSetter = 0 (the org's protocol-fee lock).
///   D. UniswapV2Router02     - needs B and C.
///   E. core                  - Phase -> AirdropDistributor -> Launch(token) -> MemberNFT -> Stake
///                              -> Submit -> Vote -> Mint, exactly as DeployCore.s.sol. The
///                              distributor is deployed BY the core body (it is the genesis token's
///                              distributor and the LOVE20Token constructor mints the whole genesis
///                              supply to it), including its CREATE-address prediction for
///                              AirdropDistributor/Launch/MemberNFT/Vote/Mint (nonce +1/+2/+3/+6/+7).
///   F. action                - ActionTarget -> LpExecutor -> GroupActionExecutor -> GroupServiceExecutor.
///                              The two executors are linked against the four libraries deployed by
///                              DeployLibraries.s.sol (see that file for why it is a separate run).
///   G. group-chat            - GroupAdmin -> GroupChat -> ban/scope sources -> 4 managers.
///   H. periphery / tools     - BatchTransfer, then LOVE20Hub(Stake). APPENDED AS THE LAST CREATES
///                              of the run, on purpose: every address here is CREATE(deployer, nonce),
///                              so inserting them anywhere earlier would shift the nonce of every
///                              contract deployed after them and silently change the committed
///                              frontend address book. Keep new modules at this position.
///
/// Everything after A is broadcast from one account (params: DEPLOY_ACCOUNT_INDEX, anvil #0) in a
/// single `vm.startBroadcast()`, so the CREATE nonces are exactly the sequence above.
///
/// Reads only from env (script/local.sh loads params/anvil31337_dev/*.params and exports them) and,
/// for the airdrop root/totalShare, from the snapshot fixture so the contract and the proofs the
/// frontend is served cannot disagree.
contract DeployLocal is DeployCore {
    // ---- dex artifact integrity (identical to ../dex/script/deploy/DeployUniswapV2.s.sol) ----
    bytes32 internal constant PAIR_INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;
    bytes32 internal constant FACTORY_CREATION_HASH =
        0x8716c49c3c982e1d8b8beaab0a95d88cc5ec06681dded0f951fa1f3059c1e32a;
    bytes32 internal constant ROUTER_CREATION_HASH = 0xdcc6e896a61e7aa6adbaad7c377d2f14c32c7ded40e258ea079932d43678295b;

    // The .siblings/ symlink is the same directory as ../dex; it is used because foundry.toml declares
    // fs_permissions on this path (see remappings.txt for why the symlink exists at all).
    //
    // `make bootstrap PINNED=1` compiles a read-only snapshot of the dex commit in siblings.lock, and
    // that worktree has no build output (build/ is gitignored in ../dex). `make pin` therefore
    // hard-link copies it to .siblings-pinned/dex/build and script/local.sh exports
    // DEX_ARTIFACT_ROOT to point here; the creation-bytecode hashes asserted below are unchanged, so
    // a pin that does not match the artifacts still fails loudly. Unset == the live path, byte for
    // byte the same string as before, so the default mode is untouched.
    string internal constant DEFAULT_DEX_ARTIFACT_ROOT = ".siblings/dex/build";

    function _dexArtifact(string memory relativePath) internal view returns (string memory) {
        return string.concat(vm.envOr("DEX_ARTIFACT_ROOT", DEFAULT_DEX_ARTIFACT_ROOT), relativePath);
    }

    string internal constant FACTORY_ARTIFACT = "/core/UniswapV2Factory.sol/UniswapV2Factory.json";
    string internal constant ROUTER_ARTIFACT = "/periphery/UniswapV2Router02.sol/UniswapV2Router02.json";
    string internal constant PAIR_ARTIFACT = "/core/UniswapV2Pair.sol/UniswapV2Pair.json";

    // MAX_FEE_SETTLEMENT_RATIO (2.5e15) is inherited from DeployCore and enforced by its
    // _validateConfig, so it is not redeclared here.

    // ---------------------------------------------------------------------------------------
    // Everything the deployment produced. Mirrors the org's *_ADDRESS key names.
    // ---------------------------------------------------------------------------------------
    struct Deployed {
        address weth;
        address factory;
        address router;
        address multicall3;
        address airdropDistributor;
        address token;
        address phase;
        address launch;
        address memberNFT;
        address stake;
        address submit;
        address vote;
        address mint;
        address actionTarget;
        address lpExecutor;
        address groupActionExecutor;
        address groupServiceExecutor;
        address groupAdmin;
        address groupChat;
        address groupChatBanList;
        address adminBanSource;
        address govVotedBanSource;
        address groupMember;
        address groupMemberScope;
        address groupJoinScopeSource;
        address tokenMainManager;
        address tokenGovManager;
        address tokenActionGovManager;
        address tokenActionMainManager;
        address pair;
        // Appended after the whole protocol stack (see the Order note in the contract doc): these two
        // are the last CREATEs of the run, which is what keeps every address above them unchanged.
        address batchTransfer;
        address hub;
    }

    struct Params {
        uint256 chainId;
        address multicall3;
        string wethName;
        string wethSymbol;
        address feeToSetter;
        address deployer;
        // genesis airdrop: contract configuration (core.params) + the snapshot it must agree with
        bytes32 genesisMerkleRoot;
        uint256 genesisClaimDelayRounds;
        uint256 totalShare;
        // action / group-chat
        uint256[] splits;
        uint256 actionRecentRounds;
        uint256 maxAdminIds;
        uint256 minSupportToOpposeMultiplier;
        uint256 banThresholdRatio;
        address beforePostPlugin;
        address afterPostPlugin;
    }

    /// ---------------------------------------------------------------------------------------
    /// Entry point. Deliberately not named `run()`: DeployCore declares a non-virtual `run()`.
    /// ---------------------------------------------------------------------------------------
    function runLocal() external returns (Deployed memory deployed) {
        Params memory params = _loadParams();
        // Only the parameters that do not depend on a deployment can be checked before broadcasting:
        // a wrong chain id, a missing Multicall3, an empty split list or a mismatched airdrop
        // snapshot must not cost a transaction. Everything that needs a deployed address (factory,
        // router) is validated as soon as that address exists - still before the contract that
        // consumes it is created.
        require(block.chainid == params.chainId, "Chain ID mismatch");
        require(params.deployer != address(0), "Deployer is zero");
        require(params.multicall3.code.length != 0, "Multicall3 is missing - run script/local.sh multicall3 first");
        _validateSplits(params.splits);
        _validateGroupChatParams(params);

        DeployCore.CoreConfig memory coreConfig = _loadCoreConfig(params);

        vm.startBroadcast();

        // ---- B/C/D: WETH + UniswapV2 (see dex artifact notes above) ----
        deployed.weth = address(new WETH9Configurable(params.wethName, params.wethSymbol));
        require(deployed.weth.code.length != 0, "WETH deployment failed");
        console2.log("WETH              ", deployed.weth);

        deployed.factory =
            _deployArtifact(_dexArtifact(FACTORY_ARTIFACT), abi.encode(params.feeToSetter), FACTORY_CREATION_HASH);
        console2.log("UniswapV2Factory  ", deployed.factory);
        deployed.router = _deployArtifact(
            _dexArtifact(ROUTER_ARTIFACT), abi.encode(deployed.factory, deployed.weth), ROUTER_CREATION_HASH
        );
        console2.log("UniswapV2Router02 ", deployed.router);

        // ---- E: core, through the org's own deploy body ----
        // Every constructor argument of the core contracts now exists, so DeployCore's own
        // validation (chain id, all scalars, factory/router wiring, genesis airdrop config) runs
        // here - still before the first core contract is created. DeployCore also deploys the
        // AirdropDistributor itself (nonce +1) before Launch, exactly as its own script does.
        coreConfig.dexConfig.router = deployed.router;
        coreConfig.dexConfig.pairFactory = deployed.factory;
        _validateConfig(coreConfig);
        DeployCore.DeploymentAddresses memory core = _deployCore(coreConfig);
        deployed.token = core.token;
        deployed.airdropDistributor = core.airdropDistributor;
        deployed.phase = core.phase;
        deployed.launch = core.launch;
        deployed.memberNFT = core.memberNFT;
        deployed.stake = core.stake;
        deployed.submit = core.submit;
        deployed.vote = core.vote;
        deployed.mint = core.mint;

        // ---- G: action ----
        deployed.actionTarget = address(new ActionTarget(deployed.mint));
        console2.log("ActionTarget      ", deployed.actionTarget);
        deployed.lpExecutor = address(new LpExecutor(deployed.actionTarget));
        console2.log("LpExecutor        ", deployed.lpExecutor);
        deployed.groupActionExecutor = address(new GroupActionExecutor(deployed.actionTarget, params.splits));
        console2.log("GroupActionExec   ", deployed.groupActionExecutor);
        deployed.groupServiceExecutor = address(new GroupServiceExecutor(deployed.groupActionExecutor));
        console2.log("GroupServiceExec  ", deployed.groupServiceExecutor);

        // ---- H: group-chat ----
        deployed.groupAdmin = address(new GroupAdmin(deployed.memberNFT, params.maxAdminIds));
        console2.log("GroupAdmin        ", deployed.groupAdmin);
        deployed.groupChat = address(new GroupChat(deployed.groupAdmin, deployed.phase));
        console2.log("GroupChat         ", deployed.groupChat);
        deployed.groupChatBanList = address(new GroupChatBanList(deployed.groupAdmin));
        console2.log("GroupChatBanList  ", deployed.groupChatBanList);
        deployed.adminBanSource = address(new AdminBanSource(deployed.groupChatBanList));
        console2.log("AdminBanSource    ", deployed.adminBanSource);
        deployed.govVotedBanSource = address(
            new GovVotedBanSource(deployed.memberNFT, params.minSupportToOpposeMultiplier, params.banThresholdRatio)
        );
        console2.log("GovVotedBanSource ", deployed.govVotedBanSource);
        deployed.groupMember = address(new GroupMember(deployed.groupAdmin));
        console2.log("GroupMember       ", deployed.groupMember);
        deployed.groupMemberScope = address(new GroupMemberScope(deployed.groupMember));
        console2.log("GroupMemberScope  ", deployed.groupMemberScope);
        deployed.groupJoinScopeSource =
            address(new GroupJoinScopeSource(deployed.groupMember, deployed.groupActionExecutor));
        console2.log("GroupJoinScopeSrc ", deployed.groupJoinScopeSource);
        deployed.tokenMainManager = address(
            new TokenMainManager(
                deployed.groupChat,
                deployed.govVotedBanSource,
                params.beforePostPlugin,
                params.afterPostPlugin,
                deployed.actionTarget
            )
        );
        console2.log("TokenMainManager  ", deployed.tokenMainManager);
        deployed.tokenGovManager = address(
            new TokenGovManager(
                deployed.groupChat,
                deployed.govVotedBanSource,
                params.beforePostPlugin,
                params.afterPostPlugin,
                deployed.actionTarget
            )
        );
        console2.log("TokenGovManager   ", deployed.tokenGovManager);
        deployed.tokenActionGovManager = address(
            new TokenActionGovManager(
                deployed.groupChat,
                deployed.govVotedBanSource,
                params.beforePostPlugin,
                params.afterPostPlugin,
                deployed.actionTarget,
                params.actionRecentRounds
            )
        );
        console2.log("TokenActionGovMgr ", deployed.tokenActionGovManager);
        deployed.tokenActionMainManager = address(
            new TokenActionMainManager(
                deployed.groupChat,
                deployed.govVotedBanSource,
                params.beforePostPlugin,
                params.afterPostPlugin,
                deployed.actionTarget,
                params.actionRecentRounds
            )
        );
        console2.log("TokenActionMainMgr", deployed.tokenActionMainManager);

        // ---- H: periphery / tools (LAST on purpose - see the Order note above) ----
        // BatchTransfer has no constructor arguments and no dependency on the protocol; the Hub takes
        // only Stake and derives router/factory/launch/memberNFT/wrapped-native + the DEX fee profile
        // from it. Nothing downstream consumes either address, so appending them here cannot move an
        // existing address. Do not move this block above the group-chat deployment.
        deployed.batchTransfer = address(new BatchTransfer());
        console2.log("BatchTransfer     ", deployed.batchTransfer);
        deployed.hub = address(new LOVE20Hub(deployed.stake));
        console2.log("LOVE20Hub         ", deployed.hub);

        vm.stopBroadcast();

        // ---- post-deploy validation (state already on chain) ----
        deployed.multicall3 = params.multicall3;
        deployed.pair = _validateDex(deployed, params);
        _validateCore(coreConfig, deployed);
        _validateAction(deployed, params);
        _validateGroupChat(deployed, params);
        _validatePeriphery(deployed);

        _writeAddresses(deployed, params);
        _logSummary(deployed);
    }

    /// ---------------------------------------------------------------------------------------
    /// Params
    /// ---------------------------------------------------------------------------------------
    function _loadParams() internal view returns (Params memory params) {
        params.chainId = vm.envUint("CHAIN_ID");
        params.multicall3 = vm.envAddress("MULTICALL3_ADDRESS");
        params.wethName = vm.envString("WETH_NAME");
        params.wethSymbol = vm.envString("WETH_SYMBOL");
        params.feeToSetter = vm.envAddress("FACTORY_FEE_TO_SETTER");
        params.deployer = vm.envAddress("DEPLOYER_ADDRESS");

        // AirdropDistributor configuration, passed straight through to DeployCore.CoreConfig.
        params.genesisMerkleRoot = vm.envBytes32("GENESIS_AIRDROP_MERKLE_ROOT");
        params.genesisClaimDelayRounds = vm.envUint("GENESIS_AIRDROP_CLAIM_DELAY_ROUNDS");
        params.totalShare = vm.envUint("TOTAL_SHARE");

        string memory snapshot = vm.readFile(vm.envString("AIRDROP_SNAPSHOT_FILE"));
        // The fixture stores numbers as decimal strings (canonical burn snapshot format), so they are
        // read as strings and parsed: JSON numbers would lose precision in a JS consumer.
        bytes32 snapshotMerkleRoot = vm.parseBytes32(vm.parseJsonString(snapshot, ".merkleRoot"));
        uint256 snapshotTotalShare = vm.parseUint(vm.parseJsonString(snapshot, ".totalShare"));
        require(params.genesisMerkleRoot != bytes32(0), "GENESIS_AIRDROP_MERKLE_ROOT is zero");
        // One root feeds the contract AND the proofs SeedFlow/frontend use: if the params file and
        // the snapshot disagree, every claim reverts InvalidProof. Fail before broadcasting instead.
        require(
            snapshotMerkleRoot == params.genesisMerkleRoot,
            "GENESIS_AIRDROP_MERKLE_ROOT disagrees with the snapshot fixture"
        );
        require(snapshotTotalShare == params.totalShare, "TOTAL_SHARE disagrees with the snapshot");
        // AirdropDistributor.TOTAL_SHARE is a compile-time constant (1e18); the fixture must match it.
        require(params.totalShare == 1e18, "TOTAL_SHARE must equal AirdropDistributor.TOTAL_SHARE (1e18)");

        params.splits = _envUintArray("GROUP_ACTION_SPLITS");
        params.actionRecentRounds = vm.envUint("GROUP_CHAT_ACTION_RECENT_ROUNDS");
        params.maxAdminIds = vm.envUint("GROUP_CHAT_MAX_ADMIN_IDS");
        params.minSupportToOpposeMultiplier = vm.envUint("GROUP_CHAT_MIN_SUPPORT_TO_OPPOSE_MULTIPLIER");
        params.banThresholdRatio = vm.envUint("GROUP_CHAT_BAN_THRESHOLD_RATIO");
        params.beforePostPlugin = vm.envAddress("GROUP_CHAT_BEFORE_POST_PLUGIN_ADDRESS");
        params.afterPostPlugin = vm.envAddress("GROUP_CHAT_AFTER_POST_PLUGIN_ADDRESS");
    }

    /// @dev Comma-separated decimal list (script/lib/params.sh has already expanded 1e17 -> 1e17's
    ///      decimal form). An empty value yields an empty array, which the action repo allows.
    function _envUintArray(string memory key) internal view returns (uint256[] memory values) {
        string memory raw = vm.envString(key);
        bytes memory rawBytes = bytes(raw);
        if (rawBytes.length == 0) return new uint256[](0);

        uint256 count = 1;
        for (uint256 i = 0; i < rawBytes.length; i++) {
            if (rawBytes[i] == ",") count++;
        }
        values = new uint256[](count);
        bytes memory item = new bytes(rawBytes.length);
        uint256 itemLength = 0;
        uint256 index = 0;
        for (uint256 i = 0; i <= rawBytes.length; i++) {
            if (i == rawBytes.length || rawBytes[i] == ",") {
                bytes memory slice = new bytes(itemLength);
                for (uint256 j = 0; j < itemLength; j++) {
                    slice[j] = item[j];
                }
                values[index] = vm.parseUint(string(slice));
                index++;
                itemLength = 0;
            } else {
                item[itemLength] = rawBytes[i];
                itemLength++;
            }
        }
        require(index == count, "split parsing failed");
    }

    function _loadCoreConfig(Params memory params) internal view returns (DeployCore.CoreConfig memory config) {
        config.chainId = params.chainId;
        // Filled in from the deployment itself: these two addresses do not exist yet when the
        // scalar parameters are read, and reading them from a params file would be exactly the
        // stale-address trap the org's committed address files keep falling into. The genesis
        // airdrop values do come from params (they are not deployment-derived).
        config.dexConfig.router = address(0);
        config.dexConfig.pairFactory = address(0);
        config.genesisMerkleRoot = params.genesisMerkleRoot;
        config.genesisClaimDelayRounds = params.genesisClaimDelayRounds;
        config.tokenName = vm.envString("TOKEN_NAME");
        config.tokenSymbol = vm.envString("TOKEN_SYMBOL");
        config.memberBaseDivisor = vm.envUint("MEMBER_BASE_DIVISOR");
        config.memberBytesThreshold = vm.envUint("MEMBER_BYTES_THRESHOLD");
        config.memberMultiplier = vm.envUint("MEMBER_MULTIPLIER");
        config.memberMaxNameLength = vm.envUint("MEMBER_MAX_NAME_LENGTH");
        config.phaseOriginBlocks = vm.envUint("PHASE_ORIGIN_BLOCKS");
        config.phaseOriginPhaseBlocks = vm.envUint("PHASE_ORIGIN_PHASE_BLOCKS");
        config.phaseTargetSeconds = vm.envUint("PHASE_TARGET_SECONDS");
        config.phaseAdjustThreshold = vm.envUint("PHASE_ADJUST_THRESHOLD");
        config.phaseSyncObservationLimit = vm.envUint("PHASE_SYNC_OBSERVATION_LIMIT");
        config.launchCountThresholdRatio = vm.envUint("LAUNCH_COUNT_THRESHOLD_RATIO");
        config.maxLaunchCount = vm.envUint("MAX_LAUNCH_COUNT");
        config.tokenSymbolLength = vm.envUint("TOKEN_SYMBOL_LENGTH");
        config.launchAmount = vm.envUint("LAUNCH_AMOUNT");
        config.maxSupply = vm.envUint("MAX_SUPPLY");
        config.proposalRewardMinVoteRatio = vm.envUint("PROPOSAL_REWARD_MIN_VOTE_RATIO");
        config.roundRewardGovRatio = vm.envUint("ROUND_REWARD_GOV_RATIO");
        config.roundRewardProposalRatio = vm.envUint("ROUND_REWARD_PROPOSAL_RATIO");
        config.boostStakeSupplyFactor = vm.envUint("BOOST_STAKE_SUPPLY_FACTOR");
        config.boostStakeMultiplier = vm.envUint("BOOST_STAKE_MULTIPLIER");
        config.submitMinRatio = vm.envUint("SUBMIT_MIN_RATIO");
        config.promisedWaitingPhasesMin = vm.envUint("PROMISED_WAITING_PHASES_MIN");
        config.promisedWaitingPhasesMax = vm.envUint("PROMISED_WAITING_PHASES_MAX");
        config.feeSettlementRatio = vm.envUint("FEE_SETTLEMENT_RATIO");
        config.dexConfig.swapFeeForLpRatio = vm.envUint("SWAP_FEE_FOR_LP_RATIO");
        config.dexConfig.swapFeeForProtocolRatio = vm.envUint("SWAP_FEE_FOR_PROTOCOL_RATIO");
    }

    /// @dev Overrides DeployCore._predictor(). DeployCore predicts MemberNFT/Vote/Mint as
    ///      CREATE(deployer, nonce+2/+5/+6); the deployer is the broadcast account, which forge
    ///      reports as msg.sender inside the script anyway. Resolving it from an explicit env key
    ///      keeps the prediction correct even if a future forge version changes that, and the
    ///      requires inside DeployCore._deployContracts still fail loudly on any mismatch.
    function _predictor() internal view override returns (address) {
        return vm.envAddress("DEPLOYER_ADDRESS");
    }

    /// ---------------------------------------------------------------------------------------
    /// dex
    /// ---------------------------------------------------------------------------------------
    /// @dev Reads a published artifact's creation bytecode, appends the constructor arguments,
    ///      asserts the artifact is the exact code the dex repo pins, then CREATEs it.
    ///      `expectedCreationHash` is over the bare creation bytecode (no args), the same value
    ///      ../dex/script/deploy/DeployUniswapV2.s.sol asserts.
    function _deployArtifact(string memory artifactPath, bytes memory constructorArgs, bytes32 expectedCreationHash)
        internal
        returns (address deployed)
    {
        bytes memory creation = vm.parseBytes(vm.parseJsonString(vm.readFile(artifactPath), ".bytecode.object"));
        require(creation.length != 0, string.concat("empty bytecode in ", artifactPath));
        require(keccak256(creation) == expectedCreationHash, string.concat("artifact hash mismatch: ", artifactPath));

        bytes memory code = bytes.concat(creation, constructorArgs);
        assembly {
            deployed := create(0, add(code, 0x20), mload(code))
        }
        require(deployed != address(0), string.concat("CREATE failed for ", artifactPath));
        require(deployed.code.length != 0, string.concat("no code after CREATE for ", artifactPath));
    }

    function _validateDex(Deployed memory deployed, Params memory params) internal view returns (address pair) {
        // The pair's creation code is what Router02's PairCreated CREATE2 embeds; assert it too so a
        // stale ../dex/build cannot silently produce a factory whose pairs the Router cannot predict.
        bytes memory pairCreation =
            vm.parseBytes(vm.parseJsonString(vm.readFile(_dexArtifact(PAIR_ARTIFACT)), ".bytecode.object"));
        require(keccak256(pairCreation) == PAIR_INIT_CODE_HASH, "pair artifact hash mismatch");

        require(IUniswapV2RouterView(deployed.router).factory() == deployed.factory, "router.factory mismatch");
        require(IUniswapV2RouterView(deployed.router).WETH() == deployed.weth, "router.WETH mismatch");
        require(IUniswapV2FactoryView(deployed.factory).feeTo() == address(0), "feeTo must be zero");
        require(IUniswapV2FactoryView(deployed.factory).feeToSetter() == params.feeToSetter, "feeToSetter mismatch");
        require(IWETHView(deployed.weth).decimals() == 18, "WETH decimals must be 18");
        require(
            keccak256(bytes(IWETHView(deployed.weth).symbol())) == keccak256(bytes(params.wethSymbol)),
            "WETH symbol mismatch"
        );

        // Launch._ensurePair() created the root token's pair during the core deployment; it exists
        // with ZERO reserves. Seeding the reserves is script/SeedFlow.s.sol's job.
        pair = IUniswapV2FactoryView(deployed.factory).getPair(deployed.token, deployed.weth);
        require(pair != address(0), "root token pair was not created by Launch");
        require(pair.code.length != 0, "root token pair has no code");
    }

    /// ---------------------------------------------------------------------------------------
    /// core
    /// ---------------------------------------------------------------------------------------
    /// @dev Delegates to DeployCore._deployContracts, which is the org's own deployment body: same
    ///      order, same CREATE nonce predictions (MemberNFT = nonce+2, Vote = nonce+5, Mint = nonce+6),
    ///      same inline `require`s comparing the predictions with what was actually created.
    function _deployCore(DeployCore.CoreConfig memory config)
        internal
        returns (DeployCore.DeploymentAddresses memory addrs)
    {
        addrs = _deployContracts(config, IUniswapV2RouterView(config.dexConfig.router).WETH());
    }

    function _validateCore(DeployCore.CoreConfig memory config, Deployed memory deployed) internal view {
        // DeployCore's own end-to-end validation (every binding, token supply, distributor balance).
        DeployCore.DeploymentAddresses memory addrs = DeployCore.DeploymentAddresses({
            token: deployed.token,
            airdropDistributor: deployed.airdropDistributor,
            memberNFT: deployed.memberNFT,
            phase: deployed.phase,
            launch: deployed.launch,
            mint: deployed.mint,
            vote: deployed.vote,
            submit: deployed.submit,
            stake: deployed.stake
        });
        // DeployCore's own validation already covers the full graph, including the distributor's
        // launch/phase/merkle-root bindings and the genesis supply sitting on the distributor.
        _validateDeployment(config, deployed.weth, addrs);

        require(deployed.token.code.length != 0, "token has no code");
        require(
            ILOVE20Token(deployed.token).balanceOf(deployed.airdropDistributor) == config.launchAmount,
            "AirdropDistributor does not hold the genesis supply"
        );
    }

    /// ---------------------------------------------------------------------------------------
    /// action
    /// ---------------------------------------------------------------------------------------
    function _validateAction(Deployed memory deployed, Params memory params) internal view {
        IActionTarget actionTarget = IActionTarget(deployed.actionTarget);
        require(actionTarget.MINT_ADDRESS() == deployed.mint, "ActionTarget.MINT mismatch");
        require(actionTarget.VOTE_ADDRESS() == deployed.vote, "ActionTarget.VOTE mismatch");
        require(actionTarget.SUBMIT_ADDRESS() == deployed.submit, "ActionTarget.SUBMIT mismatch");
        require(actionTarget.MEMBER_NFT_ADDRESS() == deployed.memberNFT, "ActionTarget.MEMBER_NFT mismatch");
        require(actionTarget.PHASE_ADDRESS() == deployed.phase, "ActionTarget.PHASE mismatch");

        require(
            IActionExecutor(deployed.lpExecutor).ACTION_TARGET_ADDRESS() == deployed.actionTarget,
            "LpExecutor.ACTION_TARGET mismatch"
        );
        require(IActionExecutor(deployed.lpExecutor).STAKE_ADDRESS() == deployed.stake, "LpExecutor.STAKE mismatch");

        IGroupActionExecutor groupAction = IGroupActionExecutor(deployed.groupActionExecutor);
        require(
            IActionExecutor(deployed.groupActionExecutor).ACTION_TARGET_ADDRESS() == deployed.actionTarget,
            "GroupActionExecutor.ACTION_TARGET mismatch"
        );
        require(
            IActionExecutor(deployed.groupActionExecutor).STAKE_ADDRESS() == deployed.stake,
            "GroupActionExecutor.STAKE mismatch"
        );
        require(
            IActionExecutor(deployed.groupActionExecutor).MEMBER_NFT_ADDRESS() == deployed.memberNFT,
            "GroupActionExecutor.MEMBER_NFT mismatch"
        );
        require(
            IActionExecutor(deployed.groupActionExecutor).PHASE_ADDRESS() == deployed.phase,
            "GroupActionExecutor.PHASE mismatch"
        );
        uint256[] memory splits = groupAction.SPLITS();
        require(splits.length == params.splits.length, "GroupActionExecutor.SPLITS length mismatch");
        for (uint256 i = 0; i < splits.length; i++) {
            require(splits[i] == params.splits[i], "GroupActionExecutor.SPLITS value mismatch");
        }

        IGroupServiceExecutor groupService = IGroupServiceExecutor(deployed.groupServiceExecutor);
        require(
            IActionExecutor(deployed.groupServiceExecutor).ACTION_TARGET_ADDRESS() == deployed.actionTarget,
            "GroupServiceExecutor.ACTION_TARGET mismatch"
        );
        require(
            IActionExecutor(deployed.groupServiceExecutor).STAKE_ADDRESS() == deployed.stake,
            "GroupServiceExecutor.STAKE mismatch"
        );
        require(
            groupService.GROUP_ACTION_EXECUTOR_ADDRESS() == deployed.groupActionExecutor,
            "GroupServiceExecutor.GROUP_ACTION_EXECUTOR mismatch"
        );
    }

    /// ---------------------------------------------------------------------------------------
    /// group-chat
    /// ---------------------------------------------------------------------------------------
    function _validateGroupChat(Deployed memory deployed, Params memory params) internal view {
        require(IGroupAdmin(deployed.groupAdmin).GROUP_ADDRESS() == deployed.memberNFT, "GroupAdmin.GROUP mismatch");
        require(
            IGroupAdmin(deployed.groupAdmin).MAX_ADMIN_IDS() == params.maxAdminIds, "GroupAdmin.MAX_ADMIN_IDS mismatch"
        );
        require(
            IGroupChat(deployed.groupChat).GROUP_ADMIN_ADDRESS() == deployed.groupAdmin,
            "GroupChat.GROUP_ADMIN mismatch"
        );
        require(IGroupChat(deployed.groupChat).GROUP_ADDRESS() == deployed.memberNFT, "GroupChat.GROUP mismatch");
        require(IGroupChat(deployed.groupChat).PHASE_ADDRESS() == deployed.phase, "GroupChat.PHASE mismatch");
        require(
            IGroupChatBanList(deployed.groupChatBanList).GROUP_ADMIN_ADDRESS() == deployed.groupAdmin,
            "GroupChatBanList.GROUP_ADMIN mismatch"
        );
        require(
            IAdminBanSource(deployed.adminBanSource).GROUP_BAN_LIST_ADDRESS() == deployed.groupChatBanList,
            "AdminBanSource.GROUP_BAN_LIST mismatch"
        );
        require(
            IGovVotedBanSource(deployed.govVotedBanSource).GROUP_ADDRESS() == deployed.memberNFT,
            "GovVotedBanSource.GROUP mismatch"
        );
        require(
            IGovVotedBanSource(deployed.govVotedBanSource).MIN_SUPPORT_TO_OPPOSE_MULTIPLIER()
                == params.minSupportToOpposeMultiplier,
            "GovVotedBanSource.MIN_SUPPORT_TO_OPPOSE_MULTIPLIER mismatch"
        );
        require(
            IGovVotedBanSource(deployed.govVotedBanSource).BAN_THRESHOLD_RATIO() == params.banThresholdRatio,
            "GovVotedBanSource.BAN_THRESHOLD_RATIO mismatch"
        );
        require(
            IGroupMember(deployed.groupMember).GROUP_ADMIN_ADDRESS() == deployed.groupAdmin,
            "GroupMember.GROUP_ADMIN mismatch"
        );
        require(IGroupMember(deployed.groupMember).GROUP_ADDRESS() == deployed.memberNFT, "GroupMember.GROUP mismatch");
        require(
            IGroupMemberScope(deployed.groupMemberScope).GROUP_MEMBER_ADDRESS() == deployed.groupMember,
            "GroupMemberScope.GROUP_MEMBER mismatch"
        );
        require(
            IGroupJoinScopeSource(deployed.groupJoinScopeSource).GROUP_MEMBER_ADDRESS() == deployed.groupMember,
            "GroupJoinScopeSource.GROUP_MEMBER mismatch"
        );
        require(
            IGroupJoinScopeSource(deployed.groupJoinScopeSource).GROUP_ACTION_EXECUTOR_ADDRESS()
                == deployed.groupActionExecutor,
            "GroupJoinScopeSource.GROUP_ACTION_EXECUTOR mismatch"
        );

        _validateManager(deployed.tokenMainManager, deployed, params, false);
        _validateManager(deployed.tokenGovManager, deployed, params, false);
        _validateManager(deployed.tokenActionGovManager, deployed, params, true);
        _validateManager(deployed.tokenActionMainManager, deployed, params, true);
    }

    function _validateManager(address manager, Deployed memory deployed, Params memory params, bool isAction)
        internal
        view
    {
        require(
            ITokenScopeManagerBase(manager).GROUP_CHAT_ADDRESS() == deployed.groupChat, "manager.GROUP_CHAT mismatch"
        );
        require(ITokenScopeManagerBase(manager).GROUP_ADDRESS() == deployed.memberNFT, "manager.GROUP mismatch");
        require(
            ITokenScopeManagerBase(manager).BAN_SOURCE_ADDRESS() == deployed.govVotedBanSource,
            "manager.BAN_SOURCE mismatch"
        );
        require(
            ITokenScopeManagerBase(manager).BEFORE_POST_PLUGIN_ADDRESS() == params.beforePostPlugin,
            "manager.BEFORE_POST_PLUGIN mismatch"
        );
        require(
            ITokenScopeManagerBase(manager).AFTER_POST_PLUGIN_ADDRESS() == params.afterPostPlugin,
            "manager.AFTER_POST_PLUGIN mismatch"
        );
        if (isAction) {
            require(
                ITokenActionScopeManagerBase(manager).RECENT_ROUNDS() == params.actionRecentRounds,
                "manager.RECENT_ROUNDS mismatch"
            );
        }
    }

    /// ---------------------------------------------------------------------------------------
    /// periphery / tools
    /// ---------------------------------------------------------------------------------------
    /// @dev The Hub injects exactly one dependency (Stake) and derives the rest; these checks read the
    ///      derived graph back from the deployed hub, so a wrong Stake cannot silently produce a hub
    ///      that quotes against another deployment's router/factory.
    function _validatePeriphery(Deployed memory deployed) internal view {
        require(deployed.batchTransfer.code.length != 0, "BatchTransfer has no code");
        require(deployed.hub.code.length != 0, "LOVE20Hub has no code");

        ILOVE20HubView hub = ILOVE20HubView(deployed.hub);
        require(hub.STAKE_ADDRESS() == deployed.stake, "LOVE20Hub.STAKE mismatch");
        require(hub.ROUTER_ADDRESS() == deployed.router, "LOVE20Hub.ROUTER mismatch");
        require(hub.PAIR_FACTORY_ADDRESS() == deployed.factory, "LOVE20Hub.PAIR_FACTORY mismatch");
        require(hub.LAUNCH_ADDRESS() == deployed.launch, "LOVE20Hub.LAUNCH mismatch");
        require(hub.MEMBER_NFT_ADDRESS() == deployed.memberNFT, "LOVE20Hub.MEMBER_NFT mismatch");
        require(hub.WRAPPED_NATIVE_ADDRESS() == deployed.weth, "LOVE20Hub.WRAPPED_NATIVE mismatch");
        // The hub copies the DEX fee profile from Stake at construction; assert it landed as a usable
        // profile rather than echoing a value that came from somewhere else.
        uint256 lpRatio = hub.SWAP_FEE_FOR_LP_RATIO();
        uint256 protocolRatio = hub.SWAP_FEE_FOR_PROTOCOL_RATIO();
        require(lpRatio != 0, "LOVE20Hub SWAP_FEE_FOR_LP_RATIO must be non-zero");
        require(lpRatio + protocolRatio < 1e18, "LOVE20Hub swap fee ratios must sum to less than 1e18");
    }

    /// ---------------------------------------------------------------------------------------
    /// local parameter validation
    /// ---------------------------------------------------------------------------------------
    /// @dev Mirrors the check inside ../action/script/deploy/DeployAction.s.sol: each split is in
    ///      (0, 1e18) and the list is strictly increasing. An empty list is legal (rank 1 only).
    function _validateSplits(uint256[] memory splits) internal pure {
        uint256 previous = 0;
        for (uint256 i = 0; i < splits.length; i++) {
            require(splits[i] != 0 && splits[i] < 1e18 && splits[i] > previous, "Invalid GroupAction splits");
            previous = splits[i];
        }
    }

    /// @dev Mirrors ../group-chat/script/deploy/DeployGroupChat.s.sol's _validateConfig, minus the
    ///      checks that need a deployed MemberNFT (MAX_NAME_LENGTH >= 11 is asserted by
    ///      _validateGroupChat after the core deployment).
    function _validateGroupChatParams(Params memory params) internal pure {
        require(params.actionRecentRounds != 0, "GROUP_CHAT_ACTION_RECENT_ROUNDS must be > 0");
        require(params.maxAdminIds != 0, "GROUP_CHAT_MAX_ADMIN_IDS must be > 0");
        require(params.minSupportToOpposeMultiplier != 0, "MIN_SUPPORT_TO_OPPOSE_MULTIPLIER must be > 0");
        require(params.banThresholdRatio <= 1e18, "GROUP_CHAT_BAN_THRESHOLD_RATIO must be <= 1e18");
    }

    /// ---------------------------------------------------------------------------------------
    /// address book
    /// ---------------------------------------------------------------------------------------
    /// @dev Flat {"<NAME>_ADDRESS": "0x..."} JSON, the same key convention as the org's params
    ///      files. script/export.py turns it into export/deployments/anvil31337_dev.json (contract
    ///      names + block numbers + chain id) and the frontend consumes that file.
    function _writeAddresses(Deployed memory deployed, Params memory params) internal {
        string memory out = "addresses";
        vm.serializeAddress(out, "WETH_ADDRESS", deployed.weth);
        vm.serializeAddress(out, "UNISWAP_V2_FACTORY_ADDRESS", deployed.factory);
        vm.serializeAddress(out, "UNISWAP_V2_ROUTER02_ADDRESS", deployed.router);
        vm.serializeAddress(out, "UNISWAP_V2_PAIR_ADDRESS", deployed.pair);
        vm.serializeAddress(out, "MULTICALL3_ADDRESS", deployed.multicall3);
        vm.serializeAddress(out, "AIRDROP_DISTRIBUTOR_ADDRESS", deployed.airdropDistributor);
        vm.serializeAddress(out, "LOVE20_TOKEN_ADDRESS", deployed.token);
        vm.serializeAddress(out, "PHASE_ADDRESS", deployed.phase);
        vm.serializeAddress(out, "LAUNCH_ADDRESS", deployed.launch);
        vm.serializeAddress(out, "MEMBER_NFT_ADDRESS", deployed.memberNFT);
        vm.serializeAddress(out, "STAKE_ADDRESS", deployed.stake);
        vm.serializeAddress(out, "SUBMIT_ADDRESS", deployed.submit);
        vm.serializeAddress(out, "VOTE_ADDRESS", deployed.vote);
        vm.serializeAddress(out, "MINT_ADDRESS", deployed.mint);
        vm.serializeAddress(out, "ACTION_TARGET_ADDRESS", deployed.actionTarget);
        vm.serializeAddress(out, "LP_EXECUTOR_ADDRESS", deployed.lpExecutor);
        vm.serializeAddress(out, "GROUP_ACTION_EXECUTOR_ADDRESS", deployed.groupActionExecutor);
        vm.serializeAddress(out, "GROUP_SERVICE_EXECUTOR_ADDRESS", deployed.groupServiceExecutor);
        vm.serializeAddress(out, "GROUP_ADMIN_ADDRESS", deployed.groupAdmin);
        vm.serializeAddress(out, "GROUP_CHAT_ADDRESS", deployed.groupChat);
        vm.serializeAddress(out, "GROUP_CHAT_BAN_LIST_ADDRESS", deployed.groupChatBanList);
        vm.serializeAddress(out, "ADMIN_BAN_SOURCE_ADDRESS", deployed.adminBanSource);
        vm.serializeAddress(out, "GOV_VOTED_BAN_SOURCE_ADDRESS", deployed.govVotedBanSource);
        vm.serializeAddress(out, "GROUP_MEMBER_ADDRESS", deployed.groupMember);
        vm.serializeAddress(out, "GROUP_MEMBER_SCOPE_ADDRESS", deployed.groupMemberScope);
        vm.serializeAddress(out, "GROUP_JOIN_SCOPE_SOURCE_ADDRESS", deployed.groupJoinScopeSource);
        vm.serializeAddress(out, "TOKEN_MAIN_MANAGER_ADDRESS", deployed.tokenMainManager);
        vm.serializeAddress(out, "TOKEN_GOV_MANAGER_ADDRESS", deployed.tokenGovManager);
        vm.serializeAddress(out, "TOKEN_ACTION_GOV_MANAGER_ADDRESS", deployed.tokenActionGovManager);
        vm.serializeAddress(out, "TOKEN_ACTION_MAIN_MANAGER_ADDRESS", deployed.tokenActionMainManager);
        vm.serializeAddress(out, "BATCH_TRANSFER_ADDRESS", deployed.batchTransfer);
        vm.serializeAddress(out, "HUB_ADDRESS", deployed.hub);
        string memory json = vm.serializeUint(out, "chainId", params.chainId);
        vm.writeFile(vm.envString("ADDRESSES_JSON_FILE"), json);
    }

    function _logSummary(Deployed memory deployed) internal pure {
        console2.log("");
        console2.log("=== Deployed (copy into the frontend .env) ===");
        console2.log("LOVE20_TOKEN_ADDRESS         ", deployed.token);
        console2.log("AIRDROP_DISTRIBUTOR_ADDRESS  ", deployed.airdropDistributor);
        console2.log("PHASE_ADDRESS                ", deployed.phase);
        console2.log("LAUNCH_ADDRESS               ", deployed.launch);
        console2.log("MEMBER_NFT_ADDRESS           ", deployed.memberNFT);
        console2.log("STAKE_ADDRESS                ", deployed.stake);
        console2.log("SUBMIT_ADDRESS               ", deployed.submit);
        console2.log("VOTE_ADDRESS                 ", deployed.vote);
        console2.log("MINT_ADDRESS                 ", deployed.mint);
        console2.log("ACTION_TARGET_ADDRESS        ", deployed.actionTarget);
        console2.log("GROUP_ACTION_EXECUTOR_ADDRESS", deployed.groupActionExecutor);
        console2.log("GROUP_CHAT_ADDRESS           ", deployed.groupChat);
        console2.log("UNISWAP_V2_ROUTER02_ADDRESS  ", deployed.router);
        console2.log("UNISWAP_V2_FACTORY_ADDRESS   ", deployed.factory);
        console2.log("WETH_ADDRESS                 ", deployed.weth);
        console2.log("UNISWAP_V2_PAIR_ADDRESS      ", deployed.pair);
        console2.log("MULTICALL3_ADDRESS           ", deployed.multicall3);
        console2.log("BATCH_TRANSFER_ADDRESS       ", deployed.batchTransfer);
        console2.log("HUB_ADDRESS                  ", deployed.hub);
    }
}
