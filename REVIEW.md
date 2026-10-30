# Local security review

Scope: `src/Routr.sol` and its vendored OpenZeppelin ERC-20 dependency closure.
This is an implementation review, not an independent security audit.

## Findings and design checks

No unresolved implementation defect was identified in this review. The following
checks explain the intended security boundaries and their evidence.

| Area | Review result and evidence |
| --- | --- |
| Fixed supply | The only `_mint` call in Routr is in its constructor. `INITIAL_SUPPLY` equals `10**27` smallest units. No runtime method calls `_mint` or `_burn`. Tests assert exact supply, initial balance, and one mint event. |
| Initial recipient | The constructor uses `msg.sender`. Tests deploy through both an account and a contract, including a distinct transaction origin, and confirm only the direct deployer receives the supply. |
| Access control | The ABI contains only the nine standard ERC-20/metadata functions and `INITIAL_SUPPLY`. No owner, roles, initializer, upgrade, pause, or seizure entry point exists. Tests try administrative selectors from the deployer and an unrelated account, and verify holders can still transfer. |
| Transfer authority | `transfer` uses the caller's balance. `transferFrom` spends the caller's allowance before moving tokens. Tests cover unauthorized spenders, self-spending, revocation, and allowance exhaustion. |
| Conservation | Transfers debit and credit the same exact amount. No tax, reflection, burn, or rebase is introduced. Randomized sequences compare all balances and allowances to a separate accounting model and check the total of balances remains the initial supply. |
| Arithmetic | The constructor's constant fits in `uint256`. The inherited ERC-20 checks balances and allowances before subtraction. Its unchecked arithmetic is bounded by those checks and total supply. Boundary tests include zero, full supply, self-transfers, and maximum integer values. |
| Invalid operations | Invalid receivers and spenders, insufficient balances, and insufficient allowances revert. Tests verify a failed delegated transfer also restores allowance. A zero-source, zero-value `transferFrom` fails first with `ERC20InvalidApprover` during allowance validation. |
| Reentrancy | Production code makes no external calls, including during construction and transfers. There are no recipient callbacks, token integrations, or oracle reads. No reentrancy guard is needed for this implementation. |
| Launch flows | Local tests send 10%, 85%, and 5% from a deploying factory, transfer distributor claims, and transfer to/from a pool address without deductions. The token requires no whitelist or launch configuration. Full Uniswap integration remains in the external protected verifier. |
| Deployment bytecode | The optimized Solidity 0.8.26 runtime is 1,752 bytes, below EIP-170's 24,576-byte limit. Creation and runtime link-reference maps are empty. The protected test's opcode-walk algorithm finds no reachable `DELEGATECALL`, `CALLCODE`, or `SELFDESTRUCT`. |
| Dependencies | Vendored source files match their recorded SHA-256 hashes. No proxy, linked library, downloaded build-time package, or external service is required. |

The supplied security reference also discusses vaults, oracles, swaps, randomness,
signatures, and upgrades. Routr implements none of these features, so the related
attack paths do not apply to this token. Its standard unlimited-allowance behavior
is tested for ERC-20 compatibility; holders should still limit approvals to trusted
spenders and intended amounts.

## Verification scope

Local validation uses `forge build`, the complete `forge test` suite with the
assignment's fuzz seed, `forge fmt --check`, dependency checksum verification,
and ABI/bytecode inspection. The test suite contains 31 unit/fuzz tests (including
three fuzz tests with 1,024 cases each) and two stateful invariants checked over
256 runs of 64 actions. Foundry 1.8 groups the two invariants into one reported
test result.

The supplied protected tests cannot run in isolation: they import verifier-owned
launch contracts and Uniswap v4 sources, and obtain the deployment manifest from
the verifier environment. Those components are not present in this repository.
The local tests use no environment variables or RPC and do not replace that
independent verification. Slither and Mythril were not run. No deployment or
transaction broadcast was performed.

Operational limitations are intentional: lost keys cannot be recovered, mistaken
transfers cannot be reversed, approved spenders can transfer up to their allowance,
and tokens sent to a contract with no withdrawal path can be locked indefinitely.
The constructor's recipient must be able to distribute the full supply. Source
verification, external pool/distribution checks, and independent adversarial
review remain the launch operator's release responsibilities.
