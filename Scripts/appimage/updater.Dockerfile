# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

FROM debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3
ENV DEBIAN_FRONTEND=noninteractive
RUN sed -i 's/Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources \
 && apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends ca-certificates git cmake ninja-build g++ pkg-config argagg-dev libgpgme-dev libgcrypt20-dev libarchive-dev libssl-dev libcurl4-openssl-dev libglib2.0-dev libboost-dev libfuse-dev zlib1g-dev liblzma-dev libzstd-dev libcairo2-dev librsvg2-dev libtool autoconf automake patchelf python3 dpkg-dev xz-utils
