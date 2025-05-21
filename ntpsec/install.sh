#!/bin/sh

# By Matt Simerson - 2025-05-18
#
# This script generates a configuration file for NTPsec

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
            echo "server $TARGET iburst prefer"
        else
            echo "server $TARGET"
        fi
    done
}

get_ntp_default() {
    cat <<EOF
server 2.pool.ntp.org iburst prefer
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

    test -d $NTP_LOGDIR || mkdir $NTP_LOGDIR

    CONF_NTP_STATS=$(cat <<EOF

statsdir $NTP_LOGDIR
statistics loopstats peerstats clockstats
filegen loopstats file loopstats type pid enable
filegen peerstats file peerstats type pid enable
filegen clockstats file clockstats type pid enable
EOF
)
}

ntpsec_configure()
{
    conf_ntp_stats
    conf_ntp_servers

    test -d $NTP_CONFIG_DIR || mkdir -p $NTP_CONFIG_DIR
    NTP_CONFIG_FILE="> $NTP_CONFIG_DIR/ntp.conf"

    echo
    tee $NTP_CONFIG_FILE <<EOSEC

driftfile $NTP_DRIFTFILE
leapfile $NTP_LEAPFILE
$CONF_NTP_STATS

tos maxclock 6 minclock 4 minsane 3 mindist 0.02

$NTP_SERVERS

# -------------------------------------------------------
enable calibrate
$NTP_REFCLOCKS
# -------------------------------------------------------

restrict default kod nomodify noquery limited
restrict 127.0.0.1
restrict ::1
EOSEC

}

NTP_LOGDIR=${NTP_LOGDIR:="/var/log/ntp"}

case "$(uname -s)" in
    Linux)
        NTP_CONFIG_DIR="/etc/ntpsec"
        NTP_DRIFTFILE="/var/lib/ntpsec/ntp.drift"
        NTP_LEAPFILE="/usr/share/zoneinfo/leap-seconds.list"
        NTP_LOGDIR="/var/log/ntpsec"
        apt install -y ntpsec
        systemctl stop ntpsec
        ntpsec_configure
        chown ntpsec:ntpsec /var/log/ntpsec
        sed -i -e '/^IGNORE_DHCP/ s/""/"yes"/' /etc/default/ntpsec
        systemctl start ntpsec
        ;;
    FreeBSD)
        NTP_CONFIG_DIR="/usr/local/etc"
        NTP_DRIFTFILE="/var/db/ntpd.drift"
        NTP_LEAPFILE="/etc/ntp/leap-seconds"
        pkg install -y ntpsec
        # for a systems (like Pis) that forget the time
        sysrc ntpdate_enable=YES
        sysrc ntpdate_config="/usr/local/etc/ntp.conf"
        echo -n "setting the system clock via NTP..."
        service ntpdate start
        echo "done"

        ntpsec_configure
        sysrc ntpd_enable=YES
        sysrc ntpd_program="/usr/local/sbin/ntpd"
        sysrc ntpd_config="/usr/local/etc/ntp.conf"
        sysrc ntpd_flags="-g -N"
        sysrc ntpd_user="root"
        chown ntpd:ntpd $NTP_LOGDIR
        ;;
    Darwin)
        NTP_CONFIG_DIR="/opt/local/etc"
        NTP_LOGDIR="/usr/local/var/ntp"
        ntpsec_configure
        ;;
    *)
        echo "Unsupported OS: $(uname -s)"
        exit 1
        ;;
esac
