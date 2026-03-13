{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default-linux";
    flake-utils = {
      url = "github:numtide/flake-utils";
      inputs.systems.follows = "systems";
    };
  };

  outputs = { nixpkgs, flake-utils, ... }:
  let
    overlays = [
      (final: prev: {
        buongiorno = prev.callPackage ./nix/package.nix {};
      })
    ];
  in
  flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs { inherit overlays system; };
    in
    {
      packages.default = pkgs.buongiorno;

      devShells.default = pkgs.mkShell {
        nativeBuildInputs = with pkgs; [
          zig
        ];
      };

      nixosModules.default = { config, lib, ... }:
      let
        cfg = config.programs.buongiorno;
      in
      {
        options.programs.buongiorno = {
          enable = lib.mkEnableOption "buongiorno" // {
            description = ''
              Configure greetd to use buongiorno as greeter.
              This sets `services.greetd.enable` to `true` and sets `services.greetd.default_session.command`.
              See also `programs.buongiorno.command` and `programs.buongiorno.username`.
            '';
          };
          command = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = ''
              Append `-c '<command>'` to `services.greetd.default_session.command`.
              Note that single quotes are always added around the value.
            '';
          };
          username = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = ''
              Append `-u '<username>'` to `services.greetd.default_session.command`.
              Note that single quotes are always added around the value.
            '';
          };
        };

        config = lib.mkIf cfg.enable {
          services.greetd = {
            enable = true;
            settings.default_session.command = "${pkgs.buongiorno}/bin/buongiorno -u '${cfg.username}' -c '${cfg.command}'";
          };
        };
      };
    }
  );
}
