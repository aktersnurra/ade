#!/usr/bin/env bash
# Install the qualified SmolVM build into ADE's managed runtime root.
#
# This installer is deliberately narrow. It never touches Homebrew, the upstream
# SmolVM default directories, or Microsandbox. It only ever writes below
# ADE_SMOLVM_INSTALL_ROOT.
#
# Honored environment:
#   ADE_SMOLVM_INSTALL_ROOT  managed runtime root (default ~/.local/share/ade/runtime)
#   ADE_SMOLVM_NIX_RESULT    prebuilt nix result to install instead of building

set -euo pipefail

readonly EXPECTED_VERSION="smolvm 1.13.1"
readonly VERSION_DIR="smolvm-1.13.1"

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

install_root="${ADE_SMOLVM_INSTALL_ROOT:-${HOME}/.local/share/ade/runtime}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Resolve the build result.
if [[ -n "${ADE_SMOLVM_NIX_RESULT:-}" ]]; then
  result="${ADE_SMOLVM_NIX_RESULT}"
else
  nix build "${repo_root}#smolvm" --no-link --print-out-paths >/tmp/.ade-smolvm-out
  result="$(cat /tmp/.ade-smolvm-out)"
  rm -f /tmp/.ade-smolvm-out
fi

[[ -d "${result}" ]] || fail "build result not found: ${result}"

binary="${result}/bin/smolvm"
[[ -x "${binary}" ]] || fail "smolvm binary not executable: ${binary}"

# Verify the exact version before anything is installed.
actual_version="$("${binary}" --version 2>/dev/null | head -n1 | tr -d '\r')"
if [[ "${actual_version}" != "${EXPECTED_VERSION}" ]]; then
  fail "expected ${EXPECTED_VERSION}, found '${actual_version}'"
fi

# Verify the macOS hypervisor entitlement.
#
# The entitlement lives on the executable the kernel actually loads. A Nix build
# wraps the binary, so bin/smolvm is a shell wrapper and the signed Mach-O is
# bin/.smolvm-wrapped; check that when it is present.
#
# A test double supplies entitlements.plist instead of a real signature.
signed_binary="${binary}"
if [[ -f "${result}/bin/.smolvm-wrapped" ]]; then
  signed_binary="${result}/bin/.smolvm-wrapped"
fi

entitlements=""
if [[ -f "${result}/entitlements.plist" ]]; then
  entitlements="$(cat "${result}/entitlements.plist")"
elif [[ -x /usr/bin/codesign ]]; then
  entitlements="$(/usr/bin/codesign -d --entitlements - "${signed_binary}" 2>&1 || true)"
fi

if ! printf '%s' "${entitlements}" | grep -q 'com.apple.security.hypervisor'; then
  fail "missing hypervisor entitlement on ${signed_binary}"
fi

# Record the digest of exactly what is being installed: the signed Mach-O, not
# the wrapper script around it.
digest="$(shasum -a 256 "${signed_binary}" | awk '{print $1}')"

mkdir -p "${install_root}"
staging="$(mktemp -d "${install_root}/.staging-XXXXXX")"
trap 'rm -rf "${staging}"' EXIT

cp -R "${result}/." "${staging}/"
chmod -R u+w "${staging}"
printf '%s\n' "${digest}" > "${staging}/SMOLVM_SHA256"
printf '%s\n' "${EXPECTED_VERSION}" > "${staging}/SMOLVM_VERSION"

target="${install_root}/${VERSION_DIR}"
rm -rf "${target}.previous"
if [[ -e "${target}" ]]; then
  mv "${target}" "${target}.previous"
fi
mv "${staging}" "${target}"
trap - EXIT
rm -rf "${target}.previous"

printf 'installed %s at %s\n' "${EXPECTED_VERSION}" "${target}"
printf 'sha256 %s\n' "${digest}"
