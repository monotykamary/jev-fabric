#!/bin/sh
set -eu
# CI-only, project-owned installation. Never alters ~/.bend or shell profiles.
# Archive hashes are from https://bend-lang.com/install.sh for Bend 2.0.27.
[ "${CI:-}" = true ] || { echo 'This setup script is CI-only.' >&2; exit 1; }
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform=darwin-arm64; sum=de1f0a8b8db18c336edfb9385234b34f7da60fa4c79a4261e3be4a9674a2ffd7 ;;
  Darwin-x86_64) platform=darwin-x64; sum=fcde1f2a17939b1cbef1369a32c13ffdb7cef53a8355e9cf3887b119c79fa17a ;;
  Linux-aarch64) platform=linux-arm64; sum=2535c11bf554639cd90e634248915c597a06f40753ce28dea5fc71f7a6cf9703 ;;
  Linux-x86_64) platform=linux-x64; sum=58adc86af6605ed0c48f7d84e4c23028f78893ce4a867a20a4f004b11582687b ;;
  *) echo 'Unsupported native CI platform.' >&2; exit 1 ;;
esac
root="${RUNNER_TEMP:?}/jev-bend-2.0.27"
mkdir -p "$root"
archive="$root/compiler.tar.gz"
trap 'rm -f "$archive"' EXIT
release='https://github.com/bendlang/bend/releases/download/v2.0.27'
curl --proto '=https' --tlsv1.2 -fsSL "$release/bend-2.0.27-$platform.tar.gz" -o "$archive"
if command -v sha256sum >/dev/null 2>&1; then
  printf '%s  %s\n' "$sum" "$archive" | sha256sum -c -
else
  printf '%s  %s\n' "$sum" "$archive" | shasum -a 256 -c -
fi
tar -xzf "$archive" -C "$root"
case "$platform" in
  darwin-*)
    codesign --verify --strict "$root/bend/bin/bend" || {
      echo 'Upstream compiler signature is invalid.' \
        'Use a trusted local build; do not bypass macOS signature checks.' >&2
      exit 1
    }
    ;;
esac
printf '%s\n' "$root/bend/bin" >> "${GITHUB_PATH:?}"
