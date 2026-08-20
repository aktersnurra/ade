# Nix workstation image

This flake builds the `aarch64-linux` OCI image used by the runnable Microsandbox profiles.

## Customize packages

Edit `packages.nix`. The default includes OCaml 5.5, dune, opam, Git, Jujutsu, Nix, Node.js 22, Python, Go, Rust, Neovim, tmux, and standard build/network utilities.

## Bake configuration

Place files under `root/`; they are copied verbatim into the image root. This can include personal configuration or credentials when that is the desired persistence and distribution model.

## Build

```sh
nix build ./images/nix-workstation#workstation
```

The Nix result is a gzip-compressed OCI archive tagged `ade-nix-workstation:0.1.0`. Microsandbox 0.6.10 expects the uncompressed tar stream, so decompress it before loading:

```sh
gzip -dc result > ade-nix-workstation-0.1.0.tar
msb image load --input ade-nix-workstation-0.1.0.tar
```

The Darwin `bin/ade build-image` command automates the Linux builder, decompression, load, and inspection steps.
