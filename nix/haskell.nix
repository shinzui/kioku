# Haskell project wiring: dev shells (via the haskell-nix-dev base flake) and the
# project package (via callCabal2nix). seihou-managed — to add project-specific
# dev tools without editing this file, set `haskellProject.extraDevPackages` from
# ./flake.module.nix (see flake.module.nix.example).
{ inputs, lib, flake-parts-lib, ... }:
{
  options.perSystem = flake-parts-lib.mkPerSystemOption ({ ... }: {
    options.haskellProject.extraDevPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.ghciwatch pkgs.haskellPackages.hpack ]";
      description = ''
        Extra packages to add to the dev shell. Set this from ./flake.module.nix
        to add project-specific tooling without editing the generated
        ./nix/haskell.nix.
      '';
    };
  });

  config.perSystem = { system, pkgs, config, ... }:
    let
      hsdev = inputs.haskell-nix-dev.lib.${system};
      haskellPackages = pkgs.haskell.packages."ghc9124";

      # pgvector must come from the same postgresql package the dev server runs, or the
      # extension's .so/.control files are simply not on the server's library path. Plain
      # `pkgs.postgresql` leaves the dev database permanently degraded: the embedding
      # migration's guarded DO block finds no `vector` extension, skips the columns, and
      # codd records it applied anyway. `extraDevPackages` cannot fix this — it is appended
      # after this list, so plain postgresql would still win the PATH.
      #
      # The `.withPackages` wrapper has a single `out` output, so it drops the `dev` output
      # that carries `lib/pkgconfig/libpq.pc`; without that, postgresql-libpq fails to
      # resolve and the whole build plan collapses. Keep `.dev` alongside it.
      baseDevPackages = [
        pkgs.zlib
        pkgs.just
        pkgs.pkg-config
        (pkgs.postgresql.withPackages (ps: [ ps.pgvector ]))
        pkgs.postgresql.dev
        pkgs.jq
        pkgs.process-compose
      ];

      shellHook = ''
        ${config.pre-commit.installationScript}

        export PGHOST="$PWD/db"
        export PGDATA="$PGHOST/db"
        export PGLOG=$PGHOST/postgres.log
        export PGDATABASE=kioku
        export PG_CONNECTION_STRING=postgresql://$(jq -rn --arg x $PGHOST '$x|@uri')/$PGDATABASE

        mkdir -p $PGHOST
        mkdir -p .dev

        if [ ! -d $PGDATA ]; then
          initdb --auth=trust --no-locale --encoding=UTF8
        fi
      '';

      mkProjectShell = ghc: hsdev.mkDevShell {
        inherit ghc;
        extraNativeBuildInputs = baseDevPackages ++ config.haskellProject.extraDevPackages;
        withHls = true;
        inherit shellHook;
      };
    in
    {
      packages.default = haskellPackages.callCabal2nix "kioku" inputs.self { };

      devShells.default = mkProjectShell "ghc9124";
      devShells."ghc9124" = mkProjectShell "ghc9124";
    };
}
