param(
  [string]$IndexPath = (Join-Path $PSScriptRoot '..\index.json'),
  [int]$TimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$index = Get-Content -Raw -LiteralPath $IndexPath | ConvertFrom-Json
$pending = @()
foreach ($pkg in $index.packages) {
  $art = $pkg.artifacts.'windows-x64'
  if ($null -eq $art) { continue }
  $hasSize = $art.PSObject.Properties.Name -contains 'size'
  if (-not $hasSize -and $art.urls.Count -gt 0) {
    $pending += [pscustomobject]@{ name = $pkg.name; url = $art.urls[0] }
  }
}

"Packages missing size: $($pending.Count)"

$updated = 0
$failed = @()
foreach ($item in $pending) {
  try {
    $resp = Invoke-WebRequest -Uri $item.url -Method Head -TimeoutSec $TimeoutSeconds -MaximumRedirection 10
    $len = $resp.Headers.'Content-Length'
    if ($len -is [array]) { $len = $len[0] }
    $size = [int64]$len
    if ($size -gt 0) {
      $pkg = $index.packages | Where-Object { $_.name -eq $item.name }
      if (-not ($pkg.artifacts.'windows-x64'.PSObject.Properties.Name -contains 'size')) {
        $pkg.artifacts.'windows-x64' | Add-Member -NotePropertyName 'size' -NotePropertyValue $size
      } else {
        $pkg.artifacts.'windows-x64'.size = $size
      }
      $updated++
      Write-Host "OK   $($item.name): $size" -ForegroundColor Green
    } else {
      $failed += $item.name
      Write-Host "ZERO $($item.name)" -ForegroundColor Yellow
    }
  } catch {
    $failed += $item.name
    Write-Host "FAIL $($item.name): $($_.Exception.Message.Split([Environment]::NewLine)[0])" -ForegroundColor Yellow
  }
}

$json = $index | ConvertTo-Json -Depth 32
$json.TrimEnd() + [Environment]::NewLine | Set-Content -LiteralPath $IndexPath -Encoding utf8

"Updated: $updated / Failed: $($failed.Count)"
if ($failed.Count -gt 0) { '  ' + ($failed -join ', ') }