{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  python3,
  rustc,
  cargo,
  rustPlatform,
  runCommand,
  # bindgen (used by libsqlite3-sys) dlopens libclang at build time.
  libclang,
  # The Meta C++ stack.  nixpkgs (26.11) ships all of these at
  # 2026.07.27.00, *not* the versions the repo currently pins at HEAD
  # (2026-11-08), so expect to either bump these or pin `src` to a matching
  # Sapling release.  See ../../nix/README.md.
  folly,
  fbthrift,
  fb303,
  wangle,
  fizz,
  mvfst,
  edencommon,
  cpptoml,
  libblake3,
  # Third-party C++ deps of folly/fizz/wangle/fbthrift/eden that EdenFS's
  # CMakeLists asks for directly.
  boost,
  fmt,
  gflags,
  glog,
  libevent,
  openssl,
  re2,
  curl,
  zlib,
  zstd,
  xxhash,
  xz,
  libunwind,
  # Local-store / snapshot backends that EdenConfigChecks always requires.
  rocksdb,
  snappy,
  sqlite,
  lmdb,
  # Optional; only used by the integration tests.
  gtest,
  systemd,
  # Phase switches.  Phase 1 (daemon only) is the only configuration that
  # is plausibly buildable today: the Python CLI needs an fb303 compiled
  # with FB303_THRIFT_PYTHON=ON, which nixpkgs' fb303 deliberately does not
  # do.  See ../../nix/README.md for the phased plan.
  enablePython ? false,
  buildTests ? false,
  # Pin to the Sapling 2026-11-03 release: it has the unified `eden/fs` Rust
  # workspace and the ENABLE_THRIFT_PYTHON / BUILD_TESTS switches, but still
  # uses the repo's own (repo-local) thrift helpers, so it builds against
  # nixpkgs' 2026.07.27.00 fbthrift.  The only newer dependency is edencommon
  # (for GlobPath); the flake overrides that.
  # Named `saplingSrc` rather than `src` so `callPackage` doesn't fill it
  # from the deprecated `pkgs.src` alias.
  saplingSrc ? fetchFromGitHub {
    owner = "meta";
    repo = "sapling";
    rev = "3b4d56d3be392d9df1f55d05aed448b542a18d5d";
    hash = "sha256-RfzIcu6wKSXk85GZn52N3mh7Vaj9XA13u+TP0eAaE8c=";
  },
}:

let
  version = "0.2.20261103";

  # `eden/fs` is Cargo workspace `//eden/fs`.  Regenerate with ./update.sh.
  cargoDeps = rustPlatform.importCargoLock {
    lockFile = ./Cargo.lock;
    outputHashes = import ./output-hashes.nix;
  };

  # The thrift-codegen crates (scope*, thrift*, rust*, cpp*, fb303_core*)
  # walk up from their crate directory to find <repo>/thrift/annotation/*.thrift.
  # importCargoLock flattens each crate, so that walk escapes the repo.  Ship
  # the handful of .thrift files the generators need under one root and rewrite
  # the vendored build scripts to point at it.
  thriftRoot = runCommand "edenfs-thrift-root" { } ''
    mkdir -p $out/thrift/annotation
    cp ${fbthrift}/include/thrift/annotation/scope.thrift \
       ${fbthrift}/include/thrift/annotation/thrift.thrift \
       ${fbthrift}/include/thrift/annotation/rust.thrift \
       ${fbthrift}/include/thrift/annotation/cpp.thrift \
       $out/thrift/annotation/
    cp ${fb303.src}/fb303/thrift/fb303_core.thrift $out/
  '';

  # A copy of the vendor directory in which the thrift-codegen crates are
  # dereferenced (so their build scripts run inside our tree) and patched to
  # use thriftRoot.  Everything else stays a symlink.
  cargoVendorFixed = runCommand "edenfs-cargo-vendor-fixed" {
    nativeBuildInputs = [ python3 ];
  } ''
    mkdir -p $out
    for crate in ${cargoDeps}/*; do
      name=$(basename "$crate")
      case "$name" in
        # cxx's crates build.rs does include!("../tools/cargo/build.rs").  The
        # `cxx` vendor entry happens to be the whole cxx repo, so dereference
        # these and repoint the include at that copy below.
        cxx-*|cxxbridge-*)
          cp -rL "$crate" "$out/$name"
          chmod -R u+w "$out/$name"
          ;;
        *)
          if [ -f "$crate/thrift_build.rs" ]; then
            cp -rL "$crate" "$out/$name"
            chmod -R u+w "$out/$name"
            python3 ${./fix-thrift-build.py} "$out/$name/thrift_build.rs" "${thriftRoot}"
          else
            ln -s "$crate" "$out/$name"
          fi
          ;;
      esac
    done

    cxx_repo=$(ls -d "$out"/cxx-[0-9]* | head -1)
    for f in "$out"/cxxbridge-macro-*/build.rs "$out"/cxx-build-*/build.rs \
             "$out"/cxxbridge-cmd-*/build.rs; do
      [ -f "$f" ] && echo "include!(\"$cxx_repo/tools/cargo/build.rs\");" > "$f"
    done
  '';

  # `importCargoLock` returns a directory that (a) symlinks every vendored
  # crate as <name>-<version> and (b) contains a `.cargo/config.toml` that
  # redirects crates.io *and* every git dependency to those symlinks.  That
  # config refers to its vendor directory by the relative name
  # "cargo-vendor-dir", so rewrite it to the absolute store path of our fixed
  # copy and expose it as a CARGO_HOME the CMake build can use.
  cargoHome = runCommand "edenfs-cargo-home" { } ''
    mkdir -p $out
    substitute ${cargoDeps}/.cargo/config.toml $out/config.toml \
      --replace-fail 'directory = "cargo-vendor-dir"' 'directory = "${cargoVendorFixed}"'
  '';
in
stdenv.mkDerivation (finalAttrs: {
  pname = "edenfs";
  src = saplingSrc;
  inherit version;

  # CMake/EdenConfigChecks.cmake calls find_package(CONFIG QUIET) first and
  # only falls back to FetchContent when that fails.  Every dependency below
  # is in nixpkgs, so with FULLY_DISCONNECTED=ON a missing one becomes a
  # hard configure error rather than a surprise download.
  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    python3
    rustc
    cargo
    libclang
  ];

  buildInputs = [
    folly
    fbthrift
    fb303
    wangle
    fizz
    mvfst
    edencommon
    cpptoml
    libblake3
    boost
    fmt
    gflags
    glog
    libevent
    openssl
    re2
    curl
    zlib
    zstd
    xxhash
    xz
    libunwind
    rocksdb
    snappy
    sqlite
    lmdb
    # edencommon's public headers use gtest's FRIEND_TEST macro, so gtest is
    # needed even when BUILD_TESTS is off.
    gtest
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ systemd ];

  cmakeFlags = [
    (lib.cmakeBool "BUILD_TESTS" buildTests)
    (lib.cmakeBool "ENABLE_THRIFT_PYTHON" enablePython)
    (lib.cmakeBool "FETCHCONTENT_FULLY_DISCONNECTED" true)
    # Git repository support is optional; keep it off so configure doesn't
    # chase libgit2.
    (lib.cmakeFeature "ENABLE_GIT" "OFF")
    (lib.cmakeFeature "CMAKE_BUILD_TYPE" "Release")
    # fbthrift's .thrift annotation files; EdenConfigChecks feeds this (and
    # fb303's) to the Rust thrift build scripts via THRIFT_INCLUDE_PATH.
    (lib.cmakeFeature "THRIFT_INCLUDE_DIR" "${fbthrift}/include")
    # Keep the install layout the CMakeLists expect.
    (lib.cmakeFeature "CMAKE_INSTALL_PREFIX" (placeholder "out"))
  ];

  # `eden/fs/Cargo.toml` is autocargo output with ~95 `[patch]` entries that
  # the lock marks unused.  Cargo still loads their git sources during
  # resolution, which needs network, so drop them; the shipped lock was
  # generated from the same fixed-up manifest.
  postPatch = ''
    cp ${./Cargo.lock} eden/fs/Cargo.lock
    python3 ${./trim-patches.py} eden/fs/Cargo.toml eden/fs/Cargo.lock

    # Add a native `edenfsctl mount`; this snapshot only ships the Python one.
    patch -p1 < ${./0001-rust-mount.patch}

    # nixpkgs' fbthrift 2026.07.27.00 names the compiler executable
    # FBThrift::thrift1 (FBThrift::thrift is an interface library); this
    # snapshot expects the newer layout where FBThrift::thrift is the binary.
    substituteInPlace CMake/EdenConfigChecks.cmake \
      --replace-fail '$<TARGET_FILE:FBThrift::thrift>' '$<TARGET_FILE:FBThrift::thrift1>'
  '';

  # The CMake `rust_static_library`/`rust_executable` helpers run `cargo`
  # directly.  Point them at our vendored CARGO_HOME and keep them off the
  # network.  `rust_cxx_bridge` additionally wants a `cxxbridge` matching the
  # `cxx` crate in the lock (1.0.198); it shells out to
  # `cargo install cxxbridge-cmd --version 1.0.198`, which resolves from the
  # vendored directory source because CARGO_HOME is set here.
  preConfigure = ''
    export CARGO_HOME=$NIX_BUILD_TOP/cargo-home
    mkdir -p "$CARGO_HOME"
    cp ${cargoHome}/config.toml "$CARGO_HOME/config.toml"
    export CARGO_NET_OFFLINE=true

    # openssl-sys gets pulled in with the `vendored` feature by curl-sys' or
    # rusqlite's static-ssl bundles; force it to use the system OpenSSL that
    # the C++ half links against too (avoids shipping a second copy and the
    # perl build dependency).
    export OPENSSL_NO_VENDOR=1

    # bindgen (libsqlite3-sys) needs to find libclang.so.
    export LIBCLANG_PATH=${lib.getLib libclang}/lib
  '';

  passthru = {
    inherit cargoDeps cargoHome;
    updateScript = ./update.sh;
  };

  meta = {
    description = "EdenFS virtual filesystem daemon and edenfsctl CLI";
    homepage = "https://github.com/facebook/sapling";
    license = lib.licenses.gpl2Plus;
    platforms = lib.platforms.linux;
    maintainers = [ ];
  };
})
