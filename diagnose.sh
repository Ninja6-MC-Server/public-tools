#!/usr/bin/env bash
# Ninja6 Minecraft Server Network Diagnostic Tool (Linux/Mac/Android Termux)
# Run via: curl -sSL https://raw.githubusercontent.com/Ninja6-MC-Server/public-tools/main/diagnose.sh | bash
#
# This script only reads information and opens test connections.
# It does not change any setting on your device.

# Server addresses (keep in sync with README.md)
JAVA_DOMAIN="tissues-convertible.tun.ply.gg"
JAVA_DEFAULT_PORT=25565   # used by the game when the SRV lookup fails
BEDROCK_ADDRESS="la64zuc5.free.tryportwarp.cc"
BEDROCK_PORT=11899
BEDROCK_VERSIONS="1.26.50 to 1.26.60"

ISSUES=0

# Run a command, but give up after $1 seconds (works without the timeout tool).
run_with_limit() {
    local limit=$1
    shift
    "$@" &
    local pid=$!
    ( sleep "$limit"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    local watcher=$!
    wait "$pid"
    local rc=$?
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    return $rc
}

# Open a TCP connection and close it again.
tcp_connect() {
    ( exec 3<>"/dev/tcp/$1/$2" ) 2>/dev/null
}

# Print a number as a Minecraft VarInt, in printf escape form.
varint() {
    local v=$1 b out=""
    while :; do
        b=$((v & 0x7F))
        v=$((v >> 7))
        if [ "$v" -ne 0 ]; then b=$((b | 0x80)); fi
        out="$out$(printf '\\x%02x' "$b")"
        if [ "$v" -eq 0 ]; then break; fi
    done
    printf '%s' "$out"
}

# Minecraft server list ping, using the domain name as the handshake host
# (the same thing the game does).
# Exit codes: 0 = server answered, 2 = could not connect, 3 = connected but no answer.
java_ping() {
    local host=$1 port=$2 body packet resp="" c
    # packet id 0, protocol 767, host, port (big endian), next state 1 (status)
    body="\\x00$(varint 767)$(varint ${#host})${host}$(printf '\\x%02x\\x%02x' $((port >> 8)) $((port & 255)))\\x01"
    # length prefix: 1 + 2 + 1 + host length + 2 + 1 bytes
    packet="$(varint $(( ${#host} + 7 )))${body}\\x01\\x00"
    exec 3<>"/dev/tcp/$host/$port" 2>/dev/null || return 2
    # shellcheck disable=SC2059
    printf "$packet" >&3
    while IFS= read -r -t 5 -n 1 c <&3; do
        resp="$resp$c"
        case "$resp" in *'"version"'*) exec 3<&-; return 0 ;; esac
        if [ ${#resp} -ge 4096 ]; then break; fi
    done
    exec 3<&-
    return 3
}

echo "================================================================"
echo "          NINJA6 MINECRAFT SERVER NETWORK DIAGNOSTIC TOOL       "
echo "================================================================"
echo "  Read-only: this tool does not change anything on your device."
echo ""

echo "[1/4] Checking IPv4 connectivity..."
if ping -c 2 8.8.8.8 >/dev/null 2>&1 || run_with_limit 5 tcp_connect 1.1.1.1 443; then
    echo "  [OK] IPv4 Internet is working."
else
    echo "  [FAIL] Cannot reach the IPv4 Internet!"
    ISSUES=$((ISSUES + 1))
fi

echo ""
echo "[2/4] Checking IPv6 (information only)..."
if ping6 -c 2 2001:4860:4860::8888 >/dev/null 2>&1 || ping -6 -c 2 2001:4860:4860::8888 >/dev/null 2>&1; then
    echo "  [OK] IPv6 works. Bedrock can use the direct IPv6 route (the best route)."
else
    echo "  [INFO] IPv6 ping got no reply (or this network has no IPv6)."
    echo "         Keep IPv6 turned on; Bedrock falls back to the relay route on its own."
fi

echo ""
echo "[3/4] Testing Minecraft Java server ($JAVA_DOMAIN)..."
JAVA_PORT=$JAVA_DEFAULT_PORT
SRV=""
if command -v dig >/dev/null 2>&1; then
    SRV=$(dig +short SRV "_minecraft._tcp.$JAVA_DOMAIN" 2>/dev/null | awk 'NR==1 {print $3}')
elif command -v host >/dev/null 2>&1; then
    SRV=$(host -t SRV "_minecraft._tcp.$JAVA_DOMAIN" 2>/dev/null | awk '/has SRV record/ {print $(NF-1); exit}')
fi
case "$SRV" in
    ''|*[!0-9]*) echo "  [INFO] Could not look up the server's port record; testing port $JAVA_PORT." ;;
    *) JAVA_PORT=$SRV; echo "  [OK] Server name found (port $JAVA_PORT)." ;;
esac

run_with_limit 15 java_ping "$JAVA_DOMAIN" "$JAVA_PORT"
case $? in
    0) echo "  [OK] Java server answered the server list ping." ;;
    3) echo "  [FAIL] Connected to the tunnel, but the Java server did not answer."
       echo "         The server may be offline or restarting. Try again in a few minutes."
       ISSUES=$((ISSUES + 1)) ;;
    *) echo "  [FAIL] Cannot connect to $JAVA_DOMAIN port $JAVA_PORT."
       echo "         (If your shell has no /dev/tcp support, this test cannot run here.)"
       ISSUES=$((ISSUES + 1)) ;;
esac

echo ""
echo "[4/4] Testing Minecraft Bedrock join address ($BEDROCK_ADDRESS port $BEDROCK_PORT)..."
if run_with_limit 8 tcp_connect "$BEDROCK_ADDRESS" "$BEDROCK_PORT"; then
    echo "  [OK] Bedrock join address is reachable (TCP)."
    echo "       Game traffic (UDP) is set up separately when you join, so this check"
    echo "       cannot prove the whole join path. It shows the address is up."
else
    echo "  [FAIL] Cannot connect to $BEDROCK_ADDRESS port $BEDROCK_PORT (TCP)."
    ISSUES=$((ISSUES + 1))
fi

echo ""
echo "================================================================"
echo "                      DIAGNOSTIC SUMMARY                        "
echo "================================================================"
if [ "$ISSUES" -eq 0 ]; then
    echo "STATUS: ALL CHECKS PASSED!"
else
    echo "STATUS: $ISSUES CHECK(S) FAILED (see above)."
fi
echo ""
echo "How to connect to the Ninja6 Server:"
echo ""
echo "  * JAVA EDITION (PC):"
echo "    Server Address: $JAVA_DOMAIN"
echo "    Type the name exactly like this, with no port. Do NOT use a numeric IP"
echo "    address: the tunnel only accepts players who connect by this name."
echo ""
echo "  * BEDROCK EDITION (Mobile / Windows / Consoles), versions $BEDROCK_VERSIONS:"
echo "    Server Address: $BEDROCK_ADDRESS"
echo "    Port:           $BEDROCK_PORT"
echo "    (Do NOT use the Java address on Bedrock; it will fail.)"
echo "================================================================"
