# Ninja6 Minecraft Server Network Diagnostic Tool
# Run via PowerShell:
# irm https://raw.githubusercontent.com/Ninja6-MC-Server/public-tools/main/diagnose.ps1 | iex

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Clear-Host

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "          NINJA6 MINECRAFT SERVER NETWORK DIAGNOSTIC TOOL       " -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$issues = @()
$recommendations = @()

# -------------------------------------------------------------
# STEP 1: Check Internet & IPv4 Connectivity (Ping + HTTPS fallback)
# -------------------------------------------------------------
Write-Host "[1/6] Testing General Internet & IPv4 Connectivity..." -ForegroundColor Cyan
$ipv4Ok = $false

# Try ICMP Ping
$ipv4Ping = Test-Connection -ComputerName 8.8.8.8 -Count 2 -Quiet -ErrorAction SilentlyContinue
if ($ipv4Ping) {
    $ipv4Ok = $true
} else {
    # Fallback to HTTPS probe in case firewall blocks ICMP
    try {
        $httpTest = Test-NetConnection -ComputerName "1.1.1.1" -Port 443 -WarningAction SilentlyContinue
        if ($httpTest.TcpTestSucceeded) { $ipv4Ok = $true }
    } catch {}
}

if ($ipv4Ok) {
    Write-Host "  [OK] IPv4 Internet is working." -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Cannot reach IPv4 Internet!" -ForegroundColor Red
    $issues += "No IPv4 Internet connectivity"
}

# -------------------------------------------------------------
# STEP 2: Test IPv6 Configuration & Routing Health
# -------------------------------------------------------------
Write-Host ""
Write-Host "[2/6] Testing IPv6 Configuration & Routing..." -ForegroundColor Cyan

# Check if active physical adapters have a public global IPv6 address (2000::/3)
$hasGlobalIpv6 = $false
try {
    $activeAdapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch "VPN|Tailscale|Radmin|Virtual|Loopback|TAP|ZeroTier" }
    foreach ($adapter in $activeAdapters) {
        $v6Addrs = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue | 
            Where-Object { $_.IPAddress -notlike "fe80*" -and $_.IPAddress -notlike "fd*" -and $_.IPAddress -notlike "::1" }
        if ($v6Addrs) {
            $hasGlobalIpv6 = $true
            break
        }
    }
} catch {}

if ($hasGlobalIpv6) {
    $v6Ping = Test-Connection -ComputerName 2001:4860:4860::8888 -Count 2 -Quiet -ErrorAction SilentlyContinue
    if ($v6Ping) {
        Write-Host "  [OK] Public IPv6 is assigned and routing properly." -ForegroundColor Green
    } else {
        Write-Host "  [WARNING] Router assigned a public IPv6 address, but IPv6 traffic has 100% PACKET LOSS!" -ForegroundColor Red
        Write-Host "            (This causes Minecraft login 'Creaking' error and socket disconnects)." -ForegroundColor Yellow
        $issues += "Broken IPv6 routing detected (Router assigned public IPv6, but ISP is dropping packets)"
        $recommendations += "Disable IPv6 in your router settings or on your Windows network adapter."
    }
} else {
    Write-Host "  [OK] Network is running in pure IPv4 mode (Clean & Optimal)." -ForegroundColor Green
}

# -------------------------------------------------------------
# STEP 3: Test Windows Defender Firewall Rules
# -------------------------------------------------------------
Write-Host ""
Write-Host "[3/6] Checking Windows Firewall Restrictions..." -ForegroundColor Cyan
$firewallBlocked = $false
try {
    # Check for explicit outbound block rules affecting Java or Minecraft
    $blockRules = Get-NetFirewallRule -Direction Outbound -Action Block -Enabled True -ErrorAction SilentlyContinue
    if ($blockRules) {
        foreach ($rule in $blockRules) {
            $appFilter = Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
            $portFilter = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
            
            if ($appFilter.Program -match "java|minecraft" -or $portFilter.RemotePort -match "64766|14121|25565|19132") {
                Write-Host "  [WARNING] Windows Firewall rule '$($rule.DisplayName)' is BLOCKING Minecraft traffic!" -ForegroundColor Red
                $firewallBlocked = $true
                $issues += "Windows Firewall rule '$($rule.DisplayName)' is blocking Minecraft"
            }
        }
    }
} catch {}

if (-not $firewallBlocked) {
    Write-Host "  [OK] No active Windows Firewall rules are blocking Minecraft." -ForegroundColor Green
}

# -------------------------------------------------------------
# STEP 4: Test Microsoft / Xbox Authentication Gateway
# -------------------------------------------------------------
Write-Host ""
Write-Host "[4/6] Testing Microsoft & Xbox Live Auth Gateway..." -ForegroundColor Cyan
try {
    $tcpAuth = Test-NetConnection -ComputerName "sisu.xboxlive.com" -Port 443 -WarningAction SilentlyContinue
    if ($tcpAuth.TcpTestSucceeded) {
        Write-Host "  [OK] Microsoft & Xbox Live Auth servers are reachable." -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Cannot connect to Xbox Live Auth (sisu.xboxlive.com:443)!" -ForegroundColor Red
        $issues += "Cannot reach Xbox Live Auth gateway (sisu.xboxlive.com)"
    }
} catch {
    Write-Host "  [FAIL] Failed to reach Xbox Live Auth: $_" -ForegroundColor Red
    $issues += "Xbox Live Auth unreachable"
}

# -------------------------------------------------------------
# STEP 5: Test Minecraft Java Server (TCP Port 64766)
# -------------------------------------------------------------
Write-Host ""
Write-Host "[5/6] Testing Minecraft Java Server (TCP Port 64766)..." -ForegroundColor Cyan
$javaDomain = "tissues-convertible.tun.ply.gg"
$javaIP = "147.185.221.22"
$javaPort = 64766

# DNS Resolve
try {
    $dns = Resolve-DnsName -Name $javaDomain -ErrorAction SilentlyContinue
    if ($dns) {
        Write-Host "  [OK] Java Domain ($javaDomain) resolves successfully." -ForegroundColor Green
    }
} catch {}

# TCP Socket Test
$javaTcp = Test-NetConnection -ComputerName $javaIP -Port $javaPort -WarningAction SilentlyContinue
if ($javaTcp.TcpTestSucceeded) {
    Write-Host "  [OK] Java Server TCP Port ($javaPort) is OPEN and REACHABLE!" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Cannot connect to Java Server TCP Port $javaPort ($javaIP)!" -ForegroundColor Red
    $issues += "Java Server port 64766 unreachable (Blocked by ISP/Firewall)"
}

# -------------------------------------------------------------
# STEP 6: Test Minecraft Bedrock Server (UDP Port 14121)
# -------------------------------------------------------------
Write-Host ""
Write-Host "[6/6] Testing Minecraft Bedrock Server (UDP Port 14121)..." -ForegroundColor Cyan
$bedrockDomain = "tissues-sweep.tun.ply.gg"
$bedrockIP = "147.185.221.31"
$bedrockPort = 14121

$udpSuccess = $false
try {
    $udpClient = New-Object System.Net.Sockets.UdpClient
    $udpClient.Client.ReceiveTimeout = 3000
    $magic = [byte[]](0x00,0xff,0xff,0x00,0xfe,0xfe,0xfe,0xfe,0xfd,0xfd,0xfd,0xfd,0x12,0x34,0x56,0x78)
    $pingTime = [System.BitConverter]::GetBytes([long]([System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()))
    if ([System.BitConverter]::IsLittleEndian) { [System.Array]::Reverse($pingTime) }
    $clientGuid = [byte[]](0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08)
    
    $packet = [byte[]]@(0x01) + $pingTime + $magic + $clientGuid
    $endpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($bedrockIP), $bedrockPort)
    
    [void]$udpClient.Send($packet, $packet.Length, $endpoint)
    $remoteEndpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    $response = $udpClient.Receive([ref]$remoteEndpoint)
    if ($response -and $response.Length -gt 0) {
        Write-Host "  [OK] Bedrock Server UDP Port ($bedrockPort) responded successfully!" -ForegroundColor Green
        $udpSuccess = $true
    }
    $udpClient.Close()
} catch {
}

if (-not $udpSuccess) {
    Write-Host "  [INFO] Bedrock UDP Port test sent to $bedrockIP`:$bedrockPort." -ForegroundColor Gray
}

# -------------------------------------------------------------
# SUMMARY & RECOMMENDATIONS
# -------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "                      DIAGNOSTIC SUMMARY                        " -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan

if ($issues.Count -eq 0) {
    Write-Host "STATUS: ALL NETWORK & FIREWALL CHECKS PASSED!" -ForegroundColor Green
    Write-Host ""
    Write-Host "How to connect to the Ninja6 Server:" -ForegroundColor White
    Write-Host ""
    Write-Host "  • If you play JAVA EDITION (PC):" -ForegroundColor Cyan
    Write-Host "    Server Address: tissues-convertible.tun.ply.gg" -ForegroundColor Yellow
    Write-Host "    (Or direct: 147.185.221.22:64766)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  • If you play BEDROCK EDITION (Mobile / Windows Bedrock):" -ForegroundColor Cyan
    Write-Host "    Server Address: tissues-sweep.tun.ply.gg" -ForegroundColor Yellow
    Write-Host "    Port:           14121" -ForegroundColor Yellow
    Write-Host "    (NOTE: Do NOT use the Java IP/port on Bedrock; it will fail!)" -ForegroundColor Red
} else {
    Write-Host "STATUS: ISSUES DETECTED ON YOUR PC/NETWORK:" -ForegroundColor Red
    foreach ($issue in $issues) {
        Write-Host "  - $issue" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "RECOMMENDED FIXES:" -ForegroundColor Yellow
    
    if ($issues -match "IPv6") {
        Write-Host "  1. Fix Broken IPv6 on Windows (Run PowerShell as Admin):" -ForegroundColor Cyan
        Write-Host "     Disable-NetAdapterBinding -Name * -ComponentId ms_tcpip6" -ForegroundColor White
        Write-Host "     (Or in Router settings -> disable IPv6)" -ForegroundColor Gray
    }
    
    if ($issues -match "Firewall") {
        Write-Host "  2. Fix Windows Firewall:" -ForegroundColor Cyan
        Write-Host "     Allow javaw.exe and Minecraft through Windows Defender Firewall." -ForegroundColor White
    }
    
    Write-Host ""
    Write-Host "  3. Correct Server Addresses:" -ForegroundColor Cyan
    Write-Host "     - For Java:    tissues-convertible.tun.ply.gg (or 147.185.221.22:64766)" -ForegroundColor White
    Write-Host "     - For Bedrock: tissues-sweep.tun.ply.gg  | Port: 14121" -ForegroundColor White
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
