#!/usr/bin/env bash
# Portable C++ regression and timing check, independent of macOS/Metal.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
compiler="${CXX:-c++}"
"$compiler" -std=c++20 -O2 -Icore core/Contours.cpp tests/contours_test.cpp -o "$tmp/current"
echo "Current:" >&2
"$tmp/current" > "$tmp/current.digest"
cat "$tmp/current.digest"
if [[ $# -gt 0 ]]; then
    mkdir "$tmp/baseline"
    git show "$1:core/Contours.hpp" > "$tmp/baseline/Contours.hpp"
    git show "$1:core/Contours.cpp" > "$tmp/baseline/Contours.cpp"
    "$compiler" -std=c++20 -O2 -I"$tmp/baseline" "$tmp/baseline/Contours.cpp" \
        tests/contours_test.cpp -o "$tmp/previous"
    echo "Baseline ($1):" >&2
    "$tmp/previous" > "$tmp/previous.digest"
    diff -u "$tmp/previous.digest" "$tmp/current.digest"
    echo "Geometry and statistics digests match the baseline." >&2
fi
