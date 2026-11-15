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
DEST=/usr/libexec/trusttunnel/gen-config
BACKUP=$DEST.orig
CONF_DIR=/etc/trusttunnel

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
if command -v wget >/dev/null 2>&1; then
    wget -q -O "$TMP" "$RAW_URL" || die "download failed: $RAW_URL"
elif command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$TMP" "$RAW_URL" || die "download failed: $RAW_URL"
else
    die "neither wget nor curl found"
fi
[ -s "$TMP" ] || die "the download is empty: $RAW_URL"

sh -n "$TMP" || die "the downloaded generator failed the shell syntax check"

chmod 755 "$TMP"
mv "$TMP" "$DEST"
say "patched generator installed: $DEST"

mkdir -p "$CONF_DIR"
say "exclusions directory ready: $CONF_DIR (put your exclusions.toml there)"

cat <<'EOF'

Done. Next steps:
  1. Put the exclusions fragment at /etc/trusttunnel/exclusions.toml —
     a plain TOML file with a top-level array:
         exclusions = [
             "example.com",
             "*.example.com",
             "203.0.113.0/24",
         ]
     (scp the file from the machine where you generate it)
  2. Restart the service:  service trusttunnel restart
  3. Check the generated config:
         grep -m2 "exclusions" /var/etc/trusttunnel/client.toml
     The '# exclusions: overridden by' comment means the file won.
  4. For the whole-runet bypass set the routing profile mode to 'vpn'
     (general) so the file list is the direct list:
         uci set trusttunnel.@routing_profile[-1].mode='vpn'
         uci commit trusttunnel && service trusttunnel restart

Rollback:  cp /usr/libexec/trusttunnel/gen-config.orig \
               /usr/libexec/trusttunnel/gen-config \
            && service trusttunnel restart
Remember: a `trusttunnel` package upgrade restores the stock generator —
rerun this script after such an upgrade.
EOF
