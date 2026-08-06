{
  description = "ADE Microsandbox Nix-built workstation spike";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      system = "aarch64-linux";
      pkgs = import nixpkgs { inherit system; };

      root = pkgs.buildEnv {
        name = "ade-workstation-root";
        paths = with pkgs; [
          bashInteractive
          cacert
          coreutils
          curl
          dune_3
          fd
          file
          findutils
          gawk
          gcc
          git
          gnumake
          gnugrep
          gnused
          jujutsu
          less
          neovim
          nix
          ocaml
          opam
          openssh
          pkg-config
          ripgrep
          tmux
          which
          dockerTools.binSh
          dockerTools.fakeNss
          dockerTools.usrBinEnv
        ];
        pathsToLink = [ "/bin" "/etc" "/libexec" "/share" ];
      };
    in
    {
      packages.${system} = rec {
        workstation = pkgs.dockerTools.buildLayeredImage {
          name = "ade-nix-workstation";
          tag = "spike";
          contents = [ root ];
          extraCommands = ''
            mkdir -p ./etc/nix ./nix/var/nix/profiles/per-user/root ./root ./workspace
            cat > ./etc/nix/nix.conf <<'EOF'
            experimental-features = nix-command flakes
            sandbox = false
            EOF
          '';
          config = {
            Cmd = [ "/bin/bash" ];
            Env = [
              "PATH=/bin"
              "HOME=/root"
              "USER=root"
              "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
              "LANG=C.UTF-8"
            ];
            WorkingDir = "/workspace";
          };
        };

        default = workstation;
      };
    };
}
