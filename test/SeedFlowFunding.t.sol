// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Test} from "@forge-std/Test.sol";
import {SeedFlow} from "../script/SeedFlow.s.sol";

/// @dev Pins the one piece of arithmetic that decides whether the seed can satisfy its own final
///      assertions: the per-account ETH funding target (N-01). No chain, no fork, no env - the target
///      is a pure function of the seed params, so it is tested as one.
///
///      The invariant under test is the contract between step 1 and the final assertions:
///        balance at seed end >= SEED_ETH_PER_ACCOUNT
///      given that the seed makes the account spend, after step 1,
///        - SEED_LIQUIDITY_PARENT_TOKEN_AMOUNT (wrapped into WETH and staked; the ETH leaves the
///          wallet), only for the liquidity member, and
///        - gas (bounded by SEED_GAS_ALLOWANCE).
contract SeedFlowFundingTest is Test {
    SeedFlow internal flow;

    // The profile's values (params/anvil31337_dev/seed.params), copied on purpose: a change there
    // should force a conscious look at these expectations instead of silently re-tuning them.
    uint256 internal constant ETH_PER_ACCOUNT = 100e18;
    uint256 internal constant LIQUIDITY_PARENT_TOKEN_AMOUNT = 1e20; // 100 ETH
    uint256 internal constant LIQUIDITY_MEMBER_INDEX = 0;

    function setUp() public {
        flow = new SeedFlow();
    }

    /// @dev Every account except the liquidity member is funded to SEED_ETH_PER_ACCOUNT and nothing more.
    function testNonLiquidityMembersAreFundedToEthPerAccount() public view {
        assertEq(
            flow.seedEthTarget(ETH_PER_ACCOUNT, LIQUIDITY_PARENT_TOKEN_AMOUNT, LIQUIDITY_MEMBER_INDEX, 1),
            ETH_PER_ACCOUNT
        );
        assertEq(
            flow.seedEthTarget(ETH_PER_ACCOUNT, LIQUIDITY_PARENT_TOKEN_AMOUNT, LIQUIDITY_MEMBER_INDEX, 2),
            ETH_PER_ACCOUNT
        );
        assertEq(
            flow.seedEthTarget(ETH_PER_ACCOUNT, LIQUIDITY_PARENT_TOKEN_AMOUNT, LIQUIDITY_MEMBER_INDEX, 4),
            ETH_PER_ACCOUNT
        );
    }

    /// @dev The liquidity member gets its ethPerAccount PLUS the parent amount it is about to stake
    ///      PLUS the fixed gas allowance - never just ethPerAccount.
    function testLiquidityMemberIsFundedForStakeAndGas() public view {
        uint256 target = flow.seedEthTarget(
            ETH_PER_ACCOUNT, LIQUIDITY_PARENT_TOKEN_AMOUNT, LIQUIDITY_MEMBER_INDEX, LIQUIDITY_MEMBER_INDEX
        );

        assertEq(target, ETH_PER_ACCOUNT + LIQUIDITY_PARENT_TOKEN_AMOUNT + flow.SEED_GAS_ALLOWANCE());
        assertGt(flow.SEED_GAS_ALLOWANCE(), 0, "gas allowance must be a positive constant");
    }

    /// @dev The invariant the fix restores: a liquidity member funded to its target still holds at
    ///      least ethPerAccount after the seed spend. The old target (= ethPerAccount) provably did not,
    ///      which is exactly the N-01 contradiction the assertions tripped over.
    function testLiquidityMemberEndsAboveEthPerAccount() public view {
        uint256 target = flow.seedEthTarget(ETH_PER_ACCOUNT, LIQUIDITY_PARENT_TOKEN_AMOUNT, LIQUIDITY_MEMBER_INDEX, 0);
        uint256 leftAfterStakeAndGas = target - LIQUIDITY_PARENT_TOKEN_AMOUNT - flow.SEED_GAS_ALLOWANCE();
        assertGe(leftAfterStakeAndGas, ETH_PER_ACCOUNT, "liquidity member would end under-funded");

        uint256 oldTarget = ETH_PER_ACCOUNT; // what _fundEth brought every account to before the fix
        assertLt(
            oldTarget - LIQUIDITY_PARENT_TOKEN_AMOUNT,
            ETH_PER_ACCOUNT,
            "old target must be provably unable to satisfy the final assertion"
        );
    }

    /// @dev The target follows SEED_LIQUIDITY_MEMBER_INDEX, not a hardcoded index 0.
    function testTargetFollowsTheConfiguredMemberIndex() public view {
        uint256 memberIndex = 3;
        assertEq(flow.seedEthTarget(ETH_PER_ACCOUNT, LIQUIDITY_PARENT_TOKEN_AMOUNT, memberIndex, 0), ETH_PER_ACCOUNT);
        assertEq(
            flow.seedEthTarget(ETH_PER_ACCOUNT, LIQUIDITY_PARENT_TOKEN_AMOUNT, memberIndex, memberIndex),
            ETH_PER_ACCOUNT + LIQUIDITY_PARENT_TOKEN_AMOUNT + flow.SEED_GAS_ALLOWANCE()
        );
    }
}
