FROM debian:bookworm-slim

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        curl bash docker.io && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /opt/ota

COPY ota-agent.sh .
RUN chmod +x ota-agent.sh

ENTRYPOINT ["/opt/ota/ota-agent.sh"]
CMD ["daemon"]
