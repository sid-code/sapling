# Nix packaging for EdenFS

A Nix build of **EdenFS** from the open-source CMake/cargo path (Buck is
deliberately ignored).  Phase 1 — the daemon, the setuid helper, the Rust CLI
launcher and the Rust static libraries — builds and links.

```console
$ nix build .#edenfs
$ tree -L 2 result
result/bin/edenfs
result/bin/edenfsctl
result/bin/edenfs_privhelper
result/lib/libbackingstore.a
result/lib/libedenfs_ffi.a
result/lib/libedenfs_staticlib_rs.a
```

```
nix/edencommon.nix        # edencommon 2026.11.09.00 (GlobPath), see below
nix/edenfs/
  package.nix             # the derivation (CMake + cargo, Phase 1 flags)
  Cargo.lock              # eden/fs workspace lock for the pinned source
  output-hashes.nix       # importCargoLock outputHashes for the git deps
  update.sh               # regenerate Cargo.lock + output-hashes.nix
  trim-patches.py         # drop [patch] entries the lock marks unused
  fix-thrift-build.py     # repoint vendored thrift_build.rs at a thrift root
flake.nix                 # repo-root flake: packages.{edenfs,cargo-deps,default}
```

## Why these versions

EdenFS is tightly coupled to Meta's C++ stack.  nixpkgs (even
nixpkgs-unstable in 2026-11) ships `folly`, `fbthrift`, `fb303`, `wangle`,
`fizz`, `mvfst` and `edencommon` at **2026.07.27.00**.

* Repo HEAD (2026-11-08) can't build against that: it uses fbthrift's newer
  `thrift_add_library()` and an edencommon header (`GlobPath.h`) that only
  appeared after 2026.10.26.
* The 2026-08-11 tag also needs `GlobPath`.
* We therefore pin the source to the **2026-11-03 release**
  (`3b4d56d3`), which has the unified `eden/fs` Rust workspace and the
  `ENABLE_THRIFT_PYTHON` / `BUILD_TESTS` switches, but still uses the repo's
  own repo-local thrift helpers, so it works with the packaged fbthrift.
  The only newer dependency it needs is `edencommon`, which the flake
  overrides with `nix/edencommon.nix` (2026.11.09.00, the first tag with
  `GlobPath.h`; it compiles fine against the 2026.07.27 stack).

Phase-1 flags: `ENABLE_THRIFT_PYTHON=OFF`, `BUILD_TESTS=OFF`,
`FETCHCONTENT_FULLY_DISCONNECTED=ON`, `ENABLE_GIT=OFF`.

## Rust half

EdenFS does not commit a `Cargo.lock`, and `eden/fs/Cargo.toml` pulls several
git repositories behind `branch = "main"`.  `update.sh` generates a lock and
records a `nix-prefetch-git --fetch-submodules` hash per git package
(`importCargoLock`'s `fetchgit` fetches submodules).  The pinned lock has
**795 packages, 9 git repos, 56 git packages**.

Four issues had to be fixed to compile the vendored sources (all in
`package.nix`):

* **Unused `[patch]` entries** (`postPatch`): autocargo lists ~95 patches the
  lock marks unused, but cargo still loads their git sources while resolving,
  which needs network.  `trim-patches.py` drops them.
* **Thrift codegen crates** (`scope*`, `thrift*`, `rust*`, `cpp*`,
  `fb303_core*`): their `thrift_build.rs` walks up to
  `<repo>/thrift/annotation/*.thrift`.  `importCargoLock` flattens each crate,
  so the walk escapes the repo.  `cargoVendorFixed` dereferences those crates
  into a writable vendor dir and `fix-thrift-build.py` points them at a
  prepared `thriftRoot` containing the four annotation files and
  `fb303_core.thrift`.
* **cxx build scripts**: `include!("../tools/cargo/build.rs")`; the `cxx`
  vendor entry happens to be the whole cxx repo, so the fixer repoints the
  include at it.
* **bindgen / OpenSSL**: `libclang` is needed by `libsqlite3-sys`, and
  `OPENSSL_NO_VENDOR=1` avoids a second OpenSSL from `curl-sys`/rusqlite.

`xz` (liblzma) and `libunwind` had to be added to `buildInputs` for
`edenfs`/`edenfs_privhelper` to resolve at runtime.

## Native `edenfsctl mount`

This snapshot only ships a Python `edenfsctl mount`, so `0001-rust-mount.patch`
adds a native one (applied in `postPatch`):

```console
$ edenfsctl mount <MOUNT_POINT> --repo <REPO> [--rev <COMMIT>] [--read-only]
```

It registers the checkout in `~/.eden/config.json`, writes
`~/.eden/clients/<name>/config.toml` and a version-2 `SNAPSHOT`, then calls the
daemon's `mount` thrift method.  `--repo` must be a Sapling/Mercurial
repository, i.e. contain `.hg` (Mercurial) or `.sl` (Sapling's `sl init`
creates `.sl`).  The commit defaults to the repository's current parent (via
`sl log -r .`/`hg log -r .`); pass `--rev` if neither tool is installed.
Git checkouts are not supported (the build sets `ENABLE_GIT=OFF`).  The
default config dir is `~/.eden` in the OSS build (matching the daemon);
Meta's `~/local/.eden` is kept under `cfg(fbcode_build)`.

## NixOS module

`flake.nix` exposes `nixosModules.edenfs` (aliased as `nixosModules.default`)
and an overlay providing `pkgs.edenfs`:

```nix
{
  inputs.sapling.url = "path:/path/to/sapling";

  outputs = { self, nixpkgs, sapling }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        sapling.nixosModules.edenfs
        {
          services.edenfs = {
            enable = true;
            # optional: mount checkouts once the daemon is up
            mounts = [
              { mountPoint = "/home/me/src/proj"; repo = "/home/me/src/proj-repo"; }
            ];
          };
        }
      ];
    };
  };
}
```

The module wires up:

* `security.wrappers.edenfs_privhelper` — the setuid-root helper (Nix store
  files cannot carry setuid bits).
* `boot.kernelModules = [ "fuse" ]`.
* `/etc/eden/config.d/edenfs.ini`, carrying `services.edenfs.extraConfig`.
* `edenfs`/`edenfsctl` in `environment.systemPackages`.
* A per-user `systemd.user.services.edenfs` running
  `edenfs --foreground --privhelper_path=/run/wrappers/bin/edenfs_privhelper`.
* Optional `services.edenfs.mounts`, run through `edenfsctl mount` after the
  daemon starts (best effort).

EdenFS is per-user, so the daemon lives in the user manager: it starts when
that user's systemd instance starts (on login), or at boot with
`users.users.<name>.linger = true`.

`mounts` derive the commit from the repository's current parent via
`sl`/`hg`; install one of them (e.g. `environment.systemPackages = [ pkgs.sapling ];`)
or set `rev` explicitly.

## Caveats

* **`edenfsctl` is a launcher for the other commands.**  Query/debug commands
  (`status`, `list`, `pid`, `du`, …) run natively; everything else is
  forwarded to a Python `edenfsctl.real`, which is not built in Phase 1.  The
  native `mount` above is the exception.
* **Runtime.**  The NixOS module handles the setuid privhelper, `/dev/fuse`
  and `/etc/eden`.  Without it, `edenfs_privhelper` must be setuid root (e.g.
  `security.wrappers`) and the daemon started with
  `--privhelper_path=/run/wrappers/bin/edenfs_privhelper`; otherwise the mount
  reaches the daemon and fails with `failed to open filesystem context for
  \`fuse\`: Operation not permitted`.


## Phased plan

- **Phase 1** (done): daemon + setuid helper + Rust CLI launcher + Rust
  static libraries.
- **Phase 2**: Python CLI and C++ tests.  Needs an fbthrift built with
  `thriftpy`, an fb303 built with `FB303_THRIFT_PYTHON`, and `thrift-python`.
- **Phase 3**: `services.edenfs` NixOS module (setuid wrapper, `/etc/eden`,
  fuse, systemd unit).

## Regenerating the lock

`./nix/edenfs/update.sh` fetches the pinned snapshot, regenerates
`eden/fs/Cargo.lock` (dropping unused patches), and rewrites
`output-hashes.nix`.  Keep `SNAPSHOT_REV` in the script in sync with
`saplingSrc` in `package.nix`.
