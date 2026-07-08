# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

## [0.1.8] - 2026-07-08

### Changed
- `Search-SvnLog`: default `-Limit` reduced from 200 to 5.

## [0.1.7] - 2026-07-08

### Changed
- `Search-SvnLog`: only prompt to install PwshSpectreConsole on PowerShell 7+.
  On Windows PowerShell 5.1 (where the module isn't supported) it now silently
  uses the plain-text rendering path.

## [0.1.6] - 2026-07-07

### Fixed
- `Search-SvnLog`: Spectre markup error when a changed path included copy-from
  metadata — the `[copied from ...]` text was being parsed as a Spectre color tag.
  Escaped to `[[copied from ...]]` so it renders as literal brackets.

## [0.1.5] - 2026-07-07

### Changed
- Updated `Set-RegexHistorySearch` documentation to reflect module-based usage
  (auto-registered on import; call explicitly to change the key binding).

## [0.1.4] - 2026-07-07

### Added
- `Search-AppEventLog` — searches the Application event log for entries matching a string.
- `Test-Xml` — validates an XML file against an XSD schema.

## [0.1.3] - 2026-07-07

### Added
- `Compare-DirectoryContentParallel` — multithreaded file comparison between two directories (requires PS 7.0).
- `Format-DirectoryDiff` — color-formatted output for directory comparison results (requires PS 7.0).

## [0.1.2] - 2026-07-07

### Changed
- Added Windows PowerShell 5.1 (Desktop edition) compatibility: lowered
  `PowerShellVersion` to 5.1, set `CompatiblePSEditions` to Desktop and Core,
  and replaced PowerShell 7-only operators (ternary, null-coalescing,
  null-conditional) with 5.1-compatible equivalents.

## [0.1.1] - 2026-07-07

### Added
- `Get-SvnLastRevision` to return the last commit revision for a path.
- Auto-registration of the `Set-RegexHistorySearch` PSReadLine key handler on module load.
- Gallery metadata (Tags, LicenseUri, ProjectUri, ReleaseNotes) and packaged README.

### Changed
- Wrapped public scripts in functions so they export cleanly and no longer execute on import.
- Converted `exit` to `return` in `Search-SvnLog` to avoid terminating the host.
- Raised minimum `PowerShellVersion` to 7.0.

### Fixed
- Addressed PSScriptAnalyzer findings (trailing whitespace, output type, file encoding).

## [0.1.0]

### Added
- Initial module scaffold
