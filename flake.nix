{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default-linux";
    flake-utils = {
      url = "github:numtide/flake-utils";
      inputs.systems.follows = "systems";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    let
      overlays = [
        (final: prev: {
          buongiorno = prev.callPackage ./nix/package.nix { };
        })
      ];
    in
    {
      overlays.default = builtins.head overlays;

      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.programs.buongiorno;
        in
        {
          options.programs.buongiorno = {
            enable = lib.mkEnableOption "buongiorno" // {
              description = ''
                Configure greetd to use buongiorno as greeter.
                This sets `services.greetd.enable` to `true` and sets
                `services.greetd.default_session.command`.
              '';
            };

            command = lib.mkOption {
              type = lib.types.str;
              default = "";
            };

            username = lib.mkOption {
              type = lib.types.str;
              default = "";
            };
          };

          config = lib.mkIf cfg.enable {
            nixpkgs.overlays = [ self.overlays.default ];

            services.greetd = {
              enable = true;
              settings.default_session.command = "${pkgs.buongiorno}/bin/buongiorno -u '${cfg.username}' -c '${cfg.command}'";
            };
          };
        };

    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system overlays; };
        zigDeps = pkgs.callPackage ./nix/deps.nix { };
      in
      {
        packages.default = pkgs.buongiorno;

        checks = {
          formatting = pkgs.runCommand "buongiorno-formatting" { nativeBuildInputs = [ pkgs.zig_0_13 ]; } ''
            cp -r ${./.} source
            chmod -R u+w source
            cd source
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
            zig fmt --check build.zig build.zig.zon src
            touch "$out"
          '';
          tests = pkgs.buongiorno;
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [ zig_0_13 ];

          shellHook = ''
            export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-global-cache"
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
            rm -rf "$ZIG_GLOBAL_CACHE_DIR/p"
            ln -s ${zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
          '';
        };
      }
    );
}
