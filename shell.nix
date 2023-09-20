with import <nixpkgs> { };
let 
in
stdenv.mkDerivation {
  name = "okameron";
  buildInputs = [
    lua5_4_compat
  ];
}
