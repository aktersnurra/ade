{ pkgs }:
let
  # Pinned to the same major/minor the host controller builds against, so a
  # project developed inside a workbench and built on the host see the same
  # compiler. This is a glibc OCaml from nixpkgs: the musl toolchain question
  # only affects the guest *agent* rootfs, never the workbench image.
  ocamlPackages = pkgs.ocaml-ng.ocamlPackages_5_5;

  # The OCaml toolchain a workbench needs to build ADE-shaped projects without
  # reaching the network on first use. Kept to the libraries ADE itself
  # depends on plus the editor tooling; anything project-specific belongs in
  # that project's own flake or opam switch.
  ocamlToolchain = with ocamlPackages; [
    ocaml
    dune_3
    findlib
    ocaml-lsp
    ocamlformat
    utop
    # ADE's own dependency set, so `dune build` works offline in a workbench.
    alcotest
    bos
    cmdliner
    digestif
    otoml
    rresult
    yojson
  ];

  # Herdr owns agent processes, worktrees, shells and sessions inside the
  # workbench. ADE only materializes its trusted configuration, starts it, and
  # attaches; it does not manage what runs inside.
  herdr = pkgs.callPackage ./herdr.nix { };
in
with pkgs; ocamlToolchain ++ [ herdr ] ++ [
  bashInteractive
  cacert
  coreutils
  curl
  dockerTools.binSh
  dockerTools.fakeNss
  dockerTools.usrBinEnv
  fd
  file
  findutils
  gawk
  gcc
  git
  gnumake
  gnugrep
  gnused
  go
  jq
  jujutsu
  less
  neovim
  nix
  nodejs_22
  opam
  pkg-config
  python3
  ripgrep
  rustc
  cargo
  tmux
  which
  zsh
]
