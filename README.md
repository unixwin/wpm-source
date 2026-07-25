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

The WinuxCmd bundled index may still keep an in-repo fallback, but this
repository is the canonical external WPM source.

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
