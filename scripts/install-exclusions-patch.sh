#!/bin/sh
# Exclusions-file patch for the trusttunnel OpenWrt package (fork add-on).
#   sh -c "$(wget -O - https://raw.githubusercontent.com/ytimakov/TrustTunnelOpenWrt/master/scripts/install-exclusions-patch.sh)"
#
# Replaces exactly one file of the INSTALLED official package:
# /usr/libexec/trusttunnel/gen-config, the client.toml generator, with
# the fork's version that honors an optional exclusions file. When
# main.exclusions_file (default /etc/trusttunnel/exclusions.toml) exists
# and holds a top-level `exclusions = [...]` array, that array lands in
# the generated client.toml verbatim and the routing-profile list is
# ignored. Everything else — the packages, the LuCI app, the routing —
# stays the stock official distribution.
#
# The stock file is kept once as gen-config.orig for the rollback. A
# `trusttunnel` package upgrade restores the stock generator: rerun this
# script after every such upgrade. The script is idempotent.
set -e

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

RAW_URL="${TT_PATCH_URL:-https://raw.githubusercontent.com/ytimakov/TrustTunnelOpenWrt/master/packages/trusttunnel/root/usr/libexec/trusttunnel/gen-config}"
RAW_URL_GENEXCL="${TT_PATCH_URL_GENEXCL:-https://raw.githubusercontent.com/ytimakov/TrustTunnelOpenWrt/master/scripts/gen-runet-exclusions.sh}"
DEST=/usr/libexec/trusttunnel/gen-config
BACKUP=$DEST.orig
DEST_GENEXCL=/usr/libexec/trusttunnel/gen-exclusions
CONF_DIR=/etc/trusttunnel

fetch() {
    # fetch <url> <dest> — download through whichever client exists.
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1" || die "download failed: $1"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$2" "$1" || die "download failed: $1"
    else
        die "neither wget nor curl found"
    fi
    [ -s "$2" ] || die "the download is empty: $1"
}

[ -f "$DEST" ] || die "the official trusttunnel package is not installed ($DEST not found); run the package installer first"

# The stock file is preserved once; on a rerun the backup already holds
# the pristine generator, so overwriting it with the patched file would
# lose the rollback path.
if [ -f "$BACKUP" ]; then
    say "backup already exists: $BACKUP (kept as is)"
else
    cp -p "$DEST" "$BACKUP"
    say "stock generator preserved: $BACKUP"
fi

TMP=$DEST.new
fetch "$RAW_URL" "$TMP"

sh -n "$TMP" || die "the downloaded generator failed the shell syntax check"

chmod 755 "$TMP"
mv "$TMP" "$DEST"
say "patched generator installed: $DEST"

# The runet-fragment builder ships with the patch: it has no stock
# counterpart, so an update here is a plain overwrite.
fetch "$RAW_URL_GENEXCL" "$DEST_GENEXCL.new"
sh -n "$DEST_GENEXCL.new" || die "the downloaded gen-exclusions failed the shell syntax check"
chmod 755 "$DEST_GENEXCL.new"
mv "$DEST_GENEXCL.new" "$DEST_GENEXCL"
say "exclusions builder installed: $DEST_GENEXCL"

mkdir -p "$CONF_DIR"
say "exclusions directory ready: $CONF_DIR (put your exclusions.toml there)"

cat <<'EOF'

Done. Next steps:
  1. Build the runet fragment on the router itself:
         /usr/libexec/trusttunnel/gen-exclusions --restart
     (writes /etc/trusttunnel/exclusions.toml from the curated domain
     preset + the live RIPE NCC country-resource-list for RU; rerun it
     now and then to refresh the prefixes). Or deliver your own
     exclusions.toml — any TOML file with a top-level array:
         exclusions = [
             "example.com",
             "*.example.com",
             "203.0.113.0/24",
         ]
     (scp the file from the machine where you generate it)
  2. The generated fragment is the DIRECT list: keep the routing
     profile in 'vpn' mode (general) so everything outside the list
     goes through the tunnel:
         uci set trusttunnel.@routing_profile[-1].mode='vpn'
         uci commit trusttunnel && service trusttunnel restart
  3. Check the generated config:
         grep -m2 "exclusions" /var/etc/trusttunnel/client.toml
     The '# exclusions: overridden by' comment means the file won.

Rollback:  cp /usr/libexec/trusttunnel/gen-config.orig \
               /usr/libexec/trusttunnel/gen-config \
            && service trusttunnel restart
Remember: a `trusttunnel` package upgrade restores the stock generator —
rerun this script after such an upgrade.
EOF
