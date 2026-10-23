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

# Credentials live only in tmpfs under /run/ade/secrets and are installed by
# ADE at every start; nothing below holds one, it only says where to look.
#
# git asks this helper for github.com over HTTPS and gets the active GitHub
# App installation token. With no token installed it answers nothing, and git
# falls back to whatever else is configured.
install -d /usr/local/bin
cat > /usr/local/bin/ade-git-credential <<'HELPER'
#!/bin/sh
[ "$1" = get ] || exit 0
token=/run/ade/secrets/current/github
[ -r "$token" ] || exit 0
printf 'username=x-access-token\npassword=%s\n' "$(cat "$token")"
HELPER
chmod 755 /usr/local/bin/ade-git-credential
git config --system credential.https://github.com.helper /usr/local/bin/ade-git-credential

# Claude Code reads ANTHROPIC_API_KEY. Login shells get it from profile.d,
# interactive ones (Herdr panes) from bash.bashrc.
cat > /etc/profile.d/ade-credentials.sh <<'ENV'
if [ -r /run/ade/secrets/anthropic ]; then
  ANTHROPIC_API_KEY="$(cat /run/ade/secrets/anthropic)"
  export ANTHROPIC_API_KEY
fi
ENV
grep -qxF '. /etc/profile.d/ade-credentials.sh' /etc/bash.bashrc 2>/dev/null \
  || echo '. /etc/profile.d/ade-credentials.sh' >> /etc/bash.bashrc
