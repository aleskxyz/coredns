#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Idempotent CoreDNS (aleskxyz) Windows setup: download, config, service, start, adapter DNS.

  Run (Administrator console). Do not use ".\script.ps1" alone if policy blocks it — that hits
  PSSecurityException ("running scripts is disabled"). Always use Bypass for this file, e.g.:
    powershell.exe -ExecutionPolicy Bypass -File "C:\Users\YOU\Desktop\coredns.ps1"
    powershell.exe -ExecutionPolicy Bypass -File .\docs\install-windows-aleskxyz.ps1

  If coredns.exe is already installed and matches $Ver: skips download, extract, copy, and service delete.
  Full remove: -Uninstall (service, dirs, temp zip/stage; adapter DNS set to same defaults as Linux uninstall — 217.218.127.127 / 217.218.155.155 on IPv4, IPv6 back to DHCP).

  Optional one-time for your user (then .\ may work): Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
#>
param(
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

function Remove-CoreDnsService {
  param([switch]$ForUninstall)

  $svc = Get-Service -Name CoreDNS -ErrorAction SilentlyContinue
  if ($null -eq $svc) {
    if ($ForUninstall) {
      Write-Host '[CoreDNS] Uninstall: CoreDNS service was not registered.' -ForegroundColor Gray
    }
    else {
      Write-Host '[CoreDNS] No existing Windows service; binary can be replaced safely.' -ForegroundColor Gray
    }
    return
  }

  if ($ForUninstall) {
    Write-Host '[CoreDNS] Uninstall: stopping and removing Windows service...' -ForegroundColor Cyan
  }
  else {
    Write-Host '[CoreDNS] Stopping/removing Windows service so coredns.exe can be updated...' -ForegroundColor Cyan
  }
  if ($svc.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
    Stop-Service -Name CoreDNS -Force -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
      $s = Get-Service -Name CoreDNS -ErrorAction SilentlyContinue
      if ($null -eq $s) { break }
      if ($s.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped) { break }
      Start-Sleep -Milliseconds 300
    }
    $s = Get-Service -Name CoreDNS -ErrorAction SilentlyContinue
    if ($null -ne $s -and $s.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
      throw 'CoreDNS did not stop within 60s; close handles or reboot and re-run.'
    }
  }

  Write-Host '[CoreDNS] Deleting service registration (sc delete)...' -ForegroundColor Cyan
  $p = Start-Process -FilePath sc.exe -ArgumentList @('delete', 'CoreDNS') -Wait -NoNewWindow -PassThru
  # 0 = deleted; 1060 = already absent (race); 1072 = still pending deletion — keep waiting below.
  if ($p.ExitCode -notin 0, 1060, 1072) {
    throw "sc.exe delete CoreDNS failed (exit $($p.ExitCode))"
  }

  $deadline = (Get-Date).AddSeconds(60)
  while ($null -ne (Get-Service -Name CoreDNS -ErrorAction SilentlyContinue)) {
    if ((Get-Date) -gt $deadline) {
      throw 'CoreDNS service still registered after delete; reboot or remove manually, then re-run.'
    }
    Start-Sleep -Milliseconds 300
  }
  if ($ForUninstall) {
    Write-Host '[CoreDNS] Uninstall: service removed.' -ForegroundColor Gray
  }
  else {
    Write-Host '[CoreDNS] Service unregistered; continuing.' -ForegroundColor Gray
  }
}

function Start-CoreDnsServiceIdempotent {
  $svc = Get-Service -Name CoreDNS -ErrorAction Stop
  if ($svc.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
    Write-Host '[CoreDNS] Service already running.' -ForegroundColor Gray
    return
  }
  Write-Host '[CoreDNS] Starting CoreDNS service...' -ForegroundColor Cyan
  Start-Service -Name CoreDNS -ErrorAction Stop
  $svc.Refresh()
  $svc.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, (New-TimeSpan -Seconds 45))
}

function Test-InstalledCoreDnsMatchesVer {
  param(
    [Parameter(Mandatory)][string]$ExePath,
    [Parameter(Mandatory)][string]$WantVer
  )
  if (-not (Test-Path -LiteralPath $ExePath)) { return $false }
  try {
    $text = (& $ExePath -version 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return $text -match [regex]::Escape($WantVer)
  }
  catch {
    return $false
  }
}

$Ver = '1.14.3'
$ZipUrl = "https://raw.githubusercontent.com/aleskxyz/coredns/refs/heads/release/v$Ver/coredns_${Ver}_windows_amd64.zip"
$Stage = Join-Path $env:TEMP 'coredns-win'
$Zip = Join-Path $env:TEMP "coredns_${Ver}_windows_amd64.zip"
$BinDir = 'C:\Program Files\CoreDNS'
$Data = 'C:\ProgramData\coredns'
$exe = Join-Path $BinDir 'coredns.exe'

if ($Uninstall) {
  Write-Host '[CoreDNS] Uninstall: removing service, install/data directories, temp artifacts; setting adapter DNS to post-uninstall defaults (IPv4: 217.218.127.127, 217.218.155.155; IPv6: DHCP)...' -ForegroundColor Cyan

  Remove-CoreDnsService -ForUninstall

  if (Test-Path -LiteralPath $BinDir) {
    Write-Host "[CoreDNS] Uninstall: removing $BinDir" -ForegroundColor Cyan
    Remove-Item -LiteralPath $BinDir -Recurse -Force -ErrorAction Stop
  }
  else {
    Write-Host "[CoreDNS] Uninstall: not present: $BinDir" -ForegroundColor Gray
  }

  if (Test-Path -LiteralPath $Data) {
    Write-Host "[CoreDNS] Uninstall: removing $Data" -ForegroundColor Cyan
    Remove-Item -LiteralPath $Data -Recurse -Force -ErrorAction Stop
  }
  else {
    Write-Host "[CoreDNS] Uninstall: not present: $Data" -ForegroundColor Gray
  }

  Remove-Item -LiteralPath $Zip -Force -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $Stage -ErrorAction SilentlyContinue

  $dnsAfter4a = '217.218.127.127'
  $dnsAfter4b = '217.218.155.155'
  Write-Host "[CoreDNS] Uninstall: per-adapter DNS on Up adapters — IPv4 static $dnsAfter4a + $dnsAfter4b; IPv6 DHCP..." -ForegroundColor Cyan
  $dnsOk = 0
  $dnsFail = 0
  Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -eq 'Up' } |
    ForEach-Object {
      $na = $_
      try {
        $nameArg = 'name="{0}"' -f (($na.Name) -replace '"', '')
        $p4 = Start-Process -FilePath netsh.exe -ArgumentList @(
          'interface', 'ipv4', 'set', 'dnsservers',
          $nameArg,
          'source=static',
          ('address={0}' -f $dnsAfter4a),
          'validate=no'
        ) -Wait -NoNewWindow -PassThru
        if ($p4.ExitCode -ne 0) {
          throw ("netsh IPv4 DNS primary exit {0} on adapter {1}" -f $p4.ExitCode, $na.Name)
        }
        $p4b = Start-Process -FilePath netsh.exe -ArgumentList @(
          'interface', 'ipv4', 'add', 'dnsservers',
          $nameArg,
          ('address={0}' -f $dnsAfter4b),
          'index=2',
          'validate=no'
        ) -Wait -NoNewWindow -PassThru
        if ($p4b.ExitCode -ne 0) {
          Write-Warning ("[CoreDNS] Uninstall: netsh IPv4 add secondary DNS exit {0} on adapter {1}" -f $p4b.ExitCode, $na.Name)
        }
        $p6 = Start-Process -FilePath netsh.exe -ArgumentList @(
          'interface', 'ipv6', 'set', 'dnsservers', $nameArg, 'source=dhcp'
        ) -Wait -NoNewWindow -PassThru
        if ($p6.ExitCode -ne 0) {
          Write-Warning ("[CoreDNS] Uninstall: netsh IPv6 DNS to DHCP exit {0} on adapter {1}" -f $p6.ExitCode, $na.Name)
        }
        Write-Host ("[CoreDNS] Uninstall: DNS set: {0} (index {1})" -f $na.Name, $na.InterfaceIndex) -ForegroundColor Gray
        $script:dnsOk++
      }
      catch {
        $script:dnsFail++
        Write-Warning ("[CoreDNS] Uninstall: DNS failed on {0} (index {1}): {2}" -f $na.Name, $na.InterfaceIndex, $_.Exception.Message)
      }
    }
  Write-Host ("[CoreDNS] Uninstall: DNS summary: {0} ok, {1} failed (see warnings)." -f $dnsOk, $dnsFail) -ForegroundColor $(if ($dnsFail -gt 0) { 'Yellow' } else { 'Gray' })

  Write-Host '[CoreDNS] Uninstall finished.' -ForegroundColor Green
  exit 0
}

# Older Windows PowerShell defaults may not negotiate TLS 1.2 with GitHub.
if ([Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

Write-Host "[CoreDNS] Setup starting (CoreDNS $Ver)." -ForegroundColor Cyan

Write-Host '[CoreDNS] Ensuring install directories exist...' -ForegroundColor Cyan
New-Item -ItemType Directory -Path $BinDir, $Data -Force | Out-Null

$skipBinaryInstall = Test-InstalledCoreDnsMatchesVer -ExePath $exe -WantVer $Ver
if ($skipBinaryInstall) {
  Write-Host "[CoreDNS] Binary already present and reports $Ver; skipping download and install." -ForegroundColor Gray
}
else {
  # Must stop/remove service before replacing coredns.exe (otherwise copy can fail on re-run).
  Remove-CoreDnsService

  Remove-Item -Recurse -Force $Stage -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $Stage -Force | Out-Null

  Write-Host "[CoreDNS] Downloading release zip..." -ForegroundColor Cyan
  $zipPart = $Zip + '.download'
  try {
    $iwParams = @{ Uri = $ZipUrl; OutFile = $zipPart; UseBasicParsing = $true }
    Invoke-WebRequest @iwParams
    Move-Item -LiteralPath $zipPart -Destination $Zip -Force
  }
  catch {
    Remove-Item -LiteralPath $zipPart -Force -ErrorAction SilentlyContinue
    throw
  }
  Write-Host "[CoreDNS] Saved: $Zip" -ForegroundColor Gray

  Write-Host '[CoreDNS] Extracting zip...' -ForegroundColor Cyan
  Expand-Archive -Path $Zip -DestinationPath $Stage -Force
  $stagedExe = Join-Path $Stage 'coredns.exe'
  if (-not (Test-Path -LiteralPath $stagedExe)) {
    throw "Release zip did not contain coredns.exe at root: $stagedExe"
  }
  Write-Host "[CoreDNS] Installing binary to: $exe" -ForegroundColor Cyan
  Copy-Item -LiteralPath $stagedExe -Destination $exe -Force
  Write-Host '[CoreDNS] Binary version:' -ForegroundColor Cyan
  & $exe -version
  Remove-Item -LiteralPath $Zip -Force -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $Stage -ErrorAction SilentlyContinue
}

$res = Join-Path $Data 'resolvers'
$resLines = @(
  'nameserver 194.225.152.10',
  'nameserver 194.225.62.80',
  'nameserver 217.218.127.127',
  'nameserver 217.218.155.155',
  'nameserver 2.188.21.100',
  'nameserver 2.188.21.120',
  'nameserver 2.188.21.190',
  'nameserver 2.188.21.230',
  'nameserver 2.188.21.240',
  'nameserver 2.188.21.90',
  'nameserver 2.189.44.44',
  'nameserver 46.209.157.19',
  'nameserver 95.38.102.86',
  'nameserver 1.1.1.1',
  'nameserver 8.8.8.8'
)
Write-Host "[CoreDNS] Writing resolvers: $res" -ForegroundColor Cyan
$resLines | Set-Content -Path $res -Encoding ascii -Force

$core = Join-Path $Data 'Corefile'
$coreLines = @(
  '.:53 {',
  '    bind 127.0.0.1 ::1',
  '',
  '    cache 3600 {',
  '        success 65536 3600',
  '        denial 65536 1800',
  '        serve_stale 720h immediate',
  '        prefetch 2 1m 20%',
  '        servfail 5s',
  '    }',
  '',
  '    fanout . C:/ProgramData/coredns/resolvers {',
  '        race',
  '        race-continue-on-error',
  '        attempt-count 0',
  '        timeout 5s',
  '    }',
  '',
  '    log',
  '    errors',
  '}'
)
Write-Host "[CoreDNS] Writing Corefile: $core" -ForegroundColor Cyan
$coreLines | Set-Content -Path $core -Encoding ascii -Force

Write-Host '[CoreDNS] Config file paths:' -ForegroundColor Cyan
Write-Host ("  Resolvers: {0}" -f $res) -ForegroundColor Gray
Write-Host ("  Corefile:  {0}" -f $core) -ForegroundColor Gray

$conf = Join-Path $Data 'Corefile'
# CoreDNS must receive -windows-service so coremain registers with SCM (svc.Run); without it,
# Windows reports "did not respond to the start or control request in a timely fashion."
$bp = "`"$exe`" -windows-service -conf=`"$conf`""
$svcExisting = Get-Service -Name CoreDNS -ErrorAction SilentlyContinue
if ($null -eq $svcExisting) {
  Write-Host '[CoreDNS] Registering Windows service (startup: Automatic)...' -ForegroundColor Cyan
  New-Service -Name CoreDNS -BinaryPathName $bp -DisplayName 'CoreDNS' -StartupType Automatic -ErrorAction Stop | Out-Null
}
else {
  Write-Host '[CoreDNS] Windows service already registered; skipping New-Service.' -ForegroundColor Gray
  if ($skipBinaryInstall) {
    Write-Host '[CoreDNS] Restarting service to pick up config file changes...' -ForegroundColor Cyan
    Restart-Service -Name CoreDNS -Force -ErrorAction Stop
    $svcExisting.Refresh()
    $svcExisting.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, (New-TimeSpan -Seconds 45))
  }
}

Start-CoreDnsServiceIdempotent
Write-Host '[CoreDNS] Service status:' -ForegroundColor Cyan
Get-Service -Name CoreDNS | Format-Table -AutoSize Status,Name,StartType

# netsh for IPv4 and IPv6 (same path on all supported Windows; no Set-DnsClientServerAddress -AddressFamily).
$dns4 = '127.0.0.1'
$dns6 = '::1'
Write-Host "[CoreDNS] Setting per-adapter DNS via netsh to $dns4 (IPv4) and $dns6 (IPv6) on Up adapters..." -ForegroundColor Cyan
$dnsOk = 0
$dnsFail = 0
Get-NetAdapter -ErrorAction SilentlyContinue |
  Where-Object { $_.Status -eq 'Up' } |
  ForEach-Object {
    $na = $_
    try {
      $ifName = $na.Name
      $nameArg = 'name="{0}"' -f ($ifName -replace '"', '')
      $p4 = Start-Process -FilePath netsh.exe -ArgumentList @(
        'interface', 'ipv4', 'set', 'dnsservers',
        $nameArg,
        'source=static',
        ('address={0}' -f $dns4),
        'validate=no'
      ) -Wait -NoNewWindow -PassThru
      if ($p4.ExitCode -ne 0) {
        throw ("netsh IPv4 DNS exit {0} on adapter {1}" -f $p4.ExitCode, $ifName)
      }
      $p6 = Start-Process -FilePath netsh.exe -ArgumentList @(
        'interface', 'ipv6', 'set', 'dnsservers',
        $nameArg,
        'source=static',
        ('address={0}' -f $dns6),
        'validate=no'
      ) -Wait -NoNewWindow -PassThru
      if ($p6.ExitCode -ne 0) {
        Write-Warning ("[CoreDNS] netsh IPv6 DNS exit {0} on adapter {1} (IPv4 set to {2})." -f $p6.ExitCode, $ifName, $dns4)
      }
      Write-Host ("[CoreDNS] DNS set: {0} (index {1})" -f $na.Name, $na.InterfaceIndex) -ForegroundColor Gray
      $script:dnsOk++
    }
    catch {
      $script:dnsFail++
      Write-Warning ("DNS not set on adapter {0} (index {1}): {2}" -f $na.Name, $na.InterfaceIndex, $_.Exception.Message)
    }
  }
Write-Host ("[CoreDNS] Adapter DNS summary: {0} ok, {1} skipped/failed (see warnings)." -f $dnsOk, $dnsFail) -ForegroundColor $(if ($dnsFail -gt 0) { 'Yellow' } else { 'Gray' })

Write-Host 'CoreDNS setup finished.' -ForegroundColor Green
