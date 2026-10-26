{
  pkgs,
  harbor,
}: let
  runtime = pkgs.writeShellScriptBin "python-runtime-probe" ''
    export HARBOR_RUNTIME_PROBE=wrapped
    exec "$@"
  '';
  shell = harbor.mkUvDevShell {
    inherit pkgs runtime;
    venvDir = "environment with spaces";
    devGroup = null;
    syncArgs = ["--offline"];
    opencodeLsp.enable = false;
    shellHookSuffix = "export HARBOR_SYNC_FINISHED=1";
  };
  disabled = harbor.mkUvDevShell {
    inherit pkgs;
    autoSync = false;
    opencodeLsp.enable = false;
  };
  hook = pkgs.writeText "managed-venv-hook" shell.shellHook;
  disabledHook = pkgs.writeText "disabled-venv-hook" disabled.shellHook;
in
  assert !(shell ? LD_LIBRARY_PATH);
  assert !(disabled ? LD_LIBRARY_PATH);
    pkgs.runCommand "harbor-py-managed-venv" {
      # test_venv.py proves the lock adds no untracked project state via git.
      nativeBuildInputs = shell.nativeBuildInputs ++ [pkgs.git];
      env = shell.passthru.devShellSpec.env;
    } ''
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME" "$TMPDIR/project"
      cd "$TMPDIR/project"
      cat > pyproject.toml <<'TOML'
      [project]
      name = "runtime-probe"
      version = "0.1.0"
      requires-python = ">=${pkgs.python313.pythonVersion}"
      dependencies = []
      [tool.uv]
      package = false
      TOML
      . ${disabledHook}
      test ! -e .venv
      (
        cp pyproject.toml "$TMPDIR/valid-project.toml"
        printf '[invalid\n' > pyproject.toml
        if . ${hook}; then exit 1; fi
        cp "$TMPDIR/valid-project.toml" pyproject.toml
        test -z "''${UV_NO_SYNC:-}"
        test -z "''${HARBOR_SYNC_FINISHED:-}"
      )
      . ${hook}
      test "$HARBOR_SYNC_FINISHED" = 1
      python -c 'import os, sys; assert os.environ["HARBOR_RUNTIME_PROBE"] == "wrapped"; assert sys.prefix == os.environ["VIRTUAL_ENV"]'
      uv run --active --no-sync python -c 'import os; assert os.environ["HARBOR_RUNTIME_PROBE"] == "wrapped"'
      HARBOR_VENV_HELPER=${../lib/venv.py} ${pkgs.python313}/bin/python ${../tests/test_venv.py}
      touch "$out"
    ''
