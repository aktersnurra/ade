{
  lib,
  stdenv,
  fetchurl,
  src,
  pkgsCross,
  flex,
  bison,
  bc,
  cpio,
  perl,
  elfutils,
  libelf,
  python3,
  variant ? null,
}:

assert lib.elem variant [
  null
  "sev"
  "tdx"
];

let
  linuxCrossCc = if stdenv.hostPlatform.isAarch64
    then pkgsCross.aarch64-multiplatform.stdenv.cc
    else pkgsCross.gnu64.stdenv.cc;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "libkrunfw" + lib.optionalString (variant != null) "-${variant}";
  version = "5.5.0";

  inherit src;

  # The kernel version is pinned by the libkrunfw revision's Makefile, not by
  # this expression. It must be updated in lockstep with libkrunfw-src: the
  # Nix build has no network, so a mismatch fails with "curl: command not
  # found" when the Makefile tries to fetch the tarball itself.
  kernelSrc = fetchurl {
    url = "mirror://kernel/linux/kernel/v6.x/linux-6.12.95.tar.xz";
    hash = "sha256-qejFH8seaV0dNd3liGy6V5y28pyWRsWInznWOEHUufY=";
  };

  postPatch = ''
    # The Nix build has no network, so the Makefile's kernel download is
    # replaced by a symlink to the fixed-hash tarball. Upstream's expression
    # matched the exact old command string; the current Makefile adds retry
    # flags, so match the whole recipe line by its target instead and assert the
    # rewrite happened rather than failing later with "curl: command not found".
    substituteInPlace Makefile \
      --replace-fail 'curl -fL --retry 5 --retry-delay 5 --retry-all-errors $(KERNEL_REMOTE) -o $(KERNEL_TARBALL)' \
                     'ln -s $(kernelSrc) $(KERNEL_TARBALL)'

    grep -q 'ln -s $(kernelSrc)' Makefile \
      || { echo 'kernel download was not replaced; Makefile recipe changed' >&2; exit 1; }
  '' + lib.optionalString stdenv.hostPlatform.isDarwin ''
    substituteInPlace Makefile \
      --replace 'for patch in $(KERNEL_PATCHES); do patch -p1 -d $(KERNEL_SOURCES) < "$$patch"; done' 'for patch in $(KERNEL_PATCHES); do patch -p1 -d $(KERNEL_SOURCES) < "$$patch"; done; perl -0pi -e "s/typedef struct \\{\\n\\t__u8 b\\[16\\];\\n\\} uuid_t;/#ifndef __APPLE__\\ntypedef struct {\\n\\t__u8 b[16];\\n} uuid_t;\\n#endif/; s/uuid->b\\[/(*uuid)[/g" $(KERNEL_SOURCES)/scripts/mod/file2alias.c' \
      --replace '$(MAKE) olddefconfig' '$(MAKE) HOSTCC=cc HOSTCFLAGS=-I../host-include olddefconfig' \
      --replace '$(MAKE) $(MAKEFLAGS) $(KERNEL_FLAGS)' '$(MAKE) HOSTCC=cc HOSTCFLAGS=-I../host-include $(MAKEFLAGS) $(KERNEL_FLAGS)'
  '';

  preBuild = lib.optionalString stdenv.hostPlatform.isDarwin ''
    mkdir -p host-include
    cp ${linuxCrossCc.libc.dev}/include/elf.h host-include/
    cat > host-include/byteswap.h <<'EOF'
    #pragma once
    #define bswap_16(x) __builtin_bswap16(x)
    #define bswap_32(x) __builtin_bswap32(x)
    #define bswap_64(x) __builtin_bswap64(x)
    EOF
    export HOSTCC=cc
  '';

  nativeBuildInputs = [
    stdenv.cc
    flex
    bison
    bc
    cpio
    perl
    python3
    python3.pkgs.pyelftools
  ] ++ lib.optionals stdenv.hostPlatform.isDarwin [
    linuxCrossCc
    libelf
  ];

  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    elfutils
  ];

  makeFlags = [
    "PREFIX=${placeholder "out"}"
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [
    "OS=Linux"
    "ARCH=${stdenv.hostPlatform.linuxArch}"
    "CROSS_COMPILE=${linuxCrossCc.targetPrefix}"
  ]
  ++ lib.optionals (variant == "sev") [
    "SEV=1"
  ]
  ++ lib.optionals (variant == "tdx") [
    "TDX=1"
  ];

  # Upstream's expression passes OS=Linux on macOS so the guest kernel
  # cross-builds. But OS also selects the *host* library format, so the result
  # is an ELF .so the macOS loader rejects with "slice is not valid mach-o
  # file", and smolvm then reports libkrunfw as missing entirely.
  #
  # The kernel bundle (kernel.c) is plain, OS-independent C; only the final link
  # differs. So the Linux pass produces the bundle, and this step relinks it
  # with the native compiler into the Mach-O dylib the loader expects, under the
  # names the Makefile defines for Darwin.
  postBuild = lib.optionalString stdenv.hostPlatform.isDarwin ''
    abi_version="$(sed -n 's/^ABI_VERSION[[:space:]]*=[[:space:]]*//p' Makefile | head -n1)"
    : "''${abi_version:=5}"

    cc -fPIC -DABI_VERSION="$abi_version" -shared \
      -o "libkrunfw.$abi_version.dylib" kernel.c
    install_name_tool -id "libkrunfw.$abi_version.dylib" "libkrunfw.$abi_version.dylib"
  '';

  postInstall = lib.optionalString stdenv.hostPlatform.isDarwin ''
    abi_version="$(sed -n 's/^ABI_VERSION[[:space:]]*=[[:space:]]*//p' Makefile | head -n1)"
    : "''${abi_version:=5}"

    mkdir -p "$out/lib"
    install -m 755 "libkrunfw.$abi_version.dylib" "$out/lib/"
    ln -sf "libkrunfw.$abi_version.dylib" "$out/lib/libkrunfw.dylib"
  '';

  # Fixes https://github.com/containers/libkrunfw/issues/55
  env = lib.optionalAttrs stdenv.targetPlatform.isAarch64 {
    NIX_CFLAGS_COMPILE = "-march=armv8-a+crypto";
  };

  enableParallelBuilding = true;

  meta = {
    description = "Dynamic library bundling the guest payload consumed by libkrun";
    homepage = "https://github.com/smol-machines/libkrunfw";
    license = with lib.licenses; [
      lgpl2Only
      lgpl21Only
    ];
    platforms = [
      "x86_64-linux"
    ]
    ++ lib.optionals (variant == null) [
      "aarch64-linux"
      "riscv64-linux"
      "aarch64-darwin"
      "x86_64-darwin"
    ];
  };
})
