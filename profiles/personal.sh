# shellcheck shell=bash disable=SC2034

PROFILE_HOME="${ADE_PERSONAL_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ade/workbenches/personal}"
SANDBOX_NAME="${ADE_PERSONAL_SANDBOX:-ade-personal}"
IMAGE="${ADE_PERSONAL_IMAGE:-ade-nix-workstation:0.1.0}"
if [[ -n "${ADE_PERSONAL_IMAGE:-}" ]]; then
  EXPECTED_IMAGE_DIGEST="${ADE_PERSONAL_IMAGE_DIGEST:-}"
else
  EXPECTED_IMAGE_DIGEST="sha256:5c0bffada804326ae73d3bf3778a77358aa236974e27d9f80a7ec88e826a1997"
fi
CPUS="${ADE_PERSONAL_CPUS:-4}"
MEMORY="${ADE_PERSONAL_MEMORY:-8G}"
ROOT_DISK="${ADE_PERSONAL_ROOT_DISK:-24G}"
CREDENTIAL_ENV_FILE="${ADE_PERSONAL_CREDENTIALS:-${XDG_CONFIG_HOME:-$HOME/.config}/ade/credentials/personal.env}"

PERSIST_DIRS=(
  "$PROFILE_HOME/workspace"
  "$PROFILE_HOME/config"
  "$PROFILE_HOME/cache"
  "$PROFILE_HOME/state"
)
MOUNTS=(
  "$PROFILE_HOME/workspace:/workspace"
  "$PROFILE_HOME/config:/root/.config"
  "$PROFILE_HOME/cache:/root/.cache"
  "$PROFILE_HOME/state:/root/.local/state"
)

# A dedicated SSH and GPG identity for this workbench, so its commits are
# attributable and revoking it never touches your own keys. See work.sh for the
# generation commands.
ADE_PERSONAL_IDENTITY="${ADE_PERSONAL_IDENTITY:-${XDG_CONFIG_HOME:-$HOME/.config}/ade/identity/personal}"
if [[ -d "$ADE_PERSONAL_IDENTITY/ssh" ]]; then
  MOUNTS+=("$ADE_PERSONAL_IDENTITY/ssh:/root/.ssh")
fi
if [[ -d "$ADE_PERSONAL_IDENTITY/gnupg" ]]; then
  MOUNTS+=("$ADE_PERSONAL_IDENTITY/gnupg:/root/.gnupg")
fi

# Public networking is deliberate for the personal profile. Copy the profile
# and replace this with --no-net plus explicit rules when a narrower personal
# workbench is desired.
NETWORK_ARGS=(--net public)

load_credentials() { :; }

# Agent harnesses authenticate inside this VM. Device-login state persists in
# the profile-specific /root/.config mount. No ambient host credential is
# forwarded automatically.
configure_credentials() { :; }

EXTRA_CREATE_ARGS=()
DEFAULT_SHELL=(/bin/bash -l)
