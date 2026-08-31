# Upstream's published libkrunfw, extracted from the SmolVM release artifact.
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
}:

let
  version = "1.13.1";
  arch = if stdenv.hostPlatform.isAarch64 then "arm64" else "x86_64";
in
stdenv.mkDerivation {
  pname = "libkrunfw-upstream";
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
    cp lib/libkrunfw.*.dylib "$out/lib/"
    cp lib/libkrunfw.dylib "$out/lib/" 2>/dev/null || true

    # The kernel banner records the version upstream shipped. Asserting on it
    # makes a silent substitution visible if the release contents ever change.
    # grep -a treats the binary as text; `strings` is not in the build sandbox.
    if ! grep -aq 'Linux version 6.12.95' "$out/lib/libkrunfw.5.dylib"; then
      echo 'libkrunfw does not embed the expected kernel version' >&2
      exit 1
    fi

    runHook postInstall
  '';

  dontFixup = true;

  meta = {
    description = "libkrunfw from the upstream SmolVM release, pinned by hash";
    license = with lib.licenses; [ lgpl2Only lgpl21Only ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
