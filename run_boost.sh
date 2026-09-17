#!/bin/bash

set -e

# ==================================================
# Configuration
# ==================================================

BOOST_CONTAINER="boost"
BOOST_DATA_CONTAINER="boost-data"
LOTUS_CONTAINER="lotus-node-0"

BOOST_NETWORK="fil-lotus-devnet_lotus"

BOOST_IMAGE="boost-node"
BOOST_DATA_IMAGE="boost-data-node"

BOOST_REPO_VOLUME="boost-repo"
BOOST_CLIENT_VOLUME="boost-client"
BOOST_DATA_VOLUME="boost-data"

MAX_STAGING_DEALS_BYTES=1073741824
BOOST_LIBP2P_PORT="${BOOST_LIBP2P_PORT:-50000}"
BOOST_PUBLIC_HOST="${BOOST_PUBLIC_HOST:-boost}"

# ==================================================
# Header
# ==================================================

echo "======================================"
echo " Starting Boost"
echo "======================================"
echo

# ==================================================
# Check Docker
# ==================================================

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker is not available."
    exit 1
fi

# ==================================================
# Check Lotus
# ==================================================

if ! docker ps --format '{{.Names}}' | grep -q "^${LOTUS_CONTAINER}$"; then
    echo "ERROR: Lotus container is not running:"
    echo "  $LOTUS_CONTAINER"
    exit 1
fi

echo "Lotus container:"
echo "  $LOTUS_CONTAINER"
echo

# ==================================================
# Check network
# ==================================================

if ! docker network inspect "$BOOST_NETWORK" >/dev/null 2>&1; then
    echo "ERROR: Docker network not found:"
    echo "  $BOOST_NETWORK"
    exit 1
fi

echo "Docker network:"
echo "  $BOOST_NETWORK"
echo

# ==================================================
# Remove old containers
# ==================================================

echo "Removing old Boost containers..."

docker rm -f "$BOOST_CONTAINER" 2>/dev/null || true
docker rm -f "$BOOST_DATA_CONTAINER" 2>/dev/null || true

echo

# ==================================================
# Build images
# ==================================================

echo "Building Boost image..."

docker build \
    -t "$BOOST_IMAGE" \
    -f Dockerfile.boost \
    .

echo

echo "Building Boost Data image..."

docker build \
    -t "$BOOST_DATA_IMAGE" \
    -f Dockerfile.boost-data \
    .

echo

# ==================================================
# Create volumes
# ==================================================

docker volume create "$BOOST_REPO_VOLUME" >/dev/null
docker volume create "$BOOST_CLIENT_VOLUME" >/dev/null
docker volume create "$BOOST_DATA_VOLUME" >/dev/null

# ==================================================
# Start Boost Data
# ==================================================

echo "Starting Boost Data..."

docker run -d \
    --name "$BOOST_DATA_CONTAINER" \
    --hostname "$BOOST_DATA_CONTAINER" \
    --network "$BOOST_NETWORK" \
    -v "$BOOST_DATA_VOLUME:/root/.boost-data" \
    "$BOOST_DATA_IMAGE" \
    run leveldb \
    --repo=/root/.boost-data \
    --addr=0.0.0.0:8042

sleep 2

if ! docker ps --format '{{.Names}}' | grep -q "^${BOOST_DATA_CONTAINER}$"; then
    echo "ERROR: Boost Data failed to start."
    docker logs "$BOOST_DATA_CONTAINER"
    exit 1
fi

echo "Boost Data: OK"
echo

# ==================================================
# Start Boost
# ==================================================

echo "Starting Boost..."

docker run -d \
    --name "$BOOST_CONTAINER" \
    --hostname "$BOOST_CONTAINER" \
    --network "$BOOST_NETWORK" \
    -p 1288:1288 \
    -p 3104:3104 \
    -p "${BOOST_LIBP2P_PORT}:${BOOST_LIBP2P_PORT}" \
    -v "$BOOST_REPO_VOLUME:/root/.boost" \
    -v "$BOOST_CLIENT_VOLUME:/root/.boost-client" \
    -v "$(pwd)/benchmark-files:/benchmark-files" \
    -v "$(pwd)/out:/out" \
    "$BOOST_IMAGE"

sleep 2

if ! docker ps --format '{{.Names}}' | grep -q "^${BOOST_CONTAINER}$"; then
    echo "ERROR: Boost failed to start."
    docker logs "$BOOST_CONTAINER"
    exit 1
fi

echo "Boost container: OK"
echo

# ==================================================
# Versions
# ==================================================

echo "Boost:"
docker exec "$BOOST_CONTAINER" boostd --version

echo

echo "Boost Data:"
docker exec "$BOOST_DATA_CONTAINER" boostd-data --version

echo

# ==================================================
# Docker DNS
# ==================================================

echo "Testing Docker DNS..."

docker exec "$BOOST_CONTAINER" \
    getent hosts "$LOTUS_CONTAINER"

docker exec "$BOOST_CONTAINER" \
    getent hosts "$BOOST_DATA_CONTAINER"

echo "Docker DNS: OK"
echo

# ==================================================
# Test APIs
# ==================================================

echo "Testing Lotus APIs..."

docker exec "$BOOST_CONTAINER" \
    bash -c "echo > /dev/tcp/$LOTUS_CONTAINER/1234"

echo "  FullNode :1234 OK"

docker exec "$BOOST_CONTAINER" \
    bash -c "echo > /dev/tcp/$LOTUS_CONTAINER/2345"

echo "  Miner :2345 OK"

docker exec "$BOOST_CONTAINER" \
    bash -c "echo > /dev/tcp/$BOOST_DATA_CONTAINER/8042"

echo "  Boost Data :8042 OK"

echo

# ==================================================
# Get Lotus API tokens
# ==================================================

echo "Getting Lotus API information..."

FULLNODE_API_INFO=$(
    docker exec "$LOTUS_CONTAINER" \
        lotus auth api-info --perm=admin |
        sed 's/^FULLNODE_API_INFO=//'
)

MINER_API_INFO=$(
    docker exec "$LOTUS_CONTAINER" \
        lotus-miner auth api-info --perm=admin |
        sed 's/^MINER_API_INFO=//'
)

if [ -z "$FULLNODE_API_INFO" ]; then
    echo "ERROR: Could not obtain FullNode API info."
    exit 1
fi

if [ -z "$MINER_API_INFO" ]; then
    echo "ERROR: Could not obtain Miner API info."
    exit 1
fi

# ==================================================
# Convert API addresses to Docker DNS
# ==================================================

FULLNODE_TOKEN="${FULLNODE_API_INFO%%:*}"
MINER_TOKEN="${MINER_API_INFO%%:*}"

FULLNODE_API_INFO="${FULLNODE_TOKEN}:/dns4/${LOTUS_CONTAINER}/tcp/1234/http"
MINER_API_INFO="${MINER_TOKEN}:/dns4/${LOTUS_CONTAINER}/tcp/2345/http"

echo "FullNode:"
echo "  /dns4/${LOTUS_CONTAINER}/tcp/1234/http"

echo "Miner:"
echo "  /dns4/${LOTUS_CONTAINER}/tcp/2345/http"

echo

# ==================================================
# Get Lotus wallet
# ==================================================

echo "Getting Lotus wallet..."

COLLAT_WALLET=$(
    docker exec "$LOTUS_CONTAINER" \
        lotus-miner actor control list --verbose |
        awk '$1 == "owner" {print $3; exit}'
)

if [ -z "$COLLAT_WALLET" ]; then
    echo "ERROR: Could not determine Lotus wallet."
    exit 1
fi

echo "Wallet:"
echo "  $COLLAT_WALLET"
echo

# ==================================================
# Initialize Boost
# ==================================================

if docker exec "$BOOST_CONTAINER" test -f /root/.boost/config.toml; then

    echo "Boost repository already initialized."

else

    echo "Initializing Boost..."

    docker exec \
        -e "FULLNODE_API_INFO=$FULLNODE_API_INFO" \
        "$BOOST_CONTAINER" \
        boostd init \
        --api-sealer="$MINER_API_INFO" \
        --api-sector-index="$MINER_API_INFO" \
        --wallet-publish-storage-deals="$COLLAT_WALLET" \
        --wallet-deal-collateral="$COLLAT_WALLET" \
        --max-staging-deals-bytes="$MAX_STAGING_DEALS_BYTES" \
        --nosync

    echo "Boost initialization completed."
fi

echo

# ==================================================
# Configure config.toml
# ==================================================

CONFIG_FILE="/root/.boost/config.toml"

echo "Configuring Boost..."

docker exec "$BOOST_CONTAINER" sed -i \
    "s|^SealerApiInfo =.*|SealerApiInfo = \"$MINER_API_INFO\"|" \
    "$CONFIG_FILE"
docker exec "$BOOST_CONTAINER" sed -i \
    "s|^SectorIndexApiInfo =.*|SectorIndexApiInfo = \"$MINER_API_INFO\"|" \
    "$CONFIG_FILE"
docker exec "$BOOST_CONTAINER" sed -i \
    's|^#ListenAddress = .*|ListenAddress = "/ip4/0.0.0.0/tcp/1288/http"|' \
    "$CONFIG_FILE"
docker exec "$BOOST_CONTAINER" sed -i \
    's|^#ServiceApiInfo = .*|ServiceApiInfo = "ws://boost-data:8042"|' \
    "$CONFIG_FILE"
docker exec "$BOOST_CONTAINER" sed -i \
    "/^\[Libp2p\]/,/^\[/ s|^[[:space:]]*#*ListenAddresses =.*|ListenAddresses = [\"/ip4/0.0.0.0/tcp/$BOOST_LIBP2P_PORT\"]|" \
    "$CONFIG_FILE"
docker exec "$BOOST_CONTAINER" sed -i \
    "/^\[Libp2p\]/,/^\[/ s|^[[:space:]]*#*AnnounceAddresses =.*|AnnounceAddresses = [\"/dns4/$BOOST_PUBLIC_HOST/tcp/$BOOST_LIBP2P_PORT\"]|" \
    "$CONFIG_FILE"

# ==================================================
# Explicit HTTP Publisher / LevelDB configuration
# ==================================================

docker exec "$BOOST_CONTAINER" sed -i \
    '/^[[:space:]]*\[IndexProvider.HttpPublisher\]/,/^[[:space:]]*\[/ s/^[[:space:]]*#*[[:space:]]*Enabled[[:space:]]*=.*/    Enabled = true/' \
    "$CONFIG_FILE"

docker exec "$BOOST_CONTAINER" sed -i \
    "/^[[:space:]]*\[IndexProvider.HttpPublisher\]/,/^[[:space:]]*\[/ s/^[[:space:]]*#*[[:space:]]*PublicHostname[[:space:]]*=.*/    PublicHostname = \"$BOOST_PUBLIC_HOST\"/" \
    "$CONFIG_FILE"

docker exec "$BOOST_CONTAINER" sed -i \
    '/^[[:space:]]*\[IndexProvider.HttpPublisher\]/,/^[[:space:]]*\[/ s/^[[:space:]]*#*[[:space:]]*Port[[:space:]]*=.*/    Port = 3104/' \
    "$CONFIG_FILE"

docker exec "$BOOST_CONTAINER" sed -i \
    '/^[[:space:]]*\[IndexProvider.HttpPublisher\]/,/^[[:space:]]*\[/ s/^[[:space:]]*#*[[:space:]]*WithLibp2p[[:space:]]*=.*/    WithLibp2p = true/' \
    "$CONFIG_FILE"

docker exec "$BOOST_CONTAINER" sed -i \
    '/^[[:space:]]*\[LocalIndexDirectory.Leveldb\]/,/^[[:space:]]*\[/ s/^[[:space:]]*#*[[:space:]]*Enabled[[:space:]]*=.*/    Enabled = true/' \
    "$CONFIG_FILE"


docker exec "$BOOST_CONTAINER" sed -i \
    '/^[[:space:]]*\[LocalIndexDirectory.Yugabyte\]/,/^[[:space:]]*\[/ s/^[[:space:]]*#*[[:space:]]*Enabled[[:space:]]*=.*/    Enabled = false/' \
    "$CONFIG_FILE"

echo "Boost configuration updated."
echo

# ==================================================
# Show important configuration
# ==================================================

echo "Important Boost configuration:"
echo

docker exec "$BOOST_CONTAINER" grep -E \
'^(SealerApiInfo|SectorIndexApiInfo)' \
"$CONFIG_FILE"

docker exec "$BOOST_CONTAINER" sed -n '/^\[API\]/,/^\[/p' "$CONFIG_FILE" | head -10

docker exec "$BOOST_CONTAINER" sed -n \
'/^\[LocalIndexDirectory\]/,/^\[Monitoring\]/p' \
"$CONFIG_FILE" | grep -E \
'^\[|ServiceApiInfo|Enabled'

echo

# ==================================================
# Start boostd
# ==================================================

echo "Starting boostd..."

docker exec -d \
    -e "FULLNODE_API_INFO=$FULLNODE_API_INFO" \
    "$BOOST_CONTAINER" \
    boostd run \
    --deprecated \
    --nosync

sleep 5

# ==================================================
# Check boostd
# ==================================================

if ! docker exec "$BOOST_CONTAINER" \
    pgrep -x boostd >/dev/null 2>&1; then

    echo "ERROR: boostd failed to start."
    docker logs --tail 200 "$BOOST_CONTAINER"
    exit 1
fi

echo "boostd: OK"
echo

# ==================================================
# Register Boost endpoint in the miner actor
# ==================================================

echo "Registering Boost multiaddr in miner actor..."

BOOST_LISTEN_MADDR=$(
    docker exec "$BOOST_CONTAINER" boostd net listen | tail -n 1
)
BOOST_PEER_ID="${BOOST_LISTEN_MADDR##*/p2p/}"

if [ -z "$BOOST_PEER_ID" ] || [ "$BOOST_PEER_ID" = "$BOOST_LISTEN_MADDR" ]; then
    echo "ERROR: Could not determine Boost PeerID."
    echo "  $BOOST_LISTEN_MADDR"
    exit 1
fi

echo "Boost PeerID: $BOOST_PEER_ID"

SET_PEER_ID_OUTPUT=$(
    docker exec "$LOTUS_CONTAINER" \
        lotus-miner actor set-peer-id "$BOOST_PEER_ID"
)

echo "$SET_PEER_ID_OUTPUT"

SET_PEER_ID_CID=$(printf '%s\n' "$SET_PEER_ID_OUTPUT" | grep -oE 'bafy[a-zA-Z0-9]+' | tail -n 1 || true)
if [ -n "$SET_PEER_ID_CID" ]; then
    docker exec "$LOTUS_CONTAINER" lotus state wait-msg "$SET_PEER_ID_CID"
fi

SET_ADDRS_OUTPUT=$(
    docker exec "$LOTUS_CONTAINER" \
        lotus-miner actor set-addrs \
        "/dns4/${BOOST_CONTAINER}/tcp/${BOOST_LIBP2P_PORT}"
)

echo "$SET_ADDRS_OUTPUT"

SET_ADDRS_CID=$(printf '%s\n' "$SET_ADDRS_OUTPUT" | grep -oE 'bafy[a-zA-Z0-9]+' | tail -n 1 || true)
if [ -n "$SET_ADDRS_CID" ]; then
    docker exec "$LOTUS_CONTAINER" lotus state wait-msg "$SET_ADDRS_CID"
fi

echo "Boost multiaddr registered: /dns4/${BOOST_CONTAINER}/tcp/${BOOST_LIBP2P_PORT}"
echo

# ==================================================
# Check ports
# ==================================================

echo "Checking Boost APIs..."

docker exec "$BOOST_CONTAINER" \
    bash -c "echo > /dev/tcp/127.0.0.1/1288"

echo "  Boost JSON RPC :1288 OK"

docker exec "$BOOST_CONTAINER" \
    bash -c "echo > /dev/tcp/127.0.0.1/3104"

echo "  HTTP Publisher :3104 OK"

docker exec "$BOOST_CONTAINER" \
    bash -c "echo > /dev/tcp/127.0.0.1/${BOOST_LIBP2P_PORT}"

echo "  Libp2p :${BOOST_LIBP2P_PORT} OK"

echo

# ==================================================
# Final
# ==================================================

echo "======================================"
echo " Boost is ready"
echo "======================================"
echo

echo "Lotus FullNode:"
echo "  ${LOTUS_CONTAINER}:1234"

docker exec "$BOOST_CONTAINER" grep -A12 '^\[Libp2p\]' "$CONFIG_FILE"
echo "Lotus Miner:"
echo "  ${LOTUS_CONTAINER}:2345"

echo "Boost API:"
echo "  boost:1288"

echo "Boost Data:"
echo "  ws://boost-data:8042"

echo "HTTP Publisher:"
echo "  boost:3104"

echo "Libp2p:"
echo "  ${BOOST_PUBLIC_HOST}:${BOOST_LIBP2P_PORT}"

echo

echo "Wallet:"
echo "  $COLLAT_WALLET"

echo

echo "Benchmark files:"
echo "  /benchmark-files"

echo