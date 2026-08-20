{
  description = "Configurable ADE Microsandbox workstation OCI image";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      system = "aarch64-linux";
      pkgs = import nixpkgs { inherit system; };
      workstationPackages = import ./packages.nix { inherit pkgs; };

      packagesRoot = pkgs.buildEnv {
        name = "ade-workstation-root";
        paths = workstationPackages;
        pathsToLink = [ "/bin" "/etc" "/libexec" "/share" ];
      };

      configuredRoot = pkgs.runCommand "ade-workstation-configured-root" { } ''
        mkdir -p "$out"
        cp -a ${./root}/. "$out/"
      '';
    in
    {
      packages.${system} = rec {
        workstation = pkgs.dockerTools.buildLayeredImage {
          name = "ade-nix-workstation";
          tag = "0.1.0";
          contents = [ packagesRoot configuredRoot ];
          extraCommands = ''
            mkdir -p ./etc/nix ./nix/var/nix/profiles/per-user/root \
              ./root/.config ./root/.cache ./root/.local/state ./workspace
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
