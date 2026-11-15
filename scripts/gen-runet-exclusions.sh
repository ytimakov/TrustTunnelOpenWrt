#!/bin/sh
# gen-exclusions — build the runet exclusions TOML fragment on the router.
#
# The companion of the exclusions-file feature (main.exclusions_file,
# see gen-config): this script writes /etc/trusttunnel/exclusions.toml —
# a plain TOML fragment with one top-level exclusions array — so the
# country-wide bypass list never has to live in UCI or be authored by
# hand.
#
# Sources:
#   - the embedded domain preset: curated RU services on foreign TLDs
#     plus the ru/su/xn--p1ai TLD wildcards. The cyrillic 'рф' entries
#     are left out on purpose — the client core rejects non-ASCII
#     domains and logs a warning for each;
#   - the live RIPE NCC country-resource-list for RU. IPv4 range entries
#     (a.b.c.d-e.f.g.h) are expanded into the aligned CIDR blocks; IPv6
#     entries pass through as-is.
#
# Dependencies: curl (installed by the trusttunnel package) and the
# busybox awk/sed/tr/sort toolset. POSIX sh throughout.

set -eu

OUT=/etc/trusttunnel/exclusions.toml
FROM_JSON=
RESTART=0
RIPE_URL="https://stat.ripe.net/data/country-resource-list/data.json?resource=RU"

usage() {
    cat <<'USAGE'
gen-exclusions [-o OUT] [--from-json FILE] [--restart]

  -o OUT         output path (default /etc/trusttunnel/exclusions.toml)
  --from-json F  use a cached country-resource-list response instead of
                 downloading it (offline runs, tests)
  --restart      restart the trusttunnel service after writing

Builds the runet bypass fragment — the curated domain preset plus the
RIPE NCC country-resource-list for RU — for the exclusions-file feature
of this fork (main.exclusions_file, see gen-config).
USAGE
}

while [ $# -gt 0 ]; do
    case $1 in
        -o)          [ $# -ge 2 ] || { printf 'gen-exclusions: -o needs a path\n' >&2; exit 1; }; OUT=$2; shift 2 ;;
        --from-json) [ $# -ge 2 ] || { printf 'gen-exclusions: --from-json needs a path\n' >&2; exit 1; }; FROM_JSON=$2; shift 2 ;;
        --restart)   RESTART=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) printf 'gen-exclusions: unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done

die() { printf 'gen-exclusions: %s\n' "$*" >&2; exit 1; }

# --- fetch ---------------------------------------------------------------------

if [ -n "$FROM_JSON" ]; then
    [ -r "$FROM_JSON" ] || die "cached response is not readable: $FROM_JSON"
    json=$(cat "$FROM_JSON")
else
    command -v curl >/dev/null 2>&1 || die "curl not found (the trusttunnel package installs it)"
    printf 'gen-exclusions: fetching the RIPE country-resource-list for RU...\n'
    json=$(curl -fsSL --max-time 120 "$RIPE_URL") || die "the RIPE download failed"
fi
[ -n "$json" ] || die "the RIPE response is empty"

# --- parse the arrays ------------------------------------------------------------
# The response is compact single-line JSON. The arrays hold quoted
# strings and no nested brackets, so a greedy prefix up to the key plus
# a capture up to the first ] isolate each array.

v4_raw=$(printf '%s\n' "$json" | sed -n 's/.*"ipv4"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p')
v6_raw=$(printf '%s\n' "$json" | sed -n 's/.*"ipv6"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p')
[ -n "$v4_raw" ] || die "no ipv4 array in the RIPE response"

# --- ipv4: expand ranges into aligned CIDR blocks --------------------------------

v4_list=$(printf '%s\n' "$v4_raw" | tr ',' '\n' | tr -d '"' | awk '
    function ip2num(ip, a) {
        if (split(ip, a, ".") != 4) return -1
        return a[1] * 16777216 + a[2] * 65536 + a[3] * 256 + a[4]
    }
    function log2(n, l) { l = 0; while (n > 1) { n = int(n / 2); l++; } return l }
    {
        gsub(/[ \t]/, "")
        if ($0 == "") next
        if (split($0, p, "-") == 2) {
            s = ip2num(p[1]); e = ip2num(p[2])
            if (s < 0 || e < 0 || s > e) {
                printf "gen-exclusions: skipped bad range: %s\n", $0 > "/dev/stderr"
                next
            }
            while (s <= e) {
                align = 1
                while (s % (align * 2) == 0 && align < 16777216) align *= 2
                size = e - s + 1
                while (align > size) align = int(align / 2)
                printf "%d.%d.%d.%d/%d\n", int(s / 16777216) % 256, int(s / 65536) % 256, int(s / 256) % 256, s % 256, 32 - log2(align)
                s += align
            }
            next
        }
        if ($0 ~ /^[0-9][0-9.]*\/[0-9][0-9]*$/ || $0 ~ /^[0-9][0-9.]*$/) { print; next }
        printf "gen-exclusions: skipped unrecognized ipv4 entry: %s\n", $0 > "/dev/stderr"
    }
' | sort -u)

# --- ipv6: pass through, ranges are not supported by the core --------------------

v6_list=$(printf '%s\n' "$v6_raw" | tr ',' '\n' | tr -d '"' | awk '
    {
        gsub(/[ \t]/, "")
        if ($0 == "") next
        if ($0 ~ /-/) {
            printf "gen-exclusions: skipped ipv6 range (unsupported): %s\n", $0 > "/dev/stderr"
            next
        }
        print
    }
' | sort -u)

# --- the embedded curated domain preset ------------------------------------------

domains=$(cat <<'PRESET'
v-vpn.ikontyres.com
*.ikontyres.com
login.microsoftonline.com
*.microsoftonline.com
login.windows.net
login.live.com
*.msftauth.net
*.windows.net
teams.microsoft.com
*.teams.microsoft.com
*.teams.cdn.office.net
*.office.com
*.office.net
*.office365.com
*.lync.com
graph.microsoft.com
*.msocdn.com
*.svc.ms
trouter.microsoft.com
*.trouter.microsoft.com
ru
*.ru
su
*.su
xn--p1ai
*.xn--p1ai
yandex.ru
*.yandex.ru
yandex.net
*.yandex.net
yandex.com
*.yandex.com
yandex.cloud
*.yandex.cloud
yandex-team.ru
*.yandex-team.ru
yastatic.net
*.yastatic.net
ya.ru
*.ya.ru
yandex.st
*.yandex.st
kinopoisk.ru
*.kinopoisk.ru
yandexdisk.ru
*.yandexdisk.ru
vk.com
*.vk.com
vk.me
*.vk.me
userapi.com
*.userapi.com
vkontakte.ru
*.vkontakte.ru
mail.ru
*.mail.ru
ok.ru
*.ok.ru
list.ru
*.list.ru
bk.ru
*.bk.ru
inbox.ru
*.inbox.ru
corp.mail.ru
*.corp.mail.ru
odnoklassniki.ru
*.odnoklassniki.ru
my.com
*.my.com
max.ru
*.max.ru
web.max.ru
*.web.max.ru
platform-api.max.ru
*.platform-api.max.ru
platform-api2.max.ru
*.platform-api2.max.ru
dev.max.ru
*.dev.max.ru
oneme.ru
*.oneme.ru
api-gost.oneme.ru
*.api-gost.oneme.ru
mytracker.ru
*.mytracker.ru
mytracker.com
*.mytracker.com
vk-analytics.ru
*.vk-analytics.ru
tracker-api.vk-analytics.ru
*.tracker-api.vk-analytics.ru
avito.ru
*.avito.ru
ozon.ru
*.ozon.ru
wildberries.ru
*.wildberries.ru
lamoda.ru
*.lamoda.ru
cian.ru
*.cian.ru
auto.ru
*.auto.ru
drom.ru
*.drom.ru
rutube.ru
*.rutube.ru
rbc.ru
*.rbc.ru
lenta.ru
*.lenta.ru
rt.com
*.rt.com
ria.ru
*.ria.ru
tass.ru
*.tass.ru
1tv.ru
*.1tv.ru
vgtrk.ru
*.vgtrk.ru
kp.ru
*.kp.ru
habr.ru
*.habr.ru
habr.com
*.habr.com
gosuslugi.ru
*.gosuslugi.ru
pfr.gov.ru
*.pfr.gov.ru
nalog.gov.ru
*.nalog.gov.ru
customsonline.ru
*.customsonline.ru
gost.ru
*.gost.ru
mos.ru
*.mos.ru
mosreg.ru
*.mosreg.ru
rosreestr.gov.ru
*.rosreestr.gov.ru
gu.spb.ru
*.gu.spb.ru
hh.ru
*.hh.ru
hhcdn.ru
*.hhcdn.ru
tbank.ru
*.tbank.ru
tinkoff.ru
*.tinkoff.ru
tinkoffinsurance.ru
*.tinkoffinsurance.ru
sberbank.ru
*.sberbank.ru
sber.ru
*.sber.ru
sberdevices.ru
*.sberdevices.ru
vtb.ru
*.vtb.ru
vtb24.ru
*.vtb24.ru
alfabank.ru
*.alfabank.ru
raiffeisen.ru
*.raiffeisen.ru
psbank.ru
*.psbank.ru
gazprombank.ru
*.gazprombank.ru
mts.ru
*.mts.ru
beeline.ru
*.beeline.ru
megafon.ru
*.megafon.ru
tele2.ru
*.tele2.ru
rostelecom.ru
*.rostelecom.ru
PRESET
)

# --- assemble ---------------------------------------------------------------------

[ -n "$v4_list" ] || die "the ipv4 list came out empty — the RIPE response format may have changed"

workdir=$(mktemp -d)
entries=$workdir/entries
{
    printf '%s\n' "$domains"
    printf '%s\n' "$v4_list"
    printf '%s\n' "$v6_list"
} | awk 'NF { printf "    \"%s\",\n", $0 }' | sed -e '$s/,$//' > "$entries"

total=$(grep -c . "$entries")
[ "$total" -gt 0 ] || die "no rules produced"

{
    printf '# Generated by gen-exclusions (ytimakov/TrustTunnelOpenWrt fork) on %s\n' "$(date -u '+%Y-%m-%d %H:%M UTC')"
    printf '# Runet bypass: curated domain preset + RIPE NCC country-resource-list (RU).\n'
    printf '# Consumed by gen-config via main.exclusions_file. Spliced verbatim into client.toml.\n'
    printf 'exclusions = [\n'
    cat "$entries"
    printf ']\n'
} > "$workdir/fragment"

mkdir -p "$(dirname "$OUT")"
cat "$workdir/fragment" > "$OUT"
rm -rf "$workdir"

domains_n=$(printf '%s\n' "$domains" | grep -c .)
v4_n=$(printf '%s\n' "$v4_list" | grep -c .)
v6_n=$(printf '%s\n' "$v6_list" | grep -c .)
printf 'gen-exclusions: written %s (%d rules: %d domains, %d ipv4, %d ipv6)\n' "$OUT" "$total" "$domains_n" "$v4_n" "$v6_n"

if [ "$RESTART" = 1 ]; then
    service trusttunnel restart
fi
