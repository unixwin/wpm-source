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
  if ($pkg.artifacts) {
    $artifactProps = @($pkg.artifacts.PSObject.Properties)
  }

  if ($artifactProps.Count -eq 0) {
    $indexOnly += 1
    continue
  }

  $readyArtifacts = 0
  foreach ($prop in $artifactProps) {
    if (Test-ArtifactReady -Artifact $prop.Value) {
      $readyArtifacts += 1
    } else {
      $errors.Add("$name has incomplete artifact metadata for $($prop.Name).")
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
