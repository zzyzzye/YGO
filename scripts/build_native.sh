#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find "$repo_root/native" "$repo_root/build/native" -type f -name '._*' -delete 2>/dev/null || true
cmake -S "$repo_root/native" -B "$repo_root/build/native" -DCMAKE_BUILD_TYPE=Debug
cmake --build "$repo_root/build/native" -j4
ctest --test-dir "$repo_root/build/native" --output-on-failure
