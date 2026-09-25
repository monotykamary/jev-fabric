#!/bin/sh
set -eu
export BEND_NO_TELEMETRY=1
cd "$(dirname "$0")/.."
sh scripts/build-native.sh
bend examples/native/judge.bend --check-only
bend examples/native/persistent.bend --check-only
# Build outside Bun's test hooks, with process-group deadlines and phase evidence.
for name in core io fail-fast jobs jobs-streams codec codec-limits wire codec-wire-probe http jev-client session monitor monitor-pure policy-core; do
  printf '\nBuilding native fixture: %s\n' "$name"
  build/jev-fabric -- exec 90000 bend "native/tests/$name.bend" -o "build/test-$name"
done
build/test-core
build/test-jobs-streams
export JEV_NATIVE_PREBUILT=1
bun test --timeout 30000 native/tests/*.test.ts
