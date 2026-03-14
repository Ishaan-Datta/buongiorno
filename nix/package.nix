{
  stdenv,
  callPackage,
  zig_0_13,
}:

stdenv.mkDerivation {
  pname = "buongiorno";
  version = "0.1.3";

  src = ./..;

  nativeBuildInputs = [
    zig_0_13.hook
  ];

  preBuild = ''
    export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-global-cache"
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
    ln -sfn ${callPackage ./deps.nix { }} "$ZIG_GLOBAL_CACHE_DIR/p"
  '';
}
