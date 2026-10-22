# harbor-py

Reusable Python `uv2nix` and `pyproject-nix` infrastructure for Nix flakes.

`harbor-py` exposes a small `lib.*` API, following the same consumption style as
`harbor-rs`: downstream flakes keep project policy local while sharing the
boring Python/Nix plumbing.

## API

- `mkPkgs`, `forAllSystems`, `forPackageSystems`
- `mkPythonEnv`
- `loadUvWorkspace`, `mkPythonApplicationPackage`
- `mkUvHelper`, `mkUvDevShell`, `mkUvDevShells`
- `mkUvPythonSet`, `mkUvVirtualEnv`, `mkUvPackage`, `mkUvCheckEnv`, `mkUvAppPackage`
- `mkFfmpegCompat`
- `mkFfmpegTorchCodecAbiCheck`
- `pythonOverrides.addSetuptools`
- `pythonOverrides.addTorchRuntime`
- `pythonOverrides.addTorchCodecFfmpegRuntime`

`mkUvVirtualEnv` and `mkUvCheckEnv` return immutable uv2nix environments. Use
their `${env}/bin/python` interpreter rather than manually prepending a
`site-packages` path. They expose the same locations as passthroughs:
`pythonEnvironment`, `pythonInterpreter`, and `pythonSitePackages`.

`mkUvDevShell` `extraPackages` are Nix shell tools; they do not add Python
dependencies to the uv environment. Put Python dependencies in `pyproject.toml`
and `uv.lock`, or replace them through the pyproject-nix overlay. Keep one
provider for a given Python package instead of mixing Nix and uv copies through
`PYTHONPATH`.

Nix checks run against read-only source trees. Tool caches and reports must be
placed under `$TMPDIR` or `$out`, not in the source tree.

### Development runtime migration

`mkUvDevShell` now scopes `baseLibs` and `extraLibs` to the managed Python
interpreter instead of exporting `LD_LIBRARY_PATH` across the shell. Python
console scripts, subprocesses and `uv run` inherit that runtime. Other native
commands can use the launcher exposed as `shell.passthru.runtime`.

Configure `venvDir` (default `.venv`), `systemSitePackages` (default `false`) and
`syncArgs` (an escaped argument list). Pass a runtime from
`harbor.lib.core.devShell.mkRuntime` when combining Python and Rust; it replaces
`baseLibs`/`extraLibs`.
The selected Nix CPython creates the venv, and sync uses
`--active --python-preference only-system` with downloads disabled. Both
CPython-created and uv-created compatible venvs are adopted, including uv's
configuration without an `executable` field.

Runtime changes update interpreter aliases without rebuilding a compatible
venv. Interpreter/site-policy changes rebuild previously managed environments
with rollback on creation failure. Preparation and interpreter wrapping share a
persistent sibling lock, so concurrent helper invocations cannot replace or
remove another invocation's in-progress environment. An incompatible unmanaged environment is
preserved with an actionable error. Sync failures stop the hook before
activation and before setting `UV_NO_SYNC`. `autoSync = false` leaves venv
creation, synchronization and activation to the caller; use the exposed runtime
launcher explicitly in that mode.

The launcher uses CPython's venv protocol. Execute
`checks.<system>.python-managed-venv` on a native platform to qualify the hook,
entry points and uv execution there.

```bash
nix flake init -t github:caniko/harbor-py
```

## Minimal Usage

```nix
{
  inputs.harbor-py.url = "github:caniko/harbor-py";

  outputs = { self, nixpkgs, harbor-py, ... }:
    let
      py = harbor-py.lib;
    in {
      devShells = py.forAllSystems (system:
        let
          pkgs = py.mkPkgs { inherit system; };
        in {
          default = py.mkUvDevShell {
            inherit pkgs;
            uvExtra = "dev";
          };
        });
    };
}
```
