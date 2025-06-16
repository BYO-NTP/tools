#!/bin/sh

# By Matt Simerson - 2025-05-18
#
# This script installs and configures NTPsec

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
    echo "Discovering NTP servers via DNS SRV records..."
    NTP_SERVERS=$(get_servers_via_dns)

    if [ -z "$NTP_SERVERS" ]; then
        NTP_SERVERS=$(get_ntp_default)
    fi
}

conf_ntp_stats() {
    if [ "$NTP_STATISTICS" = "false" ]; then return; fi

    CONF_NTP_STATS=$(cat <<EOF

statsdir $NTP_LOG_DIR
statistics loopstats peerstats clockstats
filegen loopstats file loopstats type pid enable
filegen peerstats file peerstats type pid enable
filegen clockstats file clockstats type pid enable
EOF
)
}

configure()
{
    conf_ntp_stats
    conf_ntp_servers

    NTP_CONFIG_FILE="$NTP_ETC_DIR/ntp.conf"

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

set_platform_vars()
{
    NTP_LOG_DIR=${NTP_LOG_DIR:="/var/log/ntp"}

    case "$(uname -s)" in
        Linux)
            NTP_DRIFTFILE="/var/lib/ntpsec/ntp.drift"
            NTP_ETC_DIR="/etc/ntpsec"
            NTP_LEAPFILE="/usr/share/zoneinfo/leap-seconds.list"
            NTP_LOG_DIR="/var/log/ntpsec"
            ;;
        FreeBSD)
            NTP_DRIFTFILE="/var/db/ntpd.drift"
            NTP_ETC_DIR="/usr/local/etc"
            NTP_LEAPFILE="/etc/ntp/leap-seconds"
            ;;
        Darwin)
            NTP_ETC_DIR="/opt/local/etc"
            NTP_LOG_DIR="/usr/local/var/ntp"
            ;;
    esac
}

install() {
    case "$NTP_REFCLOCKS" in
        *'refclock gpsd'*)
            curl -sS https://byo-ntp.github.io/tools/gpsd/install.sh | sh ;;
        *)  curl -sS https://byo-ntp.github.io/tools/gpsd/disable.sh | sh ;;
    esac

    test -d $NTP_ETC_DIR || mkdir -p $NTP_ETC_DIR
    test -d $NTP_LOG_DIR || mkdir -p $NTP_LOG_DIR

    case "$(uname -s)" in
        Linux)
            apt install -y ntpsec
            systemctl stop ntpsec
            ;;
        FreeBSD)
            pkg install -y ntpsec
            sysrc ntpd_program="/usr/local/sbin/ntpd"
            sysrc ntpd_config="/usr/local/etc/ntp.conf"
            sysrc ntpdate_config="/usr/local/etc/ntp.conf"
            ;;
        Darwin)
            port install ntpsec
            ;;
        *)
            echo "Unsupported OS: $(uname -s)"
            exit 1
            ;;
    esac
}

start() {
    case "$(uname -s)" in
        Linux)
            chown ntpsec:ntpsec /var/log/ntpsec
            sed -i -e '/^IGNORE_DHCP/ s/""/"yes"/' /etc/default/ntpsec
            systemctl start ntpsec
            ;;
        FreeBSD)
            sysrc ntpd_enable=YES
            sysrc ntpd_flags="-g -N"
            sysrc ntpd_user="root"
            chown ntpd:ntpd $NTP_LOG_DIR

            # for a systems (like Pis) that forget the time
            sysrc ntpdate_enable=YES
            echo -n "setting the system clock via NTP..."
            service ntpdate start
            echo "done"

            service ntpd start
            ;;
        Darwin)
            port load ntpsec
            ;;
        *)
            echo "Unsupported OS: $(uname -s)"
            exit 1
            ;;
    esac
}

set_platform_vars
install
configure
start
