<#
.SYNOPSIS
  One-click deploy script for a self-hosted ppmmx node on Windows - run this
  yourself on the machine you want the node to live on.

.DESCRIPTION
  Requires Docker Desktop (with WSL2 or Hyper-V backend) to already be
  installed and running - unlike the Linux deploy.sh, this script does NOT
  install Docker for you: Docker Desktop's installer is interactive and
  usually needs a reboot, which isn't safe to automate. If Docker Desktop
  isn't found, this script prints the download link and exits.

  Otherwise it does the same thing deploy.sh does: resolves your node's role
  from ppcenter using just -LicenseCode, clones ppmmxDocker if you're not
  already inside a checkout, auto-detects your public IP unless you pass
  -WebrtcHost, writes .env with your credentials, and runs
  `docker compose up -d --build`.

.PARAMETER LicenseCode
  Required. From the console's "ppmmx 节点" tab (looks like lic_...). This is
  the ONLY credential you need: nodeSecret and the node's type (standalone/
  origin/edge/record) were already decided when you created the node in
  console, so this script resolves them from ppcenter automatically - see
  "[1/6]" below.

.PARAMETER Role
  standalone | origin | edge | record - normally auto-resolved from
  -LicenseCode (see "[1/6]"); pass this to skip that lookup and force a role.

.PARAMETER ControlUrl
  ppcenter WS control-plane address. Default: wss://api.pp-cdn.org/ws/mmx

.PARAMETER Region
  Free-text label shown in ppcenter. Default: self-hosted

.PARAMETER Capacity
  Max concurrent publish+play channels. Default: 100

.PARAMETER WebrtcHost
  This host's public IP/domain, so viewers and publishers can reach it.
  Default: auto-detected.

.PARAMETER WebrtcPort
  Host port for WebRTC/WHIP/WHEP. Default: 8888

.PARAMETER UdpPort
  Host port for WebRTC ICE (UDP). Default: 8188

.PARAMETER AdminPort
  Host port for the admin UI. Default: 8080

.PARAMETER ApiPort
  Host port for the internal control API. Default: 9996

.PARAMETER SrtPort
  Host port for SRT ingest (UDP). Default: 7890

.EXAMPLE
  .\deploy.ps1 -LicenseCode lic_xxx
.EXAMPLE
  .\deploy.ps1 -LicenseCode lic_xxx -WebrtcHost 1.2.3.4
#>
param(
  # Not [Parameter(Mandatory)] on purpose: that makes PowerShell prompt
  # interactively for a missing value instead of failing fast, which is the
  # wrong behavior for a script meant to be run (or piped into) headlessly.
  # Checked by hand below instead.
  [string]$LicenseCode = '',
  # No [ValidateSet] here either, for the same reason: validating a literal
  # default ('') against the set would itself fail. Checked by hand below,
  # only when non-empty (empty means "auto-resolve from -LicenseCode").
  [string]$Role = '',
  [string]$ControlUrl = 'wss://api.pp-cdn.org/ws/mmx',
  [string]$Region = 'self-hosted',
  [int]$Capacity = 100,
  [string]$WebrtcHost = '',
  [int]$WebrtcPort = 8888,
  [int]$UdpPort = 8188,
  [int]$AdminPort = 8080,
  [int]$ApiPort = 9996,
  [int]$SrtPort = 7890
)

$ErrorActionPreference = 'Stop'
$RepoUrl = 'https://github.com/ppcdn-org/ppmmxDocker.git'

if ([string]::IsNullOrWhiteSpace($LicenseCode)) {
  Write-Host "ERROR: -LicenseCode is required" -ForegroundColor Red
  Write-Host ""
  Write-Host "Usage: .\deploy.ps1 -LicenseCode lic_xxx [options]"
  Write-Host "See the comment-based help for all options: Get-Help .\deploy.ps1 -Full"
  exit 1
}
if ($LicenseCode -notlike 'lic_*') {
  Write-Warning "-LicenseCode doesn't look like 'lic_...' - double check you copied the right value from console"
}
if (-not [string]::IsNullOrWhiteSpace($Role) -and $Role -notin @('standalone', 'origin', 'edge', 'record')) {
  Write-Host "ERROR: -Role must be one of standalone/origin/edge/record, got '$Role'" -ForegroundColor Red
  exit 1
}

function Get-ApiBaseFromControlUrl {
  # Derives the REST API base (https://host) from the WS control URL
  # (wss://host/ws/mmx) so the bootstrap lookup below always targets the
  # same ppcenter -ControlUrl points at, without a separate parameter to
  # keep in sync.
  param([string]$Url)
  $u = $Url -replace '/ws/mmx$', ''
  if ($u -like 'wss://*') { return 'https://' + $u.Substring(6) }
  if ($u -like 'ws://*') { return 'http://' + $u.Substring(5) }
  return $u
}

if ([string]::IsNullOrWhiteSpace($Role)) {
  Write-Host "[1/6] Resolving node role from -LicenseCode ..."
  $apiBase = Get-ApiBaseFromControlUrl -Url $ControlUrl
  $bootstrapUrl = "$apiBase/v1/ppmmx/bootstrap?licenseCode=$([uri]::EscapeDataString($LicenseCode))"
  try {
    $bootstrap = Invoke-RestMethod -Uri $bootstrapUrl -TimeoutSec 10
  } catch {
    $detail = $_.ErrorDetails.Message
    if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $_.Exception.Message }
    Write-Host "ERROR: could not resolve this license code against ${apiBase}: $detail" -ForegroundColor Red
    Write-Host "       double check -LicenseCode, or pass -Role explicitly to skip this lookup"
    exit 1
  }
  switch ($bootstrap.data.nodeType) {
    'NODE_ROLE_STANDALONE' { $Role = 'standalone' }
    'NODE_ROLE_ORIGIN' { $Role = 'origin' }
    'NODE_ROLE_EDGE' { $Role = 'edge' }
    'NODE_ROLE_RECORDER' { $Role = 'record' }
    default {
      Write-Host "ERROR: ppcenter returned an unexpected nodeType '$($bootstrap.data.nodeType)' for this license code" -ForegroundColor Red
      exit 1
    }
  }
  Write-Host "      -> role=$Role"
} else {
  Write-Host "[1/6] Using provided -Role: $Role (skipping license-code lookup)"
}

Write-Host "[2/6] Checking Docker Desktop ..."
$dockerOk = $false
try {
  docker version *> $null
  if ($?) { $dockerOk = $true }
} catch {}
if (-not $dockerOk) {
  Write-Host ""
  Write-Host "ERROR: Docker Desktop not found or not running." -ForegroundColor Red
  Write-Host "Install it first (needs WSL2 or Hyper-V), start it, then re-run this script:"
  Write-Host "  https://www.docker.com/products/docker-desktop/"
  exit 1
}
Write-Host "      found: $(docker --version)"
docker compose version *> $null
if (-not $?) {
  Write-Host "ERROR: 'docker compose' is unavailable even though Docker is installed - update Docker Desktop." -ForegroundColor Red
  exit 1
}

Write-Host "[3/6] Locating ppmmxDocker ..."
if (-not (Test-Path -LiteralPath 'docker-compose.yml')) {
  Write-Host "      docker-compose.yml not found in $(Get-Location), cloning the repo ..."
  $gitOk = $false
  try { git --version *> $null; if ($?) { $gitOk = $true } } catch {}
  if ($gitOk) {
    git clone --depth 1 $RepoUrl ppmmxDocker
    if (-not $?) { throw "git clone failed" }
  } else {
    Write-Host "      git not found, downloading a zip snapshot instead ..."
    $zipUrl = 'https://github.com/ppcdn-org/ppmmxDocker/archive/refs/heads/main.zip'
    $zipPath = Join-Path $env:TEMP 'ppmmxDocker.zip'
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    Expand-Archive -LiteralPath $zipPath -DestinationPath . -Force
    Rename-Item -LiteralPath 'ppmmxDocker-main' -NewName 'ppmmxDocker'
    Remove-Item -LiteralPath $zipPath -Force
  }
  Set-Location 'ppmmxDocker'
} else {
  Write-Host "      already in a ppmmxDocker checkout: $(Get-Location)"
}

if ([string]::IsNullOrWhiteSpace($WebrtcHost)) {
  Write-Host "[4/6] Detecting this host's public IP ..."
  try {
    $WebrtcHost = (Invoke-RestMethod -Uri 'https://ifconfig.me' -TimeoutSec 5).Trim()
  } catch {
    try {
      $WebrtcHost = (Invoke-RestMethod -Uri 'https://icanhazip.com' -TimeoutSec 5).Trim()
    } catch {
      Write-Host "ERROR: could not auto-detect a public IP (no outbound internet?); pass -WebrtcHost <ip-or-domain> explicitly" -ForegroundColor Red
      exit 1
    }
  }
  Write-Host "      -> $WebrtcHost"
} else {
  Write-Host "[4/6] Using provided -WebrtcHost: $WebrtcHost"
}

Write-Host "[5/6] Writing .env ..."
$envLines = @(
  "MMX_ROLE=$Role",
  "MMX_LICENSE_CODE=$LicenseCode",
  "MMX_CONTROL_URL=$ControlUrl",
  "MMX_NODE_REGION=$Region",
  "MMX_NODE_CAPACITY=$Capacity",
  "MMX_WEBRTC_BASE_URL=http://${WebrtcHost}:${WebrtcPort}",
  "MMX_PUBLISH_URL=",
  "MMX_WEBRTC_PORT=$WebrtcPort",
  "MMX_WEBRTC_UDP_PORT=$UdpPort",
  "MMX_ADMIN_PORT=$AdminPort",
  "MMX_API_PORT=$ApiPort",
  "MMX_SRT_PORT=$SrtPort"
)
Set-Content -LiteralPath '.env' -Value $envLines -Encoding utf8

Write-Host "[6/6] Starting (docker compose up -d --build) ..."
docker compose up -d --build
if (-not $?) { throw "docker compose up failed" }

Start-Sleep -Seconds 3
Write-Host ""
Write-Host "== container status =="
docker compose ps

$cwd = Get-Location
Write-Host ""
Write-Host "部署完成 / Done."
Write-Host ""
Write-Host "  查看日志 / follow logs:   cd `"$cwd`"; docker compose logs -f"
Write-Host "  停止节点 / stop:          cd `"$cwd`"; docker compose down"
Write-Host "  重新部署 / redeploy:      重新运行本脚本，或 docker compose up -d --build"
Write-Host ""
Write-Host "确保云厂商安全组/防火墙放行（本脚本不会帮你改这些）："
Write-Host "  $WebrtcPort/tcp   WHIP/WHEP (推流信令 + 播放)"
Write-Host "  $UdpPort/udp   WebRTC ICE 媒体（主要流量）"
if ($Role -eq 'standalone' -or $Role -eq 'origin') {
  Write-Host "  $SrtPort/udp   SRT 推流（如果用 SRT 推流）"
}
Write-Host "不建议公网暴露 $AdminPort/tcp（admin 管理界面）。"
Write-Host ""
Write-Host "几分钟内回到控制台的 ppmmx 节点列表确认状态变为「运行中」。"
