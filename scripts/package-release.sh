#!/bin/sh
# Package a built executable into dist/jev-fabric-<platform>.tar.gz.
#
#   sh scripts/package-release.sh <platform> <path-to-binary>
#
# The archive holds one top-level jev-fabric/ directory: the executable, the Bend
# library (for `jev-fabric -- run` programs), the Python and TypeScript `serve`
# clients, examples, the agent skill and docs.
set -eu

[ $# -eq 2 ] || { echo 'usage: package-release.sh <platform> <binary>' >&2; exit 2; }
platform=$1
binary=$2
cd "$(dirname "$0")/.."

version=$("$binary" -- --version | sed 's/-native.*//')
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "unexpected version output: $version" >&2; exit 1 ;;
esac

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
root="$stage/jev-fabric"
mkdir -p "$root/bin" "$root/native" "$root/examples"

cp "$binary" "$root/bin/jev-fabric"
chmod 755 "$root/bin/jev-fabric"
# Library modules and their C effects; tests and probes stay in the repository.
cp native/*.bend native/*.c native/trust.json "$root/native/"
cp -R native/vendor "$root/native/vendor"
cp -R examples/native examples/doom examples/clients "$root/examples/"
# Clients ship without their tests.
mkdir -p "$root/clients/python" "$root/clients/typescript"
cp clients/python/jev_fabric.py "$root/clients/python/"
cp clients/typescript/jev-fabric.ts "$root/clients/typescript/"
cp clients/README.md "$root/clients/"
cp -R skills "$root/skills"
cp README.md LICENSE "$root/"
printf 'v%s\n' "$version" > "$root/VERSION"

mkdir -p dist
tar -czf "dist/jev-fabric-$platform.tar.gz" -C "$stage" jev-fabric
echo "dist/jev-fabric-$platform.tar.gz (v$version)"
