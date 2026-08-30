# The SmolVM guest agent, cross-compiled to Linux musl.
#
# Upstream builds this on macOS by running smolvm itself, which cannot work
# before a rootfs exists. Nix cross-compiles directly instead, so the runtime is
# self-contained and reproducible rather than bootstrapped from a prebuilt
# release artifact.
{ lib
, stdenv
, pkgsCross
, fetchFromGitHub
, rustPlatform
}:

let
  version = "1.13.1";
  rev = "62f5f04bcb4fc097cca55cffa5772a32093f4636";

  src = fetchFromGitHub {
    owner = "smol-machines";
    repo = "smolvm";
    inherit rev;
    hash = "sha256-jLcJpAoF+as+y15oaL8u9Z+YFIBjyFgMC2K3sNQh4VM=";
  };

  # The guest is always Linux, whatever the host is.
  muslPkgs =
    if stdenv.hostPlatform.isAarch64
    then pkgsCross.aarch64-multiplatform-musl
    else pkgsCross.musl64;
in
muslPkgs.rustPlatform.buildRustPackage {
  pname = "smolvm-agent";
  inherit version src;

  cargoLock.lockFile = "${src}/Cargo.lock";

  # Only the guest agent. The workspace also holds host-only and CUDA crates
  # that have no place in the guest rootfs.
  cargoBuildFlags = [ "-p" "smolvm-agent" ];

  doCheck = false;

  # A fully static binary: the guest rootfs is assembled from Alpine packages
  # and must not depend on the build host's dynamic loader.
  RUSTFLAGS = "-C target-feature=+crt-static";

  meta = {
    description = "SmolVM guest agent, cross-compiled for the guest rootfs";
    license = lib.licenses.asl20;
    mainProgram = "smolvm-agent";
  };
}
