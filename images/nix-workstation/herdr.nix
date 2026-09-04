# Herdr, the terminal workspace manager that owns agent processes, worktrees,
# shells and sessions inside a workbench.
#
# Pinned to the exact release the plan names, with the SHA-256 upstream
# publishes in herdr.dev/latest.json. Verified to match:
#
#   f55610658e1c2e0d2aaef730b4b2ab885f7f8ba00285ab372bfb14f2e3d5b40d
#
# This is a prebuilt binary rather than a source build. Upstream publishes no
# reproducible build, and the guest needs a Linux aarch64 executable; the hash
# pin is what makes it immutable and verifiable.
{ lib
, stdenv
, fetchurl
, autoPatchelfHook
, zlib
, openssl
}:

let
  version = "0.8.2";

  # The guest is Linux whatever the host is.
  platform =
    if stdenv.hostPlatform.isAarch64 then "linux-aarch64" else "linux-x86_64";

  hashes = {
    "linux-aarch64" = "sha256-9VYQZY4cLg0qrvcwtLKriF9/i6AChas3K/sU8uPVtA0=";
    "linux-x86_64" = "sha256-l2FQoU1JDJSyQ+ouGn6y37Z/EuNrGC25CTb2co5q7PQ=";
  };
in
stdenv.mkDerivation {
  pname = "herdr";
  inherit version;

  src = fetchurl {
    url =
      "https://github.com/herdrdev/herdr/releases/download/v${version}/herdr-${platform}";
    hash = hashes.${platform};
  };

  dontUnpack = true;
  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ zlib openssl stdenv.cc.cc.lib ];

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/herdr"
    runHook postInstall
  '';

  meta = {
    description = "Terminal workspace manager for AI coding agents";
    homepage = "https://herdr.dev";
    mainProgram = "herdr";
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "aarch64-linux" "x86_64-linux" ];
  };
}
