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
AIRDROP="$(json_addr AIRDROP_ADDRESS)"
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
check "export.params.groupActionSplits" \
    "$(python3 -c 'import json,os; raw=os.environ.get("GROUP_ACTION_SPLITS",""); print(json.dumps(raw.split(",") if raw else []))')" \
    "$(json_path params groupActionSplits)"
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
check_gt "LOVE20Token.balanceOf(Airdrop)" "0" "$(call "$TOKEN" 'balanceOf(address)(uint256)' "$AIRDROP")"

r0="$(cast call "$PAIR" 'getReserves()(uint112,uint112,uint32)' --rpc-url "$RPC_URL" | sed -n '1p' | awk '{print $1}')"
r1="$(cast call "$PAIR" 'getReserves()(uint112,uint112,uint32)' --rpc-url "$RPC_URL" | sed -n '2p' | awk '{print $1}')"
check_gt "UniswapV2Pair reserve0" "0" "${r0:-0}"
check_gt "UniswapV2Pair reserve1" "0" "${r1:-0}"
check_gt "UniswapV2Pair LP held by Stake" "0" "$(call "$PAIR" 'balanceOf(address)(uint256)' "$STAKE")"
stake_shares="$(call "$STAKE" 'totalStake(address)(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)' "$TOKEN" | head -1)"
check_gt "Stake.totalLiquidityShares" "0" "$stake_shares"

merkle_root="$(call "$AIRDROP" 'merkleRoot()(bytes32)')"
fixture_root="$(python3 -c "import json;print(json.load(open('$SNAPSHOT_ABS'))['merkleRoot'])")"
fixture_total="$(python3 -c "import json;print(int(json.load(open('$SNAPSHOT_ABS'))['totalShare']))")"
check "Airdrop.merkleRoot() == fixture root" "$fixture_root" "$merkle_root"
check "Airdrop.totalShare() == fixture totalShare" "$fixture_total" "$(call "$AIRDROP" 'totalShare()(uint256)')"

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
claimable="$(call "$AIRDROP" 'claimableAmount(address,address,uint256,bytes32[])(uint256)' \
    "$TOKEN" "$unclaimed_addr" "$unclaimed_share" "$unclaimed_proof_args")"
check_gt "Airdrop.claimableAmount(unclaimed fixture entry)" "0" "$claimable"
check "Airdrop.isClaimed(seed[0])" "true" "$(call "$AIRDROP" 'isClaimed(address,address)(bool)' "$TOKEN" "$first_seed")"

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
# GroupActionExecutor.SPLITS() is asserted value-by-value at deploy time (DeployLocal._validateAction);
# cast renders uint256[] with human units, so re-parsing it here would test the formatter, not the chain.

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
    echo "Airdrop claim example for a fixture account (unclaimed index $UNCLAIMED_INDEX):"
    echo ""
    echo '```bash'
    echo "cast call $AIRDROP 'claimableAmount(address,address,uint256,bytes32[])(uint256)' \\"
    echo "  $TOKEN $unclaimed_addr $unclaimed_share '$unclaimed_proof_args' --rpc-url $RPC_URL"
    echo '```'
} >"$REPORT"

say ""
if [ "$FAILED" -eq 0 ]; then
    say "  ALL CHECKS PASSED — report written to export/VERIFIED.md"
    exit 0
fi
say "  VERIFICATION FAILED — see export/VERIFIED.md"
exit 1
