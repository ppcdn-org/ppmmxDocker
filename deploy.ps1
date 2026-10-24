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
  Max concurrent publish+play channels. Default: 1000 (effectively unlimited -
  the software does not cap the node; the real limit is its hardware)

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

.PARAMETER RtmpPort
  Host port for Enhanced RTMP (ERTMP) ingest (TCP). Default: 1935

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
  [int]$Capacity = 1000,
  [string]$WebrtcHost = '',
  [int]$WebrtcPort = 8888,
  [int]$UdpPort = 8188,
  [int]$AdminPort = 8080,
  [int]$ApiPort = 9996,
  [int]$SrtPort = 7890,
  [int]$RtmpPort = 1935
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

# Provision the node's public HTTPS hostname. ppcenter assigns a stable random
# <prefix>-<random>.<nodeDomain> and publishes the DNS A record, so the node can
# serve WHEP over TLS (a browser on an https player page blocks a plain-http
# edge). Best-effort: when ppcenter has no cloudflare config, keep the bare-IP
# http base and leave Caddy idle.
$WebrtcBaseUrl = "http://${WebrtcHost}:${WebrtcPort}"
$publicHostname = ''
Write-Host "[4b/6] Provisioning public HTTPS hostname ..."
try {
  $provApi = Get-ApiBaseFromControlUrl -Url $ControlUrl
  $provBody = @{ licenseCode = $LicenseCode; publicIp = $WebrtcHost } | ConvertTo-Json
  $prov = Invoke-RestMethod -Uri "$provApi/v1/ppmmx/provision" -Method Post -ContentType 'application/json' -Body $provBody -TimeoutSec 10
  $publicHostname = "$($prov.data.publicHostname)"
} catch {
  Write-Host "      provision call failed: $($_.Exception.Message)" -ForegroundColor Yellow
}
if (-not [string]::IsNullOrWhiteSpace($publicHostname)) {
  Write-Host "      -> https://$publicHostname"
  $WebrtcBaseUrl = "https://$publicHostname"
  $caddyfile = "# Generated by deploy.ps1 - do not edit by hand.`n" +
    "# TLS front for the node's WHEP/ABR endpoint; proxies to the local mmx`n" +
    "# WebRTC HTTP server (which keeps serving plain HTTP for forwardMmx).`n" +
    "$publicHostname {`n`treverse_proxy 127.0.0.1:$WebrtcPort`n}"
  Set-Content -LiteralPath 'Caddyfile' -Value $caddyfile -Encoding utf8 -NoNewline
} else {
  Write-Host "      -> no hostname (ppcenter cloudflare not configured); keeping $WebrtcBaseUrl"
  Set-Content -LiteralPath 'Caddyfile' -Value '' -Encoding utf8
}

Write-Host "[5/6] Writing .env ..."
# SRT ingest address advertised to ppcenter. Advertised by origin AND
# standalone (a standalone ingests SRT/WHIP and serves WHEP itself, so it must
# be schedulable for its owner's apps). ERTMP is advertised by both too: both
# roles run the rtmp listener, and without it ppcenter answers no_healthy_origin.
$publishUrl = ''
$rtmpPublishUrl = ''
if ($Role -eq 'origin' -or $Role -eq 'standalone') {
  $publishUrl = "${WebrtcHost}:${SrtPort}"
}
if ($Role -eq 'origin' -or $Role -eq 'standalone') {
  $rtmpPublishUrl = "${WebrtcHost}:${RtmpPort}"
}
$envLines = @(
  "MMX_ROLE=$Role",
  "MMX_LICENSE_CODE=$LicenseCode",
  "MMX_CONTROL_URL=$ControlUrl",
  "MMX_NODE_REGION=$Region",
  "MMX_NODE_CAPACITY=$Capacity",
  "MMX_WEBRTC_BASE_URL=$WebrtcBaseUrl",
  "MMX_PUBLISH_URL=$publishUrl",
  "MMX_RTMP_PUBLISH_URL=$rtmpPublishUrl",
  "MMX_WEBRTC_PORT=$WebrtcPort",
  "MMX_WEBRTC_UDP_PORT=$UdpPort",
  "MMX_ADMIN_PORT=$AdminPort",
  "MMX_API_PORT=$ApiPort",
  "MMX_SRT_PORT=$SrtPort",
  "MMX_RTMP_PORT=$RtmpPort"
)
Set-Content -LiteralPath '.env' -Value $envLines -Encoding utf8

# Public reachability: WebRTC media (WHIP publish / WHEP playback) uses ICE
# candidates gathered from the node's own interfaces, so under the default
# bridge network the container only advertises its private 172.x address -
# external publishers/viewers reach the signaling port but never the media, and
# every WebRTC stream fails to start. Switch the ppmmx service to host
# networking and drop the now-ignored ports block (see README "公网可达性").
$composePath = 'docker-compose.yml'
$compose = Get-Content -LiteralPath $composePath -Raw
if ($compose -match '(?m)^    # network_mode: host') {
  Write-Host "[5b/6] Enabling host networking on the ppmmx container ..."
  $compose = $compose -replace '(?m)^    # network_mode: host', '    network_mode: host'
  $compose = [regex]::Replace($compose, "(?ms)\r?\n    ports:\r?\n(?:      - .*\r?\n)+", "`n")
  Set-Content -LiteralPath $composePath -Value $compose -Encoding utf8
}

# ICE candidates: the template's webrtcIPsFromInterfaces: true advertises every
# interface address - private NICs, loopback and docker bridges as well as the
# public IP. On multi-NIC hosts the publisher/viewer then walks those dead
# pairs first, so WHIP/WHEP connects slowly or not at all. Advertise only the
# host's public address; docker-compose.override.yml is merged over the base
# compose and wins over both the bundled template and a custom mmx.yml.
$overrideLines = @(
  '# Generated by deploy.ps1 - do not edit by hand.',
  'services:',
  '  ppmmx:',
  '    environment:',
  '      MTX_WEBRTCIPSFROMINTERFACES: "no"',
  "      MTX_WEBRTCADDITIONALHOSTS: `"$WebrtcHost`""
)
Set-Content -LiteralPath 'docker-compose.override.yml' -Value $overrideLines -Encoding utf8

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
if ($Role -eq 'standalone' -or $Role -eq 'origin') {
  Write-Host "  $RtmpPort/tcp   Enhanced RTMP (ERTMP) 推流（如果用 ERTMP 推流）"
}
if (-not [string]::IsNullOrWhiteSpace($publicHostname)) {
  Write-Host "  80/tcp, 443/tcp   HTTPS 播放入口（WHEP/TLS 证书自动签发，浏览器播放必需）"
}
Write-Host "不建议公网暴露 $AdminPort/tcp（admin 管理界面）。"
Write-Host ""
Write-Host "几分钟内回到控制台的 ppmmx 节点列表确认状态变为「运行中」。"
