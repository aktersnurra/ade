#!/usr/bin/env bash
# Provision an Arch (or Arch Linux ARM) workbench guest. ADE pipes this to
# `bash -s` as root after the machine is created, with no SSH identity and no
# credentials in the guest. It is safe to re-run.
set -euo pipefail

# The image is a daily rebuild of Arch Linux ARM; refresh its keyring before
# upgrading so a stale signing key cannot fail the transaction.
pacman-key --init
case "$(uname -m)" in
  aarch64) pacman-key --populate archlinuxarm ;;
  *) pacman-key --populate archlinux ;;
esac

pacman -Syu --noconfirm --needed \
  base-devel curl git jujutsu openssh ripgrep fd nodejs npm python

# Herdr and Claude Code ship their own installers. Both land under
# ~/.local/bin or similar, which a non-login shell does not have on PATH.
curl -fsSL https://herdr.dev/install.sh | sh
curl -fsSL https://claude.ai/install.sh | bash

cat > /etc/profile.d/ade-path.sh <<'EOF'
export PATH="$HOME/.local/bin:$PATH"
EOF

# Clone mounts under /src belong to the host user, not to guest root, so git
# refuses to clone them as "dubious ownership". They are the user's own
# repositories, mounted read-only.
git config --system --replace-all safe.directory '/src/*' '^/src/\*$'
