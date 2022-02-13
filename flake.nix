{
  description = "dream2nix: A generic framework for 2nix tools";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";

    # required for builder go/gomod2nix
    gomod2nix = { url = "github:tweag/gomod2nix"; flake = false; };

    # required for translator nodejs/pure/package-lock
    nix-parsec = { url = "github:nprindle/nix-parsec"; flake = false; };

    # required for translator pip
    mach-nix = { url = "mach-nix"; flake = false; };

    # required for builder nodejs/node2nix
    node2nix = { url = "github:svanderburg/node2nix"; flake = false; };

    # required for utils.satisfiesSemver
    poetry2nix = { url = "github:nix-community/poetry2nix/1.21.0"; flake = false; };

    # required for builder rust/crane
    crane = { url = "github:ipetkov/crane"; flake = false; };
    nix-std = { url = "github:chessai/nix-std"; flake = false; };
  };

  outputs = {
    self,
    gomod2nix,
    mach-nix,
    nix-parsec,
    nixpkgs,
    node2nix,
    poetry2nix,
    crane,
    nix-std,
  }@inp:
    let

      b = builtins;

      lib = nixpkgs.lib;

      supportedSystems = [ "x86_64-linux" "x86_64-darwin" "aarch64-darwin" ];

      forAllSystems = f: lib.genAttrs supportedSystems (system:
        f system (import nixpkgs { inherit system; overlays = [ self.overlay ]; })
      );

      # To use dream2nix in non-flake + non-IFD enabled repos, the source code of dream2nix
      # must be installed into these repos (using nix run dream2nix#install).
      # The problem is, all of dream2nix' dependecies need to be installed as well.
      # Therefore 'externalPaths' contains all relevant files of external projects
      # which dream2nix depends on. Exactly these files will be installed.
      externalPaths = {
        mach-nix = [
          "lib/extractor/default.nix"
          "lib/extractor/distutils.patch"
          "lib/extractor/setuptools.patch"
          "LICENSE"
        ];
        node2nix = [
          "nix/node-env.nix"
          "LICENSE"
        ];
        nix-parsec = [
          "parsec.nix"
          "lexer.nix"
          "LICENSE"
        ];
        poetry2nix = [
          "semver.nix"
          "LICENSE"
        ];
        crane = [
          "lib/buildDepsOnly.nix"
          "lib/cargoBuild.nix"
          "lib/mkCargoDerivation.nix"
          "lib/mkDummySrc.nix"
          "lib/writeTOML.nix"
          "lib/cleanCargoToml.nix"
          "pkgs/configureCargoCommonVarsHook.sh"
          "pkgs/configureCargoVendoredDepsHook.sh"
          "pkgs/inheritCargoArtifactsHook.sh"
          "pkgs/installCargoArtifactsHook.sh"
          "pkgs/remapSourcePathPrefixHook.sh"
          "LICENSE"
        ];
        nix-std = [
          "applicative.nix"
          "bool.nix"
          "default.nix"
          "fixpoints.nix"
          "function.nix"
          "functor.nix"
          "list.nix"
          "monad.nix"
          "monoid.nix"
          "nonempty.nix"
          "nullable.nix"
          "num.nix"
          "optional.nix"
          "regex.nix"
          "semigroup.nix"
          "serde.nix"
          "set.nix"
          "string.nix"
          "types.nix"
          "version.nix"
        ];
      };

      # create a directory containing the files listed in externalPaths
      makeExternalDir = import ./src/utils/external-dir.nix;

      externalDirFor = forAllSystems (system: pkgs: makeExternalDir {
        inherit externalPaths externalSources pkgs;
      });

      # An interface to access files of external projects.
      # This implementation aceeses the flake inputs directly,
      # but if dream2nix is used without flakes, it defaults
      # to another implementation of that function which
      # uses the installed external paths instead (see default.nix)
      externalSources =
        lib.genAttrs
          (lib.attrNames externalPaths)
          (inputName: inp."${inputName}");

      overridesDirs =  [ "${./overrides}" ];

      # system specific dream2nix api
      dream2nixFor = forAllSystems (system: pkgs: import ./src rec {
        externalDir = externalDirFor."${system}";
        inherit externalSources lib pkgs;
        config = {
          inherit overridesDirs;
        };
      });

    in
      {
        # overlay with flakes enabled nix
        # (all of dream2nix cli dependends on nix ^2.4)
        overlay = final: prev: {
          nix = prev.writeScriptBin "nix" ''
            ${final.nixUnstable}/bin/nix --option experimental-features "nix-command flakes" "$@"
          '';
        };

        # System independent dream2nix api.
        # Similar to drem2nixFor but will require 'system(s)' or 'pkgs' as an argument.
        # Produces flake-like output schema.
        lib = (import ./src/lib.nix {
          inherit externalPaths externalSources overridesDirs lib;
          nixpkgsSrc = "${nixpkgs}";
        })
        # system specific dream2nix library
        // (forAllSystems (system: pkgs:
          import ./src {
            inherit
              externalSources
              lib
              overridesDirs
              pkgs
            ;
          }
        ));

        # the dream2nix cli to be used with 'nix run dream2nix'
        defaultApp =
          forAllSystems (system: pkgs: self.apps."${system}".dream2nix);

        # all apps including cli, install, etc.
        apps = forAllSystems (system: pkgs:
          dream2nixFor."${system}".apps.flakeApps // {
            tests-impure.type = "app";
            tests-impure.program = b.toString
              (dream2nixFor."${system}".callPackageDream ./tests/impure {});
            tests-unit.type = "app";
            tests-unit.program = b.toString
              (dream2nixFor."${system}".callPackageDream ./tests/unit {
                inherit self;
              });
          }
        );

        # a dev shell for working on dream2nix
        # use via 'nix develop . -c $SHELL'
        devShell = forAllSystems (system: pkgs: pkgs.mkShell {

          buildInputs = with pkgs;
            (with pkgs; [
              nixUnstable
            ])
            # using linux is highly recommended as cntr is amazing for debugging builds
            ++ lib.optionals stdenv.isLinux [ cntr ];

          shellHook = ''
            export NIX_PATH=nixpkgs=${nixpkgs}
            export d2nExternalDir=${externalDirFor."${system}"}
            export dream2nixWithExternals=${dream2nixFor."${system}".dream2nixWithExternals}

            if [ -e ./overrides ]; then
              export d2nOverridesDir=$(realpath ./overrides)
            else
              export d2nOverridesDir=${./overrides}
              echo -e "\nManually execute 'export d2nOverridesDir={path to your dream2nix overrides dir}'"
            fi

            if [ -e ../dream2nix ]; then
              export dream2nixWithExternals=$(realpath ./src)
            else
              export dream2nixWithExternals=${./src}
              echo -e "\nManually execute 'export dream2nixWithExternals={path to your dream2nix checkout}'"
            fi
          '';
        });

        checks = forAllSystems (system: pkgs: import ./tests/pure {
          inherit lib pkgs;
          dream2nix = dream2nixFor."${system}";
        });
      };
}
