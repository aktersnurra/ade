{
  description = "ADE: manage local SmolVM agent workbenches";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Pinned to the exact revisions the approved SmolVM commit declares. The
    # macOS build weak-links libkrun, so the host CLI cannot be linked without
    # them, and the published release tarballs are not an acceptable substitute:
    # they carry no signatures or provenance attestations.
    libkrun-src = {
      url = "github:smol-machines/libkrun/98163265197caa24a789699f16a68b98e917b65b";
      flake = false;
    };

    libkrunfw-src = {
      url = "github:smol-machines/libkrunfw/516ceece6aed60ccc84ac8faa459885062e39400";
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
          libkrunfw = pkgs.callPackage ./nix/libkrunfw.nix { src = libkrunfw-src; };
          libkrun = pkgs.callPackage ./nix/libkrun.nix {
            src = libkrun-src;
            inherit libkrunfw;
            withBlk = true;
            withNet = true;
            withGpu = pkgs.stdenv.hostPlatform.isLinux;
          };
        in
        {
          ade = adePackage pkgs;
          default = adePackage pkgs;
          inherit libkrunfw libkrun;
          smolvm = pkgs.callPackage ./nix/smolvm.nix { inherit libkrun; };
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
