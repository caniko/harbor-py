{
  nixLib,
  metaDevShell,
  opencodeLspLib,
  mkUvHelper,
}: {
  pkgs,
  timeZone ? "UTC",
  python ? pkgs.python313,
  uvExtra ? null,
  devGroup ? "dev",
  basePackages ? [],
  extraPackages ? [],
  baseLibs ? [],
  extraLibs ? [],
  extraEnv ? {},
  pythonPathEntries ? [],
  helperPackages ? [],
  helperSpecs ? [],
  shellHookPrefix ? "",
  shellHookSuffix ? "",
  autoSync ? true,
  venvDir ? ".venv",
  systemSitePackages ? false,
  syncArgs ? [],
  runtime ? null,
  opencodeLsp ? {enable = true;},
}: let
  inherit (nixLib) escapeShellArg escapeShellArgs optional optionals optionalString;
  opencodeLspEnabled = (opencodeLsp.enable or true) && opencodeLspLib != null;
  # The servers nix-opencode-lsp configures for the python profile, also on
  # PATH so other editors (VS Code via direnv, Helix, Neovim) resolve the same
  # binaries. Listed explicitly: its full shell would add nixpkgs'
  # rust-analyzer and shadow a Rust toolchain's in a composed shell.
  opencodeLspPackages = optionals opencodeLspEnabled [pkgs.basedpyright pkgs.ruff];
  expectedPython = nixLib.getExe python;
  scopedRuntime =
    if runtime != null
    then runtime
    else
      metaDevShell.mkRuntime {
        inherit pkgs;
        name = "harbor-python-runtime";
        libraryPackages = baseLibs ++ extraLibs;
      };
  venvPython = pkgs.writeShellScript "harbor-venv-python" ''
    export __PYVENV_LAUNCHER__="$(${pkgs.coreutils}/bin/realpath -s "$0")"
    exec ${nixLib.getExe scopedRuntime} ${expectedPython} "$@"
  '';
  uvFlags = escapeShellArgs (
    optional (uvExtra != null) "--extra"
    ++ optional (uvExtra != null) uvExtra
    ++ optional (devGroup != null) "--group"
    ++ optional (devGroup != null) devGroup
    ++ syncArgs
  );
  generatedHelpers = map (spec: mkUvHelper ({inherit pkgs;} // spec)) helperSpecs;
  opencodeLspHook =
    if opencodeLspEnabled
    then
      (opencodeLspLib.mkShell {
        inherit pkgs;
        profiles = ["python"];
        # nix-opencode-lsp's base config pins nixpkgs' rust-analyzer; resolve
        # it from PATH like harbor-rs's profile, so a composed Rust toolchain's
        # rust-analyzer serves OpenCode.
        extraLsp.rust.command = ["rust-analyzer"];
      }).shellHook
    else "";
  pythonPath = optionalString (pythonPathEntries != []) ''
    export PYTHONPATH=${escapeShellArg (nixLib.concatStringsSep ":" pythonPathEntries)}"''${PYTHONPATH:+:$PYTHONPATH}"
  '';
  syncHook = optionalString autoSync ''
    export VIRTUAL_ENV=${optionalString (!(nixLib.hasPrefix "/" venvDir)) ''"$PWD"/''}${escapeShellArg venvDir}
    unset UV_NO_SYNC
    ${expectedPython} ${./venv.py} sync --venv "$VIRTUAL_ENV" \
      --launcher ${venvPython} --uv ${nixLib.getExe pkgs.uv} \
      ${optionalString systemSitePackages "--system-site-packages"} -- ${uvFlags} || return 1
    export UV_NO_SYNC=1
    . "$VIRTUAL_ENV/bin/activate"
  '';
in
  assert nixLib.assertMsg (runtime == null || baseLibs ++ extraLibs == []) "harbor-py: provide runtime or baseLibs/extraLibs, not both";
    if metaDevShell == null
    then throw "harbor-py: mkUvDevShell requires the harbor-meta flake input"
    else
      metaDevShell.mkShell {
        inherit pkgs timeZone;
        packages = [python pkgs.uv scopedRuntime] ++ basePackages ++ extraPackages ++ generatedHelpers ++ helperPackages ++ opencodeLspPackages;
        env =
          {
            UV_LINK_MODE = "copy";
            UV_PYTHON_DOWNLOADS = "never";
          }
          // extraEnv;
        mkShellArgs.passthru = {
          runtime = scopedRuntime;
          inherit venvPython;
        };
        extraShellHook = ''
          ${shellHookPrefix}
          ${opencodeLspHook}
          ${pythonPath}
          ${syncHook}
          ${shellHookSuffix}
        '';
      }
