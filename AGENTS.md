# wpm-source index rules

`index.json` is the contract every `wpm install` resolves against. Changes
here reach users immediately - there is no staging, no cache invalidation and
no undo other than a follow-up PR.

## Entry rules

- `artifacts.<arch>` keys are `windows-x64` / `windows-arm64`. Each needs
  `type`, `sha256`, `size`, `urls` and `files`; packages also carry `layout`.
- `sha256` and `size` must be measured from the **published asset** (download
  it, or read the CI packaging step's log line and cross-check). A digest
  copied from a build log without that cross-check has already shipped a
  broken entry.
- `files` must describe the payload exactly:
  - every `from` path must exist inside the artifact;
  - `to` paths must land where the layout says they do - `opt/<pkg>/...` for
    `layout: shim`, root-relative (`usr/bin/<name>` for a bare name) for
    `layout: flat`;
  - a mapping for a file the artifact no longer ships fails the install with
    "extracted path not found", and a *missing* mapping silently drops a file.
- Version strings are **ordered**, not compared for equality: a dotted-numeric
  core plus an optional Debian-style packaging revision
  (`5.4.1-unixwin2` > `5.4.1-unixwin1` > `5.4.1`). A repackaged artifact must
  carry a revision, otherwise installed copies are never offered the update.
  Vendor spellings (`9.5.0.0p1`, `r42`) keep the conservative rule.
- Keep `description` honest about the things a user notices: layout, TLS
  backend, whether a shell/perl ships, and any migration prerequisite.
- `commands` drives the PATH entry links (`<root>/bin/<cmd>.exe`) and, for
  `layout: shim`, the dispatcher links; keep it in step with what the payload
  actually provides.
- Prefer `layout: shim` for anything with private DLLs or several commands: it
  keeps the payload (and its DLLs) out of `<root>/usr/bin`, which is a PATH
  neighbour. Reserve `flat` for the binary that must be the PATH entry itself.

## Flow

- The `winuxcmd` core entry is written by the WinuxCmd release workflow
  automatically; every other entry is a pull request (niugit, gawk, openssh,
  ...).
- If a release's index job was skipped (a repository without
  `WPM_SOURCE_TOKEN`, e.g. niu-git), open the entry PR by hand from the
  release's measured digests.
- Nothing else belongs in this repository: no scripts, no partial index, no
  per-package state.
