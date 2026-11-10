# Local-chain deployment for the LOVE20BSC protocol stack.
#
# Every target is a thin wrapper over script/local.sh, which is the place to look for what actually
# happens. `make bootstrap` is the one command: it starts anvil and ends with a verified, seeded
# chain plus the export the frontend consumes.
#
# Frequently used overrides (exported to the scripts, they win over params/anvil31337_dev/*.params):
#   make bootstrap PORT=8555     # run the chain on another port (moves ANVIL_PORT and RPC_URL)
#   make bootstrap HOST=127.0.0.2
#   make deploy PROFILE=anvil31337_dev
SHELL := /bin/bash
.DEFAULT_GOAL := help

PROFILE ?= anvil31337_dev
LOCAL := bash script/local.sh

# An exported PORT/HOST wins over network.params (script/lib/params.sh honours these two keys).
ifneq ($(strip $(PORT)),)
export ANVIL_PORT := $(PORT)
endif
ifneq ($(strip $(HOST)),)
export ANVIL_HOST := $(HOST)
endif
export PROFILE

.PHONY: help bootstrap build preflight fixture anvil stop multicall3 libraries deploy seed export verify clean all

help:
	@echo "LOVE20BSC local chain (profile: $(PROFILE))"
	@echo ""
	@echo "  make bootstrap     start anvil + fixture + Multicall3 + libraries + deploy + seed + export + verify"
	@echo ""
	@echo "  Individual steps (the order bootstrap runs them in):"
	@echo "    make preflight   toolchain, sibling checkouts, dex artifacts, Multicall3 tx checksum"
	@echo "    make fixture     (re)generate fixtures/airdrop/$(PROFILE).json"
	@echo "    make anvil       start anvil with the flags in params/$(PROFILE)/network.params"
	@echo "    make build       forge build (compiles the siblings read-only)"
	@echo "    make multicall3  deploy Multicall3 at 0xcA11bde05977b3631167028862bE2a173976CA11"
	@echo "    make libraries   deploy the four linked action libraries"
	@echo "    make deploy      deploy WETH + UniswapV2 + Airdrop + core + action + group-chat"
	@echo "    make seed        airdrop claims, MemberNFTs, liquidity, ETH balances"
	@echo "    make export      export/deployments/$(PROFILE).json + export/abis/*.json"
	@echo "    make verify      cast assertions over every exported address -> export/VERIFIED.md"
	@echo ""
	@echo "  make stop          stop the anvil this repo started"
	@echo "  make clean         remove out/ cache/ broadcast/ .anvil/ and generated exports"
	@echo ""
	@echo "  make bootstrap PORT=8555    run on another port"

bootstrap:
	@$(LOCAL) bootstrap

all: bootstrap

build:
	@$(LOCAL) build

preflight:
	@$(LOCAL) preflight

fixture:
	@$(LOCAL) fixture

anvil:
	@$(LOCAL) anvil

stop:
	@$(LOCAL) stop

multicall3:
	@$(LOCAL) multicall3

libraries:
	@$(LOCAL) libraries

deploy:
	@$(LOCAL) deploy

seed:
	@$(LOCAL) seed

export:
	@$(LOCAL) export

verify:
	@$(LOCAL) verify

clean:
	@$(LOCAL) clean
