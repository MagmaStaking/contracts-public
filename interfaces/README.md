# Interfaces Directory

This directory contains all the interface definitions for the Magma protocol contracts.

## Interface Files

### `IMagma.sol`
Interface for the main Magma ERC-4626 vault contract. Includes:
- Admin management functions
- Vault configuration functions  
- Delegation functions (both CoreVault and gVault routing)
- View functions for vault addresses

### `ICoreVault.sol`
Interface for the CoreVault contract which handles equal distribution delegation among whitelisted validators. Includes:
- Validator whitelist management (admin functions)
- Equal distribution delegation functions
- Rebalancing functionality
- View functions for validator state and delegation amounts

### `IGVault.sol`
Interface for the gVault contract which handles direct validator-specific delegation. Includes:
- Direct validator delegation functions
- View functions for contract references

### `IMagmaDelegation.sol`
Interface for the MagmaDelegation contract which handles the low-level delegation logic. Includes:
- Core delegation operations (delegate, undelegate, complete, redelegate)
- Data structures for delegation and unbonding state
- View functions for delegation information

## Usage

Import interfaces in your contracts like this:

```solidity
import {IMagma} from "../interfaces/IMagma.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {IGVault} from "../interfaces/IGVault.sol";
import {IMagmaDelegation} from "../interfaces/IMagmaDelegation.sol";
```

## Benefits

- **Separation of Concerns**: Interface definitions are separate from implementation
- **Reusability**: Interfaces can be imported by multiple contracts and tests
- **Documentation**: Interfaces serve as clear documentation of contract APIs
- **Type Safety**: Proper typing when interacting with contracts through interfaces
- **Testing**: Easier to create mocks and test contracts using interfaces