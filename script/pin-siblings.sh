#!/usr/bin/env bash
# Pinned siblings for the local chain: read-only `git worktree` snapshots of the sibling repositories
# at the commits recorded in siblings.lock.
#
# Why: the anvil build compiles the sibling checkouts (../core, ../action, ../group-chat, ../libs,
# ../dex, ../periphery, ../tools) through the .siblings/ symlinks. While a sibling is mid-change
# (for example core's IStake.stakeLiquidity gaining a deadline), every `make bootstrap` fails to
# compile even though the change has nothing to do with the local chain. `make bootstrap PINNED=1`
# instead compiles the worktrees created here, so the chain stays reproducible until we deliberately
# bump siblings.lock. PINNED=0 (the default) is untouched: live checkouts through .siblings/.
#
#   pin      create/refresh .siblings-pinned/<repo> at the lock's commit (idempotent)
#   status   live HEAD vs lock vs pinned worktree, per repo
#   clean    remove the worktrees (git worktree remove) and .siblings-pinned/
#   relock   rewrite siblings.lock from the live HEADs (bump; refuses on a dirty sibling)
#
# Layout / invariants:
#   * Every worktree lives in THIS repo (.siblings-pinned/, gitignored) but is registered in the
#     sibling's own .git/worktrees/, so `clean` must use `git worktree remove`, never a bare rm.
#     Registering a worktree does not touch the sibling's working tree or its `git status`.
#   * Sibling `lib/` is a set of submodules and `git worktree add` does not check submodules out.
#     The build reaches exactly one of them (core/lib, through the @forge-std/ and
#     @openzeppelin/ remappings), so a submodule is hard-link copied from the live checkout only
#     when the pinned commit records the same submodule commit as the live checkout; the ones the
#     build actually reads additionally require the live submodule to be checked out at that
#     commit, otherwise this script fails instead of silently compiling a different submodule.
#   * dex's creation bytecode comes from the gitignored ../dex/build, so that directory is
#     hard-link copied next to the pinned dex worktree and read from there (DEX_ARTIFACT_ROOT).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

LOCK="$ROOT/siblings.lock"
PINNED_DIR="$ROOT/.siblings-pinned"
# Fixed order (also the order the lock is written in): core first because action/periphery/group-chat
# submodules point back at it.
REPOS=(core action group-chat libs dex periphery tools)

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
step() { printf "${BLUE}==>${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}  ok${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}  warn${NC} %s\n" "$*"; }
die()  { printf "${RED}  error${NC} %s\n" "$*" >&2; exit 1; }

# ------------------------------------------------------------------------------------------------
# lock helpers
# ------------------------------------------------------------------------------------------------
lock_query() {
    # lock_query repos.<repo>.<field>
    python3 - "$LOCK" "$1" <<'PY'
import json
import sys

with open(sys.argv[1]) as fh:
    node = json.load(fh)
for part in sys.argv[2].split("."):
    if not isinstance(node, dict) or part not in node:
        raise SystemExit(f"missing key {part!r} in {sys.argv[2]!r}")
    node = node[part]
if not isinstance(node, str) or not node:
    raise SystemExit(f"{sys.argv[2]} is not a non-empty string")
print(node)
PY
}

require_lock() {
    [ -f "$LOCK" ] || die "missing $LOCK - it records the pinned commits (see README 'Pinned siblings')"
    for repo in "${REPOS[@]}"; do
        lock_query "repos.$repo.url" >/dev/null 2>&1 \
            || die "$LOCK: no repos.$repo.url (the lock must list: ${REPOS[*]})"
        lock_query "repos.$repo.sha" >/dev/null 2>&1 \
            || die "$LOCK: no repos.$repo.sha (the lock must list: ${REPOS[*]})"
    done
}

sibling_path() { printf '%s/../%s' "$ROOT" "$1"; }
pinned_path()  { printf '%s/%s' "$PINNED_DIR" "$1"; }

# The submodule paths the anvil build can actually reach, derived from remappings.txt:
# a target of `.siblings/<repo>/lib/<name>/...` means sources under <repo>/lib/<name> are compiled.
anvil_lib_paths() {
    local line target repo rest sub
    while IFS= read -r line; do
        target="${line#*=}"
        case "$target" in .siblings/*) ;; *) continue ;; esac
        target="${target#.siblings/}"
        repo="${target%%/*}"
        rest="${target#*/}"
        case "$rest" in lib/*) ;; *) continue ;; esac
        rest="${rest#lib/}"
        sub="${rest%%/*}"
        [ -n "$sub" ] && printf '%s/lib/%s\n' "$repo" "$sub"
    done <"$ROOT/remappings.txt"
}

is_anvil_reachable_lib() {
    local wanted="$1" known
    while IFS= read -r known; do
        [ "$known" = "$wanted" ] && return 0
    done < <(anvil_lib_paths)
    return 1
}

# ------------------------------------------------------------------------------------------------
# git worktree helpers
# ------------------------------------------------------------------------------------------------
is_registered_worktree() {
    # is_registered_worktree <repo> <abs-dir>
    local repo="$1" dir="$2" sibling
    sibling="$(sibling_path "$repo")"
    git -C "$sibling" worktree list --porcelain 2>/dev/null | grep -Fxq "worktree $dir"
}

worktree_head() {
    git -C "$1" rev-parse --verify HEAD 2>/dev/null || true
}

remove_worktree() {
    # Only ever touches <repo>'s registered worktree in .siblings-pinned (guarded below); the sibling
    # checkout itself is never written to.
    local repo="$1" dir="$2" sibling
    sibling="$(sibling_path "$repo")"
    case "$dir" in
        "$PINNED_DIR"/*) ;;
        *) die "refusing to remove $dir: it is not under $PINNED_DIR" ;;
    esac
    if is_registered_worktree "$repo" "$dir"; then
        # --force also drops a worktree whose files were changed by a build; the deregistration is
        # what matters (a bare rm would leave a stale entry in ../<repo>/.git/worktrees/).
        git -C "$sibling" worktree remove --force "$dir" >/dev/null 2>&1 || true
    fi
    [ -e "$dir" ] && rm -rf "$dir"
    git -C "$sibling" worktree prune >/dev/null 2>&1 || true
    return 0
}

# ------------------------------------------------------------------------------------------------
# pin
# ------------------------------------------------------------------------------------------------
pin_libs() {
    # Materialise <repo>/lib from the live checkout, submodule by submodule, under two rules:
    #   * the pinned commit and the live checkout must record the same submodule commit, and the
    #     live submodule must actually be checked out at it (hard links share the bytes!);
    #   * an unreachable submodule (not read by any remapping) that does not meet that rule is
    #     skipped with a warning - copying it is what would be wrong, skipping costs nothing.
    local repo="$1" sha="$2" dir sibling meta path mode type subsha live_sub actual_sub rel copied=0 skipped=0
    dir="$(pinned_path "$repo")"
    sibling="$(sibling_path "$repo")"

    # No lib/ directory at all: nothing to do (libs has none).
    if [ -z "$(git -C "$sibling" ls-tree "$sha" lib/)" ]; then
        ok "$repo: pinned commit has no lib/ submodules"
        return 0
    fi

    while IFS=$'\t' read -r meta path; do
        [ -n "${path:-}" ] || continue
        # meta is "<mode> <type> <sha>"
        set -- $meta
        mode="$1" type="$2" subsha="$3"
        if [ "$mode" != "160000" ]; then
            warn "$repo/$path: pinned entry is mode $mode (not a gitlink); skipped (not needed by the build)"
            continue
        fi
        rel="$repo/$path"
        live_sub="$(git -C "$sibling" ls-tree HEAD -- "$path" | awk '{print $3}')"
        actual_sub="$(git -C "$sibling/$path" rev-parse --verify HEAD 2>/dev/null || true)"

        if [ "$live_sub" = "$subsha" ] && [ "$actual_sub" = "$subsha" ]; then
            if [ ! -e "$sibling/$path" ] || [ -z "$(ls -A "$sibling/$path" 2>/dev/null)" ]; then
                die "$repo: submodule $path is empty in $sibling
    The pinned commit records $subsha and the live checkout agrees, but the directory is not
    checked out, so it cannot be hard-link copied. Initialise it, then re-run 'make pin':
      git -C ../$repo submodule update --init --recursive $path"
            fi
            mkdir -p "$dir/lib"
            rm -rf "$dir/$path"
            cp -al "$sibling/$path" "$dir/$path" || die "cp -al $sibling/$path -> $dir/$path failed"
            copied=$((copied + 1))
            continue
        fi

        # Mismatch: the pinned commit wants one submodule commit, the live checkout has another.
        if is_anvil_reachable_lib "$rel"; then
            die "$repo: pinned $repo@$sha needs $path@$subsha, but the live checkout has
    lib-tree $([ -n "$live_sub" ] && printf '%s' "$live_sub" || printf '<absent>'), checked out $([ -n "$actual_sub" ] && printf '%s' "$actual_sub" || printf '<not initialised>').
    $rel is compiled by this project (its remapping is in remappings.txt), so pinning it from the
    live checkout would silently compile a different submodule. Neither the live checkout nor
    siblings.lock is touched by this script. Pick one:
      # (a) make the live submodule match the pinned commit, then re-run 'make pin':
      #     git -C ../$repo/lib/${path#lib/} checkout $subsha
      # (b) bump the pin to the live state (only after a green PINNED=0 bootstrap):
      #     make pin-lock && make unpin && make pin"
        fi
        warn "$repo/$path: pinned wants $subsha, live has $([ -n "$live_sub" ] && printf '%s' "$live_sub" || printf '<absent>'); skipped (no remapping reads it)"
        skipped=$((skipped + 1))
    done < <(git -C "$sibling" ls-tree "$sha" lib/)

    if [ "$copied" -eq 0 ] && [ "$skipped" -gt 0 ]; then
        warn "$repo: pinned worktree has no lib/ content (nothing to copy)"
    else
        ok "$repo: lib copied ($copied submodule(s)$([ "$skipped" -gt 0 ] && printf ', %s skipped' "$skipped"))"
    fi
}

pin_dex_build() {
    local repo="$1" dir src artifact
    [ "$repo" = "dex" ] || return 0
    dir="$(pinned_path "$repo")"
    src="$ROOT/../dex/build"
    for artifact in \
        core/UniswapV2Factory.sol/UniswapV2Factory.json \
        core/UniswapV2Pair.sol/UniswapV2Pair.json \
        periphery/UniswapV2Router02.sol/UniswapV2Router02.json; do
        [ -s "$src/$artifact" ] || die "missing dex build artifact: ../dex/build/$artifact
    The pinned dex worktree has no build output (build/ is gitignored in ../dex), so the published
    creation bytecode has to be snapshotted from the live checkout. Build it first:
      make -C ../dex build
    then re-run 'make pin'."
    done
    rm -rf "$dir/build"
    cp -al "$src" "$dir/build" || die "cp -al ../dex/build -> ${dir#"$ROOT"/}/build failed"
    ok "dex: build/ snapshotted (.siblings-pinned/dex/build)"
}

pin_one() {
    local repo="$1" sha want_url sibling dir head log
    sha="$(lock_query "repos.$repo.sha")"
    want_url="$(lock_query "repos.$repo.url")"
    sibling="$(sibling_path "$repo")"
    dir="$(pinned_path "$repo")"

    [ -d "$sibling" ] || die "missing sibling checkout: $sibling
    Pinned siblings are snapshots of the local checkouts (this script does not clone). Clone the repo
    next to this one, or fix the path, then re-run 'make pin'."

    git -C "$sibling" cat-file -e "$sha^{commit}" 2>/dev/null || die "$repo: pinned commit $sha is not in $sibling
    A pin only ever uses local commits (no network). Make the commit available first, e.g.:
      git -C ../$repo fetch origin $sha
    then re-run 'make pin'."

    local have_url
    have_url="$(git -C "$sibling" remote get-url origin 2>/dev/null || true)"
    if [ -n "$have_url" ] && [ "$have_url" != "$want_url" ]; then
        warn "$repo: ../$repo origin is $have_url, siblings.lock says $want_url (pin uses the local checkout)"
    fi

    if [ -d "$dir" ]; then
        head="$(worktree_head "$dir")"
        if [ "$head" = "$sha" ] && is_registered_worktree "$repo" "$dir"; then
            ok "$repo: already pinned at ${sha:0:7}"
            pin_libs "$repo" "$sha"
            pin_dex_build "$repo"
            return 0
        fi
        warn "$repo: refreshing stale pinned worktree (HEAD ${head:-<none>}, lock wants ${sha:0:7})"
        remove_worktree "$repo" "$dir"
    fi

    mkdir -p "$PINNED_DIR"
    log="$(mktemp)"
    if ! git -C "$sibling" worktree add --detach "$dir" "$sha" >"$log" 2>&1; then
        sed 's/^/      /' "$log" >&2
        rm -f "$log"
        die "git worktree add failed for $repo@${sha:0:7} -> ${dir#"$ROOT"/}
    Read the git output above. The two usual causes are an unregistered leftover directory (remove
    it: 'make unpin && make pin') and a commit object that is not present (fetch it, see above)."
    fi
    rm -f "$log"

    head="$(worktree_head "$dir")"
    [ "$head" = "$sha" ] || die "$repo: worktree is at ${head:-<none>} after add, expected $sha"
    ok "$repo: pinned at ${sha:0:7} -> ${dir#"$ROOT"/}"
    pin_libs "$repo" "$sha"
    pin_dex_build "$repo"
}

cmd_pin() {
    require_lock
    step "pin siblings (read-only worktrees from $(basename "$LOCK"))"
    # --no-index: the path does not exist yet on the first run, and check-ignore otherwise skips
    # paths that are not in the index/worktree.
    git check-ignore -q --no-index "$PINNED_DIR/" \
        || die "${PINNED_DIR#"$ROOT"/}/ is not gitignored - 'make pin' would dirty this repo's git status.
    Add it to .gitignore first (it is part of the committed setup)."

    local repo
    for repo in "${REPOS[@]}"; do
        pin_one "$repo"
    done

    step "pinned siblings ready - build them with: make bootstrap PINNED=1"
    printf '    %-12s %s\n' "repo" "pinned commit"
    for repo in "${REPOS[@]}"; do
        printf '    %-12s %s\n' "$repo" "$(worktree_head "$(pinned_path "$repo")")"
    done
    ok "PINNED=1 will compile .siblings-pinned/* instead of the live sibling checkouts"
}

# ------------------------------------------------------------------------------------------------
# status
# ------------------------------------------------------------------------------------------------
cmd_status() {
    require_lock
    step "pinned siblings status (siblings.lock)"
    printf '    %-12s %-9s %-9s %-9s %s\n' "repo" "lock" "pinned" "live" "state"
    local repo sha want_head live_head dir state ready=1
    for repo in "${REPOS[@]}"; do
        sha="$(lock_query "repos.$repo.sha")"
        dir="$(pinned_path "$repo")"
        want_head="$(worktree_head "$dir")"
        live_head="$(worktree_head "$(sibling_path "$repo")")"
        if [ ! -d "$dir" ]; then
            state="NOT PINNED"
            ready=0
        elif [ -z "$want_head" ]; then
            state="NOT A GIT WORKTREE"
            ready=0
        elif ! is_registered_worktree "$repo" "$dir"; then
            state="NOT REGISTERED (re-run make pin)"
            ready=0
        elif [ "$want_head" != "$sha" ]; then
            state="STALE (re-run make unpin && make pin)"
            ready=0
        elif [ "$want_head" = "$live_head" ]; then
            state="pinned"
        else
            state="pinned (live is ${live_head:0:7})"
        fi
        printf '    %-12s %-9s %-9s %-9s %s\n' \
            "$repo" "${sha:0:7}" "$([ -n "$want_head" ] && printf '%s' "${want_head:0:7}" || printf '-')" \
            "$([ -n "$live_head" ] && printf '%s' "${live_head:0:7}" || printf '-')" "$state"
    done

    local artifact missing=0
    for artifact in \
        core/UniswapV2Factory.sol/UniswapV2Factory.json \
        core/UniswapV2Pair.sol/UniswapV2Pair.json \
        periphery/UniswapV2Router02.sol/UniswapV2Router02.json; do
        [ -s "$PINNED_DIR/dex/build/$artifact" ] || { missing=1; break; }
    done
    if [ "$missing" = "0" ]; then
        ok "dex build snapshot present (.siblings-pinned/dex/build)"
    else
        warn "dex build snapshot missing (.siblings-pinned/dex/build) - re-run 'make pin'"
        ready=0
    fi

    local reachable
    reachable="$(anvil_lib_paths | paste -sd' ' -)"
    ok "compiled submodules (from remappings.txt): ${reachable:-none}"

    if [ "$ready" = "1" ]; then
        ok "ready: make bootstrap PINNED=1"
    else
        warn "not ready: run 'make pin' (or 'make unpin && make pin' if stale); PINNED=1 bootstrap will refuse"
        return 1
    fi
}

# ------------------------------------------------------------------------------------------------
# clean (unpin)
# ------------------------------------------------------------------------------------------------
cmd_clean() {
    step "unpin siblings (remove .siblings-pinned/ worktrees)"
    local repo dir sibling dirty=0 status_out
    for repo in "${REPOS[@]}"; do
        dir="$(pinned_path "$repo")"
        sibling="$(sibling_path "$repo")"
        [ -d "$sibling" ] || { warn "$repo: ../$repo is gone; nothing to deregister"; continue; }
        if is_registered_worktree "$repo" "$dir"; then
            remove_worktree "$repo" "$dir"
            ok "$repo: worktree removed and deregistered"
        elif [ -d "$dir" ]; then
            rm -rf "$dir"
            git -C "$sibling" worktree prune >/dev/null 2>&1 || true
            warn "$repo: removed unregistered leftover directory ${dir#"$ROOT"/}"
        else
            ok "$repo: not pinned"
        fi
        # The whole point of 'git worktree remove' (instead of rm -rf) is that the sibling repo is
        # left exactly as it was: prove it instead of asserting it.
        status_out="$(git -C "$sibling" status --porcelain 2>/dev/null || true)"
        if [ -n "$status_out" ]; then
            warn "$repo: ../$repo working tree is not clean (pre-existing or owner's edits - unpin does not write there): $(printf '%s' "$status_out" | head -3 | tr '\n' ' ')"
            dirty=1
        fi
    done
    # .siblings/ symlinks are the PINNED=0 wiring and must survive an unpin.
    local link
    for link in "${REPOS[@]}"; do
        [ -L "$ROOT/.siblings/$link" ] || warn ".siblings/$link symlink is missing (PINNED=0 preflight recreates it)"
    done
    if [ -d "$PINNED_DIR" ]; then
        rm -rf "$PINNED_DIR"
    fi
    [ "$dirty" = "1" ] || ok "sibling working trees unchanged (git status still clean)"
    ok "unpinned; PINNED=0 (default) behaviour is unaffected"
}

# ------------------------------------------------------------------------------------------------
# relock (bump)
# ------------------------------------------------------------------------------------------------
cmd_relock() {
    step "regenerate siblings.lock from the live checkouts"
    local repo sibling sha url dirty=0 status_out
    for repo in "${REPOS[@]}"; do
        sibling="$(sibling_path "$repo")"
        [ -d "$sibling" ] || die "missing sibling checkout: $sibling"
        status_out="$(git -C "$sibling" status --porcelain)"
        if [ -n "$status_out" ]; then
            warn "$repo: ../$repo has uncommitted changes: $(printf '%s' "$status_out" | head -3 | tr '\n' ' ')"
            dirty=1
        fi
    done
    if [ "$dirty" = "1" ]; then
        die "refusing to write siblings.lock while a sibling working tree is dirty
    A lock records commits, but the build compiles the working tree: pinning HEAD while edits are
    pending would pin code that was never built and hide the difference. Commit or stash the
    sibling edits, run a green PINNED=0 bootstrap, then re-run 'make pin-lock'."
    fi

    local tmp
    tmp="$(mktemp)"
    {
        for repo in "${REPOS[@]}"; do
            sibling="$(sibling_path "$repo")"
            printf '%s\t%s\t%s\n' "$repo" \
                "$(git -C "$sibling" rev-parse HEAD)" \
                "$(git -C "$sibling" remote get-url origin 2>/dev/null || true)"
        done
    } >"$tmp"

    python3 - "$LOCK" "$tmp" <<'PY'
import json
import os
import sys
import tempfile

lock_path, dump_path = sys.argv[1], sys.argv[2]
try:
    with open(lock_path) as fh:
        lock = json.load(fh)
except FileNotFoundError:
    lock = {"schemaVersion": 1, "repos": {}}

repos = {}
with open(dump_path) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        repo, sha, url = (line.split("\t") + ["", ""])[:3]
        if not url:
            url = f"https://github.com/LOVE20BSC/{repo}.git"
        repos[repo] = {"url": url, "sha": sha}

# Keep the hand-written comment block and schema version; only the shas are machine-owned.
lock["schemaVersion"] = lock.get("schemaVersion", 1)
lock["repos"] = repos
directory = os.path.dirname(os.path.abspath(lock_path))
fd, tmp_out = tempfile.mkstemp(dir=directory, suffix=".tmp")
with os.fdopen(fd, "w") as fh:
    json.dump(lock, fh, indent=2)
    fh.write("\n")
os.replace(tmp_out, lock_path)
PY
    rm -f "$tmp"

    for repo in "${REPOS[@]}"; do
        printf '    %-12s %s\n' "$repo" "$(git -C "$(sibling_path "$repo")" rev-parse HEAD)"
    done
    ok "siblings.lock rewritten - next: make unpin && make pin && make bootstrap PINNED=1"
}

usage() {
    sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
    local cmd="${1:-}"
    case "$cmd" in
        pin) cmd_pin ;;
        status) cmd_status ;;
        clean | unpin) cmd_clean ;;
        relock) cmd_relock ;;
        '' | -h | --help | help) usage ;;
        *) die "unknown subcommand: $cmd (try --help)" ;;
    esac
}

main "$@"
