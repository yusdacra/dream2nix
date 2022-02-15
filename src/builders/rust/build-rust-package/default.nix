{
  lib,
  pkgs,

  ...
}:

{
  subsystemAttrs,
  defaultPackageName,
  defaultPackageVersion,
  getCyclicDependencies,
  getDependencies,
  getSource,
  getSourceSpec,
  packages,
  produceDerivation,

  ...
}@args:

let
  l = lib // builtins;

  vendorPackageDependencies = import ../vendor.nix {
    inherit lib pkgs getSource getSourceSpec getDependencies getCyclicDependencies;
  };

  # Generates a shell script that writes git vendor entries to .cargo/config.
  writeGitVendorEntries =
    let
      makeEntry = source:
        ''
        [source."${source.url}"]
        replace-with = "vendored-sources"
        git = "${source.url}"
        ${l.optionalString (source ? type) "${source.type} = \"${source.value}\""}
        '';
      entries = l.map makeEntry subsystemAttrs.gitSources;
    in ''
      mkdir -p ../.cargo/ && touch ../.cargo/config
      cat >> ../.cargo/config <<EOF
      ${l.concatStringsSep "\n" entries}
      EOF
    '';

  buildPackage = pname: version:
    let
      src = getSource pname version;
      vendorDir = vendorPackageDependencies pname version;
    in
    produceDerivation pname (pkgs.rustPlatform.buildRustPackage {
      inherit pname version src;

      postUnpack = ''
        ln -s ${vendorDir} ./nix-vendor
      '';

      cargoVendorDir = "../nix-vendor";

      preBuild = ''
        ${writeGitVendorEntries}
      '';
    });
in
rec {
  packages =
    l.mapAttrs
      (name: version:
        { "${version}" = buildPackage name version; })
      args.packages;

  defaultPackage = packages."${defaultPackageName}"."${defaultPackageVersion}";
}
