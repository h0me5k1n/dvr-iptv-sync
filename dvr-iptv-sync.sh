#!/bin/sh
# =============================================================================
# dvr-iptv-sync.sh - IPTV provider domain routing manager for domain_vpn_routing
# =============================================================================
# Reads M3U or Xtream Codes provider URLs from a cfg file, extracts stream
# domains, and updates a domain_vpn_routing policy on Asuswrt-Merlin routers.
#
# Usage:
#   sh dvr-iptv-sync.sh          - dry run (check only, no changes made)
#   sh dvr-iptv-sync.sh UPDATE   - apply updates to domain_vpn_routing policy
#
# Requirements:
#   - Asuswrt-Merlin firmware with domain_vpn_routing installed via amtm
#   - Entware curl with SSL support (opkg install curl)
#   - A domain_vpn_routing policy already created (see README)
#
# Configuration:
#   Edit dvr-iptv-sync.cfg (in the same directory as this script) to add your
#   IPTV provider URLs. See dvr-iptv-sync.cfg.example for format details.
# =============================================================================

# Entware binaries are not in PATH when scripts are run with sh on Merlin
export PATH=/opt/bin:/opt/sbin:$PATH

SCRIPTNAME="$(basename "$0")"
SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"
vLOG="$SCRIPTDIR/${SCRIPTNAME%.*}.log"
LOCKFILE="$SCRIPTDIR/${SCRIPTNAME%.*}.lock"
LISTFILE="$SCRIPTDIR/${SCRIPTNAME%.*}.cfg"

# domain_vpn_routing policy name (must be created before running this script)
POLICY_NAME=IPTV

# Derived path to the policy domain list file
DOMAINLIST_FILE="/jffs/configs/domain_vpn_routing/policy_${POLICY_NAME}_domainlist"

# Timeout in seconds for curl requests
CURLTIMEOUT=30

# Interface to bind playlist downloads to. Leave empty to auto-detect from the
# domain_vpn_routing policy config (recommended). Set explicitly to override,
# e.g. tun11 (OpenVPN client 1) or wg11 (WireGuard client 1).
CURL_INTERFACE=""

# Known dynamic DNS providers - use full domain rather than TLD for these
DYNAMIC_DNS_PROVIDERS="ddns.net dynns.com no-ip.com dyndns.org"

# =============================================================================
# LOGGING
# =============================================================================

PrintLog() {
    echo "[$(date)] - ${*}" >> "${vLOG}"
}

TrimLog() {
    [ -f "$vLOG" ] || return
    local LINES
    LINES=$(wc -l < "$vLOG")
    if [ "$LINES" -gt 500 ]; then
        local TMP
        TMP=$(mktemp /tmp/dvr_iptv_sync_trim.XXXXXX)
        tail -250 "$vLOG" > "$TMP" && mv "$TMP" "$vLOG"
    fi
}

log_and_print() {
    echo "$*"
    PrintLog "$*"
}

SysLog() {
    logger -t "dvr-iptv-sync" "$*"
}

# =============================================================================
# INTERFACE DETECTION
# =============================================================================

# Read the interface assigned to the policy from domain_vpn_routing's config
# and map it to the tunnel device name curl can bind to.
detect_policy_interface() {
    local DVR_CONF="/jffs/configs/domain_vpn_routing/domain_vpn_routing.conf"
    [ -f "$DVR_CONF" ] || return 0

    local IFACE
    IFACE=$(awk -F"|" -v p="$POLICY_NAME" '$1 == p {print $4; exit}' "$DVR_CONF")

    case "$IFACE" in
        ovpnc1) echo "tun11" ;;
        ovpnc2) echo "tun12" ;;
        ovpnc3) echo "tun13" ;;
        ovpnc4) echo "tun14" ;;
        ovpnc5) echo "tun15" ;;
        wgc1)   echo "wg11"  ;;
        wgc2)   echo "wg12"  ;;
        wgc3)   echo "wg13"  ;;
        wgc4)   echo "wg14"  ;;
        wgc5)   echo "wg15"  ;;
        *)      echo ""      ;;  # WAN or unknown — no binding needed
    esac
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
        echo "       Copy dvr-iptv-sync.cfg.example to dvr-iptv-sync.cfg and edit it."
        ERRORS=$((ERRORS + 1))
    fi

    # Check domain_vpn_routing script exists
    if [ ! -f "/jffs/scripts/domain_vpn_routing.sh" ]; then
        echo "ERROR: /jffs/scripts/domain_vpn_routing.sh not found."
        echo "       Install domain_vpn_routing via amtm:"
        echo "         amtm"
        echo "       Then select the option to install domain_vpn_routing."
        ERRORS=$((ERRORS + 1))
    fi

    # Check policy domainlist file exists
    if [ ! -f "$DOMAINLIST_FILE" ]; then
        echo "ERROR: Policy domainlist not found: $DOMAINLIST_FILE"
        echo "       Create the '$POLICY_NAME' policy in domain_vpn_routing first:"
        echo "       /jffs/scripts/domain_vpn_routing.sh createpolicy"
        ERRORS=$((ERRORS + 1))
    else
        echo "  [OK] Policy $POLICY_NAME found"

        # Auto-detect download interface from policy config if not manually set
        if [ -z "$CURL_INTERFACE" ]; then
            CURL_INTERFACE=$(detect_policy_interface)
            if [ -n "$CURL_INTERFACE" ]; then
                echo "  [OK] Auto-detected download interface: $CURL_INTERFACE"
            else
                echo "  [OK] Policy routed via WAN — no interface binding needed"
            fi
        else
            echo "  [OK] Download interface (manual override): $CURL_INTERFACE"
        fi
    fi

    # Check curl is available
    if ! which curl >/dev/null 2>&1; then
        echo "ERROR: curl not found."
        echo "       Install via Entware: opkg install curl"
        ERRORS=$((ERRORS + 1))
    else
        if ! curl --version 2>&1 | grep -qi "ssl\|openssl\|mbedtls\|wolfssl\|nss"; then
            echo "WARNING: curl may not have SSL support."
            echo "         Install Entware curl for HTTPS support: opkg install curl"
        else
            echo "  [OK] curl SSL support detected"
        fi
    fi

    # Warn if cru job is not persisted in services-start (won't survive reboot)
    if ! grep -qs "dvr-iptv-sync" /jffs/scripts/services-start; then
        echo "  WARNING: Cron job not found in /jffs/scripts/services-start."
        echo "           The schedule will not survive a reboot. To fix, run:"
        echo "           echo 'cru a dvr-iptv-sync \"0 3,12,19 * * * sh ${SCRIPTDIR}/${SCRIPTNAME} UPDATE\"' >> /jffs/scripts/services-start"
        echo "           chmod +x /jffs/scripts/services-start"
    else
        echo "  [OK] Cron job persisted in services-start"
    fi

    if [ "$ERRORS" -gt 0 ]; then
        echo ""
        echo "Preflight checks failed with $ERRORS error(s). Exiting."
        PrintLog "Preflight checks failed with $ERRORS error(s). Exiting."
        SysLog "ERROR: preflight failed with $ERRORS error(s)"
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
    SERVER="${SERVER%/}"
    echo "${SERVER}/get.php?username=${USER}&password=${PASS}&type=m3u_plus&output=mpegts"
}

# =============================================================================
# M3U PROCESSING
# =============================================================================

# Fetch an M3U from a URL and extract unique hosts from stream URLs.
# All log output goes to stderr so it is not captured when called with $().
# Content is written to a temp file to avoid busybox shell variable size limits.
fetch_and_extract() {
    local URL="$1"
    local LABEL="$2"
    local TMPFILE="/tmp/dvr_iptv_sync_$$.m3u"

    echo "  Fetching M3U from: $LABEL" >&2
    PrintLog "  Fetching M3U from: $LABEL"

    if [ -n "$CURL_INTERFACE" ]; then
        curl --interface "$CURL_INTERFACE" --connect-timeout "$CURLTIMEOUT" -s -L "$URL" -o "$TMPFILE"
    else
        curl --connect-timeout "$CURLTIMEOUT" -s -L "$URL" -o "$TMPFILE"
    fi

    if [ ! -s "$TMPFILE" ]; then
        echo "  WARNING: No content returned from $LABEL" >&2
        PrintLog "  WARNING: No content returned from $LABEL"
        SysLog "WARNING: no content returned from $LABEL"
        rm -f "$TMPFILE"
        return 1
    fi

    # Extract unique hosts from stream URLs (http/https, with or without port)
    local RESULT
    RESULT=$(grep -E "^https?://" "$TMPFILE" | awk -F[/:] '{print $4}' | sort -u)
    rm -f "$TMPFILE"

    if [ -z "$RESULT" ]; then
        echo "  WARNING: Playlist received but no http(s) stream URLs found." >&2
        echo "           Stream URLs must appear at the start of a line." >&2
        PrintLog "  WARNING: Playlist received but no http(s) stream URLs found from $LABEL"
        SysLog "WARNING: no stream URLs found in playlist from $LABEL"
        return 1
    fi

    echo "$RESULT"
}

# Get the routing domain for a hostname, respecting dynamic DNS providers
get_routing_domain() {
    local DOMAIN="$1"
    local TLD
    TLD=$(echo "$DOMAIN" | grep -o '[^.]*\.[^.]*$')

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
# DOMAIN_VPN_ROUTING UPDATE LOGIC
# =============================================================================

process_hosts() {
    local HOSTS="$1"
    local NEW_DOMAINS=""

    # Read existing entries from the policy domainlist
    local EXISTING
    EXISTING=$(grep -v '^$' "$DOMAINLIST_FILE" 2>/dev/null)

    for HOST in $HOSTS; do
        # Skip bare IP addresses - domain_vpn_routing is domain-based only
        if expr "$HOST" : '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' >/dev/null 2>&1; then
            log_and_print "  [SKIP] $HOST is a bare IP address - skipping"
            continue
        fi

        local RDOMAIN
        RDOMAIN=$(get_routing_domain "$HOST")

        if echo "$EXISTING" | grep -qxF "$RDOMAIN"; then
            log_and_print "  [DOM ] $HOST (routing as $RDOMAIN) already in policy"
        else
            log_and_print "  [DOM+] $HOST (routing as $RDOMAIN) NOT in policy - will add"
            # Avoid duplicates within a single run
            if ! echo "$NEW_DOMAINS" | grep -qxF "$RDOMAIN" 2>/dev/null; then
                NEW_DOMAINS=$(printf "%s\n%s" "$NEW_DOMAINS" "$RDOMAIN")
            fi
        fi
    done

    NEW_DOMAINS=$(echo "$NEW_DOMAINS" | grep -v '^$')

    if [ -n "$NEW_DOMAINS" ]; then
        local COUNT
        COUNT=$(echo "$NEW_DOMAINS" | wc -l)
        if [ "$ACTION" = "UPDATE" ]; then
            log_and_print "Adding $COUNT new domain(s) to policy $POLICY_NAME..."
            printf "%s\n" "$NEW_DOMAINS" >> "$DOMAINLIST_FILE"
            # domain_vpn_routing requires a trailing blank line in the domainlist
            printf "\n" >> "$DOMAINLIST_FILE"
            log_and_print "Querying policy $POLICY_NAME..."
            sh /jffs/scripts/domain_vpn_routing.sh querypolicy "$POLICY_NAME"
            log_and_print "Policy query completed."
            SYNC_RESULT="$COUNT domain(s) added to policy $POLICY_NAME"
        else
            log_and_print "$COUNT domain(s) would be added (run with UPDATE to apply)."
            SYNC_RESULT="DRY RUN: $COUNT domain(s) would be added to policy $POLICY_NAME"
        fi
    else
        log_and_print "Policy $POLICY_NAME is already up to date."
        SYNC_RESULT="policy $POLICY_NAME up to date"
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

trap 'rm -f "$LOCKFILE"' EXIT

TrimLog
PrintLog "-----"
PrintLog "$SCRIPTNAME started"

ACTION="${1:-null}"
SYNC_RESULT="no hosts found"

if [ "$ACTION" = "UPDATE" ]; then
    log_and_print "Mode: UPDATE (changes will be applied)"
else
    log_and_print "Mode: DRY RUN (pass UPDATE as argument to apply changes)"
fi
SysLog "started [$ACTION]"
echo ""

preflight_checks

ALL_HOSTS=""

while IFS= read -r LINE; do
    # Strip carriage returns (CRLF files) and leading/trailing whitespace
    LINE=$(printf '%s' "$LINE" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$LINE" in
        ""|\#*) continue ;;
    esac

    TYPE=$(echo "$LINE" | cut -d'|' -f1)

    case "$TYPE" in
        M3U)
            URL=$(echo "$LINE" | cut -d'|' -f2)
            log_and_print "Processing M3U provider: $URL"
            HOSTS=$(fetch_and_extract "$URL" "$URL")
            SOURCE_HOST=$(echo "$URL" | awk -F[/:] '{print $4}')
            [ -n "$SOURCE_HOST" ] && HOSTS=$(printf "%s\n%s" "$HOSTS" "$SOURCE_HOST" | sort -u | grep -v '^$')
            ;;
        XC)
            SERVER=$(echo "$LINE" | cut -d'|' -f2)
            USER=$(echo "$LINE" | cut -d'|' -f3)
            PASS=$(echo "$LINE" | cut -d'|' -f4)
            URL=$(build_xc_url "$SERVER" "$USER" "$PASS")
            log_and_print "Processing XC provider: $SERVER (user: $USER)"
            HOSTS=$(fetch_and_extract "$URL" "$SERVER")
            SOURCE_HOST=$(echo "$SERVER" | awk -F[/:] '{print $4}')
            [ -n "$SOURCE_HOST" ] && HOSTS=$(printf "%s\n%s" "$HOSTS" "$SOURCE_HOST" | sort -u | grep -v '^$')
            ;;
        *)
            log_and_print "WARNING: Unknown line type '$TYPE' - skipping: $LINE"
            continue
            ;;
    esac

    if [ -n "$HOSTS" ]; then
        HOSTCOUNT=$(echo "$HOSTS" | wc -l)
        log_and_print "  Found $HOSTCOUNT unique host(s):"
        echo "$HOSTS" | while IFS= read -r H; do
            log_and_print "    $(get_routing_domain "$H") (from $H)"
        done
        ALL_HOSTS=$(printf "%s\n%s" "$ALL_HOSTS" "$HOSTS" | sort -u | grep -v '^$')
    fi

    echo ""

done < "$LISTFILE"

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
SysLog "completed - $SYNC_RESULT"
