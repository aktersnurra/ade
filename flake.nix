{
  description = "ADE: manage local SmolVM agent workbenches";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Pinned to the submodule commits recorded at the approved SmolVM revision
    # (`git ls-tree 62f5f04 libkrun libkrunfw`), NOT to the revisions in
    # upstream's own flake.nix, which are stale relative to those submodules.
    #
    # Upstream treats the submodules as authoritative: scripts/check-libkrun-
    # provenance.sh asserts the shipped library matches `HEAD:libkrun`
    # specifically to prevent shipping a stale libkrun. The flake inputs are not
    # covered by that check and had drifted.
    #
    # The drift is not cosmetic. libkrun 98163265 still defaulted VsockConfig to
    # Implicit and exported krun_disable_implicit_vsock; 2dfbd6fb removes that
    # symbol and defaults to Disabled, which is precisely what smolvm 1.13.1
    # assumes when it calls krun_add_vsock directly.
    #
    # The macOS build weak-links libkrun, so the host CLI cannot be linked
    # without these. The published release tarballs are not an acceptable
    # substitute: they carry no signatures or provenance attestations.
    libkrun-src = {
      url = "github:smol-machines/libkrun/2dfbd6fb6a1acf50413b64009b90fed8c589c9c3";
      flake = false;
    };

    libkrunfw-src = {
      url = "github:smol-machines/libkrunfw/8f1307644bdcb95fe1343bf0d6ccf30aa22f1549";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, libkrun-src, libkrunfw-src }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));

      adePackage = pkgs:
        let ocamlPackages = pkgs.ocamlPackages;
        in ocamlPackages.buildDunePackage {
          pname = "ade";
          version = "0.1.0";
          duneVersion = "3";
          src = ./.;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          buildInputs = with ocamlPackages; [
            cmdliner
            otoml
            yojson
            digestif
            bos
            rresult
          ];
          doCheck = false;
          meta.mainProgram = "ade";
        };
    in
    {
      packages = forAllSystems (pkgs:
        let
          # Built from pinned source, but not currently usable: see
          # nix/libkrunfw-upstream.nix for why the published artifact is used
          # instead. Kept so a source build can be re-tested with a suitable
          # compiler.
          libkrunfw-source = pkgs.callPackage ./nix/libkrunfw.nix {
            src = libkrunfw-src;
          };

          libkrunfw = pkgs.callPackage ./nix/libkrunfw-upstream.nix { };
          # libkrun links against libkrunfw's headers and stub only; the kernel
          # payload it loads at runtime is whichever library SMOLVM_LIB_DIR
          # provides. It therefore builds against the source expression, while
          # the runtime uses the upstream artifact.
          libkrun = pkgs.callPackage ./nix/libkrun.nix {
            src = libkrun-src;
            libkrunfw = libkrunfw-source;
            withBlk = true;
            withNet = true;
            withGpu = pkgs.stdenv.hostPlatform.isLinux;
          };
          smolvm-agent = pkgs.callPackage ./nix/smolvm-agent.nix { };
          agent-rootfs = pkgs.callPackage ./nix/agent-rootfs.nix {
            inherit smolvm-agent;
          };
        in
        {
          ade = adePackage pkgs;
          default = adePackage pkgs;
          inherit libkrunfw libkrunfw-source libkrun smolvm-agent agent-rootfs;
          smolvm = pkgs.callPackage ./nix/smolvm.nix {
            inherit libkrun libkrunfw agent-rootfs;
          };
        });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = (with pkgs.ocamlPackages; [
            ocaml
            dune_3
            findlib
            ocaml-lsp
            ocamlformat
            cmdliner
            otoml
            yojson
            digestif
            bos
            rresult
            alcotest
          ]) ++ [ pkgs.python3 pkgs.git ];
        };
      });

      checks = forAllSystems (pkgs: {
        unit = (adePackage pkgs).overrideAttrs (old: {
          name = "ade-unit-checks";
          doCheck = true;
          checkInputs = [ pkgs.ocamlPackages.alcotest ];
        });
      });
    };
}
