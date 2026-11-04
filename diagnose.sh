#!/usr/bin/env bash
# Ninja6 Minecraft Server Network Diagnostic Tool (Linux/Mac/Android Termux)
# Run via: curl -sSL https://raw.githubusercontent.com/Ninja6-MC-Server/public-tools/main/diagnose.sh | bash
#
# This script only reads information and opens test connections.
# It does not change any setting on your device.

TOOL_VERSION="2026-11-05"

# Server addresses (keep in sync with README.md and diagnose.ps1)
JAVA_DOMAIN="tissues-convertible.tun.ply.gg"
JAVA_DEFAULT_PORT=25565   # used by the game when the SRV lookup fails
BEDROCK_ADDRESS="la64zuc5.free.tryportwarp.cc"
BEDROCK_PORT=11899
BEDROCK_VERSIONS="1.26.50 to 1.26.60"

ISSUES=0
FIXES=""
R_NET="?"; R_IPV6="?"; R_DNS="?"; R_JAVA="?"; R_BEDROCK="?"; R_SAVED="?"

add_fix() { FIXES="$FIXES  $1
"; }

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
# (the same thing the game does). An optional third argument is the address to
# connect to, for testing through an IP found by public DNS.
# Exit codes: 0 = server answered, 2 = could not connect, 3 = connected but no answer.
java_ping() {
    local host=$1 port=$2 target=${3:-$1} body packet resp="" c
    # packet id 0, protocol 767, host, port (big endian), next state 1 (status)
    body="\\x00$(varint 767)$(varint ${#host})${host}$(printf '\\x%02x\\x%02x' $((port >> 8)) $((port & 255)))\\x01"
    # length prefix: 1 + 2 + 1 + host length + 2 + 1 bytes
    packet="$(varint $(( ${#host} + 7 )))${body}\\x01\\x00"
    { exec 3<>"/dev/tcp/$target/$port"; } 2>/dev/null || return 2
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

# First IPv4 address for a name, looked up the way apps on this device do.
resolve_system() {
    local out
    if command -v getent >/dev/null 2>&1; then
        out=$(getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1 {print $1}')
        [ -n "$out" ] && { echo "$out"; return; }
    fi
    if command -v dscacheutil >/dev/null 2>&1; then
        out=$(dscacheutil -q host -a name "$1" 2>/dev/null | awk '/^ip_address:/ {print $2; exit}')
        [ -n "$out" ] && { echo "$out"; return; }
    fi
    # ping prints the address it resolved, even when ICMP itself is blocked
    out=$(run_with_limit 4 ping -c 1 "$1" 2>/dev/null | head -1 | sed -n 's/^PING [^(]*(\([0-9.]*\)).*/\1/p')
    echo "$out"
}

# First IPv4 address for a name from Cloudflare DNS over HTTPS (skips your DNS server).
resolve_public() {
    curl -s -m 8 -H 'accept: application/dns-json' \
        "https://cloudflare-dns.com/dns-query?name=$1&type=A" 2>/dev/null |
        grep -o '"type":1,"TTL":[0-9]*,"data":"[0-9.]*"' | head -1 | sed 's/.*"data":"\([0-9.]*\)"/\1/'
}

echo "================================================================"
echo "          NINJA6 MINECRAFT SERVER NETWORK DIAGNOSTIC TOOL       "
echo "================================================================"
echo "  Read-only: this tool does not change anything on your device."
echo ""

echo "[1/6] Checking IPv4 connectivity..."
if ping -c 2 8.8.8.8 >/dev/null 2>&1 || run_with_limit 5 tcp_connect 1.1.1.1 443; then
    echo "  [OK] IPv4 Internet is working."
    R_NET="OK"
else
    echo "  [FAIL] Cannot reach the IPv4 Internet!"
    ISSUES=$((ISSUES + 1)); R_NET="FAIL"
fi

echo ""
echo "[2/6] Checking IPv6 (information only)..."
if ping6 -c 2 2001:4860:4860::8888 >/dev/null 2>&1 || ping -6 -c 2 2001:4860:4860::8888 >/dev/null 2>&1; then
    echo "  [OK] IPv6 works. Bedrock can use the direct IPv6 route (the best route)."
    R_IPV6="OK"
else
    echo "  [INFO] IPv6 ping got no reply (or this network has no IPv6)."
    echo "         Keep IPv6 turned on; Bedrock falls back to the relay route on its own."
    R_IPV6="NOPING"
fi

echo ""
echo "[3/6] Checking that your device can find the server names (DNS)..."
DNS_BLOCKED=0
JAVA_PUBLIC_IP=""
R_DNS="OK"
for NAME in "$JAVA_DOMAIN" "$BEDROCK_ADDRESS"; do
    SYS_IP=$(resolve_system "$NAME")
    if [ -z "$SYS_IP" ]; then
        # No lookup tool gave an answer; a connection by name proves the lookup works
        PROBE_PORT=$BEDROCK_PORT
        [ "$NAME" = "$JAVA_DOMAIN" ] && PROBE_PORT=$JAVA_DEFAULT_PORT
        run_with_limit 6 tcp_connect "$NAME" "$PROBE_PORT" && SYS_IP="lookup works"
    fi
    PUB_IP=$(resolve_public "$NAME")
    [ "$NAME" = "$JAVA_DOMAIN" ] && JAVA_PUBLIC_IP=$PUB_IP
    if [ -n "$SYS_IP" ]; then
        echo "  [OK] $NAME found ($SYS_IP)."
    elif [ -n "$PUB_IP" ]; then
        echo "  [FAIL] Your DNS server cannot find $NAME, but public DNS can ($PUB_IP)."
        echo "         Your network's DNS is blocking or filtering it (internet provider,"
        echo "         router, school/work filter, ad blocker or antivirus)."
        ISSUES=$((ISSUES + 1)); DNS_BLOCKED=1; R_DNS="BLOCKED"
    else
        echo "  [INFO] Could not look up $NAME (or this device has no lookup tool)."
        [ "$R_DNS" = "OK" ] && R_DNS="UNKNOWN"
    fi
done
if [ "$DNS_BLOCKED" -eq 1 ]; then
    add_fix "Change your DNS server to 1.1.1.1 and 1.0.0.1 (Cloudflare) or 8.8.8.8 and 8.8.4.4"
    add_fix "(Google) in your network settings or on your router. On Android: Settings >"
    add_fix "Network > Private DNS > enter one.one.one.one or dns.google."
    add_fix "If you use an ad blocker, parental filter or antivirus web shield, allow ply.gg in it."
fi

echo ""
echo "[4/6] Testing Minecraft Java server ($JAVA_DOMAIN)..."
JAVA_PORT=$JAVA_DEFAULT_PORT
SRV=""
if command -v dig >/dev/null 2>&1; then
    SRV=$(dig +short SRV "_minecraft._tcp.$JAVA_DOMAIN" 2>/dev/null | awk 'NR==1 {print $3}')
elif command -v host >/dev/null 2>&1; then
    SRV=$(host -t SRV "_minecraft._tcp.$JAVA_DOMAIN" 2>/dev/null | awk '/has SRV record/ {print $(NF-1); exit}')
fi
case "$SRV" in
    ''|*[!0-9]*) echo "  [INFO] Could not look up the server's port record; testing port $JAVA_PORT." ;;
    *) JAVA_PORT=$SRV; echo "  [OK] Server port record found (port $JAVA_PORT)." ;;
esac

run_with_limit 15 java_ping "$JAVA_DOMAIN" "$JAVA_PORT"
JAVA_RC=$?
if [ "$JAVA_RC" -eq 0 ]; then
    echo "  [OK] Java server answered the server list ping."
    R_JAVA="OK"
elif [ "$DNS_BLOCKED" -eq 1 ] && [ -n "$JAVA_PUBLIC_IP" ]; then
    # Your DNS cannot find the name. Test the server anyway through the address public DNS gave.
    if run_with_limit 15 java_ping "$JAVA_DOMAIN" "$JAVA_PORT" "$JAVA_PUBLIC_IP"; then
        echo "  [FAIL] The game cannot find $JAVA_DOMAIN through your DNS server."
        echo "         The server itself is online and reachable from your network:"
        echo "         fixing your DNS (see below) should let you join."
        R_JAVA="DNSONLY"
    else
        echo "  [FAIL] Your DNS cannot find the server, and a test through public DNS also failed."
        R_JAVA="FAIL"
    fi
    ISSUES=$((ISSUES + 1))
elif [ "$JAVA_RC" -eq 3 ]; then
    echo "  [FAIL] Connected to the tunnel, but the Java server did not answer."
    echo "         The server may be offline or restarting. Try again in a few minutes."
    ISSUES=$((ISSUES + 1)); R_JAVA="NOANSWER"
else
    echo "  [FAIL] Cannot connect to $JAVA_DOMAIN port $JAVA_PORT."
    echo "         (If your shell has no /dev/tcp support, this test cannot run here.)"
    ISSUES=$((ISSUES + 1)); R_JAVA="FAIL"
fi

echo ""
echo "[5/6] Testing Minecraft Bedrock join address ($BEDROCK_ADDRESS port $BEDROCK_PORT)..."
if run_with_limit 8 tcp_connect "$BEDROCK_ADDRESS" "$BEDROCK_PORT"; then
    echo "  [OK] Bedrock join address is reachable (TCP)."
    echo "       Game traffic (UDP) is set up separately when you join, so this check"
    echo "       cannot prove the whole join path. It shows the address is up."
    R_BEDROCK="OK"
else
    echo "  [FAIL] Cannot connect to $BEDROCK_ADDRESS port $BEDROCK_PORT (TCP)."
    ISSUES=$((ISSUES + 1)); R_BEDROCK="FAIL"
fi

echo ""
echo "[6/6] Checking your saved Ninja6 servers for old addresses..."
LISTS_READ=0
SAVED_BAD=0
SAVED_GOOD=0
for LIST in \
    "$HOME/.minecraft/servers.dat" \
    "$HOME/Library/Application Support/minecraft/servers.dat" \
    "$HOME"/.local/share/PrismLauncher/instances/*/.minecraft/servers.dat \
    "$HOME"/.local/share/PrismLauncher/instances/*/minecraft/servers.dat \
    "$HOME"/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/instances/*/.minecraft/servers.dat \
    "$HOME"/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/instances/*/minecraft/servers.dat \
    "$HOME"/Library/Application\ Support/PrismLauncher/instances/*/.minecraft/servers.dat \
    "$HOME"/Library/Application\ Support/PrismLauncher/instances/*/minecraft/servers.dat \
    /sdcard/Android/data/com.mojang.minecraftpe/files/games/com.mojang/minecraftpe/external_servers.txt \
    /sdcard/games/com.mojang/minecraftpe/external_servers.txt
do
    [ -r "$LIST" ] || continue
    LISTS_READ=$((LISTS_READ + 1))
    case "$LIST" in
        *external_servers.txt)
            # Bedrock list, one server per line: index:name:address:port:timestamp
            while IFS=: read -r _ ENAME EHOST EPORT _; do
                case "$EHOST" in
                    "$BEDROCK_ADDRESS")
                        if [ "$EPORT" = "$BEDROCK_PORT" ]; then
                            echo "  [OK] Bedrock server '$ENAME' uses the right address."
                            SAVED_GOOD=$((SAVED_GOOD + 1))
                        else
                            echo "  [FIX] Bedrock server '$ENAME' has port $EPORT. Change it to $BEDROCK_PORT."
                            SAVED_BAD=$((SAVED_BAD + 1))
                        fi ;;
                    *.tun.ply.gg|147.185.221.*)
                        echo "  [FIX] Bedrock server '$ENAME' ($EHOST port $EPORT) is an old address."
                        echo "        Edit it: address $BEDROCK_ADDRESS, port $BEDROCK_PORT"
                        SAVED_BAD=$((SAVED_BAD + 1)) ;;
                esac
            done < "$LIST" ;;
        *)
            # Java list (binary NBT): pick out the addresses that matter
            for ADDR in $(LC_ALL=C grep -aoE '147\.185\.221\.[0-9]+(:[0-9]+)?|2602:fbaf:[0-9a-fA-F:]+|[a-z0-9-]+\.tun\.ply\.gg(:[0-9]+)?|la64zuc5\.free\.tryportwarp\.cc(:[0-9]+)?' "$LIST" 2>/dev/null); do
                case "$ADDR" in
                    "$JAVA_DOMAIN"|"$JAVA_DOMAIN":*)
                        echo "  [OK] Saved Java server $ADDR uses the right address."
                        SAVED_GOOD=$((SAVED_GOOD + 1)) ;;
                    *)
                        echo "  [FIX] Saved Java server $ADDR is an old or wrong address."
                        echo "        Edit it and change the address to: $JAVA_DOMAIN"
                        echo "        (in $LIST)"
                        SAVED_BAD=$((SAVED_BAD + 1)) ;;
                esac
            done ;;
    esac
done

if [ "$LISTS_READ" -eq 0 ]; then
    echo "  [INFO] No saved server lists found (other launchers are not checked)."
    R_SAVED="NONE"
elif [ "$SAVED_BAD" -gt 0 ]; then
    ISSUES=$((ISSUES + 1)); R_SAVED="OLD$SAVED_BAD"
    add_fix "Edit the saved server entries marked [FIX] in step 6, or delete them and add the server again."
elif [ "$SAVED_GOOD" -gt 0 ]; then
    R_SAVED="OK"
else
    echo "  [INFO] Read $LISTS_READ server list(s); no Ninja6 server is saved in them yet."
    R_SAVED="NOTSAVED"
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
if [ -n "$FIXES" ]; then
    echo ""
    echo "WHAT TO DO:"
    printf '%s' "$FIXES"
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

# One line that players can paste into Discord when asking for help
OS_TEXT=$(uname -sm 2>/dev/null | tr ' ' '-')
echo ""
echo "================================================================"
echo "RESULT LINE (paste this in Discord when asking for help):"
echo "  N6DIAG $TOOL_VERSION | NET:$R_NET IPV6:$R_IPV6 DNS:$R_DNS JAVA:$R_JAVA BEDROCK:$R_BEDROCK SAVED:$R_SAVED | $OS_TEXT"
echo "================================================================"
