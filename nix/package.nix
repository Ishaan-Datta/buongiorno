{ stdenv
, callPackage
, zig_0_13
}:
stdenv.mkDerivation {
  pname = "buongiorno";
  version = "0.1.3";

  src = ./..;

  nativeBuildInputs = [
    zig_0_13.hook
  ];

  postPatch = ''
    ln -s ${callPackage ./deps.nix {}} $ZIG_GLOBAL_CACHE_DIR/p
  '';
}
