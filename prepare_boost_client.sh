
#!/usr/bin/env bash
set -euo pipefail

LOTUS=lotus-node-0
BOOST=boost
CLIENT_REPO=/root/.boost-client
SOURCE_WALLET=t3qg5hw3qgebo7x3e3ycwtsvbuntebk2scqinuwimrcbm4kt6sh3fa2tjo4kojbs3zrfeddqegskkl3etu54zq
AMOUNT=100000
MARKET_AMOUNT=99900

FULLNODE_API_INFO=$(
  docker exec "$LOTUS" lotus auth api-info --perm=admin |
  sed 's/^FULLNODE_API_INFO=//'
)

TOKEN="${FULLNODE_API_INFO%%:*}"
FULLNODE_API_INFO="${TOKEN}:/dns4/lotus-node-0/tcp/1234/http"

echo "A inicializar Boost client..."

docker exec \
  -e FULLNODE_API_INFO="$FULLNODE_API_INFO" \
  "$BOOST" boost \
  --repo="$CLIENT_REPO" \
  init

CLIENT_F3=$(
  docker exec "$BOOST" boost \
    --repo="$CLIENT_REPO" \
    wallet default
)

echo "Wallet cliente Boost: $CLIENT_F3"

echo "A exportar a chave cliente..."

docker exec "$BOOST" boost \
  --repo="$CLIENT_REPO" \
  wallet export "$CLIENT_F3" > /tmp/client.key.hex

cp /tmp/client.key.hex /tmp/client.keyinfo

docker cp /tmp/client.keyinfo "$LOTUS:/tmp/client.keyinfo"

echo "A importar wallet no Lotus..."

docker exec "$LOTUS" lotus wallet import /tmp/client.keyinfo

echo
echo "Wallets Lotus:"
docker exec "$LOTUS" lotus wallet list

read -r -p "Indica o endereço t3 da wallet cliente mostrado acima: " CLIENT_T3

echo "A enviar FIL para o cliente..."

SEND_CID=$(
  docker exec "$LOTUS" lotus send \
    --from="$SOURCE_WALLET" \
    "$CLIENT_T3" \
    "$AMOUNT" |
  tail -n 1
)

echo "Mensagem: $SEND_CID"
docker exec "$LOTUS" lotus state wait-msg "$SEND_CID"

echo "A adicionar fundos ao market..."

ADD_CID=$(
  docker exec "$LOTUS" lotus wallet market add \
    --from="$CLIENT_T3" \
    --address="$CLIENT_T3" \
    "$MARKET_AMOUNT" |
  awk '/message cid:/ {print $NF}'
)

if [ -n "$ADD_CID" ]; then
  docker exec "$LOTUS" lotus state wait-msg "$ADD_CID"
fi

echo
echo "Saldo market do cliente:"
docker exec "$LOTUS" lotus state market balance "$CLIENT_T3"

rm -f /tmp/client.key.hex /tmp/client.keyinfo

echo "Cliente Boost preparado."