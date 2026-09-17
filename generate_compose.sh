#!/bin/bash

set -e

SCALE=$1
OUTPUT=docker-compose.generated.yml

cat > $OUTPUT <<EOF
version: "3.9"

services:

  redis:
    image: redis:6-alpine
    container_name: lotus-redis
    hostname: lotus-redis
    ports:
      - "6379:6379"
    networks:
      - lotus


EOF

for ((i=0;i<SCALE;i++)); do
cat >> $OUTPUT <<EOF

  lotus-node-$i:
    image: lotus-node
    container_name: lotus-node-$i
    hostname: lotus-node-$i
    depends_on:
      - redis
    environment:
      LOTUS_REDIS_ADDR: lotus-redis:6379
      NODE_ID: $i
    volumes:
      - lotus-config:/config
      - ./benchmark-files:/benchmark-files
      - ./out:/out
    ports:
      - "$((3000+i)):1234"
    networks:
      - lotus

EOF
done

cat >> $OUTPUT <<EOF



volumes:
  lotus-config:

networks:
  lotus:
EOF