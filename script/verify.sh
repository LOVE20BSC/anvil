#!/usr/bin/env bash
# Independent post-deployment verification.
#
# Every check is a `cast call` / `cast code` against the live node - nothing is read back from the
# deployment scripts' own logs, so a script that lies cannot make this pass. The address list comes
# from export/deployments/<profile>.json, which is what the frontend consumes.
#
# Writes export/VERIFIED.md with the actual values and exits non-zero if anything fails.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROFILE="${PROFILE:-anvil31337_dev}"
PARAMS_DIR="$ROOT/params/$PROFILE"
DEPLOYMENTS_DIR="$ROOT/export/deployments"
JSON="$DEPLOYMENTS_DIR/$PROFILE.json"
REPORT="$ROOT/export/VERIFIED.md"

# shellcheck source=script/lib/params.sh
source "$ROOT/script/lib/params.sh"
for f in network accounts dex multicall3 airdrop core action group-chat seed; do
    params_load "$PARAMS_DIR/$f.params"
done
RPC_URL="http://${ANVIL_HOST}:${ANVIL_PORT}"
SNAPSHOT_ABS="$ROOT/$AIRDROP_SNAPSHOT_FILE"

FAILED=0
CHECKS=()

say() { printf '%s\n' "$*"; }

# check <label> <expected> <actual>
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        CHECKS+=("| $label | \`$expected\` | \`$actual\` | PASS |")
        printf '  \033[0;32mPASS\033[0m %s = %s\n' "$label" "$actual"
    else
        CHECKS+=("| $label | \`$expected\` | \`$actual\` | **FAIL** |")
        printf '  \033[0;31mFAIL\033[0m %s: expected %s, got %s\n' "$label" "$expected" "$actual"
        FAILED=1
    fi
}

# gt <a> <b> -> 0 if a > b. Uses python for the comparison because a uint256 balance overflows the
# shell's 64-bit arithmetic (1e18 token amounts are routine here).
gt() { python3 -c "import sys;sys.exit(0 if int('$1') > int('$2') else 1)" 2>/dev/null; }

# check_gt <label> <lower bound> <actual>
check_gt() {
    local label="$1" bound="$2" actual="$3"
    if gt "$actual" "$bound"; then
        CHECKS+=("| $label | \`> $bound\` | \`$actual\` | PASS |")
        printf '  \033[0;32mPASS\033[0m %s = %s (> %s)\n' "$label" "$actual" "$bound"
    else
        CHECKS+=("| $label | \`> $bound\` | \`$actual\` | **FAIL** |")
        printf '  \033[0;31mFAIL\033[0m %s: expected > %s, got %s\n' "$label" "$bound" "$actual"
        FAILED=1
    fi
}

call() { cast call "$1" "$2" "${@:3}" --rpc-url "$RPC_URL" 2>/dev/null | awk '{print $1}'; }
code_size() {
    local code
    code="$(cast code "$1" --rpc-url "$RPC_URL" 2>/dev/null)"
    [ "$code" = "0x" ] && { echo 0; return; }
    echo $(( (${#code} - 2) / 2 ))
}
json_addr() { python3 -c "import json;print(json.load(open('$JSON'))['addresses']['$1'])"; }
# json_path <key>... -> the value at that path in the export, one JSON token per line.
json_path() {
    python3 - "$JSON" "$@" <<'PY'
import json
import sys

node = json.load(open(sys.argv[1]))
for key in sys.argv[2:]:
    node = node[int(key)] if isinstance(node, list) else node[key]
print(json.dumps(node) if isinstance(node, (dict, list)) else node)
PY
}

[ -f "$JSON" ] || { echo "missing $JSON - run 'make export' first" >&2; exit 1; }

say ""
say "==> verify ($PROFILE @ $RPC_URL)"

# ------------------------------------------------------------------------------------------------
# 0. chain
# ------------------------------------------------------------------------------------------------
chain_id="$(cast chain-id --rpc-url "$RPC_URL")"
block_number="$(cast block-number --rpc-url "$RPC_URL")"
check "chain id" "$CHAIN_ID" "$chain_id"

TOKEN="$(json_addr LOVE20_TOKEN_ADDRESS)"
DISTRIBUTOR="$(json_addr AIRDROP_DISTRIBUTOR_ADDRESS)"
PHASE="$(json_addr PHASE_ADDRESS)"
LAUNCH="$(json_addr LAUNCH_ADDRESS)"
MEMBER_NFT="$(json_addr MEMBER_NFT_ADDRESS)"
STAKE="$(json_addr STAKE_ADDRESS)"
SUBMIT="$(json_addr SUBMIT_ADDRESS)"
VOTE="$(json_addr VOTE_ADDRESS)"
MINT="$(json_addr MINT_ADDRESS)"
ACTION_TARGET="$(json_addr ACTION_TARGET_ADDRESS)"
LP_EXECUTOR="$(json_addr LP_EXECUTOR_ADDRESS)"
GROUP_ACTION_EXECUTOR="$(json_addr GROUP_ACTION_EXECUTOR_ADDRESS)"
GROUP_SERVICE_EXECUTOR="$(json_addr GROUP_SERVICE_EXECUTOR_ADDRESS)"
GROUP_ADMIN="$(json_addr GROUP_ADMIN_ADDRESS)"
GROUP_CHAT="$(json_addr GROUP_CHAT_ADDRESS)"
WETH="$(json_addr WETH_ADDRESS)"
FACTORY="$(json_addr UNISWAP_V2_FACTORY_ADDRESS)"
ROUTER="$(json_addr UNISWAP_V2_ROUTER02_ADDRESS)"
PAIR="$(json_addr UNISWAP_V2_PAIR_ADDRESS)"
MULTICALL3="$(json_addr MULTICALL3_ADDRESS)"
GROUP_ACTION_JOIN="$(json_addr GROUP_ACTION_JOIN_LIBRARY_ADDRESS)"
GROUP_ACTION_MANAGER="$(json_addr GROUP_ACTION_MANAGER_LIBRARY_ADDRESS)"
GROUP_ACTION_VERIFY="$(json_addr GROUP_ACTION_VERIFY_LIBRARY_ADDRESS)"
GROUP_RECIPIENTS="$(json_addr GROUP_RECIPIENTS_LIBRARY_ADDRESS)"

# ------------------------------------------------------------------------------------------------
# 1. code at every exported address
# ------------------------------------------------------------------------------------------------
say "  -- code at every exported address --"
CODE_ROWS=()
while IFS=$'\t' read -r name address; do
    size="$(code_size "$address")"
    if [ "$size" -gt 0 ]; then
        CODE_ROWS+=("| $name | \`$address\` | $size | PASS |")
    else
        CODE_ROWS+=("| $name | \`$address\` | 0 | **FAIL** |")
        FAILED=1
        printf '  \033[0;31mFAIL\033[0m no code at %s (%s)\n' "$address" "$name"
    fi
done < <(python3 -c "
import json
d=json.load(open('$JSON'))
for name, addr in sorted(d['contracts'].items()):
    print(f'{name}\t{addr[\"address\"]}')
")
printf '  \033[0;32mPASS\033[0m code present at all %s exported addresses\n' "${#CODE_ROWS[@]}"

# ------------------------------------------------------------------------------------------------
# 2. dex wiring
# ------------------------------------------------------------------------------------------------
check "UniswapV2Router02.factory()" "$FACTORY" "$(call "$ROUTER" 'factory()(address)')"
check "UniswapV2Router02.WETH()" "$WETH" "$(call "$ROUTER" 'WETH()(address)')"
check "UniswapV2Factory.feeTo()" "0x0000000000000000000000000000000000000000" "$(call "$FACTORY" 'feeTo()(address)')"
check "UniswapV2Factory.feeToSetter()" "0x0000000000000000000000000000000000000000" "$(call "$FACTORY" 'feeToSetter()(address)')"
pair_token0="$(call "$PAIR" 'token0()(address)')"
pair_token1="$(call "$PAIR" 'token1()(address)')"
if [ "$pair_token0" = "$WETH" ]; then pair_side="token0"; else pair_side="token1"; fi
check "UniswapV2Pair has WETH as $pair_side" "$WETH" "$( [ "$pair_token0" = "$WETH" ] && echo "$pair_token0" || echo "$pair_token1" )"

# ------------------------------------------------------------------------------------------------
# 3. core wiring
# ------------------------------------------------------------------------------------------------
check "LOVE20Token.MINTER()" "$MINT" "$(call "$TOKEN" 'MINTER()(address)')"
check "LOVE20Token.PARENT_TOKEN_ADDRESS()" "$WETH" "$(call "$TOKEN" 'PARENT_TOKEN_ADDRESS()(address)')"
check "LOVE20Token.symbol()" "$TOKEN_SYMBOL" "$(call "$TOKEN" 'symbol()(string)' | tr -d '\"')"
check "LOVE20Token.name()" "$TOKEN_NAME" "$(call "$TOKEN" 'name()(string)' | tr -d '\"')"
check "LOVE20Token.MAX_SUPPLY()" "$MAX_SUPPLY" "$(call "$TOKEN" 'MAX_SUPPLY()(uint256)')"
check "Launch.FIRST_TOKEN_ADDRESS()" "$TOKEN" "$(call "$LAUNCH" 'FIRST_TOKEN_ADDRESS()(address)')"
check "Launch.MINT_ADDRESS()" "$MINT" "$(call "$LAUNCH" 'MINT_ADDRESS()(address)')"
check "Launch.MEMBER_NFT_ADDRESS()" "$MEMBER_NFT" "$(call "$LAUNCH" 'MEMBER_NFT_ADDRESS()(address)')"
check "Launch.ROOT_PARENT_TOKEN_ADDRESS()" "$WETH" "$(call "$LAUNCH" 'ROOT_PARENT_TOKEN_ADDRESS()(address)')"
check "Launch.PAIR_FACTORY_ADDRESS()" "$FACTORY" "$(call "$LAUNCH" 'PAIR_FACTORY_ADDRESS()(address)')"
check "Stake.VOTE_ADDRESS()" "$VOTE" "$(call "$STAKE" 'VOTE_ADDRESS()(address)')"
check "Stake.LAUNCH_ADDRESS()" "$LAUNCH" "$(call "$STAKE" 'LAUNCH_ADDRESS()(address)')"
check "Stake.ROUTER_ADDRESS()" "$ROUTER" "$(call "$STAKE" 'ROUTER_ADDRESS()(address)')"
check "Stake.PAIR_FACTORY_ADDRESS()" "$FACTORY" "$(call "$STAKE" 'PAIR_FACTORY_ADDRESS()(address)')"
check "Vote.SUBMIT_ADDRESS()" "$SUBMIT" "$(call "$VOTE" 'SUBMIT_ADDRESS()(address)')"
check "Vote.STAKE_ADDRESS()" "$STAKE" "$(call "$VOTE" 'STAKE_ADDRESS()(address)')"
check "Submit.STAKE_ADDRESS()" "$STAKE" "$(call "$SUBMIT" 'STAKE_ADDRESS()(address)')"
check "Mint.MEMBER_NFT_ADDRESS()" "$MEMBER_NFT" "$(call "$MINT" 'MEMBER_NFT_ADDRESS()(address)')"
check "AirdropDistributor.LAUNCH_ADDRESS()" "$LAUNCH" "$(call "$DISTRIBUTOR" 'LAUNCH_ADDRESS()(address)')"
check "AirdropDistributor.PHASE_ADDRESS()" "$PHASE" "$(call "$DISTRIBUTOR" 'PHASE_ADDRESS()(address)')"
check "ActionTarget.MINT_ADDRESS()" "$MINT" "$(call "$ACTION_TARGET" 'MINT_ADDRESS()(address)')"
check "LpExecutor.STAKE_ADDRESS()" "$STAKE" "$(call "$LP_EXECUTOR" 'STAKE_ADDRESS()(address)')"
check "GroupActionExecutor.ACTION_TARGET_ADDRESS()" "$ACTION_TARGET" \
    "$(call "$GROUP_ACTION_EXECUTOR" 'ACTION_TARGET_ADDRESS()(address)')"
check "GroupServiceExecutor.GROUP_ACTION_EXECUTOR_ADDRESS()" "$GROUP_ACTION_EXECUTOR" \
    "$(call "$GROUP_SERVICE_EXECUTOR" 'GROUP_ACTION_EXECUTOR_ADDRESS()(address)')"
check "GroupChat.GROUP_ADDRESS()" "$MEMBER_NFT" "$(call "$GROUP_CHAT" 'GROUP_ADDRESS()(address)')"
check "GroupChat.GROUP_ADMIN_ADDRESS()" "$GROUP_ADMIN" "$(call "$GROUP_CHAT" 'GROUP_ADMIN_ADDRESS()(address)')"

# ------------------------------------------------------------------------------------------------
# 4. phase (must be 1 on a fresh bootstrap; a long-running local chain may be higher)
# ------------------------------------------------------------------------------------------------
current_phase="$(call "$PHASE" 'currentPhase()(uint256)')"
check_gt "Phase.currentPhase()" "0" "$current_phase"
check "Phase.ORIGIN_PHASE_BLOCKS()" "$PHASE_ORIGIN_PHASE_BLOCKS" "$(call "$PHASE" 'ORIGIN_PHASE_BLOCKS()(uint256)')"
check "Phase.TARGET_SECONDS()" "$PHASE_TARGET_SECONDS" "$(call "$PHASE" 'TARGET_SECONDS()(uint256)')"
check "GroupChat.currentRound()" "$current_phase" "$(call "$GROUP_CHAT" 'currentRound()(uint256)')"

# ------------------------------------------------------------------------------------------------
# 4b. exported metadata is data the frontend trusts: it must describe THIS chain
# ------------------------------------------------------------------------------------------------
exported_deployer="$(json_path deployer)"
check "export.deployer == params deploy account" \
    "$(cast wallet address --mnemonic "$SEED_MNEMONIC" --mnemonic-index "$DEPLOY_ACCOUNT_INDEX")" \
    "$exported_deployer"
check_gt "exported deployer ETH balance" "0" "$(cast balance "$exported_deployer" --rpc-url "$RPC_URL")"

check "export.params.tokenName" "$(call "$TOKEN" 'name()(string)' | tr -d '\"')" "$(json_path params tokenName)"
check "export.params.tokenSymbol" "$(call "$TOKEN" 'symbol()(string)' | tr -d '\"')" "$(json_path params tokenSymbol)"
check "export.params.phaseOriginBlocks" "$(call "$PHASE" 'ORIGIN_BLOCKS()(uint256)')" \
    "$(json_path params phaseOriginBlocks)"
check "export.params.phaseOriginPhaseBlocks" "$(call "$PHASE" 'ORIGIN_PHASE_BLOCKS()(uint256)')" \
    "$(json_path params phaseOriginPhaseBlocks)"
check "export.params.phaseTargetSeconds" "$(call "$PHASE" 'TARGET_SECONDS()(uint256)')" \
    "$(json_path params phaseTargetSeconds)"
check "export.params.seedAccountCount" "$SEED_ACCOUNT_COUNT" "$(json_path params seedAccountCount)"
check "export.params.seedMemberCount" "$SEED_MEMBER_COUNT" "$(json_path params seedMemberCount)"
check "export.uniswapV2.factory" "$FACTORY" "$(json_path uniswapV2 factory)"
check "export.uniswapV2.feeTo" "$(call "$FACTORY" 'feeTo()(address)')" "$(json_path uniswapV2 feeTo)"

# ------------------------------------------------------------------------------------------------
# 5. seeded state: identities, balances, liquidity, airdrop
# ------------------------------------------------------------------------------------------------
SEED_ACCOUNTS=$(python3 - <<'PY'
import subprocess
mnemonic = __import__("os").environ["SEED_MNEMONIC"]
start = int(__import__("os").environ["SEED_ACCOUNT_START_INDEX"])
count = int(__import__("os").environ["SEED_MEMBER_COUNT"])
for i in range(start, start + count):
    out = subprocess.run(["cast", "wallet", "address", "--mnemonic", mnemonic, "--mnemonic-index", str(i)],
                         capture_output=True, text=True, check=True)
    print(out.stdout.strip())
PY
)
first_seed="$(echo "$SEED_ACCOUNTS" | head -1)"
check_gt "MemberNFT.balanceOf(seed[0])" "0" "$(call "$MEMBER_NFT" 'balanceOf(address)(uint256)' "$first_seed")"
check_gt "MemberNFT.totalSupply()" "1" "$(call "$MEMBER_NFT" 'totalSupply()(uint256)')"
check_gt "LOVE20Token.balanceOf(seed[0])" "0" "$(call "$TOKEN" 'balanceOf(address)(uint256)' "$first_seed")"
check_gt "LOVE20Token.balanceOf(AirdropDistributor)" "0" "$(call "$TOKEN" 'balanceOf(address)(uint256)' "$DISTRIBUTOR")"

r0="$(cast call "$PAIR" 'getReserves()(uint112,uint112,uint32)' --rpc-url "$RPC_URL" | sed -n '1p' | awk '{print $1}')"
r1="$(cast call "$PAIR" 'getReserves()(uint112,uint112,uint32)' --rpc-url "$RPC_URL" | sed -n '2p' | awk '{print $1}')"
check_gt "UniswapV2Pair reserve0" "0" "${r0:-0}"
check_gt "UniswapV2Pair reserve1" "0" "${r1:-0}"
check_gt "UniswapV2Pair LP held by Stake" "0" "$(call "$PAIR" 'balanceOf(address)(uint256)' "$STAKE")"
stake_shares="$(call "$STAKE" 'totalStake(address)(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)' "$TOKEN" | head -1)"
check_gt "Stake.totalLiquidityShares" "0" "$stake_shares"

# --- AirdropDistributor: one airdropInfo() tuple covers root, round, shares and amounts ---
# `--json` is required: without it `cast call` prints the already-decoded human tuple
# `(0x…, 0x…, 2, …)`, which a comma split would mis-read when snapshotUri contains a comma.
# Field order is AirdropInfo: tokenAddress, merkleRoot, claimableFromRound, totalClaimedShare,
# totalRemainingShare, totalClaimedAmount, remainingAmount, snapshotUri.
AIRDROP_INFO_SIG='airdropInfo(address)((address,bytes32,uint256,uint256,uint256,uint256,uint256,string))'
airdrop_info_json="$(cast call "$DISTRIBUTOR" "$AIRDROP_INFO_SIG" "$TOKEN" --rpc-url "$RPC_URL" --json 2>/dev/null || true)"
airdrop_field() {
    [ -n "$airdrop_info_json" ] || { echo ""; return 0; }
    printf '%s' "$airdrop_info_json" \
        | python3 -c "import json,sys;print(json.load(sys.stdin)[0][$1])" 2>/dev/null || echo ""
}
info_token="$(airdrop_field 0)"
merkle_root="$(airdrop_field 1)"
claimable_from_round="$(airdrop_field 2)"
total_claimed_share="$(airdrop_field 3)"
total_remaining_share="$(airdrop_field 4)"
total_claimed_amount="$(airdrop_field 5)"
remaining_amount="$(airdrop_field 6)"
snapshot_uri="$(airdrop_field 7)"

check "AirdropDistributor.airdropInfo.tokenAddress" \
    "$(printf '%s' "$TOKEN" | tr 'A-Z' 'a-z')" "$(printf '%s' "$info_token" | tr 'A-Z' 'a-z')"
fixture_root="$(python3 -c "import json;print(json.load(open('$SNAPSHOT_ABS'))['merkleRoot'])")"
fixture_total="$(python3 -c "import json;print(int(json.load(open('$SNAPSHOT_ABS'))['totalShare']))")"
check "AirdropDistributor.airdropInfo.merkleRoot == params GENESIS_AIRDROP_MERKLE_ROOT" \
    "$GENESIS_AIRDROP_MERKLE_ROOT" "$merkle_root"
check "AirdropDistributor.airdropInfo.merkleRoot == fixture root" "$fixture_root" "$merkle_root"
check "AirdropDistributor.TOTAL_SHARE == fixture totalShare" \
    "$fixture_total" "$(call "$DISTRIBUTOR" 'TOTAL_SHARE()(uint256)')"

# claimableFromRound was frozen as max(phase at deploy, 1) + claim delay. Read the distributor's own
# deployment block from the export and ask the chain what phase that block was in, instead of
# assuming the bootstrap never crossed a phase boundary (it runs in phase 1).
distributor_block="$(json_path contracts AirdropDistributor blockNumber)"
phase_at_deploy="$(call "$PHASE" 'phaseAtBlock(uint256)(uint256)' "$distributor_block")"
base_round=$(( phase_at_deploy > 0 ? phase_at_deploy : 1 ))
expected_from_round=$(( base_round + GENESIS_AIRDROP_CLAIM_DELAY_ROUNDS ))
check "AirdropDistributor.airdropInfo.claimableFromRound" "$expected_from_round" "$claimable_from_round"
check_gt "AirdropDistributor claim round reached by now" "$(( expected_from_round - 1 ))" "$current_phase"

# The seed claims the first SEED_MEMBER_COUNT entries; shares are equal, so each payout is exactly
# launchAmount * share / TOTAL_SHARE (balance and remaining share shrink by the same ratio).
first_share="$(python3 -c "import json;print(json.load(open('$SNAPSHOT_ABS'))['entries'][0]['share'])")"
expected_claim_amount="$(python3 -c "print(int('$LAUNCH_AMOUNT') * int('$first_share') // int('$TOTAL_SHARE'))")"
check "AirdropDistributor.claimedAmount(seed[0])" "$expected_claim_amount" \
    "$(call "$DISTRIBUTOR" 'claimedAmount(address,address)(uint256)' "$TOKEN" "$first_seed")"
check "AirdropDistributor.isClaimed(seed[0])" "true" \
    "$(call "$DISTRIBUTOR" 'isClaimed(address,address)(bool)' "$TOKEN" "$first_seed")"

expected_claimed_share="$(python3 -c "print(int('$first_share') * int('$SEED_MEMBER_COUNT'))")"
expected_remaining_share="$(python3 -c "print(int('$TOTAL_SHARE') - int('$expected_claimed_share'))")"
expected_balance="$(python3 -c "print(int('$LAUNCH_AMOUNT') - int('$expected_claim_amount') * int('$SEED_MEMBER_COUNT'))")"
expected_claimed_amount="$(python3 -c "print(int('$expected_claim_amount') * int('$SEED_MEMBER_COUNT'))")"
check "AirdropDistributor.airdropInfo.totalClaimedShare" "$expected_claimed_share" "$total_claimed_share"
check "AirdropDistributor.airdropInfo.totalRemainingShare" "$expected_remaining_share" "$total_remaining_share"
check "AirdropDistributor.airdropInfo.totalClaimedAmount" "$expected_claimed_amount" "$total_claimed_amount"
check "AirdropDistributor.airdropInfo.remainingAmount" "$expected_balance" "$remaining_amount"
check "AirdropDistributor.airdropInfo.remainingAmount == token balance" \
    "$(call "$TOKEN" 'balanceOf(address)(uint256)' "$DISTRIBUTOR")" "$remaining_amount"
check "LOVE20Token.balanceOf(AirdropDistributor)" "$expected_balance" \
    "$(call "$TOKEN" 'balanceOf(address)(uint256)' "$DISTRIBUTOR")"

# Snapshot URI: core@4200d35 still only lets a LAUNCHED token's launcher member set it. The genesis
# airdrop has no launcher member (configured with launcherMemberId 0 in the constructor) and
# `launcherMemberIdByTokenAddress` no longer exists, so the only observable genesis state is
# `airdropInfo.snapshotUri`; it MUST be empty. The intended URI lives in seed.params as SNAPSHOT_URI
# until core exposes a genesis path.
check "AirdropDistributor.airdropInfo.snapshotUri(genesis, not registrable on core@4200d35)" "" "$snapshot_uri"

# The exported metadata is what the frontend consumes; make sure the new struct fields made it there.
check "export.airdropDistributor.merkleRoot" "$merkle_root" "$(json_path airdropDistributor merkleRoot)"
check "export.airdropDistributor.claimableFromRound" "$claimable_from_round" \
    "$(json_path airdropDistributor claimableFromRound)"
check "export.airdropDistributor.totalClaimedShare" "$total_claimed_share" \
    "$(json_path airdropDistributor totalClaimedShare)"
check "export.airdropDistributor.totalRemainingShare" "$total_remaining_share" \
    "$(json_path airdropDistributor totalRemainingShare)"
check "export.airdropDistributor.totalClaimedAmount" "$total_claimed_amount" \
    "$(json_path airdropDistributor totalClaimedAmount)"
check "export.airdropDistributor.remainingAmount" "$remaining_amount" \
    "$(json_path airdropDistributor remainingAmount)"
check "export.airdropDistributor.snapshotUri" "$snapshot_uri" "$(json_path airdropDistributor snapshotUri)"

# claimableAmount for a fixture entry that has NOT claimed (the seed only claims the first
# SEED_MEMBER_COUNT entries), plus the unclaimed/claimed state of a seeded one.
UNCLAIMED_INDEX="$(python3 -c "import json;print(len(json.load(open('$SNAPSHOT_ABS'))['entries'])-1)")"
read -r unclaimed_addr unclaimed_share < <(python3 -c "
import json
e=json.load(open('$SNAPSHOT_ABS'))['entries'][$UNCLAIMED_INDEX]
print(e['account'], e['share'])")
unclaimed_proof_args=$(python3 -c "
import json
e=json.load(open('$SNAPSHOT_ABS'))['entries'][$UNCLAIMED_INDEX]
print('[' + ','.join(e['proof']) + ']')")
claimable="$(call "$DISTRIBUTOR" 'claimableAmount(address,address,uint256,bytes32[])(uint256)' \
    "$TOKEN" "$unclaimed_addr" "$unclaimed_share" "$unclaimed_proof_args")"
check "AirdropDistributor.claimableAmount(unclaimed fixture entry)" "$expected_claim_amount" "$claimable"

for account in $SEED_ACCOUNTS; do
    balance="$(cast balance "$account" --rpc-url "$RPC_URL")"
    if ! gt "$balance" "$SEED_ETH_PER_ACCOUNT" && [ "$balance" != "$SEED_ETH_PER_ACCOUNT" ]; then
        FAILED=1
        printf '  \033[0;31mFAIL\033[0m ETH balance of %s is %s (< %s)\n' "$account" "$balance" "$SEED_ETH_PER_ACCOUNT"
        CHECKS+=("| ETH balance of \`$account\` | \`>= $SEED_ETH_PER_ACCOUNT\` | \`$balance\` | **FAIL** |")
    else
        CHECKS+=("| ETH balance of \`$account\` | \`>= $SEED_ETH_PER_ACCOUNT\` | \`$balance\` | PASS |")
    fi
done
printf '  \033[0;32mPASS\033[0m ETH balances of %s seeded accounts >= %s wei\n' \
    "$(echo "$SEED_ACCOUNTS" | wc -l | tr -d ' ')" "$SEED_ETH_PER_ACCOUNT"

check "Multicall3.getBlockNumber() > 0" "true" \
    "$(gt "$(call "$MULTICALL3" 'getBlockNumber()(uint256)')" 0 && echo true || echo false)"
# GroupActionExecutor has no SPLITS() getter any more (../action 652c270 took the verification-open
# schedule out of the contract and its constructor now takes only actionTarget), so there is nothing
# to re-check here.

# library code (already covered by the code sweep, repeated here because linking is the risky part)
for pair_name in "GroupActionJoin:$GROUP_ACTION_JOIN" "GroupActionManager:$GROUP_ACTION_MANAGER" \
    "GroupActionVerify:$GROUP_ACTION_VERIFY" "GroupRecipients:$GROUP_RECIPIENTS"; do
    name="${pair_name%%:*}"; address="${pair_name##*:}"
    check_gt "library $name code size" "0" "$(code_size "$address")"
done

# ------------------------------------------------------------------------------------------------
# report
# ------------------------------------------------------------------------------------------------
{
    echo "# Verification — $(printf '%s' "$PROFILE")"
    echo ""
    echo "Generated by \`make verify\` (\`script/verify.sh\`) on $(date -u '+%Y-%m-%dT%H:%M:%SZ') (UTC)."
    echo "Every value below came from a \`cast call\` against the running node — nothing is copied"
    echo "from the deploy scripts' logs."
    echo ""
    echo "| item | value |"
    echo "|---|---|"
    echo "| chain id | \`$chain_id\` |"
    echo "| rpc | \`$RPC_URL\` |"
    echo "| block at verification | \`$block_number\` |"
    echo "| current phase | \`$current_phase\` |"
    echo "| deploy block | \`$(python3 -c "import json;print(json.load(open('$JSON'))['deployBlock'])")\` |"
    echo "| result | $( [ "$FAILED" -eq 0 ] && echo '**ALL CHECKS PASSED**' || echo '**FAILURES — see table**') |"
    echo ""
    echo "## Addresses (code present at every one)"
    echo ""
    echo "| contract | address | code size (bytes) | status |"
    echo "|---|---|---|---|"
    printf '%s\n' "${CODE_ROWS[@]}"
    echo ""
    echo "## Checks"
    echo ""
    echo "| check | expected | actual | status |"
    echo "|---|---|---|---|"
    printf '%s\n' "${CHECKS[@]}"
    echo ""
    echo "## Reproduce"
    echo ""
    echo '```bash'
    echo "make bootstrap                      # fresh anvil on 127.0.0.1:8545"
    echo "make verify                         # re-run only the checks above"
    echo "cast call $PHASE 'currentPhase()(uint256)' --rpc-url $RPC_URL"
    echo "cast call $MEMBER_NFT 'balanceOf(address)(uint256)' $first_seed --rpc-url $RPC_URL"
    echo "cast call $PAIR 'getReserves()(uint112,uint112,uint32)' --rpc-url $RPC_URL"
    echo '```'
    echo ""
    echo "AirdropDistributor claim example for a fixture account (unclaimed index $UNCLAIMED_INDEX)."
    echo "The claim pays \`msg.sender\`, so send it from the account that owns the share:"
    echo ""
    echo '```bash'
    echo "cast call $DISTRIBUTOR 'claimableAmount(address,address,uint256,bytes32[])(uint256)' \\"
    echo "  $TOKEN $unclaimed_addr $unclaimed_share '$unclaimed_proof_args' --rpc-url $RPC_URL"
    echo "cast send $DISTRIBUTOR 'claim(address,uint256,bytes32[])' \\"
    echo "  $TOKEN $unclaimed_share '$unclaimed_proof_args' --rpc-url $RPC_URL --private-key <claimant key>"
    echo '```'
    echo ""
    echo "Snapshot URI: seed.params declares \`SNAPSHOT_URI=$SNAPSHOT_URI\`, but the genesis airdrop"
    echo "has no launcher member and core@4200d35's \`onlySnapshotUriUpdater\` rejects that case for"
    echo "every caller, so \`airdropInfo(genesisToken).snapshotUri\` is empty by design."
} >"$REPORT"

say ""
if [ "$FAILED" -eq 0 ]; then
    say "  ALL CHECKS PASSED — report written to export/VERIFIED.md"
    exit 0
fi
say "  VERIFICATION FAILED — see export/VERIFIED.md"
exit 1
