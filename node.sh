#!/bin/bash
if ! [[ "$1" =~ ^[0-9]+$ ]]; then
 echo "Usage: '$0 0' to connect to lotus-node-0, '$0 1' to connect to lotus-node-1 and so on"
 exit 1
fi

docker exec -it lotus-node-$1 /bin/bash
