Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Die([string]$msg) {
  Write-Error $msg
  exit 1
}

$envFile = '.env'

# Get TUNNEL_TOKEN: prefer environment variable, else read from .env
$token = $env:TUNNEL_TOKEN

if (-not $token -and (Test-Path -LiteralPath $envFile)) {
  foreach ($line in Get-Content -LiteralPath $envFile) {
    if ($line -match '^\s*TUNNEL_TOKEN\s*=\s*(.+?)\s*$') {
      $token = $Matches[1].Trim()
      break
    }
  }
}

if (-not $token) {
  Die 'TUNNEL_TOKEN is not set. Set it in .env or in the environment (PowerShell): $env:TUNNEL_TOKEN="..."'
}

# Detect LAN IPv4 address via default route interface
$lanIp = $null

try {
  $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1
  if (-not $route) { throw 'No default route found' }

  $ipObj = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex |
    Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
    Sort-Object PrefixLength |
    Select-Object -First 1

  if (-not $ipObj) { throw 'No IPv4 found on default route interface' }
  $lanIp = $ipObj.IPAddress
}
catch {
  $ipObj = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
    Select-Object -First 1

  if (-not $ipObj) { Die 'Could not detect LAN IPv4 address.' }
  $lanIp = $ipObj.IPAddress
}

# Write .env deterministically
$envContents = 'LAN_IP=' + $lanIp + "`r`n" + 'TUNNEL_TOKEN=' + $token + "`r`n"
Set-Content -LiteralPath $envFile -Value $envContents -Encoding ASCII

Write-Output ('Wrote ' + $envFile + ':')
Get-Content -LiteralPath $envFile
Write-Output ''

Write-Debug ('Running docker compose up with LAN_IP=' + $lanIp)

docker compose up -d

Write-Output ''
Write-Output ('Up. AdGuard setup UI: http://' + $lanIp + ':3000')
