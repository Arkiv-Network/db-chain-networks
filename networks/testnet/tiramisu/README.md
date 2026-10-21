# tiramisu

An Arkiv db-chain network — its public genesis and discovery entry point. No secrets are
stored here; they are managed out-of-band by the deployment tooling.

- chain id: 7738577
- public RPC — a single metered endpoint fronts the watcher execution layer; the block-producing
  producer is in-cluster only and is not a public endpoint:
  - `rpc.tiramisu.db-chain.testnet.arkiv.network` — HTTP JSON-RPC over HTTPS, and WebSocket at `wss://rpc.tiramisu.db-chain.testnet.arkiv.network` on the same host.

Metering contract:
- Anonymous callers get a small per-IP request budget. Once it is spent the endpoint answers `429`,
  carrying a `RateLimit` header and a `Retry-After` telling you when to retry.
- An API key raises the limits. Get one from the Arkiv hub at https://hub.arkiv.network; the `429` also carries a
  `Link: <hub>; rel="help"` header naming the hub authoritatively.
- Billed responses carry an `Arkiv-Cost` header (the cost charged for that request); successful
  keyed requests also carry `Arkiv-Quota-Remaining` (the remaining quota).

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

### The first sync starts from the published snapshot

A run that finds both datadirs empty restores this chain's published snapshot before starting the
clients, so the node comes up near the head instead of syncing from genesis, which takes days. The
snapshots are served from https://testnet.snapshots.arkiv.network, and the script reads

    https://testnet.snapshots.arkiv.network/tiramisu/latest.json

to find the current one. That manifest states the run it was taken in, the head slot and block it
holds, the reth and lighthouse images that wrote the two databases, and each layer's size compressed
and unpacked; the script prints them before it fetches anything. It refuses a snapshot of another
chain, or of this chain before a wipe that restarted it from a new genesis time, and says so when the
images that wrote the databases are not the ones this node runs — a difference to weigh rather than a
reason to stop. Each layer is a tar archive compressed with gzip or zstd, as the manifest's compression
field states, and the script restores either.

For a prefilled network, initial-snapshot.json pins an immutable generation-zero execution snapshot.
It is used when no current backup exists, including after a wipe. Its execution genesis checksum and
state root must match this record. It contains no consensus history: Lighthouse starts from the matching
genesis.ssz. Later ordinary snapshots restore both execution and consensus state and require the same
genesis time. Prefilled networks cannot use FROM_GENESIS=1 to bypass their required execution state.

The snapshot carries chain data and nothing else: the node still generates its own network identity and
mints its own JWT, exactly as it does from genesis. A node that already holds chain data is left as it
is, and a restore that fails empties both datadirs, so a re-run starts clean.

    FROM_GENESIS=1 ./run-node.sh

skips the step and syncs from genesis. That is the better choice when the published snapshot has fallen
far behind: compare the head slot in latest.json with the chain's head now — the chain adds a block a
slot, and SECONDS_PER_SLOT in config.yaml beside this file says how long a slot is — and when replaying
that gap is no cheaper than replaying the whole chain, syncing from genesis is one fewer moving part.

Each layer is fetched in ranges of CHUNK_BYTES bytes, 1 GiB by default, with two of them in flight so
the next range downloads while the current one is unpacked — the container's /tmp needs twice that much
free. A range that fails is retried, RETRY_BACKOFF seconds apart and lengthening, 5 seconds by default.
A range averaging, for a minute, under an eighth of the fastest range so far — and never under MIN_RATE
bytes a second, 1 MiB/s by default — is fetched again on a fresh connection, which is what a connection
that has degraded needs. All three are set on the command line the way FROM_GENESIS is, so a host with a
small /tmp runs

    CHUNK_BYTES=268435456 ./run-node.sh

The objects can also be downloaded ahead of the run, with whatever ranged, resumable downloader you
prefer: latest.json names each layer's key, and the object is at SNAPSHOTS_URL/key. A directory holding
latest.json and the two objects under their own basenames is restored from with

    SNAPSHOT_DIR=/path/to/snapshot ./run-node.sh

which reads that directory and never the network. The archives need room of their own while the restore
runs: the compressed sizes latest.json states, on top of the unpacked ones the datadirs take.

The node is caught up when the beacon node answers `is_syncing: false` at
http://localhost:5052/eth/v1/node/syncing and the block number at http://localhost:8545 is within a few
blocks of the one this chain's public RPC reports.

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
- Keep the host clock NTP-synced. Consensus is slot-timed, and a drifting clock desynchronises the node.
