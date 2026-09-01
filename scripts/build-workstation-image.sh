#!/usr/bin/env bash
# Build the ADE workstation OCI image.
#
# The image is aarch64-linux, and Nix can only assemble it on an aarch64-linux
# machine. This host is macOS, so the build runs inside a SmolVM workbench --
# the SmolVM replacement for the Microsandbox path this repository used before.
#
# The builder is the previously built workstation image itself, which already
# contains Nix. That makes the build self-hosting: the current image builds its
# successor.
#
# Honored environment:
#   ADE_SMOLVM_BIN        runtime to use (default: managed runtime root)
#   ADE_BUILDER_IMAGE     image to build inside (default: artifacts/*.tar)
#   ADE_ARTIFACT_DIR      where the result is written (default: artifacts/)

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifact_dir="${ADE_ARTIFACT_DIR:-$repo_root/artifacts}"
smolvm="${ADE_SMOLVM_BIN:-$HOME/.local/share/ade/runtime/smolvm-1.13.1/bin/smolvm}"
builder_image="${ADE_BUILDER_IMAGE:-$artifact_dir/ade-nix-workstation-0.1.0.tar}"

fail() { printf '%s\n' "$*" >&2; exit 1; }

[[ -x "$smolvm" ]] || fail "smolvm runtime not found: $smolvm"
[[ -f "$builder_image" ]] || fail "builder image not found: $builder_image"

# mkfs.ext4 is needed on the host to format the machine's disks.
command -v mkfs.ext4 >/dev/null 2>&1 \
  || fail 'mkfs.ext4 not on PATH; add e2fsprogs (nix profile install nixpkgs#e2fsprogs)'

mkdir -p "$artifact_dir"

# A short HOME: the agent's Unix socket path must stay under the macOS
# sun_path limit of 104 bytes, which a $TMPDIR path exceeds.
work="$(mktemp -d /tmp/ade-img.XXXXXX)"
trap 'rm -rf "$work"' EXIT
export HOME="$work" \
       XDG_DATA_HOME="$work/data" \
       XDG_CACHE_HOME="$work/cache" \
       XDG_CONFIG_HOME="$work/config"

echo "building the workstation image inside a workbench..."

# Assembling a layered image of this size needs considerably more than the
# defaults: the store fills with hundreds of packages before the tarball is
# written, and a too-small VM dies mid-build with "unexpected EOF reading a
# line" from the build hook rather than a clear resource error.
"$smolvm" machine run --net \
  --mem 16384 \
  --cpus 6 \
  --storage 60 \
  -v "$repo_root/images/nix-workstation:/src:ro" \
  -v "$artifact_dir:/out" \
  --image "$builder_image" \
  -- /bin/bash -c '
    set -euo pipefail

    # The flake directory is mounted read-only, and Nix needs to write a lock
    # file, so build from a copy.
    build_dir="$(mktemp -d)"
    cp -a /src/. "$build_dir/"
    cd "$build_dir"

    # Three settings the image ships that do not hold inside a workbench:
    #
    #   builders/build-hook: the image points at @/etc/nix/machines, which does
    #     not exist here. Nix still spawns the hook, it exits immediately, and
    #     the failure surfaces as "unexpected EOF reading a line" rather than
    #     anything about remote builders.
    #   build-users-group: the image has no nixbld group. The build runs as root
    #     in a VM that is itself the isolation boundary, so an empty group is
    #     what applies.
    #
    # These are passed as flags rather than NIX_CONFIG, which the image config
    # overrides.
    nix \
      --extra-experimental-features "nix-command flakes" \
      --builders "" \
      --option build-hook "" \
      --option build-users-group "" \
      --max-jobs 4 \
      build ".#packages.aarch64-linux.workstation" --print-build-logs

    cp -L result /out/ade-nix-workstation-0.1.0.tar.new
  '

result="$artifact_dir/ade-nix-workstation-0.1.0.tar"
[[ -f "$result.new" ]] || fail 'the build produced no image'
mv "$result.new" "$result"

digest="$(shasum -a 256 "$result" | awk '{print $1}')"
printf 'built %s\nsha256 %s\n' "$result" "$digest"
