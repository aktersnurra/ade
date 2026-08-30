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

  postFixup = ''
    wrapProgram "$out/bin/smolvm" \
      --prefix PATH : ${lib.makeBinPath runtimeDeps}
  '' + lib.optionalString stdenv.hostPlatform.isDarwin ''
    # wrapProgram has renamed the real executable, so the library reference and
    # the signature must be applied to the wrapped binary: that is the file the
    # kernel actually loads and checks entitlements on.
    real="$out/bin/.smolvm-wrapped"

    # smolvm weak-links libkrun, and records it as the bare name
    # "libkrun.1.dylib". dyld never resolves a bare name through rpath, so the
    # reference itself must be rewritten to the pinned library's absolute path.
    ${lib.optionalString (libkrun != null) ''
      install_name_tool \
        -change libkrun.1.dylib "${lib.getLib libkrun}/lib/libkrun.1.dylib" \
        "$real"
    ''}

    # Signing must follow install_name_tool, which invalidates any existing
    # signature.
    cp ${src}/smolvm.entitlements entitlements.plist
    /usr/bin/codesign --force --sign - \
      --entitlements entitlements.plist \
      "$real"
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    # The CLI prints an informational note about packed assets on stderr, so the
    # version assertion reads stdout only.
    version_output="$("$out/bin/smolvm" --version 2>/dev/null)"
    echo "smolvm reports: $version_output"
    case "$version_output" in
      *"${version}"*) ;;
      *) echo "expected smolvm ${version}, got '$version_output'" >&2; exit 1 ;;
    esac
  '' + lib.optionalString stdenv.hostPlatform.isDarwin ''
    # codesign is a host tool and is not on the build sandbox PATH, so it is
    # invoked by absolute path, exactly as it is for signing above.
    entitlements="$(/usr/bin/codesign -d --entitlements - "$out/bin/.smolvm-wrapped" 2>&1)"
    case "$entitlements" in
      *com.apple.security.hypervisor*) echo "hypervisor entitlement present" ;;
      *) echo "missing hypervisor entitlement" >&2; exit 1 ;;
    esac
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
