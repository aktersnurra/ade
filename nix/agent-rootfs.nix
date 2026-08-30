# The SmolVM guest agent rootfs.
#
# Upstream builds this with scripts/build-agent-rootfs.sh, which on macOS
# assembles the tree by *running smolvm* -- impossible before a rootfs exists.
# The escape upstream uses is a prebuilt release artifact, which carries no
# signature or provenance.
#
# This derivation assembles the same tree declaratively from pinned inputs: the
# Alpine minirootfs, crane, the guest utilities the agent shells out to, and the
# cross-compiled agent. Every input is fixed-hash, and no VM is needed to build
# it.
{ lib
, stdenv
, fetchurl
, smolvm-agent
, gnutar
, gzip
}:

let
  alpineVersion = "3.19";
  alpinePatch = "3.19.0";
  craneVersion = "0.19.0";

  guestArch = if stdenv.hostPlatform.isAarch64 then "aarch64" else "x86_64";
  craneArch = if stdenv.hostPlatform.isAarch64 then "arm64" else "x86_64";

  minirootfs = fetchurl {
    url =
      "https://dl-cdn.alpinelinux.org/alpine/v${alpineVersion}/releases/${guestArch}"
      + "/alpine-minirootfs-${alpinePatch}-${guestArch}.tar.gz";
    hash = "sha256-7m01l8B45QqDei0SRZTEOZV/vZ5lPRKGr7NVxDNw0NE=";
  };

  crane = fetchurl {
    url =
      "https://github.com/google/go-containerregistry/releases/download/v${craneVersion}"
      + "/go-containerregistry_Linux_${craneArch}.tar.gz";
    hash = "sha256-1DmVfBqda8CHC+kh4ldTp/pnvysmkbd85IpvwlvHGaA=";
  };

  # The utilities the agent shells out to (jq, e2fsprogs, util-linux, crun) are
  # deliberately NOT taken from nixpkgs' static cross builds: pkgsStatic for
  # musl is largely uncached, so it rebuilds a whole toolchain from source for
  # tools the guest only needs for specific operations.
  #
  # The Alpine minirootfs already ships busybox, which covers the basic
  # utilities. Filesystem resize and OCI container execution need the real
  # packages; those are layered in separately once boot is qualified.
in
stdenv.mkDerivation {
  pname = "smolvm-agent-rootfs";
  version = "1.13.1";

  dontUnpack = true;
  nativeBuildInputs = [ gnutar gzip ];

  buildPhase = ''
    runHook preBuild

    mkdir -p rootfs
    tar -xzf ${minirootfs} -C rootfs

    mkdir -p rootfs/usr/local/bin
    tar -xzf ${crane} -C rootfs/usr/local/bin crane

    install -m 0755 ${smolvm-agent}/bin/smolvm-agent rootfs/usr/local/bin/smolvm-agent

    # The agent is the guest init: it sets up overlayfs and pivot_root itself
    # before starting the vsock listener, so busybox init is replaced.
    rm -f rootfs/sbin/init
    ln -s /usr/local/bin/smolvm-agent rootfs/sbin/init

    # Mount points the agent creates before any writable overlay exists. On a
    # read-only rootfs those create_dir_all calls fail, the mounts fail, and the
    # VM boots without its persistent overlay, so they are baked in here.
    for dir in overlay storage newroot virtiofs rosetta; do
      mkdir -p "rootfs/mnt/$dir"
    done
    mkdir -p rootfs/storage rootfs/etc/init.d rootfs/run

    echo "nameserver 1.1.1.1" > rootfs/etc/resolv.conf

    # A build artifact, not runtime state.
    rm -f rootfs/run/seatd.sock

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -a rootfs/. "$out/"

    # The stock minirootfs ships a few owner-only paths. Left alone they make
    # the tree unreadable to the user running smolvm once it lives under a
    # system prefix, which breaks pack creation. Widening them discloses
    # nothing: this is a public build artifact with no secrets.
    chmod 755 "$out" || true
    chmod 755 "$out/root" || true
    chmod 644 "$out/etc/shadow" || true

    for dir in bin sbin usr/bin usr/sbin usr/local/bin usr/local/sbin; do
      [ -d "$out/$dir" ] || continue
      find "$out/$dir" -type f -exec chmod 755 {} +
    done

    runHook postInstall
  '';

  # The tree is a guest filesystem. Host fixup would rewrite interpreters and
  # strip binaries built for a different libc.
  dontFixup = true;

  meta = {
    description = "SmolVM guest agent rootfs, assembled from pinned inputs";
    license = lib.licenses.asl20;
  };
}
