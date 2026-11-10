#!/usr/bin/env bash
# Parameter file loader for params/<profile>/*.params.
#
# Adapted from ../core/script/deploy/params.sh (same lexical rules, credited, not copied wholesale -
# this repo needs one different property, documented below). Rules kept identical:
#
#   * `<mantissa>e<exponent>` and `1_000_000` are expanded to plain decimal on load, because
#     `vm.envUint` in Solidity accepts neither form. Purely lexical: a malformed value stays as-is
#     and makes vm.envUint fail loudly before broadcast instead of silently becoming 0.
#   * a whole-quoted value loses its quotes and is NOT comment-stripped (so a value may contain #)
#   * an unquoted trailing ` # comment` is stripped
#   * no variable expansion, no command substitution: literal text only
#   * `params_require_keys` / `params_require_values` assert presence in the FILE, not in the
#     environment, so an inherited value can never satisfy a required key
#
# One deliberate difference: this loader does NOT sweep inherited variables before loading, and the
# keys listed in PARAMS_PRESERVE keep an inherited value instead of the file's. Making
# `PORT=8555 make bootstrap` work is worth more here than the "file always wins" guarantee; a local
# developer must be able to move the chain off 8545 without editing a committed file. The opposite
# failure mode - a stale exported value silently winning - is covered by printing the effective
# endpoint in `make verify` and by the chain-id assertion in every script.

# Keys an exported environment variable may override (the chain endpoint only: moving the port must
# move the anvil process AND every RPC URL together, so they are derived from these two).
PARAMS_PRESERVE=(ANVIL_HOST ANVIL_PORT CHAIN_ID)

params_expand_value() {
    local value="$1" item out="" sep=""
    local -a items
    [ -n "$value" ] || return 0
    IFS=',' read -ra items <<<"$value" || true
    for item in "${items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        if [[ "$item" =~ ^([0-9][0-9_]*)[eE]([0-9]+)$ ]]; then
            # Pad the mantissa with <exponent> zeros: pure string operation, no 64-bit limit (1e28 works).
            printf -v item '%s%*s' "${BASH_REMATCH[1]//_/}" "${BASH_REMATCH[2]}" ''
            item="${item// /0}"
        elif [[ "$item" =~ ^[0-9][0-9_]*$ ]]; then
            item="${item//_/}"
        fi
        out="$out$sep$item"
        sep=","
    done
    printf '%s' "$out"
}

# Load one .params file and export every KEY=value it defines.
params_load() {
    local file="$1" line key value
    if [ ! -f "$file" ]; then
        echo "Error: params file not found: $file" >&2
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in
            '' | '#'*) continue ;;
        esac
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "Error: invalid key in $file: $key" >&2
            return 1
        fi
        if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
            value="${value#?}"
            value="${value%?}"
        else
            value="${value%%[[:space:]]#*}"
            value="${value%"${value##*[![:space:]]}"}"
        fi
        local preserved=0 k
        for k in "${PARAMS_PRESERVE[@]}"; do
            if [ "$key" = "$k" ] && [ -n "${!key:-}" ]; then
                preserved=1
                break
            fi
        done
        if [ "$preserved" -eq 0 ]; then
            printf -v "$key" '%s' "$(params_expand_value "$value")"
            export "$key"
        fi
    done <"$file"
}

# Assert that a file defines every named key (leading whitespace allowed).
params_require_keys() {
    local file="$1" key
    shift
    for key in "$@"; do
        if ! grep -qE "^[[:space:]]*${key}=" "$file"; then
            echo "Error: $key must be set in $file" >&2
            return 1
        fi
    done
}

# Assert that a file defines every named key with a non-empty value.
params_require_values() {
    local file="$1" key
    shift
    for key in "$@"; do
        if ! grep -qE "^[[:space:]]*${key}=[^[:space:]]" "$file"; then
            echo "Error: $key must be set to a non-empty value in $file" >&2
            return 1
        fi
    done
}
