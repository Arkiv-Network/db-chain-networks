# db-chain-networks

The **network registry** for Arkiv database-chain networks — the source of truth for what networks
exist, and the artifact you consume to join one.

Each network is recorded here by the deployment tooling **before** it runs anywhere, so a purged or
cluster-lost network is always restorable with the same genesis and identities. Deletions are
recorded too (the directory is removed at head; git history retains it as the audit trail).

## Networks

Each row is one network this registry records, rebuilt by the deployment tooling from the records in
every commit it makes. `bin/network-list --write` rebuilds it after a change made by hand, and CI fails
when the table and the tree disagree.

<!-- networks:begin -->
| Network | Cluster | Chain ID | Public RPC | Description |
| --- | --- | --- | --- | --- |
| [rabdi](networks/testnet/rabdi/) | testnet | 7794095 | https://rpc.rabdi.db-chain.testnet.arkiv.network | Public testnet on the GolemDB node; indexer, metered RPC edge and faucet |
| [sorbet](networks/testnet/sorbet/) | testnet | 7706815 | https://rpc.sorbet.db-chain.testnet.arkiv.network | Testnet prefilled with the Sourcify contract dataset; metered RPC edge and indexer; used for index rewrite and load work |
| [tiramisu](networks/testnet/tiramisu/) | testnet | 7738577 | https://rpc.tiramisu.db-chain.testnet.arkiv.network | Public Arkiv testnet; metered RPC edge, indexer and faucet; the network external developers join |
<!-- networks:end -->

## What's here (and what's not)

```
networks/<cluster>/<name>/
  config.yaml       # consensus chain spec (a lighthouse --testnet-dir)
  genesis.json      # execution genesis
  genesis.ssz       # consensus genesis state — raw, the immutable artifact
  p2p.yaml          # peer addresses — execution enodes, consensus boot ENRs
  boot_enr.yaml     # published consensus ENRs — the --testnet-dir boot list
  pubkeys.txt       # the 64 validator public keys
  metadata.yaml     # name, chain id, base domain, public RPC, description
  run-node.sh       # executable — brings up a node that follows this chain
  README.md         # endpoints + how to follow this chain
  SHA256SUMS        # integrity
```

`p2p.yaml` and `boot_enr.yaml` are present while the network publishes public P2P endpoints; a
network that publishes none carries neither.

**No secrets are ever committed here** — not even encrypted. Validator keystores, the JWT, and the
node private keys are managed out-of-band by the deployment tooling and never touch this repo. CI
enforces this on every push with a targeted validator: no secret-bearing files, no mnemonic value,
plus checksum, required-file, and layout checks.

## Following a network

Clone this repository and run the network's own script from its directory:

```
cd networks/<cluster>/<name> && ./run-node.sh
```

Docker is the only prerequisite, and the script takes no arguments: it brings up an Arkiv execution
client and a Lighthouse beacon node in docker, reading the addresses to dial from `p2p.yaml` at run
time and everything else from the directory beside it. The node follows the chain read-only — it
holds no keys and proposes nothing. `p2p.yaml` is rewritten whenever the addresses a network
publishes move, so a node that loses its peering is one `git pull` and one re-run of the script away
from having it back; a re-run replaces the containers and keeps their datadirs, so the node re-peers
without resyncing. The per-network `README.md` lists the live endpoints.

The mechanics underneath, for anyone running their own client setup: a beacon node with
`--testnet-dir` pointed at a `networks/<cluster>/<name>/` directory (it provides `config.yaml` +
`genesis.ssz`) and `--boot-nodes` from `boot_enr.yaml`, plus an execution client started from
`genesis.json`. `--testnet-dir` is lighthouse's flag for **any** custom network — testnet or mainnet
alike — not a signal that the chain is for testing; Arkiv networks are never built into the client,
so this is always how you join one.

