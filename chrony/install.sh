#!/bin/sh

# By Matt Simerson - 2025-05-20
#
# This script installs and configures chrony

set -e 

get_servers_via_dns() {
    # use DNS to customize the NTP servers. For details see
    # https://byo-ntp.github.io/srv-lookup.html
    HOSTNAME=$(hostname)
    DOMAIN=$(echo $HOSTNAME | sed 's/^[^.]*\.//')

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
    echo "Discovering NTP servers via DNS SRV records..."
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
ntsdumpdir /var/db/chrony
dumpdir /var/db/chrony
EOBSD
        )"
        ;;
    *)
        echo "Unsupported OS: $(uname -s)"
        exit 1
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
$NTP_REFCLOCKS
# -------------------------------------------------------

$CHRONY_STATS

$CHRONY_ERRATA

allow all
EO_CHRONY
}

install_chrony_freebsd()
{
    if [ ! -x "/usr/local/sbin/chronyd" ]; then
        pkg install -y chrony
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
            NTP_LOG_DIR="/usr/local/var/ntp"
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
        *)
            echo "Unsupported OS: $(uname -s)"
            exit 1
            ;;
    esac
}

start() {
    case "$(uname -s)" in
        Linux) service chrony start ;;
        FreeBSD) service chronyd start ;;
        *)
            echo "Unsupported OS: $(uname -s)"
            exit 1
            ;;
    esac
}

set_platform_vars
curl -sS https://byo-ntp.github.io/tools/ntpsec/disable.sh | sh
curl -sS https://byo-ntp.github.io/tools/ntp/disable.sh | sh
install
configure
start
