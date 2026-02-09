-include .env

.PHONY: source .env

# 128kb contract size limit in Monad https://docs.monad.xyz/introduction/monad-for-developers#smart-contracts
DeployMagma :; @forge clean && forge script script/Magma.s.sol:DeployMagma --rpc-url ${RPC_URL} --private-key ${PRIVATE_KEY} --broadcast -vvvv --slow --skip-simulation --code-size-limit 131072

DeployGVaultUpgradeMagma :; @forge clean && forge script script/DeployGVaultUpgradeMagma.s.sol:DeployGVaultUpgradeMagma --rpc-url ${RPC_URL} --private-key ${PRIVATE_KEY} --broadcast -vvvv --slow --skip-simulation --code-size-limit 131072