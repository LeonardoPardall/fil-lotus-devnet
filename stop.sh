#!/bin/sh
###################################################################################
#                                                                                 #
#  Lotus Devnet Stop Script (Docker Compose)                                      #
#                                                                                 #
###################################################################################

set -e

echo "Stopping containers..."
docker compose -f docker-compose.generated.yml down

echo "Removing generated compose file..."
rm -f docker-compose.generated.yml


## remove volume 
echo "Removing volumes..."
docker volume rm fil-lotus-devnet_lotus-config




echo "Done."