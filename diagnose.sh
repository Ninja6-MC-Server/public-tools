#!/usr/bin/env bash
# Ninja6 Minecraft Server Network Diagnostic Tool (Linux/Mac/Android Termux)
# Run via: curl -sSL https://raw.githubusercontent.com/Ninja6-MC-Server/public-tools/main/diagnose.sh | bash

echo "================================================================"
echo "          NINJA6 MINECRAFT SERVER NETWORK DIAGNOSTIC TOOL       "
echo "================================================================"
echo ""

echo "[1/4] Checking IPv4 connectivity..."
if ping -c 2 8.8.8.8 >/dev/null 2>&1; then
    echo "  [OK] IPv4 Internet is working."
else
    echo "  [FAIL] Cannot reach IPv4 Internet!"
fi

echo ""
echo "[2/4] Testing IPv6 Stability..."
if ping6 -c 2 2001:4860:4860::8888 >/dev/null 2>&1; then
    echo "  [OK] IPv6 is working properly."
else
    echo "  [WARNING] IPv6 is failing (packet loss detected) - prioritize IPv4!"
fi

echo ""
echo "[3/4] Testing Minecraft Java Server (147.185.221.22:64766)..."
if nc -z -w 3 147.185.221.22 64766 >/dev/null 2>&1; then
    echo "  [OK] Java Port (64766) is reachable!"
else
    echo "  [INFO] Checking Java domain tissues-convertible.tun.ply.gg..."
fi

echo ""
echo "[4/4] Summary & Connection Details:"
echo "  • Java Edition:    tissues-convertible.tun.ply.gg (or 147.185.221.22:64766)"
echo "  • Bedrock Edition: tissues-sweep.tun.ply.gg  | Port: 14121"
echo "================================================================"
