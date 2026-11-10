// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAirdrop} from "../src/vendor/IAirdrop.sol";
import {ILOVE20Token} from "@core/interfaces/ILOVE20Token.sol";
import {IMemberNFT} from "@core/interfaces/IMemberNFT.sol";
import {IStake} from "@core/interfaces/IStake.sol";
import {IPhase} from "@core/interfaces/IPhase.sol";

interface IWETHDeposit {
    function deposit() external payable;
}

interface IUniswapV2PairView {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
}

/// @title SeedFlow
/// @notice Turns a freshly deployed stack into a chain the frontend can actually be used against.
///
/// What a deploy alone leaves behind:
///   * the whole genesis supply sits in the Airdrop, every account has zero community tokens;
///   * no MemberNFT exists, so no wallet can act as a member;
///   * Launch._ensurePair() created the root token's pair with ZERO reserves, i.e. the token cannot
///     be bought, sold, or staked - and Stake.stakeLiquidity() is the only door into governance.
///
/// What this script does, in order, all as the real end users (each seeded account signs its own
/// transactions - no `deal`, no `anvil_setStorageAt`, no state forgery):
///
///   1. ETH top-up: every seeded account is brought to at least SEED_ETH_PER_ACCOUNT. anvil already
///      funds its own accounts, so on the default flags this is usually a no-op - it exists so the
///      same script works when someone lowers `--balance`.
///   2. Airdrop claim: every seeded account claims its fixture share with its own proof. This is the
///      only way community tokens enter circulation, exactly as in production:
///      claimable = balanceOf(airdrop) * share / remainingShare(token).
///   3. MemberNFT mint: every seeded account mints an identity (the name gets the protocol's "Test"
///      prefix), paying and burning the root-token mint cost.
///   4. Liquidity: SEED_LIQUIDITY_MEMBER_INDEX wraps ETH into WETH, approves Stake for both tokens and
///      calls Stake.stakeLiquidity(...). We deliberately use Stake and not Router.addLiquidity: the
///      stake is what creates governance weight (liquidityShares -> govVotes), so the seeded chain can
///      vote, submit and claim round rewards without a second manual step. The pair therefore gets its
///      reserves AND the staker gets a member stake in one transaction.
///
/// Reads the address book written by DeployLocal (export/deployments/<profile>.addresses.json) and the
/// same snapshot fixture the Airdrop was constructed with. Every seeded key is checked against the
/// fixture account before it claims, so a fixture generated for a different mnemonic fails here
/// instead of silently claiming for an account nobody controls.
contract SeedFlow is Script {
    struct SnapshotEntry {
        address account;
        uint256 share;
        bytes32[] proof;
    }

    struct Addresses {
        address token;
        address airdrop;
        address memberNFT;
        address stake;
        address weth;
        address pair;
        address phase;
    }

    struct SeedParams {
        string mnemonic;
        uint256 startIndex;
        uint256 memberCount;
        string namePrefix;
        uint256 liquidityMemberIndex;
        uint256 liquidityTokenAmount;
        uint256 liquidityParentTokenAmount;
        uint256 liquiditySlippage;
        uint256 liquidityPromisedWaitingPhases;
        uint256 ethPerAccount;
    }

    uint256 internal constant WAD = 1e18;

    function runSeed() external {
        SeedParams memory params = _loadParams();
        Addresses memory addrs = _loadAddresses();
        SnapshotEntry[] memory entries = _loadSnapshot();

        require(entries.length == vm.envUint("SEED_ACCOUNT_COUNT"), "snapshot entry count != SEED_ACCOUNT_COUNT");
        require(params.memberCount != 0 && params.memberCount <= entries.length, "SEED_MEMBER_COUNT out of range");
        require(params.liquidityMemberIndex < params.memberCount, "SEED_LIQUIDITY_MEMBER_INDEX out of range");
        require(addrs.token.code.length != 0, "token has no code - deploy first");
        require(addrs.airdrop.code.length != 0, "airdrop has no code - deploy first");
        require(addrs.memberNFT.code.length != 0, "memberNFT has no code - deploy first");
        require(addrs.stake.code.length != 0, "stake has no code - deploy first");
        require(addrs.pair.code.length != 0, "pair has no code - deploy first");

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        uint256 currentPhase = IPhase(addrs.phase).currentPhase();
        require(currentPhase >= 1, "phase 0 - the chain has not advanced past the deployment block");
        console2.log("  phase at seed start:", currentPhase);

        _fundEth(deployerKey, deployer, entries, params);

        uint256[] memory memberIds = new uint256[](params.memberCount);
        for (uint256 i = 0; i < params.memberCount; i++) {
            uint256 key = vm.deriveKey(params.mnemonic, uint32(params.startIndex + i));
            address account = vm.addr(key);
            require(account == entries[i].account, "derived key does not match the snapshot account");

            uint256 claimed = _claimAndMint(key, addrs, entries[i], params.namePrefix, i);
            memberIds[i] = claimed;
        }

        _stakeLiquidity(
            vm.deriveKey(params.mnemonic, uint32(params.startIndex + params.liquidityMemberIndex)),
            addrs,
            memberIds[params.liquidityMemberIndex],
            params
        );

        _assertSeedState(addrs, entries, memberIds, params);
    }

    // ------------------------------------------------------------------------------------------
    // step 1 - ETH
    // ------------------------------------------------------------------------------------------
    function _fundEth(uint256 deployerKey, address deployer, SnapshotEntry[] memory entries, SeedParams memory params)
        internal
    {
        vm.startBroadcast(deployerKey);
        for (uint256 i = 0; i < params.memberCount; i++) {
            address account = entries[i].account;
            if (account.balance < params.ethPerAccount) {
                uint256 topUp = params.ethPerAccount - account.balance;
                (bool sent,) = account.call{value: topUp}("");
                require(sent, "ETH top-up failed");
                console2.log("  eth topped up:", account, topUp);
            }
        }
        vm.stopBroadcast();
        console2.log("  eth: deployer", deployer, "balance", deployer.balance);
    }

    // ------------------------------------------------------------------------------------------
    // steps 2+3 - airdrop claim, member mint (both signed by the seeded account itself)
    // ------------------------------------------------------------------------------------------
    function _claimAndMint(
        uint256 key,
        Addresses memory addrs,
        SnapshotEntry memory entry,
        string memory namePrefix,
        uint256 index
    ) internal returns (uint256 memberId) {
        IAirdrop airdrop = IAirdrop(addrs.airdrop);
        uint256 claimable = airdrop.claimableAmount(addrs.token, entry.account, entry.share, entry.proof);
        require(claimable != 0, "fixture entry is not claimable (wrong root or already claimed)");

        string memory name = string.concat(namePrefix, vm.toString(index));
        uint256 cost = IMemberNFT(addrs.memberNFT).calculateMintCost(name);

        vm.startBroadcast(key);
        uint256 claimed = airdrop.claim(addrs.token, entry.account, entry.share, entry.proof);
        require(claimed == claimable, "claim amount differs from the quote");

        IERC20(addrs.token).approve(addrs.memberNFT, cost);
        (uint256 tokenId, uint256 actualCost) = IMemberNFT(addrs.memberNFT).mint(name);
        vm.stopBroadcast();

        // The protocol prefixes "Test" onto the name when the token symbol starts with "Test"; that
        // never shortens it, and any name >= BYTES_THRESHOLD bytes has the same cost, so the approved
        // amount is exact. If that assumption ever breaks, the mint reverts on allowance - and this
        // require makes the reason obvious when it does not.
        require(actualCost == cost, "mint cost differed from calculateMintCost");

        console2.log("  member:", entry.account);
        console2.log("  member memberId:", tokenId);
        console2.log("  member claimed:", claimed);
        console2.log("  member mintCost:", actualCost);
        require(IMemberNFT(addrs.memberNFT).balanceOf(entry.account) != 0, "member NFT not minted");
        require(airdrop.isClaimed(addrs.token, entry.account), "airdrop claim not recorded");
        return tokenId;
    }

    // ------------------------------------------------------------------------------------------
    // step 4 - liquidity through Stake
    // ------------------------------------------------------------------------------------------
    function _stakeLiquidity(uint256 key, Addresses memory addrs, uint256 memberId, SeedParams memory params)
        internal
    {
        address account = vm.addr(key);
        require(memberId != 0, "liquidity member has no member NFT");

        vm.startBroadcast(key);
        IWETHDeposit(addrs.weth).deposit{value: params.liquidityParentTokenAmount}();
        IERC20(addrs.token).approve(addrs.stake, params.liquidityTokenAmount);
        IERC20(addrs.weth).approve(addrs.stake, params.liquidityParentTokenAmount);
        (uint256 govVotesAdded, uint256 liquiditySharesAdded) = IStake(addrs.stake).stakeLiquidity(
            addrs.token,
            params.liquidityTokenAmount,
            params.liquidityParentTokenAmount,
            params.liquiditySlippage,
            params.liquidityPromisedWaitingPhases,
            memberId
        );
        vm.stopBroadcast();

        console2.log("  liquidity: account", account, "memberId", memberId);
        console2.log("  liquidity: liquidityShares", liquiditySharesAdded, "govVotes", govVotesAdded);
    }

    // ------------------------------------------------------------------------------------------
    // assertions + summary
    // ------------------------------------------------------------------------------------------
    function _assertSeedState(
        Addresses memory addrs,
        SnapshotEntry[] memory entries,
        uint256[] memory memberIds,
        SeedParams memory params
    ) internal view {
        IUniswapV2PairView pair = IUniswapV2PairView(addrs.pair);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        require(reserve0 != 0 && reserve1 != 0, "pair reserves are still zero");

        uint256 lpInStake = pair.balanceOf(addrs.stake);
        require(lpInStake != 0, "Stake holds no LP tokens");
        (uint256 totalLiquidityShares,,,,,,) = IStake(addrs.stake).totalStake(addrs.token);
        require(totalLiquidityShares != 0, "Stake.totalLiquidityShares is zero");

        for (uint256 i = 0; i < params.memberCount; i++) {
            require(IMemberNFT(addrs.memberNFT).balanceOf(entries[i].account) > 0, "seeded account has no MemberNFT");
            require(
                IERC20(addrs.token).balanceOf(entries[i].account) > 0,
                "seeded account holds no community tokens after claiming"
            );
            require(entries[i].account.balance >= params.ethPerAccount, "seeded account is under-funded");
        }

        // Reserves are ordered by the pair's token0/token1, which is sorted by address, so label
        // them from the pair itself instead of assuming the community token comes first.
        uint256 reserveToken = pair.token0() == addrs.token ? uint256(reserve0) : uint256(reserve1);
        uint256 reserveWeth = pair.token0() == addrs.weth ? uint256(reserve0) : uint256(reserve1);

        console2.log("");
        console2.log("  pair:", addrs.pair);
        console2.log("  pair reserve token:", reserveToken);
        console2.log("  pair reserve weth:", reserveWeth);
        console2.log("  pair price (token per weth):", reserveToken / reserveWeth);
        console2.log("  pair lp held by Stake:", lpInStake);
        console2.log("  stake totalLiquidityShares:", totalLiquidityShares);
        console2.log("  memberNFT totalSupply:", IMemberNFT(addrs.memberNFT).totalSupply());
        console2.log("  token totalSupply:", ILOVE20Token(addrs.token).totalSupply());
        console2.log("  phase:", IPhase(addrs.phase).currentPhase());
        // memberIds is used only for ordering/logs; the require above already proves ownership.
        console2.log("  first seeded memberId:", memberIds[0]);
    }

    // ------------------------------------------------------------------------------------------
    // env / files
    // ------------------------------------------------------------------------------------------
    function _loadParams() internal view returns (SeedParams memory params) {
        params.mnemonic = vm.envString("SEED_MNEMONIC");
        params.startIndex = vm.envUint("SEED_ACCOUNT_START_INDEX");
        params.memberCount = vm.envUint("SEED_MEMBER_COUNT");
        params.namePrefix = vm.envString("SEED_MEMBER_NAME_PREFIX");
        params.liquidityMemberIndex = vm.envUint("SEED_LIQUIDITY_MEMBER_INDEX");
        params.liquidityTokenAmount = vm.envUint("SEED_LIQUIDITY_TOKEN_AMOUNT");
        params.liquidityParentTokenAmount = vm.envUint("SEED_LIQUIDITY_PARENT_TOKEN_AMOUNT");
        params.liquiditySlippage = vm.envUint("SEED_LIQUIDITY_SLIPPAGE");
        params.liquidityPromisedWaitingPhases = vm.envUint("SEED_LIQUIDITY_PROMISED_WAITING_PHASES");
        params.ethPerAccount = vm.envUint("SEED_ETH_PER_ACCOUNT");

        require(bytes(params.mnemonic).length != 0, "SEED_MNEMONIC is empty");
        require(bytes(params.namePrefix).length != 0, "SEED_MEMBER_NAME_PREFIX is empty");
        require(params.liquidityTokenAmount != 0, "SEED_LIQUIDITY_TOKEN_AMOUNT is zero");
        require(params.liquidityParentTokenAmount != 0, "SEED_LIQUIDITY_PARENT_TOKEN_AMOUNT is zero");
    }

    function _loadAddresses() internal view returns (Addresses memory addrs) {
        string memory book = vm.readFile(vm.envString("ADDRESSES_JSON_FILE"));
        addrs.token = vm.parseJsonAddress(book, ".LOVE20_TOKEN_ADDRESS");
        addrs.airdrop = vm.parseJsonAddress(book, ".AIRDROP_ADDRESS");
        addrs.memberNFT = vm.parseJsonAddress(book, ".MEMBER_NFT_ADDRESS");
        addrs.stake = vm.parseJsonAddress(book, ".STAKE_ADDRESS");
        addrs.weth = vm.parseJsonAddress(book, ".WETH_ADDRESS");
        addrs.pair = vm.parseJsonAddress(book, ".UNISWAP_V2_PAIR_ADDRESS");
        addrs.phase = vm.parseJsonAddress(book, ".PHASE_ADDRESS");
    }

    function _loadSnapshot() internal view returns (SnapshotEntry[] memory entries) {
        string memory json = vm.readFile(vm.envString("AIRDROP_SNAPSHOT_FILE"));
        uint256 count = _jsonUint(json, ".accountCount");
        entries = new SnapshotEntry[](count);
        for (uint256 i = 0; i < count; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            entries[i] = SnapshotEntry({
                account: vm.parseJsonAddress(json, string.concat(base, ".account")),
                share: _jsonUint(json, string.concat(base, ".share")),
                proof: vm.parseJsonBytes32Array(json, string.concat(base, ".proof"))
            });
            require(entries[i].account != address(0), "snapshot entry has a zero account");
            require(entries[i].share != 0, "snapshot entry has a zero share");
        }
    }

    /// @dev The fixture stores numbers as decimal strings (canonical burn snapshot format).
    function _jsonUint(string memory json, string memory key) internal pure returns (uint256) {
        return vm.parseUint(vm.parseJsonString(json, key));
    }
}
