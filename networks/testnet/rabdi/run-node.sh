#!/usr/bin/env bash
# run-node.sh — bring up a node that follows the rabdi chain.
#
# Docker is the only prerequisite, and bringing the node up takes no arguments: everything else is in
# this directory, which is the chain's public record. The connection details come from p2p.yaml, which
# the operator side rewrites whenever the addresses this chain publishes move — so a node that loses its
# peering is one 'git pull' and one re-run away from having it back.
#
# The node is two containers: the execution layer and the beacon node, which holds the published
# watchers as trusted peers, so it re-dials them by itself whenever a connection drops.
#
# Re-running is also the update procedure. It replaces both containers and leaves their datadirs (named
# docker volumes) in place, so the node re-peers without resyncing.
#
# Once both containers are seen running they are set to restart with docker, so the node comes back
# after a host reboot. --teardown removes everything the script creates.
set -euo pipefail
cd "$(dirname "$0")"

# Styles for the script's output: escape sequences when its output, on both stdout and stderr, goes to a
# terminal that takes them and NO_COLOR is unset or empty, and empty otherwise, so output piped or
# redirected to a file stays plain.
bold='' dim='' cyan='' green='' red='' reset=''
if [ -t 1 ] && [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
  bold=$(printf '\033[1m')
  dim=$(printf '\033[2m')
  cyan=$(printf '\033[36m')
  green=$(printf '\033[32m')
  red=$(printf '\033[31m')
  reset=$(printf '\033[0m')
fi

NETWORK=rabdi

# The images the node runs come from images.env beside this script, so a tool reading this record and
# this script name the same images.
if [ ! -f images.env ]; then
  echo "${red}images.env is missing — this record is incomplete; git pull and retry${reset}" >&2
  exit 1
fi
# shellcheck source=/dev/null
. ./images.env

# This user's state directory for the chain: it holds the JWT the two clients share, which is a local
# secret and so is never kept in this directory, the chain's public record.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/db-chain-networks/$NETWORK"

usage(){
  cat <<EOF
${bold}Usage:${reset} ${cyan}./run-node.sh${reset}
       ${cyan}./run-node.sh --teardown${reset}

Brings up a node that follows the $NETWORK chain: an Arkiv execution client and a Lighthouse beacon
node, both in docker. Bringing it up takes no arguments: the connection details come from the
p2p.yaml beside this script, and everything else it needs is in this directory. The node peers with
every watcher p2p.yaml publishes, on both layers, so one watcher restarting leaves it the others.
The beacon node holds the watchers as trusted peers and re-dials them by itself whenever a
connection drops.

Re-running is the update procedure. It replaces both containers and keeps their datadirs, so the
node re-peers without resyncing. Once they are running they are set to restart with docker, so the
node comes back after a host reboot.

${bold}What the script creates, all of which --teardown removes:${reset}
  containers      $NETWORK-el, $NETWORK-cl
  volumes         $NETWORK-el-data, $NETWORK-cl-data (the chain data: a later run restores or resyncs it)
  docker network  $NETWORK-net
  directory       $STATE_DIR (the JWT the two clients share)

${bold}--teardown leaves the images the script pulled, since other nodes on this host may run them:${reset}
  $EL_IMAGE
  $CL_IMAGE
'docker image rm' removes one once no container uses it.

Output is coloured when it goes to a terminal; NO_COLOR=1 turns it off.
EOF
}

# teardown removes everything the script creates, and only that: the two containers, their datadir
# volumes, the network they share and the state directory holding the JWT. Each is removed only if it
# exists, so a teardown after a partial run, or a second teardown, finishes cleanly.
teardown(){
  local c v
  for c in "$NETWORK-el" "$NETWORK-cl"; do
    if docker container inspect "$c" >/dev/null 2>&1; then
      docker rm -f "$c" >/dev/null
      echo "removed container $c"
    fi
  done
  for v in "$NETWORK-el-data" "$NETWORK-cl-data"; do
    if docker volume inspect "$v" >/dev/null 2>&1; then
      docker volume rm "$v" >/dev/null
      echo "removed volume $v"
    fi
  done
  if docker network inspect "$NETWORK-net" >/dev/null 2>&1; then
    docker network rm "$NETWORK-net" >/dev/null
    echo "removed network $NETWORK-net"
  fi
  if [ -d "$STATE_DIR" ]; then
    rm -rf "$STATE_DIR"
    rmdir "$(dirname "$STATE_DIR")" 2>/dev/null || true
    echo "removed directory $STATE_DIR"
  fi
  echo "the pulled images are left in place; ./run-node.sh --help lists them"
}

case "${1:-}" in
  "")         ;;
  -h|--help) usage; exit 0;;
  --teardown) teardown; exit 0;;
  *)          usage >&2; printf '\nunexpected argument: %s\n' "$1" >&2; exit 2;;
esac

# The published endpoints, read with the tools every shell has: the enodes an execution client peers
# with, and the ENRs a beacon node boots from. Each is a YAML list, one entry per watcher, and both
# clients take the whole list comma-separated — so a watcher that is away costs this node nothing.
p2p_list(){
  awk -v key="$1:" '
    $1 == key { inlist = 1; next }
    inlist && $1 == "-" { print $2; next }
    inlist { exit }
  ' p2p.yaml | tr -d '"' | paste -sd, -
}

if [ ! -f p2p.yaml ]; then
  echo "${red}p2p.yaml is missing — this network is not currently publishing a public P2P endpoint; git pull and retry${reset}" >&2
  exit 1
fi
EL_ENODES=$(p2p_list el_enodes)
CL_ENRS=$(p2p_list cl_boot_enrs)
if [ -z "$EL_ENODES" ] || [ -z "$CL_ENRS" ]; then
  echo "${red}p2p.yaml carries no endpoints on both layers — this network is not currently publishing a complete public P2P surface; git pull and retry${reset}" >&2
  exit 1
fi
# The peer counts are printed so a joiner sees how many watchers carry it: with one per layer, a restart
# of that watcher stalls the node until the watcher is back.
echo "peering with $(awk -F, '{print NF}' <<<"$EL_ENODES") execution and $(awk -F, '{print NF}' <<<"$CL_ENRS") consensus watchers from p2p.yaml" >&2

# The JWT is a local secret shared by the two clients, so it is minted once and kept — under this
# user's state directory, since this directory is the chain's public record and holds no secret. A
# jwtsecret found beside the script is adopted into the state directory; overwriting the kept copy is
# harmless, because both clients are replaced together and share whatever the file then says.
JWT_FILE="$STATE_DIR/jwtsecret"
mkdir -p "$STATE_DIR"
[ -f jwtsecret ] && mv -f jwtsecret "$JWT_FILE"
[ -f "$JWT_FILE" ] || openssl rand -hex 32 > "$JWT_FILE"

# A re-run starts from a clean pair of containers; the named volumes below carry the chain data across.
docker rm -f "$NETWORK-el" "$NETWORK-cl" >/dev/null 2>&1 || true

# The two containers share a private network, so the beacon node reaches the execution layer by name
# whatever order they come up in. It outlives a run and is shared by every re-run.
docker network inspect "$NETWORK-net" >/dev/null 2>&1 || docker network create "$NETWORK-net" >/dev/null

# The execution layer. Its arguments start at 'node' because the image's entrypoint is the Arkiv binary
# itself. The RPC is bound to loopback: it is there to be read from this host, not served.
#
# Discovery stays off: the node reaches the chain by dialing the published enodes directly, and a
# joiner typically sits behind NAT, so any address discovery would advertise is one the network
# cannot dial back — the watchers would burn their outbound attempts on it. The default discovery
# bootnodes also belong to public Ethereum, whose nodes have nothing to offer this chain.
#
# ARKIV_STORE_PATH names the directory of the Arkiv store, which runs inside the node and refuses to
# start without it. The store sits in the datadir volume beside reth's own database, so it survives a
# re-run and is part of every snapshot of /data.
docker run -d --name "$NETWORK-el" --network "$NETWORK-net" \
  -v "$PWD:/gen" -v "$JWT_FILE:/jwtsecret:ro" -v "$NETWORK-el-data:/data" -p 127.0.0.1:8545:8545 \
  -e ARKIV_STORE_PATH=/data/golemdb \
  "$EL_IMAGE" \
  node --chain /gen/genesis.json --datadir /data \
    --authrpc.addr 0.0.0.0 --authrpc.port 8551 --authrpc.jwtsecret /jwtsecret \
    --http --http.addr 0.0.0.0 --http.api eth,net,web3 \
    --disable-discovery \
    --trusted-peers "$EL_ENODES"

# The consensus layer, driving the execution layer over the engine API. Its HTTP API is bound to
# loopback too: the sync state lives there, and it is the first thing to read when a node looks stuck.
# With optimistic finalized sync off, it hands every finalized block to the execution layer for
# verification while it syncs, which lets the execution layer catch up after a long stop.
#
# Discovery stays off here too: the node peers with the published watchers alone, dialing their ENRs at
# startup and re-dialing them as trusted peers afterwards, and an address discovery would advertise
# from behind NAT is one the watchers cannot dial back.
#
# The watchers are held as trusted peers through the beacon API, at every start of the beacon node:
# lighthouse's --trusted-peers takes bare peer ids and dials nothing, while POST /lighthouse/add_peer
# with an ENR pins the peer's score and re-dials it every heartbeat, and that set lives in the
# process's memory. The container's command registers them before handing over to lighthouse, so the
# registration comes with every start of the process, the restart after a host reboot included. It
# speaks HTTP through bash's TCP redirection, since the image carries no HTTP client. The registration
# loop is started from a subshell that exits at once, so it is orphaned to the init process --init
# provides, which reaps it when it finishes.
docker run -d --name "$NETWORK-cl" --init --network "$NETWORK-net" \
  -v "$PWD:/gen" -v "$JWT_FILE:/jwtsecret:ro" -v "$NETWORK-cl-data:/data" -p 127.0.0.1:5052:5052 \
  -e CL_ENRS="$CL_ENRS" \
  "$CL_IMAGE" \
  bash -c 'register(){
  local enr body status
  for enr in ${CL_ENRS//,/ }; do
    body="{\"enr\":\"$enr\"}"
    { exec 3<>/dev/tcp/127.0.0.1/5052; } 2>/dev/null || return 1
    printf "POST /lighthouse/add_peer HTTP/1.1\r\nHost: 127.0.0.1:5052\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s" "${#body}" "$body" >&3
    read -r -t 5 status <&3 || status=
    exec 3>&-
    case $status in *" 200 "*) ;; *) return 1;; esac
  done
}
( ( until register; do sleep 5; done; echo "registered the watchers as trusted beacon peers" ) & )
exec lighthouse "$@"' bash beacon_node --testnet-dir /gen --datadir /data \
    --execution-endpoint "http://$NETWORK-el:8551" --execution-jwt /jwtsecret \
    --http --http-address 0.0.0.0 \
    --boot-nodes "$CL_ENRS" --disable-discovery \
    --allow-insecure-genesis-sync --ignore-ws-check --disable-optimistic-finalized-sync

# A container that refuses its arguments is gone within a second or two, so the run is confirmed before
# it is called a success: a "started" line printed over a dead container is worse than no line at all.
sleep 3
down=0
for container in "$NETWORK-el" "$NETWORK-cl"; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" != true ]; then
    echo "${red}$container is not running. Its last log lines:${reset}" >&2
    docker logs --tail 20 "$container" >&2 || true
    down=1
  fi
done
if [ "$down" = 1 ]; then
  echo "${red}the node did not come up — address the cause above and run this script again${reset}" >&2
  exit 1
fi

# Containers that have been seen running are armed to come back with dockerd, so the node survives a
# host reboot. Arming a container before it is checked would let one that crash-loops read as running.
docker update --restart unless-stopped "$NETWORK-el" "$NETWORK-cl" >/dev/null

cat <<EOF

${bold}${green}Started $NETWORK-el and $NETWORK-cl.${reset}

${dim}To verify, watch the execution layer establish a session with a published peer:${reset}
  ${cyan}docker logs -f $NETWORK-el${reset}
${dim}read the beacon node's sync state:${reset}
  ${cyan}curl -s http://localhost:5052/eth/v1/node/syncing${reset}
${dim}and watch the head climb to the chain's:${reset}
  ${cyan}curl -s -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' http://localhost:8545${reset}
${dim}and read the watchers among the beacon node's peers, each held as trusted at score "Max":${reset}
  ${cyan}curl -s http://localhost:5052/lighthouse/peers${reset}

${dim}To update, or to recover a peering that stopped holding: ${reset}${cyan}git pull${reset}${dim}, then run this script again.${reset}
${dim}To remove everything this script created: ${reset}${cyan}./run-node.sh --teardown${reset}
EOF
