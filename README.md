# WinuxCmd WPM Source

This repository is the official WinuxCmd WPM package index.

Repository metadata:

- Repository: `unixwin/wpm-source`
- Description: `Curated WinuxCmd WPM index for standalone Windows command-line binaries`
- Public artifact: `index.json`
- Optional release artifact: `wpm-index.json`

## Scope

WPM sources should stay focused on portable command-line tools that fit beside
`winuxcmd.exe`.

Good WPM packages:

- Single `.exe` downloads.
- `.zip` archives with clear file mappings.
- CLI tools that are useful in Unix-like shell workflows on Windows.
- Packages with known license metadata and SHA-256 checksums.

Out of scope:

- GUI applications.
- MSI/MSIX/AppX installers.
- Services, drivers, background agents, or tools that require global setup.
- Language runtimes and SDKs that are better installed by winget, Visual Studio,
  or the vendor installer.

## Source Layout

The minimum repository can be simple:

```text
wpm-source/
  README.md
  index.json
```

WinuxCmd can point official sources at:

```text
https://raw.githubusercontent.com/unixwin/wpm-source/main/index.json
https://cdn.jsdelivr.net/gh/unixwin/wpm-source@main/index.json
https://github.com/unixwin/wpm-source/releases/latest/download/wpm-index.json
```

WinuxCmd should only bundle source URLs for bootstrap behavior. Package
metadata and artifact updates belong in this repository.

## Updating Packages

Use `scripts/update-package.ps1` instead of hand-editing `index.json`. The
script downloads the artifact, computes SHA-256, updates the package artifact,
and refreshes the top-level `updated` date.

Preview first:

```powershell
pwsh ./scripts/update-package.ps1 `
  -Package jq `
  -Version 1.8.2 `
  -Platform windows-x64 `
  -Type exe `
  -Url https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-windows-amd64.exe `
  -From jq.exe `
  -To jq.exe `
  -DryRun
```

Apply the update by removing `-DryRun`, then validate:

```powershell
pwsh ./scripts/validate-index.ps1
```

For zip packages, map the executable inside the archive:

```powershell
pwsh ./scripts/update-package.ps1 `
  -Package fd `
  -Version 10.4.2 `
  -Platform windows-x64 `
  -Type zip `
  -Url https://github.com/sharkdp/fd/releases/download/v10.4.2/fd-v10.4.2-x86_64-pc-windows-msvc.zip `
  -From fd.exe `
  -To fd.exe
```

For a new package, also provide metadata:

```powershell
pwsh ./scripts/update-package.ps1 `
  -Package tool `
  -Version 1.2.3 `
  -Platform windows-x64 `
  -Type zip `
  -Url https://example.invalid/tool-1.2.3-windows-x64.zip `
  -From tool.exe `
  -To tool.exe `
  -Description "Useful standalone command-line tool." `
  -Kind external `
  -Category developer `
  -License MIT `
  -Commands tool
```

## Package Requirements

Every installable artifact should include:

- `type`: `exe` or `zip`
- `sha256`: required for remote downloads
- `urls`: one or more HTTPS download URLs
- `files`: explicit `from` to `to` mappings

Example:

```json
{
  "name": "tool",
  "version": "1.2.3",
  "description": "Useful standalone command-line tool.",
  "kind": "external",
  "category": "developer",
  "license": "MIT",
  "commands": ["tool"],
  "artifacts": {
    "windows-x64": {
      "type": "zip",
      "sha256": "<64 lowercase hex chars>",
      "urls": ["https://example.invalid/tool-1.2.3-windows-x64.zip"],
      "files": [
        { "from": "tool.exe", "to": "tool.exe" }
      ]
    }
  }
}
```

Metadata-only packages are allowed as placeholders, but WPM should display them
as `index-only` until URLs, SHA-256 hashes, and file mappings are present.
