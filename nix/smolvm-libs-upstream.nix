# Upstream's published libkrun and libkrunfw, from the SmolVM release artifact.
#
# ADE builds every other component from pinned source. This one is consumed
# prebuilt for a specific, documented reason: the guest kernel's behaviour
# depends on the compiler that builds it. Upstream compiles it with Debian GCC
# 12.2.0 (visible in the kernel's own version banner); nixpkgs' aarch64 cross
# compiler is GCC 15.3.0 and produces a kernel that boots but never reaches
# init. GCC 12 has been removed from nixpkgs, so the toolchain upstream
# actually uses is not available here.
#
# The tradeoff is deliberate and bounded:
#
#   - it applies to libkrunfw only; the SmolVM CLI, libkrun, the guest agent
#     and the agent rootfs are all still built from pinned source;
#   - the artifact is pinned by SHA-256 and matches upstream's published
#     checksums.sha256, so it is immutable and verifiable, unlike a
#     curl-to-latest install;
#   - it carries no signature or provenance attestation, which is exactly the
#     property the design objects to. That gap is recorded rather than hidden.
#
# Replacing this with a source build requires either the GCC upstream uses or
# building libkrunfw the way upstream does, inside a Linux VM.
{ lib
, stdenv
, fetchurl
  # Accepted for interface compatibility with nix/libkrunfw.nix, which
  # libkrun.nix overrides. The published release ships only the default
  # variant, so anything else is refused rather than silently substituted.
, variant ? null
}:

assert lib.assertMsg (variant == null)
  "libkrunfw-upstream provides only the default variant, not ${toString variant}";


let
  version = "1.13.1";
  arch = if stdenv.hostPlatform.isAarch64 then "arm64" else "x86_64";
in
stdenv.mkDerivation {
  pname = "smolvm-libs-upstream";
  inherit version;

  src = fetchurl {
    url =
      "https://github.com/smol-machines/smolvm/releases/download/v${version}"
      + "/smolvm-${version}-darwin-${arch}.tar.gz";
    hash = "sha256-2od6KezWYxc6xgh+fW1EBelCwaWsvZKSixENRpfaB88=";
  };

  sourceRoot = "smolvm-${version}-darwin-${arch}";

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib"

    # libkrun and libkrunfw are taken together, from the same release. They are
    # version-coupled: pairing one side with a separately built counterpart
    # aborts at VM start (SIGABRT, exit 134), even when both are the nominally
    # correct versions.
    # Every library from the release, not just libkrun*: upstream's libkrun
    # links libvirglrenderer (which in turn pulls libepoxy and libMoltenVK),
    # and a missing one only surfaces as a dyld failure at first run.
    cp lib/*.dylib "$out/lib/"

    # The kernel banner records the version upstream shipped. Asserting on it
    # makes a silent substitution visible if the release contents ever change.
    # grep -a treats the binary as text; `strings` is not in the build sandbox.
    if ! grep -aq 'Linux version 6.12.95' "$out/lib/libkrunfw.5.dylib"; then
      echo 'libkrunfw does not embed the expected kernel version' >&2
      exit 1
    fi

    for required in libkrun.dylib libkrunfw.5.dylib libvirglrenderer.1.dylib; do
      test -f "$out/lib/$required" \
        || { echo "$required missing from the release archive" >&2; exit 1; }
    done

    runHook postInstall
  '';

  dontFixup = true;

  meta = {
    description = "libkrun and libkrunfw from the upstream SmolVM release, pinned by hash";
    license = with lib.licenses; [ lgpl2Only lgpl21Only ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    # libkrun.nix reads this to derive its own platforms. Upstream publishes a
    # darwin-arm64 artifact, which is what this expression extracts.
    platforms = [ "aarch64-darwin" ];
  };
}
