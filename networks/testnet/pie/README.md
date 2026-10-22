# pie

An Arkiv db-chain network — its public genesis and discovery entry point. No secrets are
stored here; they are managed out-of-band by the deployment tooling.

- chain id: 7713079
- public RPC — the watchers are the public RPC surface; the block-producing producer is in-cluster
  only and is not a public endpoint:
  - `watcher-1-el.pie.db-chain.testnet.arkiv.network`

## Run your own node

Docker is the only requirement. From a copy of this directory:

    ./run-node.sh          # or: bash run-node.sh

The script needs no arguments. It reads the connection details from p2p.yaml, mints the JWT the two
clients authenticate to each other with — kept under your own state directory
(`${XDG_STATE_HOME:-$HOME/.local/state}/db-chain-networks/`), never in this directory, which holds
no secret — and starts them: the Arkiv execution client — reth hosting the Arkiv entity engine, which is
part of the state transition, so stock reth cannot follow this chain — and a Lighthouse beacon node. The
node follows the chain read-only: it holds no keys, needs no funding, and proposes nothing, and every
connection it opens is outbound, so it needs no inbound port of its own.

Once it is up, the script prints how to check it: the beacon node's sync state at
http://localhost:5052/eth/v1/node/syncing, and the execution layer's head at http://localhost:8545.
Both are bound to loopback, so they answer on the host that runs them and nowhere else. Both containers
are set to restart with docker once they are seen running, so the node comes back after a host reboot.

### When the connection details change

p2p.yaml is rewritten whenever the addresses this chain publishes move, so a node that loses its peering
is one `git pull` and one re-run of the script away from having it back. Re-running replaces both
containers and leaves their datadirs — named docker volumes — in place, so the node
re-peers without resyncing.

### Removing the node

    ./run-node.sh --teardown

removes everything the script created: both containers, both datadir volumes (the chain data), the
docker network the two share, and the state directory holding the JWT. It leaves the images the script
pulled, which other nodes on the host may run; `./run-node.sh --help` lists them.

Notes:
- The sync runs from genesis: this chain publishes no checkpoint endpoint.
- Keep the host clock NTP-synced. Consensus is slot-timed, and a drifting clock desynchronises the node.
