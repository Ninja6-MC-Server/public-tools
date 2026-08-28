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
# STEP 1: Check Internet & IPv6 Health
# -------------------------------------------------------------
Write-Host "[1/5] Testing General Internet & IPv4 Connectivity..." -ForegroundColor Cyan
$ipv4Ping = Test-Connection -ComputerName 8.8.8.8 -Count 2 -Quiet -ErrorAction SilentlyContinue
if ($ipv4Ping) {
    Write-Host "  [OK] IPv4 Internet is working." -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Cannot reach IPv4 Internet (8.8.8.8)!" -ForegroundColor Red
    $issues += "No IPv4 Internet connectivity"
}

Write-Host ""
Write-Host "[2/5] Testing IPv6 Stability (Common ISP Bug Check)..." -ForegroundColor Cyan
$hasIpv6 = $false
try {
    $activeAdapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
    foreach ($adapter in $activeAdapters) {
        $v6Binding = Get-NetAdapterBinding -Name $adapter.Name -ComponentId ms_tcpip6 -ErrorAction SilentlyContinue
        if ($v6Binding -and $v6Binding.Enabled) {
            $hasIpv6 = $true
            break
        }
    }
} catch {}

if ($hasIpv6) {
    $v6Ping = Test-Connection -ComputerName 2001:4860:4860::8888 -Count 2 -Quiet -ErrorAction SilentlyContinue
    if ($v6Ping) {
        Write-Host "  [OK] IPv6 is enabled and working properly." -ForegroundColor Green
    } else {
        Write-Host "  [WARNING] IPv6 is enabled on your PC, but IPv6 traffic has 100% PACKET LOSS!" -ForegroundColor Red
        Write-Host "            (This causes Minecraft login 'Creaking' error and connection socket exceptions)." -ForegroundColor Yellow
        $issues += "Broken IPv6 routing detected (100% packet loss on IPv6)"
        $recommendations += "Disable IPv6 on your network adapter or router to use fast, stable IPv4."
    }
} else {
    Write-Host "  [OK] IPv6 is disabled; using pure IPv4 (Optimal)." -ForegroundColor Green
}

# -------------------------------------------------------------
# STEP 2: Test Microsoft / Xbox Authentication
# -------------------------------------------------------------
Write-Host ""
Write-Host "[3/5] Testing Microsoft / Xbox Live Authentication Gateway..." -ForegroundColor Cyan
try {
    $tcpAuth = Test-NetConnection -ComputerName "sisu.xboxlive.com" -Port 443 -WarningAction SilentlyContinue
    if ($tcpAuth.TcpTestSucceeded) {
        Write-Host "  [OK] Microsoft & Xbox Live Auth servers are reachable." -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Cannot connect to Xbox Live Auth (sisu.xboxlive.com)!" -ForegroundColor Red
        $issues += "Cannot connect to Xbox Live Auth gateway"
    }
} catch {
    Write-Host "  [FAIL] Failed to reach Xbox Live Auth: $_" -ForegroundColor Red
    $issues += "Xbox Live Auth unreachable"
}

# -------------------------------------------------------------
# STEP 3: Test Minecraft Java Server (TCP)
# -------------------------------------------------------------
Write-Host ""
Write-Host "[4/5] Testing Minecraft Java Server (TCP Port 64766)..." -ForegroundColor Cyan
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
    $issues += "Java Server port 64766 blocked by local firewall or ISP"
}

# -------------------------------------------------------------
# STEP 4: Test Minecraft Bedrock Server (UDP)
# -------------------------------------------------------------
Write-Host ""
Write-Host "[5/5] Testing Minecraft Bedrock Server (UDP Port 14121)..." -ForegroundColor Cyan
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
    Write-Host "STATUS: ALL NETWORK CHECKS PASSED!" -ForegroundColor Green
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
    
    if ($issues -contains "Broken IPv6 routing detected (100% packet loss on IPv6)") {
        Write-Host "  1. Fix Broken IPv6 on Windows (Run PowerShell as Admin):" -ForegroundColor Cyan
        Write-Host "     Disable-NetAdapterBinding -Name * -ComponentId ms_tcpip6" -ForegroundColor White
        Write-Host "     (Or open Network Connections -> Properties -> Uncheck IPv6)" -ForegroundColor Gray
    }
    
    Write-Host ""
    Write-Host "  2. Correct Server Addresses:" -ForegroundColor Cyan
    Write-Host "     - For Java:    tissues-convertible.tun.ply.gg (or 147.185.221.22:64766)" -ForegroundColor White
    Write-Host "     - For Bedrock: tissues-sweep.tun.ply.gg  | Port: 14121" -ForegroundColor White
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
