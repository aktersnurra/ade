# shellcheck shell=bash disable=SC2034

PROFILE_HOME="${ADE_WORK_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ade/workbenches/work}"
SANDBOX_NAME="${ADE_WORK_SANDBOX:-ade-work}"
IMAGE="${ADE_WORK_IMAGE:-ade-nix-workstation:0.1.0}"
if [[ -n "${ADE_WORK_IMAGE:-}" ]]; then
  EXPECTED_IMAGE_DIGEST="${ADE_WORK_IMAGE_DIGEST:-}"
else
  EXPECTED_IMAGE_DIGEST="sha256:5c0bffada804326ae73d3bf3778a77358aa236974e27d9f80a7ec88e826a1997"
fi
CPUS="${ADE_WORK_CPUS:-4}"
MEMORY="${ADE_WORK_MEMORY:-8G}"
ROOT_DISK="${ADE_WORK_ROOT_DISK:-24G}"
CREDENTIAL_ENV_FILE="${ADE_WORK_CREDENTIALS:-${XDG_CONFIG_HOME:-$HOME/.config}/ade/credentials/work.env}"

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

# Point this at the parent of your work checkouts so agents can search across
# repositories. Mount the repository root only -- not $HOME -- and check the
# tree for .env files, kubeconfigs, and .git/config remotes carrying tokens,
# because everything mounted here is readable by every agent in this VM.
if [[ -n "${ADE_WORK_REPOS:-}" ]]; then
  MOUNTS+=("$ADE_WORK_REPOS:/repos")
fi

# The agent gets its own Git identity: a dedicated SSH key for push, a dedicated
# GPG key for signing, and a fine-grained PAT below. Commits are then
# attributable to the agent rather than to you, GitHub's audit log separates the
# two, and revoking the agent's access never touches your own credentials.
#
# Generate these once, outside the workspace:
#   ssh-keygen -t ed25519 -f ~/.config/ade/identity/work/ssh/id_ed25519 -C ade-work
#   gpg --quick-gen-key 'ADE Work Agent <you+ade@example.com>' ed25519 sign 1y
ADE_WORK_IDENTITY="${ADE_WORK_IDENTITY:-${XDG_CONFIG_HOME:-$HOME/.config}/ade/identity/work}"
if [[ -d "$ADE_WORK_IDENTITY/ssh" ]]; then
  MOUNTS+=("$ADE_WORK_IDENTITY/ssh:/root/.ssh")
fi
if [[ -d "$ADE_WORK_IDENTITY/gnupg" ]]; then
  MOUNTS+=("$ADE_WORK_IDENTITY/gnupg:/root/.gnupg")
fi

# Deny by default, then permit the common workbench destinations below.
# Add, remove, or replace rules with any Microsandbox --net-rule grammar.
NETWORK_ARGS=(
  --no-net
  --net-rule "allow:egress@dns"
  # GitHub Copilot (the work-licensed agent) and its device-code login.
  --net-rule "allow@api.githubcopilot.com:tcp:443"
  --net-rule "allow@copilot-proxy.githubusercontent.com:tcp:443"
  --net-rule "allow@api.github.com:tcp:443"
  --net-rule "allow@github.com:tcp:443"
  --net-rule "allow@objects.githubusercontent.com:tcp:443"
  --net-rule "allow@raw.githubusercontent.com:tcp:443"
  --net-rule "allow@cache.nixos.org:tcp:443"
  --net-rule "allow@opam.ocaml.org:tcp:443"
  --net-rule "allow@registry.npmjs.org:tcp:443"
  --net-rule "allow@pypi.org:tcp:443"
  --net-rule "allow@files.pythonhosted.org:tcp:443"
  --net-rule "allow@crates.io:tcp:443"
  --net-rule "allow@static.crates.io:tcp:443"
  --net-rule "allow@proxy.golang.org:tcp:443"
  --net-rule "allow@sum.golang.org:tcp:443"
)

# Override this function in a user profile to load values from macOS Keychain,
# 1Password, pass, SOPS, a mounted file, or any other credential source.
load_credentials() { :; }

# Agent harnesses authenticate inside this VM. Their login state persists in
# the profile-specific /root/.config mount, so work and personal authority do
# not cross. Git operations may use the optional dedicated SSH/GPG mounts above.
# Add explicit credential handling only in a user profile when VM-local login
# is unsuitable; no ambient host credential is forwarded by this profile.
configure_credentials() { :; }

# Append arbitrary native options; nothing is hidden by the launcher.
EXTRA_CREATE_ARGS=()
DEFAULT_SHELL=(/bin/bash -l)
