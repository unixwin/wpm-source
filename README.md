# WinuxCmd WPM Source

This repository is the official WinuxCmd WPM package index.

Repository metadata:

- Repository: `unixwin/wpm-source`
- Description: `Curated WinuxCmd WPM index for standalone Windows command-line binaries`
- Public artifact: `index.json`
- Optional release artifact: `wpm-index.json`

## Bootstrap

Install WinuxCmd (which bundles `wpm`) from winget:

```powershell
winget install caomengxuan666.WinuxCmd
```

Then update the package index and install tools:

```powershell
wpm index update
wpm install ripgrep fd jq
```

## Scope

WPM sources focus on portable command-line tools that fit beside
`winuxcmd.exe`, plus a curated tier of relocatable development toolchains.

Good WPM packages:

- Single `.exe` downloads.
- `.zip` archives with clear file mappings.
- CLI tools that are useful in Unix-like shell workflows on Windows.
- Packages with known license metadata and SHA-256 checksums.

### Toolchain tier (`category: "toolchain"`)

Language runtimes and SDKs are admitted when they satisfy ALL of:

- Self-contained portable archive — no post-install downloader
  (`rustup-init`-style bootstrappers are excluded).
- Relocatable: runs from `opt\<pkg>\` via the shim layout without
  machine-global setup.
- Official release or CI-built mirror on `unixwin/wpm-artifacts`, pinned by
  SHA-256.
- License allows redistribution.

Out of scope:

- GUI applications.
- MSI/MSIX/AppX installers; services, drivers, background agents, or tools
  that require global setup.
- Non-relocatable environments (conda, vcpkg) and bootstrap downloaders
  (rustup-init, nvm, sdkman).
- MSVC / Windows SDK (not redistributable by us).
- Ecosystem package managers that install other software (winget, scoop,
  chocolatey).

The two-tier scope keeps WPM a reproducible, isolated, shell-side environment:
single-exe tools install flat; toolchains live self-contained under `opt\`,
enabling side-by-side versions without PATH conflicts.

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

- `type`: `exe`, `zip`, `tar.gz`, `tgz`, or `tar.xz`
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

## OpenSSL

`openssl` is packaged as the single static `bin/openssl.exe` from the ServBay
portable build, so it has no DLL dependencies. Like all Windows OpenSSL builds,
its compiled-in `OPENSSLDIR` is an absolute path that will not exist after a
WPM install, so commands that require a config file (notably `openssl req`)
will fail until `OPENSSL_CONF` points at an existing file:

```sh
# in ~/.winuxshrc, or before running openssl req
export OPENSSL_CONF="$HOME/openssl.cnf"   # any existing file, even empty, works
```

Key generation (`openssl genpkey`), certificate signing (`openssl x509 -req`),
digests, and `s_client` with an explicit `-CAfile` work without a config.

## GNU and POSIX-Style Tools

Prefer installable artifacts only when upstream publishes a Windows-native or
portable archive that WPM can verify with SHA-256 and explicit file mappings.

Keep packages metadata-only when the name is important for discovery but the
artifact is not safe to install directly. Examples:

- `gawk`: real GNU awk belongs in the index, but only as installable after a
  reviewed Windows portable artifact and SHA-256 are available.
- `parallel`: GNU Parallel depends on a Perl/Unix-style runtime model, so WPM
  should not claim it as installable until that dependency strategy is explicit.
  Native alternatives such as `rush` or `xargs -P` can be installable today.
