# LOVE20BSC — local chain (`anvil31337_dev`)

One command starts a local anvil node and leaves it with the **entire protocol stack deployed,
seeded, exported and verified**:

```bash
make bootstrap
```

Chain: **chainId 31337**, `http://127.0.0.1:8545`, `--accounts 20 --block-time 1 --gas-limit 60000000
--code-size-limit 100000 --base-fee 1000000000` (the flags are in
[`params/anvil31337_dev/network.params`](params/anvil31337_dev/network.params); bootstrap starts in
automine mode and switches interval mining on after verify — see §2).

Ports are parameterised (`PORT=…` / `ANVIL_PORT=…`) because a machine often runs more than one
chain. **8545 is the default "human" chain** — a developer's browser wallet is connected to it, so
automated runs must never bootstrap or revert it. The frontend e2e suite therefore runs a second,
disposable chain on **8555**. Runtime state — pid file and logs — is per port: 8545 keeps the
historical flat `.anvil/` layout, every other port gets `.anvil/<port>/`. `make stop PORT=8555` /
`make clean PORT=8555` only ever touch 8555, and `make stop` / `make clean` only touch 8545.

The sibling repositories (`core/`, `action/`, `group-chat/`, `libs/`, `dex/`, `periphery/`,
`tools/`) are **read-only inputs**. Nothing in this repo writes into them. Their Solidity sources are compiled through the
`.siblings/*` remappings, and the UniswapV2 **Factory/Router/Pair** creation bytecode is read out of
`dex/build/` instead of being recompiled. `WETH9Configurable` is the exception: its source
(`dex/script/WETH9Configurable.sol`) is imported and compiled by this repo, then deployed with
`new WETH9Configurable(...)`; no WETH bytecode is read from `dex/build`.

---

## 1. Quick start

```bash
# from this directory (requires ~/.foundry/bin on PATH)
make stop && make clean && make bootstrap   # ≈45–50 s, always from a fresh chain
make verify             # re-run only the checks
make stop               # stop the 8545 anvil this repo started
make clean              # stop the 8545 anvil; remove build/export artifacts and 8545 runtime state
make bootstrap PORT=8555   # second chain next to 8545: own pid/log in .anvil/8555/
make stop PORT=8555        # stop/clean only the 8555 chain
```

**The address book is reproducible only from a fresh chain.** `make bootstrap` refuses to start if
any chain is already running, and before the first transaction it asserts block 0 / deployer nonce 0
/ no Multicall3 (`make fresh`). A used chain is never exported: `script/export.py` re-checks that the
DeployLibraries broadcast starts at nonce 0 and that DeployLocal continues immediately after it.
Never make the chain match a committed address book by setting a nonce — addresses always follow the
deployment.

Other ports: anvil treats host/port as the chain's identity, and this repo derives every RPC URL
from them. Because runtime state is namespaced per port, a second chain can run next to the
developer's 8545 without either `make stop` killing the other:

```bash
make bootstrap PORT=8555        # moves both the anvil process and every RPC URL
make stop PORT=8555             # stops only the 8555 chain (pid file: .anvil/8555/anvil.pid)
make bootstrap HOST=0.0.0.0     # binds all interfaces
```

Requirements: `forge` / `cast` / `anvil` **1.8.1+** (in `~/.foundry/bin`), `python3` (stdlib only),
`bash`, `make`, `shasum`. No Node, no npm, no `just`.

Preconditions on the siblings: `dex/build/` must exist (see [§8](#8-external-inputs-and-what-this-repo-does-not-do)).
Everything else (`core/out`, `action/out`, `group-chat/out`) is only needed for the ABI export step.

---

## 2. What `make bootstrap` does

| # | Step | Command | What it produces |
|---|---|---|---|
| 1 | preflight | `make preflight` | toolchain + sibling + artifact + Multicall3-tx checksum checks, `.siblings/` symlinks |
| 2 | airdrop fixture | `make fixture` | `fixtures/airdrop/anvil31337_dev.json` (10 accounts, proofs, merkle root) |
| 3 | build | `make build` | `forge build` over this project + the sibling sources (read-only) |
| 4 | anvil | `make anvil` | chain 31337 on `ANVIL_PORT` (8545 by default), automine; runtime state in `.anvil/` (8545) or `.anvil/<port>/`; **bootstrap refuses to reuse any running chain** |
| 5 | fresh guard | `make fresh` | deployer nonce 0 + no Multicall3 (bootstrap also requires block 0); fails loudly on a used chain |
| 6 | Multicall3 | `make multicall3` | `0xcA11bde05977b3631167028862bE2a173976CA11` from the upstream pre-signed tx |
| 7 | linked libraries | `make libraries` | the 4 action libraries (CREATE at deployer nonces 0..3, addresses to `export/libraries.json`) |
| 8 | deploy | `make deploy` | WETH, UniswapV2, core (8 incl. `AirdropDistributor`), action (4), group-chat (12), periphery/tools (2, appended last) |
| 9 | seed | `make seed` | advance to the genesis claim round, airdrop claims, 5 MemberNFTs, liquidity + governance stake, ETH top-ups |
| 10 | export | `make export` | `export/deployments/anvil31337_dev.json`, `export/abis/*.json`; nonce sequence re-checked |
| 11 | verify | `make verify` | `cast` assertions → `export/VERIFIED.md`, non-zero exit on any failure |
| 12 | interval mining | `anvil_setIntervalMining 1` | chain switches to `--block-time 1` for the frontend/phase clock |

The bootstrap runs with anvil **automine** (one transaction == one block) and switches interval
mining on only at the end. That makes the export byte-identical between two clean runs — addresses
*and* block numbers — without changing how the finished chain behaves for the frontend.

Each step is independently runnable and idempotent where that is meaningful (`preflight`, `fixture`,
`anvil`, `multicall3`, `libraries`, `export`, `verify`). `deploy` + `seed` are one-shot per
deployment: run `make deploy && make seed` again and you get a *new* stack at new addresses (the old
contracts are simply orphaned — fine on a throwaway chain, and the address book is rewritten).

---

## 3. Deployment order

```
Multicall3                      canonical address, upstream signed tx
WETH9Configurable               dex/script/WETH9Configurable.sol, source compiled by this repo
UniswapV2Factory                dex/build artifact (not recompiled), feeToSetter = 0 (fee locked)
UniswapV2Router02               dex/build artifact (not recompiled), (factory, WETH)
Phase                           ← start of DeployCore._deployContracts()
AirdropDistributor              deployed BY DeployCore, configured with the genesis token + root
Launch                          creates LOVE20Token and its (empty) Uniswap pair
MemberNFT
Stake
Submit
Vote
Mint
ActionTarget
LpExecutor
GroupActionExecutor             linked against the 4 libraries
GroupServiceExecutor            linked against GroupRecipients
GroupAdmin
GroupChat
GroupChatBanList
AdminBanSource
GovVotedBanSource
GroupMember
GroupMemberScope
GroupJoinScopeSource
TokenMainManager
TokenGovManager
TokenActionGovManager
TokenActionMainManager
BatchTransfer                   ← start of DeployLocal's appended periphery/tools block
LOVE20Hub(Stake)
```

**`BatchTransfer` and `LOVE20Hub` are appended at the very end, on purpose.** Every address in this
repo is a plain `CREATE(deployer, nonce)` result, so inserting a module anywhere earlier would shift
the nonce of every contract deployed after it and silently change the committed address book
(`MemberNFT`, `Stake`, `Vote`, `Mint`, the executors, the group-chat stack, …). The two sibling
modules therefore come after the whole protocol stack and before `_writeAddresses`, which is what
keeps every pre-existing address unchanged. `BatchTransfer` (tools) has no constructor arguments and
no protocol dependency; `LOVE20Hub` (periphery) takes only `STAKE_ADDRESS` and derives
router/factory/launch/memberNFT/wrapped-native plus the DEX fee profile from `Stake`. Nothing
downstream consumes either address, so the tail is the only safe place for them.

**The AirdropDistributor is part of core, not of this repo.** `DeployCore._deployContracts` deploys
it immediately after `Phase` and before `Launch`, because the `LOVE20Token` constructor mints the
whole `LAUNCH_AMOUNT` to it and there is no setter. `DeployLocal` no longer deploys any airdrop
contract and no longer passes a `distributor` address: `CoreConfig` carries only
`genesisMerkleRoot` + `genesisClaimDelayRounds`, and `DeploymentAddresses.airdropDistributor` is
read back from the core deploy body.

**Core ordering is the sibling repo's own.** `DeployLocal` inherits `DeployCore` from
`core/script/deploy/DeployCore.s.sol` and calls its `_deployContracts`, so the CREATE nonce
predictions in `DeployCore._predictAddresses()` (`AirdropDistributor = nonce+1`, `Launch = nonce+2`,
`MemberNFT = nonce+3`, `Vote = nonce+6`, `Mint = nonce+7`) are literally the same code path,
including the `require`s that fail loudly if a prediction does not match. `_predictor()` is
overridden to read `DEPLOYER_ADDRESS` from the environment instead of `msg.sender`, which cannot
drift from the broadcast account.

Because the old vendored Airdrop occupied deployer nonce 7 and core's new order puts `Phase` there,
**`PHASE_ADDRESS` is the one pre-existing address that moves**; everything from `Launch` onwards
(and the genesis token, created by `Launch` at its nonce 1) keeps its address. Airdrop 7 → Phase,
Phase 8 → AirdropDistributor.

---

## 4. Address book (the run recorded in [`export/VERIFIED.md`](export/VERIFIED.md))

Fresh chain, deterministic: the same command produces the same addresses, because anvil account #0
starts at nonce 0 and the transaction order is fixed.

| key | contract | address | block |
|---|---|---|---|
| `MULTICALL3_ADDRESS` | Multicall3 | `0xcA11bde05977b3631167028862bE2a173976CA11` | 1 |
| `GROUP_ACTION_JOIN_LIBRARY_ADDRESS` | GroupActionJoin | `0x5FbDB2315678afecb367f032d93F642f64180aa3` | 2 |
| `GROUP_ACTION_MANAGER_LIBRARY_ADDRESS` | GroupActionManager | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` | 3 |
| `GROUP_ACTION_VERIFY_LIBRARY_ADDRESS` | GroupActionVerify | `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` | 4 |
| `GROUP_RECIPIENTS_LIBRARY_ADDRESS` | GroupRecipients | `0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9` | 5 |
| `WETH_ADDRESS` | WETH9 | `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9` | 6 |
| `UNISWAP_V2_FACTORY_ADDRESS` | UniswapV2Factory | `0x5FC8d32690cc91D4c39d9d3abcBD16989F875707` | 7 |
| `UNISWAP_V2_ROUTER02_ADDRESS` | UniswapV2Router02 | `0x0165878A594ca255338adfa4d48449f69242Eb8F` | 8 |
| `UNISWAP_V2_PAIR_ADDRESS` | UniswapV2Pair | `0x3FC12a5abAe69C8Eee58C37cEDC266751507620D` | 11 |
| `AIRDROP_DISTRIBUTOR_ADDRESS` | AirdropDistributor | `0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6` | 10 |
| `LOVE20_TOKEN_ADDRESS` | LOVE20Token | `0x8aCd85898458400f7Db866d53FCFF6f0D49741FF` | 11 |
| `PHASE_ADDRESS` | Phase | `0xa513E6E4b8f2a923D98304ec87F64353C4D5C853` | 9 |
| `LAUNCH_ADDRESS` | Launch | `0x8A791620dd6260079BF849Dc5567aDC3F2FdC318` | 11 |
| `MEMBER_NFT_ADDRESS` | MemberNFT | `0x610178dA211FEF7D417bC0e6FeD39F05609AD788` | 12 |
| `STAKE_ADDRESS` | Stake | `0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e` | 13 |
| `SUBMIT_ADDRESS` | Submit | `0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0` | 14 |
| `VOTE_ADDRESS` | Vote | `0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82` | 15 |
| `MINT_ADDRESS` | Mint | `0x9A676e781A523b5d0C0e43731313A708CB607508` | 16 |
| `ACTION_TARGET_ADDRESS` | ActionTarget | `0x0B306BF915C4d645ff596e518fAf3F9669b97016` | 17 |
| `LP_EXECUTOR_ADDRESS` | LpExecutor | `0x959922bE3CAee4b8Cd9a407cc3ac1C251C2007B1` | 18 |
| `GROUP_ACTION_EXECUTOR_ADDRESS` | GroupActionExecutor | `0x9A9f2CCfdE556A7E9Ff0848998Aa4a0CFD8863AE` | 19 |
| `GROUP_SERVICE_EXECUTOR_ADDRESS` | GroupServiceExecutor | `0x68B1D87F95878fE05B998F19b66F4baba5De1aed` | 20 |
| `GROUP_ADMIN_ADDRESS` | GroupAdmin | `0x3Aa5ebB10DC797CAC828524e59A333d0A371443c` | 21 |
| `GROUP_CHAT_ADDRESS` | GroupChat | `0xc6e7DF5E7b4f2A278906862b61205850344D4e7d` | 22 |
| `GROUP_CHAT_BAN_LIST_ADDRESS` | GroupChatBanList | `0x59b670e9fA9D0A427751Af201D676719a970857b` | 23 |
| `ADMIN_BAN_SOURCE_ADDRESS` | AdminBanSource | `0x4ed7c70F96B99c776995fB64377f0d4aB3B0e1C1` | 24 |
| `GOV_VOTED_BAN_SOURCE_ADDRESS` | GovVotedBanSource | `0x322813Fd9A801c5507c9de605d63CEA4f2CE6c44` | 25 |
| `GROUP_MEMBER_ADDRESS` | GroupMember | `0xa85233C63b9Ee964Add6F2cffe00Fd84eb32338f` | 26 |
| `GROUP_MEMBER_SCOPE_ADDRESS` | GroupMemberScope | `0x4A679253410272dd5232B3Ff7cF5dbB88f295319` | 27 |
| `GROUP_JOIN_SCOPE_SOURCE_ADDRESS` | GroupJoinScopeSource | `0x7a2088a1bFc9d81c55368AE168C2C02570cB814F` | 28 |
| `TOKEN_MAIN_MANAGER_ADDRESS` | TokenMainManager | `0x09635F643e140090A9A8Dcd712eD6285858ceBef` | 29 |
| `TOKEN_GOV_MANAGER_ADDRESS` | TokenGovManager | `0xc5a5C42992dECbae36851359345FE25997F5C42d` | 30 |
| `TOKEN_ACTION_GOV_MANAGER_ADDRESS` | TokenActionGovManager | `0x67d269191c92Caf3cD7723F116c85e6E9bf55933` | 31 |
| `TOKEN_ACTION_MAIN_MANAGER_ADDRESS` | TokenActionMainManager | `0xE6E340D132b5f46d1e472DebcD681B2aBc16e57E` | 32 |
| `BATCH_TRANSFER_ADDRESS` | BatchTransfer | `0xc3e53F4d16Ae77Db1c982e75a937B9f60FE63690` | 33 |
| `HUB_ADDRESS` | LOVE20Hub | `0x84eA74d481Ee0A5332c457a4d796187F6Ba67fEB` | 34 |

Notes:

* The first four CREATE nonces of the deploy account belong to the **linked libraries**, so `WETH`
  is `0xDc64…`, not the `0x5FbD…` a bare `dex` deployment produces. The address book is the source of
  truth — the org's committed `addresses.*.params` files are stale and mutually inconsistent.
* `UniswapV2Pair` and `LOVE20Token` have no transaction of their own (created inside `Launch`'s
  constructor), so their block is attributed to `Launch`.
* **Addresses and block numbers are deterministic on a clean chain.** Bootstrap uses automine and
  `--slow` so every transaction gets exactly one block, numbered from 1. Two
  `make stop && make clean && make bootstrap` runs produce byte-identical
  `export/deployments/anvil31337_dev.json` (verify with `sha256sum`). The finished chain resumes
  1-second blocks; only *post-bootstrap* activity changes heights.
* The deployer starts at CREATE nonce 0. There is deliberately no "start nonce" parameter: a
  non-zero start is a bug, not a configuration choice (see `params/anvil31337_dev/accounts.params`).
* `UniswapV2Factory`/`Router02`/`Pair` creation bytecode is **not recompiled** here: the published
  dex artifacts are read and hash-checked against the constants in
  `dex/script/deploy/DeployUniswapV2.s.sol` (`PAIR_INIT_CODE_HASH`, `FACTORY_CREATION_HASH`,
  `ROUTER_CREATION_HASH`), because the Pair init-code hash is embedded in the Router.
* `WETH9Configurable` is **not** one of those artifacts: its source
  (`dex/script/WETH9Configurable.sol`) is imported and compiled by this repo, and `DeployLocal`
  deploys it with `new WETH9Configurable(...)`. No WETH bytecode is read from `dex/build`; the
  source is read-only, the compilation is ours.

---

## 5. The export

```text
export/
├── deployments/anvil31337_dev.json    the frontend's address book
├── abis/<Contract>.json               21 ABI arrays (top-level `abi` from the sibling out/ artifacts)
├── airdrop/anvil31337_dev.json        snapshot with proofs (copy of fixtures/airdrop/…)
└── VERIFIED.md                        generated verification report with actual values
```

`export/deployments/anvil31337_dev.json`:

```jsonc
{
  "network": "anvil31337_dev",
  "chainId": 31337,
  "rpcUrl": "http://127.0.0.1:8545",
  "deployer": "0xf39Fd…2266",
  "deployBlock": 25,
  "contracts": { "Launch": { "address": "0x…", "blockNumber": 24, "group": "core" }, … },
  "addresses": { "LAUNCH_ADDRESS": "0x…", … },      // same keys as params files
  "libraries": { "GroupActionJoin": "0x…", … },
  "uniswapV2": { "factory": "0x…", "router02": "0x…", "weth": "0x…", "pair": "0x…", "feeTo": "0x0000000000000000000000000000000000000000", "pairInitCodeHash": "0x96e8…" },
  "airdropDistributor": {
    "address": "0x…", "token": "0x…", "merkleRoot": "0x…", "totalShare": "1000000000000000000",
    "accountCount": "10", "claimDelayRounds": 1, "claimableFromRound": 2,
    "totalClaimedShare": 500000000000000000, "totalRemainingShare": 500000000000000000,
    "totalClaimedAmount": 500000000000000000000000000, "remainingAmount": 500000000000000000000000000,
    "snapshotUri": "", "intendedSnapshotUri": "http://127.0.0.1:5180/airdrop/anvil31337_dev.json",
    "snapshotFile": "export/airdrop/anvil31337_dev.json"
  },
  "params": { "tokenName": "TestLOVE20@TestWETH", "phaseOriginPhaseBlocks": 120, "phaseTargetSeconds": 12 }
}
```

`deployer`, `params.*` and `uniswapV2.feeTo` are data, not an echo of the shell that happened to run
`make export`: `export.py` takes the deployer from the deploy broadcast receipts (and asserts it
agrees with `DEPLOYER_ADDRESS` when that is set), parses the token/phase/seed values out of
`params/anvil31337_dev/*.params`, and calls `feeTo()` (and `feeToSetter()`) on the factory over the
live node. A non-zero `feeTo` is exported as-is with a warning; the deployment's
`feeToSetter = address(0)` lock is what makes it zero on this profile, and `make verify` asserts both
the chain value and the exported value. Missing inputs fail the export instead of writing
`""`/`0` placeholders. `rpcUrl` stays the profile's canonical endpoint from `network.params`
(`http://127.0.0.1:8545`, what a fresh `make bootstrap` serves) even when a one-off `PORT=`
override starts the chain elsewhere.

ABIs exported: `MemberNFT`, `LOVE20Token`, `Launch`, `Stake`, `Submit`, `Vote`, `Mint`, `Phase`,
`AirdropDistributor` (from `core/out/AirdropDistributor.sol/`), `ActionTarget`, `LpExecutor`,
`GroupActionExecutor`, `GroupServiceExecutor`, `GroupChat`, `UniswapV2Router02`,
`UniswapV2Factory`, `UniswapV2Pair`, `Multicall3`, plus `WETH9` (the UI needs
`deposit()`/`withdraw()`), `BatchTransfer` (tools) and `LOVE20Hub` (periphery). The last two are
compiled by this repo from the read-only sibling sources, so the exported ABI is the one that matches
the bytecode this repo deployed (the siblings' own `out/` belongs to another checkout and can be
stale or absent). The old `Airdrop.json` is gone.

ABI provenance: each file is the top-level `abi` of `core|action|group-chat/out/<File>.sol/<Contract>.json`
or `dex/build/...`. Those directories are **read**; the export script never builds in them. If one is
missing it fails with the throwaway-copy recipe (copy the repo to a temp dir, `forge build` there,
set `CORE_OUT=` / `ACTION_OUT=` / `GROUP_CHAT_OUT=` / `DEX_BUILD=` and re-run `make export`).

---

## 6. Seeded state

`script/SeedFlow.s.sol` runs as the **real end users** — every seeded account signs its own
transactions. No `deal`, no `anvil_setStorageAt`, no state forgery anywhere in the seed path.

| What | How | Result on the verified run |
|---|---|---|
| ETH | account #0 tops every seeded account up to `SEED_ETH_PER_ACCOUNT` (100 ETH); the liquidity member's target is `SEED_ETH_PER_ACCOUNT + SEED_LIQUIDITY_PARENT_TOKEN_AMOUNT` (100 ETH, which it wraps and stakes) `+ SEED_GAS_ALLOWANCE` (0.2 ETH for the gas it signs), i.e. 200.2 ETH — `SEED_ETH_PER_ACCOUNT` is the balance the seed must leave behind, not the amount it hands out | 5 accounts ≥ 100 ETH (anvil already funds them, so usually a no-op) |
| Claim round | `script/local.sh` mines up to `claimableFromRound` (= max(phase at deploy,1) + `GENESIS_AIRDROP_CLAIM_DELAY_ROUNDS` = **2**) before seeding; `SeedFlow` re-asserts it | bootstrap ends in **phase 2** (block 121), not phase 1 |
| Airdrop claim | each of the first `SEED_MEMBER_COUNT` (5) accounts calls `AirdropDistributor.claim(token, share, proof)` with its own key (`msg.sender` is the claimer) | 5 × 1e26 tokens claimed; accounts 5–9 left unclaimed for the **claim UI** |
| MemberNFT | each of the 5 claims, then `approve` + `mint("Testdev-member-<i>")` (the name is stored verbatim) | 5 identities, ids 1–5, 9e20 burned per mint |
| Liquidity + governance | member 0 wraps 100 ETH → `WETH.deposit`, approves `Stake`, calls `Stake.stakeLiquidity(token, 2e23, 1e20, 1, 1)` | pair reserves **200 000 token / 100 WETH** (price 2000 token/ETH), 4.472135954999579391818e21 LP minted to `Stake`, equal `govVotes` |

**Liquidity goes through `Stake.stakeLiquidity`, not `Router.addLiquidity`.** `Launch._ensurePair()`
only *creates* the pair (zero reserves). Routing the first liquidity through `Stake` does two things
at once: it gives the pair its reserves, and it gives a member actual governance weight
(`liquidityShares → govVotes`), so the seeded chain can vote/submit/claim rewards without a second
manual step. The staker is member id 1 (anvil account #0).

The airdrop fixture covers **10 accounts** (anvil indices 0–9), **1e17 share each**, total 1e18, so
the airdrop page has both claimed (0–4) and claimable (5–9) state to exercise. Claims are paid from
the distributor's `LAUNCH_AMOUNT` balance at `balanceOf(distributor) * share / remainingShare`; with
equal shares each payout is exactly `1e26` and the distributor keeps `5e26` after the seed.

**Snapshot URI — fixed at deployment.** `core.params` supplies
`GENESIS_AIRDROP_SNAPSHOT_URI`, pointing to
`https://love20bsc.github.io/core/script/network/anvil31337_dev/airdrop.json`. `DeployLocal` passes it to the
distributor's constructor; seed and verify compare the on-chain value with the configuration.
The genesis token still has `launcherMemberId = 0`, so subsequent URI updates remain forbidden.
The frontend bundles the snapshot and only needs the URI when its local file is unavailable or
has a different root. Existing exports, including the example above, may still show an empty URI
until a fresh deployment and export; changing the configuration cannot alter an old contract.

---

## 7. Linked libraries (the risky part)

`GroupActionExecutor` has **three** unresolved link placeholders (`GroupActionJoin`,
`GroupActionManager`, `GroupActionVerify`) and `GroupServiceExecutor` **one** (`GroupRecipients`).
Solidity substitutes them at **compile** time, so the addresses must exist *before* the deployment
script is compiled:

1. `script/DeployLibraries.s.sol` deploys the four libraries with plain `CREATE` from
   `vm.getCode("<File>.sol:<Contract>")` and writes `export/libraries.json`.
2. `script/local.sh` builds the linker argument from that file and exports it as
   **`FOUNDRY_LIBRARIES`** (not `--libraries`: in forge 1.8.1 the CLI flag splits its whole value on
   `:` and therefore accepts only **one** library per invocation, failing with
   `failed to parse, too many arguments passed`; the config env var accepts the comma-separated
   list).
3. `forge script` recompiles the executors with the four addresses substituted and deploys them.
   `DeployLocal._validateAction` then reads back every executor immutable.

The shell deliberately **always emits all four entries** rather than re-deriving them from `out/`:
`forge build --libraries …` links addresses *into* the cached artifacts and drops their link
references, so a derivation from artifacts would silently shrink after the first run and leave a
stale address baked into the bytecode. The artifacts are used only as a cross-check of the source
unit names (`.siblings/action/src/<Name>.sol`).

---

## 8. External inputs, and what this repo does not do

Read-only inputs, remapped in [`remappings.txt`](remappings.txt):

```text
@core/        -> .siblings/core/src/                      @libs/        -> .siblings/libs/src/
@action/      -> .siblings/action/src/                    @forge-std/   -> .siblings/core/lib/forge-std/src/
@group-chat/  -> .siblings/group-chat/src/                @openzeppelin/contracts/ -> .siblings/core/lib/openzeppelin-contracts/contracts/
core/ action/ group-chat/ libs/ dex/  (non-@ prefixes, for sibling scripts/artifacts)
periphery/ tools/                     (non-@ prefixes: LOVE20Hub and BatchTransfer sources)
```

`.siblings/<repo>` are committed **relative symlinks** (`../../<repo>`). They are not cosmetic: with
`../core/...`-style remappings, foundry compiled the same sibling file under two source-unit names
(`../action/src/X.sol` and `/abs/path/action/src/X.sol`), which duplicated 45 artifacts, made
`vm.getCode("X.sol:X")` ambiguous and would have left the link references unfilled. Going through a
path inside the project root produces exactly one source-unit name per file
(`.siblings/action/src/X.sol`). `make preflight` recreates the symlinks if a checkout lost them.

Deliberately **not** done:

* No `make -C ../dex build`, no `forge build` inside any sibling — those write there. `dex/build` is
  a precondition; if it is missing, preflight prints the command to run yourself.
* No `dex/script/deploy/one_click_deploy.sh` (it rewrites `dex/script/network/...`).
* No copies of sibling sources — the old vendored `Airdrop` was deleted; the airdrop now comes from
  core (see §9).
* No keystore, no `.account` file: the deploy key is derived from the anvil mnemonic in
  `params/anvil31337_dev/accounts.params`.

### Pinned siblings (opt-in: `make bootstrap PINNED=1`)

The default build compiles the **live** sibling checkouts, so a sibling that is mid-change breaks
everything: on 2026-11-14 core's `IStake.stakeLiquidity` gained a `deadline` parameter while the
anvil scripts (and the live `periphery` checkout) still called the five-argument form, so every
port's `make bootstrap` stopped compiling until core was consistent again. Pinned siblings remove
that coupling without changing the default: compile a **read-only `git worktree` snapshot** of seven
sibling commits instead of the live trees.

```bash
make pin                                     # create .siblings-pinned/<repo> at the commits in siblings.lock
make pin-status                              # lock vs pinned vs live HEAD, per repo (+ whether PINNED=1 is ready)
make bootstrap PINNED=1 PORT=8580            # build/deploy from the pinned worktrees; 8545 is never touched
make unpin                                   # git worktree remove + drop .siblings-pinned/
make pin-lock                                # bump: rewrite siblings.lock from the live HEADs
```

`siblings.lock` (committed) records the seven `url`/`sha` pairs. Its baseline is the
`sources.*.head` of the last successful export (`interface-dev-dsh/src/config/abis/manifest.json`),
i.e. the commits the committed `export/deployments/anvil31337_dev.json` was produced from — with the
2026-11-14 lock that is core `8d604a2`, action `66e2d65`, group-chat `45f1966`, libs `65b1106`,
dex `31464c0`, periphery `3b825a5`, tools `44d7f54`.

What differs in PINNED=1 (all of it inside `script/local.sh`; `PINNED=0` is the default path and
keeps the old behaviour):

* **Remappings.** `FOUNDRY_REMAPPINGS` is set to every line of `remappings.txt` rewritten
  `.siblings/` -> `.siblings-pinned/`. Forge gives config/env remappings precedence over
  `remappings.txt` and de-duplicates by context, so the live entries become dead and no live sibling
  file is read. (The value is newline-separated: forge 1.8.1 parses one remapping per line, while a
  comma-joined value is parsed as a single bogus remapping.)
* **dex creation bytecode.** `build/` is gitignored in `../dex`, so the pinned worktree has none.
  `make pin` hard-link copies `../dex/build` next to the pinned dex worktree and the deploy script
  reads it through `DEX_ARTIFACT_ROOT` (the three creation-code hashes are still asserted, so a
  snapshot that does not match the pinned dex commit fails loudly).
* **ABI export.** `export.py` otherwise reads each sibling's own `out/`; in pinned mode it reads
  *this* project's `out/`, which is the compilation of the pinned tree. Without that the address book
  would be pinned but `export/abis/*.json` would describe the mid-change live sibling.
* **preflight** verifies all seven worktrees exist at the lock's commits and that the pinned dex
  snapshot is complete. It never creates anything: a missing/stale pin fails with the exact command
  (`make pin`, or `make unpin && make pin`).

Where the worktrees live and why `unpin` is not `rm -rf`:

* The checkouts are `anvil/.siblings-pinned/<repo>` (gitignored), but each one is registered in the
  **sibling's own** `.git/worktrees/<repo>` by `git worktree add --detach`. Deleting the directory
  would leave that registration behind, so `make unpin` uses `git worktree remove --force` (plus
  `git worktree prune`). Registering a worktree does not modify the sibling's working tree or its
  `git status`; `make unpin` prints the sibling statuses to prove it.
* Sibling `lib/` are submodules and `git worktree add` does not populate them. `make pin` copies only
  the submodules the pinned commit and the live checkout *agree* on (hard links: same bytes, no
  copy), and fails for a submodule the build actually reads if the live checkout is at another
  commit. Today that condition holds for core's `forge-std`/`openzeppelin-contracts` (the only ones
  any remapping reaches); `action/lib/core` and `periphery/lib/core` are ahead of the pin because the
  live core was bumped, and they are skipped with a warning (no remapping reads them, so nothing is
  compiled from them).

Bump procedure (`siblings.lock` is the only thing that moves):

```bash
# 1. prove the live tree actually works, from scratch
make stop && make clean && make bootstrap
# 2. record its commits (refuses while any sibling working tree is dirty: a lock stores commits, the
#    build compiles the working tree)
make pin-lock
# 3. materialise the new pin and prove it reproduces the same chain
make unpin && make pin
make bootstrap PINNED=1 PORT=8580
# 4. compare: export/deployments/anvil31337_dev.json must be identical to the committed one
git status --porcelain export/deployments/anvil31337_dev.json
make stop PORT=8580
```

Leftover risks: `make pin` never fetches (it only uses commits already present in the local
checkouts, and says so when the pinned sha is missing); the pinned tree is a snapshot, so a sibling
`lib/` submodule that is updated later does not update the pin — that is what `make pin-lock` is for;
and `make clean` deliberately leaves `.siblings-pinned/` alone (it is a checkout, not build output).

---

## 9. Airdrop (core `AirdropDistributor`)

The airdrop is now protocol code: `core/src/distributor/AirdropDistributor.sol` at `core@141c931`.
`DeployCore` deploys it itself (it is not passed in as a `distributor` address any more) and
`DeployLocal` reads `airdropDistributor` back from the core deploy body. There is **no vendored
airdrop** in this repo: `src/vendor/Airdrop.sol` / `IAirdrop.sol` were deleted, along with the
constructor provenance parameters they needed.

* Genesis configuration comes from `params/anvil31337_dev/core.params`:
  `GENESIS_AIRDROP_MERKLE_ROOT` and `GENESIS_AIRDROP_CLAIM_DELAY_ROUNDS`. The root must match the
  snapshot fixture (and therefore the frontend's `public/airdrop` copy); `DeployLocal` refuses to
  broadcast if the params file and the fixture disagree.
* `claimableFromRound = max(phase at deployment, 1) + claimDelayRounds`. This profile deploys in
  phase 1 with a delay of 1, so claims open in **phase 2**. `script/local.sh seed` mines the
  intervening blocks (anvil-only; it happens after the deploy broadcast, so exported addresses and
  block numbers are unchanged) and `SeedFlow` asserts the round before claiming.
* Claim interface: `claim(tokenAddress, share, proof)` — the distributor pays `msg.sender`, there is
  no account argument. `claimableAmount(tokenAddress, claimer, share, proof)` quotes the payout,
  `isClaimed(tokenAddress, claimer)` / `claimedAmount(tokenAddress, claimer)` report past claims, and
  `airdropInfo(tokenAddress)` returns the whole per-token state (root, claim round, claimed/remaining
  shares and amounts, snapshot URI) in one struct.
* Claim math is unchanged in shape: `amount = balanceOf(distributor) * share / remainingShare(token)`.
  Shares are relative, never absolute amounts.
* The distributor implements `ILaunchDistributor.onTokenLaunched`, so child-token launches **can**
  use it as a callback distributor (the old `NoCallback` limitation is gone).
* Fixture (`fixtures/airdrop/anvil31337_dev.json`), generated by `script/gen_airdrop_fixture.py`:
  double-hashed keccak leaves `keccak(keccak(abi.encode(account, share)))`, sorted-pair internal
  nodes, unpaired last node promoted, every proof re-verified before writing. Numbers are emitted as
  decimal **strings** (1e18 is not JS-safe as a number).
* Deployment preflight in `DeployLocal` cross-checks the fixture root and totalShare against params
  and requires totalShare to equal `1e18`. It does not repeat core's full snapshot checks for proofs,
  accountCount, duplicate addresses and the sum of entry shares when reading an existing file;
  the local generator verifies proofs and rejects duplicate addresses and invalid share allocations
  when creating the fixture.
* Provenance fields in the fixture (`sourceChainId 31337`, … `0x…C0FFEE01`) are synthetic and
  labelled as such: they feed the fixture format only — the new distributor has no provenance
  immutables, and this chain has no Burn deployment.
* **Snapshot URI:** see §6. `core.params` supplies `GENESIS_AIRDROP_SNAPSHOT_URI` at construction.
  Genesis URI updates remain forbidden; launched tokens can update theirs normally.

---

## 10. Verification

`make verify` (`script/verify.sh`) is independent of the deploy scripts: every value is a `cast`
call against the running node, and it exits non-zero on any failure. Full output:
[`export/VERIFIED.md`](export/VERIFIED.md).

Headline values from the verified run:

| check | value |
|---|---|
| chain id | `31337` |
| code present | all 36 exported addresses |
| `Phase.currentPhase()` | `2` on the committed run (the seed advanced to the genesis claim round; the chain mines every second afterwards) |
| `Phase.ORIGIN_PHASE_BLOCKS()` | `120` (= 2 min per phase at `--block-time 1`) |
| `MemberNFT.totalSupply()` | `5` |
| `MemberNFT.balanceOf(seed[0])` | `1` |
| `LOVE20Token.balanceOf(seed[0])` | `99799100000000000000000000` |
| `LOVE20Token.balanceOf(AirdropDistributor)` | `500000000000000000000000000` |
| pair reserves | `200000000000000000000000` token / `100000000000000000000` WETH |
| LP held by `Stake` | `4472135954999579391818` |
| `Stake.totalLiquidityShares` | `4472135954999579391818` |
| `AirdropDistributor.airdropInfo(genesis).merkleRoot` | `0x046a5d5357fd4da6986a88fb1e2baf3603375d2099ce9f46b9d6fbe333c6c404` (= params = fixture) |
| `AirdropDistributor.TOTAL_SHARE()` | `1000000000000000000` (= fixture) |
| `AirdropDistributor.airdropInfo(genesis).claimableFromRound` | `2` |
| `AirdropDistributor.claimedAmount(genesis, seed[0])` | `100000000000000000000000000` |
| `AirdropDistributor.isClaimed(genesis, seed[0])` | `true` |
| `AirdropDistributor.airdropInfo(genesis).totalClaimedShare` / `totalRemainingShare` | `500000000000000000` / `500000000000000000` |
| `AirdropDistributor.airdropInfo(genesis).totalClaimedAmount` / `remainingAmount` | `500000000000000000000000000` / `500000000000000000000000000` |
| `AirdropDistributor.airdropInfo(genesis).snapshotUri` | equals `GENESIS_AIRDROP_SNAPSHOT_URI` (§6) |
| ETH balance of each seeded account | ≥ `100000000000000000000` wei |
| `Multicall3.getBlockNumber()` | > 0 |

The report also re-checks the wiring graph (`router.factory()`, `router.WETH()`, `factory.feeTo()==0`,
`token.MINTER()`, `Launch.FIRST_TOKEN_ADDRESS()`, `Stake.VOTE_ADDRESS()`,
`GroupChat.GROUP_ADDRESS()`, …) and that the committed export's `deployer`, `params.*` and
`uniswapV2.feeTo` agree with the chain (including a non-zero deployer ETH balance), so a stale or
hand-edited export cannot pass `make verify`.

> **Port note.** The committed verification ran on the canonical `127.0.0.1:8545` after the
> unrelated anvil process (a different, older frontend checkout) that had been holding the port was
> stopped. The chain flags are the profile defaults in `params/anvil31337_dev/network.params`. The
> committed `export/deployments/anvil31337_dev.json` carries the profile's canonical `rpcUrl`
> (`http://127.0.0.1:8545`); addresses and block numbers are those of this verified run and are
> reproducible on a fresh chain.
>
> The frontend e2e suite bootstraps the same profile on `PORT=8555`. Because the exported `rpcUrl`
> stays the profile's canonical endpoint (see §5), a clean 8555 bootstrap regenerates every export
> file byte-identically, including all addresses and block numbers. `export/VERIFIED.md` is the one
> file that changes: `script/verify.sh` records the endpoint it was run against (its `rpc` row and
> the copy-paste `cast` examples then point at 8555), plus the wall-clock timestamp. After a 8555
> bootstrap it is therefore restored to HEAD (`git checkout -- export/VERIFIED.md`): the committed
> report must describe the canonical 8545 chain, not the disposable automated one. Commit it
> deliberately when the verified values themselves change.

---

## 11. Re-running

```bash
# everything, from scratch (stops this repo's anvil, removes build + chain state)
make stop
make clean
make bootstrap

# step by step (the bootstrap order; fresh must pass before the first deployment tx)
make preflight && make fixture && make build && make anvil && make fresh
make multicall3 && make libraries && make deploy && make seed
make export && make verify
# then: cast rpc anvil_setIntervalMining 1 --rpc-url http://127.0.0.1:8545

# a second chain next to the developer's 8545 (own pid/log in .anvil/<port>/, independent stop/clean)
make bootstrap PORT=8556
cast block-number --rpc-url http://127.0.0.1:8556
make stop PORT=8556

# the frontend e2e suite does exactly this on 8555: `pnpm e2e` bootstraps it once and reuses it

# inspect
cast call $PHASE 'currentPhase()(uint256)' --rpc-url http://127.0.0.1:8545
cast call $MEMBER_NFT 'balanceOf(address)(uint256)' 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url http://127.0.0.1:8545
cast call $PAIR 'getReserves()(uint112,uint112,uint32)' --rpc-url http://127.0.0.1:8545
```

`make bootstrap` refuses to reuse any running chain; `make anvil` refuses to attach to a chain this
repo did not start (no live `.anvil/anvil.pid` matching the endpoint), so a stray anvil on 8545 cannot
be silently polluted. Both print the ways out (stop it, or use `PORT=`).

To prove determinism:

```bash
make stop && make clean && make bootstrap
cp export/deployments/anvil31337_dev.json /tmp/anvil-1.json
make stop && make clean && make bootstrap
sha256sum /tmp/anvil-1.json export/deployments/anvil31337_dev.json   # same hash
```

The frontend consumes the export only through `pnpm sync:anvil` (documented in the frontend's
ADR-0004 §6); it never hand-edits the address book. The deployer nonce is never set by hand.

---

## 12. Known limitations

1. **No real burn-derived snapshot.** The local chain has no `Burn` deployment, so the airdrop
   snapshot is synthetic (10 anvil accounts, equal shares, fake non-zero provenance). Shape and
   hashing match the canonical generator exactly, so the claim UI is exercised for real.
2. **Old exports need a fresh deployment for the genesis URI.** The URI is now a constructor
   argument; existing contracts with an empty URI cannot be updated. Their matching bundled
   snapshot still works. New exports also include public `coreParams` for frontend synchronization.
3. **Address-determinism is per fresh chain.** Everything is plain `CREATE` from anvil account #0.
   `make bootstrap` asserts a fresh chain (block 0, nonce 0, no Multicall3) and refuses to reuse one,
   so a clean run is reproducible. Re-running `make deploy` manually on a used chain gives new
   addresses; `export.py` will refuse to export such a run, and the frontend only consumes the export
   through `pnpm sync:anvil`.
4. **`make seed` is one-shot per deployment.** Running it twice on the same deployment reverts on
   "fixture entry is not claimable" (the first run consumed the shares) and on duplicate MemberNFT
   names. Re-run `make deploy && make seed` for a fresh stack.
5. **Phase timing is block-based.** `PHASE_ORIGIN_PHASE_BLOCKS=120` at `--block-time 1` is 2 minutes
   per phase, ~8 minutes per round. It is not wall-clock: a frozen chain freezes the phase.
6. **No BSC profile.** Only `anvil31337_dev` exists here; the siblings have no BSC deploy params
   either (only fork configs in `compatibility/`).
7. **dex must be built already.** `dex/build/` is gitignored upstream; this repo will not build it
   for you (that writes into `dex/`).

---

## 13. Layout

```text
anvil/
├── Makefile                     thin wrappers over script/local.sh
├── foundry.toml                 solc 0.8.37/osaka/200, allow_paths, fs_permissions, no metadata
├── remappings.txt               sibling remappings (via .siblings/ symlinks)
├── siblings.lock                pinned commits for `make bootstrap PINNED=1` (url + sha per sibling)
├── .siblings/{core,action,group-chat,libs,dex,periphery,tools}   committed relative symlinks (read-only inputs)
├── .siblings-pinned/<repo>      gitignored `git worktree` snapshots created by `make pin` (PINNED=1)
├── params/anvil31337_dev/       OUR parameter set, one file per area
│   ├── network.params           chain id, anvil host/port/block-time/gas/base-fee
│   ├── accounts.params          anvil mnemonic, deploy account index, seed account range
│   ├── dex.params               WETH name/symbol, feeToSetter lock
│   ├── multicall3.params        canonical address, upstream signed tx + sha256, funding
│   ├── airdrop.params           snapshot path + total share + synthetic fixture provenance
│   ├── core.params              token/phase/mint/submit/stake + genesis airdrop root/delay/URI
│   ├── action.params            no numeric parameter; only the note about link-time libraries
│   ├── group-chat.params        rounds/admins/ban thresholds/plugin slots
│   └── seed.params              how many members, liquidity, ETH
├── script/
│   ├── local.sh                 orchestrator (preflight|fixture|anvil|stop|multicall3|libraries|deploy|seed|export|verify|build|clean|bootstrap)
│   ├── pin-siblings.sh          make pin / pin-status / unpin / pin-lock (see "Pinned siblings")
│   ├── DeployLibraries.s.sol    deploys the 4 link targets first
│   ├── DeployLocal.s.sol        WETH + UniswapV2 + core (incl. AirdropDistributor) + action + group-chat
│   │                            + periphery/tools (BatchTransfer, LOVE20Hub — appended last)
│   ├── SeedFlow.s.sol           round advance, claims, MemberNFTs, liquidity via Stake, ETH top-ups
│   ├── gen_airdrop_fixture.py   merkle tree + proofs + self-verification
│   ├── export.py                deployment JSON + ABIs + snapshot copy
│   ├── verify.sh                cast assertions -> export/VERIFIED.md
│   └── lib/params.sh            .params loader (lexical 1e18 expansion, required-key asserts)
├── fixtures/
│   ├── airdrop/anvil31337_dev.json          the snapshot (10 accounts, proofs)
│   └── multicall3/multicall3_signed_tx.hex  upstream pre-signed deployment tx
└── export/                      frontend deliverables (§5)
```

## 14. Troubleshooting

| symptom | cause / fix |
|---|---|
| `a chain is already running at http://127.0.0.1:8545; bootstrap only deploys onto a fresh chain` | bootstrap purposefully refuses to reuse a chain. Run `make stop && make clean && make bootstrap` for the same port; add `PORT=<port>` when the chain was a non-default one. |
| `refusing to deploy onto a used chain: block=…, deployer nonce=…` | your chain was not clean (usually a reused/old anvil). `make stop && make clean && make bootstrap`; never set a nonce by hand. |
| `deployment did not start from nonce 0` from `make export` | the broadcast came from a used chain. Rebuild from scratch; the export is intentionally refused. |
| `something is already serving chain 31337 at http://127.0.0.1:8545` | another process holds the port. Stop it yourself (this repo never kills foreign processes), or use `PORT=` for an explicitly separate chain (runtime state then lives in `.anvil/<port>/`). |
| `missing dex artifact: ../dex/build/...` | run `make -C ../dex build` yourself (this repo will not write into `dex/`). |
| `failed to parse, too many arguments passed` | you are passing multiple `--libraries` values to the CLI; use `FOUNDRY_LIBRARIES` (already done by `script/local.sh`). |
| `fixture entry is not claimable` from `make seed` | seed already ran on this deployment: `make deploy && make seed`. |
| `vm.getCode: multiple matching artifacts found` | the `.siblings/` symlinks are missing, so foundry compiled a sibling file twice. `make preflight` recreates them; then `make clean`. |
| verification reports `no code at …` | the chain was reset/restarted after `make deploy`. Re-run `make bootstrap` (add `PORT=` if it was a non-default chain). |
| `no .anvil/8555/anvil.pid - was the chain started by this repo?` | the e2e chain's runtime record is missing. Check `lsof -nP -iTCP:8555`; if nothing listens, the frontend's `pnpm e2e` bootstraps a fresh chain. Never point this at 8545. |

## 15. Credits

Protocol sources: the sibling repositories (`core`, `action`, `group-chat`, `libs`, `dex`) — compiled
read-only, never modified. Airdrop: core's `AirdropDistributor` (snapshot format follows
`LOVE20TKM/burn`). Multicall3: `mds1/multicall` (upstream
pre-signed deployment transaction). UniswapV2: `Uniswap/v2-core` + `v2-periphery` via `dex/build`.
