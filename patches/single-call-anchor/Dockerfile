# Stock xl1 producer image plus the single-call EVM anchor (xl1-docker-images#11).
# Only cli-min.mjs changes; its sourcemap is left as shipped.
#
#   docker build --build-arg BASE=xl1:5.6.2 -t xl1:5.6.2-anchor1 patches/single-call-anchor
ARG BASE=xl1:5.6.2
FROM ${BASE}
USER root
COPY patch-anchor.mjs /opt/xl1/patch-anchor.mjs
RUN node /opt/xl1/patch-anchor.mjs /usr/local/lib/node_modules/@xyo-network/xl1-cli/dist/cli-min.mjs \
  && rm /opt/xl1/patch-anchor.mjs
USER node
LABEL org.xyo.xl1-patch="single-call-anchor (xl1-docker-images#11)"
