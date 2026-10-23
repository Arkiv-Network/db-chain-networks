#!/usr/bin/env bash
# run-node.sh — bring up a node that follows the follow-pub chain.
#
# Docker is the only prerequisite, and bringing the node up takes no arguments: everything else is in
# this directory, which is the chain's public record. The connection details come from p2p.yaml, which
# the operator side rewrites whenever the addresses this chain publishes move — so a node that loses its
# peering is one 'git pull' and one re-run away from having it back.
#
# Re-running is also the update procedure. It replaces both containers and leaves their datadirs (named
# docker volumes) in place, so the node re-peers without resyncing.
#
# Once both containers are seen running they are set to restart with docker, so the node comes back
# after a host reboot. --teardown removes everything the script creates.
#
# A run that finds both datadirs empty fills them from this chain's published snapshot first, so the
# node starts near the head instead of syncing from genesis, which takes days. A node that already
# holds chain data is left as it is, and FROM_GENESIS=1 skips the step and syncs from genesis.
set -euo pipefail
cd "$(dirname "$0")"

NETWORK=follow-pub
EL_IMAGE=ghcr.io/arkiv-network/arkiv-reth:v0.5.1@sha256:73e9f5c5a6105b2c2603cbfa7081a2803cdb15f00328f9c6db0dd43556235a50
CL_IMAGE=sigp/lighthouse:v8.3.1@sha256:05b5068268ea3fbd64389309d1d7c15b8f18a53f28d0886f098316302f4cdb41
SNAPSHOTS_URL=https://devnet.snapshots.gobas.me
BOOT_IMAGE=alpine:3.22.7@sha256:e9f2de928efcc1b53d0948e684b4f490315f280de6044844ec0ff26c0b44d3cf

# This user's state directory for the chain: it holds the JWT the two clients share, which is a local
# secret and so is never kept in this directory, the chain's public record.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/db-chain-networks/$NETWORK"

usage(){
  cat <<EOF
Usage: ./run-node.sh
       ./run-node.sh --teardown

Brings up a node that follows the $NETWORK chain: an Arkiv execution client and a Lighthouse beacon
node, both in docker. Bringing it up takes no arguments: the connection details come from the
p2p.yaml beside this script, and everything else it needs is in this directory. The node peers with
every watcher p2p.yaml publishes, on both layers, so one watcher restarting leaves it the others.

Re-running is the update procedure. It replaces both containers and keeps their datadirs, so the node
re-peers without resyncing. Once they are running they are set to restart with docker, so the node
comes back after a host reboot.

With both datadirs empty — a first run, or one after removing them — the script restores this chain's
published snapshot before starting the clients, so the node begins near the head. FROM_GENESIS=1 skips
that and syncs from genesis instead.

What the script creates, all of which --teardown removes:
  containers      $NETWORK-el, $NETWORK-cl
  volumes         $NETWORK-el-data, $NETWORK-cl-data (the chain data: a later run restores or resyncs it)
  docker network  $NETWORK-net
  directory       $STATE_DIR (the JWT the two clients share)

--teardown leaves the images the script pulled, since other nodes on this host may run them:
  $EL_IMAGE
  $CL_IMAGE
  $BOOT_IMAGE
'docker image rm' removes one once no container uses it.
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
  echo "p2p.yaml is missing — this network is not currently publishing a public P2P endpoint; git pull and retry" >&2
  exit 1
fi
EL_ENODES=$(p2p_list el_enodes)
CL_ENRS=$(p2p_list cl_boot_enrs)
if [ -z "$EL_ENODES" ] || [ -z "$CL_ENRS" ]; then
  echo "p2p.yaml carries no endpoints on both layers — this network is not currently publishing a complete public P2P surface; git pull and retry" >&2
  exit 1
fi
# The peer counts are printed so a joiner sees how many watchers carry it: with one per layer, a restart
# of that watcher stalls the node until the watcher is back.
echo "peering with $(awk -F, '{print NF}' <<<"$EL_ENODES") execution and $(awk -F, '{print NF}' <<<"$CL_ENRS") consensus watchers from p2p.yaml" >&2

# The JWT is a local secret shared by the two containers, so it is minted once and kept — under this
# user's state directory, since this directory is the chain's public record and holds no secret. A
# jwtsecret found beside the script is adopted into the state directory; overwriting the kept copy is
# harmless, because both containers are replaced together and share whatever the file then says.
JWT_FILE="$STATE_DIR/jwtsecret"
mkdir -p "$STATE_DIR"
[ -f jwtsecret ] && mv -f jwtsecret "$JWT_FILE"
[ -f "$JWT_FILE" ] || openssl rand -hex 32 > "$JWT_FILE"

# The chain's published snapshot. Restoring it is a download and an untar, where syncing from genesis
# takes days — so a node whose datadirs are both empty is filled from it before the clients start.
#
# The work runs in a throwaway container holding both datadirs and this directory: the host needs no
# tools beyond docker, and the container gets the script to run in an environment variable, which
# leaves this terminal's stdin free to answer the one question the step can ask.
read -r -d '' BOOTSTRAP <<'INNER' || true
set -euo pipefail
ts(){ date -u +%FT%TZ; }
say(){ echo "$(ts) $*" >&2; }

# Anything that goes wrong leaves both datadirs empty, so a re-run starts clean instead of resuming
# onto half a chain.
wipe(){
  find "$@" -mindepth 1 -delete
}
cleanup(){
  if [ "$1" -ne 0 ] && { [ -n "$(ls -A /el)" ] || [ -n "$(ls -A /cl)" ]; }; then
    say "bootstrap failed — emptying both datadirs so a re-run starts clean"
    wipe /el /cl
  fi
}
trap 'cleanup $?' EXIT

# use_initial <path> <reason> — settles the manifest on the record's initial snapshot, copied to <path>,
# and says why it is the source. The snapshot's own base URL becomes the endpoint its layers are read from.
use_initial(){
  local out=$1
  cp /gen/initial-snapshot.json "$out"
  [ "$(jq -r '.private // false' "$out")" != true ] || { say "initial snapshot is private; pre-download it with authentication and set SNAPSHOT_DIR"; exit 1; }
  SNAPSHOTS_URL=$(jq -er '.snapshotBaseUrl | select(startswith("https://"))' "$out")
  say "restoring from initial-snapshot.json: $2"
}

# fetch_manifest <path> — writes the snapshot's manifest to <path>: copied from the directory a
# pre-downloaded snapshot was taken from, or read from the endpoint. A chain that publishes no snapshot
# answers 404, and a network wiped since its last snapshot answers with the wipe's tombstone, which
# names when it was wiped and carries no layers. Either way, at a terminal that is a question, and
# otherwise the run stops rather than silently starting a sync from genesis that takes days.
fetch_manifest(){
  local out=$1 code current previous
  if [ -n "${SNAPSHOT_DIR:-}" ]; then
    if [ -f /snapshot/latest.json ]; then
      cp /snapshot/latest.json "$out"
      say "restoring from latest.json of the pre-downloaded snapshot directory"
    else
      cp /snapshot/manifest.json "$out"
      say "restoring from manifest.json of the pre-downloaded snapshot directory"
    fi
    return 0
  fi
  if [ "${SNAPSHOTS_PRIVATE:-false}" = true ]; then
    say "private snapshots require an authenticated pre-download and SNAPSHOT_DIR"
    exit 1
  fi
  if [ -z "${SNAPSHOTS_URL:-}" ] && [ -s /gen/initial-snapshot.json ]; then
    use_initial "$out" "SNAPSHOTS_URL is unset"
    return
  fi
  code=$(curl -sS -o "$out" -w '%{http_code}' "$SNAPSHOTS_URL/$NETWORK/latest.json") || { say "cannot reach $SNAPSHOTS_URL"; exit 1; }
  if { [ "$code" = 404 ] || { [ "$code" = 200 ] && jq -e '.wiped' "$out" >/dev/null 2>&1; }; } && [ -s /gen/initial-snapshot.json ]; then
    use_initial "$out" "latest.json is $([ "$code" = 404 ] && echo "404" || echo "a tombstone (wiped $(jq -r '.wiped' "$out"))")"
    return
  fi
  # A registry restore may regenerate the beacon clock before a fresh backup
  # exists. Only its immutable genesis generation is safe across that boundary.
  if [ "$code" = 200 ] && [ -s /gen/initial-snapshot.json ] && [ "$(jq -r '.kind // empty' "$out")" != genesis ]; then
    current=$(sed -n "s/^MIN_GENESIS_TIME:[[:space:]]*//p" /gen/config.yaml | tr -d "\"' \r")
    previous=$(jq -r '.genesisTime // empty' "$out")
    if [ -n "$previous" ] && [ "$previous" != "$current" ]; then
      use_initial "$out" "latest.json records beacon genesis time $previous and this record's is $current"
      return
    fi
  fi
  case "$code" in
    200)
      if ! jq -e '.wiped' "$out" >/dev/null 2>&1; then
        say "restoring from $SNAPSHOTS_URL/$NETWORK/latest.json: the live pointer to the newest snapshot"
        return 0
      fi
      say "$NETWORK was wiped at $(jq -r '.wiped' "$out") and has not published a snapshot since — retry later, or sync from genesis";;
    404)
      say "no snapshot is published for $NETWORK at $SNAPSHOTS_URL — the sync would run from genesis";;
    *)   say "GET $SNAPSHOTS_URL/$NETWORK/latest.json: HTTP $code"; exit 1;;
  esac
  genesis_or_stop
}

# genesis_or_stop — ends a bootstrap that has no snapshot to restore: at a terminal it asks whether to
# sync from genesis instead, and otherwise it stops and says how to ask for one.
genesis_or_stop(){
  local answer
  if [ -t 0 ]; then
    read -r -p "sync from genesis instead? [y/N] " answer
    case "$answer" in
      y|Y) exit 0;;
      *)   exit 1;;
    esac
  fi
  say "run this script with FROM_GENESIS=1 to sync from genesis"
  exit 1
}

# digest <image ref> — the ref's manifest digest, or the whole ref when it carries none: two refs
# naming one digest are the same image however each spells the repository it was pulled from.
digest(){
  case "$1" in
    *@sha256:*) echo "${1##*@}";;
    *)          echo "$1";;
  esac
}

# manifest_check <genesis.json> <manifest> — refuses a snapshot of another chain, and one of an earlier
# incarnation of this chain: a wipe keeps the chain id and re-stamps MIN_GENESIS_TIME in the config.yaml
# beside genesis.json, so a manifest recording another genesis time is of a chain that no longer runs. A
# manifest that records none is checked by chain id alone. It says so when the clients that wrote the
# databases are not the ones this node runs, which is a difference to weigh rather than a reason to stop.
manifest_check(){
  local genesis=$1 manifest=$2 want have pair layer ours theirs
  want=$(jq -r .config.chainId "$genesis")
  have=$(jq -r .chainId "$manifest")
  if [ "$want" != "$have" ]; then
    say "the snapshot is of chain $have and this record is chain $want — refusing to restore it"
    exit 1
  fi
  if [ "$(jq -r '.kind // empty' "$manifest")" = genesis ]; then
    jq -e '.head.slot == 0 and .head.block == 0 and .layers.el != null and .layers.cl == null' "$manifest" >/dev/null || { say "invalid genesis snapshot"; exit 1; }
    want=$(sha256sum "$genesis" | cut -d' ' -f1)
    have=$(jq -r '.genesis.genesisSha256' "$manifest")
    [ "$want" = "$have" ] || { say "genesis snapshot execution genesis checksum mismatch"; exit 1; }
    want=$(jq -er .stateHash "$genesis")
    have=$(jq -r '.genesis.stateRoot' "$manifest")
    [ "$want" = "$have" ] || { say "genesis snapshot state root mismatch"; exit 1; }
    # Generation zero has no consensus history: a restored/wiped network can restamp
    # its beacon clock while retaining the verified execution genesis identity.
    return
  fi
  have=$(jq -r '.genesisTime // empty' "$manifest")
  if [ -n "$have" ]; then
    want=$(sed -n "s/^MIN_GENESIS_TIME:[[:space:]]*//p" "$(dirname "$genesis")/config.yaml" | tr -d "\"' \r") \
      || want=""
    if [ "$want" != "$have" ]; then
      say "$NETWORK was wiped since this snapshot was taken (snapshot genesis $have, this chain's genesis ${want:-unknown}); it is obsolete — use $SNAPSHOTS_URL/$NETWORK/latest.json"
      exit 1
    fi
  fi
  for pair in "reth:$EL_IMAGE" "lighthouse:$CL_IMAGE"; do
    layer=${pair%%:*}
    ours=${pair#*:}
    theirs=$(jq -r ".images.$layer" "$manifest")
    [ "$(digest "$ours")" = "$(digest "$theirs")" ] || say "note: the snapshot was written by $theirs, and this node runs $ours"
  done
}

# space_check <manifest> <dir> — refuses a restore the filesystem holding the datadirs cannot take:
# both layers unpacked, plus a tenth for the chain to grow into while the node catches up. df -kP keeps
# the columns on one line whatever the device is called. The datadirs are docker volumes, so the
# filesystem measured is the one holding docker's data root, on the machine the docker daemon runs on;
# the figure names it.
space_check(){
  local manifest=$1 dir=$2 raw gz avail need where
  raw=$(jq -r '.layers.el.rawBytes + (.layers.cl.rawBytes // 0)' "$manifest")
  gz=$(jq -r '.layers.el.bytes + (.layers.cl.bytes // 0)' "$manifest")
  avail=$(df -kP "$dir" | awk 'NR==2{print $4*1024}')
  need=$((raw + raw / 10))
  where=${DOCKER_ROOT:+the disk holding the docker data root, $DOCKER_ROOT}
  say "$((gz/1024/1024/1024)) GiB to fetch, $((raw/1024/1024/1024)) GiB unpacked, $((avail/1024/1024/1024)) GiB free on ${where:-the filesystem holding $dir}"
  if [ "$avail" -lt "$need" ]; then
    say "not enough free space: the restore needs $((need/1024/1024/1024)) GiB with headroom"
    exit 1
  fi
}

# floor_for <bytes per second> — the rate a range has to hold to be worth waiting on: an eighth of the
# fastest range so far, and never under MIN_RATE. A link states its own pace, so a connection crawling
# where others fly is replaced while a link that is simply slow is left to run.
floor_for(){
  local min=${MIN_RATE:-1048576} eighth=$(($1 / 8))
  echo $((eighth > min ? eighth : min))
}

# fetch_range <url> <from> <to> <out> <floor> — writes one byte range of an object to <out>, retried
# until it arrives whole: one stream held open for a whole layer is reset partway through, a range that
# comes up short is a truncated chunk rather than the end of the object, and a connection that degrades
# stays degraded — so a transfer averaging under <floor> bytes a second for a minute is a failed try, a
# connection worth replacing rather than waiting on. The floor is the caller's, an eighth of the best
# rate a range has reached and never under MIN_RATE. Each wait is RETRY_BACKOFF seconds longer than the
# last, and the range fails once six tries are spent.
fetch_range(){
  local url=$1 from=$2 to=$3 out=$4 floor=$5 backoff=${RETRY_BACKOFF:-5} n try
  n=$((to - from + 1))
  for try in 1 2 3 4 5 6; do
    if curl -fsS -r "$from-$to" --connect-timeout 30 --speed-limit "$floor" --speed-time 60 -o "$out" "$url" &&
      [ "$(wc -c <"$out" | tr -d ' ')" -eq "$n" ]; then
      return 0
    fi
    rm -f "$out"
    [ "$try" -lt 6 ] || { say "range $from-$to of ${url##*/} did not arrive whole in $try tries"; return 1; }
    sleep $((try * backoff))
  done
}

# fetch_object <url> <bytes> — streams an object to stdout a range at a time, with the next range
# downloading while the current one is written into the pipe: unpacking a layer costs about twice what
# fetching it does, so an overlapped fetch takes no time of its own. One range ahead is all that pays —
# the unpack the whole stream waits on is what remains — and it is what the two files alternate between.
fetch_object(){
  # Both files exist at once, so the container needs 2 x CHUNK_BYTES free in /tmp: 2 GiB by default.
  local url=$1 total=$2 chunk=${CHUNK_BYTES:-$((1<<30))} from=0 to slot=0 cur next pid
  # Every range is timed, and the fastest of them sets the floor the next ones are held to.
  local best=0 flight=0 started=0 rate
  [ "$total" -gt 0 ] || return 0
  to=$((chunk - 1))
  [ "$to" -ge "$total" ] && to=$((total - 1))
  cur=/tmp/chunk.$slot
  flight=$((to - from + 1))
  started=$SECONDS
  fetch_range "$url" "$from" "$to" "$cur" "$(floor_for "$best")" || return 1
  rate=$((flight / (SECONDS - started + 1)))
  [ "$rate" -gt "$best" ] && best=$rate
  while :; do
    from=$((to + 1))
    pid=""
    if [ "$from" -lt "$total" ]; then
      to=$((from + chunk - 1))
      [ "$to" -ge "$total" ] && to=$((total - 1))
      slot=$((1 - slot))
      next=/tmp/chunk.$slot
      flight=$((to - from + 1))
      started=$SECONDS
      fetch_range "$url" "$from" "$to" "$next" "$(floor_for "$best")" &
      pid=$!
    fi
    cat "$cur"
    rm -f "$cur"
    [ -n "$pid" ] || break
    # A range that spent its tries fails the layer rather than reaching tar as a hole. Its clock runs
    # until here, past the unpack it was fetched behind, so a rate measured while the unpack is the
    # slower half reads low and the floor it sets is the conservative one.
    wait "$pid" || return 1
    rate=$((flight / (SECONDS - started + 1)))
    [ "$rate" -gt "$best" ] && best=$rate
    cur=$next
  done
  rm -f /tmp/chunk.0 /tmp/chunk.1
}

# layer_stream <key> <bytes> — writes one layer's object to stdout: the file a pre-downloaded snapshot
# directory holds under the key's basename, or the object read from the endpoint a range at a time.
layer_stream(){
  if [ -n "${SNAPSHOT_DIR:-}" ]; then
    cat "/snapshot/${1##*/}"
  else
    fetch_object "$SNAPSHOTS_URL/$1" "$2"
  fi
}

# unpack <compression> <dir> — unpacks the archive on stdin into <dir>, decompressed as the manifest
# states. A zstd layer is written with a 2^27 window, which --long=27 matches.
unpack(){
  case "$1" in
    gzip) tar -xzf - -C "$2" ;;
    zstd) zstd -d --long=27 -c | tar -xf - -C "$2" ;;
  esac
}

# restore_layer <layer> <manifest> <dir> — unpacks one layer's object into <dir>, hashing and counting
# the stream on its way into tar, so a download that arrived wrong is caught rather than started from.
# The archive carries its owners, so each datadir comes out owned as its client runs.
restore_layer(){
  local layer=$1 manifest=$2 dir=$3 key want_sha want_bytes have_sha have_bytes started first file compression
  key=$(jq -r ".layers.$layer.key" "$manifest")
  want_sha=$(jq -r ".layers.$layer.sha256" "$manifest")
  want_bytes=$(jq -r ".layers.$layer.bytes" "$manifest")
  compression=$(jq -r ".layers.$layer.compression" "$manifest")
  case "$compression" in
    gzip|zstd) ;;
    *) say "$layer: unsupported snapshot compression: $compression"; exit 1 ;;
  esac
  rm -f "/tmp/$layer.sha" "/tmp/$layer.bytes"
  started=$(date +%s)
  if [ -n "${SNAPSHOT_DIR:-}" ]; then
    file=/snapshot/${key##*/}
    [ -r "$file" ] || { say "$layer: $file is missing from the snapshot directory"; exit 1; }
    say "$layer: reading $file"
  else
    say "$layer: fetching $key"
  fi
  layer_stream "$key" "$want_bytes" \
    | tee >(sha256sum | cut -d' ' -f1 > "/tmp/$layer.sha") >(wc -c | tr -d ' ' > "/tmp/$layer.bytes") \
    | unpack "$compression" "$dir"
  # The two readers hang off the pipeline and finish just after it, so their results are waited for.
  for _ in $(seq 1 30); do
    [ -s "/tmp/$layer.sha" ] && [ -s "/tmp/$layer.bytes" ] && break
    sleep 1
  done
  have_sha=$(cat "/tmp/$layer.sha")
  have_bytes=$(cat "/tmp/$layer.bytes")
  if [ "$have_sha" != "$want_sha" ]; then
    say "$layer: sha256 mismatch — $have_sha arrived, the manifest states $want_sha"
    exit 1
  fi
  if [ "$have_bytes" != "$want_bytes" ]; then
    say "$layer: size mismatch — $have_bytes bytes arrived, the manifest states $want_bytes"
    exit 1
  fi
  # The archive records the datadir's root as root-owned with the client's group, which a bare container
  # has no membership of: the root takes the ownership of what it holds, so the client can write in it.
  # ls -nd prints an entry's numeric owner and group as its third and fourth columns.
  first=$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit)
  # shellcheck disable=SC2012
  chown "$(ls -nd "$first" | awk '{print $3 ":" $4}')" "$dir"
  say "$layer: verified $have_bytes bytes in $(($(date +%s) - started)) s"
}

fetch_manifest /tmp/latest.json
manifest_check /gen/genesis.json /tmp/latest.json
if [ "$(jq -r '.private // false' /tmp/latest.json)" = true ] && [ -z "${SNAPSHOT_DIR:-}" ]; then
  say "private snapshot requires authenticated pre-download and SNAPSHOT_DIR"
  exit 1
fi
run=$(jq -r .run /tmp/latest.json)
slot=$(jq -r .head.slot /tmp/latest.json)
block=$(jq -r .head.block /tmp/latest.json)
say "snapshot $run: head slot $slot, block $block"
space_check /tmp/latest.json /el
restore_layer el /tmp/latest.json /el
if [ "$(jq -r '.kind // empty' /tmp/latest.json)" = genesis ]; then
  # Receipt only, not consensus state or a node identity. Lighthouse initializes
  # from this registry's matching genesis.ssz, including its current clock.
  cp /tmp/latest.json /cl/.initial-snapshot.json
else
  restore_layer cl /tmp/latest.json /cl
fi
say "restored $NETWORK at slot $slot, block $block, from snapshot $run — the node syncs forward from there"
INNER

# volume_empty <volume> — true when the named volume holds nothing. It is read through a container, so
# the host needs no access to where docker keeps its volumes.
volume_empty(){
  [ -z "$(docker run --rm -v "$1:/v:ro" "$BOOT_IMAGE" ls -A /v)" ]
}

# bootstrap_container [docker run flag]... — runs the bootstrap in a throwaway container holding both
# datadirs and this directory, and a pre-downloaded snapshot directory when the run names one. The
# script it runs travels in the environment rather than on stdin, which leaves this terminal free to
# answer the one question the step can ask.
bootstrap_container(){
  local args=(--rm -i "$@" -v "$NETWORK-el-data:/el" -v "$NETWORK-cl-data:/cl" -v "$PWD:/gen:ro")
  [ -z "${SNAPSHOT_DIR:-}" ] || args+=(-v "$SNAPSHOT_DIR:/snapshot:ro")
  docker run "${args[@]}" \
    -e NETWORK -e SNAPSHOTS_URL -e SNAPSHOTS_PRIVATE -e EL_IMAGE -e CL_IMAGE -e BOOTSTRAP -e SNAPSHOT_DIR \
    -e DOCKER_ROOT -e CHUNK_BYTES -e RETRY_BACKOFF -e MIN_RATE \
    "$BOOT_IMAGE" sh -c 'apk add --no-cache --upgrade ca-certificates ca-certificates-bundle bash curl jq zstd >/dev/null 2>&1 && exec bash -c "$BOOTSTRAP"'
}

# docker_disk — sets DOCKER_ROOT to docker's data root, where the datadirs' volumes live, and says so
# when that is not this machine's disk: Docker Desktop keeps it on a virtual disk with a size cap of its
# own, stored on this machine's disk, and a remote daemon keeps it on another host. The restore's
# free-space check measures the disk holding the data root, so this machine's free space is printed
# beside it whenever the two differ.
docker_disk(){
  local info os
  DOCKER_ROOT=""
  info=$(docker info --format '{{.DockerRootDir}}|{{.OperatingSystem}}' 2>/dev/null) || return 0
  DOCKER_ROOT=${info%%|*}
  os=${info#*|}
  case "$os" in
    *"Docker Desktop"*) ;;
    *) [ ! -d "$DOCKER_ROOT" ] || return 0;;
  esac
  echo "docker keeps its data at $DOCKER_ROOT on a disk other than this machine's ($os): the free space the restore checks is that disk's" >&2
  echo "Docker Desktop caps that disk at the size set in its Resources settings and stores it on this machine's disk, which has $(df -kP "$HOME" | awk 'NR==2{print int($4/1048576)}') GiB free" >&2
}

# Both datadirs are filled together or not at all: one layer restored to a point of the chain the other
# never saw is not a node, so a datadir holding data is what says the node has been running and needs
# nothing bootstrapped.
bootstrap_from_snapshot(){
  local el_vol="$NETWORK-el-data" cl_vol="$NETWORK-cl-data" el_empty=0 cl_empty=0 given
  # A snapshot downloaded ahead of the run is read from a directory instead of the endpoint. The path is
  # resolved while the shell is still where the operator typed it, and a directory that holds no manifest
  # is refused before anything is created.
  if [ -n "${SNAPSHOT_DIR:-}" ]; then
    given=$SNAPSHOT_DIR
    SNAPSHOT_DIR=$(cd "$given" 2>/dev/null && pwd) || { echo "SNAPSHOT_DIR $given is not a directory" >&2; exit 1; }
    if [ ! -f "$SNAPSHOT_DIR/latest.json" ] && [ ! -f "$SNAPSHOT_DIR/manifest.json" ]; then
      echo "SNAPSHOT_DIR holds neither $SNAPSHOT_DIR/latest.json nor $SNAPSHOT_DIR/manifest.json" >&2
      exit 1
    fi
  fi
  docker volume create "$el_vol" >/dev/null
  docker volume create "$cl_vol" >/dev/null
  volume_empty "$el_vol" && el_empty=1
  volume_empty "$cl_vol" && cl_empty=1
  if [ "$el_empty$cl_empty" = 00 ]; then
    return 0
  fi
  if [ "$el_empty$cl_empty" != 11 ]; then
    echo "one datadir holds chain data and the other is empty; a snapshot restores both layers at one point of the chain" >&2
    echo "to bootstrap from the snapshot: docker volume rm $el_vol $cl_vol — then run this script again" >&2
    exit 1
  fi
  if [ -n "${SNAPSHOT_DIR:-}" ]; then
    echo "restoring $NETWORK from $SNAPSHOT_DIR" >&2
  else
    echo "bootstrapping $NETWORK from $SNAPSHOTS_URL" >&2
  fi
  docker_disk
  # Every variable the container reads has to be exported for docker to pass it along by name. The knobs
  # and the snapshot directory are named whether or not this run sets them: an unset name passes nothing,
  # and the bootstrap falls back to its own defaults.
  export NETWORK SNAPSHOTS_URL SNAPSHOTS_PRIVATE EL_IMAGE CL_IMAGE BOOTSTRAP SNAPSHOT_DIR DOCKER_ROOT CHUNK_BYTES RETRY_BACKOFF MIN_RATE
  # A terminal is given to the container only when there is one, so the question the step can ask is
  # answerable by hand and a run with none is not left waiting on a prompt nobody sees.
  if [ -t 0 ]; then
    bootstrap_container -t
  else
    bootstrap_container
  fi
}

if [ -s initial-snapshot.json ] && [ "${FROM_GENESIS:-}" = 1 ]; then
  echo "this execution genesis requires seeded state; FROM_GENESIS cannot skip its snapshot" >&2
  exit 1
fi
if [ -n "${SNAPSHOTS_URL:-}" ] && [ "${FROM_GENESIS:-}" != 1 ]; then
  bootstrap_from_snapshot
elif [ "${FROM_GENESIS:-}" != 1 ] && { [ "${SNAPSHOTS_PRIVATE:-false}" = true ] || [ -s initial-snapshot.json ]; }; then
  bootstrap_from_snapshot
fi

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
docker run -d --name "$NETWORK-el" --network "$NETWORK-net" \
  -v "$PWD:/gen" -v "$JWT_FILE:/jwtsecret:ro" -v "$NETWORK-el-data:/data" -p 127.0.0.1:8545:8545 \
  "$EL_IMAGE" \
  node --chain /gen/genesis.json --datadir /data \
    --authrpc.addr 0.0.0.0 --authrpc.port 8551 --authrpc.jwtsecret /jwtsecret \
    --http --http.addr 0.0.0.0 --http.api eth,net,web3 \
    --disable-discovery \
    --trusted-peers "$EL_ENODES"

# The consensus layer, driving the execution layer over the engine API. Its HTTP API is bound to
# loopback too: the sync state lives there, and it is the first thing to read when a node looks stuck.
docker run -d --name "$NETWORK-cl" --network "$NETWORK-net" \
  -v "$PWD:/gen" -v "$JWT_FILE:/jwtsecret:ro" -v "$NETWORK-cl-data:/data" -p 127.0.0.1:5052:5052 \
  "$CL_IMAGE" \
  lighthouse beacon_node --testnet-dir /gen --datadir /data \
    --execution-endpoint "http://$NETWORK-el:8551" --execution-jwt /jwtsecret \
    --http --http-address 0.0.0.0 \
    --boot-nodes "$CL_ENRS" \
    --allow-insecure-genesis-sync --ignore-ws-check

# A container that refuses its arguments is gone within a second or two, so the run is confirmed before
# it is called a success: a "started" line printed over a dead container is worse than no line at all.
sleep 3
down=0
for container in "$NETWORK-el" "$NETWORK-cl"; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" != true ]; then
    printf '%s is not running. Its last log lines:\n' "$container" >&2
    docker logs --tail 20 "$container" >&2 || true
    down=1
  fi
done
if [ "$down" = 1 ]; then
  echo "the node did not come up — address the cause above and run this script again" >&2
  exit 1
fi

# A pair that has been seen running is armed to come back with dockerd, so the node survives a host
# reboot. Arming a container before it is checked would let one that crash-loops read as running.
docker update --restart unless-stopped "$NETWORK-el" "$NETWORK-cl" >/dev/null

cat <<EOF

Started $NETWORK-el and $NETWORK-cl.

To verify, watch the execution layer establish a session with a published peer:
  docker logs -f $NETWORK-el
read the beacon node's sync state:
  curl -s http://localhost:5052/eth/v1/node/syncing
and watch the head climb to the chain's:
  curl -s -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' http://localhost:8545

To update, or to recover a peering that stopped holding: git pull, then run this script again.
To remove everything this script created: ./run-node.sh --teardown
EOF
