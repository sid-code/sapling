# NixOS module for EdenFS.
#
# EdenFS is a per-user filesystem: the daemon runs as the user and the
# setuid-root `edenfs_privhelper` performs the privileged FUSE operations.
# This module therefore installs the privhelper as a setuid wrapper, makes
# `edenfsctl` available, and runs a systemd *user* service for each user.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.edenfs;

  # The setuid wrapper created by security.wrappers below.
  privhelper = "/run/wrappers/bin/edenfs_privhelper";

  defaultPackage = pkgs.callPackage ./package.nix {
    edencommon = pkgs.callPackage ../edencommon.nix { };
  };

  mountArgs = m:
    lib.concatStringsSep " " (
      [
        "${cfg.package}/bin/edenfsctl"
        "mount"
        (lib.escapeShellArg m.mountPoint)
        "--repo"
        (lib.escapeShellArg m.repo)
      ]
      ++ lib.optional (m.rev != null) "--rev ${lib.escapeShellArg m.rev}"
      ++ lib.optional m.readOnly "--read-only"
    );

  mountScript = pkgs.writeShellScript "edenfs-mounts" ''
    ${lib.concatMapStringsSep "\n" (m: ''
      ${mountArgs m} || echo "edenfs: failed to mount ${m.mountPoint}" >&2
    '') cfg.mounts}
  '';
in
{
  options.services.edenfs = {
    enable = lib.mkEnableOption "the EdenFS virtual filesystem daemon";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = ''
        The EdenFS package to use (the `edenfs` flake output).
      '';
    };

    enableUserService = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Start the EdenFS daemon as a systemd user service.  The daemon runs as
        the logged-in user; the setuid privhelper performs the FUSE mount.
      '';
    };

    mounts = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            mountPoint = lib.mkOption {
              type = lib.types.str;
              description = "Where to mount the checkout.";
            };
            repo = lib.mkOption {
              type = lib.types.str;
              description = "The backing Sapling/Mercurial repository (a directory containing .hg).";
            };
            rev = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                The commit to check out.  Defaults to the repository's current
                parent (requires `sl` or `hg` on PATH).
              '';
            };
            readOnly = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Mount the checkout read-only.";
            };
          };
        }
      );
      default = [ ];
      description = ''
        Checkouts to mount after the user service starts.  Best effort: a
        failed mount is logged but does not fail the service.
      '';
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Extra configuration appended to `/etc/eden/config.d/edenfs.ini`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # FUSE mounting needs root.  Nix store files cannot be setuid, so wrap the
    # privhelper (this creates /run/wrappers/bin/edenfs_privhelper).
    security.wrappers.edenfs_privhelper = {
      source = "${cfg.package}/bin/edenfs_privhelper";
      owner = "root";
      group = "root";
      setuid = true;
    };

    boot.kernelModules = [ "fuse" ];

    # The daemon reads system config from /etc/eden/config.d/*.
    environment.etc."eden/config.d/edenfs.ini".text = ''
      # Managed by NixOS (services.edenfs.extraConfig).
    '' + cfg.extraConfig;

    environment.systemPackages = [ cfg.package ];

    systemd.user.services.edenfs = lib.mkIf cfg.enableUserService {
      description = "EdenFS virtual filesystem daemon";
      wantedBy = [ "default.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = lib.concatStringsSep " " [
          "${cfg.package}/bin/edenfs"
          "--foreground"
          "--edenfsctlPath"
          "${cfg.package}/bin/edenfsctl"
          "--privhelper_path"
          privhelper
        ];
        # The daemon needs the user's home (checkouts and ~/.eden) and
        # /dev/fuse; do not sandbox those away.
        ProtectHome = false;
        PrivateDevices = false;
        Restart = "on-failure";
        RestartSec = 2;
      }
      // lib.optionalAttrs (cfg.mounts != [ ]) {
        # Type=simple: the daemon has bound its socket by the time ExecStart
        # returns, but edenfsctl also retries the connection.
        ExecStartPost = mountScript;
      };
    };
  };
}
