# syntax=docker/dockerfile:1
#
# Public multi-role XL1 node image with network/role presets.
#
# Preset mode (recommended for federated producer):
#   docker run --rm \
#     -e XL1_NETWORK=sequence \
#     -e XL1_ROLE=producer \          # or producer-rest
#     -e XL1_MNEMONIC='…' \
#     -e XL1_REWARD_ADDRESS=0x… \
#     xl1:local
#
# Passthrough mode (full CLI control):
#   docker run --rm --env-file api.env xl1:local start api
#
# Build (from the repository root; compile first if dist/ is missing):
#   pnpm xy compile
#   docker build -f docker/Dockerfile --build-arg XL1_CLI_VERSION=5.3.3 -t xl1:local .
#
# Or just: ./scripts/build-image.sh

ARG NODE_VERSION=24.14.1

FROM node:${NODE_VERSION}-alpine

ARG XL1_CLI_VERSION=5.3.3

LABEL org.opencontainers.image.title="XL1 Node" \
  org.opencontainers.image.description="Multi-role XYO Layer One node with network/role presets" \
  org.opencontainers.image.source="https://github.com/XYOracleNetwork/xl1-docker-images" \
  org.opencontainers.image.vendor="XYO Network" \
  org.opencontainers.image.licenses="LGPL-3.0-only"

RUN apk add --no-cache ca-certificates

RUN npm install -g "@xyo-network/xl1-cli@${XL1_CLI_VERSION}" \
  && npm cache clean --force

# Preset entrypoint + JSON profiles (network × role)
COPY presets /opt/xl1/presets
COPY dist/node /opt/xl1/lib

ENV XL1_HEALTH_CHECK_PORT=9099 \
  XL1_PRESETS_DIR=/opt/xl1/presets \
  NODE_ENV=production

RUN mkdir -p /data \
  && chown -R node:node /data /opt/xl1

WORKDIR /data
USER node

EXPOSE 8080 8081 8084 9099

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.XL1_HEALTH_CHECK_PORT||9099)+'/livez').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["node", "/opt/xl1/lib/entrypoint.mjs"]
# Empty CMD: preset mode uses XL1_NETWORK/XL1_ROLE; otherwise pass e.g. start api
CMD []
