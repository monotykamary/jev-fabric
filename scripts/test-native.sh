#!/bin/sh
set -eu
export BEND_NO_TELEMETRY=1
cd "$(dirname "$0")/.."
sh scripts/build-native.sh
bend native/tests/proofs.bend --check-only
bend native/tests/core.bend -o build/test-core
bend native/tests/io.bend -o build/test-io
bend native/tests/fail-fast.bend -o build/test-fail-fast
build/test-core
bun test native/tests/process.test.ts
