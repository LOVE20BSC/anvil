#!/usr/bin/env bash
# Local chain orchestrator for the anvil31337_dev profile.
#
# Every step is a subcommand so `make bootstrap` is just a sequence, and a failed step can be re-run
# on its own. Nothing here writes outside this repository: the sibling checkouts are read-only
# inputs (sources and ../dex/build artifacts) and no command in this file runs inside them.
#
#   preflight    tool + sibling + artifact checks, no chain interaction
#   fixture      (re)generate fixtures/airdrop/anvil31337_dev.json
#   anvil        start anvil with params/anvil31337_dev/network.params, or reuse a healthy one
#   stop         stop the anvil started by this repo (pid file in .anvil/, or .anvil/<port>/ for
#                a non-default port; 8545 stays in the historical flat layout)
#   fresh        assert deployer nonce 0 + no Multicall3 (bootstrap also requires block 0)
#   multicall3   deploy Multicall3 at its canonical address from the upstream pre-signed tx
#   libraries    deploy the four action libraries (link targets for the executors)
#   deploy       deploy WETH + UniswapV2 + core (with its AirdropDistributor) + action + group-chat
#   seed         advance to the genesis claim round, then seed identities/liquidity/ETH
#   export       build export/deployments/anvil31337_dev.json + export/abis/*.json
#   verify       cast-level assertions over every exported address (writes export/VERIFIED.md)
#   bootstrap    preflight -> fixture -> build -> anvil -> fresh -> multicall3 -> libraries ->
#                deploy -> seed -> export -> verify -> interval mining
#
# The address book is only reproducible when the deployment starts from CREATE nonce 0 on a chain
# at block 0. `bootstrap` therefore refuses to reuse a chain: a dirty chain silently produces a
# different address set (that is exactly how the old, non-reproducible book was created). It starts
# anvil in automine mode (one transaction == one block, so even block numbers are deterministic),
# verifies the whole stack, and only then enables the 1s interval mining the frontend expects.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROFILE="${PROFILE:-anvil31337_dev}"
PARAMS_DIR="$ROOT/params/$PROFILE"
OUT_DIR="$ROOT/export"
DEPLOYMENTS_DIR="$OUT_DIR/deployments"
ABIS_DIR="$OUT_DIR/abis"
# Runtime state (pid file, logs) is per port. The default port 8545 is the developer's canonical
# "human" chain and keeps the historical flat `.anvil/` layout, so an anvil that is already running
# from an older checkout keeps its pid file working. Every other port gets its own `.anvil/<port>/`
# namespace: `make stop PORT=8555` / `make clean PORT=8555` then only ever touch the 8555 chain, and
# the frontend e2e suite can run its own bootstrap while the developer's 8545 chain keeps running.
DEFAULT_ANVIL_PORT=8545
ANVIL_DIR="$ROOT/.anvil"
ANVIL_PID_FILE="$ANVIL_DIR/anvil.pid"
ANVIL_LOG="$ANVIL_DIR/anvil.log"

# shellcheck source=script/lib/params.sh
source "$ROOT/script/lib/params.sh"

# ------------------------------------------------------------------------------------------------
# logging
# ------------------------------------------------------------------------------------------------
BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
step() { printf "${BLUE}==>${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}  ok${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}  warn${NC} %s\n" "$*"; }
die()  { printf "${RED}  error${NC} %s\n" "$*" >&2; exit 1; }

# ------------------------------------------------------------------------------------------------
# parameters
# ------------------------------------------------------------------------------------------------
load_params() {
    local files=(network accounts dex multicall3 airdrop core action group-chat seed)
    local f
    for f in "${files[@]}"; do
        params_load "$PARAMS_DIR/$f.params"
    done

    # Derived, deliberately not file keys (see network.params).
    export RPC_URL="http://${ANVIL_HOST}:${ANVIL_PORT}"
    # Pick this port's runtime namespace (see DEFAULT_ANVIL_PORT at the top). Recomputed on every
    # load_params call because ANVIL_PORT can come from the file or from a `PORT=`/`ANVIL_PORT=`
    # override; 8545 keeps the flat `.anvil/` layout for backwards compatibility.
    if [ "$ANVIL_PORT" = "$DEFAULT_ANVIL_PORT" ]; then
        ANVIL_DIR="$ROOT/.anvil"
    else
        ANVIL_DIR="$ROOT/.anvil/$ANVIL_PORT"
    fi
    ANVIL_PID_FILE="$ANVIL_DIR/anvil.pid"
    ANVIL_LOG="$ANVIL_DIR/anvil.log"
    export PROFILE
    export REPO_ROOT="$ROOT"
    export EXPORT_DIR="$OUT_DIR"
    export ADDRESSES_JSON_FILE="$DEPLOYMENTS_DIR/${PROFILE}.addresses.json"
    export LIBRARIES_JSON_FILE="$OUT_DIR/libraries.json"
    # forge/cast resolve relative paths against the project root, and fs_permissions in foundry.toml
    # are declared relative too, so the params keep relative paths. Bash checks need absolute ones.
    SNAPSHOT_ABS="$ROOT/$AIRDROP_SNAPSHOT_FILE"
    MULTICALL3_TX_ABS="$ROOT/$MULTICALL3_SIGNED_TX_FILE"

    # The deploy account is derived from the mnemonic so the key is never a committed secret.
    DEPLOYER_PRIVATE_KEY="$(cast wallet private-key --mnemonic "$SEED_MNEMONIC" --mnemonic-index "$DEPLOY_ACCOUNT_INDEX")"
    DEPLOYER_ADDRESS="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"
    export DEPLOYER_PRIVATE_KEY DEPLOYER_ADDRESS

    mkdir -p "$DEPLOYMENTS_DIR" "$ABIS_DIR" "$ANVIL_DIR"
}

require_tools() {
    local missing=()
    local tool
    for tool in forge cast anvil python3; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if [ "${#missing[@]}" -ne 0 ]; then
        die "missing required tools: ${missing[*]} (foundry lives in ~/.foundry/bin; add it to PATH)"
    fi
}

# ------------------------------------------------------------------------------------------------
# preflight
# ------------------------------------------------------------------------------------------------
# The remappings point into .siblings/<repo>, committed relative symlinks. They are what keeps solc
# from compiling the same sibling file under two different source-unit names (see README
# "Remappings"); recreate them if a checkout lost them.
ensure_symlinks() {
    local repo target
    mkdir -p "$ROOT/.siblings"
    for repo in core action group-chat libs dex; do
        target="../../$repo"
        if [ ! -e "$ROOT/.siblings/$repo" ]; then
            ln -sfn "$target" "$ROOT/.siblings/$repo"
            ok "created .siblings/$repo -> $target"
        fi
    done
}

cmd_preflight() {
    load_params
    require_tools
    step "preflight (${PROFILE}, chain ${CHAIN_ID}, rpc ${RPC_URL})"
    ensure_symlinks

    local sibling
    for sibling in core action group-chat libs dex; do
        [ -d "$ROOT/../$sibling" ] || die "missing sibling checkout: $ROOT/../$sibling (read-only input)"
    done
    ok "sibling checkouts present (core action group-chat libs dex)"

    local artifact
    for artifact in \
        "../dex/build/core/UniswapV2Factory.sol/UniswapV2Factory.json" \
        "../dex/build/core/UniswapV2Pair.sol/UniswapV2Pair.json" \
        "../dex/build/periphery/UniswapV2Router02.sol/UniswapV2Router02.json"; do
        [ -s "$ROOT/$artifact" ] || die "missing dex artifact: $artifact
    Build it in a throwaway copy, or run this in the dex repo yourself:
      make -C ../dex build
    This repo never builds ../dex for you: `make build` there writes into ../dex."
    done
    ok "dex creation bytecode artifacts present (hash-asserted during deploy)"

    [ -s "$MULTICALL3_TX_ABS" ] || die "missing Multicall3 signed-tx fixture: $MULTICALL3_SIGNED_TX_FILE"
    local tx_sha
    tx_sha="$(tr -d '\n' <"$MULTICALL3_TX_ABS" | shasum -a 256 | cut -d' ' -f1)"
    [ "$tx_sha" = "$MULTICALL3_SIGNED_TX_SHA256" ] \
        || die "Multicall3 signed-tx fixture checksum mismatch: got $tx_sha want $MULTICALL3_SIGNED_TX_SHA256"
    ok "Multicall3 signed transaction matches its pinned sha256"

    local canonical
    canonical="$(cast compute-address "$MULTICALL3_DEPLOYER_ADDRESS" --nonce "$MULTICALL3_DEPLOYER_NONCE")"
    [ "$(printf '%s' "$canonical" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$MULTICALL3_ADDRESS" | tr '[:upper:]' '[:lower:]')" ] \
        || die "CREATE(deployer,nonce) is $canonical, expected the canonical Multicall3 address $MULTICALL3_ADDRESS"
    ok "Multicall3 deployer/nonce produce the canonical address $MULTICALL3_ADDRESS"
}

# ------------------------------------------------------------------------------------------------
# fixture
# ------------------------------------------------------------------------------------------------
cmd_fixture() {
    load_params
    step "airdrop snapshot"
    python3 "$ROOT/script/gen_airdrop_fixture.py" \
        --mnemonic "$SEED_MNEMONIC" \
        --start-index "$SEED_ACCOUNT_START_INDEX" \
        --count "$SEED_ACCOUNT_COUNT" \
        --total-share "$TOTAL_SHARE" \
        --source-chain-id "$SOURCE_CHAIN_ID" \
        --source-block-number "$SOURCE_BLOCK_NUMBER" \
        --source-burn-address "$SOURCE_BURN_ADDRESS" \
        --output "$SNAPSHOT_ABS"
}

# ------------------------------------------------------------------------------------------------
# anvil
# ------------------------------------------------------------------------------------------------
rpc_chain_id() {
    cast chain-id --rpc-url "$RPC_URL" 2>/dev/null || true
}

# The bootstrap deploys in automine mode (one transaction == one block), which makes the exported
# block numbers deterministic as well as the addresses. The frontend and the phase clock need the
# profile's 1s interval mining, so it is switched on only AFTER export/verify. `make anvil` (the
# standalone developer chain) starts with it enabled immediately.
enable_interval_mining() {
    if [ "${ANVIL_BLOCK_TIME:-0}" -gt 0 ] 2>/dev/null; then
        cast rpc anvil_setIntervalMining "$ANVIL_BLOCK_TIME" --rpc-url "$RPC_URL" >/dev/null
        ok "interval mining enabled (${ANVIL_BLOCK_TIME}s per block)"
    fi
}

# Suffix for the copy-paste recovery commands: empty on the default port, ` PORT=<port>` otherwise.
# It keeps the hints correct for an automated chain on 8555 instead of telling the operator to stop
# the developer's 8545 chain by mistake.
port_arg() {
    if [ "$ANVIL_PORT" = "$DEFAULT_ANVIL_PORT" ]; then
        printf ''
    else
        printf ' PORT=%s' "$ANVIL_PORT"
    fi
}

cmd_anvil() {
    load_params
    require_tools
    step "anvil ${ANVIL_HOST}:${ANVIL_PORT} (chain ${CHAIN_ID})"

    local running_id
    running_id="$(rpc_chain_id)"
    if [ "${BOOTSTRAP_ACTIVE:-0}" = "1" ] && [ "$running_id" = "$CHAIN_ID" ]; then
        # bootstrap must own a FRESH chain. Reusing a chain that has already served a deployment
        # moves the deployer to a later nonce and silently changes every CREATE address - the exact
        # failure that produced the unreproducible address book this guard exists to prevent.
        die "a chain is already running at ${RPC_URL}; bootstrap only deploys onto a fresh chain.
    Stop it and remove all chain/build state first:
      make stop$(port_arg) && make clean$(port_arg) && make bootstrap$(port_arg)"
    fi
    if [ "$running_id" = "$CHAIN_ID" ]; then
        # Only a chain THIS repo started may be reused. Anything else on the same port belongs to
        # another project (a very common case on a developer machine), and deploying the whole stack
        # onto it would silently pollute it and produce an address book nobody can reproduce.
        # `make anvil` may reuse its own chain; `make bootstrap` deliberately does not (see above).
        local pid="" rec_host="" rec_port=""
        if [ -f "$ANVIL_PID_FILE" ]; then
            read -r pid rec_host rec_port <"$ANVIL_PID_FILE" || true
        fi
        if [ -n "$pid" ] && [ "$rec_host" = "$ANVIL_HOST" ] && [ "$rec_port" = "$ANVIL_PORT" ] \
            && kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o comm= 2>/dev/null | grep -q anvil; then
            ok "chain started by this repo is still running (pid $pid) - reusing it"
            return 0
        fi
        die "something is already serving chain ${CHAIN_ID} at ${RPC_URL}, but it was not started by this repo (no live ${ANVIL_PID_FILE#"$ROOT"/}).
    Refusing to deploy onto an unknown chain. Either stop that process yourself, or pick another port:
      make bootstrap PORT=<free port>"
    fi
    if [ -n "$running_id" ]; then
        die "${RPC_URL} answers with a different chain id (${running_id}); stop it or run with PORT=<free port>"
    fi

    : >"$ANVIL_LOG"
    # No --block-time: automine, one block per transaction. This keeps the export deterministic
    # (block numbers included); interval mining is enabled after bootstrap / immediately for
    # `make anvil`.
    nohup anvil \
        --chain-id "$CHAIN_ID" \
        --host "$ANVIL_HOST" \
        --port "$ANVIL_PORT" \
        --accounts "$ANVIL_ACCOUNTS" \
        --balance "$ANVIL_BALANCE" \
        --gas-limit "$ANVIL_GAS_LIMIT" \
        --code-size-limit "$ANVIL_CODE_SIZE_LIMIT" \
        --base-fee "$ANVIL_BASE_FEE" \
        >>"$ANVIL_LOG" 2>&1 &
    # The pid file records the endpoint too: "PID HOST PORT". A pid alone cannot prove that the
    # chain answering on this endpoint is the one this repo started.
    printf '%s %s %s\n' "$!" "$ANVIL_HOST" "$ANVIL_PORT" >"$ANVIL_PID_FILE"

    local i
    for i in $(seq 1 50); do
        if [ "$(rpc_chain_id)" = "$CHAIN_ID" ]; then
            ok "anvil up (pid $!, automine, log ${ANVIL_LOG#"$ROOT"/})"
            if [ "${BOOTSTRAP_ACTIVE:-0}" != "1" ]; then
                enable_interval_mining
            fi
            return 0
        fi
        sleep 0.2
    done
    die "anvil did not become ready on $RPC_URL - see ${ANVIL_LOG#"$ROOT"/}"
}

cmd_stop() {
    load_params
    step "stop anvil (chain ${CHAIN_ID} on ${RPC_URL})"
    if [ -f "$ANVIL_PID_FILE" ]; then
        local pid _host _port
        read -r pid _host _port <"$ANVIL_PID_FILE" || true
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" && ok "stopped pid $pid"
        else
            warn "pid $pid is not running"
        fi
        rm -f "$ANVIL_PID_FILE"
    else
        warn "no ${ANVIL_PID_FILE#"$ROOT"/} - was the chain started by this repo?"
    fi
}

# ------------------------------------------------------------------------------------------------
# fresh-chain guard
# ------------------------------------------------------------------------------------------------
# Addresses are CREATE(deployer, nonce) results. A chain that has already processed a transaction is
# not reproducible, even if it has the same chain id. This asserts the facts that make the export
# deterministic from nonce 0: the deployer has sent nothing and the canonical Multicall3 address is
# still empty (it is published by a different account, so a non-zero deployer nonce would not catch a
# half-published chain). During bootstrap it additionally requires block 0: the deployment runs in
# automine mode, and that is what makes the exported block numbers identical between clean runs.
# A standalone `make anvil` ticks blocks while it sits idle, so only bootstrap pins the height.
cmd_fresh() {
    load_params
    step "fresh-chain guard"
    local block nonce multicall_code used=0
    block="$(cast block-number --rpc-url "$RPC_URL")"
    nonce="$(cast nonce "$DEPLOYER_ADDRESS" --rpc-url "$RPC_URL")"
    multicall_code="$(cast code "$MULTICALL3_ADDRESS" --rpc-url "$RPC_URL")"
    [ "$nonce" = "0" ] || used=1
    [ "$multicall_code" = "0x" ] || used=1
    if [ "${BOOTSTRAP_ACTIVE:-0}" = "1" ] && [ "$block" != "0" ]; then
        used=1
    fi
    if [ "$used" = "1" ]; then
        die "refusing to deploy onto a used chain: block=$block, deployer nonce=$nonce, Multicall3 code=${#multicall_code} hex chars.
    A non-fresh chain changes every CREATE address and produces an address book that nobody can
    reproduce. Reset the chain and every build artifact first:
      make stop && make clean && make bootstrap"
    fi
    ok "fresh enough (${DEPLOYER_ADDRESS} nonce 0, Multicall3 absent, block $block)"
}

# ------------------------------------------------------------------------------------------------
# multicall3 (canonical address, upstream pre-signed transaction)
# ------------------------------------------------------------------------------------------------
cmd_multicall3() {
    load_params
    step "Multicall3 at ${MULTICALL3_ADDRESS}"

    local code
    code="$(cast code "$MULTICALL3_ADDRESS" --rpc-url "$RPC_URL")"
    if [ "$code" != "0x" ]; then
        ok "already deployed ($(( (${#code} - 2) / 2 )) bytes) - skipping"
        return 0
    fi

    # anvil-only cheat: the upstream deployer EOA starts empty on a fresh chain.
    cast rpc anvil_setBalance "$MULTICALL3_DEPLOYER_ADDRESS" \
        "$(cast to-hex "$MULTICALL3_DEPLOYER_FUNDING")" --rpc-url "$RPC_URL" >/dev/null
    ok "funded deployer ${MULTICALL3_DEPLOYER_ADDRESS} with ${MULTICALL3_DEPLOYER_FUNDING} wei"

    local tx blk_before blk_after
    tx="$(tr -d '\n' <"$MULTICALL3_TX_ABS")"
    blk_before="$(cast block-number --rpc-url "$RPC_URL")"
    cast publish "$tx" --rpc-url "$RPC_URL" >/dev/null
    ok "published upstream signed transaction (CREATE from ${MULTICALL3_DEPLOYER_ADDRESS}, nonce ${MULTICALL3_DEPLOYER_NONCE})"

    code="$(cast code "$MULTICALL3_ADDRESS" --rpc-url "$RPC_URL")"
    [ "$code" != "0x" ] || die "no code at $MULTICALL3_ADDRESS after publishing the transaction"
    # Functional check: Multicall3.getBlockNumber() must answer. This proves the runtime code is the
    # real Multicall3 and not an unrelated contract that happened to be created there.
    local block
    block="$(cast call "$MULTICALL3_ADDRESS" "getBlockNumber()(uint256)" --rpc-url "$RPC_URL")"
    [ "$block" -gt 0 ] || die "Multicall3.getBlockNumber() returned $block"
    ok "code present ($(( (${#code} - 2) / 2 )) bytes), getBlockNumber() = $block"

    # Multicall3 is published outside the forge broadcast, so its block number is recorded here for
    # script/export.py (which otherwise only sees DeployLocal's transactions). The block is found by
    # asking for the code AT a block: anvil keeps historical state, and the first block that reports
    # code is exactly the creation block. (`cast publish` prints the block hash, not the tx hash, so
    # parsing its output would be a trap.)
    blk_after="$(cast block-number --rpc-url "$RPC_URL")"
    local mc_block="" b
    for b in $(seq "$blk_before" $((blk_after + 2))); do
        if [ "$(cast code "$MULTICALL3_ADDRESS" --block "$b" --rpc-url "$RPC_URL")" != "0x" ]; then
            mc_block="$b"
            break
        fi
    done
    [ -n "$mc_block" ] || mc_block="$blk_after"
    printf '{"address": "%s", "blockNumber": %s}\n' "$MULTICALL3_ADDRESS" "$mc_block" \
        >"$DEPLOYMENTS_DIR/${PROFILE}.multicall3.json"
    ok "recorded deployment block ${mc_block}"
}

# ------------------------------------------------------------------------------------------------
# linked libraries
# ------------------------------------------------------------------------------------------------
cmd_libraries() {
    load_params
    step "action linked libraries"
    # The libs are deployed with plain CREATE, so a re-run on a used chain just moves them; that is
    # fine because the linking addresses are recomputed from that run's output every time.
    forge script script/DeployLibraries.s.sol:DeployLibraries \
        --sig "runLibraries()" \
        --rpc-url "$RPC_URL" \
        --private-key "$DEPLOYER_PRIVATE_KEY" \
        --broadcast --legacy --slow \
        >"$ANVIL_DIR/deploy-libraries.log" 2>&1 \
        || { tail -40 "$ANVIL_DIR/deploy-libraries.log" >&2; die "library deployment failed (see .anvil/deploy-libraries.log)"; }

    local name addr
    for name in GroupActionJoin GroupActionManager GroupActionVerify GroupRecipients; do
        addr="$(python3 -c "import json,sys;print(json.load(open('$LIBRARIES_JSON_FILE'))['$name'])")"
        cast code "$addr" --rpc-url "$RPC_URL" | grep -qv '^0x$' || die "no code at library $name ($addr)"
        ok "$name $addr"
    done
}

# Build the forge `--libraries` argument: "<solc source unit>:<library name>:<address>".
#
# The four entries are ALWAYS emitted, in a fixed order, from export/libraries.json. They are not
# derived from the current out/ artifacts on purpose: `forge build --libraries ...` (and a previous
# `forge script --libraries ...`) links the addresses INTO the cached artifacts and drops their link
# references, so deriving the list from the artifacts would silently shrink it after the first run
# and leave a stale address baked into the executor bytecode. The list is static; the artifacts are
# only used as a cross-check that the source unit names have not changed.
link_args() {
    python3 - "$ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
libs = json.loads((root / "export/libraries.json").read_text())
names = ["GroupActionJoin", "GroupActionManager", "GroupActionVerify", "GroupRecipients"]
entries = []
for name in names:
    if name not in libs:
        raise SystemExit(f"export/libraries.json has no address for {name}")
    entries.append(f".siblings/action/src/{name}.sol:{name}:{libs[name]}")

for artifact in ("GroupActionExecutor", "GroupServiceExecutor"):
    refs = json.loads((root / "out" / f"{artifact}.sol" / f"{artifact}.json").read_text())["bytecode"].get(
        "linkReferences", {}
    )
    for source_unit, contracts in refs.items():
        for name in contracts:
            if name not in libs:
                raise SystemExit(f"{artifact} needs linked library {name} but it was not deployed")
            expected = f".siblings/action/src/{name}.sol"
            if source_unit != expected:
                raise SystemExit(f"unexpected source unit for {name}: {source_unit} != {expected}")
print(",".join(entries))
PY
}

# ------------------------------------------------------------------------------------------------
# deploy
# ------------------------------------------------------------------------------------------------
cmd_deploy() {
    load_params
    step "deploy (WETH -> UniswapV2 -> core [Phase, AirdropDistributor, Launch, ...] -> action -> group-chat)"
    [ -s "$LIBRARIES_JSON_FILE" ] || die "missing $LIBRARIES_JSON_FILE - run 'make libraries' first"
    [ -s "$SNAPSHOT_ABS" ] || die "missing $AIRDROP_SNAPSHOT_FILE - run 'make fixture' first"

    local libs
    libs="$(link_args)"
    # NOTE: the addresses are passed through FOUNDRY_LIBRARIES, not `--libraries`. In forge 1.8.1 the
    # CLI flag splits its whole value on ':' and therefore accepts exactly ONE library per invocation
    # ("failed to parse, too many arguments passed" otherwise), while the config env var accepts the
    # comma-separated list. Same parser, same result, working syntax.
    FOUNDRY_LIBRARIES="$libs" forge script script/DeployLocal.s.sol:DeployLocal \
        --sig "runLocal()" \
        --rpc-url "$RPC_URL" \
        --private-key "$DEPLOYER_PRIVATE_KEY" \
        --broadcast --legacy --slow \
        >"$ANVIL_DIR/deploy.log" 2>&1 \
        || { grep -v '^\s*$' "$ANVIL_DIR/deploy.log" | tail -40 >&2; die "deployment failed (see .anvil/deploy.log)"; }
    grep -E "^(WETH|UniswapV2|Airdrop|Phase|Launch|MemberNFT|Stake|Submit|Vote|Mint|ActionTarget|LpExecutor|Group|Token)" \
        "$ANVIL_DIR/deploy.log" | sed 's/^/  /' || true
    ok "deployed; address book written to $ADDRESSES_JSON_FILE"
}

# ------------------------------------------------------------------------------------------------
# seed
# ------------------------------------------------------------------------------------------------
# AirdropDistributor records claimableFromRound = max(phase at deploy, 1) + claim delay. The
# bootstrap deploys in phase 1 and the seed runs immediately, so on this profile every claim would
# revert ClaimRoundNotReached until phase 2. Mining the gap is chain control, not state forgery:
# it is the local equivalent of waiting for the round. It happens AFTER the DeployLocal broadcast,
# so the exported addresses/block numbers (read from that broadcast) are unchanged.
advance_to_claim_round() {
    local distributor token phase_addr claimable phase origin_blocks origin_phase_blocks
    local target_block current_block delta
    distributor="$(python3 -c "import json;print(json.load(open('$ADDRESSES_JSON_FILE'))['AIRDROP_DISTRIBUTOR_ADDRESS'])")"
    token="$(python3 -c "import json;print(json.load(open('$ADDRESSES_JSON_FILE'))['LOVE20_TOKEN_ADDRESS'])")"
    phase_addr="$(python3 -c "import json;print(json.load(open('$ADDRESSES_JSON_FILE'))['PHASE_ADDRESS'])")"

    # core@4200d35 exposes airdropInfo(token) instead of claimableFromRoundByTokenAddress; --json
    # keeps the tuple parseable (claimableFromRound is field index 2).
    claimable="$(cast call "$distributor" \
        'airdropInfo(address)((address,bytes32,uint256,uint256,uint256,uint256,uint256,string))' \
        "$token" --rpc-url "$RPC_URL" --json \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)[0][2])' 2>/dev/null || true)"
    [ -n "$claimable" ] && [ "$claimable" != "0" ] \
        || die "AirdropDistributor has no genesis claim round - did the core deployment configure it?"
    phase="$(cast call "$phase_addr" 'currentPhase()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')"
    if [ "$phase" -ge "$claimable" ]; then
        ok "already at claim round (phase $phase >= $claimable)"
        return 0
    fi

    origin_blocks="$(cast call "$phase_addr" 'ORIGIN_BLOCKS()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')"
    origin_phase_blocks="$(cast call "$phase_addr" 'ORIGIN_PHASE_BLOCKS()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')"
    target_block=$((origin_blocks + (claimable - 1) * origin_phase_blocks))
    current_block="$(cast block-number --rpc-url "$RPC_URL")"
    delta=$((target_block - current_block))
    [ "$delta" -gt 0 ] || die "cannot reach claim round $claimable from block $current_block"
    cast rpc anvil_mine "$(cast to-hex "$delta")" --rpc-url "$RPC_URL" >/dev/null
    phase="$(cast call "$phase_addr" 'currentPhase()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')"
    [ "$phase" -ge "$claimable" ] || die "mined $delta blocks but phase is $phase < $claimable"
    ok "mined $delta blocks to reach claim round ($phase >= $claimable)"
}

cmd_seed() {
    load_params
    step "seed (advance to claim round, airdrop claims, MemberNFTs, liquidity, ETH balances)"
    advance_to_claim_round
    forge script script/SeedFlow.s.sol:SeedFlow \
        --sig "runSeed()" \
        --rpc-url "$RPC_URL" \
        --private-key "$DEPLOYER_PRIVATE_KEY" \
        --broadcast --legacy --slow \
        >"$ANVIL_DIR/seed.log" 2>&1 \
        || { grep -v '^\s*$' "$ANVIL_DIR/seed.log" | tail -40 >&2; die "seeding failed (see .anvil/seed.log)"; }
    grep -E "^  (member|liquidity|airdrop|eth|pair|total)" "$ANVIL_DIR/seed.log" | sed 's/^/  /' || true
    ok "seeded"
}

# ------------------------------------------------------------------------------------------------
# export / verify
# ------------------------------------------------------------------------------------------------
cmd_export() {
    load_params
    step "export"
    python3 "$ROOT/script/export.py"
    ok "export/deployments/${PROFILE}.json + export/abis/*.json"
}

cmd_verify() {
    load_params
    step "verify"
    bash "$ROOT/script/verify.sh"
}

cmd_build() {
    load_params
    step "build (siblings are compiled read-only)"
    forge build
    ok "forge build"
}

cmd_clean() {
    load_params
    # Never leave an anvil running without its pid file: the next bootstrap would either attach to
    # this used chain (reproducibility bug) or refuse it as "unknown". Stop only the chain this repo
    # started; a foreign process on the same port is left alone and reported by the next bootstrap.
    if [ -f "$ANVIL_PID_FILE" ]; then
        cmd_stop
    fi
    step "clean (chain ${CHAIN_ID} on ${RPC_URL})"
    rm -rf "$ROOT/out" "$ROOT/cache" "$ROOT/broadcast"
    rm -rf "$DEPLOYMENTS_DIR" "$ABIS_DIR" "$OUT_DIR/libraries.json" "$OUT_DIR/VERIFIED.md"
    # Runtime state is per port (see DEFAULT_ANVIL_PORT): cleaning the default 8545 chain must not
    # wipe `.anvil/8555/` (the frontend e2e chain's pid/log) and cleaning 8555 must not touch the
    # developer's flat `.anvil/`. Exports/build output above are shared and are regenerated by the
    # next bootstrap.
    if [ "$ANVIL_DIR" = "$ROOT/.anvil" ]; then
        if [ -d "$ANVIL_DIR" ]; then
            find "$ANVIL_DIR" -maxdepth 1 -type f -delete
        fi
        ok "removed out/ cache/ broadcast/ .anvil runtime files and exported artifacts (other ports' .anvil/<port>/ kept)"
    else
        rm -rf "$ANVIL_DIR"
        ok "removed out/ cache/ broadcast/ ${ANVIL_DIR#"$ROOT"/} and exported artifacts"
    fi
}

# ------------------------------------------------------------------------------------------------
# bootstrap
# ------------------------------------------------------------------------------------------------
cmd_bootstrap() {
    # Set before cmd_anvil: bootstrap refuses to reuse any running chain, and starts anvil in
    # automine mode so that one transaction == one block (deterministic addresses AND block numbers).
    export BOOTSTRAP_ACTIVE=1
    cmd_preflight
    cmd_fixture
    cmd_build
    cmd_anvil
    cmd_fresh
    cmd_multicall3
    cmd_libraries
    cmd_deploy
    cmd_seed
    cmd_export
    cmd_verify
    # The export is complete and deterministic; now hand the chain to the frontend with the
    # profile's block interval.
    enable_interval_mining
    printf "\n${GREEN}bootstrap complete${NC} - chain %s at %s, address book export/deployments/%s.json\n" \
        "$CHAIN_ID" "$RPC_URL" "$PROFILE"
}

usage() {
    sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
    local cmd="${1:-}"
    case "$cmd" in
        preflight) cmd_preflight ;;
        fixture) cmd_fixture ;;
        anvil) cmd_anvil ;;
        stop) cmd_stop ;;
        fresh) cmd_fresh ;;
        multicall3) cmd_multicall3 ;;
        libraries) cmd_libraries ;;
        deploy) cmd_deploy ;;
        seed) cmd_seed ;;
        export) cmd_export ;;
        verify) cmd_verify ;;
        build) cmd_build ;;
        clean) cmd_clean ;;
        bootstrap) cmd_bootstrap ;;
        '' | -h | --help | help) usage ;;
        *) die "unknown subcommand: $cmd (try --help)" ;;
    esac
}

main "$@"
