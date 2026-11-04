# Ninja6 Minecraft Server Network Diagnostic Tool
# Run via PowerShell:
# irm https://raw.githubusercontent.com/Ninja6-MC-Server/public-tools/main/diagnose.ps1 | iex
#
# This script only reads information and opens test connections.
# It does not change any setting on your PC. The only thing it writes is
# the one-line result, which it copies to your clipboard.

Clear-Host

$toolVersion = "2026-11-05"

# Server addresses (keep in sync with README.md and diagnose.sh)
$javaDomain      = "tissues-convertible.tun.ply.gg"
$javaSrvName     = "_minecraft._tcp.$javaDomain"
$javaDefaultPort = 25565   # used by the game when the SRV lookup fails
$bedrockAddress  = "la64zuc5.free.tryportwarp.cc"
$bedrockPort     = 11899
$bedrockVersions = "1.26.50 to 1.26.60"

# Old addresses players may still have saved
$oldJavaIpPattern   = '^(147\.185\.221\.\d+|2602:fbaf:[0-9a-f:]*)$'
$oldBedrockHosts    = @("tissues-sweep.tun.ply.gg", "147.185.221.31")

# Probe targets
$ipv4Target = "8.8.8.8"
$ipv4Https  = "1.1.1.1"
$ipv6Target = "2001:4860:4860::8888"
$xboxAuth   = "sisu.xboxlive.com"
$publicDns  = @("1.1.1.1", "8.8.8.8")

$issues = New-Object System.Collections.Generic.List[string]
$fixes  = New-Object System.Collections.Generic.List[string]
$notes  = New-Object System.Collections.Generic.List[string]

# Short codes for the one-line result
$result = [ordered]@{ NET = "?"; IPV6 = "?"; FW = "?"; MS = "?"; DNS = "?"; JAVA = "?"; BEDROCK = "?"; SAVED = "?" }

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
    $value = 0
    for ($i = 0; $i -lt 5; $i++) {
        $b = $Stream.ReadByte()
        if ($b -lt 0) { throw "connection closed by the server" }
        $value = $value -bor (($b -band 0x7F) -shl (7 * $i))
        if (($b -band 0x80) -eq 0) { return $value }
    }
    throw "invalid response"
}

function Test-JavaStatus {
    # Sends a Minecraft server list ping with $TargetHost as the handshake host
    # (the same thing the game does) and returns the server's answer.
    # $ConnectTo lets the test connect to an IP address found by public DNS while
    # still sending the domain name in the handshake.
    param([string]$TargetHost, [int]$Port, [string]$ConnectTo = "", [int]$TimeoutMs = 6000)
    $status = @{ Connected = $false; Ok = $false; Version = ""; Error = "" }
    if (-not $ConnectTo) { $ConnectTo = $TargetHost }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ConnectTo, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw "connection timed out" }
        $client.EndConnect($async)
        $status.Connected = $true

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
            $status.Version = $Matches[1]
        }
        $status.Ok = $true
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        $status.Error = $msg
    } finally {
        $client.Close()
    }
    return $status
}

function Resolve-SystemDnsName {
    # Looks up a name the same way games do (hosts file, then your DNS server).
    # Returns the IPv4 addresses, or an empty list.
    param([string]$Name)
    try {
        return @([System.Net.Dns]::GetHostAddresses($Name) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString })
    } catch {
        return @()
    }
}

function Resolve-PublicDnsName {
    # Looks up a name with public DNS servers, skipping your own DNS server.
    param([string]$Name)
    foreach ($server in $publicDns) {
        try {
            $answers = @(Resolve-DnsName -Name $Name -Type A -Server $server -DnsOnly -QuickTimeout -ErrorAction Stop |
                Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress })
            if ($answers.Count -gt 0) { return $answers }
        } catch {
            Write-Verbose "No answer from $server"
        }
    }
    # Fall back to DNS over HTTPS, for networks that intercept plain DNS
    try {
        $doh = Invoke-RestMethod -Uri "https://cloudflare-dns.com/dns-query?name=$Name&type=A" -Headers @{ accept = "application/dns-json" } -TimeoutSec 8 -UseBasicParsing
        return @($doh.Answer | Where-Object { $_.type -eq 1 } | ForEach-Object { $_.data })
    } catch {
        return @()
    }
}

function Read-NbtServerList {
    # Reads the name and address of each saved server from a Java Edition
    # servers.dat file (uncompressed NBT). Read-only.
    param([string]$Path)
    $script:nbt = [System.IO.File]::ReadAllBytes($Path)
    $script:nbtPos = 0
    $script:nbtFound = New-Object System.Collections.Generic.List[object]

    function Get-NbtSlice([int]$Count) {
        if ($script:nbtPos + $Count -gt $script:nbt.Length) { throw "file ends early" }
        $slice = New-Object byte[] $Count
        [Array]::Copy($script:nbt, $script:nbtPos, $slice, 0, $Count)
        $script:nbtPos += $Count
        if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($slice) }
        return ,$slice
    }
    function Get-NbtInt32 { return [BitConverter]::ToInt32((Get-NbtSlice 4), 0) }
    function Get-NbtString {
        $len = [BitConverter]::ToUInt16((Get-NbtSlice 2), 0)
        if ($script:nbtPos + $len -gt $script:nbt.Length) { throw "file ends early" }
        $text = [System.Text.Encoding]::UTF8.GetString($script:nbt, $script:nbtPos, $len)
        $script:nbtPos += $len
        return $text
    }
    function Read-NbtPayload([int]$Type) {
        switch ($Type) {
            1  { $script:nbtPos += 1 }
            2  { $script:nbtPos += 2 }
            3  { $script:nbtPos += 4 }
            4  { $script:nbtPos += 8 }
            5  { $script:nbtPos += 4 }
            6  { $script:nbtPos += 8 }
            7  { $n = Get-NbtInt32; $script:nbtPos += $n }
            8  { return (Get-NbtString) }
            9  {
                $itemType = $script:nbt[$script:nbtPos]; $script:nbtPos += 1
                $n = Get-NbtInt32
                for ($i = 0; $i -lt $n; $i++) { [void](Read-NbtPayload $itemType) }
            }
            10 {
                $entry = @{}
                while ($true) {
                    if ($script:nbtPos -ge $script:nbt.Length) { throw "file ends early" }
                    $tagType = $script:nbt[$script:nbtPos]; $script:nbtPos += 1
                    if ($tagType -eq 0) { break }
                    $tagName = Get-NbtString
                    $value = Read-NbtPayload $tagType
                    if ($tagType -eq 8 -and ($tagName -eq 'name' -or $tagName -eq 'ip')) { $entry[$tagName] = $value }
                }
                if ($entry.ContainsKey('ip')) { $script:nbtFound.Add([pscustomobject]@{ Name = $entry['name']; Address = $entry['ip'] }) }
            }
            11 { $n = Get-NbtInt32; $script:nbtPos += 4 * $n }
            12 { $n = Get-NbtInt32; $script:nbtPos += 8 * $n }
            default { throw "unknown tag $Type" }
        }
        return $null
    }

    $rootType = $script:nbt[0]; $script:nbtPos = 1
    if ($rootType -ne 10) { throw "not a server list" }
    [void](Get-NbtString)
    [void](Read-NbtPayload 10)
    return $script:nbtFound.ToArray()
}

function Split-ServerAddress {
    # Splits "host", "host:port", "[v6]:port" or a bare IPv6 address.
    param([string]$Address)
    $a = $Address.Trim()
    if ($a -match '^\[([^\]]+)\](?::(\d+))?$') { return @($Matches[1], $Matches[2]) }
    if ($a -match '^([^:]+):(\d+)$') { return @($Matches[1], $Matches[2]) }
    return @($a, $null)
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "          NINJA6 MINECRAFT SERVER NETWORK DIAGNOSTIC TOOL       " -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Read-only: this tool does not change anything on your PC." -ForegroundColor Gray
Write-Host ""

# -------------------------------------------------------------
# STEP 1: Internet & IPv4 connectivity (ping, then HTTPS fallback)
# -------------------------------------------------------------
Write-Host "[1/8] Testing general Internet & IPv4 connectivity..." -ForegroundColor Cyan
$ipv4Ok = [bool](Test-Connection -ComputerName $ipv4Target -Count 2 -Quiet -ErrorAction SilentlyContinue)
if (-not $ipv4Ok) {
    # Some networks block ping, so also try an HTTPS connection
    $ipv4Ok = Test-TcpPort -TargetHost $ipv4Https -Port 443
}

if ($ipv4Ok) {
    Write-Host "  [OK] IPv4 Internet is working." -ForegroundColor Green
    $result.NET = "OK"
} else {
    Write-Host "  [FAIL] Cannot reach the IPv4 Internet!" -ForegroundColor Red
    $issues.Add("No IPv4 Internet connectivity")
    $result.NET = "FAIL"
}

# -------------------------------------------------------------
# STEP 2: IPv6 (information only)
# -------------------------------------------------------------
Write-Host ""
Write-Host "[2/8] Checking IPv6 (information only)..." -ForegroundColor Cyan

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
        $result.IPV6 = "OK"
    } else {
        Write-Host "  [INFO] A public IPv6 address is assigned, but an IPv6 ping did not get a reply." -ForegroundColor Gray
        Write-Host "         Some networks block ping. Bedrock falls back to the relay route on its own." -ForegroundColor Gray
        $notes.Add("IPv6 ping failed. Keep IPv6 turned on; Bedrock uses the relay route if direct IPv6 does not work.")
        $result.IPV6 = "NOPING"
    }
} else {
    Write-Host "  [INFO] No public IPv6 address. Bedrock will use the relay route; that is fine." -ForegroundColor Gray
    $result.IPV6 = "NONE"
}

# -------------------------------------------------------------
# STEP 3: Windows Defender Firewall rules (read only)
# -------------------------------------------------------------
Write-Host ""
Write-Host "[3/8] Checking Windows Firewall rules..." -ForegroundColor Cyan
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

if ($firewallBlocked) {
    $fixes.Add("Allow javaw.exe and Minecraft through Windows Defender Firewall.")
    $result.FW = "BLOCK"
} elseif ($firewallChecked) {
    Write-Host "  [OK] No active Windows Firewall rules are blocking Minecraft." -ForegroundColor Green
    $result.FW = "OK"
}

# -------------------------------------------------------------
# STEP 4: Microsoft / Xbox authentication
# -------------------------------------------------------------
Write-Host ""
Write-Host "[4/8] Testing Microsoft & Xbox Live sign-in servers..." -ForegroundColor Cyan
if (Test-TcpPort -TargetHost $xboxAuth -Port 443) {
    Write-Host "  [OK] Microsoft & Xbox Live sign-in servers are reachable." -ForegroundColor Green
    $result.MS = "OK"
} else {
    Write-Host "  [FAIL] Cannot connect to Xbox Live sign-in ($xboxAuth`:443)!" -ForegroundColor Red
    $issues.Add("Cannot reach the Xbox Live sign-in server ($xboxAuth)")
    $result.MS = "FAIL"
}

# -------------------------------------------------------------
# STEP 5: DNS (can this PC find the server names?)
# -------------------------------------------------------------
Write-Host ""
Write-Host "[5/8] Checking that your PC can find the server names (DNS)..." -ForegroundColor Cyan
$dnsBlocked = $false
$javaPublicIps = @()
$dnsCodes = @()
foreach ($name in @($javaDomain, $bedrockAddress)) {
    $systemIps = @(Resolve-SystemDnsName $name)
    $publicIps = @(Resolve-PublicDnsName $name)
    if ($name -eq $javaDomain) { $javaPublicIps = $publicIps }

    if ($systemIps.Count -gt 0) {
        $matching = @($systemIps | Where-Object { $publicIps -contains $_ })
        if ($publicIps.Count -gt 0 -and $matching.Count -eq 0) {
            Write-Host "  [WARNING] $name points to $($systemIps -join ', ') on this PC," -ForegroundColor Yellow
            Write-Host "            but public DNS says $($publicIps -join ', ')." -ForegroundColor Yellow
            Write-Host "            Check the hosts file, a VPN or a DNS filter." -ForegroundColor Yellow
            $issues.Add("$name points to a different address on this PC than on public DNS")
            $dnsCodes += "DIFF"
        } else {
            Write-Host "  [OK] $name found ($($systemIps -join ', '))." -ForegroundColor Green
            $dnsCodes += "OK"
        }
    } elseif ($publicIps.Count -gt 0) {
        Write-Host "  [FAIL] Your DNS server cannot find $name," -ForegroundColor Red
        Write-Host "         but public DNS can ($($publicIps -join ', ')). Your network's DNS is blocking or" -ForegroundColor Red
        Write-Host "         filtering it (internet provider, router, school/work filter, ad blocker or antivirus)." -ForegroundColor Red
        $issues.Add("Your DNS server cannot find $name (public DNS can)")
        $dnsBlocked = $true
        $dnsCodes += "BLOCKED"
    } else {
        Write-Host "  [FAIL] Neither your DNS server nor public DNS could find $name." -ForegroundColor Red
        Write-Host "         Your network may block DNS lookups, or the address may be down." -ForegroundColor Red
        $issues.Add("Cannot look up $name at all")
        $dnsCodes += "FAIL"
    }
}
if ($dnsCodes -contains "BLOCKED") { $result.DNS = "BLOCKED" }
elseif ($dnsCodes -contains "DIFF") { $result.DNS = "DIFF" }
elseif ($dnsCodes -contains "FAIL") { $result.DNS = "FAIL" }
else { $result.DNS = "OK" }

if ($dnsBlocked) {
    $fixes.Add("Change your DNS server to 1.1.1.1 and 1.0.0.1 (Cloudflare) or 8.8.8.8 and 8.8.4.4 (Google):")
    $fixes.Add("  Windows Settings > Network & internet > Wi-Fi or Ethernet > Hardware properties >")
    $fixes.Add("  DNS server assignment > Edit > Manual > IPv4 on. Or change it on your router.")
    $fixes.Add("Then run this in PowerShell to forget the old answer: ipconfig /flushdns")
    $fixes.Add("If you use an ad blocker, parental filter or antivirus web shield, allow ply.gg in it.")
}

# -------------------------------------------------------------
# STEP 6: Minecraft Java server (server list ping by domain name)
# -------------------------------------------------------------
Write-Host ""
Write-Host "[6/8] Testing Minecraft Java server ($javaDomain)..." -ForegroundColor Cyan

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
    Write-Host "  [OK] Server port record found (port $javaPort)." -ForegroundColor Green
} else {
    Write-Host "  [INFO] Could not look up the server's port record; testing port $javaPort." -ForegroundColor Gray
}

$java = Test-JavaStatus -TargetHost $javaDomain -Port $javaPort
if ($java.Ok) {
    $versionText = ""
    if ($java.Version) { $versionText = " (server version: $($java.Version))" }
    Write-Host "  [OK] Java server answered the server list ping$versionText." -ForegroundColor Green
    $result.JAVA = "OK"
} elseif ($dnsBlocked -and $javaPublicIps.Count -gt 0) {
    # Your DNS cannot find the name. Test the server anyway through the address public DNS gave.
    $viaPublic = Test-JavaStatus -TargetHost $javaDomain -Port $javaPort -ConnectTo $javaPublicIps[0]
    if ($viaPublic.Ok) {
        Write-Host "  [FAIL] The game cannot find $javaDomain through your DNS server." -ForegroundColor Red
        Write-Host "         The server itself is online and reachable from your network:" -ForegroundColor Yellow
        Write-Host "         fixing your DNS (see below) should let you join." -ForegroundColor Yellow
        $result.JAVA = "DNSONLY"
    } else {
        Write-Host "  [FAIL] Your DNS cannot find the server, and a test through public DNS also failed: $($viaPublic.Error)" -ForegroundColor Red
        $result.JAVA = "FAIL"
    }
    $issues.Add("Java server not reachable by name from this PC")
} elseif ($java.Connected) {
    Write-Host "  [FAIL] Connected to the tunnel, but the Java server did not answer: $($java.Error)" -ForegroundColor Red
    Write-Host "         The server may be offline or restarting. Try again in a few minutes." -ForegroundColor Yellow
    $issues.Add("Java server did not answer through $javaDomain (server may be offline)")
    $result.JAVA = "NOANSWER"
} else {
    Write-Host "  [FAIL] Cannot connect to $javaDomain port $javaPort`: $($java.Error)" -ForegroundColor Red
    $issues.Add("Cannot connect to the Java server address $javaDomain (blocked by network or firewall?)")
    $result.JAVA = "FAIL"
}

# -------------------------------------------------------------
# STEP 7: Minecraft Bedrock server (TCP reachability of the join address)
# -------------------------------------------------------------
Write-Host ""
Write-Host "[7/8] Testing Minecraft Bedrock join address ($bedrockAddress port $bedrockPort)..." -ForegroundColor Cyan
if (Test-TcpPort -TargetHost $bedrockAddress -Port $bedrockPort) {
    Write-Host "  [OK] Bedrock join address is reachable (TCP)." -ForegroundColor Green
    Write-Host "       Game traffic (UDP) is set up separately when you join, so this check" -ForegroundColor Gray
    Write-Host "       cannot prove the whole join path. It shows the address is up." -ForegroundColor Gray
    $result.BEDROCK = "OK"
} else {
    Write-Host "  [FAIL] Cannot connect to $bedrockAddress port $bedrockPort (TCP)!" -ForegroundColor Red
    $issues.Add("Cannot reach the Bedrock join address $bedrockAddress port $bedrockPort")
    $result.BEDROCK = "FAIL"
}

# -------------------------------------------------------------
# STEP 8: Saved server lists (read only)
# -------------------------------------------------------------
Write-Host ""
Write-Host "[8/8] Checking your saved Ninja6 servers for old addresses..." -ForegroundColor Cyan

$javaListPatterns = @(
    "$env:APPDATA\.minecraft\servers.dat",
    "$env:APPDATA\PrismLauncher\instances\*\.minecraft\servers.dat",
    "$env:APPDATA\PrismLauncher\instances\*\minecraft\servers.dat",
    "$env:APPDATA\ModrinthApp\profiles\*\servers.dat",
    "$env:APPDATA\ATLauncher\instances\*\servers.dat",
    "$env:APPDATA\gdlauncher_carbon\data\instances\*\instance\servers.dat",
    "$env:USERPROFILE\curseforge\minecraft\Instances\*\servers.dat"
)
$bedrockListPatterns = @(
    "$env:APPDATA\Minecraft Bedrock\Users\*\games\com.mojang\minecraftpe\external_servers.txt",
    "$env:LOCALAPPDATA\Packages\Microsoft.MinecraftUWP_8wekyb3d8bbwe\LocalState\games\com.mojang\minecraftpe\external_servers.txt"
)

$listsRead = 0
$savedBad = 0
$savedGood = 0

foreach ($pattern in $javaListPatterns) {
    foreach ($file in @(Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue)) {
        try {
            $entries = @(Read-NbtServerList $file.FullName)
        } catch {
            Write-Host "  [INFO] Could not read $($file.FullName)." -ForegroundColor Gray
            continue
        }
        $listsRead++
        foreach ($entry in $entries) {
            $parts = Split-ServerAddress $entry.Address
            $entryHost = $parts[0].TrimEnd('.').ToLower()
            $label = "Java server '$($entry.Name)' ($($entry.Address))"
            if ($entryHost -eq $javaDomain) {
                Write-Host "  [OK] $label uses the right address." -ForegroundColor Green
                $savedGood++
            } elseif ($entryHost -match $oldJavaIpPattern) {
                Write-Host "  [FIX] $label uses the tunnel's numeric IP, which no longer works." -ForegroundColor Red
                Write-Host "        Edit it and change the address to: $javaDomain" -ForegroundColor Yellow
                Write-Host "        (in $($file.FullName))" -ForegroundColor Gray
                $savedBad++
            } elseif ($entryHost -like "*.tun.ply.gg" -or $entryHost -eq $bedrockAddress) {
                Write-Host "  [FIX] $label is an old or Bedrock-only address." -ForegroundColor Red
                Write-Host "        Edit it and change the address to: $javaDomain" -ForegroundColor Yellow
                Write-Host "        (in $($file.FullName))" -ForegroundColor Gray
                $savedBad++
            }
        }
    }
}

foreach ($pattern in $bedrockListPatterns) {
    foreach ($file in @(Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue)) {
        try {
            $lines = @(Get-Content -LiteralPath $file.FullName -ErrorAction Stop)
        } catch {
            Write-Host "  [INFO] Could not read $($file.FullName)." -ForegroundColor Gray
            continue
        }
        $listsRead++
        foreach ($line in $lines) {
            # Format: index:name:address:port:timestamp
            $fields = $line.Split(':')
            if ($fields.Count -lt 4) { continue }
            $entryName = $fields[1]
            $entryHost = $fields[2].Trim().TrimEnd('.').ToLower()
            $entryPort = $fields[3].Trim()
            $label = "Bedrock server '$entryName' ($entryHost port $entryPort)"
            if ($entryHost -eq $bedrockAddress -and $entryPort -eq "$bedrockPort") {
                Write-Host "  [OK] $label uses the right address." -ForegroundColor Green
                $savedGood++
            } elseif ($entryHost -eq $bedrockAddress -or $oldBedrockHosts -contains $entryHost -or
                      $entryHost -eq $javaDomain -or $entryHost -match $oldJavaIpPattern) {
                Write-Host "  [FIX] $label is an old or wrong address." -ForegroundColor Red
                Write-Host "        Edit it: address $bedrockAddress, port $bedrockPort" -ForegroundColor Yellow
                $savedBad++
            }
        }
    }
}

if ($listsRead -eq 0) {
    Write-Host "  [INFO] No saved server lists found (other launchers are not checked)." -ForegroundColor Gray
    $result.SAVED = "NONE"
} elseif ($savedBad -gt 0) {
    $issues.Add("$savedBad saved server entry(s) use an old address (see step 8)")
    $fixes.Add("Edit the saved server entries marked [FIX] in step 8, or delete them and add the server again.")
    $result.SAVED = "OLD$savedBad"
} elseif ($savedGood -gt 0) {
    $result.SAVED = "OK"
} else {
    Write-Host "  [INFO] Read $listsRead server list(s); no Ninja6 server is saved in them yet." -ForegroundColor Gray
    $result.SAVED = "NOTSAVED"
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
}

if ($fixes.Count -gt 0) {
    Write-Host ""
    Write-Host "WHAT TO DO:" -ForegroundColor Yellow
    foreach ($fix in $fixes) {
        Write-Host "  $fix" -ForegroundColor Yellow
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

# One line that players can paste into Discord when asking for help
$codes = ($result.GetEnumerator() | ForEach-Object { "$($_.Key):$($_.Value)" }) -join " "
$osText = "Windows " + [Environment]::OSVersion.Version.ToString() + " PS" + $PSVersionTable.PSVersion.Major + "." + $PSVersionTable.PSVersion.Minor
$resultLine = "N6DIAG $toolVersion | $codes | $osText"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "RESULT LINE (paste this in Discord when asking for help):" -ForegroundColor White
Write-Host "  $resultLine" -ForegroundColor Yellow
try {
    Set-Clipboard -Value $resultLine -ErrorAction Stop
    Write-Host "  (Copied to your clipboard. Press Ctrl+V in Discord to paste it.)" -ForegroundColor Gray
} catch {
    Write-Host "  (Select the line above and press Enter, or right-click, to copy it.)" -ForegroundColor Gray
}
Write-Host "================================================================" -ForegroundColor Cyan
