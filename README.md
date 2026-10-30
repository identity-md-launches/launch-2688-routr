# Routr (ROUTR)

Routr is a fixed-supply ERC-20. Its constructor mints all **1,000,000,000 ROUTR**
to the address deploying it. It uses 18 decimals, so the exact total supply is
**1000000000000000000000000000** smallest units (`10**27`).

## Contract and assumptions

- Deployable contract: `src/Routr.sol:Routr`.
- Name: `Routr`; symbol: `ROUTR`; decimals: `18`.
- `INITIAL_SUPPLY` is the public constant `1_000_000_000 * 10**18`.
- The requested token is interpreted as a standard ERC-20 with exact transfers.
  It has no transfer fee, tax, rebasing, burn facility, or additional minting.
- There is no owner, administrator, pause, blacklist, seizure, upgrade, or
  initialization mechanism. The deployer has the same permissions as any holder.
- ERC-20 accounting is inherited from the vendored OpenZeppelin Contracts v5.1.0
  implementation. The only custom behavior is the constructor mint.

`transfer`, `approve`, and `transferFrom` return `true` on success and revert with
OpenZeppelin's ERC-6093 custom errors on invalid operations. Zero-value transfers
between nonzero addresses succeed and emit `Transfer`. Self-transfers preserve
balances but still require sufficient balance. Transfers to the zero address
and approvals to the zero address revert.

Approvals replace the previous allowance. `transferFrom` spends the caller's
allowance even when the caller is the token holder, and a finite allowance is
reduced by the amount spent. An allowance of `type(uint256).max` is treated as
unlimited and remains unchanged. As in OpenZeppelin v5, spending an allowance
emits `Transfer` but does not emit an additional `Approval` event. Failed transfers
revert both balance and allowance changes.

## Build and check

The repository includes every Solidity dependency as ordinary files under `lib/`.
No package installation, RPC, wallet, environment file, or network access is
required to build or test once Foundry and Solidity 0.8.26 are installed.
Dependency revisions, licenses, and integrity checks are in [DEPENDENCIES.md](DEPENDENCIES.md).

```sh
forge build
FOUNDRY_FUZZ_SEED=0xf830c48dcff0b49d0a2718ba0d59fc31af0d82b969e81677ef982e7c3d100fc3 forge test
forge fmt --check
```

`foundry.toml` pins Solidity **0.8.26**, the **Cancun** EVM target, the optimizer
at **200 runs**, and `bytecode_hash = "none"`. It does not enable FFI or filesystem
permissions. Fuzz tests run 1,024 cases each. Stateful invariants run 256 sequences
of up to 64 actions each and fail on unexpected reverts. Tests do not read or set
environment variables, fork a chain, or rely on execution order; the optional
seed above is consumed by Foundry itself.

The tests cover metadata, initial supply and mint event, direct and factory
deployment, exact allocation and claim transfers, both transfer directions at a
pool boundary, approvals, allowance exhaustion and revocation, infinite
allowances, zero and maximum values, self-transfers, rejected operations and
their rollback, missing administrative entry points, and rejection of native
ETH. The invariant suite checks every tracked balance and allowance against an
independent model after randomized transfers, approvals, delegated transfers,
and failed overdraw attempts.

The supplied protected tests require the verifier's launch infrastructure,
Uniswap v4 contracts, and manifest configuration, which are not provided in this
standalone project. The local factory test checks token accounting at those
boundaries; it does not claim to run the protected suite or simulate pool pricing
and swaps. See [REVIEW.md](REVIEW.md) for the security review and verification scope.

## Deployment parameters

| Parameter | Value |
| --- | --- |
| Solidity identifier | `Routr` |
| Constructor arguments | None (`[]`) |
| Deployment value | `0` ETH (nonpayable constructor) |
| Intended launch network | Ethereum, chain ID 1 |
| Required EVM support | Cancun or later |
| Initial recipient | The constructor's `msg.sender` |
| Initial and permanent total supply | `1000000000000000000000000000` |
| Owner or operator address | None |
| External contract addresses | None |
| Libraries to link | None |
| Post-deployment initialization | None |

The artifact is `out/Routr.sol/Routr.json`. The creation bytecode can be inspected
with `forge inspect src/Routr.sol:Routr bytecode`. Deploy this contract directly,
without a proxy. No constructor arguments need to be appended and the constructor
does not call any external contract.

In the intended launch, the factory creates Routr and receives the entire supply;
the transaction origin and requester receive nothing from the constructor. The
factory is responsible for the supplied launch allocations: 10% for the swarm
distributor, 85% for pool liquidity, and the remaining 5% for the launch's
designated recipient. Pool configuration, pricing, distribution, and the launch
manifest belong to the external launch infrastructure and are not implemented or
hardcoded in this token. There are no application contracts to deploy; the
contracts in `test/` are local test scaffolding only.

## After launch

There are no settings, privileged keys, scheduled tasks, or maintenance calls.
The launch operator must deploy the reviewed artifact, check its name, symbol,
decimals, supply and initial recipient, verify the source on the explorer, and
complete and check the external distribution and pool setup. This project does
not broadcast transactions or supply a launch manifest.

Holders are responsible for custody and approvals. Prefer allowances limited to
the intended spend; revoke unused approvals. When replacing an existing nonzero
allowance, first set it to zero and confirm that transaction before setting the
new amount to mitigate the standard ERC-20 allowance replacement race. A spender
may still use its existing allowance before the revocation is confirmed.

Transfers do not invoke recipient hooks. Holders must ensure a receiving
contract can return tokens: ROUTR sent to this token contract itself, or to a
contract with no withdrawal mechanism, can be permanently inaccessible. There
is no recovery function for tokens or forced ETH. Ordinary ETH transfers to
Routr revert. An independent adversarial review remains a release responsibility;
the local checks are not a security audit.
