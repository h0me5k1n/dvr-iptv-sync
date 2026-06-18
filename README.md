# dvr-iptv-sync

Automatically manages a [domain_vpn_routing](https://github.com/Ranger802004/asusmerlin/tree/main/domain_vpn_routing) policy on Asuswrt-Merlin routers based on the domains found in your IPTV provider playlists.

## The Problem

If you run a VPN on your Asus router via Asuswrt-Merlin and want IPTV streams routed through it (or excluded from it), you need to tell domain_vpn_routing which domains belong to your IPTV providers. These can change when providers update their infrastructure, and managing them manually is tedious.

This script automates that: it fetches your M3U playlists, extracts the streaming domains, compares them against your existing domain_vpn_routing policy, and adds anything new.

## Features

- Supports **M3U** and **Xtream Codes (XC)** provider types
- Supports **HTTP and HTTPS** provider URLs
- **Dry run by default** — no changes made unless you explicitly pass `UPDATE`
- Accumulates and deduplicates domains across multiple providers before updating
- Handles **dynamic DNS providers** (uses full domain rather than TLD)
- Preflight checks for dependencies before doing any work
- Lock file prevents concurrent runs
- Log file with automatic trimming

## Requirements

- Asus router running [Asuswrt-Merlin](https://www.asuswrt-merlin.net/) firmware
- [domain_vpn_routing](https://github.com/Ranger802004/asusmerlin/tree/main/domain_vpn_routing) installed via amtm and a policy created (see below)
- Entware `curl` with SSL support (see below)

### Installing domain_vpn_routing

SSH into your router and run:

```sh
amtm
```

Navigate to the addon installer and select **domain_vpn_routing** to install it. Follow the on-screen prompts.

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

### 1. Create a domain_vpn_routing policy for IPTV

Before running this script you need a policy to write into. Create one interactively:

```sh
/jffs/scripts/domain_vpn_routing.sh createpolicy
```

When prompted:
- **Policy name**: `IPTV` (or whatever you set as `POLICY_NAME` in `dvr-iptv-sync.sh`)
- **Interface**: the VPN or WAN interface IPTV traffic should use
- **Verbose logging**: your preference
- **Private IP addresses**: disable (IPTV streams use public IPs)
- **Add CNAMEs**: enable if you have `dig` installed via Entware, otherwise disable

### 2. Copy the script to your router

The recommended location is your router USB drive, which persists across reboots.

Via SCP from your PC (the `-O` flag is required on modern OpenSSH — dropbear on the router doesn't support the SFTP-based scp used by default since OpenSSH 9.0):

```sh
scp -O dvr-iptv-sync.sh admin@192.168.1.1:/tmp/mnt/routerusb/dvr-iptv-sync/
scp -O dvr-iptv-sync.cfg.example admin@192.168.1.1:/tmp/mnt/routerusb/dvr-iptv-sync/
```

### 3. Make the script executable

```sh
chmod +x /tmp/mnt/routerusb/dvr-iptv-sync/dvr-iptv-sync.sh
```

### 4. Create your config file

```sh
cp /tmp/mnt/routerusb/dvr-iptv-sync/dvr-iptv-sync.cfg.example \
   /tmp/mnt/routerusb/dvr-iptv-sync/dvr-iptv-sync.cfg
```

Edit `dvr-iptv-sync.cfg` with your provider details (see [Configuration](#configuration) below).

### 5. Set the policy name

If you named your policy something other than `IPTV`, update this line near the top of `dvr-iptv-sync.sh`:

```sh
POLICY_NAME=IPTV
```

### 6. Playlist download routing (auto-detected)

The script automatically reads which interface your `POLICY_NAME` policy is assigned to in domain_vpn_routing's config and binds `curl` to that tunnel when fetching playlists. This means if your provider blocks direct downloads, the fetch will go via the same VPN the streams are routed through.

You will see this reported during preflight:

```
  [OK] Auto-detected download interface: tun11
```

If the policy is assigned to WAN the preflight will say so and no binding is applied.

To override the auto-detected interface, set `CURL_INTERFACE` manually near the top of `dvr-iptv-sync.sh`:

```sh
CURL_INTERFACE=tun11   # OpenVPN client 1
CURL_INTERFACE=wg11    # WireGuard client 1
CURL_INTERFACE=""      # Force default routing regardless of policy
```

## Configuration

Your config file (`dvr-iptv-sync.cfg`) uses a simple pipe-separated format. Lines beginning with `#` are comments. Blank lines are ignored.

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

Add as many lines as you need. All domains are accumulated and deduplicated across all providers before updating the policy.

```
M3U|https://iptv-org.github.io/iptv/countries/gb.m3u
XC|http://provider1.com:8080|user1|pass1
XC|https://provider2.com:8443|user2|pass2
```

## Usage

### Dry run (check only — no changes made)

```sh
sh /tmp/mnt/routerusb/dvr-iptv-sync/dvr-iptv-sync.sh
```

Shows what would be added to your policy without making any changes. Always run this first to verify the output looks correct.

### Apply updates

```sh
sh /tmp/mnt/routerusb/dvr-iptv-sync/dvr-iptv-sync.sh UPDATE
```

Adds any new domains found in your playlists to the domain_vpn_routing policy and triggers a policy query so routes are created immediately.

## Scheduling with cron

IPTV provider domains don't change frequently, but automating a periodic check means you won't be caught out.

Use the Merlin `cru` command to register the job. To survive reboots, add it to `/jffs/scripts/services-start` (create the file if it doesn't exist):

```sh
#!/bin/sh
cru a dvr-iptv-sync "0 3,12,19 * * * sh /tmp/mnt/routerusb/dvr-iptv-sync/dvr-iptv-sync.sh UPDATE"
```

Make the file executable:

```sh
chmod +x /jffs/scripts/services-start
```

To activate it immediately without waiting for a reboot, paste the full `cru a dvr-iptv-sync "..."` command above directly into your SSH session. To verify it was registered:

```sh
cru l
```

To remove it:

```sh
cru d dvr-iptv-sync
```

Adjust the schedule to taste — `0 3,12,19 * * *` runs at 03:00, 12:00 and 19:00 daily; `0 3 * * *` runs once at 03:00.

domain_vpn_routing also runs its own cron job (every 15 minutes by default) to re-query all policies, so newly added domains will be picked up even without this script re-running.

## Editing your config without SSH

Your `dvr-iptv-sync.cfg` lives on the router USB drive, which is accessible in several ways without needing to SSH in:

### Samba (Windows network share) — easiest

Enable the USB share in the Merlin web UI under **USB Application → Network Place (Samba) Share**. Your cfg file will then be accessible from Windows Explorer as a network drive, or from any SMB client on your LAN. Edit it in any text editor and save directly.

### SFTP (WinSCP / Cyberduck / Filezilla)

Connect to your router IP on port 22 using your admin credentials. Navigate to `/tmp/mnt/routerusb/dvr-iptv-sync/` and edit or replace `dvr-iptv-sync.cfg` directly.

### Push from your PC via SCP

```sh
scp -O /path/to/local/dvr-iptv-sync.cfg admin@192.168.1.1:/tmp/mnt/routerusb/dvr-iptv-sync/
```

## Logs

Runtime logs are written to `dvr-iptv-sync.log` in the same directory as the script. The log is automatically trimmed to the last 250 lines to avoid filling up the USB drive.

```sh
cat /tmp/mnt/routerusb/dvr-iptv-sync/dvr-iptv-sync.log
```

## Notes and Limitations

- The script only **adds** domains to the policy — it never removes them. If a provider removes a domain from their playlist, you can remove it manually via `domain_vpn_routing.sh deletedomain <domain>`.
- The script does not create the domain_vpn_routing policy — it must already exist. This is by design to avoid accidentally modifying your routing configuration.
- If a provider is down or returns no data at the time the script runs, that provider is skipped with a warning and the existing policy is left unchanged.
- Bare IP addresses in playlist stream URLs are skipped with a warning — domain_vpn_routing is domain-based only.

## Contributing

Issues and PRs welcome. Please do not include real provider credentials in any contributions.

## License

MIT
