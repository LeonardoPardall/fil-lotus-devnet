#!/bin/bash
    

echo "Start Lotus Node $(hostname)"

# --------------------------------------------------
# Environment
# --------------------------------------------------

export LOTUS_SKIP_GENESIS_CHECK=_yes_
export LOTUS_PATH=~/.lotus
export LOTUS_MINER_PATH=~/.lotusminer
export LOTUS_API_LISTENADDRESS="/ip4/0.0.0.0/tcp/1234/http"
export LOTUS_MINER_API_LISTENADDRESS="/ip4/0.0.0.0/tcp/2345/http"




mkdir -p ~/.lotus
mkdir -p ~/.lotusminer
if [ ! -f ~/.lotus/config.toml ]; then
    echo "Creating Lotus FullNode config"
    lotus config default > ~/.lotus/config.toml
fi
lotus config API.ListenAddress /ip4/0.0.0.0/tcp/1234/http
lotus-miner config API.ListenAddress /ip4/0.0.0.0/tcp/2345/http


# --------------------------------------------------
# Wait for node count
# --------------------------------------------------

while ! rediscli r fil-nodes; do
    sleep 1
    echo "Waiting for fil-nodes to be set in redis"
done

nodeCount=$(rediscli r fil-nodes)

echo "Start Lotus Node $(hostname) with nodeCount ${nodeCount}"


# ==================================================
# NODE 0 - GENESIS CREATION
# ==================================================

if [ "$(hostname)" == "lotus-node-0" ]; then

    rm -rf ~/.genesis-sectors
    mkdir -p ~/.genesis-sectors


    echo "Start genesis"


    # --------------------------------------------------
    # Generate pre-sealed sectors for every miner
    # --------------------------------------------------

    for i in $(seq 0 $nodeCount)
    do
        rm -rf /config/lotus-node-${i}
        mkdir -p /config/lotus-node-${i}/
        mkdir -p /config/lotus-node-${i}/cache
        mkdir -p /config/lotus-node-${i}/sealed

        echo "Generating keys for lotus-node-${i}"

        # BLS key for pre-sealed sectors
        mv ./bls-$(lotus-shed keyinfo new bls).keyinfo \
            /config/lotus-node-${i}/keyPreSeal.keyinfo

        # libp2p peer key
        mv ./libp2p-host-$(lotus-shed keyinfo new libp2p-host).keyinfo \
            /config/lotus-node-${i}/keyPeer.keyinfo


        # --------------------------------------------------
        # Pre-seal sectors
        # --------------------------------------------------

        minerId=$((1000 + ${i}))

        echo "Pre-sealing miner t0${minerId}"

        lotus-seed pre-seal \
            --miner-addr t0${minerId} \
            --sector-size 8MiB \
            --num-sectors 2 \
            --sector-offset 0 \
            --key /config/lotus-node-${i}/keyPreSeal.keyinfo


        # --------------------------------------------------
        # Move pre-seal data
        # --------------------------------------------------

        mv /root/.genesis-sectors/pre-seal-t0${minerId}.json \
            /config/lotus-node-${i}/

        mv /root/.genesis-sectors/cache/s-t0${minerId}-0 \
            /config/lotus-node-${i}/cache/

        mv /root/.genesis-sectors/cache/s-t0${minerId}-1 \
            /config/lotus-node-${i}/cache/

        mv /root/.genesis-sectors/sealed/s-t0${minerId}-0 \
            /config/lotus-node-${i}/sealed/

        mv /root/.genesis-sectors/sealed/s-t0${minerId}-1 \
            /config/lotus-node-${i}/sealed/

        mv /root/.genesis-sectors/sectorstore.json \
            /config/lotus-node-${i}/
    done


    # ==================================================
    # CREATE GENESIS TEMPLATE
    # ==================================================

    echo "Creating genesis template"

    lotus-seed genesis new \
        --network-name fil-testnet \
        genesis.json

    echo "Genesis template created"


    # --------------------------------------------------
    # Set network start time
    # --------------------------------------------------

    # Delay genesis by 120 seconds so nodes do not
    # immediately start trying to catch up.

    GENESISDELAY=120

    GENESISTMP=$(mktemp)

    GENESISTIMESTAMP=$(date --utc +%FT%H:%M:00Z)

    TIMESTAMP=$(echo \
        $(date -d ${GENESISTIMESTAMP} +%s) \
        + ${GENESISDELAY} | bc)

    jq --arg Timestamp "${TIMESTAMP}" \
        '. + { Timestamp: $Timestamp|tonumber }' \
        < genesis.json \
        > ${GENESISTMP}

    mv ${GENESISTMP} genesis.json

    echo "Genesis timestamp set to ${TIMESTAMP}"


    # ==================================================
    # ADD MINERS TO GENESIS
    # ==================================================

    echo "Adding miners to genesis"

    for i in $(seq 0 $nodeCount)
    do
        minerId=$((1000 + ${i}))

        echo "Adding miner t0${minerId}"

        lotus-seed genesis add-miner \
            genesis.json \
            /config/lotus-node-${i}/pre-seal-t0${minerId}.json
    done

    echo "All miners added"


    # ==================================================
    # GENERATE GENESIS CAR
    # ==================================================

    echo "Generating genesis CAR"

    lotus-seed genesis car \
        --out fil-testnet.car \
        genesis.json

    mv fil-testnet.car /config/fil-testnet.car

    echo "Genesis CAR created"


    # --------------------------------------------------
    # Signal that genesis is ready
    # --------------------------------------------------

    rediscli w fil-genesis-done now

    echo "Done Genesis"

fi


# ==================================================
# Signal that this node is ready
# ==================================================

rediscli w "$(hostname)" ready


# ==================================================
# Wait for genesis
# ==================================================

while ! rediscli r fil-genesis-done; do
    sleep 1
done


# ==================================================
# Import keys
# ==================================================

mkdir -p $LOTUS_PATH/keystore
chmod 0600 $LOTUS_PATH/keystore

lotus wallet import \
    /config/$(hostname)/keyPreSeal.keyinfo

PRESEAL_ADDR=$(lotus-shed key-info info \
    /config/$(hostname)/keyPreSeal.keyinfo | awk '{print $2}')

lotus wallet set-default "$PRESEAL_ADDR"

lotus-shed keyinfo import \
    /config/$(hostname)/keyPreSeal.keyinfo

lotus-shed keyinfo import \
    /config/$(hostname)/keyPeer.keyinfo


# ==================================================
# Create tmux session
# ==================================================

tmux new-session -s lotus -d


# ==================================================
# NODE 0
# ==================================================

if [ "$(hostname)" == "lotus-node-0" ]; then

    # --------------------------------------------------
    # Wait for every node
    # --------------------------------------------------

    for i in $(seq 0 $nodeCount)
    do
        while ! rediscli r lotus-node-${i}; do
            sleep 1
        done
    done


    # --------------------------------------------------
    # Start genesis node daemon
    # --------------------------------------------------

    tmux new-window -t lotus:1 \
        lotus daemon \
        --genesis=/config/fil-testnet.car \
        --bootstrap=false


    # --------------------------------------------------
    # Wait for API
    # --------------------------------------------------

    lotus wait-api


    # --------------------------------------------------
    # Save libp2p address
    # --------------------------------------------------

    lotus net listen | grep -E '^/ip4/172\.[0-9]+\.[0-9]+\.[0-9]+/tcp/' | head -n 1 \
    > /config/$(hostname).txt


    # ==================================================
    # INITIALIZE GENESIS MINER
    # ==================================================

    lotus-miner init \
        --genesis-miner \
        --actor=t01000 \
        --sector-size=8MiB \
        --pre-sealed-sectors=/config/lotus-node-0 \
        --pre-sealed-metadata=/config/lotus-node-0/pre-seal-t01000.json \
        --nosync

    lotus-miner config Subsystems.EnableMarkets true

    # --------------------------------------------------
    # Start miner
    # --------------------------------------------------

    tmux new-window -t lotus:3 \
        lotus-miner run \
        --nosync


    # --------------------------------------------------
    # Tell other nodes to start
    # --------------------------------------------------

    rediscli w fil-start-other-node now


    # --------------------------------------------------
    # Ring / full topology
    # --------------------------------------------------

    if [[ $(rediscli r nettopology) =~ "ring" ]] || \
       [[ $(rediscli r nettopology) =~ "full" ]]; then

        until [ -f /config/lotus-node-${nodeCount}.txt ]
        do
            sleep 5
        done

        lotus net connect \
            $(</config/lotus-node-${nodeCount}.txt)
    fi


# ==================================================
# OTHER NODES
# ==================================================

else

    # --------------------------------------------------
    # Wait for node 0
    # --------------------------------------------------

    while ! rediscli r fil-start-other-node; do
        sleep 1
    done


    # --------------------------------------------------
    # Start daemon
    # --------------------------------------------------

    tmux new-window -t lotus:1 \
        lotus daemon \
        --genesis=/config/fil-testnet.car \
        --bootstrap=false


    lotus wait-api


    # --------------------------------------------------
    # Save libp2p address
    # --------------------------------------------------

    lotus net listen | head -n 1 \
        > /config/$(hostname).txt


    sleep 15


    # --------------------------------------------------
    # Network topology
    # --------------------------------------------------

    NODE_ID=$(hostname | sed -e 's/.*[^0-9]\([0-9]\+\)[^0-9]*$/\1/')

    if [[ $(rediscli r nettopology) =~ "ring" ]]; then

        PREV_NODE=$((-1 + NODE_ID))

        until [ -f /config/lotus-node-${PREV_NODE}.txt ]
        do
            sleep 5
        done

        lotus net connect \
            $(</config/lotus-node-${PREV_NODE}.txt)


    elif [[ $(rediscli r nettopology) =~ "full" ]]; then

        for i in $(seq 0 $((-1 + NODE_ID)))
        do
            until [ -f /config/lotus-node-${i}.txt ]
            do
                sleep 5
            done

            lotus net connect \
                $(</config/lotus-node-${i}.txt)
        done


    elif [[ $(rediscli r nettopology) =~ "tree" ]]; then

        if [ "$(hostname)" == "lotus-node-1" ] || \
           [ "$(hostname)" == "lotus-node-2" ]; then

            until [ -f /config/lotus-node-0.txt ]
            do
                sleep 5
            done

            lotus net connect \
                $(</config/lotus-node-0.txt)


        elif [ "$(hostname)" == "lotus-node-3" ] || \
             [ "$(hostname)" == "lotus-node-4" ]; then

            until [ -f /config/lotus-node-1.txt ]
            do
                sleep 5
            done

            lotus net connect \
                $(</config/lotus-node-1.txt)


        elif [ "$(hostname)" == "lotus-node-5" ] || \
             [ "$(hostname)" == "lotus-node-6" ]; then

            until [ -f /config/lotus-node-2.txt ]
            do
                sleep 5
            done

            lotus net connect \
                $(</config/lotus-node-2.txt)


        elif [ "$(hostname)" == "lotus-node-7" ] || \
             [ "$(hostname)" == "lotus-node-8" ]; then

            until [ -f /config/lotus-node-3.txt ]
            do
                sleep 5
            done

            lotus net connect \
                $(</config/lotus-node-3.txt)


        elif [ "$(hostname)" == "lotus-node-9" ] || \
             [ "$(hostname)" == "lotus-node-10" ]; then

            until [ -f /config/lotus-node-4.txt ]
            do
                sleep 5
            done

            lotus net connect \
                $(</config/lotus-node-4.txt)


        elif [ "$(hostname)" == "lotus-node-11" ] || \
             [ "$(hostname)" == "lotus-node-12" ]; then

            until [ -f /config/lotus-node-5.txt ]
            do
                sleep 5
            done

            lotus net connect \
                $(</config/lotus-node-5.txt)


        elif [ "$(hostname)" == "lotus-node-13" ] || \
             [ "$(hostname)" == "lotus-node-14" ]; then

            until [ -f /config/lotus-node-6.txt ]
            do
                sleep 5
            done

            lotus net connect \
                $(</config/lotus-node-6.txt)


        elif [ "$(hostname)" == "lotus-node-15" ] || \
             [ "$(hostname)" == "lotus-node-16" ]; then

            until [ -f /config/lotus-node-7.txt ]
            do
                sleep 5
            done

            lotus net connect \
                $(</config/lotus-node-7.txt)
        fi


    else

        # Fallback to star topology

        lotus net connect \
            $(</config/lotus-node-0.txt)

    fi


    sleep 5

    lotus wait-api


    # ==================================================
    # INITIALIZE MINER
    # ==================================================

    MINER_ID=$((1000 + NODE_ID))

    lotus-miner init \
        --actor=t0${MINER_ID} \
        --sector-size=8MiB \
        --pre-sealed-sectors=/config/$(hostname) \
        --pre-sealed-metadata=/config/$(hostname)/pre-seal-t0${MINER_ID}.json \
        --nosync
    
    lotus-miner config Subsystems.EnableMarkets true


    # --------------------------------------------------
    # Start miner
    # --------------------------------------------------

    tmux new-window -t lotus:3 \
        lotus-miner run \
        --nosync

fi


# ==================================================
# Node started
# ==================================================

rediscli w "$(hostname)-started" ready


# ==================================================
# Remote code execution
# ==================================================

echo "start remote code execution"

rce > ~/rce.log 2>&1


# ==================================================
# Keep container alive
# ==================================================

while :
do
    sleep 1
done