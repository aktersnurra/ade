# Pinned, source-built SmolVM host CLI for ADE.
#
# ADE does not use the upstream release tarballs: they lack signatures and
# provenance attestations, and upstream's own nix expression tracks a different
# version. This derivation builds the exact approved revision from source and
# applies the macOS Hypervisor.framework entitlement ADE depends on.
{ lib
, stdenv
, rustPlatform
, fetchFromGitHub
, pkg-config
, makeWrapper
, libkrun ? null
, jq
, gzip
, gnutar
, coreutils
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

  runtimeDeps = [ jq gzip gnutar coreutils ];
in
rustPlatform.buildRustPackage {
  pname = "smolvm";
  inherit version src;

  cargoLock = {
    lockFile = "${src}/Cargo.lock";
  };

  nativeBuildInputs = [ pkg-config makeWrapper ];

  # Apple frameworks (including Hypervisor) come from the darwin stdenv SDK in
  # current nixpkgs; they are no longer separate derivations.
  buildInputs = lib.optional (libkrun != null) libkrun;

  # Only the host CLI is required; the workspace also contains guest-only and
  # CUDA crates that are not part of ADE's trusted surface.
  cargoBuildFlags = [ "--bin" "smolvm" ];

  doCheck = false;

  postInstall = lib.optionalString stdenv.hostPlatform.isDarwin ''
    cp ${src}/smolvm.entitlements entitlements.plist
    /usr/bin/codesign --force --sign - \
      --entitlements entitlements.plist \
      "$out/bin/smolvm"
  '';

  postFixup = ''
    wrapProgram "$out/bin/smolvm" \
      --prefix PATH : ${lib.makeBinPath runtimeDeps}
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/smolvm" --version | grep -q "${version}"
  '' + lib.optionalString stdenv.hostPlatform.isDarwin ''
    codesign -d --entitlements :- "$out/bin/smolvm" 2>&1 \
      | grep -q com.apple.security.hypervisor
  '' + ''
    runHook postInstallCheck
  '';

  meta = {
    description = "OCI-native microVM runtime, pinned and source-built for ADE";
    homepage = "https://github.com/smol-machines/smolvm";
    license = lib.licenses.asl20;
    mainProgram = "smolvm";
  };
}
