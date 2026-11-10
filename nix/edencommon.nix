# edencommon newer than the 2026.07.27.00 that nixpkgs ships.
#
# Sapling 2026-11 (the snapshot edenfs pins) needs
# `eden/common/utils/GlobPath.h`, which edencommon only gained after
# 2026.10.26.  This is otherwise a copy of nixpkgs'
# pkgs/by-name/ed/edencommon/package.nix at a newer tag.
{
  lib,
  stdenv,

  fetchFromGitHub,

  cmake,
  ninja,

  glog,
  gflags,
  folly,
  fb303,
  wangle,
  fbthrift,
  gtest,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "edencommon";
  version = "2026.11.09.00";

  outputs = [
    "out"
    "dev"
  ];

  src = fetchFromGitHub {
    owner = "facebookexperimental";
    repo = "edencommon";
    tag = "v${finalAttrs.version}";
    hash = "sha256-RY4bjGC5Ox6Dqute1byGwFTIrlLQDOpW03vzDom+Pyg=";
  };

  nativeBuildInputs = [
    cmake
    ninja
  ];

  buildInputs = [
    glog
    gflags
    folly
    fb303
    wangle
    fbthrift
    gtest
  ];

  cmakeFlags = [
    (lib.cmakeBool "BUILD_SHARED_LIBS" (!stdenv.hostPlatform.isStatic))

    (lib.cmakeBool "CMAKE_INSTALL_RPATH_USE_LINK_PATH" true)

    (lib.cmakeFeature "INCLUDE_INSTALL_DIR" "${placeholder "dev"}/include")
    (lib.cmakeFeature "LIB_INSTALL_DIR" "${placeholder "out"}/lib")
    (lib.cmakeFeature "CMAKE_INSTALL_DIR" "${placeholder "dev"}/lib/cmake/edencommon")
  ];

  # edencommon's own tests are not needed to build edenfs.
  doCheck = false;

  postPatch = ''
    # The CMake build requires the FBThrift Python support even though it is
    # not used.
    substituteInPlace CMakeLists.txt \
      --replace-fail \
        'find_package(FBThrift CONFIG REQUIRED COMPONENTS cpp2 py)' \
        'find_package(FBThrift CONFIG REQUIRED COMPONENTS cpp2)'

    # fmt v12.2.0 changed fmt/core.h so it no longer pulls in <string>.
    sed -e '1i #include <string>' -i eden/common/utils/String.h
  '';

  meta = {
    description = "Shared library for Meta's source control filesystem tools (EdenFS and Watchman)";
    homepage = "https://github.com/facebookexperimental/edencommon";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
})
