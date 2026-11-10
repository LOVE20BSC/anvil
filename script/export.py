#!/usr/bin/env python3
"""Build the frontend-facing export from a finished deployment.

Inputs (all produced by script/local.sh):
    export/deployments/<profile>.addresses.json   flat {UPPER_SNAKE -> 0x...} written by DeployLocal
    export/libraries.json                         the four CREATE'd action libraries
    broadcast/DeployLocal.s.sol/31337/runLocal-latest.json     per-tx block numbers
    broadcast/DeployLibraries.s.sol/31337/runLibraries-latest.json
    fixtures/airdrop/<profile>.json               merkle root / total share / provenance

Outputs:
    export/deployments/<profile>.json   one file with chainId, deploy block, every contract address
                                        + the block it was deployed in + the airdrop/univ2 metadata
    export/abis/<Contract>.json         the `abi` array only, for the contracts the frontend calls
    export/airdrop/<profile>.json       copy of the snapshot so the frontend never reads fixtures/

ABI provenance: the sibling repositories' own build output (`<repo>/out/<File>.sol/<Contract>.json`,
top-level `abi`). Those directories are READ-ONLY inputs; this script never builds in them. If one is
missing, it fails with the exact recipe (copy the repo to a throwaway directory, `forge build` there,
point ABIS_DIR_* at it) instead of writing into the sibling checkout.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

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
    deployments_dir = ROOT / "export" / "deployments"
    abis_dir = ROOT / "export" / "abis"
    snapshot_path = ROOT / os.environ.get("AIRDROP_SNAPSHOT_FILE", f"fixtures/airdrop/{profile}.json")
    include_seed = os.environ.get("SEED_ACCOUNT_COUNT")

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

    blocks.update(broadcast_blocks(ROOT / "broadcast" / "DeployLibraries.s.sol" / str(chain_id) / "runLibraries-latest.json"))
    deploy_blocks = broadcast_blocks(ROOT / "broadcast" / "DeployLocal.s.sol" / str(chain_id) / "runLocal-latest.json")
    blocks.update(deploy_blocks)
    deploy_block = max(deploy_blocks.values()) if deploy_blocks else 0

    # ---- addresses: flat map in the org's UPPER_SNAKE convention, libraries included ----
    flat = dict(addresses)
    for name, key in LIBRARIES.items():
        if name not in libraries:
            fail(f"missing deployed library {name} in export/libraries.json")
        flat[key] = libraries[name]

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

    def env_uint(name: str, default: int = 0) -> int:
        raw = os.environ.get(name, "")
        return int(raw) if raw else default

    deployment = {
        "network": profile,
        "chainId": chain_id,
        "rpcUrl": os.environ.get("RPC_URL", ""),
        "deployer": os.environ.get("DEPLOYER_ADDRESS", ""),
        "deployBlock": deploy_block,
        "contracts": contracts,
        "addresses": flat,
        "libraries": {name: libraries[name] for name in LIBRARIES if name in libraries},
        "uniswapV2": {
            "factory": flat["UNISWAP_V2_FACTORY_ADDRESS"],
            "router02": flat["UNISWAP_V2_ROUTER02_ADDRESS"],
            "weth": flat["WETH_ADDRESS"],
            "pair": flat["UNISWAP_V2_PAIR_ADDRESS"],
            "feeTo": flat["UNISWAP_V2_FACTORY_ADDRESS"],  # feeTo() is address(0) by construction
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
            "tokenName": os.environ.get("TOKEN_NAME", ""),
            "tokenSymbol": os.environ.get("TOKEN_SYMBOL", ""),
            "phaseOriginBlocks": env_uint("PHASE_ORIGIN_BLOCKS"),
            "phaseOriginPhaseBlocks": env_uint("PHASE_ORIGIN_PHASE_BLOCKS"),
            "phaseTargetSeconds": env_uint("PHASE_TARGET_SECONDS"),
            "groupActionSplits": [x for x in os.environ.get("GROUP_ACTION_SPLITS", "").split(",") if x],
            "seedAccountCount": env_uint("SEED_ACCOUNT_COUNT") if include_seed else 0,
            "seedMemberCount": env_uint("SEED_MEMBER_COUNT") if include_seed else 0,
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
