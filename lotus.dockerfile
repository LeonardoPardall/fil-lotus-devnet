# Create builder container
FROM golang:1.25.7 AS builder
# set BRANCH_FIL or COMMIT_HASH_FIL

ARG NODEPATH=/lotus
ENV DEBIAN_FRONTEND=noninteractive

# Clone Lotus



WORKDIR /
COPY lotus ${NODEPATH}
WORKDIR ${NODEPATH}



# Install Lotus deps
RUN apt-get update && \
    apt-get install -yy \
        apt-utils \
        gcc \
        git \
        bzr \
        jq \
        pkg-config \
        mesa-opencl-icd \
        ocl-icd-opencl-dev \
        hwloc \
        libhwloc-dev    
RUN make 2k
RUN /lotus/lotus config default | grep ListenAddress

RUN go build -o /lotus/lotus-bench ./cmd/lotus-bench
RUN go build -o /lotus/lotus-gateway ./cmd/lotus-gateway
RUN go build -o /lotus/lotus-wallet ./cmd/lotus-wallet



# Create final container
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
ARG LOTUS_API_PORT=1234


# Install Lotus deps
RUN apt-get update && \
    apt-get install -yy apt-utils socat curl && \
    apt-get install -yy bzr jq pkg-config mesa-opencl-icd ocl-icd-opencl-dev wget libltdl7 libnuma1 hwloc libhwloc-dev tmux nano less iputils-ping python3 iproute2 bc

# Install all lotus bins
COPY --from=builder /lotus/lotus /usr/local/bin/
COPY --from=builder /lotus/lotus-miner /usr/local/bin/
COPY --from=builder /lotus/lotus-seed /usr/local/bin/
COPY --from=builder /lotus/lotus-gateway /usr/local/bin/
COPY --from=builder /lotus/lotus-shed /usr/local/bin/
COPY --from=builder /lotus/lotus-wallet /usr/local/bin/
COPY --from=builder /lotus/lotus-worker /usr/local/bin/
COPY --from=builder /lotus/lotus-bench /usr/local/bin/



RUN lotus-shed fetch-params --proving-params 0
RUN lotus-shed fetch-params --proving-params 8MiB


# Copy RCE and rediscli
COPY rce/rce /usr/local/bin/
COPY redis-cli/rediscli /usr/local/bin

ENV LOTUS_REDIS_ADDR lotus-redis:6379

# Copy start script
COPY start_lotus.sh /start_lotus.sh

ENTRYPOINT ["/start_lotus.sh"]