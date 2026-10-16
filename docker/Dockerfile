# Tools image for Straßenraumkarte data preparation (osm2pgsql, osmium, psql).
# Tile rendering uses host QGIS — see render/qgis_env.sh.
FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Berlin

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    osm2pgsql \
    osmium-tool \
    postgresql-client \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /work

# Pass through commands (e.g. ./run.sh …); default to a shell for interactive use.
ENTRYPOINT []
CMD ["bash"]
