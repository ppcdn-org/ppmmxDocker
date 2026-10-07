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

  Otherwise it does the same thing deploy.sh does: clones ppmmxDocker if
  you're not already inside a checkout, auto-detects your public IP unless
  you pass -WebrtcHost, writes .env with your credentials, and runs
  `docker compose up -d --build`.

.PARAMETER LicenseCode
  Required. From the console's "ppmmx 节点" tab (looks like lic_...).

.PARAMETER NodeSecret
  Required. Same place, paired with the license code (looks like nsk_...).

.PARAMETER Role
  standalone (default) | origin | edge | record - must match what you
  picked in the console.

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
  .\deploy.ps1 -LicenseCode lic_xxx -NodeSecret nsk_xxx
.EXAMPLE
  .\deploy.ps1 -LicenseCode lic_xxx -NodeSecret nsk_xxx -Role origin -WebrtcHost 1.2.3.4
#>
param(
  # Not [Parameter(Mandatory)] on purpose: that makes PowerShell prompt
  # interactively for a missing value instead of failing fast, which is the
  # wrong behavior for a script meant to be run (or piped into) headlessly.
  # Checked by hand below instead.
  [string]$LicenseCode = '',
  [string]$NodeSecret = '',
  [ValidateSet('standalone', 'origin', 'edge', 'record')]
  [string]$Role = 'standalone',
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

if ([string]::IsNullOrWhiteSpace($LicenseCode) -or [string]::IsNullOrWhiteSpace($NodeSecret)) {
  Write-Host "ERROR: -LicenseCode and -NodeSecret are both required" -ForegroundColor Red
  Write-Host ""
  Write-Host "Usage: .\deploy.ps1 -LicenseCode lic_xxx -NodeSecret nsk_xxx [options]"
  Write-Host "See the comment-based help for all options: Get-Help .\deploy.ps1 -Full"
  exit 1
}
if ($LicenseCode -notlike 'lic_*') {
  Write-Warning "-LicenseCode doesn't look like 'lic_...' - double check you copied the right value from console"
}
if ($NodeSecret -notlike 'nsk_*') {
  Write-Warning "-NodeSecret doesn't look like 'nsk_...' - double check you copied the right value from console"
}

Write-Host "[1/5] Checking Docker Desktop ..."
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

Write-Host "[2/5] Locating ppmmxDocker ..."
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
  Write-Host "[3/5] Detecting this host's public IP ..."
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
  Write-Host "[3/5] Using provided -WebrtcHost: $WebrtcHost"
}

Write-Host "[4/5] Writing .env ..."
$envLines = @(
  "MMX_ROLE=$Role",
  "MMX_NODE_SECRET=$NodeSecret",
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

Write-Host "[5/5] Starting (docker compose up -d --build) ..."
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
