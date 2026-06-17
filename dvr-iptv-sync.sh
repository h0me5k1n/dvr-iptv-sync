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
    fi

    # Check curl is available
    if ! command -v curl >/dev/null 2>&1; then
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
    SERVER="${SERVER%/}"
    echo "${SERVER}/get.php?username=${USER}&password=${PASS}&type=m3u_plus&output=mpegts"
}

# =============================================================================
# M3U PROCESSING
# =============================================================================

# Fetch an M3U from a URL and extract unique hosts from stream URLs
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

    # Extract unique hosts from stream URLs (http/https, with or without port)
    echo "$CONTENT" | grep -E "^https?://" | awk -F[/:] '{print $4}' | sort -u
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
        else
            log_and_print "$COUNT domain(s) would be added (run with UPDATE to apply)."
        fi
    else
        log_and_print "Policy $POLICY_NAME is already up to date."
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
if [ "$ACTION" = "UPDATE" ]; then
    log_and_print "Mode: UPDATE (changes will be applied)"
else
    log_and_print "Mode: DRY RUN (pass UPDATE as argument to apply changes)"
fi
echo ""

preflight_checks

ALL_HOSTS=""

while IFS= read -r LINE; do
    case "$LINE" in
        ""|\#*) continue ;;
    esac

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
        HOSTCOUNT=$(echo "$HOSTS" | wc -l)
        log_and_print "  Found $HOSTCOUNT unique host(s)"
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
