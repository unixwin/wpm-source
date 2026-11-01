[CmdletBinding()]
param(
  [string]$IndexPath = (Join-Path $PSScriptRoot "..\index.json"),
  [switch]$Strict
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-ArrayLike {
  param([object]$Value)
  return $null -ne $Value -and $Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]
}

function Get-OptionalStringProperty {
  param([object]$Object, [string]$Name)

  if ($Object -and $Object.PSObject.Properties.Name -contains $Name) {
    return [string]$Object.$Name
  }
  return ""
}

# Mirrors wpm's mapping_is_directory (WinuxCmd src/commands/wpm.cpp): an
# explicit "kind", or a trailing separator on either side of the mapping.
function Test-MappingIsDirectory {
  param([object]$Mapping)

  $kind = (Get-OptionalStringProperty -Object $Mapping -Name "kind").ToLowerInvariant()
  if ($kind -eq "dir" -or $kind -eq "directory") { return $true }
  $from = (Get-OptionalStringProperty -Object $Mapping -Name "from")
  if ($from -match "[\\/]$") { return $true }
  $to = (Get-OptionalStringProperty -Object $Mapping -Name "to")
  if ($to -match "[\\/]$") { return $true }
  return $false
}

# Lower-case, forward-slash, no trailing separator, "." collapsed - the form
# every relative-position comparison below uses. wpm compares destinations
# case-insensitively (Win32 path names), so the validator must too.
function Get-NormalizedRelPath {
  param([string]$Path)

  $segments = @()
  foreach ($segment in ($Path -split "[\\/]")) {
    if ($segment -eq "" -or $segment -eq ".") { continue }
    $segments += $segment
  }
  return (($segments -join "/").ToLowerInvariant())
}

function Test-RelPathInside {
  param([string]$Child, [string]$Parent)

  $childPath = Get-NormalizedRelPath -Path $Child
  $parentPath = Get-NormalizedRelPath -Path $Parent
  if ($parentPath -eq "") { return $true }
  return $childPath -eq $parentPath -or $childPath.StartsWith($parentPath + "/")
}

function Test-ArtifactReady {
  param([object]$Artifact)

  if (-not $Artifact) { return $false }
  if (-not $Artifact.type -or @("exe", "zip", "tar.gz", "tgz", "tar.xz") -notcontains $Artifact.type) { return $false }
  if (-not $Artifact.sha256 -or $Artifact.sha256 -notmatch "^[0-9a-f]{64}$") { return $false }
  if (-not (Test-ArrayLike $Artifact.urls) -or @($Artifact.urls).Count -eq 0) { return $false }
  if (-not (Test-ArrayLike $Artifact.files) -or @($Artifact.files).Count -eq 0) { return $false }
  if ($Artifact.PSObject.Properties.Name -contains "size") {
    $sizeText = [string]$Artifact.size
    if ($sizeText -notmatch "^\d+$") { return $false }
  }
  if ($Artifact.PSObject.Properties.Name -contains "size_bytes") {
    $sizeText = [string]$Artifact.size_bytes
    if ($sizeText -notmatch "^\d+$") { return $false }
  }

  foreach ($url in @($Artifact.urls)) {
    if ($url -notmatch "^https://") { return $false }
  }

  foreach ($file in @($Artifact.files)) {
    if (-not $file.from -or -not $file.to) { return $false }
  }

  return $true
}

# Only ecosystem package managers that install other software stay banned.
# Relocatable, sha256-pinned toolchains are admitted under the `toolchain`
# category (see README "Toolchain tier").
$outOfScopeCommands = @(
  "winget", "scoop", "choco", "chocolatey"
)

function Test-OutOfScopePackage {
  param([object]$Package)

  $packageName = ([string]$Package.name).ToLowerInvariant()
  if ($outOfScopeCommands -contains $packageName) { return $true }

  $packageCommands = @()
  if ($Package.PSObject.Properties.Name -contains "commands") { $packageCommands = @($Package.commands) }
  if ($packageCommands.Count -gt 0) {
    foreach ($command in $packageCommands) {
      if ($outOfScopeCommands -contains ([string]$command).ToLowerInvariant()) {
        return $true
      }
    }
  }

  $category = (Get-OptionalStringProperty -Object $Package -Name "category").ToLowerInvariant()
  return @("package-manager") -contains $category
}

$resolvedIndexPath = (Resolve-Path -LiteralPath $IndexPath).Path
$index = Get-Content -Raw -LiteralPath $resolvedIndexPath | ConvertFrom-Json

$errors = New-Object System.Collections.Generic.List[string]
if (-not $index.schema) { $errors.Add("Missing top-level schema.") }
if (-not $index.name) { $errors.Add("Missing top-level name.") }
if (-not (Test-ArrayLike $index.packages)) { $errors.Add("Missing top-level packages array.") }

$packages = @($index.packages)
$names = @{}
$installable = 0
$indexOnly = 0
$broken = 0

foreach ($pkg in $packages) {
  $name = [string]$pkg.name
  if (-not $name) {
    $errors.Add("Package entry missing name.")
    $broken += 1
    continue
  }

  if ($names.ContainsKey($name)) {
    $errors.Add("Duplicate package name: $name")
  }
  $names[$name] = $true

  if (Test-OutOfScopePackage -Package $pkg) {
    $errors.Add("$name is out of scope for WPM; ecosystem package managers that install other software are not admitted.")
  }

  foreach ($field in @("description", "kind", "license")) {
    if (-not $pkg.$field) {
      $errors.Add("$name missing $field.")
    }
  }
  $packageCategory = (Get-OptionalStringProperty -Object $pkg -Name "category").ToLowerInvariant()
  $commandList = @()
  if ($pkg.PSObject.Properties.Name -contains "commands") { $commandList = @($pkg.commands) }
  if ($packageCategory -ne "i18n" -and $commandList.Count -eq 0) {
    $errors.Add("$name missing commands.")
  }

  if ($pkg.PSObject.Properties.Name -contains "aliases") {
    if (-not (Test-ArrayLike $pkg.aliases)) {
      $errors.Add("$name aliases must be an array.")
    } else {
      foreach ($alias in @($pkg.aliases)) {
        $aliasName = [string]$alias
        if ($alias -isnot [string]) { $aliasName = [string]$alias.name }
        if (-not $aliasName) { $errors.Add("$name contains an alias without a name.") }
      }
    }
  }

  $artifactProps = @()
  if ($pkg.PSObject.Properties.Name -contains "artifacts" -and $pkg.artifacts) {
    $artifactProps = @($pkg.artifacts.PSObject.Properties)
  }

  if ($artifactProps.Count -eq 0) {
    $indexOnly += 1
    continue
  }

  $readyArtifacts = 0
  foreach ($prop in $artifactProps) {
    $artifact = $prop.Value
    if (Test-ArtifactReady -Artifact $artifact) {
      $readyArtifacts += 1
    } else {
      $errors.Add("$name has incomplete artifact metadata for $($prop.Name).")
    }

    # Shim-layout mapping shape (payload runtime tree). A `layout: shim`
    # payload runs from wherever its files mapping puts it under
    # opt\<pkg>\, and it resolves its own DLLs and RUNTIME_PREFIX-style
    # paths (exec-path, sysroot, templates) relative to that spot. wpm
    # registers the payload at opt\<pkg>\<command>.exe when it exists and
    # otherwise at the destination of the file mapping whose `to` filename
    # equals <command>.exe (WinuxCmd wpm.cpp shim_payload_for), so the
    # mappings alone decide where the shim forwards to. Judge the shape
    # here, where it is still cheap to fix.
    $layout = (Get-OptionalStringProperty -Object $artifact -Name "layout").ToLowerInvariant()
    if ($layout -eq "") { $layout = "flat" }
    if ($layout -ne "shim") { continue }

    $directoryMaps = @()
    $fileMaps = @()
    if (Test-ArrayLike $artifact.files) {
      foreach ($mapping in @($artifact.files)) {
        if (Test-MappingIsDirectory -Mapping $mapping) { $directoryMaps += $mapping }
        else { $fileMaps += $mapping }
      }
    }

    foreach ($fileMapping in $fileMaps) {
      $mapFrom = (Get-OptionalStringProperty -Object $fileMapping -Name "from")
      if ($mapFrom -eq "") { continue }
      $mapToRaw = (Get-OptionalStringProperty -Object $fileMapping -Name "to")
      if ($mapToRaw -eq "") { $mapToRaw = ($mapFrom -split "[\\/]")[-1] }
      $mapTo = Get-NormalizedRelPath -Path $mapToRaw

      # Rule 1 - hoisting an exe out of a directory-mapped tree to the
      # package root. wpm's payload resolution prefers the package-root
      # copy, so the command runs detached from the sibling DLLs and
      # runtime files that stay inside the tree: DLL-bound payloads die
      # with STATUS_DLL_NOT_FOUND (0xC0000135) there, and statically
      # linked ones only appear to work. Whether a given exe survives is a
      # property of the exe the index cannot see, so the shape itself is
      # rejected: keep the payload inside its runtime tree.
      if ($mapTo -notmatch "/") {
        foreach ($dirMapping in $directoryMaps) {
          $dirFrom = (Get-OptionalStringProperty -Object $dirMapping -Name "from")
          if ($dirFrom -eq "") { continue }
          if (Test-RelPathInside -Child $mapFrom -Parent $dirFrom) {
            $errors.Add("$name [$($prop.Name)] hoists '$mapFrom' out of the tree mapped by '$dirFrom' to the package root ('$mapToRaw'): the shim forwards to the root copy, which runs without its sibling DLLs and runtime files (STATUS_DLL_NOT_FOUND for DLL-bound payloads). Keep the payload inside its runtime tree.")
            break
          }
        }
      }

      # Rule 2 - a file mapping whose destination lands inside a
      # directory-mapped subtree. wpm installs the mappings in array
      # order: the file mapping first pre-creates the destination and the
      # directory mapping then refuses it (destination exists), while the
      # directory mapping first makes the file mapping unlink the very
      # file it is about to link (the materialized payload resolves as its
      # own source). The overlap cannot install; map the file outside the
      # directory-mapped subtree.
      foreach ($dirMapping in $directoryMaps) {
        $dirToRaw = (Get-OptionalStringProperty -Object $dirMapping -Name "to")
        if ($dirToRaw -eq "") {
          # wpm's mapping_default_to: an omitted `to` for a directory is the
          # trimmed `from`'s final segment.
          $dirToRaw = (((Get-OptionalStringProperty -Object $dirMapping -Name "from")).TrimEnd('\', '/') -split "[\\/]")[-1]
        }
        if (Test-RelPathInside -Child $mapTo -Parent $dirToRaw) {
          $dirFrom = (Get-OptionalStringProperty -Object $dirMapping -Name "from")
          $errors.Add("$name [$($prop.Name)] maps '$mapFrom' to '$mapToRaw' inside the destination of the directory mapping '$dirFrom' -> '$dirToRaw': the two mappings fight over the same destination and wpm fails the install in either order.")
        }
      }
    }
  }

  if ($readyArtifacts -gt 0) {
    $installable += 1
  } else {
    $indexOnly += 1
  }
}

$commandOwners = @{}
foreach ($pkg in $packages) {
  $pkgName = [string]$pkg.name
  # An alias entry (`alias_of`) installs its target package by design, so it
  # necessarily repeats the target's command names; that sharing is the
  # point of the alias, not a conflict (git -> niugit). Only real packages
  # claim ownership here.
  $isAliasEntry = ($pkg.PSObject.Properties.Name -contains "alias_of") -and
    ((Get-OptionalStringProperty -Object $pkg -Name "alias_of") -ne "")
  if ($isAliasEntry) { continue }
  if ($pkg.PSObject.Properties.Name -contains "commands") {
    foreach ($command in @($pkg.commands)) {
      $commandName = ([string]$command).ToLowerInvariant()
      if (-not $commandName) { continue }
      if ($commandOwners.ContainsKey($commandName) -and $commandOwners[$commandName] -ne $pkgName) {
        $errors.Add("Command '$commandName' is provided by both '$($commandOwners[$commandName])' and '$pkgName'.")
      } else { $commandOwners[$commandName] = $pkgName }
    }
  }
  if ($pkg.PSObject.Properties.Name -contains "aliases") {
    foreach ($alias in @($pkg.aliases)) {
      $aliasName = [string]$alias
      if ($alias -isnot [string]) { $aliasName = [string]$alias.name }
      $aliasName = $aliasName.ToLowerInvariant()
      if (-not $aliasName) { continue }
      if ($commandOwners.ContainsKey($aliasName) -and $commandOwners[$aliasName] -ne $pkgName) {
        $errors.Add("Alias '$aliasName' in '$pkgName' conflicts with '$($commandOwners[$aliasName])'.")
      } else { $commandOwners[$aliasName] = $pkgName }
    }
  }
}

if ($errors.Count -gt 0) {
  $broken = $errors.Count
}

Write-Host "Validated: $resolvedIndexPath"
Write-Host "Packages: $($packages.Count)"
Write-Host "Installable: $installable"
Write-Host "Index-only: $indexOnly"
Write-Host "Issues: $($errors.Count)"

foreach ($errorMessage in $errors) {
  Write-Host "ERROR: $errorMessage" -ForegroundColor Red
}

if ($errors.Count -gt 0) {
  exit 1
}

if ($Strict -and $indexOnly -gt 0) {
  Write-Host "ERROR: strict mode rejects index-only placeholders." -ForegroundColor Red
  exit 1
}
