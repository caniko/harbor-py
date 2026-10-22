{
  nixLib,
  pyproject-nix,
  uv2nix,
  pyproject-build-systems,
  opencodeLspLib ? null,
  metaDevShell ? null,
}: let
  defaultTorchCodecMissingDeps = [
    # TorchCodec wheels bundle alternative FFmpeg 4/5/6/8 decoders.
    # mkFfmpegCompat supplies the FFmpeg 7 decoder's ABI.
    "libavcodec.so.58"
    "libavcodec.so.59"
    "libavcodec.so.60"
    "libavcodec.so.62"
    "libavdevice.so.58"
    "libavdevice.so.59"
    "libavdevice.so.60"
    "libavdevice.so.62"
    "libavfilter.so.7"
    "libavfilter.so.8"
    "libavfilter.so.9"
    "libavfilter.so.11"
    "libavformat.so.58"
    "libavformat.so.59"
    "libavformat.so.60"
    "libavformat.so.62"
    "libavutil.so.56"
    "libavutil.so.57"
    "libavutil.so.58"
    "libavutil.so.60"
    "libswresample.so.3"
    "libswresample.so.4"
    "libswresample.so.6"
    "libswscale.so.5"
    "libswscale.so.6"
    "libswscale.so.7"
    "libswscale.so.9"
  ];
in rec {
  mkFfmpegCompat = {
    pkgs,
    requireTorchCodecAbi ? true,
  }: let
    ffmpeg =
      if pkgs ? ffmpeg_7-full
      then pkgs.ffmpeg_7-full
      else if pkgs ? ffmpeg_7
      then pkgs.ffmpeg_7
      else if pkgs ? ffmpeg_6-full
      then pkgs.ffmpeg_6-full
      else pkgs.ffmpeg_6;
  in
    assert nixLib.assertMsg (builtins.isBool requireTorchCodecAbi)
    "internal error: requireTorchCodecAbi must be a boolean"; ffmpeg;

  mkFfmpegTorchCodecAbiCheck = {
    pkgs,
    ffmpeg,
    name ? "ffmpeg-torchcodec-abi-check",
  }:
    pkgs.runCommand name {} ''
      test -e ${pkgs.lib.getLib ffmpeg}/lib/libavutil.so.59 -o -e ${pkgs.lib.getLib ffmpeg}/lib/libavutil.so.58
      mkdir -p $out
      echo ok > $out/result
    '';

  pythonOverrides = {
    addSetuptools = final: prev: package:
      prev.${package}.overrideAttrs (old: {
        nativeBuildInputs =
          (old.nativeBuildInputs or [])
          ++ [
            final.setuptools
          ];
      });

    addTorchRuntime = python: final: prev: package:
      prev.${package}.overrideAttrs (old: {
        buildInputs =
          (old.buildInputs or [])
          ++ [
            final.torch
          ];
        preFixup =
          (old.preFixup or "")
          + ''
            addAutoPatchelfSearchPath "${final.torch}/${python.sitePackages}/torch"
          '';
      });

    addTorchCodecFfmpegRuntime = {
      python,
      ffmpeg,
      ignoredMissingDeps ? defaultTorchCodecMissingDeps,
    }: final: prev:
      prev.torchcodec.overrideAttrs (old: {
        buildInputs =
          (old.buildInputs or [])
          ++ [
            final.torch
            ffmpeg
          ];
        preFixup =
          (old.preFixup or "")
          + ''
            addAutoPatchelfSearchPath "${final.torch}/${python.sitePackages}/torch"
          '';
        autoPatchelfIgnoreMissingDeps = (old.autoPatchelfIgnoreMissingDeps or []) ++ ignoredMissingDeps;
      });
  };

  mkUvHelper = {
    pkgs,
    name,
    command,
    uv ? pkgs.uv,
  }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [uv];
      text = ''
        unset UV_NO_SYNC
        uv ${command} "$@"
      '';
    };

  mkPythonEnv = {
    pkgs,
    python ? pkgs.python313,
    packages ? (_: []),
  }:
    python.withPackages packages;

  mkUvDevShell = import ./uv-dev-shell.nix {
    inherit nixLib metaDevShell opencodeLspLib mkUvHelper;
  };

  mkUvDevShells = {
    pkgs,
    extras,
    defaultExtra,
    mkShellArgs,
  }: let
    mkShellForExtra = uvExtra:
      mkUvDevShell (
        (mkShellArgs uvExtra)
        // {
          inherit pkgs uvExtra;
        }
      );
    shells = nixLib.genAttrs extras mkShellForExtra;
  in
    shells
    // {
      default = shells.${defaultExtra};
    };

  loadUvWorkspace = {workspaceRoot}:
    uv2nix.lib.workspace.loadWorkspace {inherit workspaceRoot;};

  mkUvPythonSet = {
    pkgs,
    python ? pkgs.python313,
    workspaceRoot,
    dependencies,
    sourcePreference ? "wheel",
    pyprojectOverrides ? final: prev: {},
    extraOverlays ? [],
  }: let
    workspace = loadUvWorkspace {inherit workspaceRoot;};
    overlay = workspace.mkPyprojectOverlay {
      inherit sourcePreference dependencies;
    };
    buildSystemOverlay = pyproject-build-systems.overlays.${sourcePreference};
  in
    (pkgs.callPackage pyproject-nix.build.packages {
      inherit python;
    }).overrideScope
    (
      nixLib.composeManyExtensions (
        [
          buildSystemOverlay
          overlay
          pyprojectOverrides
        ]
        ++ extraOverlays
      )
    );

  mkUvVirtualEnv = {
    pkgs,
    python ? pkgs.python313,
    name,
    dependencies,
    ...
  } @ args: let
    pythonSet = mkUvPythonSet (builtins.removeAttrs args ["name"]);
    environment = pythonSet.mkVirtualEnv name dependencies;
  in
    environment
    // {
      passthru =
        (environment.passthru or {})
        // {
          pythonEnvironment = environment;
          pythonInterpreter = "${environment}/bin/python";
          pythonSitePackages = "${environment}/${python.sitePackages}";
        };
    };

  mkUvPackage = mkUvVirtualEnv;

  mkUvCheckEnv = mkUvVirtualEnv;

  mkPythonApplicationPackage = {
    pkgs,
    name,
    environment,
    scripts,
    runtimePathPackages ? [],
    runtimeLibraryPackages ? [],
    wrapperEnv ? {},
    includeEnvironment ? false,
    meta ? {},
    passthru ? {},
  }:
    pkgs.symlinkJoin {
      inherit name meta;
      paths = nixLib.optional includeEnvironment environment;
      nativeBuildInputs = [pkgs.makeWrapper];
      postBuild = nixLib.concatStringsSep "\n" (
        map (
          script: let
            source = "${environment}/bin/${script}";
            target = "$out/bin/${script}";
            wrapEnvFlags = nixLib.concatStringsSep " " (
              nixLib.mapAttrsToList (
                key: value: "--set ${key} ${nixLib.escapeShellArg (toString value)}"
              )
              wrapperEnv
            );
          in ''
            mkdir -p $out/bin
            ${nixLib.optionalString (!includeEnvironment) "makeWrapper ${source} ${target}"}
            wrapProgram ${target}${
              nixLib.optionalString (
                runtimePathPackages != []
              ) " --prefix PATH : ${nixLib.makeBinPath runtimePathPackages}"
            }${
              nixLib.optionalString (
                runtimeLibraryPackages != []
              ) " --prefix LD_LIBRARY_PATH : ${nixLib.makeLibraryPath runtimeLibraryPackages}"
            }${nixLib.optionalString (wrapEnvFlags != "") " ${wrapEnvFlags}"}
          ''
        )
        scripts
      );
      passthru =
        passthru
        // {
          pythonEnvironment = environment;
          pythonInterpreter = "${environment}/bin/python";
        };
    };

  mkUvAppPackage = {
    pkgs,
    name,
    scripts,
    dependencies,
    envName ? "${name}-env",
    runtimePathPackages ? [],
    runtimeLibraryPackages ? [],
    wrapperEnv ? {},
    includeEnvironment ? true,
    meta ? {},
    passthru ? {},
    ...
  } @ args: let
    venv = mkUvVirtualEnv (
      (builtins.removeAttrs args [
        "name"
        "scripts"
        "envName"
        "runtimePathPackages"
        "runtimeLibraryPackages"
        "wrapperEnv"
        "includeEnvironment"
        "meta"
        "passthru"
      ])
      // {
        name = envName;
      }
    );
    wrapEnvFlags = nixLib.concatStringsSep " " (
      nixLib.mapAttrsToList (
        key: value: "--set ${key} ${nixLib.escapeShellArg (toString value)}"
      )
      wrapperEnv
    );
    wrapScript = script: ''
      wrapProgram $out/bin/${script} \
        --prefix PATH : ${nixLib.makeBinPath runtimePathPackages} \
        --prefix LD_LIBRARY_PATH : ${nixLib.makeLibraryPath runtimeLibraryPackages}${
        nixLib.optionalString (wrapEnvFlags != "") " \\\n  ${wrapEnvFlags}"
      }
    '';
  in
    mkPythonApplicationPackage {
      inherit
        pkgs
        name
        scripts
        runtimePathPackages
        runtimeLibraryPackages
        wrapperEnv
        includeEnvironment
        meta
        passthru
        ;
      environment = venv;
    };
}
