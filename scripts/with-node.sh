#!/usr/bin/env bash
set -euo pipefail

if command -v node >/dev/null 2>&1 &&
   node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)'; then
  exec node "$@"
fi

if [[ "$(uname -s)" != Darwin ]]; then
  echo "ERROR: Install Node.js 22 or newer; the CI bootstrap supports macOS only." >&2
  exit 1
fi

version="22.23.2"
case "$(uname -m)" in
  arm64)
    architecture="arm64"
    checksum="61130f394c1630d211dd50aecc4353d379480f36d3ac913cd85dbba1aed585c6"
    ;;
  x86_64)
    architecture="x64"
    checksum="58e99022c2ff89395576cc7fd4d98cea24bb68081475d5f88b801ee8729fb026"
    ;;
  *)
    echo "ERROR: Unsupported macOS architecture for the Node.js CI bootstrap." >&2
    exit 1
    ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$root/build"
work_dir="$(mktemp -d "$root/build/node-runtime.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT
package="node-v$version-darwin-$architecture"
archive="$work_dir/$package.tar.gz"
echo "Fetching checksum-pinned Node.js $version into this job's temporary workspace."
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  --retry 2 --max-time 120 "https://nodejs.org/dist/v$version/$package.tar.gz" -o "$archive"
printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c -
tar -xzf "$archive" -C "$work_dir"
"$work_dir/$package/bin/node" "$@"
