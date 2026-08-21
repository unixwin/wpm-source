param(
  [string]$IndexPath = (Join-Path $PSScriptRoot '..\index.json'),
  [string]$OutDir = (Join-Path $PSScriptRoot '..\dist\scoop-bucket')
)

# Generates a Scoop bucket (one JSON manifest per installable package) from
# the WPM index. Only single-exe artifacts translate cleanly to Scoop shims;
# multi-file/DLL packages rely on the WPM shim layout and are skipped here.

$ErrorActionPreference = 'Stop'
$index = Get-Content -Raw -LiteralPath $IndexPath | ConvertFrom-Json

if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutDir | Out-Null

$generated = 0
foreach ($pkg in $index.packages) {
  $art = $pkg.artifacts.'windows-x64'
  if (-not $art) { continue }
  if (@($pkg.commands).Count -eq 0) { continue }
  if (@($art.files).Count -ne 1) { continue }

  $from = [string]$art.files[0].from
  $to = [string]$art.files[0].to
  if ($from -ne $to) { continue }

  $arch64 = @{ url = @([string]$art.urls[0]); hash = @([string]$art.sha256) }
  if ($from.Contains('/')) {
    $arch64.extract_dir = ($from -replace '/[^/]+$', '') -replace '/', '\'
  }

  $manifest = [ordered]@{
    version      = [string]$pkg.version
    description  = [string]$pkg.description
    license      = [string]$pkg.license
    architecture = @{ '64bit' = $arch64 }
    bin          = @([string]$to)
  }

  ($manifest | ConvertTo-Json -Depth 8) |
    Set-Content -LiteralPath (Join-Path $OutDir "$($pkg.name).json") -Encoding utf8
  $generated++
}

"Generated $generated scoop manifests -> $OutDir"