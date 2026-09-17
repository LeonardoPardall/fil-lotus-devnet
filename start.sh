#! /bin/bash

# Number of nodes
if [[ $1 =~ ^[0-9]+$ ]]; then
    SCALE="$1"
else
    SCALE=3
fi

echo "Scale is $SCALE"

# Network topology
if [[ $2 =~ "ring" ]] || [[ $2 =~ "full" ]] || [[ $2 =~ "tree" ]]; then
    TOPOLOGY="$2"
else
    TOPOLOGY="star"
fi

./generate_compose.sh "$SCALE"  


# Start network
docker compose -f docker-compose.generated.yml up -d

echo "Waiting for Redis..."

until docker exec lotus-redis redis-cli ping >/dev/null 2>&1
do
    sleep 1
done


export LOTUS_REDIS_ADDR=localhost:6379
echo "$LOTUS_REDIS_ADDR"
# Configure Redis
./redis-cli/rediscli w nettopology "$TOPOLOGY"
./redis-cli/rediscli w fil-nodes "$(($SCALE-1))"

if [[ "$3" == "true" ]]; then
    ./redis-cli/rediscli w SingleBlock true
fi

echo "Waiting for Lotus nodes..."

for i in $(seq 0 $(($SCALE-1)))
do
    while ! ./redis-cli/rediscli r lotus-node-${i}-started >/dev/null
    do
        sleep 1
    done
done

echo "All nodes ready."