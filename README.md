## Magma 

### Protocol Overview

Magma is a modular, upgradeable staking protocol built on an ERC4626 vault (`Magma`) that orchestrates validator-facing vaults (`CoreVault`, `gVault`) and an adapter for the Monad staking precompile. The system separates responsibilities for clarity, safety, and upgradeability.

- Vaults and roles
  - `Magma` (ERC4626): user-facing vault; mints/burns shares; tracks total assets; coordinates async requests and vault operations.
  - `CoreVault`: delegates stake equally across a whitelist of validators; handles protocol-wide rebalances; manages a global withdrawal queue for user requests.
  - `gVault`: delegates per validator for curated validator sets and caps; handles per-validator withdrawal queues and admin-driven rebalances.
  - Governance/Admin: owned by a Timelock/Governor in production. All admin-only functions route through this role.

- Upgradeability
  - All concrete contracts are UUPS upgradeable with storage gaps. `_authorizeUpgrade` checks Magma admin (ultimately Timelock/Governor) before upgrades. UUPS upgradeability is done through the foundry plugin. 

- Monad staking integration
  - `MagmaDelegationModule` is an abstract adapter exposing internal functions for `delegate`, `undelegate`, `withdraw`, and views into precompile state (e.g., `getWithdrawalRequest`).
  - Validators are tracked by `uint64 valId`. Undelegations use `uint8 withdrawalId` per (delegator, validator), 0–255.

### ERC4626 Async Flows

ERC4626 methods are split between synchronous deposits and asynchronous withdrawals/redemptions:

- Deposits/mints
  - ERC4626 `deposit`/`mint` unwrap WMON and delegate native MON through `CoreVault`. The vault does not retain WMON post-deposit; `totalAssets()` reflects delegated native plus any idle.
  - Native deposits are supported via `depositMon()` (and variants) which mint shares and delegate immediately.

- Withdraws/redeems (async)
  - Users submit requests: `requestWithdraw(assets, controller, owner)` or `requestRedeem(shares, controller, owner)` which lock shares and enqueue undelegations.
  - Claiming is time-based: after a delay (configurable), users call `withdraw`/`redeem` to receive WMON (ERC20). Native redemption can be handled via higher-level flows if desired.
  - Operator model: owners can authorize operators to act on their behalf for request/claim operations.

### Withdrawal Queues and IDs

To support unlimited user requests despite the 256 in-flight cap per (delegator, validator), the protocol batches:

- CoreVault
  - Global queue: amounts are accrued and submitted equally across whitelisted validators when a free `withdrawalId` becomes available per validator.
  - Pending attribution: user addresses/amounts are stored per `(valId, withdrawalId)` for precise distribution when the precompile withdrawal matures.
  - Admin reserved withdrawal ID: `ADMIN_WID = 255` used for rebalances and validator removals.
  - Corevault is always rebalanced "equally" with an equal stake distribution among validators whenver a new validator is added or removed

- gVault
  - Per-validator queue: amounts accrue by `valId` and are submitted when a slot is free and stake capacity exists.
  - Pending attribution stored per `(valId, withdrawalId)` for distribution on completion.
  <!-- TODO: update docs -->
  - Admin reserved withdrawal ID: `ADMIN_WID_REBALANCE = 254` for admin rebalancing.
  - two types of rebalancing: removing validator, or admin-initiated liquidity rebalance when CoreVault is close to becoming illiquid.

- Withdrawal ID allocation
  - Per validator cursor scans 0–255, skipping the reserved admin ID. If all 256 are occupied, callers should complete some withdrawals first.

### Rebalancing

- CoreVault rebalances equal stake across validators in two phases:
  - Initiate: undelegate excess using admin ID; track pending totals separately from user withdrawals.
  - Redistribute: after funds are available, delegate deficits to reach target per validator.
  - Epoch guard: rebalance and validator set changes are gated by `epochSeconds` to avoid spamming.

- gVault rebalancing pulls a percentage (bps) from each whitelisted validator using the admin ID and forwards matured funds to `Magma` for redistribution.

### Operational Controls

- Pause/Unpause
  - `Magma`, `CoreVault`, and `gVault` expose minimal pausing that gates user-facing operations.

- Minimum withdrawal size
  - Each vault enforces a configurable `minUserWithdrawAmount` to prevent dust requests.

- Queue caps
  - Conservative caps (e.g., 64 items per queue) limit worst-case gas for batch processing.

### Errors and Events

- Custom errors in `MagmaErrorsModule.sol` replace string reverts, carrying useful context.
- Key events are emitted for queueing, submission, withdrawal distributions, and rebalancing.

### Testing

- Unit tests cover ERC4626 synchronous deposit/mint, async request/claim flows, pause behavior, validator management, and queue attribution.
- Native-flow tests use async claim-style for requests originating from native deposits.
