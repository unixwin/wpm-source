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

function Test-MappingIsDirectory {
  param([object]$Mapping)

  # Mirrors wpm's mapping_is_directory (src/commands/wpm.cpp): an explicit
  # "kind", or a trailing separator on either side of the mapping.
  $kind = (Get-OptionalStringProperty -Object $Mapping -Name "kind").ToLowerInvariant()
  if ($kind -eq "dir" -or $kind -eq "directory") { return $true }
  $from = [string]$Mapping.from
  if ($from -match "[\\/]$") { return $true }
  if ($Mapping.PSObject.Properties.Name -contains "to") {
    $to = [string]$Mapping.to
    if ($to -match "[\\/]$") { return $true }
  }
  return $false
}

function Get-NormalizedRelPath {
  # Lower-case, forward-slash, no trailing separator - the form every
  # relative-position comparison below uses. wpm compares destinations
  # case-insensitively (Win32 path names), so the validator must too.
  param([string]$Path)
  return $Path.replace('\', '/').ToLowerInvariant().TrimEnd('/')
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
$warnings = New-Object System.Collections.Generic.List[string]
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
  if ($pkg.PSObject.Properties.Name -contains "artifacts") {
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

    # Layout mapping checks (issue #72): the shim forwards <command> to a
    # payload file, and that payload resolves its own DLLs and runtime paths
    # relative to its installed location. The index entries below describe
    # where each mapping lands, so this is where the shape is judgeable.
    $layout = (Get-OptionalStringProperty -Object $artifact -Name "layout").ToLowerInvariant()
    if ($layout -eq "") { $layout = "flat" }
    $fileMaps = @()
    $dirMaps = @()
    if (Test-ArrayLike $artifact.files) {
      foreach ($fileMapping in @($artifact.files)) {
        if (Test-MappingIsDirectory -Mapping $fileMapping) { $dirMaps += $fileMapping }
        else { $fileMaps += $fileMapping }
      }
    }

    foreach ($fileMapping in $fileMaps) {
      $mapFrom = Get-NormalizedRelPath -Path ([string]$fileMapping.from)
      if ($fileMapping.PSObject.Properties.Name -contains "to" -and $fileMapping.to) {
        $mapTo = Get-NormalizedRelPath -Path ([string]$fileMapping.to)
      } else {
        $mapTo = $mapFrom.Split("/")[-1]
      }

      # A file mapping hoisted to the package root while a directory mapping
      # also materializes the tree the exe came from: the payload then runs
      # detached from its sibling DLLs and RUNTIME_PREFIX tree. Whether that
      # breaks depends on the payload (MinGit git.exe dies 0xC0000135, hoisted
      # rustc.exe loses rustc_driver-*.dll, hoisted cargo.exe survives), so
      # this stays a warning; the fix is mapping the artifact's own launcher
      # or keeping the exe beside its tree (see docs/index-schema.md).
      if ($layout -eq "shim" -and $dirMaps.Count -gt 0 -and (-not $mapTo.Contains("/"))) {
        foreach ($dirMapping in $dirMaps) {
          if (Test-RelPathInside -Child $mapFrom -Parent ([string]$dirMapping.from)) {
            $warnings.Add("$name [$($prop.Name)] hoists payload '$($fileMapping.from)' to the package root ('$($fileMapping.to)') out of the tree mapped by '$($dirMapping.from)': RUNTIME_PREFIX/private-DLL payloads break from there (issue #72).")
            break
          }
        }
      }

      # A file mapping that lands inside a directory-mapped tree cannot work
      # in either order: file-first pre-creates the destination directory and
      # the directory mapping then fails without --force, directory-first
      # makes wpm unlink the payload it is about to re-link (materialize_file
      # removes the target before hard-linking).
      foreach ($dirMapping in $dirMaps) {
        $dirTo = if ($dirMapping.PSObject.Properties.Name -contains "to") { [string]$dirMapping.to } else { [string]$dirMapping.from }
        if ((Test-RelPathInside -Child $mapFrom -Parent ([string]$dirMapping.from)) -and
            (Test-RelPathInside -Child $mapTo -Parent $dirTo)) {
          $errors.Add("$name [$($prop.Name)] file mapping '$($fileMapping.from)' -> '$($fileMapping.to)' lands inside the directory mapping '$($dirMapping.from)' -> '$dirTo'; wpm fails the install or unlinks the materialized payload (self-collision).")
        }
      }
    }

    # Every shim command must have a declared payload: wpm resolves
    # opt\<pkg>\<command>.exe either directly from a file mapping or from the
    # top of a directory-mapped tree; with neither, the shim answers
    # "no payload is registered for '<command>'". Only the fully undeclared
    # case is judgeable from the index alone (whether a directory tree really
    # holds the exe at its top needs the artifact), so the check stays narrow.
    if ($layout -eq "shim" -and $fileMaps.Count -eq 0 -and $dirMaps.Count -eq 0) {
      foreach ($commandName in $commandList) {
        $warnings.Add("$name [$($prop.Name)]: shim command '$commandName' has no files mapping; no payload can be registered for it.")
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
  # An alias entry (`alias_of`) intentionally shares the target package's
  # commands; ownership belongs to the target so the shared name is not
  # reported as a conflict.
  $ownerName = $pkgName
  if ($pkg.PSObject.Properties.Name -contains "alias_of") {
    $ownerName = [string]$pkg.alias_of
    if (-not $ownerName) { $ownerName = $pkgName }
  }
  if ($pkg.PSObject.Properties.Name -contains "commands") {
    foreach ($command in @($pkg.commands)) {
      $commandName = ([string]$command).ToLowerInvariant()
      if (-not $commandName) { continue }
      if ($commandOwners.ContainsKey($commandName) -and $commandOwners[$commandName] -ne $ownerName) {
        $errors.Add("Command '$commandName' is provided by both '$($commandOwners[$commandName])' and '$pkgName'.")
      } else { $commandOwners[$commandName] = $ownerName }
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

foreach ($warningMessage in $warnings) {
  Write-Host "WARNING: $warningMessage" -ForegroundColor Yellow
}

if ($errors.Count -gt 0) {
  exit 1
}

if ($Strict -and $indexOnly -gt 0) {
  Write-Host "ERROR: strict mode rejects index-only placeholders." -ForegroundColor Red
  exit 1
}
