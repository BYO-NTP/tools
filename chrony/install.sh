#!/bin/sh

# By Matt Simerson - 2025-05-20
#
# This script installs and configures chrony
# 
# it is typically run like this:
#   curl -sS https://byo-ntp.github.io/tools/chrony/install.sh | sh

set -e 

HOSTNAME=$(hostname)
DOMAIN=$(echo $HOSTNAME | sed 's/^[^.]*\.//')

get_servers_via_dns() {
    # use DNS to customize the NTP servers. For details see
    # https://byo-ntp.github.io/srv-lookup.html

    if [ -x "/usr/bin/dig" ]; then   # dig from dnsutils
        SRV_RECORDS=$(dig +short _ntp._udp."$DOMAIN" SRV)
    elif [ -x "/usr/bin/drill" ]; then # drill from ldnsutils
        SRV_RECORDS=$(drill -4 -Q SRV _ntp._udp."$DOMAIN")
    else
        SRV_RECORDS=$(drill -4 -Q SRV _ntp._udp."$DOMAIN")
    fi

    if [ -z "$SRV_RECORDS" ]; then return; fi

    echo "$SRV_RECORDS" | while read -r line; do
        set -- $line
        TARGET=$(printf "%s" "$4" | sed 's/\.$//')  # remove trailing dot
        if [ -z "$TARGET" ]; then continue; fi

        # ignore myself
        if [ "$4" = "$HOSTNAME" ]; then continue; fi

        TARGET="server $TARGET"

        # $1 = SRV priority, $2 is SRV weight
        if [ "$1" = "1" ]; then TARGET="$TARGET iburst"; fi
        if [ "$2" = "0" ]; then TARGET="$TARGET prefer"; fi
        if [ "$2" = "100" ]; then TARGET="$TARGET noselect"; fi
        echo "$TARGET"
    done
}

get_ntp_default() {
    cat <<EOF
server 2.pool.ntp.org iburst
server 1.pool.ntp.org iburst
server 3.pool.ntp.org
EOF
}

assure_dnsutil()
{
    if [ -x "/usr/bin/dig" ]; then return; fi
    if [ -x "/usr/bin/drill" ]; then return; fi

    # much smaller than dnsutils
    apt install -y ldnsutils
}

conf_ntp_servers()
{
    assure_dnsutil
    echo "Discovering NTP servers for $DOMAIN via DNS SRV records..."
    NTP_SERVERS=$(get_servers_via_dns)

    if [ -z "$NTP_SERVERS" ]; then
        NTP_SERVERS=$(get_ntp_default)
    fi
}

conf_ntp_stats() {
    if [ "$NTP_STATISTICS" = "false" ]; then return; fi

    CHRONY_STATS=$(cat <<EOF
logdir $NTP_LOG_DIR
log measurements statistics tracking
EOF
)
}

get_errata() {
    # TODO: check if Pi 5 and enable `hwtimestamp *`
    case "$(uname -s)" in
    Linux)
        CHRONY_ERRATA="$(cat <<EOLINUX
keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/chrony.drift
dumpdir /var/lib/chrony
ntsdumpdir /var/lib/chrony

maxupdateskew 100.0
rtcsync
makestep 1 3
leapsectz right/UTC
EOLINUX
        )"
        ;;
    FreeBSD)
        CHRONY_ERRATA="$(cat <<EOBSD
driftfile /var/db/chrony/drift
dumpdir /var/db/chrony
ntsdumpdir /var/db/chrony
EOBSD
        )"
        ;;
    Darwin)
        CHRONY_ERRATA="$(cat <<EOMAC
makestep 30 3
driftfile /opt/local/var/run/chrony/drift
dumpdir /opt/local/var/run/chrony
ntsdumpdir /opt/local/var/run/chrony
rtcsync
EOMAC
        )"
        ;;
    esac
}

configure()
{
    conf_ntp_stats
    conf_ntp_servers
    get_errata

    echo
    tee "$NTP_ETC_DIR/chrony.conf" <<EO_CHRONY
$NTP_SERVERS

# -------------------------------------------------------
minsamples 32
$NTP_REFCLOCKS
# -------------------------------------------------------

$CHRONY_STATS

$CHRONY_ERRATA

allow all
EO_CHRONY
}

is_running()
{
    case "$(uname -s)" in
        FreeBSD|Darwin) pgrep -q "$1" ;;
        Linux) pgrep -c "$1" > /dev/null 2>&1 ;;
    esac
}

stop() {
    case "$(uname -s)" in
        FreeBSD) service chronyd onestop ;;
        Darwin) sudo port unload chrony ;;
        Linux) systemctl stop chrony ;;
    esac
}

install_chrony_freebsd()
{
    if [ ! -x "/usr/local/sbin/chronyd" ]; then
        pkg install -y chrony-lite
    fi

    test -d /var/log/chrony || mkdir /var/log/chrony
    chown chronyd:chronyd /var/log/chrony
    pw groupmod dialer -m chronyd
    sysrc chronyd_flags="-m -P 50"
    sysrc chronyd_enable=YES
}

install_chrony_linux()
{
    if ! dpkg -s chrony | grep -q "ok installed"; then
        apt install -y chrony
        if is_running chrony; then stop; fi
    fi

    chown _chrony:_chrony /var/log/chrony
}

set_platform_vars()
{
    NTP_LOG_DIR=${NTP_LOG_DIR:="/var/log/chrony"}

    case "$(uname -s)" in
        Linux)
            NTP_ETC_DIR="/etc/chrony"
            NTP_LEAPFILE="/usr/share/zoneinfo/leap-seconds.list"
            ;;
        FreeBSD)
            NTP_ETC_DIR="/usr/local/etc"
            NTP_LEAPFILE="/var/db/ntpd.leap-seconds.list"
            ;;
        Darwin)
            NTP_ETC_DIR="/opt/local/etc"
            NTP_LOG_DIR="/opt/local/var/log/chrony"
            ;;
    esac
}

install() {
    curl -sS https://byo-ntp.github.io/tools/gpsd/install.sh | sh

    test -d "$NTP_ETC_DIR" || mkdir -p "$NTP_ETC_DIR"
    test -d "$NTP_LOG_DIR" || mkdir -p "$NTP_LOG_DIR"

    case "$(uname -s)" in
        Linux)   install_chrony_linux ;;
        FreeBSD) install_chrony_freebsd ;;
        Darwin)  sudo port install chrony ;;
    esac
}

start() {
    case "$(uname -s)" in
        Linux) service chrony start ;;
        FreeBSD) service chronyd start ;;
        Darwin) sudo port load chrony ;;
    esac
}

telegraf()
{
    case "$(uname -s)" in
        FreeBSD) TG_ETC_DIR="/usr/local/etc" ;;
        Linux)   TG_ETC_DIR="/etc/telegraf"  ;;
        Darwin)  TG_ETC_DIR="/opt/local/etc/telegraf" ;;
    esac

    if [ ! -f "$TG_ETC_DIR/telegraf.conf" ]; then return; fi

    if grep -q '^\[\[inputs.chrony\]\]' "$TG_ETC_DIR/telegraf.conf"; then
        echo "BYO-NTP: telegraf is already configured for chrony."
        return
    fi

    echo -n "BYO-NTP: configuring telegraf for chrony..."
    sed -e '/^#\[\[inputs.chrony/ s/^#//' \
        -e '/:323/ s/#//g' \
        -e '/metrics.*sources/ s/#//g' \
        -e '/^\[\[inputs.ntpq/ s/^\[/#[/' \
        -e '/-c peers/ s/options/#options/' \
        -e '/-n -p/ s/[[:space:]]options/ #options/' \
        "$TG_ETC_DIR/telegraf.conf" > "$TG_ETC_DIR/telegraf.conf.new"
    mv -- "$TG_ETC_DIR/telegraf.conf.new" "$TG_ETC_DIR/telegraf.conf"

    echo "done"

    if is_running telegraf; then
        echo "BYO-NTP: restarting telegraf to pick up changes..."
        case "$(uname -s)" in
            FreeBSD|Linux) service telegraf restart ;;
            Darwin)  sudo port reload telegraf ;;
        esac
    else
        echo "BYO-NTP: telegraf is not running."
    fi
}

assure_offset() {
    if [ -z "$GNSS_OFFSET_NMEA" ]; then
        echo "ERR: GNSS_OFFSET_NMEA is not set."
        exit 1
    fi
}

case "$(uname -s)" in
    Darwin|FreeBSD|Linux) ;;
    *)
        echo "ERR: Unsupported platform $(uname -s). Please file a feature request."
        exit 1
    ;;
esac

assure_offset
set_platform_vars
curl -sS https://byo-ntp.github.io/tools/ntpsec/disable.sh | sh
curl -sS https://byo-ntp.github.io/tools/ntp/disable.sh | sh
install
configure
start
telegraf