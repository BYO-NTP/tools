#!/bin/sh

# By Matt Simerson - 2025-05-20
#
# This script installs and configures chrony

set -e 

get_servers_via_dns() {
    # use DNS to customize the NTP servers
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

        # if the SRV priority is 1
        if [ "$1" = "1" ]; then
            echo "server $TARGET iburst"
        else
            echo "server $TARGET"
        fi
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
    NTP_SERVERS=$(get_servers_via_dns)

    if [ -z "$NTP_SERVERS" ]; then
        NTP_SERVERS=$(get_ntp_default)
    fi
}

conf_ntp_stats() {
    if [ "$NTP_STATISTICS" = "false" ]; then return; fi

    test -d "$NTP_LOGDIR" || mkdir "$NTP_LOGDIR"

    CHRONY_STATS=$(cat <<EOF
logdir $NTP_LOGDIR
log measurements statistics tracking
EOF
)
}

get_errata() {
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

chrony_configure()
{
    conf_ntp_stats
    conf_ntp_servers
    get_errata

    test -d $NTP_ETC_DIR || mkdir -p $NTP_ETC_DIR

    echo
    tee > "$NTP_ETC_DIR/chrony.conf" <<EO_CHRONY
$NTP_SERVERS

# -------------------------------------------------------
$NTP_REFCLOCKS
# -------------------------------------------------------

$CHRONY_STATS

$CHRONY_ERRATA

allow all
EO_CHRONY
}

chrony_install_freebsd()
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

chrony_install_linux()
{
    if ! dpkg -s chrony | grep -q "ok installed"; then
        apt install -y chrony
    fi

    chown _chrony:_chrony /var/log/chrony
}

NTP_LOGDIR=${NTP_LOGDIR:="/var/log/chrony"}

case "$(uname -s)" in
    Linux)
        NTP_ETC_DIR="/etc/chrony"
        NTP_LEAPFILE="/usr/share/zoneinfo/leap-seconds.list"
        test -d /etc/chrony || mkdir /etc/chrony
        chrony_install_linux
        chrony_configure
        service chrony restart
        ;;
    FreeBSD)
        NTP_ETC_DIR="/usr/local/etc"
        NTP_LEAPFILE="/var/db/ntpd.leap-seconds.list"
        chrony_install_freebsd
        chrony_configure
        service chronyd start
        ;;
    Darwin)
        NTP_ETC_DIR="/opt/local/etc"
        NTP_LOGDIR="/usr/local/var/ntp"
        chrony_configure
        ;;
    *)
        echo "Unsupported OS: $(uname -s)"
        exit 1
        ;;
esac
