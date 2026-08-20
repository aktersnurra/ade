# shellcheck shell=bash disable=SC2034

PROFILE_HOME="${ADE_WORK_OFFLINE_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ade/workbenches/work-offline}"
SANDBOX_NAME="${ADE_WORK_OFFLINE_SANDBOX:-ade-work-offline}"
IMAGE="${ADE_WORK_OFFLINE_IMAGE:-ade-nix-workstation:0.1.0}"
if [[ -n "${ADE_WORK_OFFLINE_IMAGE:-}" ]]; then
  EXPECTED_IMAGE_DIGEST="${ADE_WORK_OFFLINE_IMAGE_DIGEST:-}"
else
  EXPECTED_IMAGE_DIGEST="sha256:5c0bffada804326ae73d3bf3778a77358aa236974e27d9f80a7ec88e826a1997"
fi
CPUS="${ADE_WORK_OFFLINE_CPUS:-4}"
MEMORY="${ADE_WORK_OFFLINE_MEMORY:-8G}"
ROOT_DISK="${ADE_WORK_OFFLINE_ROOT_DISK:-24G}"

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

# No DNS exception, destination rule, credential file, or secret source.
NETWORK_ARGS=(--no-net)
CREDENTIAL_ENV_FILE=""
SECRET_SPECS=()
REQUIRED_SECRETS=()
ENV_ARGS=()
EXTRA_CREATE_ARGS=()
DEFAULT_SHELL=(/bin/bash -l)
