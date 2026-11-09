# syntax=docker/dockerfile:1
FROM node:24.11.1-bookworm-slim@sha256:48abc13a19400ca3985071e287bd405a1d99306770eb81d61202fb6b65cf0b57 AS node
FROM rocker/r-ver:4.2.3@sha256:6dff804fb051f7c38cf9ebcaf307b5102b46e5187ffe2ce921d760a26facd693 AS dependencies
ENV DEBIAN_FRONTEND=noninteractive MAKEFLAGS=-j1 \
    R_LIBS=/opt/validation/R-library DATABASECONNECTOR_JAR_FOLDER=/opt/validation/jdbc \
    PATH=/opt/pgsql/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
RUN apt-get update && apt-get install -y --no-install-recommends \
    bison build-essential ca-certificates curl flex libbz2-dev libcurl4-openssl-dev \
    libicu-dev liblzma-dev libpcre2-dev libssl-dev libtirpc-dev openjdk-11-jdk-headless \
    procps python3 zlib1g-dev && rm -rf /var/lib/apt/lists/* \
    && ln -s "$(dirname "$(dirname "$(readlink -f /usr/bin/javac)")")" /opt/java \
    && R CMD javareconf
ENV JAVA_HOME=/opt/java
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
COPY tools/docker/runtime-lock.json tools/docker/fetch.py /opt/validation/
RUN python3 /opt/validation/fetch.py \
    && mkdir -p /tmp/pg-build && tar -xjf /opt/validation/downloads/postgresql.tar.bz2 -C /tmp/pg-build --strip-components=1 \
    && cd /tmp/pg-build && ./configure --prefix=/opt/pgsql --without-readline --without-icu --with-openssl \
    && make -C src/interfaces/libpq install && make -C src/bin/psql install \
    && cd / && rm -rf /tmp/pg-build
COPY tools/docker/install.R /opt/validation/
RUN Rscript --vanilla /opt/validation/install.R \
    && dpkg-query -W > /opt/validation/system-packages.txt \
    && rm -rf /opt/validation/downloads

# Source edits reuse all compiled R/JNI/JDBC/client and npm dependency layers.
FROM dependencies AS validation
WORKDIR /workspace/source
COPY packages/contracts/package.json packages/contracts/package-lock.json ./packages/contracts/
COPY packages/tracer/package.json packages/tracer/package-lock.json ./packages/tracer/
RUN npm ci --prefix packages/contracts --ignore-scripts --no-audit --no-fund \
    && npm ci --prefix packages/tracer --ignore-scripts --no-audit --no-fund
ARG VALIDATION_UID=1000
ARG VALIDATION_GID=1000
COPY --chown=${VALIDATION_UID}:${VALIDATION_GID} . .
RUN R CMD INSTALL --library="$R_LIBS" . \
    && mkdir -p packages/tracer/node_modules/.vite packages/tracer/node_modules/.vitest-cache packages/tracer/node_modules/.vite-temp \
    && chown -R "$VALIDATION_UID:$VALIDATION_GID" packages/tracer/node_modules/.vite packages/tracer/node_modules/.vitest-cache packages/tracer/node_modules/.vite-temp \
    && python3 tools/docker/runner.py build-manifest
ENV HOME=/validation/state/home ACHILLES_NEXT_FIXTURE_STATE=/validation/state/postgresql
USER ${VALIDATION_UID}:${VALIDATION_GID}
ENTRYPOINT ["python3", "tools/docker/runner.py"]
CMD ["smoke"]
