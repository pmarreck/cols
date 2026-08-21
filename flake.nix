{
  description = "cols - extract columns from line-oriented text by number, extremely fast";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = zig-overlay.packages.${system}."0.16.0";
        isDarwin = pkgs.stdenv.isDarwin;
        pname = "cols";
        version = "0.1.0";

        zigDepsHash = "sha256-CZYaUzlhZdEIT0Wep+Pw7yvyDcfJMsrgJUMZJIS0OBo=";

        # Strategy-1 fixed-output derivation: one hash for the whole dep tree
        # (pcre2). Regenerate via the fix-zig-deps-hash procedure when
        # build.zig.zon changes.
        zigDeps = pkgs.stdenv.mkDerivation {
          pname = "${pname}-zig-deps";
          inherit version;
          src = self;
          nativeBuildInputs = [ zig pkgs.git pkgs.cacert ]
            ++ pkgs.lib.optionals isDarwin [
              pkgs.darwin.cctools
              pkgs.apple-sdk
            ];
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = zigDepsHash;
          buildPhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$out
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            export GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            zig build --fetch=all
          '';
          dontInstall = true;
          dontFixup = true;
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            zig
            pkgs.jq        # CLI suite validates --json output with jq
            pkgs.hyperfine # ./bm
            pkgs.gawk      # ./bm comparison target + corpus generator
          ];
        };

        packages.default = pkgs.stdenv.mkDerivation {
          inherit pname version;
          src = self;
          nativeBuildInputs = [ zig ]
            ++ pkgs.lib.optionals isDarwin [
              pkgs.darwin.cctools
              pkgs.apple-sdk
            ];
          dontConfigure = true;
          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
            chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
            zig build --prefix $out -Doptimize=ReleaseFast
          '';
          dontInstall = true;
          dontFixup = true;
        };

        # Mechatron Prime runs these. `build` compiles; `test` RUNS the unit
        # suite, the full CLI suite against the release binary, and smoke-execs
        # it — a compile-only gate says nothing about whether the tool works.
        checks = {
          build = self.packages.${system}.default;
          test = pkgs.stdenv.mkDerivation {
            name = "${pname}-test";
            src = self;
            nativeBuildInputs = [ zig pkgs.jq ]
              ++ pkgs.lib.optionals isDarwin [
                pkgs.darwin.cctools
                pkgs.apple-sdk
              ];
            dontConfigure = true;
            buildPhase = ''
              export HOME="$TMPDIR"
              export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
              mkdir -p $ZIG_GLOBAL_CACHE_DIR
              cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
              chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
              # 1) Zig unit tests
              zig build test
              # 2) release binary + full CLI suite against it
              zig build -Doptimize=ReleaseFast
              ./zig-out/bin/cols --about >/dev/null
              # bash explicitly: the sandbox has no /usr/bin/env for the shebang
              COLS_BIN=./zig-out/bin/cols bash ./tests/cli/cols_cli_test
            '';
            installPhase = ''
              mkdir -p $out
              echo "tests passed and binary executes" > $out/result
            '';
            dontFixup = true;
          };
        };
      });
}
