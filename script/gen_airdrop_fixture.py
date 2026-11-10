#!/usr/bin/env python3
"""Generate the local airdrop snapshot (Merkle tree) for the anvil31337_dev profile.

The artifact this writes is the file the vendored Airdrop contract is constructed with and the file
the frontend is served, so it must match the contract's derivation exactly:

    leaf(account, share) = keccak256(bytes.concat(keccak256(abi.encode(account, share))))
    node(a, b)           = keccak256(bytes.concat(min(a,b), max(a,b)))     # sorted pair
    unpaired last node   = promoted unchanged

That is the algorithm in LOVE20TKM/burn/script/GenerateAirdropSnapshot.s.sol (double-hashed leaves,
sorted pairs, promotion), and `Airdrop.leafHash()` is the same double hash. Shares are relative: the
contract pays `balanceOf(this) * share / remainingShare(token)`, so the snapshot only fixes the
split, never an absolute amount. `totalShare = sum(shares)` and may not exceed 1e18.

Accounts are derived from the standard anvil mnemonic with `cast wallet address`, i.e. exactly the
keys script/SeedFlow.s.sol derives on chain with vm.deriveKey. The deploy and the seed therefore
cannot disagree about who owns a share: both read this file, and SeedFlow asserts
`vm.addr(derivedKey) == entries[i].account` before claiming.

Every proof is re-verified here (against a locally re-implemented verifier) before the file is
written, so a bug in the tree builder cannot reach the chain.

Numeric JSON fields are emitted as decimal STRINGS, matching the canonical burn snapshot format
(`"totalShare": "1000000000000000000"`), because 1e18 exceeds the IEEE-754 exact range and a JS
frontend must not round it. Addresses and proof elements are 0x-prefixed hex strings.

Usage (called by script/local.sh, which supplies the values from params/anvil31337_dev/*.params):
    gen_airdrop_fixture.py --mnemonic "<12 words>" --start-index 0 --count 10 \
        --total-share 1000000000000000000 --source-chain-id 31337 --source-block-number 1 \
        --source-burn-address 0x... --output fixtures/airdrop/anvil31337_dev.json
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


def keccak(hex_data: str) -> str:
    """keccak256 of a hex string, via `cast` (the toolchain this repo already depends on)."""
    out = subprocess.run(
        ["cast", "keccak", hex_data], capture_output=True, text=True, check=True
    )
    digest = out.stdout.strip()
    if not digest.startswith("0x") or len(digest) != 66:
        raise RuntimeError(f"unexpected cast keccak output: {digest!r}")
    return digest


def abi_encode_address_uint256(address: str, amount: int) -> str:
    """abi.encode(address,uint256) for one static pair: 32-byte word + 32-byte word."""
    addr = address.lower()
    if addr.startswith("0x"):
        addr = addr[2:]
    if len(addr) != 40:
        raise ValueError(f"bad address: {address}")
    if amount < 0 or amount >= 1 << 256:
        raise ValueError(f"amount out of uint256 range: {amount}")
    return "0x" + addr.rjust(64, "0") + format(amount, "064x")


def leaf_hash(address: str, share: int) -> str:
    inner = keccak(abi_encode_address_uint256(address, share))
    # bytes.concat of the 32-byte digest with itself-nothing: the leaf is keccak(inner).
    return keccak(inner)


def node_hash(left: str, right: str) -> str:
    if left > right:  # bytewise comparison of the lowercase 0x-prefixed hex strings == lexicographic
        left, right = right, left
    return keccak("0x" + left[2:] + right[2:])


def build_tree(leaves: list[str]) -> tuple[str, list[list[str]]]:
    """Return (root, proofs). Levels are lists of hashes, bottom-up."""
    if not leaves:
        raise ValueError("no leaves")
    levels = [list(leaves)]
    while len(levels[-1]) > 1:
        cur = levels[-1]
        nxt = []
        for i in range(0, len(cur), 2):
            if i + 1 == len(cur):
                nxt.append(cur[i])  # unpaired last node promoted unchanged
            else:
                nxt.append(node_hash(cur[i], cur[i + 1]))
        levels.append(nxt)

    proofs: list[list[str]] = []
    for index in range(len(leaves)):
        proof: list[str] = []
        idx = index
        for level in levels[:-1]:
            sibling = idx ^ 1
            if sibling < len(level):
                proof.append(level[sibling])
            # else: promoted node, no sibling at this level
            idx //= 2
        proofs.append(proof)
    return levels[-1][0], proofs


def verify(root: str, address: str, share: int, proof: list[str]) -> bool:
    computed = leaf_hash(address, share)
    for sibling in proof:
        computed = node_hash(computed, sibling)
    return computed == root


def derive_addresses(mnemonic: str, start: int, count: int) -> list[str]:
    addresses = []
    for index in range(start, start + count):
        out = subprocess.run(
            ["cast", "wallet", "address", "--mnemonic", mnemonic, "--mnemonic-index", str(index)],
            capture_output=True,
            text=True,
            check=True,
        )
        addresses.append(out.stdout.strip())
    return addresses


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mnemonic", required=True)
    ap.add_argument("--start-index", type=int, default=0)
    ap.add_argument("--count", type=int, required=True)
    ap.add_argument("--total-share", required=True, help="decimal, 1e18 == 100%%")
    ap.add_argument("--source-chain-id", required=True)
    ap.add_argument("--source-block-number", required=True)
    ap.add_argument("--source-burn-address", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    count = args.count
    if not 5 <= count <= 21:
        print(f"error: count must be 5..21 for a usable local snapshot, got {count}", file=sys.stderr)
        return 2
    total_share = int(args.total_share)
    if total_share <= 0 or total_share > 10**18:
        print("error: total share must be in (0, 1e18]", file=sys.stderr)
        return 2
    if total_share % count != 0:
        print(f"error: total share {total_share} is not divisible by {count} accounts", file=sys.stderr)
        return 2
    per_account = total_share // count

    accounts = derive_addresses(args.mnemonic, args.start_index, count)
    if len(set(a.lower() for a in accounts)) != count:
        print("error: derived duplicate addresses", file=sys.stderr)
        return 2

    leaves = [leaf_hash(a, per_account) for a in accounts]
    root, proofs = build_tree(leaves)

    for account, proof in zip(accounts, proofs):
        if not verify(root, account, per_account, proof):
            print(f"error: self-verification failed for {account}", file=sys.stderr)
            return 2

    snapshot = {
        "sourceChainId": str(args.source_chain_id),
        "sourceBlockNumber": str(args.source_block_number),
        "sourceBurnAddress": args.source_burn_address,
        "merkleRoot": root,
        "totalShare": str(total_share),
        "accountCount": str(count),
        "entries": [
            {"account": account, "share": str(per_account), "proof": proof}
            for account, proof in zip(accounts, proofs)
        ],
    }

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(snapshot, indent=2) + "\n")

    print(f"snapshot  : {output}")
    print(f"accounts  : {count} (mnemonic index {args.start_index}..{args.start_index + count - 1})")
    print(f"share/each: {per_account}  totalShare: {total_share}")
    print(f"merkleRoot: {root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
