[CmdletBinding()]
param(
  [string]$IndexPath = (Join-Path $PSScriptRoot "..\index.json"),
  [Parameter(Mandatory = $true)]
  [string]$Package,
  [Parameter(Mandatory = $true)]
  [string]$Version,
  [ValidateSet("windows-x64", "windows-arm64")]
  [string]$Platform = "windows-x64",
  [Parameter(Mandatory = $true)]
  [ValidateSet("exe", "zip", "tar.gz", "tgz", "tar.xz")]
  [string]$Type,
  [ValidateSet("flat", "shim")]
  [string]$Layout,
  [Parameter(Mandatory = $true)]
  [string]$Url,
  [Parameter(Mandatory = $true)]
  [string]$From,
  [string]$To,
  [string[]]$Files,
  [string]$Sha256,
  [int64]$Size,
  [string]$Description,
  [ValidateSet("core", "external")]
  [string]$Kind = "external",
  [string]$Category,
  [string]$License,
  [string[]]$Commands,
  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Set-JsonProperty {
  param(
    [Parameter(Mandatory = $true)] [object]$Object,
    [Parameter(Mandatory = $true)] [string]$Name,
    [object]$Value
  )

  $propertyNames = @($Object.PSObject.Properties | ForEach-Object { $_.Name })
  if ($propertyNames -contains $Name) {
    $Object.$Name = $Value
    return
  }

  $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
}

function Get-ArtifactHash {
  param(
    [Parameter(Mandatory = $true)] [string]$ArtifactUrl
  )

  $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
  try {
    Write-Host "Downloading artifact to compute SHA-256..."
    Invoke-WebRequest -Uri $ArtifactUrl -OutFile $tempFile -UseBasicParsing
    $script:ArtifactDownloadSize = (Get-Item -LiteralPath $tempFile).Length
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $tempFile).Hash.ToLowerInvariant()
  } finally {
    if (Test-Path -LiteralPath $tempFile) {
      Remove-Item -LiteralPath $tempFile -Force
    }
  }
}

function Get-ArtifactSize {
  param(
    [Parameter(Mandatory = $true)] [string]$ArtifactUrl
  )

  try {
    $response = Invoke-WebRequest -Uri $ArtifactUrl -Method Head -UseBasicParsing
    if ($response.Headers["Content-Length"]) {
      $contentLength = $response.Headers["Content-Length"]
      if ($contentLength -is [array]) { $contentLength = $contentLength[0] }
      return [int64]$contentLength
    }
  } catch {
    # HEAD is not always supported; fall back to a ranged GET when needed.
  }
  return $null
}

$resolvedIndexPath = (Resolve-Path -LiteralPath $IndexPath).Path
$index = Get-Content -Raw -LiteralPath $resolvedIndexPath | ConvertFrom-Json

if (-not ($index.PSObject.Properties.Name -contains "packages") -or -not $index.packages) {
  Set-JsonProperty -Object $index -Name "packages" -Value @()
}

$packages = @($index.packages)
$pkg = $packages | Where-Object { $_.name -eq $Package } | Select-Object -First 1

if (-not $pkg) {
  $missing = @()
  if (-not $Description) { $missing += "-Description" }
  if (-not $License) { $missing += "-License" }
  if (-not $Commands -or $Commands.Count -eq 0) { $missing += "-Commands" }
  if ($missing.Count -gt 0) {
    throw "New package '$Package' needs metadata: $($missing -join ', ')"
  }

  $pkg = [pscustomobject]@{
    name        = $Package
    version     = $Version
    description = $Description
    kind        = $Kind
    license     = $License
    commands    = [string[]]$Commands
    artifacts   = [pscustomobject]@{}
  }
  if ($Category) {
    Set-JsonProperty -Object $pkg -Name "category" -Value $Category
  }

  $packages += $pkg
  Set-JsonProperty -Object $index -Name "packages" -Value $packages
}

Set-JsonProperty -Object $pkg -Name "version" -Value $Version
if ($Description) { Set-JsonProperty -Object $pkg -Name "description" -Value $Description }
if ($Kind) { Set-JsonProperty -Object $pkg -Name "kind" -Value $Kind }
if ($Category) { Set-JsonProperty -Object $pkg -Name "category" -Value $Category }
if ($License) { Set-JsonProperty -Object $pkg -Name "license" -Value $License }
if ($Commands -and $Commands.Count -gt 0) {
  Set-JsonProperty -Object $pkg -Name "commands" -Value ([string[]]$Commands)
}
if (-not ($pkg.PSObject.Properties.Name -contains "artifacts") -or -not $pkg.artifacts) {
  Set-JsonProperty -Object $pkg -Name "artifacts" -Value ([pscustomobject]@{})
}

if (-not $To) { $To = $From }
$Sha256Provided = -not [string]::IsNullOrWhiteSpace($Sha256)
if (-not $Sha256) { $Sha256 = Get-ArtifactHash -ArtifactUrl $Url }
$Sha256 = $Sha256.ToLowerInvariant()
if ($Sha256 -notmatch "^[0-9a-f]{64}$") {
  throw "SHA-256 must be 64 lowercase hex characters."
}

$ArtifactSize = $null
if ($Size) { $ArtifactSize = $Size }
elseif (-not $Sha256Provided) { $ArtifactSize = $ArtifactDownloadSize }
else { $ArtifactSize = Get-ArtifactSize -ArtifactUrl $Url }

$artifact = [pscustomobject]@{
  type   = $Type
  sha256 = $Sha256
  urls   = [string[]]@($Url)
  files  = @()
}
if ($Layout) { Set-JsonProperty -Object $artifact -Name "layout" -Value $Layout }
$fileMappings = @()
if (-not $To) { $To = $From }
$fileMappings += [pscustomobject]@{ from = $From; to = $To }
if ($Files -and $Files.Count -gt 0) {
  foreach ($entry in $Files) {
    if ($entry -match '^(.*?)=(.*)$') {
      $fileMappings += [pscustomobject]@{ from = $Matches[1]; to = $Matches[2] }
    } else {
      $fileMappings += [pscustomobject]@{ from = $entry; to = $entry }
    }
  }
}
$artifact.files = $fileMappings
if ($ArtifactSize) { Set-JsonProperty -Object $artifact -Name "size" -Value $ArtifactSize }
Set-JsonProperty -Object $pkg.artifacts -Name $Platform -Value $artifact
Set-JsonProperty -Object $index -Name "updated" -Value (Get-Date -Format "yyyy-MM-dd")

$json = $index | ConvertTo-Json -Depth 32
if ($DryRun) {
  Write-Host "Dry run: would update $Package $Version for $Platform"
  Write-Host "SHA256: $Sha256"
  if ($ArtifactSize) { Write-Host "Size: $ArtifactSize" }
  return
}

$json.TrimEnd() + [Environment]::NewLine | Set-Content -LiteralPath $resolvedIndexPath -Encoding utf8
Write-Host "Updated $Package $Version for $Platform in $resolvedIndexPath"
Write-Host "SHA256: $Sha256"
if ($ArtifactSize) { Write-Host "Size: $ArtifactSize" }
