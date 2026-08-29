{
  description = "ADE: manage local SmolVM agent workbenches";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
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
      packages = forAllSystems (pkgs: {
        ade = adePackage pkgs;
        default = adePackage pkgs;
        smolvm = pkgs.callPackage ./nix/smolvm.nix { libkrun = null; };
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
