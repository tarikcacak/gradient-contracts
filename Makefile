-include .env
export

.PHONY: install build test fuzz invariant fork coverage gas fmt slither deploy smoke abi clean

install:
	forge install foundry-rs/forge-std --no-commit

build:
	forge build

test:
	forge test -vvv

fuzz:
	FOUNDRY_PROFILE=ci forge test --match-path "test/unit/*" -vv

invariant:
	FOUNDRY_PROFILE=ci forge test --match-path "test/invariant/*" -vv

fork:
	forge test --fork-url $(SEPOLIA_RPC_URL) --match-path "test/fork/*" -vvv

coverage:
	forge coverage --report summary

gas:
	forge snapshot

fmt:
	forge fmt

slither:
	slither . --exclude-dependencies

deploy:
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url $(SEPOLIA_RPC_URL) --broadcast --verify \
		--etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv

smoke:
	forge script script/Deploy.s.sol:Smoke --rpc-url $(SEPOLIA_RPC_URL) --broadcast -vvvv

# Exports the ABIs the Go indexer consumes.
abi:
	mkdir -p ../backend/abi
	forge inspect BondingCurve abi > ../backend/abi/BondingCurve.json
	forge inspect TokenFactory abi > ../backend/abi/TokenFactory.json
	forge inspect LaunchToken  abi > ../backend/abi/LaunchToken.json

clean:
	forge clean
