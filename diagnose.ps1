# Ninja6 Minecraft Server Network Diagnostic Tool
# Run via PowerShell:
# irm https://raw.githubusercontent.com/Ninja6-MC-Server/public-tools/main/diagnose.ps1 | iex
#
# This script only reads information and opens test connections.
# It does not change any setting on your PC.

Clear-Host

# Server addresses (keep in sync with README.md)
$javaDomain      = "tissues-convertible.tun.ply.gg"
$javaSrvName     = "_minecraft._tcp.$javaDomain"
$javaDefaultPort = 25565   # used by the game when the SRV lookup fails
$bedrockAddress  = "la64zuc5.free.tryportwarp.cc"
$bedrockPort     = 11899
$bedrockVersions = "1.26.50 to 1.26.60"

# Probe targets
$ipv4Target = "8.8.8.8"
$ipv4Https  = "1.1.1.1"
$ipv6Target = "2001:4860:4860::8888"
$xboxAuth   = "sisu.xboxlive.com"

$issues = New-Object System.Collections.Generic.List[string]
$notes  = New-Object System.Collections.Generic.List[string]

function Test-TcpPort {
    # Opens a TCP connection and closes it again. Returns $true if it connected.
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 5000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($async)
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function ConvertTo-VarInt {
    param([int]$Value)
    $bytes = New-Object System.Collections.Generic.List[byte]
    $v = [BitConverter]::ToUInt32([BitConverter]::GetBytes($Value), 0)
    do {
        $b = [byte]($v -band 0x7F)
        $v = $v -shr 7
        if ($v -ne 0) { $b = $b -bor 0x80 }
        $bytes.Add([byte]$b)
    } while ($v -ne 0)
    return ,$bytes.ToArray()
}

function Read-VarInt {
    param([System.IO.Stream]$Stream)
    $result = 0
    for ($i = 0; $i -lt 5; $i++) {
        $b = $Stream.ReadByte()
        if ($b -lt 0) { throw "connection closed by the server" }
        $result = $result -bor (($b -band 0x7F) -shl (7 * $i))
        if (($b -band 0x80) -eq 0) { return $result }
    }
    throw "invalid response"
}

function Test-JavaStatus {
    # Sends a Minecraft server list ping, using the domain name as the handshake host
    # (the same thing the game does), and returns the server's answer.
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 6000)
    $result = @{ Connected = $false; Ok = $false; Version = ""; Error = "" }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw "connection timed out" }
        $client.EndConnect($async)
        $result.Connected = $true

        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $stream.WriteTimeout = $TimeoutMs

        $hostBytes = [System.Text.Encoding]::UTF8.GetBytes($TargetHost)
        $body = New-Object System.Collections.Generic.List[byte]
        $body.AddRange([byte[]](ConvertTo-VarInt 0))                 # packet id: handshake
        $body.AddRange([byte[]](ConvertTo-VarInt 767))               # protocol version (any real one works for a ping)
        $body.AddRange([byte[]](ConvertTo-VarInt $hostBytes.Length))
        $body.AddRange([byte[]]$hostBytes)                           # server address
        $body.Add([byte](($Port -shr 8) -band 0xFF))                 # port, big endian
        $body.Add([byte]($Port -band 0xFF))
        $body.AddRange([byte[]](ConvertTo-VarInt 1))                 # next state: status

        $packet = New-Object System.Collections.Generic.List[byte]
        $packet.AddRange([byte[]](ConvertTo-VarInt $body.Count))
        $packet.AddRange($body)
        $packet.AddRange([byte[]](0x01, 0x00))                       # status request
        $out = $packet.ToArray()
        $stream.Write($out, 0, $out.Length)
        $stream.Flush()

        [void](Read-VarInt $stream)                                  # packet length
        $packetId = Read-VarInt $stream
        if ($packetId -ne 0) { throw "unexpected reply from the server" }
        $jsonLength = Read-VarInt $stream
        if ($jsonLength -le 0 -or $jsonLength -gt 1048576) { throw "unexpected reply from the server" }
        $buffer = New-Object byte[] $jsonLength
        $read = 0
        while ($read -lt $jsonLength) {
            $n = $stream.Read($buffer, $read, $jsonLength - $read)
            if ($n -le 0) { throw "connection closed by the server" }
            $read += $n
        }
        $json = [System.Text.Encoding]::UTF8.GetString($buffer)
        if ($json -match '"version"\s*:\s*\{[^}]*"name"\s*:\s*"([^"]*)"') {
            $result.Version = $Matches[1]
        }
        $result.Ok = $true
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        $result.Error = $msg
    } finally {
        $client.Close()
    }
    return $result
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "          NINJA6 MINECRAFT SERVER NETWORK DIAGNOSTIC TOOL       " -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Read-only: this tool does not change anything on your PC." -ForegroundColor Gray
Write-Host ""

# -------------------------------------------------------------
# STEP 1: Internet & IPv4 connectivity (ping, then HTTPS fallback)
# -------------------------------------------------------------
Write-Host "[1/6] Testing general Internet & IPv4 connectivity..." -ForegroundColor Cyan
$ipv4Ok = [bool](Test-Connection -ComputerName $ipv4Target -Count 2 -Quiet -ErrorAction SilentlyContinue)
if (-not $ipv4Ok) {
    # Some networks block ping, so also try an HTTPS connection
    $ipv4Ok = Test-TcpPort -TargetHost $ipv4Https -Port 443
}

if ($ipv4Ok) {
    Write-Host "  [OK] IPv4 Internet is working." -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Cannot reach the IPv4 Internet!" -ForegroundColor Red
    $issues.Add("No IPv4 Internet connectivity")
}

# -------------------------------------------------------------
# STEP 2: IPv6 (information only)
# -------------------------------------------------------------
Write-Host ""
Write-Host "[2/6] Checking IPv6 (information only)..." -ForegroundColor Cyan

# Does an active physical adapter have a public IPv6 address (2000::/3)?
$hasGlobalIpv6 = $false
try {
    $activeAdapters = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch "VPN|Tailscale|Radmin|Virtual|Loopback|TAP|ZeroTier" }
    foreach ($adapter in $activeAdapters) {
        $v6Addrs = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -match '^[23]' }
        if ($v6Addrs) {
            $hasGlobalIpv6 = $true
            break
        }
    }
} catch {
    Write-Host "  [INFO] Could not read network adapter details." -ForegroundColor Gray
}

if ($hasGlobalIpv6) {
    $v6Ping = Test-Connection -ComputerName $ipv6Target -Count 2 -Quiet -ErrorAction SilentlyContinue
    if ($v6Ping) {
        Write-Host "  [OK] Public IPv6 works. Bedrock can use the direct IPv6 route (the best route)." -ForegroundColor Green
    } else {
        Write-Host "  [INFO] A public IPv6 address is assigned, but an IPv6 ping did not get a reply." -ForegroundColor Gray
        Write-Host "         Some networks block ping. Bedrock falls back to the relay route on its own." -ForegroundColor Gray
        $notes.Add("IPv6 ping failed. Keep IPv6 turned on; Bedrock uses the relay route if direct IPv6 does not work.")
    }
} else {
    Write-Host "  [INFO] No public IPv6 address. Bedrock will use the relay route; that is fine." -ForegroundColor Gray
}

# -------------------------------------------------------------
# STEP 3: Windows Defender Firewall rules (read only)
# -------------------------------------------------------------
Write-Host ""
Write-Host "[3/6] Checking Windows Firewall rules..." -ForegroundColor Cyan
$firewallBlocked = $false
$firewallChecked = $false
try {
    # Look for enabled outbound block rules that affect Java or Minecraft
    $blockRules = Get-NetFirewallRule -Direction Outbound -Action Block -Enabled True -ErrorAction Stop
    $firewallChecked = $true
    foreach ($rule in $blockRules) {
        $appFilter = Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
        $portFilter = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
        if ($appFilter.Program -match "java|minecraft" -or $portFilter.RemotePort -match "^(25565|64766|11899|19132)$") {
            Write-Host "  [WARNING] Windows Firewall rule '$($rule.DisplayName)' is BLOCKING Minecraft traffic!" -ForegroundColor Red
            $firewallBlocked = $true
            $issues.Add("Windows Firewall rule '$($rule.DisplayName)' is blocking Minecraft")
        }
    }
} catch {
    Write-Host "  [INFO] Could not read the firewall rules on this PC." -ForegroundColor Gray
}

if ($firewallChecked -and -not $firewallBlocked) {
    Write-Host "  [OK] No active Windows Firewall rules are blocking Minecraft." -ForegroundColor Green
}

# -------------------------------------------------------------
# STEP 4: Microsoft / Xbox authentication
# -------------------------------------------------------------
Write-Host ""
Write-Host "[4/6] Testing Microsoft & Xbox Live sign-in servers..." -ForegroundColor Cyan
if (Test-TcpPort -TargetHost $xboxAuth -Port 443) {
    Write-Host "  [OK] Microsoft & Xbox Live sign-in servers are reachable." -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Cannot connect to Xbox Live sign-in ($xboxAuth`:443)!" -ForegroundColor Red
    $issues.Add("Cannot reach the Xbox Live sign-in server ($xboxAuth)")
}

# -------------------------------------------------------------
# STEP 5: Minecraft Java server (server list ping by domain name)
# -------------------------------------------------------------
Write-Host ""
Write-Host "[5/6] Testing Minecraft Java server ($javaDomain)..." -ForegroundColor Cyan

# The game looks up an SRV record to find the port (and uses 25565 without one), so do the same
$javaPort = $javaDefaultPort
$srvFound = $false
try {
    $srv = Resolve-DnsName -Name $javaSrvName -Type SRV -ErrorAction Stop | Where-Object { $_.Type -eq 'SRV' } | Select-Object -First 1
    if ($srv) {
        $javaPort = [int]$srv.Port
        $srvFound = $true
    }
} catch {
    $srvFound = $false
}

if ($srvFound) {
    Write-Host "  [OK] Server name found (port $javaPort)." -ForegroundColor Green
} else {
    Write-Host "  [INFO] Could not look up the server's port record; testing port $javaPort." -ForegroundColor Gray
}

$java = Test-JavaStatus -TargetHost $javaDomain -Port $javaPort
if ($java.Ok) {
    $versionText = ""
    if ($java.Version) { $versionText = " (server version: $($java.Version))" }
    Write-Host "  [OK] Java server answered the server list ping$versionText." -ForegroundColor Green
} elseif ($java.Connected) {
    Write-Host "  [FAIL] Connected to the tunnel, but the Java server did not answer: $($java.Error)" -ForegroundColor Red
    Write-Host "         The server may be offline or restarting. Try again in a few minutes." -ForegroundColor Yellow
    $issues.Add("Java server did not answer through $javaDomain (server may be offline)")
} else {
    Write-Host "  [FAIL] Cannot connect to $javaDomain port $javaPort`: $($java.Error)" -ForegroundColor Red
    $issues.Add("Cannot connect to the Java server address $javaDomain (blocked by network or firewall?)")
}

# -------------------------------------------------------------
# STEP 6: Minecraft Bedrock server (TCP reachability of the join address)
# -------------------------------------------------------------
Write-Host ""
Write-Host "[6/6] Testing Minecraft Bedrock join address ($bedrockAddress port $bedrockPort)..." -ForegroundColor Cyan
if (Test-TcpPort -TargetHost $bedrockAddress -Port $bedrockPort) {
    Write-Host "  [OK] Bedrock join address is reachable (TCP)." -ForegroundColor Green
    Write-Host "       Game traffic (UDP) is set up separately when you join, so this check" -ForegroundColor Gray
    Write-Host "       cannot prove the whole join path. It shows the address is up." -ForegroundColor Gray
} else {
    Write-Host "  [FAIL] Cannot connect to $bedrockAddress port $bedrockPort (TCP)!" -ForegroundColor Red
    $issues.Add("Cannot reach the Bedrock join address $bedrockAddress port $bedrockPort")
}

# -------------------------------------------------------------
# SUMMARY & RECOMMENDATIONS
# -------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "                      DIAGNOSTIC SUMMARY                        " -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan

if ($issues.Count -eq 0) {
    Write-Host "STATUS: ALL CHECKS PASSED!" -ForegroundColor Green
} else {
    Write-Host "STATUS: ISSUES DETECTED:" -ForegroundColor Red
    foreach ($issue in $issues) {
        Write-Host "  - $issue" -ForegroundColor Red
    }
    if ($firewallBlocked) {
        Write-Host ""
        Write-Host "  Firewall fix: allow javaw.exe and Minecraft through Windows Defender Firewall." -ForegroundColor Yellow
    }
}

if ($notes.Count -gt 0) {
    Write-Host ""
    Write-Host "NOTES:" -ForegroundColor Gray
    foreach ($note in $notes) {
        Write-Host "  - $note" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "How to connect to the Ninja6 Server:" -ForegroundColor White
Write-Host ""
Write-Host "  * JAVA EDITION (PC):" -ForegroundColor Cyan
Write-Host "    Server Address: $javaDomain" -ForegroundColor Yellow
Write-Host "    Type the name exactly like this, with no port. Do NOT use a numeric IP" -ForegroundColor Gray
Write-Host "    address: the tunnel only accepts players who connect by this name." -ForegroundColor Gray
Write-Host ""
Write-Host "  * BEDROCK EDITION (Mobile / Windows / Consoles), versions $($bedrockVersions):" -ForegroundColor Cyan
Write-Host "    Server Address: $bedrockAddress" -ForegroundColor Yellow
Write-Host "    Port:           $bedrockPort" -ForegroundColor Yellow
Write-Host "    (Do NOT use the Java address on Bedrock; it will fail.)" -ForegroundColor Gray

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
