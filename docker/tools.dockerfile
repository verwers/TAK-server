# tools.dockerfile
# Lightweight utility image for running TAK Server scripts
# Used by run-in-docker.sh and run-in-docker.ps1

FROM alpine:3.18

LABEL maintainer="TAK Server Project"
LABEL description="Lightweight tools image for TAK Server deployment scripts"

# Install required tools
RUN apk add --no-cache \
    bash \
    curl \
    docker-cli \
    grep \
    jq \
    netcat-openbsd \
    openssl \
    sed \
    zip \
    postgresql-client

# Set bash as default shell
SHELL ["/bin/bash", "-c"]

# Create workspace directory
WORKDIR /workspace

# Default command
CMD ["/bin/bash"]
