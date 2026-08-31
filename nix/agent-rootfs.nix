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

  # The utilities the agent shells out to, taken as Alpine packages rather than
  # nixpkgs' static cross builds: pkgsStatic for musl is largely uncached and
  # rebuilds an entire toolchain from source, and these are already built
  # against the exact musl this minirootfs ships.
  #
  # crun is required for OCI container execution and must land at /usr/bin/crun,
  # which is where the agent looks for it. The rest cover filesystem resize
  # (e2fsprogs) and the queries the agent makes (jq, util-linux-misc).
  #
  # An .apk is a gzipped tar, so each is simply unpacked over the rootfs in
  # dependency order.
  alpineMirror = "https://dl-cdn.alpinelinux.org/alpine/v${alpineVersion}";

  apk = { name, repo, hash }:
    fetchurl {
      url = "${alpineMirror}/${repo}/${guestArch}/${name}";
      inherit hash;
    };

  guestPackages = [
    (apk {
      name = "crun-1.12-r0.apk";
      repo = "community";
      hash = "sha256-TuaWB1kOcvq2PMbFAsBEbBH/ZXXiJjJWBgaYa29wnsM=";
    })
    (apk {
      name = "libseccomp-2.5.5-r0.apk";
      repo = "main";
      hash = "sha256-iWHtY53DIO8N5XqEwQctkxEvo/psokoXhcjF08a5JC8=";
    })
    (apk {
      name = "yajl-2.1.0-r9.apk";
      repo = "main";
      hash = "sha256-YNgvbqGzxH1S7w75jA67HffJG8btYmT/QTDitRLBWSU=";
    })
    (apk {
      name = "libcap2-2.69-r1.apk";
      repo = "main";
      hash = "sha256-gtv6Yu1fA7klrlEGmqo/87NzFKjwl8INmiO3F/HJZQs=";
    })
    (apk {
      name = "jq-1.7.1-r0.apk";
      repo = "main";
      hash = "sha256-KHsEwjOtUeYZ+mo3WvJOgJaa8lvu+azmx3aH71mkodw=";
    })
    (apk {
      name = "oniguruma-6.9.9-r0.apk";
      repo = "main";
      hash = "sha256-uzyAr6iUsYn1f/fXvbUNVEqDE2N8i7nPa77pxUl7lWI=";
    })
    (apk {
      name = "e2fsprogs-1.47.0-r5.apk";
      repo = "main";
      hash = "sha256-QRdVX2GtrPj1Ggw4sXyKMO9scAlBr8CoOztOApsicJs=";
    })
    (apk {
      name = "e2fsprogs-extra-1.47.0-r5.apk";
      repo = "main";
      hash = "sha256-oWiJqxNAO1CdYFfU7gQLC8/ECWFgfq9o2BLiWQTIdbA=";
    })
    (apk {
      name = "util-linux-misc-2.39.3-r0.apk";
      repo = "main";
      hash = "sha256-dcIET05AfDYQIqVE508oJzxuHtvQwHT5rXYUPeuYW5Q=";
    })
  ];
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

    # Alpine packages. Each .apk is a gzipped tar; the metadata entries
    # (.PKGINFO, .SIGN.*) are package bookkeeping and are not wanted in the
    # rootfs.
    for pkg in ${lib.concatStringsSep " " (map toString guestPackages)}; do
      tar -xzf "$pkg" -C rootfs --exclude='.PKGINFO' --exclude='.SIGN.*' \
        --exclude='.pre-install' --exclude='.post-install' --exclude='.trigger' 2>/dev/null || true
    done

    # The agent spawns crun by absolute path.
    test -x rootfs/usr/bin/crun \
      || { echo 'crun missing from rootfs/usr/bin after package extraction' >&2; exit 1; }

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
