# gcpstools Repository Guide

## Project

- This is a PowerShell module named `gcpstools`.
- Module code supports PowerShell 5.1.
- `build.ps1` requires PowerShell 7+ and must be run with `pwsh`.
- The authoritative module version and export list are in `src/gcpstools/gcpstools.psd1`.

## Code Conventions

- Each file in `src/gcpstools/Public/` defines exactly one function matching its filename.
- Add new public functions to `FunctionsToExport` in `gcpstools.psd1`.
- Keep internal helpers in `Private/` or nested inside the public function.
- Preserve PowerShell 5.1 compatibility in module code.
- Use `apply_patch` for edits and avoid unrelated formatting changes.

## Server Update Commands

- `Get-ServerUpdateStatus` gets installed updates through CIM and available updates through PowerShell remoting.
- If remoting fails, pending-reboot detection falls back to the registry through CIM.
- Suppress internal CIM and remoting provider noise with `-Verbose:$false`.
- User-facing verbose messages must include the target computer name.
- `Invoke-ServerUpdate` runs Windows Update through a SYSTEM scheduled task because WUA cannot install updates from a remote session.
- To update only machines with available updates:

  ```powershell
  Get-ServerUpdateStatus -ComputerName 'APP01', 'SQL01' -AsObject |
      Where-Object AvailableUpdateCount -gt 0 |
      Invoke-ServerUpdate -Wait
  ```

## Validation

- Run the full suite with `./build.ps1 -Test`.
- Focused status tests are in `tests/Public/Get-ServerUpdateStatus.Tests.ps1`.
- Add regression tests for behavior changes.

## Release

- Bump versions with `./build.ps1 -BumpVersion Patch` or `Minor` or `Major`.
- The bump command also rolls the `CHANGELOG.md` `[Unreleased]` section.
- Review and commit changes before tagging.
- Releases require the `main` branch and a clean working tree.
- `./build.ps1 -Tag` creates and pushes `v<ModuleVersion>`, triggering `.github/workflows/publish.yml`.
- Never hardcode the current version in instructions; read it from the manifest.
- Do not commit `src/gcpstools/README.md`; it is generated from the root README during publishing.