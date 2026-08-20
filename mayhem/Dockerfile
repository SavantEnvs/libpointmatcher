# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile for libpointmatcher — builds ON TOP of the org C/C++ base
# (ghcr.io/savantenvs/base). The base provides debian + clang/llvm + libFuzzer/ASan/UBSan +
# the build contract ENV; this adds libpointmatcher's apt deps and runs the per-commit build.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) -t libpointmatcher-commit:test .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# libpointmatcher's system deps: Eigen3 (headers), Boost (thread/system/program_options/date_time/
# chrono), yaml-cpp. libnabo is NOT packaged — it is fetched and built below (network available
# during docker build), so build.sh needs no network (§6.5).
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
      libeigen3-dev \
      libboost-thread-dev libboost-system-dev libboost-program-options-dev \
      libboost-date-time-dev libboost-chrono-dev \
      libyaml-cpp-dev \
 && rm -rf /var/lib/apt/lists/*

# libnabo 1.1.2 (libpointmatcher's kd-tree dep, not packaged): fetch AND build it here, once, into
# /opt/toolchains/libnabo. It is third-party code outside the repo tree, so no patch can change it,
# and it is not on the fuzzed path (no libnabo object is linked into fuzz_lib). Building it in the
# image instead of in build.sh takes it off every graded rebuild. Only the project's own sources are
# rebuilt by build.sh.
RUN git clone --depth 1 --branch 1.1.2 https://github.com/norlab-ulaval/libnabo.git /opt/libnabo-src \
 && cmake -S /opt/libnabo-src -B /tmp/libnabo-build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/opt/toolchains/libnabo \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DLIBNABO_BUILD_EXAMPLES=OFF -DLIBNABO_BUILD_TESTS=OFF -DLIBNABO_BUILD_PYTHON=OFF \
 && cmake --build /tmp/libnabo-build -j"${MAYHEM_JOBS:-$(nproc)}" \
 && cmake --install /tmp/libnabo-build \
 && rm -rf /tmp/libnabo-build \
 && chmod -R a+rX /opt/libnabo-src /opt/toolchains/libnabo

USER mayhem

WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run the gtest suite at build time — a failing suite fails the image build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
