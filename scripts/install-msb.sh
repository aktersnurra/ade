#!/usr/bin/env bash
set -eo pipefail

VERSION="0.6.10"
INSTALL_ROOT="${ADE_MSB_INSTALL_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/ade/runtime/msb-$VERSION}"
ARCHIVE="${ADE_MSB_ARCHIVE:-}"
EXPECTED_SHA256="${ADE_MSB_ARCHIVE_SHA256:-a1742728676bbdfa3850e59df4b85b9df7dabcfd7e1c270876725aecdd3e992c}"
PARENT="$(dirname "$INSTALL_ROOT")"
mkdir -p "$PARENT"
STAGING="$(mktemp -d "$PARENT/.msb-$VERSION.XXXXXX")"
DOWNLOADED=""

cleanup() {
  python3 - "$STAGING" "$DOWNLOADED" <<'PY'
from pathlib import Path
import shutil, sys
for value in sys.argv[1:]:
    if not value:
        continue
    path = Path(value)
    if path.is_dir():
        shutil.rmtree(path, ignore_errors=True)
    elif path.exists():
        path.unlink()
PY
}
trap cleanup EXIT INT TERM

if [[ -z "$ARCHIVE" ]]; then
  [[ "$(uname -s)" == Darwin ]] || { echo 'official runtime installer supports Darwin only' >&2; exit 1; }
  [[ "$(uname -m)" == arm64 ]] || { echo 'official runtime installer requires Apple silicon' >&2; exit 1; }
  DOWNLOADED="$STAGING/microsandbox-darwin-aarch64.tar.gz"
  curl --fail --location --proto '=https' --tlsv1.2 \
    -o "$DOWNLOADED" \
    "https://github.com/superradcompany/microsandbox/releases/download/v$VERSION/microsandbox-darwin-aarch64.tar.gz"
  ARCHIVE="$DOWNLOADED"
fi

ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
[[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] || {
  echo "Microsandbox archive checksum mismatch: expected $EXPECTED_SHA256, got $ACTUAL_SHA256" >&2
  exit 1
}

mkdir -p "$STAGING/runtime/bin"
tar -xzf "$ARCHIVE" -C "$STAGING/runtime/bin"
chmod 0755 "$STAGING/runtime/bin/msb"
[[ "$("$STAGING/runtime/bin/msb" --version)" == "msb $VERSION" ]] || {
  echo "installed archive does not contain msb $VERSION" >&2
  exit 1
}

python3 - "$STAGING/runtime" "$INSTALL_ROOT" <<'PY'
from pathlib import Path
import os, shutil, sys
source, target = map(Path, sys.argv[1:])
if target.exists():
    shutil.rmtree(target)
os.replace(source, target)
PY

printf 'installed=%s\n' "$INSTALL_ROOT/bin/msb"
printf 'version=msb %s\n' "$VERSION"
