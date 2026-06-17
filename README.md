# x3miptv

Automatically manages [x3mRouting](https://github.com/Xentrk/x3mRouting) IPSET lists on Asuswrt-Merlin routers based on the domains and IP addresses found in your IPTV provider playlists.

## The Problem

If you run NordVPN (or any VPN) on your Asus router via Asuswrt-Merlin and want your IPTV streams routed through it, you need to tell x3mRouting which domains and IPs belong to your IPTV providers. These can change when providers update their infrastructure, and managing them manually is tedious.

This script automates that: it fetches your M3U playlists, extracts the streaming domains and IP addresses, compares them against your existing x3mRouting IPSET lists, and updates them if anything has changed.

## Features

- Supports **M3U** and **Xtream Codes (XC)** provider types
- Supports **HTTP and HTTPS** provider URLs
- Handles both **domain-based** and **IP address-based** IPSET lists
- **Dry run by default** — no changes made unless you explicitly pass `UPDATE`
- Accumulates and deduplicates hosts across multiple providers before updating
- Handles **dynamic DNS providers** (uses full domain rather than TLD)
- Preflight checks for dependencies before doing any work
- Lock file prevents concurrent runs
- Log file with automatic trimming

## Requirements

- Asus router running [Asuswrt-Merlin](https://www.asuswrt-merlin.net/) firmware
- [x3mRouting](https://github.com/Xentrk/x3mRouting) installed and configured via [amtm](https://diversion.ch/amtm/)
- At least one IPSET list already configured in `/jffs/scripts/nat-start`
- Entware `curl` with SSL support (see below)

### Installing Entware curl with SSL support

The built-in router curl may not support HTTPS. Install the Entware version:

```sh
opkg install curl
```

Verify SSL support is present:

```sh
curl --version | grep -i ssl
```

You should see something like `OpenSSL` or `mbedTLS` in the output. The script will warn you at startup if SSL support cannot be detected.

## Installation

### 1. Copy the script to your router

The recommended location is your router USB drive, which persists across reboots.

Via SCP from your PC:

```sh
scp x3miptv.sh admin@192.168.1.1:/tmp/mnt/routerusb/x3miptv/
scp x3miptv.cfg.example admin@192.168.1.1:/tmp/mnt/routerusb/x3miptv/
```

Or SSH into the router and clone/download directly if you have git or wget available via Entware.

### 2. Make the script executable

```sh
chmod +x /tmp/mnt/routerusb/x3miptv/x3miptv.sh
```

### 3. Create your config file

```sh
cp /tmp/mnt/routerusb/x3miptv/x3miptv.cfg.example \
   /tmp/mnt/routerusb/x3miptv/x3miptv.cfg
```

Edit `x3miptv.cfg` with your provider details (see [Configuration](#configuration) below).

### 4. Ensure your x3mRouting IPSETs exist

The script expects at least one IPSET already configured in `/jffs/scripts/nat-start`. The default IPSET names are:

| Purpose | Default name |
|---|---|
| Domain-based routing | `IPTV` |
| IP address-based routing | `IPADDRESSTV` |

These names can be changed at the top of `x3miptv.sh` if yours differ:

```sh
DEFAULT_IPSET_NAME=IPTV
IPADDRESS_IPSET_NAME=IPADDRESSTV
```

## Configuration

Your config file (`x3miptv.cfg`) uses a simple pipe-separated format. Lines beginning with `#` are comments. Blank lines are ignored.

### M3U provider

```
M3U|<full_playlist_url>
```

Examples:

```
M3U|https://iptv-org.github.io/iptv/countries/gb.m3u
M3U|https://yourprovider.com/get.php?username=user&password=pass&type=m3u_plus&output=mpegts
```

### Xtream Codes provider

```
XC|<server_url>|<username>|<password>
```

The script constructs the M3U URL from your credentials automatically. Include the full protocol and port in the server URL.

Examples:

```
XC|http://yourprovider.com:8080|yourusername|yourpassword
XC|https://yourprovider.com:8443|yourusername|yourpassword
```

### Multiple providers

Add as many lines as you need. All domains and IPs are accumulated and deduplicated across all providers before updating x3mRouting.

```
M3U|https://iptv-org.github.io/iptv/countries/gb.m3u
XC|http://provider1.com:8080|user1|pass1
XC|https://provider2.com:8443|user2|pass2
```

## Usage

### Dry run (check only — no changes made)

```sh
sh /tmp/mnt/routerusb/x3miptv/x3miptv.sh
```

This shows what would be added to your IPSET lists without making any changes. Always run this first to verify the output looks correct.

### Apply updates

```sh
sh /tmp/mnt/routerusb/x3miptv/x3miptv.sh UPDATE
```

This updates your x3mRouting IPSET lists with any new domains or IPs found.

## Scheduling with cron

IPTV provider IPs and domains don't change frequently, but automating a periodic check means you won't be caught out. A daily check is plenty.

Add a cron job via the Merlin UI (**Administration → System → Cron Job**), or directly via Entware cron:

```sh
# Run at 03:00 every day, applying updates automatically
0 3 * * * sh /tmp/mnt/routerusb/x3miptv/x3miptv.sh UPDATE >> /tmp/mnt/routerusb/x3miptv/x3miptv.log 2>&1
```

## Editing your config without SSH

Your `x3miptv.cfg` lives on the router USB drive, which is accessible in several ways without needing to SSH in:

### Samba (Windows network share) — easiest

Enable the USB share in the Merlin web UI under **USB Application → Network Place (Samba) Share**. Your cfg file will then be accessible from Windows Explorer as a network drive, or from any SMB client on your LAN. Edit it in any text editor and save directly.

### SFTP (WinSCP / Cyberduck / Filezilla)

Connect to your router IP on port 22 using your admin credentials. Navigate to `/tmp/mnt/routerusb/x3miptv/` and edit or replace `x3miptv.cfg` directly.

### Push from your PC via SCP

```sh
scp /path/to/local/x3miptv.cfg admin@192.168.1.1:/tmp/mnt/routerusb/x3miptv/
```

### SSH one-liner (overwrite cfg from local file)

```sh
ssh admin@192.168.1.1 "cat > /tmp/mnt/routerusb/x3miptv/x3miptv.cfg" < x3miptv.cfg
```

## Logs

Runtime logs are written to `x3miptv.log` in the same directory as the script. The log is automatically trimmed to the last 250 lines to avoid filling up the USB drive.

View the log:

```sh
cat /tmp/mnt/routerusb/x3miptv/x3miptv.log
```

## Notes and Limitations

- The script does not create new IPSET lists — they must already exist in `/jffs/scripts/nat-start`. This is by design to avoid accidentally modifying your routing configuration.
- If a provider is down or returns no data at the time the script runs, that provider is skipped with a warning and existing IPSET entries are preserved.
- The script handles providers whose stream URLs use bare IP addresses (no domain) via the separate `IPADDRESS_IPSET_NAME` IPSET.

## Contributing

Issues and PRs welcome. Please do not include real provider credentials in any contributions.

## License

MIT
