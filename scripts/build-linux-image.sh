#!/usr/bin/env bash
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ARTIFACT_DIR="${ADE_ARTIFACT_DIR:-$REPO_ROOT/artifacts}"
BUILDER_IMAGE="${ADE_NIX_BUILDER_IMAGE:-nixos/nix@sha256:a326ac1ed46069ead5cdcba3a3a1e7255ebf72300c8319bf2c12cacfe9ab2787}"
BUILDER_NAME="ade-nix-image-builder-$$"
QUAL_ROOT="$(mktemp -d /private/tmp/ade-image-builder.XXXXXX)"
MSB_BIN="$QUAL_ROOT/bin/msb"
export MSB_HOME="$QUAL_ROOT/msb-home"
export DYLD_LIBRARY_PATH="$QUAL_ROOT/bin"

cleanup() {
  if [[ -x "$MSB_BIN" ]]; then
    "$MSB_BIN" stop "$BUILDER_NAME" >/dev/null 2>&1 || true
    "$MSB_BIN" remove "$BUILDER_NAME" >/dev/null 2>&1 || true
  fi
  python3 - "$QUAL_ROOT" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1], ignore_errors=True)
PY
}
trap cleanup EXIT INT TERM

[[ "$(uname -s)" == Darwin ]] || { echo 'this builder is for Darwin hosts' >&2; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo 'this builder requires Apple silicon' >&2; exit 1; }
mkdir -p "$QUAL_ROOT/bin" "$QUAL_ROOT/download" "$ARTIFACT_DIR"

archive="$QUAL_ROOT/download/microsandbox-darwin-aarch64.tar.gz"
curl --fail --location --proto '=https' --tlsv1.2 \
  -o "$archive" \
  https://github.com/superradcompany/microsandbox/releases/download/v0.6.10/microsandbox-darwin-aarch64.tar.gz
printf '%s  %s\n' \
  a1742728676bbdfa3850e59df4b85b9df7dabcfd7e1c270876725aecdd3e992c \
  "$archive" | shasum -a 256 -c -
tar -xzf "$archive" -C "$QUAL_ROOT/bin"
chmod 0755 "$MSB_BIN"
[[ "$($MSB_BIN --version)" == 'msb 0.6.10' ]]

"$MSB_BIN" image pull "$BUILDER_IMAGE"
"$MSB_BIN" image inspect --format json "$BUILDER_IMAGE" \
  >"$ARTIFACT_DIR/nix-builder-image.json"

"$MSB_BIN" create --name "$BUILDER_NAME" \
  --cpus "${ADE_BUILDER_CPUS:-4}" \
  --memory "${ADE_BUILDER_MEMORY:-12G}" \
  --root-disk "${ADE_BUILDER_ROOT_DISK:-40G}" \
  --mount-dir "$REPO_ROOT:/mnt" \
  --workdir /mnt \
  --net public \
  --pull never \
  "$BUILDER_IMAGE"

# The repository is mounted at /mnt, so the guest can only write back through
# a path inside it. Build there, then move the archive to ARTIFACT_DIR on the
# host, which may point anywhere.
"$MSB_BIN" exec --no-tty --timeout "${ADE_BUILDER_TIMEOUT:-45m}" \
  "$BUILDER_NAME" -- sh -lc '
    set -eu
    mkdir -p /root/.config/nix /mnt/artifacts
    printf "experimental-features = nix-command flakes\nsandbox = false\n" \
      >/root/.config/nix/nix.conf
    nix build ./images/nix-workstation#packages.aarch64-linux.workstation \
      --out-link /tmp/ade-nix-workstation
    cp -L /tmp/ade-nix-workstation /mnt/artifacts/ade-nix-workstation-0.1.0.tar.gz
  '

if [[ "$ARTIFACT_DIR" != "$REPO_ROOT/artifacts" ]]; then
  mv "$REPO_ROOT/artifacts/ade-nix-workstation-0.1.0.tar.gz" \
    "$ARTIFACT_DIR/ade-nix-workstation-0.1.0.tar.gz"
fi

gzip -dc "$ARTIFACT_DIR/ade-nix-workstation-0.1.0.tar.gz" \
  >"$ARTIFACT_DIR/ade-nix-workstation-0.1.0.tar"
"$MSB_BIN" image load --input "$ARTIFACT_DIR/ade-nix-workstation-0.1.0.tar"
"$MSB_BIN" image inspect --format json ade-nix-workstation:0.1.0 \
  >"$ARTIFACT_DIR/ade-nix-workstation-0.1.0.json"

printf 'image=%s\nmetadata=%s\n' \
  "$ARTIFACT_DIR/ade-nix-workstation-0.1.0.tar" \
  "$ARTIFACT_DIR/ade-nix-workstation-0.1.0.json"
