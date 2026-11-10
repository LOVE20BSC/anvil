#!/usr/bin/env python3
"""Build the frontend-facing export from a finished deployment.

Inputs:
    params/<profile>/*.params                     the authoritative token/phase/seed/split values
    export/deployments/<profile>.addresses.json   flat {UPPER_SNAKE -> 0x...} written by DeployLocal
    export/libraries.json                         the four CREATE'd action libraries
    broadcast/DeployLocal.s.sol/31337/runLocal-latest.json     deployer + per-tx block numbers
    broadcast/DeployLibraries.s.sol/31337/runLibraries-latest.json
    fixtures/airdrop/<profile>.json               merkle root / total share / provenance
    the running node (`RPC_URL`, or the profile endpoint from network.params) for factory.feeTo()

Outputs:
    export/deployments/<profile>.json   one file with chainId, deploy block, every contract address
                                        + the block it was deployed in + the airdrop/univ2 metadata
    export/abis/<Contract>.json         the `abi` array only, for the contracts the frontend calls
    export/airdrop/<profile>.json       copy of the snapshot so the frontend never reads fixtures/

The metadata is data, not an echo of whatever environment happened to be set: the profile's params
files are parsed here, the deployer is taken from the deploy receipts, and feeTo() is called on the
factory. Missing inputs fail loudly instead of writing ""/0 placeholders that a frontend would
silently consume. This also means `python3 script/export.py` is self-contained for a valid profile
(only `RPC_URL` needs to be exported when the chain is not on the profile's default endpoint).

ABI provenance: the sibling repositories' own build output (`<repo>/out/<File>.sol/<Contract>.json`,
top-level `abi`). Those directories are READ-ONLY inputs; this script never builds in them. If one is
missing, it fails with the exact recipe (copy the repo to a throwaway directory, `forge build` there,
point ABIS_DIR_* at it) instead of writing into the sibling checkout.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"

# The same order as load_params() in script/local.sh. Later files do not override keys from earlier
# ones in practice (every key is unique), but the order is kept identical so a future shared key
# behaves the same way here as it does for the deploy scripts.
PARAM_FILES = ("network", "accounts", "dex", "multicall3", "airdrop", "core", "action", "group-chat", "seed")

# ------------------------------------------------------------------------------------------------
# contract name -> the org-convention address key it is exported under
# ------------------------------------------------------------------------------------------------
CONTRACTS = {
    "WETH9": ("WETH_ADDRESS", "uniswap"),
    "UniswapV2Factory": ("UNISWAP_V2_FACTORY_ADDRESS", "uniswap"),
    "UniswapV2Router02": ("UNISWAP_V2_ROUTER02_ADDRESS", "uniswap"),
    "UniswapV2Pair": ("UNISWAP_V2_PAIR_ADDRESS", "uniswap"),
    "Multicall3": ("MULTICALL3_ADDRESS", "infra"),
    "Airdrop": ("AIRDROP_ADDRESS", "core"),
    "LOVE20Token": ("LOVE20_TOKEN_ADDRESS", "core"),
    "Phase": ("PHASE_ADDRESS", "core"),
    "Launch": ("LAUNCH_ADDRESS", "core"),
    "MemberNFT": ("MEMBER_NFT_ADDRESS", "core"),
    "Stake": ("STAKE_ADDRESS", "core"),
    "Submit": ("SUBMIT_ADDRESS", "core"),
    "Vote": ("VOTE_ADDRESS", "core"),
    "Mint": ("MINT_ADDRESS", "core"),
    "ActionTarget": ("ACTION_TARGET_ADDRESS", "action"),
    "LpExecutor": ("LP_EXECUTOR_ADDRESS", "action"),
    "GroupActionExecutor": ("GROUP_ACTION_EXECUTOR_ADDRESS", "action"),
    "GroupServiceExecutor": ("GROUP_SERVICE_EXECUTOR_ADDRESS", "action"),
    "GroupAdmin": ("GROUP_ADMIN_ADDRESS", "group-chat"),
    "GroupChat": ("GROUP_CHAT_ADDRESS", "group-chat"),
    "GroupChatBanList": ("GROUP_CHAT_BAN_LIST_ADDRESS", "group-chat"),
    "AdminBanSource": ("ADMIN_BAN_SOURCE_ADDRESS", "group-chat"),
    "GovVotedBanSource": ("GOV_VOTED_BAN_SOURCE_ADDRESS", "group-chat"),
    "GroupMember": ("GROUP_MEMBER_ADDRESS", "group-chat"),
    "GroupMemberScope": ("GROUP_MEMBER_SCOPE_ADDRESS", "group-chat"),
    "GroupJoinScopeSource": ("GROUP_JOIN_SCOPE_SOURCE_ADDRESS", "group-chat"),
    "TokenMainManager": ("TOKEN_MAIN_MANAGER_ADDRESS", "group-chat"),
    "TokenGovManager": ("TOKEN_GOV_MANAGER_ADDRESS", "group-chat"),
    "TokenActionGovManager": ("TOKEN_ACTION_GOV_MANAGER_ADDRESS", "group-chat"),
    "TokenActionMainManager": ("TOKEN_ACTION_MAIN_MANAGER_ADDRESS", "group-chat"),
}

# The libraries are exported too: a frontend that decodes executor calls needs them in the address
# book, and `make verify` code-checks every exported address (so this keeps them covered).
LIBRARIES = {
    "GroupActionJoin": "GROUP_ACTION_JOIN_LIBRARY_ADDRESS",
    "GroupActionManager": "GROUP_ACTION_MANAGER_LIBRARY_ADDRESS",
    "GroupActionVerify": "GROUP_ACTION_VERIFY_LIBRARY_ADDRESS",
    "GroupRecipients": "GROUP_RECIPIENTS_LIBRARY_ADDRESS",
}

# ------------------------------------------------------------------------------------------------
# ABI sources. `None` means "this repo's own out/". Everything else is a sibling, read-only.
# ------------------------------------------------------------------------------------------------
CORE_OUT = Path(os.environ.get("CORE_OUT", ROOT.parent / "core" / "out"))
ACTION_OUT = Path(os.environ.get("ACTION_OUT", ROOT.parent / "action" / "out"))
GROUP_CHAT_OUT = Path(os.environ.get("GROUP_CHAT_OUT", ROOT.parent / "group-chat" / "out"))
DEX_BUILD = Path(os.environ.get("DEX_BUILD", ROOT.parent / "dex" / "build"))

ABI_SOURCES = {
    # core
    "LOVE20Token": CORE_OUT / "LOVE20Token.sol" / "LOVE20Token.json",
    "Phase": CORE_OUT / "Phase.sol" / "Phase.json",
    "Launch": CORE_OUT / "Launch.sol" / "Launch.json",
    "MemberNFT": CORE_OUT / "MemberNFT.sol" / "MemberNFT.json",
    "Stake": CORE_OUT / "Stake.sol" / "Stake.json",
    "Submit": CORE_OUT / "Submit.sol" / "Submit.json",
    "Vote": CORE_OUT / "Vote.sol" / "Vote.json",
    "Mint": CORE_OUT / "Mint.sol" / "Mint.json",
    # action
    "ActionTarget": ACTION_OUT / "ActionTarget.sol" / "ActionTarget.json",
    "LpExecutor": ACTION_OUT / "LpExecutor.sol" / "LpExecutor.json",
    "GroupActionExecutor": ACTION_OUT / "GroupActionExecutor.sol" / "GroupActionExecutor.json",
    "GroupServiceExecutor": ACTION_OUT / "GroupServiceExecutor.sol" / "GroupServiceExecutor.json",
    # group-chat
    "GroupChat": GROUP_CHAT_OUT / "GroupChat.sol" / "GroupChat.json",
    # uniswap (published artifacts, not recompiled - see params/anvil31337_dev/dex.params)
    "UniswapV2Factory": DEX_BUILD / "core" / "UniswapV2Factory.sol" / "UniswapV2Factory.json",
    "UniswapV2Router02": DEX_BUILD / "periphery" / "UniswapV2Router02.sol" / "UniswapV2Router02.json",
    "UniswapV2Pair": DEX_BUILD / "core" / "UniswapV2Pair.sol" / "UniswapV2Pair.json",
    # this project (vendored airdrop, configurable WETH, forge-std's canonical IMulticall3 ABI)
    "Airdrop": ROOT / "out" / "Airdrop.sol" / "Airdrop.json",
    "WETH9": ROOT / "out" / "WETH9Configurable.sol" / "WETH9Configurable.json",
    "Multicall3": ROOT / "out" / "IMulticall3.sol" / "IMulticall3.json",
}

ABI_HELP = """missing ABI artifact: {path}
  That directory belongs to a sibling repository and this project never builds or writes in it.
  Rebuild it read-only in a throwaway copy instead, e.g.:
      tmp=$(mktemp -d) && rsync -a --exclude out --exclude cache --exclude broadcast "{repo}/" "$tmp/repo/" \\
        && (cd "$tmp/repo" && forge build)
  then point the matching override at that copy, e.g.
      {env_var}="$tmp/repo/out" make export
"""


def fail(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(1)


def read_json(path: Path):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return None


def run_cast(*args: str) -> str:
    """Run `cast` and return stdout; fail with the tool's own stderr if it doesn't exit 0."""
    try:
        result = subprocess.run(["cast", *args], capture_output=True, text=True)
    except FileNotFoundError:
        fail("cast not found on PATH - Foundry is required for the on-chain metadata")
    if result.returncode != 0:
        fail(f"cast {' '.join(args)} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def checksum_address(address: str) -> str:
    """EIP-55 checksum via `cast` (the address book is consumed by a JS frontend)."""
    value = run_cast("to-check-sum-address", address).strip()
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", value):
        fail(f"cast to-check-sum-address returned an unexpected value: {value!r}")
    return value


def cast_call_address(rpc_url: str, to: str, signature: str) -> str:
    """Call a view function returning one address and return it checksummed."""
    value = run_cast("call", to, signature, "--rpc-url", rpc_url).strip().splitlines()
    value = value[0].strip() if value else ""
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", value):
        fail(f"{to}.{signature} returned an unexpected value: {value!r}")
    return checksum_address(value)


def expand_params_value(value: str) -> str:
    """Mirror params_expand_value() in script/lib/params.sh (lexical 1e18 / 1_000 expansion).

    Kept identical on purpose: the deploy scripts consume the shell loader's expansion and this
    script consumes the same files, so `1e17,4e17,7e17` must become the same decimal strings in
    both. Anything that does not match the two numeric forms is returned unchanged.
    """
    items = []
    for raw in value.split(","):
        item = raw.strip()
        match = re.fullmatch(r"([0-9][0-9_]*)[eE]([0-9]+)", item)
        if match:
            item = match.group(1).replace("_", "") + "0" * int(match.group(2))
        elif re.fullmatch(r"[0-9][0-9_]*", item):
            item = item.replace("_", "")
        items.append(item)
    return ",".join(items)


def parse_params_file(path: Path) -> dict[str, str]:
    """Parse one .params file with the lexical rules documented in script/lib/params.sh."""
    values: dict[str, str] = {}
    for raw_line in path.read_text().splitlines():
        line = raw_line.lstrip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            fail(f"invalid key in {path}: {key}")
        if value.startswith(('"', "'")):
            # A whole-quoted value keeps its content verbatim (so it may contain '#').
            value = value[1:-1]
        else:
            # Remove an unquoted ` # comment` suffix, matching the shell loader.
            value = re.sub(r"[ \t]+#.*$", "", value).rstrip()
        values[key] = expand_params_value(value)
    return values


def load_params(profile: str) -> dict[str, str]:
    params: dict[str, str] = {}
    for stem in PARAM_FILES:
        path = ROOT / "params" / profile / f"{stem}.params"
        if not path.is_file():
            fail(f"missing params file: {path}")
        params.update(parse_params_file(path))
    return params


def require_param(params: dict[str, str], key: str) -> str:
    value = params.get(key, "")
    if value == "":
        fail(f"params/{os.environ.get('PROFILE', 'anvil31337_dev')}/*.params does not define {key}")
    return value


def param_uint(params: dict[str, str], key: str) -> int:
    raw = require_param(params, key)
    try:
        value = int(raw)
    except ValueError:
        fail(f"{key} is not a decimal integer: {raw!r}")
    if value < 0:
        fail(f"{key} is negative: {raw!r}")
    return value


def canonical_rpc_url(params: dict[str, str]) -> str:
    """The profile's own endpoint. Deliberately not the PORT override: it is what a fresh
    `make bootstrap` serves, so the committed export stays reproducible off this machine."""
    return f"http://{require_param(params, 'ANVIL_HOST')}:{require_param(params, 'ANVIL_PORT')}"


def deployer_from_broadcast(path: Path) -> str:
    """The actual sender of the deployment transactions, from forge's broadcast receipts.

    `DEPLOYER_ADDRESS` is derived from the mnemonic by local.sh; the broadcast is the chain-visible
    record and therefore the authority for what the frontend should call the deployer. When both
    are present they must agree, so a mnemonic/index change cannot silently mislabel an export.
    """
    data = read_json(path)
    if not data:
        fail(f"missing deploy broadcast {path} - run `make deploy` first")
    senders = {str(r.get("from", "")).lower() for r in data.get("receipts", []) if r.get("from")}
    senders.discard("")
    if len(senders) != 1:
        fail(f"{path} has {len(senders)} transaction senders, expected exactly one deployer")
    sender = senders.pop()
    expected = os.environ.get("DEPLOYER_ADDRESS", "")
    if expected and expected.lower() != sender:
        fail(f"broadcast sender {sender} disagrees with DEPLOYER_ADDRESS {expected}")
    return checksum_address(sender)


def broadcast_blocks(path: Path) -> dict[str, int]:
    """address(lowercase) -> block number, from one forge broadcast file."""
    data = read_json(path)
    if not data:
        print(f"warning: broadcast file not found: {path} (block numbers will be 0)", file=sys.stderr)
        return {}
    receipts = {r["transactionHash"].lower(): r for r in data.get("receipts", [])}
    blocks: dict[str, int] = {}

    for tx in data.get("transactions", []):
        address = tx.get("contractAddress")
        if not address:
            continue
        receipt = receipts.get((tx.get("hash") or "").lower())
        if receipt:
            blocks[address.lower()] = int(receipt["blockNumber"], 16) if isinstance(
                receipt["blockNumber"], str
            ) else int(receipt["blockNumber"])
    return blocks


def abi_env_var(path: Path) -> str:
    """Which override env var the user would set to point at a throwaway build of that repo."""
    for env_var, root in (
        ("CORE_OUT", CORE_OUT),
        ("ACTION_OUT", ACTION_OUT),
        ("GROUP_CHAT_OUT", GROUP_CHAT_OUT),
        ("DEX_BUILD", DEX_BUILD),
    ):
        if path.is_relative_to(root):
            return env_var
    return "(this repo's out/, run `make build`)"


def load_abi(name: str, path: Path, env_var: str) -> list:
    data = read_json(path)
    if data is None:
        repo = path.parents[2] if len(path.parents) > 2 else path
        print(ABI_HELP.format(path=path, repo=repo, env_var=env_var), file=sys.stderr)
        fail(f"no ABI artifact for {name}")
    abi = data.get("abi")
    if not isinstance(abi, list) or not abi:
        fail(f"{path} has no top-level abi array")
    return abi


def main() -> int:
    profile = os.environ.get("PROFILE") or "anvil31337_dev"
    params = load_params(profile)
    deployments_dir = ROOT / "export" / "deployments"
    abis_dir = ROOT / "export" / "abis"
    snapshot_path = ROOT / (params.get("AIRDROP_SNAPSHOT_FILE") or f"fixtures/airdrop/{profile}.json")

    addresses_path = deployments_dir / f"{profile}.addresses.json"
    addresses = read_json(addresses_path)
    if not addresses:
        fail(f"missing {addresses_path} - run `make deploy` first")
    chain_id = int(addresses.pop("chainId"))

    libraries = read_json(ROOT / "export" / "libraries.json") or {}
    snapshot = read_json(snapshot_path)
    if not snapshot:
        fail(f"missing airdrop snapshot {snapshot_path} - run `make fixture` first")

    blocks: dict[str, int] = {}

    # Multicall3 is published outside the forge broadcast (upstream pre-signed transaction), so its
    # block comes from the receipt recorded by script/local.sh.
    multicall3_info = read_json(deployments_dir / f"{profile}.multicall3.json")
    if multicall3_info:
        blocks[multicall3_info["address"].lower()] = int(multicall3_info["blockNumber"])

    deploy_broadcast = ROOT / "broadcast" / "DeployLocal.s.sol" / str(chain_id) / "runLocal-latest.json"
    blocks.update(broadcast_blocks(ROOT / "broadcast" / "DeployLibraries.s.sol" / str(chain_id) / "runLibraries-latest.json"))
    deploy_blocks = broadcast_blocks(deploy_broadcast)
    blocks.update(deploy_blocks)
    deploy_block = max(deploy_blocks.values()) if deploy_blocks else 0

    # ---- addresses: flat map in the org's UPPER_SNAKE convention, libraries included ----
    flat = dict(addresses)
    for name, key in LIBRARIES.items():
        if name not in libraries:
            fail(f"missing deployed library {name} in export/libraries.json")
        flat[key] = libraries[name]

    # ---- live-chain metadata: read the value, never assume it ----
    # RPC_URL is set by script/local.sh and follows a PORT override; the committed rpcUrl stays the
    # profile's canonical endpoint (see canonical_rpc_url). feeTo() is what the chain actually says:
    # the deployment passes feeToSetter = 0 to lock the protocol fee off, so a non-zero feeTo means
    # the chain does not match that intent and the export must show it (plus a warning) instead of
    # copying the factory address into the field.
    chain_rpc_url = os.environ.get("RPC_URL") or canonical_rpc_url(params)
    factory = flat["UNISWAP_V2_FACTORY_ADDRESS"]
    fee_to = cast_call_address(chain_rpc_url, factory, "feeTo()(address)")
    fee_to_setter = cast_call_address(chain_rpc_url, factory, "feeToSetter()(address)")
    if fee_to != ZERO_ADDRESS:
        print(
            f"warning: UniswapV2Factory.feeTo() is {fee_to}, not the zero address the deployment "
            f"locks in; exporting the on-chain value as-is",
            file=sys.stderr,
        )
    if fee_to_setter != ZERO_ADDRESS:
        print(
            f"warning: UniswapV2Factory.feeToSetter() is {fee_to_setter}; the profile's "
            f"FACTORY_FEE_TO_SETTER expects address(0) (protocol fee permanently off)",
            file=sys.stderr,
        )

    deployer = deployer_from_broadcast(deploy_broadcast)

    # ---- contracts: contract name -> {address, blockNumber, group} ----
    contracts = {}
    for name, (key, group) in CONTRACTS.items():
        if key not in flat:
            fail(f"address book has no {key} for contract {name}")
        address = flat[key]
        contracts[name] = {
            "address": address,
            "blockNumber": blocks.get(address.lower(), deploy_block),
            "group": group,
        }
    for name, key in LIBRARIES.items():
        address = flat[key]
        contracts[name] = {
            "address": address,
            "blockNumber": blocks.get(address.lower(), deploy_block),
            "group": "action-library",
        }

    # The root token and its pair are created inside Launch's constructor (LOVE20Token + _ensurePair),
    # so neither has a transaction of its own: attribute both to the Launch deployment block.
    contracts["LOVE20Token"]["blockNumber"] = contracts["Launch"]["blockNumber"]
    contracts["UniswapV2Pair"]["blockNumber"] = contracts["Launch"]["blockNumber"]

    # ---- params: from params/<profile>/*.params, not from ambient environment variables ----
    splits = [item for item in require_param(params, "GROUP_ACTION_SPLITS").split(",") if item]
    for split in splits:
        # params_expand_value has already turned 1e17 into decimal; reject anything else so a typo
        # cannot become a string the frontend must interpret.
        if not re.fullmatch(r"[0-9]+", split):
            fail(f"GROUP_ACTION_SPLITS contains a non-decimal entry: {split!r}")
    token_name = require_param(params, "TOKEN_NAME")
    token_symbol = require_param(params, "TOKEN_SYMBOL")

    deployment = {
        "network": profile,
        "chainId": chain_id,
        "rpcUrl": canonical_rpc_url(params),
        "deployer": deployer,
        "deployBlock": deploy_block,
        "contracts": contracts,
        "addresses": flat,
        "libraries": {name: libraries[name] for name in LIBRARIES if name in libraries},
        "uniswapV2": {
            "factory": factory,
            "router02": flat["UNISWAP_V2_ROUTER02_ADDRESS"],
            "weth": flat["WETH_ADDRESS"],
            "pair": flat["UNISWAP_V2_PAIR_ADDRESS"],
            # Queried above from factory.feeTo(); the deployment's feeToSetter = 0 lock is what
            # makes this the zero address, not an assumption baked into this script.
            "feeTo": fee_to,
            "pairInitCodeHash": "0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f",
        },
        "airdrop": {
            "address": flat["AIRDROP_ADDRESS"],
            "token": flat["LOVE20_TOKEN_ADDRESS"],
            "merkleRoot": snapshot["merkleRoot"],
            "totalShare": snapshot["totalShare"],
            "accountCount": snapshot["accountCount"],
            "sourceChainId": snapshot["sourceChainId"],
            "sourceBlockNumber": snapshot["sourceBlockNumber"],
            "sourceBurnAddress": snapshot["sourceBurnAddress"],
            "snapshotFile": f"export/airdrop/{profile}.json",
        },
        "params": {
            "tokenName": token_name,
            "tokenSymbol": token_symbol,
            "phaseOriginBlocks": param_uint(params, "PHASE_ORIGIN_BLOCKS"),
            "phaseOriginPhaseBlocks": param_uint(params, "PHASE_ORIGIN_PHASE_BLOCKS"),
            "phaseTargetSeconds": param_uint(params, "PHASE_TARGET_SECONDS"),
            "groupActionSplits": splits,
            "seedAccountCount": param_uint(params, "SEED_ACCOUNT_COUNT"),
            "seedMemberCount": param_uint(params, "SEED_MEMBER_COUNT"),
        },
    }

    deployments_dir.mkdir(parents=True, exist_ok=True)
    out_path = deployments_dir / f"{profile}.json"
    out_path.write_text(json.dumps(deployment, indent=2, sort_keys=True) + "\n")

    # ---- ABIs ----
    abis_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for name, path in ABI_SOURCES.items():
        abi = load_abi(name, path, abi_env_var(path))
        (abis_dir / f"{name}.json").write_text(json.dumps(abi, indent=2) + "\n")
        written.append(name)

    # ---- airdrop snapshot copy ----
    airdrop_dir = ROOT / "export" / "airdrop"
    airdrop_dir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(snapshot_path, airdrop_dir / f"{profile}.json")

    print(f"wrote {out_path.relative_to(ROOT)}")
    print(f"  chainId {chain_id}, deploy block {deploy_block}, {len(contracts)} contracts")
    print(f"wrote {len(written)} ABIs to export/abis/")
    print(f"wrote export/airdrop/{profile}.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
