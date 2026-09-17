#! /bin/bash

echo "Start Lotus Node $(hostname)"
# Define env vars
export LOTUS_SKIP_GENESIS_CHECK=_yes_
export LOTUS_PATH=~/.lotus
export LOTUS_MINER_PATH=~/.lotusminer


rm -rf ~/.genesis-sectors
# create general directories
mkdir -p ~/.lotus
mkdir -p ~/.lotusminer
mkdir -p ~/.genesis-sectors


while ! rediscli r fil-nodes; do
  sleep 1
  echo "Waiting for fil-nodes to be set in redis"
done
nodeCount=$(rediscli r fil-nodes)

echo "Start Lotus Node $(hostname) with nodeCount ${nodeCount}"

if [ "$(hostname)" == "lotus-node-0" ]; then
    echo "Start genesis"
    for i in $(seq 0 $nodeCount)
    do
        mkdir -p /config/lotus-node-${i}/
        mkdir -p /config/lotus-node-${i}/cache
        mkdir -p /config/lotus-node-${i}/sealed
        
        # Generating bls keys for pre-sealing sectors
        mv ./bls-$(lotus-shed keyinfo new bls).keyinfo /config/lotus-node-${i}/keyPreSeal.keyinfo

        # Generating libp2p ed25519 peer key
        mv ./libp2p-host-$(lotus-shed keyinfo new libp2p-host).keyinfo /config/lotus-node-${i}/keyPeer.keyinfo
        
        # Pre-sealing sectors
        minerId=$((1000 + ${i}))
        lotus-seed pre-seal --miner-addr t0${minerId} --sector-size 8MiB --num-sectors 2 --sector-offset 0 --key /config/lotus-node-${i}/keyPreSeal.keyinfo
        
        mv /root/.genesis-sectors/pre-seal-t0${minerId}.json /config/lotus-node-${i}/
        mv /root/.genesis-sectors/cache/s-t0${minerId}-0 /config/lotus-node-${i}/cache/
        mv /root/.genesis-sectors/cache/s-t0${minerId}-1 /config/lotus-node-${i}/cache/
        mv /root/.genesis-sectors/sealed/s-t0${minerId}-0 /config/lotus-node-${i}/sealed/
        mv /root/.genesis-sectors/sealed/s-t0${minerId}-1 /config/lotus-node-${i}/sealed/
        mv /root/.genesis-sectors/sectorstore.json /config/lotus-node-${i}/
    done
    
    # Generate network configuration
    lotus-seed genesis new --network-name fil-testnet genesis.json
    echo "genesis creation done"
    
    
    # Set Network start time, to avoid catchup at start
    
    # GENESISDELAY is a time in seconds added to the current time to delay the network start by some amount of time
    GENESISDELAY=120

    GENESISTMP=$(mktemp)
    GENESISTIMESTAMP=$(date --utc +%FT%H:%M:00Z)
    TIMESTAMP=$(echo $(date -d ${GENESISTIMESTAMP} +%s) + ${GENESISDELAY} | bc)

    jq --arg Timestamp ${TIMESTAMP} ' . + { Timestamp: $Timestamp|tonumber } ' < "genesis.json" > ${GENESISTMP}
    mv ${GENESISTMP} "genesis.json"
    
    
    # Add miners to genesis 
    for i in $(seq 0 $nodeCount)
    do
        lotus-seed genesis add-miner genesis.json /config/lotus-node-${i}/pre-seal-t0$((1000 + ${i})).json
    done 
    
    # Generate genesis car file
    lotus-seed genesis car --out fil-testnet.car genesis.json
    mv fil-testnet.car /config/fil-testnet.car


    rediscli w fil-genesis-done now
    echo "Done Genesis"
fi


rediscli w "$(hostname)" ready

while ! rediscli r fil-genesis-done; do
  sleep 1
done


# Importing keys to lotus repository
mkdir -p $LOTUS_PATH/keystore && chmod 0600 $LOTUS_PATH/keystore
lotus-shed keyinfo import /config/$(hostname)/keyPreSeal.keyinfo
lotus-shed keyinfo import /config/$(hostname)/keyPeer.keyinfo

# Generate Tmux session
tmux new-session -s lotus -d

if [ "$(hostname)" == "lotus-node-0" ]; then

    for i in $(seq 0 $nodeCount)
    do
        while ! rediscli r lotus-node-${i}; do
          sleep 1
        done       
    done

    # Start Genesis Node Daemon  
    tmux new-window -t lotus:1 lotus daemon --genesis=/config/fil-testnet.car  --bootstrap=false

    # Wait till started
    lotus wait-api
    
    # Write ip to config
    lotus net listen | head -n 1 > /config/$(hostname).txt
    
    lotus-miner init --genesis-miner --actor=t01000 --sector-size=8MiB --pre-sealed-sectors=/config/lotus-node-0 --pre-sealed-metadata=/config/lotus-node-0/pre-seal-t01000.json --nosync
    
    tmux new-window -t lotus:3 lotus-miner run --nosync

    rediscli w fil-start-other-node now
    
     if [[ $(rediscli r nettopology) =~ "ring"  ]] || [[ $(rediscli r nettopology) =~ "full"  ]]; then
        until [ -f /config/lotus-node-${nodeCount}.txt ]
        do
            sleep 5
        done
        lotus net connect $(</config/lotus-node-${nodeCount}.txt)
    fi
    

else
    while ! rediscli r fil-start-other-node; do
      sleep 1
    done
    
    # Start Node Daemon  
    tmux new-window -t lotus:1 lotus daemon --genesis=/config/fil-testnet.car --bootstrap=false

    lotus wait-api 
    
    lotus net listen | head -n 1 > /config/$(hostname).txt

    sleep 15
    
    if [[ $(rediscli r nettopology) =~ "ring"  ]]; then
        until [ -f /config/lotus-node-$((-1 + $(hostname | sed -e 's/.*[^0-9]\([0-9]\+\)[^0-9]*$/\1/'))).txt ]
        do
            sleep 5
        done
        lotus net connect $(</config/lotus-node-$((-1 + $(hostname | sed -e 's/.*[^0-9]\([0-9]\+\)[^0-9]*$/\1/'))).txt)
    elif [[ $(rediscli r nettopology) =~ "full"  ]]; then
        for i in $(seq 0 $((-1 + $(hostname | sed -e 's/.*[^0-9]\([0-9]\+\)[^0-9]*$/\1/'))))
        do
            until [ -f /config/lotus-node-${i}.txt ]
            do
                sleep 5
            done
            lotus net connect $(</config/lotus-node-${i}.txt)
        done
        
    elif [[ $(rediscli r nettopology) =~ "tree"  ]]; then
        if [ "$(hostname)" == "lotus-node-1" ] || [ "$(hostname)" == "lotus-node-2" ] ; then
            until [ -f /config/lotus-node-0.txt ]
            do
                sleep 5
            done
            lotus net connect $(</config/lotus-node-0.txt)
        elif [ "$(hostname)" == "lotus-node-3" ] || [ "$(hostname)" == "lotus-node-4" ] ; then
            until [ -f /config/lotus-node-1.txt ]
            do
                sleep 5
            done
            lotus net connect $(</config/lotus-node-1.txt)
        elif [ "$(hostname)" == "lotus-node-5" ] || [ "$(hostname)" == "lotus-node-6" ] ; then
            until [ -f /config/lotus-node-2.txt ]
            do
                sleep 5
            done
            lotus net connect $(</config/lotus-node-2.txt)
        elif [ "$(hostname)" == "lotus-node-7" ] || [ "$(hostname)" == "lotus-node-8" ] ; then
            until [ -f /config/lotus-node-3.txt ]
            do
                sleep 5
            done
            lotus net connect $(</config/lotus-node-3.txt)
        elif [ "$(hostname)" == "lotus-node-9" ] || [ "$(hostname)" == "lotus-node-10" ] ; then
            until [ -f /config/lotus-node-4.txt ]
            do
                sleep 5
            done
            lotus net connect $(</config/lotus-node-4.txt)
        elif [ "$(hostname)" == "lotus-node-11" ] || [ "$(hostname)" == "lotus-node-12" ] ; then
            until [ -f /config/lotus-node-5.txt ]
            do
                sleep 5
            done
            lotus net connect $(</config/lotus-node-5.txt)
        elif [ "$(hostname)" == "lotus-node-13" ] || [ "$(hostname)" == "lotus-node-14" ] ; then
            until [ -f /config/lotus-node-6.txt ]
            do
                sleep 5
            done
            lotus net connect $(</config/lotus-node-6.txt)
        elif [ "$(hostname)" == "lotus-node-15" ] || [ "$(hostname)" == "lotus-node-16" ] ; then
            until [ -f /config/lotus-node-7.txt ]
            do
                sleep 5
            done
            lotus net connect $(</config/lotus-node-7.txt)
        fi
    else
        lotus net connect $(</config/lotus-node-0.txt) # fall back to star
    fi


    sleep 5
    lotus wait-api 
    
    lotus-miner init --actor=t0$((1000 + $(hostname | sed -e 's/.*[^0-9]\([0-9]\+\)[^0-9]*$/\1/'))) --sector-size=8MiB --pre-sealed-sectors=/config/$(hostname) --pre-sealed-metadata=/config/$(hostname)/pre-seal-t0$((1000 + $(hostname | sed -e 's/.*[^0-9]\([0-9]\+\)[^0-9]*$/\1/'))).json --nosync
    
    tmux new-window -t lotus:3 lotus-miner run --nosync
    
    #echo "Create Miner"
    #echo "Create Wallets"
    #ownerWallet=$(lotus wallet new bls)
    #workerWallet=$(lotus wallet new bls)
    #node0Ip=$(cat /config/gen.ip |sed 's/ *$//g')
    
    #echo "Transfer funds"
    #fundOwner=$(curl http://${node0Ip}?lotus%20send%20${ownerWallet}%201000)
    #fundWorker=$(curl http://${node0Ip}?lotus%20send%20${workerWallet}%201000)
    #echo "fund Owner Id:${fundOwner}"
    #echo "fund Worker Id:${fundWorker}"
    #sleep 60
    #lotus state wait-msg ${fundOwner}
    #lotus state wait-msg ${fundWorker}

    #echo "init miner"
    #lotus-miner init --sector-size=8MiB --owner=${ownerWallet}  --worker=$workerWallet --nosync
    #tmux new-window -t lotus:3 lotus-miner run --nosync
    
    #echo "Set miner actor address"
    #lotus-miner actor set-addrs /ip4/$(hostname -I)/tcp/24001
    
    #lotus-miner sectors pledge
    #lotus-miner sectors pledge
    #lotus-miner sectors seal 0
    #lotus-miner sectors seal 1
    
fi

rediscli w "$(hostname)-started" ready
#socat tcp-listen:1235,reuseaddr,fork tcp:localhost:1234 &

echo "start remote code execution"
rce > ~/rce.log 2>&1

# Port Forward localhost bound port 1234
# Run forever until exit
while :
do
	sleep 1
done