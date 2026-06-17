#!/bin/sh
# =============================================================================
# x3miptv.sh - IPTV provider domain/IP routing manager for x3mRouting
# =============================================================================
# Reads M3U or Xtream Codes provider URLs from a cfg file, extracts stream
# domains and IPs, and updates x3mRouting IPSET lists on Asuswrt-Merlin routers.
#
# Usage:
#   sh x3miptv.sh          - dry run (check only, no changes made)
#   sh x3miptv.sh UPDATE   - apply updates to x3mRouting configuration
#
# Requirements:
#   - Asuswrt-Merlin firmware with x3mRouting installed
#   - Entware curl with SSL support (opkg install curl)
#   - x3mRouting configured with at least one IPSET in /jffs/scripts/nat-start
#
# Configuration:
#   Edit x3miptv.cfg (in the same directory as this script) to add your
#   IPTV provider URLs. See x3miptv.cfg.example for format details.
# =============================================================================

SCRIPTNAME="$(basename "$0")"
SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"
vLOG="$SCRIPTDIR/${SCRIPTNAME%.*}.log"
LOCKFILE="$SCRIPTDIR/${SCRIPTNAME%.*}.lock"
LISTFILE="$SCRIPTDIR/${SCRIPTNAME%.*}.cfg"

# IPSET name for domain-based routing (must exist in nat-start)
DEFAULT_IPSET_NAME=IPTV
# IPSET name for IP address-based routing (must exist in nat-start)
IPADDRESS_IPSET_NAME=IPADDRESSTV

# Timeout in seconds for curl requests
CURLTIMEOUT=30

# Known dynamic DNS providers - use full domain rather than TLD for these
DYNAMIC_DNS_PROVIDERS="ddns.net dynns.com no-ip.com dyndns.org"

# =============================================================================
# LOGGING
# =============================================================================

PrintLog() {
    echo "[$(date)] - ${*}" >> "${vLOG}"
}

TrimLog() {
    touch "$vLOG"
    NumLogLines=$(wc -l < "$vLOG")
    if [ "$NumLogLines" -gt 500 ]; then
        echo "$(tail -250 "$vLOG")" > "$vLOG"
    fi
}

log_and_print() {
    echo "$*"
    PrintLog "$*"
}

# =============================================================================
# PREFLIGHT CHECKS
# =============================================================================

preflight_checks() {
    local ERRORS=0

    echo "Running preflight checks..."

    # Check cfg file exists
    if [ ! -f "$LISTFILE" ]; then
        echo "ERROR: Config file not found: $LISTFILE"
        echo "       Copy x3miptv.cfg.example to x3miptv.cfg and edit it."
        ERRORS=$((ERRORS + 1))
    fi

    # Check nat-start exists
    if [ ! -f "/jffs/scripts/nat-start" ]; then
        echo "ERROR: /jffs/scripts/nat-start not found."
        echo "       x3mRouting must be installed and configured before running this script."
        ERRORS=$((ERRORS + 1))
    fi

    # Check x3mRouting is available
    if ! command -v x3mRouting >/dev/null 2>&1; then
        echo "ERROR: x3mRouting command not found."
        echo "       Ensure x3mRouting is installed via amtm."
        ERRORS=$((ERRORS + 1))
    fi

    # Check curl is available
    if ! command -v curl >/dev/null 2>&1; then
        echo "ERROR: curl not found."
        echo "       Install via Entware: opkg install curl"
        ERRORS=$((ERRORS + 1))
    else
        # Check curl SSL support
        if ! curl --version 2>&1 | grep -qi "ssl\|openssl\|mbedtls\|wolfssl\|nss"; then
            echo "WARNING: curl may not have SSL support."
            echo "         Install Entware curl for HTTPS support: opkg install curl"
        else
            echo "  [OK] curl SSL support detected"
        fi
    fi

    # Check ipset is available
    if ! command -v ipset >/dev/null 2>&1; then
        echo "ERROR: ipset command not found."
        ERRORS=$((ERRORS + 1))
    fi

    if [ "$ERRORS" -gt 0 ]; then
        echo ""
        echo "Preflight checks failed with $ERRORS error(s). Exiting."
        PrintLog "Preflight checks failed with $ERRORS error(s). Exiting."
        exit 1
    fi

    echo "  [OK] All preflight checks passed."
    echo ""
}

# =============================================================================
# URL CONSTRUCTION
# =============================================================================

# Build an M3U URL from an Xtream Codes server URL, username and password
build_xc_url() {
    local SERVER="$1"
    local USER="$2"
    local PASS="$3"
    # Strip any trailing slash from server URL
    SERVER="${SERVER%/}"
    echo "${SERVER}/get.php?username=${USER}&password=${PASS}&type=m3u_plus&output=mpegts"
}

# =============================================================================
# M3U PROCESSING
# =============================================================================

# Fetch an M3U from a URL and extract unique domains and IP addresses
fetch_and_extract() {
    local URL="$1"
    local LABEL="$2"

    log_and_print "  Fetching M3U from: $LABEL"
    local CONTENT
    CONTENT=$(curl --connect-timeout "$CURLTIMEOUT" -s -L "$URL")

    if [ -z "$CONTENT" ]; then
        log_and_print "  WARNING: No content returned from $LABEL"
        return 1
    fi

    # Extract unique hosts (domain or IP) from stream URLs
    # Handles http and https, with or without port numbers
    echo "$CONTENT" | grep -E "^https?://" | awk -F[/:] '{print $4}' | sort -u
}

# Determine whether a string is an IPv4 address
is_ip_address() {
    expr "$1" : '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' >/dev/null 2>&1
}

# Get the top-level domain for a hostname, respecting dynamic DNS providers
get_routing_domain() {
    local DOMAIN="$1"
    local TLD
    TLD=$(echo "$DOMAIN" | grep -o '[^.]*\.[^.]*$')

    # Check if TLD matches a known dynamic DNS provider — if so use full domain
    local DYN
    for DYN in $DYNAMIC_DNS_PROVIDERS; do
        if [ "$TLD" = "$DYN" ]; then
            echo "$DOMAIN"
            return
        fi
    done

    echo "$TLD"
}

# =============================================================================
# X3MROUTING UPDATE LOGIC
# =============================================================================

process_hosts() {
    local HOSTS="$1"

    # Read current x3mRouting lines from nat-start
    local X3M_LINE_ORIGINAL
    X3M_LINE_ORIGINAL=$(grep "/jffs/scripts/x3mRouting/x3mRouting.sh" /jffs/scripts/nat-start | grep "$DEFAULT_IPSET_NAME" | head -1)
    X3M_LINE_ORIGINAL="${X3M_LINE_ORIGINAL/sh \/jffs\/scripts\/x3mRouting\/x3mRouting.sh/x3mRouting}"
    local X3M_LINE="$X3M_LINE_ORIGINAL"

    local X3M_LINE_IP_ORIGINAL
    X3M_LINE_IP_ORIGINAL=$(grep "/jffs/scripts/x3mRouting/x3mRouting.sh" /jffs/scripts/nat-start | grep "$IPADDRESS_IPSET_NAME" | head -1)
    X3M_LINE_IP_ORIGINAL="${X3M_LINE_IP_ORIGINAL/sh \/jffs\/scripts\/x3mRouting\/x3mRouting.sh/x3mRouting}"
    local X3M_LINE_IP="$X3M_LINE_IP_ORIGINAL"

    # Collect all IPs currently in the IP IPSET
    local EXISTING_IPS
    EXISTING_IPS=$(ipset -L "$IPADDRESS_IPSET_NAME" 2>/dev/null | grep -E "^[0-9]+\." | sort -u)

    # Track new IPs to add
    local NEW_IPS="$EXISTING_IPS"

    for HOST in $HOSTS; do
        if is_ip_address "$HOST"; then
            # --- IP address handling ---
            if echo "$EXISTING_IPS" | grep -q "^${HOST}$"; then
                log_and_print "  [IP ] $HOST already in $IPADDRESS_IPSET_NAME"
            else
                log_and_print "  [IP+] $HOST NOT in $IPADDRESS_IPSET_NAME - will add"
                NEW_IPS=$(printf "%s\n%s" "$NEW_IPS" "$HOST" | sort -u)
            fi
        else
            # --- Domain handling ---
            local RDOMAIN
            RDOMAIN=$(get_routing_domain "$HOST")

            if grep "/jffs/scripts/x3mRouting/x3mRouting.sh" /jffs/scripts/nat-start | grep "$DEFAULT_IPSET_NAME" | grep -q "$RDOMAIN"; then
                log_and_print "  [DOM] $HOST (routing as $RDOMAIN) already in $DEFAULT_IPSET_NAME"
            else
                log_and_print "  [DOM+] $HOST (routing as $RDOMAIN) NOT in $DEFAULT_IPSET_NAME - will add"
                X3M_LINE="${X3M_LINE},${RDOMAIN}"
            fi
        fi
    done

    # --- Apply domain IPSET updates ---
    if [ "$X3M_LINE" != "$X3M_LINE_ORIGINAL" ]; then
        if [ "$ACTION" = "UPDATE" ]; then
            log_and_print "Applying domain IPSET update for $DEFAULT_IPSET_NAME..."
            x3mRouting ipset_name="$DEFAULT_IPSET_NAME" del
            $X3M_LINE
            log_and_print "Domain IPSET updated successfully."
        else
            log_and_print "Domain IPSET update required (run with UPDATE to apply)."
        fi
    else
        log_and_print "Domain IPSET $DEFAULT_IPSET_NAME is up to date."
    fi

    # --- Apply IP IPSET updates ---
    if [ "$NEW_IPS" != "$EXISTING_IPS" ]; then
        if [ "$ACTION" = "UPDATE" ]; then
            log_and_print "Applying IP IPSET update for $IPADDRESS_IPSET_NAME..."
            # Build comma-separated IP list for x3mRouting
            local IP_LIST
            IP_LIST=$(echo "$NEW_IPS" | tr '\n' ',' | sed 's/,$//')
            x3mRouting ipset_name="$IPADDRESS_IPSET_NAME" del
            x3mRouting ipset_name="$IPADDRESS_IPSET_NAME" ip="$IP_LIST"
            log_and_print "IP IPSET updated successfully."
        else
            log_and_print "IP IPSET update required (run with UPDATE to apply)."
        fi
    else
        log_and_print "IP IPSET $IPADDRESS_IPSET_NAME is up to date."
    fi
}

# =============================================================================
# MAIN
# =============================================================================

# Prevent concurrent runs
if [ -f "$LOCKFILE" ]; then
    echo "Lock file exists ($LOCKFILE). Is another instance running?"
    exit 1
fi
touch "$LOCKFILE"

# Ensure lockfile is removed on exit
trap 'rm -f "$LOCKFILE"' EXIT

TrimLog
PrintLog "-----"
PrintLog "$SCRIPTNAME started"

# Determine action
ACTION="${1:-null}"
if [ "$ACTION" = "UPDATE" ]; then
    log_and_print "Mode: UPDATE (changes will be applied)"
else
    log_and_print "Mode: DRY RUN (pass UPDATE as argument to apply changes)"
fi
echo ""

# Run preflight checks
preflight_checks

# Accumulate all hosts across all providers
ALL_HOSTS=""

# Read and process each line of the cfg file
while IFS= read -r LINE; do
    # Skip blank lines and comments
    case "$LINE" in
        ""|\#*) continue ;;
    esac

    # Parse line type
    TYPE=$(echo "$LINE" | cut -d'|' -f1)

    case "$TYPE" in
        M3U)
            URL=$(echo "$LINE" | cut -d'|' -f2)
            log_and_print "Processing M3U provider: $URL"
            HOSTS=$(fetch_and_extract "$URL" "$URL")
            ;;
        XC)
            SERVER=$(echo "$LINE" | cut -d'|' -f2)
            USER=$(echo "$LINE" | cut -d'|' -f3)
            PASS=$(echo "$LINE" | cut -d'|' -f4)
            URL=$(build_xc_url "$SERVER" "$USER" "$PASS")
            log_and_print "Processing XC provider: $SERVER (user: $USER)"
            HOSTS=$(fetch_and_extract "$URL" "$SERVER")
            ;;
        *)
            log_and_print "WARNING: Unknown line type '$TYPE' - skipping: $LINE"
            continue
            ;;
    esac

    if [ -n "$HOSTS" ]; then
        HOSTCOUNT=$(echo "$HOSTS" | wc -w)
        log_and_print "  Found $HOSTCOUNT unique host(s)"
        # Accumulate, deduplicating as we go
        ALL_HOSTS=$(printf "%s\n%s" "$ALL_HOSTS" "$HOSTS" | sort -u | grep -v '^$')
    fi

    echo ""

done < "$LISTFILE"

# Process all accumulated hosts against x3mRouting
if [ -n "$ALL_HOSTS" ]; then
    TOTAL=$(echo "$ALL_HOSTS" | wc -l)
    log_and_print "Processing $TOTAL unique host(s) across all providers..."
    echo ""
    process_hosts "$ALL_HOSTS"
else
    log_and_print "No hosts found across any providers. Check your cfg file and provider URLs."
fi

echo ""
PrintLog "$SCRIPTNAME completed"
log_and_print "$SCRIPTNAME completed."
