#!/bin/sh

# By Matt Simerson - 2025-05-20
#
# This script generates a configuration file for chrony
set -e 

get_servers_via_dns() {
    HOSTNAME=$(hostname)
    DOMAIN=$(echo $HOSTNAME | sed 's/^[^.]*\.//')

    if [ -x "/usr/bin/dig" ]; then   # dig from dnsutils
        SRV_RECORDS=$(dig +short _ntp._udp."$DOMAIN" SRV)
    elif [ -x "/usr/bin/drill" ]; then # drill from ldnsutils
        SRV_RECORDS=$(drill -4 -Q SRV _ntp._udp."$DOMAIN")
    else
        apt install -y ldnsutils &> /dev/null  # much smaller than dnsutils
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
server 2.us.pool.ntp.org iburst
server 1.us.pool.ntp.org iburst
server 3.us.pool.ntp.org
EOF
}

conf_ntp_servers()
{
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
    
}

ntpd_configure()
{
    conf_ntp_stats
    conf_ntp_servers

    test -d $NTP_ETC_DIR || mkdir -p $NTP_ETC_DIR
    NTP_CONFIG_FILE="> $NTP_ETC_DIR/chrony.conf"

    echo
    tee $NTP_CONFIG_FILE <<EO_CHRONY
$NTP_SERVERS

# -------------------------------------------------------
$NTP_REFCLOCKS
# -------------------------------------------------------

$CHRONY_STATS

$CHRONY_ERRATA
EO_CHRONY

}

NTP_LOGDIR=${NTP_LOGDIR:="/var/log/chrony"}

case "$(uname -s)" in
    Linux)
        NTP_ETC_DIR="/etc/chrony"
        NTP_LEAPFILE="/usr/share/zoneinfo/leap-seconds.list"
        test -d /etc/chrony || mkdir /etc/chrony
        CHRONY_ERRATA=(cat <<EOF
keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/chrony.drift
ntsdumpdir /var/lib/chrony

maxupdateskew 100.0
rtcsync
makestep 1 3
leapsectz right/UTC
EOF
        )
        ntpd_configure
        apt install -y chrony
        chown _chrony:_chrony /var/log/chrony
        ;;
    FreeBSD)
        NTP_ETC_DIR="/etc"
        NTP_LEAPFILE="/var/db/ntpd.leap-seconds.list"

        pkg install -y chrony
        pw groupmod dialer -m chronyd
        sysrc chronyd_flags="-m -P 50"
        sysrc chronyd_enable=YES
        CHRONY_ERRATA=(cat <<EOF
driftfile /var/db/chrony/drift
ntsdumpdir /var/db/chrony
dumpdir /var/db/chrony

allow all
EOF
        )
        ntpd_configure
        ;;
    Darwin)
        NTP_ETC_DIR="/opt/local/etc"
        NTP_LOGDIR="/usr/local/var/ntp"
        ntpd_configure
        ;;
    *)
        echo "Unsupported OS: $(uname -s)"
        exit 1
        ;;
esac
