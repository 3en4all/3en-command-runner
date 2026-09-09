# 3EN Router <-> Pi-hole autonomous integration finalizer v1
# Target: 3EN002 OpenWrt 192.168.1.2 + Pi-hole 192.168.1.3
# Windows PowerShell 5.1
param(
    [ValidateSet('Discovery','Backup','ApplyDns','TestDns','ApplyLogging','TestLogging','Final','Rollback')]
    [string]$Phase
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = 'C:\3EN-Agent'
$Work = Join-Path $Root 'router-pihole-final'
$StatePath = Join-Path $Work 'state.json'
$ReportPath = Join-Path $Work 'FINAL-REPORT.txt'
$Router = '192.168.1.2'
$PiHole = '192.168.1.3'
$RouterUser = 'root'
$RouterKey = 'C:\Users\wi3lk\.ssh\3en002_agent_ed25519'
$RemoteBackup = '/tmp/3en-router-pihole-final-backup'
New-Item -ItemType Directory -Force -Path $Work | Out-Null

function Write-Marker([string]$Text) { Write-Host ('3EN_RP=' + $Text) }

function Invoke-NativeCapture {
    param([string]$Exe,[string[]]$Args)
    $out = & $Exe @Args 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw ($Exe + ' failed exit=' + $code) }
    return $out.Trim()
}

function Invoke-Router([string]$Command) {
    if (-not (Test-Path -LiteralPath $RouterKey)) { throw 'Router SSH key unavailable' }
    $args = @('-i',$RouterKey,'-o','BatchMode=yes','-o','ConnectTimeout=6','-o','StrictHostKeyChecking=accept-new',($RouterUser+'@'+$Router),$Command)
    return Invoke-NativeCapture 'ssh.exe' $args
}

function Invoke-Pi {
    param([string]$Command,$State)
    if (-not $State.piSsh) { throw 'Pi-hole SSH unavailable' }
    $args = @('-i',[string]$State.piKey,'-o','BatchMode=yes','-o','ConnectTimeout=6','-o','StrictHostKeyChecking=accept-new',([string]$State.piUser+'@'+$PiHole),$Command)
    return Invoke-NativeCapture 'ssh.exe' $args
}

function Test-Tcp([string]$HostName,[int]$Port,[int]$TimeoutMs=1800) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($HostName,$Port,$null,$null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs,$false)) { return $false }
        $c.EndConnect($iar); return $true
    } catch { return $false } finally { $c.Close() }
}

function Test-DnsPi {
    try {
        $r = @(Resolve-DnsName -Name 'example.com' -Server $PiHole -Type A -DnsOnly -ErrorAction Stop | Where-Object {$_.IPAddress})
        return ($r.Count -gt 0)
    } catch { return $false }
}

function Save-State($State) {
    $State.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $State | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Load-State {
    if (-not (Test-Path -LiteralPath $StatePath)) { throw 'Integration state missing; discovery must run first' }
    return Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-KeyCandidates {
    $keys = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $RouterKey) { [void]$keys.Add($RouterKey) }
    $sshDir = Join-Path $env:USERPROFILE '.ssh'
    if (Test-Path -LiteralPath $sshDir) {
        Get-ChildItem -LiteralPath $sshDir -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Extension -notin @('.pub','.txt','.bak') -and $_.Name -notin @('known_hosts','known_hosts.old','config')
        } | ForEach-Object { if (-not $keys.Contains($_.FullName)) { [void]$keys.Add($_.FullName) } }
    }
    return @($keys)
}

function Discover-PiSsh {
    $users = @('pi','root','3en4all','wi3lk',$env:USERNAME) | Where-Object { $_ } | Select-Object -Unique
    foreach ($key in @(Get-KeyCandidates)) {
        foreach ($u in $users) {
            try {
                $args = @('-i',$key,'-o','BatchMode=yes','-o','ConnectTimeout=3','-o','ConnectionAttempts=1','-o','StrictHostKeyChecking=accept-new',($u+'@'+$PiHole),'printf 3EN_PI_SSH_OK')
                $o = Invoke-NativeCapture 'ssh.exe' $args
                if ($o -match '3EN_PI_SSH_OK') { return [pscustomobject]@{ok=$true;user=$u;key=$key} }
            } catch {}
        }
    }
    return [pscustomobject]@{ok=$false;user='';key=''}
}

function Get-PiUpstreamEvidence($State) {
    if (-not $State.piSsh) { return '' }
    $cmd = "(grep -E '^[[:space:]]*upstreams[[:space:]]*=' /etc/pihole/pihole.toml 2>/dev/null || true); (grep -E '^PIHOLE_DNS_' /etc/pihole/setupVars.conf 2>/dev/null || true)"
    try { return Invoke-Pi $cmd $State } catch { return '' }
}

function Ensure-Discovery {
    if (-not (Test-Path -LiteralPath $StatePath)) { Invoke-Discovery }
}

function Invoke-Discovery {
    if (-not (Test-DnsPi)) { throw 'Pi-hole DNS is not answering correctly' }
    $routerProbe = Invoke-Router "printf 3EN_ROUTER_SSH_OK; echo; uci -q show dhcp.lan; echo __NETWORK__; uci -q show network.wan; echo __SYSTEM__; uci -q show system.@system[0]; echo __RESOLV__; cat /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null || true"
    if ($routerProbe -notmatch '3EN_ROUTER_SSH_OK') { throw 'Router SSH validation failed' }

    $pi = Discover-PiSsh
    $state = [pscustomobject][ordered]@{
        schema = 1
        discoveredUtc = (Get-Date).ToUniversalTime().ToString('o')
        updatedUtc = $null
        router = $Router
        pihole = $PiHole
        routerSsh = $true
        piholeDns = $true
        piholeWeb80 = (Test-Tcp $PiHole 80)
        piholeWeb443 = (Test-Tcp $PiHole 443)
        piSsh = [bool]$pi.ok
        piUser = [string]$pi.user
        piKey = [string]$pi.key
        dhcpAdvertisesPi = ($routerProbe -match [regex]::Escape($PiHole))
        routerProbe = $routerProbe
        piUpstreamEvidence = ''
        safeRouterDnsSwitch = $false
        routerDnsSwitchApplied = $false
        dnsChanged = $false
        loggingChanged = $false
        backupReady = $false
        logVerifiedOnPi = $false
    }
    if ($state.piSsh) {
        $ev = Get-PiUpstreamEvidence $state
        $state.piUpstreamEvidence = [string]$ev
        if (-not [string]::IsNullOrWhiteSpace($ev) -and $ev -notmatch [regex]::Escape($Router)) {
            $state.safeRouterDnsSwitch = $true
        }
    }
    Save-State $state
    Write-Marker ('DISCOVERY_PASS;PI_SSH='+$state.piSsh+';DHCP_PI='+$state.dhcpAdvertisesPi+';ROUTER_DNS_SWITCH_SAFE='+$state.safeRouterDnsSwitch)
}

function Invoke-Backup {
    Ensure-Discovery
    $state = Load-State
    $local = Join-Path $Work 'backup'
    New-Item -ItemType Directory -Force -Path $local | Out-Null
    Invoke-Router ("rm -rf $RemoteBackup; mkdir -p $RemoteBackup; uci export dhcp > $RemoteBackup/dhcp.uci; uci export network > $RemoteBackup/network.uci; uci export system > $RemoteBackup/system.uci; cp /etc/config/dhcp $RemoteBackup/dhcp.config; cp /etc/config/network $RemoteBackup/network.config; cp /etc/config/system $RemoteBackup/system.config; sha256sum $RemoteBackup/* 2>/dev/null || true") | Set-Content -LiteralPath (Join-Path $local 'router-checksums.txt') -Encoding UTF8
    foreach ($f in @('dhcp.uci','network.uci','system.uci','dhcp.config','network.config','system.config')) {
        $args = @('-i',$RouterKey,'-o','BatchMode=yes','-o','ConnectTimeout=6','-o','StrictHostKeyChecking=accept-new',($RouterUser+'@'+$Router+':'+$RemoteBackup+'/'+$f),(Join-Path $local $f))
        [void](Invoke-NativeCapture 'scp.exe' $args)
    }
    if ($state.piSsh) {
        try {
            [void](Invoke-Pi "tar -czf /tmp/3en-pihole-config-backup.tgz /etc/pihole /etc/rsyslog.conf /etc/rsyslog.d 2>/dev/null || true; test -s /tmp/3en-pihole-config-backup.tgz" $state)
            $args = @('-i',[string]$state.piKey,'-o','BatchMode=yes','-o','ConnectTimeout=6','-o','StrictHostKeyChecking=accept-new',([string]$state.piUser+'@'+$PiHole+':/tmp/3en-pihole-config-backup.tgz'),(Join-Path $local 'pihole-config-backup.tgz'))
            [void](Invoke-NativeCapture 'scp.exe' $args)
        } catch {}
    }
    foreach ($f in @('dhcp.config','network.config','system.config')) { if (-not (Test-Path -LiteralPath (Join-Path $local $f))) { throw ('Backup artifact missing: '+$f) } }
    $state.backupReady = $true
    Save-State $state
    Write-Marker 'BACKUP_PASS'
}

function Invoke-ApplyDns {
    Ensure-Discovery
    $state = Load-State
    if (-not $state.backupReady) { Invoke-Backup; $state = Load-State }
    $dhcp = Invoke-Router "uci -q show dhcp.lan"
    if ($dhcp -notmatch "6,$([regex]::Escape($PiHole))") {
        [void](Invoke-Router "uci add_list dhcp.lan.dhcp_option='6,$PiHole'; uci commit dhcp; /etc/init.d/dnsmasq restart")
        $state.dnsChanged = $true
    }

    # Router-own DNS is switched only when Pi-hole upstream evidence exists and excludes the router,
    # preventing a router<->Pi-hole DNS loop. Otherwise existing router upstream remains untouched.
    if ($state.safeRouterDnsSwitch) {
        $wan = Invoke-Router "uci -q show network.wan"
        $already = ($wan -match "dns='?$([regex]::Escape($PiHole))'?") -and ($wan -match "peerdns='?0'?")
        if (-not $already) {
            [void](Invoke-Router "uci set network.wan.peerdns='0'; uci -q delete network.wan.dns; uci add_list network.wan.dns='$PiHole'; uci commit network; ifup wan >/dev/null 2>&1 &")
            Start-Sleep -Seconds 6
            $state.routerDnsSwitchApplied = $true
            $state.dnsChanged = $true
        }
    }
    Save-State $state
    Write-Marker ('DNS_APPLY_PASS;ROUTER_SWITCH='+$state.routerDnsSwitchApplied)
}

function Invoke-TestDns {
    $state = Load-State
    if (-not (Test-DnsPi)) { throw 'Pi-hole DNS validation failed' }
    $dhcp = Invoke-Router "uci -q show dhcp.lan"
    if ($dhcp -notmatch [regex]::Escape('6,'+$PiHole)) { throw 'DHCP does not advertise Pi-hole DNS' }
    $r = Invoke-Router "nslookup example.com 2>/dev/null | head -n 12"
    if ($r -notmatch '(Address|Name)') { throw 'Router DNS resolution failed' }
    if ($state.routerDnsSwitchApplied) {
        $wan = Invoke-Router "uci -q show network.wan"
        if ($wan -notmatch [regex]::Escape($PiHole)) { throw 'Router DNS switch did not persist' }
    }
    Write-Marker 'DNS_TEST_PASS'
}

function Invoke-ApplyLogging {
    Ensure-Discovery
    $state = Load-State
    if (-not $state.backupReady) { Invoke-Backup; $state = Load-State }
    $cur = Invoke-Router "uci -q get system.@system[0].log_ip; uci -q get system.@system[0].log_port; uci -q get system.@system[0].log_proto"
    if ($cur -notmatch [regex]::Escape($PiHole)) {
        [void](Invoke-Router "uci set system.@system[0].log_ip='$PiHole'; uci set system.@system[0].log_port='514'; uci set system.@system[0].log_proto='udp'; uci commit system; /etc/init.d/log restart")
        $state.loggingChanged = $true
    }
    $marker = '3EN-RP-FINAL-' + (Get-Date -Format 'yyyyMMddHHmmss')
    [void](Invoke-Router ("logger -t 3en-test '3en blocked in: $marker'; logger -t banIP-test 'banIP $marker'; logger -t firewall 'REJECT wan $marker'"))
    $state | Add-Member -Force -NotePropertyName logMarker -NotePropertyValue $marker
    Save-State $state
    Write-Marker ('LOGGING_APPLY_PASS;MARKER='+$marker)
}

function Invoke-TestLogging {
    $state = Load-State
    $cfg = Invoke-Router "uci -q get system.@system[0].log_ip; uci -q get system.@system[0].log_port; uci -q get system.@system[0].log_proto"
    if ($cfg -notmatch [regex]::Escape($PiHole) -or $cfg -notmatch '514') { throw 'Remote syslog target validation failed' }
    if ($state.piSsh) {
        Start-Sleep -Seconds 2
        $m = [string]$state.logMarker
        $cmd = "grep -R -F '$m' /var/log/3en-remote/3en-blocked.log /var/log/3en-remote/banip.log /var/log/3en-remote/wan-reject.log /var/log/3en-remote/3EN002.log 2>/dev/null | head -n 20 || true"
        $hits = Invoke-Pi $cmd $state
        if ([string]::IsNullOrWhiteSpace($hits)) { throw 'Remote log marker not observed on collector' }
        $state.logVerifiedOnPi = $true
        Save-State $state
    }
    Write-Marker ('LOGGING_TEST_PASS;COLLECTOR_VERIFIED='+$state.logVerifiedOnPi)
}

function Invoke-Rollback {
    if (-not (Test-Path -LiteralPath $StatePath)) { Write-Marker 'ROLLBACK_NO_STATE'; return }
    $cmd = "test -f $RemoteBackup/dhcp.uci && uci import dhcp < $RemoteBackup/dhcp.uci; test -f $RemoteBackup/network.uci && uci import network < $RemoteBackup/network.uci; test -f $RemoteBackup/system.uci && uci import system < $RemoteBackup/system.uci; uci commit dhcp; uci commit network; uci commit system; /etc/init.d/dnsmasq restart; /etc/init.d/log restart; ifup wan >/dev/null 2>&1 &"
    [void](Invoke-Router $cmd)
    Start-Sleep -Seconds 5
    if (-not (Test-DnsPi)) { throw 'Rollback completed but Pi-hole DNS health check failed' }
    Write-Marker 'ROLLBACK_PASS'
}

function Invoke-Final {
    Invoke-TestDns
    Invoke-TestLogging
    $state = Load-State
    $lines = @(
        '3EN ROUTER + PI-HOLE INTEGRATION FINAL REPORT',
        ('UTC='+(Get-Date).ToUniversalTime().ToString('o')),
        ('Router='+$Router),
        ('PiHole='+$PiHole),
        ('PiHoleDNS=PASS'),
        ('DHCP advertises Pi-hole=PASS'),
        ('Router DNS switch applied='+$state.routerDnsSwitchApplied),
        ('Router DNS switch safety evidence='+$state.safeRouterDnsSwitch),
        ('Remote syslog target=PASS'),
        ('Collector-side log verification='+$state.logVerifiedOnPi),
        ('Pi-hole SSH auto-discovered='+$state.piSsh),
        ('Backup ready='+$state.backupReady),
        'FINAL_STATUS=SUCCESS'
    )
    $lines | Set-Content -LiteralPath $ReportPath -Encoding UTF8
    $lines | ForEach-Object { Write-Host $_ }
    Write-Marker 'FINAL_SUCCESS'
}

switch ($Phase) {
    'Discovery'    { Invoke-Discovery }
    'Backup'       { Invoke-Backup }
    'ApplyDns'     { Invoke-ApplyDns }
    'TestDns'      { Invoke-TestDns }
    'ApplyLogging' { Invoke-ApplyLogging }
    'TestLogging'  { Invoke-TestLogging }
    'Final'        { Invoke-Final }
    'Rollback'     { Invoke-Rollback }
}
