# Image root overlay

Everything under this directory is copied into the OCI image root.

Use it for any image-baked configuration required by your workbench, including dotfiles, editor settings, agent configuration, certificates, credential files, scripts, and project-specific defaults. The repository and resulting image will contain those bytes, so choose deliberately which material belongs here versus a runtime mount, environment value, or Microsandbox `--secret` source.

Examples:

```text
root/
  root/.config/nvim/init.lua
  root/.gitconfig
  etc/ssl/certs/company-ca.pem
  usr/local/bin/workbench-init
```
