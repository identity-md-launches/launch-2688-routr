# Vendored dependencies

All required Solidity sources are included as regular files. There are no git
submodules, runtime package downloads, or dependencies on `node_modules`.
The selected upstream files are unmodified, including their SPDX headers.

| Dependency | Release | Exact commit | Included files |
| --- | --- | --- | --- |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/69c8def5f222ff96f2b5beff05dfba996368aa79) | v5.1.0 | `69c8def5f222ff96f2b5beff05dfba996368aa79` | `ERC20.sol`, its four transitive Solidity dependencies, and `LICENSE` |
| [Forge Standard Library](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505) | v1.9.7 | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | Entire `src/` directory, `LICENSE-MIT`, and `LICENSE-APACHE` |

OpenZeppelin is used by the production contract. Forge Standard Library is used
only by tests. Licenses are preserved in each dependency's directory. Only the
OpenZeppelin ERC-20 dependency closure is included; unrelated OpenZeppelin
contracts are deliberately not vendored.

Each dependency's `SHA256SUMS` lists SHA-256 hashes of its upstream files, with
paths relative to the repository root. Check them without network access:

```sh
sha256sum --check lib/openzeppelin-contracts/SHA256SUMS
sha256sum --check lib/forge-std/SHA256SUMS
```

For provenance, the downloaded GitHub codeload archives at the exact commits had
these SHA-256 digests:

- OpenZeppelin: `b0d8bc73b249cee906d596cf8e63c6ea71a4311c4e2a45a0b253e060d6dd3ae8`
- Forge Standard Library: `a387f7c2a10387f889b0d18b999cfa667a5273ac11cc11e18923022eb8b24bc3`

The archives themselves are unnecessary for building and are not included.
