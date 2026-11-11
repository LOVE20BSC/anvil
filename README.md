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

The four sibling repositories (`core/`, `action/`, `group-chat/`, `libs/`, `dex/`) are **read-only
inputs**. Nothing in this repo writes into them. Their Solidity sources are compiled through the
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
make stop               # stop the anvil this repo started
make clean              # stop this repo's anvil; remove out/ cache/ broadcast/ .anvil/ and exports
```

**The address book is reproducible only from a fresh chain.** `make bootstrap` refuses to start if
any chain is already running, and before the first transaction it asserts block 0 / deployer nonce 0
/ no Multicall3 (`make fresh`). A used chain is never exported: `script/export.py` re-checks that the
DeployLibraries broadcast starts at nonce 0 and that DeployLocal continues immediately after it.
Never make the chain match a committed address book by setting a nonce — addresses always follow the
deployment.

Other ports (the second anvil on a machine will collide otherwise):

```bash
make bootstrap PORT=8555        # moves both the anvil process and every RPC URL
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
| 4 | anvil | `make anvil` | chain 31337 on 8545, automine; **bootstrap refuses to reuse any running chain** |
| 5 | fresh guard | `make fresh` | deployer nonce 0 + no Multicall3 (bootstrap also requires block 0); fails loudly on a used chain |
| 6 | Multicall3 | `make multicall3` | `0xcA11bde05977b3631167028862bE2a173976CA11` from the upstream pre-signed tx |
| 7 | linked libraries | `make libraries` | the 4 action libraries (CREATE at deployer nonces 0..3, addresses to `export/libraries.json`) |
| 8 | deploy | `make deploy` | WETH, UniswapV2, Airdrop, core (7), action (4), group-chat (12) |
| 9 | seed | `make seed` | airdrop claims, 5 MemberNFTs, liquidity + governance stake, ETH top-ups |
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

## 3. Deployment order (and the one place the brief had to be corrected)

```
Multicall3                      canonical address, upstream signed tx
WETH9Configurable               dex/script/WETH9Configurable.sol, source compiled by this repo
UniswapV2Factory                dex/build artifact (not recompiled), feeToSetter = 0 (fee locked)
UniswapV2Router02               dex/build artifact (not recompiled), (factory, WETH)
Airdrop                         ← MUST be before core: it is Launch's distributor
Phase
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
```

**Why the Airdrop is not last.** The brief lists Airdrop as step 6 (after group-chat), but
`Launch`'s constructor takes `distributor` and the `LOVE20Token` constructor mints the whole
`LAUNCH_AMOUNT` to it. There is no setter. Deploying the Airdrop after `Launch` would leave the
genesis supply in the wrong hands forever, so the Airdrop is deployed immediately before `Launch`
and its address is passed as `distributor` programmatically (never from a params file). This is the
only ordering change; it is also asserted after deployment
(`LOVE20Token.balanceOf(airdrop) == LAUNCH_AMOUNT`, see `DeployLocal._validateCore`).

**Core ordering is the sibling repo's own.** `DeployLocal` inherits `DeployCore` from
`core/script/deploy/DeployCore.s.sol` and calls its `_deployContracts`, so the CREATE nonce
predictions in `DeployCore._predictAddresses()` (`MemberNFT = nonce+2`, `Vote = nonce+5`,
`Mint = nonce+6`) are literally the same code path, including the `require`s that fail loudly if a
prediction does not match. `_predictor()` is overridden to read `DEPLOYER_ADDRESS` from the
environment instead of `msg.sender`, which cannot drift from the broadcast account.

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
| `AIRDROP_ADDRESS` | Airdrop | `0xa513E6E4b8f2a923D98304ec87F64353C4D5C853` | 9 |
| `LOVE20_TOKEN_ADDRESS` | LOVE20Token | `0x8aCd85898458400f7Db866d53FCFF6f0D49741FF` | 11 |
| `PHASE_ADDRESS` | Phase | `0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6` | 10 |
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
├── abis/<Contract>.json               19 ABI arrays (top-level `abi` from the sibling out/ artifacts)
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
  "airdrop": { "address": "0x…", "merkleRoot": "0x…", "totalShare": "1000000000000000000", "snapshotFile": "…" },
  "params": { "tokenName": "TestLOVE20@TestWETH", "phaseOriginPhaseBlocks": 120, "groupActionSplits": ["…"] }
}
```

`deployer`, `params.*` and `uniswapV2.feeTo` are data, not an echo of the shell that happened to run
`make export`: `export.py` takes the deployer from the deploy broadcast receipts (and asserts it
agrees with `DEPLOYER_ADDRESS` when that is set), parses the token/phase/seed/split values out of
`params/anvil31337_dev/*.params`, and calls `feeTo()` (and `feeToSetter()`) on the factory over the
live node. A non-zero `feeTo` is exported as-is with a warning; the deployment's
`feeToSetter = address(0)` lock is what makes it zero on this profile, and `make verify` asserts both
the chain value and the exported value. Missing inputs fail the export instead of writing
`""`/`0` placeholders. `rpcUrl` stays the profile's canonical endpoint from `network.params`
(`http://127.0.0.1:8545`, what a fresh `make bootstrap` serves) even when a one-off `PORT=`
override starts the chain elsewhere.

ABIs exported: `MemberNFT`, `LOVE20Token`, `Launch`, `Stake`, `Submit`, `Vote`, `Mint`, `Phase`,
`ActionTarget`, `LpExecutor`, `GroupActionExecutor`, `GroupServiceExecutor`, `GroupChat`, `Airdrop`,
`UniswapV2Router02`, `UniswapV2Factory`, `UniswapV2Pair`, `Multicall3`, plus `WETH9` (the UI needs
`deposit()`/`withdraw()`).

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
| ETH | account #0 tops every seeded account up to `SEED_ETH_PER_ACCOUNT` (100 ETH) | 5 accounts ≥ 100 ETH (anvil already funds them, so usually a no-op) |
| Airdrop claim | each of the first `SEED_MEMBER_COUNT` (5) accounts calls `claim(token, self, share, proof)` with its own key | 5 × 1e26 tokens claimed; accounts 5–9 left unclaimed for the **claim UI** |
| MemberNFT | each of the 5 claims, then `approve` + `mint("Testdev-member-<i>")` (the name is stored verbatim) | 5 identities, ids 1–5, 9e20 burned per mint |
| Liquidity + governance | member 0 wraps 100 ETH → `WETH.deposit`, approves `Stake`, calls `Stake.stakeLiquidity(token, 2e23, 1e20, 5e16, 1, 1)` | pair reserves **200 000 token / 100 WETH** (price 2000 token/ETH), 4.472135954999579391818e21 LP minted to `Stake`, equal `govVotes` |

**Liquidity goes through `Stake.stakeLiquidity`, not `Router.addLiquidity`.** `Launch._ensurePair()`
only *creates* the pair (zero reserves). Routing the first liquidity through `Stake` does two things
at once: it gives the pair its reserves, and it gives a member actual governance weight
(`liquidityShares → govVotes`), so the seeded chain can vote/submit/claim rewards without a second
manual step. The staker is member id 1 (anvil account #0).

The airdrop fixture covers **10 accounts** (anvil indices 0–9), **1e17 share each**, total 1e18, so
the airdrop page has both claimed (0–4) and claimable (5–9) state to exercise.

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
* No copies of sibling sources except the vendored TKM `Airdrop` (see §9).
* No keystore, no `.account` file: the deploy key is derived from the anvil mnemonic in
  `params/anvil31337_dev/accounts.params`.

---

## 9. Airdrop

`src/vendor/Airdrop.sol` is a verbatim copy of `LOVE20TKM/burn/src/Airdrop.sol` @
`b32bb821d2131c5aef09aa661f9681ddf1741fcf`, with a header recording the origin. Two mechanical edits
only: the pragma (`=0.8.17` → `=0.8.37`) and the OpenZeppelin 4.x `security/ReentrancyGuard.sol` →
5.x `utils/ReentrancyGuard.sol` import (the siblings vendor OZ 5.6.1). `IAirdrop` is vendored next
to it.

* **`onTokenLaunched` is not implemented** by this contract (checked: it does not inherit
  `ILaunchDistributor`). `DeployLocal._validateCore` asserts it at runtime with a `staticcall` that
  **must** fail, so the docs cannot silently go stale. Consequence: child-token launches must use
  `DistributorMode.NoCallback` on this chain. The first token does not need the callback — `Launch`
  mints the genesis supply to the Airdrop in the `LOVE20Token` constructor.
* Claim math is the canonical one: `amount = balanceOf(airdrop) * share / remainingShare(token)`.
  Shares are relative, never absolute amounts.
* Fixture (`fixtures/airdrop/anvil31337_dev.json`), generated by `script/gen_airdrop_fixture.py`:
  double-hashed keccak leaves `keccak(keccak(abi.encode(account, share)))`, sorted-pair internal
  nodes, unpaired last node promoted, every proof re-verified before writing. Numbers are emitted as
  decimal **strings** (canonical burn format, 1e18 is not JS-safe as a number).
* Provenance is synthetic and labelled as such: `sourceChainId 31337`, `sourceBlockNumber 1`,
  `sourceBurnAddress 0x…C0FFEE01` — this chain has no Burn deployment, so there is no real burn
  activity to snapshot.

---

## 10. Verification

`make verify` (`script/verify.sh`) is independent of the deploy scripts: every value is a `cast`
call against the running node, and it exits non-zero on any failure. Full output:
[`export/VERIFIED.md`](export/VERIFIED.md).

Headline values from the verified run:

| check | value |
|---|---|
| chain id | `31337` |
| code present | all 34 exported addresses |
| `Phase.currentPhase()` | `1` on the committed run (the chain mines every second, so it advances afterwards) |
| `Phase.ORIGIN_PHASE_BLOCKS()` | `120` (= 2 min per phase at `--block-time 1`) |
| `MemberNFT.totalSupply()` | `5` |
| `MemberNFT.balanceOf(seed[0])` | `1` |
| `LOVE20Token.balanceOf(seed[0])` | `99799100000000000000000000` |
| `LOVE20Token.balanceOf(airdrop)` | `500000000000000000000000000` |
| pair reserves | `200000000000000000000000` token / `100000000000000000000` WETH |
| LP held by `Stake` | `4472135954999579391818` |
| `Stake.totalLiquidityShares` | `4472135954999579391818` |
| `Airdrop.merkleRoot()` | `0x046a5d5357fd4da6986a88fb1e2baf3603375d2099ce9f46b9d6fbe333c6c404` (= fixture) |
| `Airdrop.totalShare()` | `1000000000000000000` (= fixture) |
| `Airdrop.claimableAmount(unclaimed fixture entry)` | `100000000000000000000000000` |
| `Airdrop.isClaimed(seed[0])` | `true` |
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

# a one-off chain on another port (only one chain at a time: the frontend has one RPC)
make stop && make clean
make bootstrap PORT=8556

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
2. **Airdrop has no `onTokenLaunched`.** Child-token launches must use `NoCallback` mode on this
   chain (see §9).
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

## Blocked

**Nothing is blocked.** Every step of the brief runs end to end. One item is a deliberate,
documented deviation rather than a blocker: the **Airdrop is deployed before core** instead of last
(§3 — `Launch`'s `distributor` is a constructor argument and the genesis supply is minted inside
it). No input is missing; `make bootstrap` ships 8545 as the default.

---

## 13. Layout

```text
anvil/
├── Makefile                     thin wrappers over script/local.sh
├── foundry.toml                 solc 0.8.37/osaka/200, allow_paths, fs_permissions, no metadata
├── remappings.txt               sibling remappings (via .siblings/ symlinks)
├── .siblings/{core,action,group-chat,libs,dex}   committed relative symlinks (read-only inputs)
├── params/anvil31337_dev/       OUR parameter set, one file per area
│   ├── network.params           chain id, anvil host/port/block-time/gas/base-fee
│   ├── accounts.params          anvil mnemonic, deploy account index, seed account range
│   ├── dex.params               WETH name/symbol, feeToSetter lock
│   ├── multicall3.params        canonical address, upstream signed tx + sha256, funding
│   ├── airdrop.params           snapshot path + provenance to assert
│   ├── core.params              token/phase/mint/submit/stake values
│   ├── action.params            GROUP_ACTION_SPLITS (+ note: libraries are link-time)
│   ├── group-chat.params        rounds/admins/ban thresholds/plugin slots
│   └── seed.params              how many members, how much liquidity, how much ETH
├── script/
│   ├── local.sh                 orchestrator (preflight|fixture|anvil|stop|multicall3|libraries|deploy|seed|export|verify|build|clean|bootstrap)
│   ├── DeployLibraries.s.sol    deploys the 4 link targets first
│   ├── DeployLocal.s.sol        WETH + UniswapV2 + Airdrop + core + action + group-chat
│   ├── SeedFlow.s.sol           claims, MemberNFTs, liquidity via Stake, ETH top-ups
│   ├── gen_airdrop_fixture.py   merkle tree + proofs + self-verification
│   ├── export.py                deployment JSON + ABIs + snapshot copy
│   ├── verify.sh                cast assertions -> export/VERIFIED.md
│   └── lib/params.sh            .params loader (lexical 1e18 expansion, required-key asserts)
├── src/vendor/                  Airdrop.sol + IAirdrop.sol (the only vendored sources)
├── fixtures/
│   ├── airdrop/anvil31337_dev.json          the snapshot (10 accounts, proofs)
│   └── multicall3/multicall3_signed_tx.hex  upstream pre-signed deployment tx
└── export/                      frontend deliverables (§5)
```

## 14. Troubleshooting

| symptom | cause / fix |
|---|---|
| `a chain is already running at http://127.0.0.1:8545; bootstrap only deploys onto a fresh chain` | bootstrap purposefully refuses to reuse a chain. Run `make stop && make clean && make bootstrap`. |
| `refusing to deploy onto a used chain: block=…, deployer nonce=…` | your chain was not clean (usually a reused/old anvil). `make stop && make clean && make bootstrap`; never set a nonce by hand. |
| `deployment did not start from nonce 0` from `make export` | the broadcast came from a used chain. Rebuild from scratch; the export is intentionally refused. |
| `something is already serving chain 31337 at http://127.0.0.1:8545` | another process holds the port. Stop it yourself (this repo never kills foreign processes), or use `PORT=` for an explicitly separate chain. |
| `missing dex artifact: ../dex/build/...` | run `make -C ../dex build` yourself (this repo will not write into `dex/`). |
| `failed to parse, too many arguments passed` | you are passing multiple `--libraries` values to the CLI; use `FOUNDRY_LIBRARIES` (already done by `script/local.sh`). |
| `fixture entry is not claimable` from `make seed` | seed already ran on this deployment: `make deploy && make seed`. |
| `vm.getCode: multiple matching artifacts found` | the `.siblings/` symlinks are missing, so foundry compiled a sibling file twice. `make preflight` recreates them; then `make clean`. |
| verification reports `no code at …` | the chain was reset/restarted after `make deploy`. Re-run `make bootstrap`. |

## 15. Credits

Protocol sources: the sibling repositories (`core`, `action`, `group-chat`, `libs`, `dex`) — compiled
read-only, never modified. Airdrop: `LOVE20TKM/burn`. Multicall3: `mds1/multicall` (upstream
pre-signed deployment transaction). UniswapV2: `Uniswap/v2-core` + `v2-periphery` via `dex/build`.
