#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq --no-install-recommends nlohmann-json3-dev
git config --global --add safe.directory /work/source
architecture=$(uname -m)
cmake -S source -B "build-$architecture" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DBUILD_QT_UI=OFF -DLIBAPPIMAGE_SHARED_ONLY=ON -DCPR_FORCE_USE_SYSTEM_CURL=OFF -DCMAKE_INSTALL_PREFIX=/usr
cmake --build "build-$architecture" --parallel 4 --target appimageupdatetool
DESTDIR="/work/stage-$architecture" cmake --install "build-$architecture" --component APPIMAGEUPDATETOOL
# The shared updater and zsync libraries are copied from the build for staging;
# the final bundle collects precisely the executable's dynamic dependencies.
mkdir -p "stage-$architecture/usr/lib"
find "build-$architecture" -name '*.so*' -type f -exec cp -t "stage-$architecture/usr/lib" {} +
export LD_LIBRARY_PATH="/work/stage-$architecture/usr/lib"
python3 collect-helper.py "$architecture"
