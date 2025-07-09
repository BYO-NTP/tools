#!/bin/sh

# By Matt Simerson - 2025-05-18
#
# This script installs and configures NTPsec
# 
# it is typically run like this:
#   curl -sS https://byo-ntp.github.io/tools/ntpsec/install.sh | sh

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
    echo "Discovering NTP servers for $DOMAIN via DNS SRV records..."
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
            NTP_DRIFTFILE="/opt/local/var/db/ntp.drift"
            NTP_LEAPFILE="/opt/local/var/db/leapfile"
            ;;
    esac
}

install_debian_source() {
    # rebuilding NTPsec is required to get gpsd refclock support
    # because https://gitlab.com/NTPsec/ntpsec/-/issues/668
    cd
    command -v git >/dev/null || apt install -y git
    if [ ! -d ntpsec ]; then
        git clone --depth=1 https://github.com/ntpsec/ntpsec.git
        cd ntpsec
    else
        cd ntpsec && git pull
    fi

    export PYTHONPATH=/usr/local/lib/python3.11/site-packages
    ./buildprep
    ./waf configure --refclock=local,nmea,pps,shm,gpsd \
        --pythondir=/usr/local/lib/python3.11/dist-packages \
        --pythonarchdir=/usr/local/lib/python3.11/dist-packages
    ./waf build
    ./waf install
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
        FreeBSD) service ntpd onestop ;;
        Darwin) sudo port unload ntpsec ;;
        Linux) systemctl stop ntpsec ;;
    esac
}

install_debian_apt() {
    apt install -y ntpsec
    if is_running ntpd; then stop; fi
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
            case "$NTP_REFCLOCKS" in
                *'refclock gpsd'*) install_debian_source ;;
                *)                 install_debian_apt ;;
            esac
            ;;
        FreeBSD)
            pkg install -y ntpsec
            sysrc ntpd_program="/usr/local/sbin/ntpd"
            sysrc ntpd_config="/usr/local/etc/ntp.conf"
            sysrc ntpdate_config="/usr/local/etc/ntp.conf"
            # Grant ntpd access to serial devices by adding to the dialer group
            id ntpd | grep -q dialer || pw groupmod dialer -m ntpd
            ;;
        Darwin)
            port install ntpsec +refclock
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
        Darwin) sudo port load ntpsec ;;
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

    if grep -q '^\[\[inputs.ntpq\]\]' "$TG_ETC_DIR/telegraf.conf"; then
        echo "telegraf is already configured for ntpd."
        return
    fi

    echo -n "Configuring Telegraf for ntp..."
    sed -e '/^#\[\[inputs.ntpq/ s/^#//g' \
        -e '/options.*peers/ s/#//g' \
        -e '/options.*-p/ s/#//g' \
        -e '/^\[\[inputs.chrony/ s/^\[/#[/' \
        -e '/:323/ s/server/#server/' \
        -e '/metrics.*sources/ s/[[:space:]]metrics/ #metrics/' \
        "$TG_ETC_DIR/telegraf.conf" > "$TG_ETC_DIR/telegraf.conf.new"
    mv -- "$TG_ETC_DIR/telegraf.conf.new" "$TG_ETC_DIR/telegraf.conf"
    echo "done"

    if is_running telegraf; then
        echo "Restarting telegraf to pick up changes."
        case "$(uname -s)" in
            FreeBSD|Linux) service telegraf restart ;;
            Darwin)  sudo port reload telegraf ;;
        esac
    else
        echo "telegraf is not running."
    fi
}

case "$(uname -s)" in
    Darwin|FreeBSD|Linux) ;;
    *)  echo "ERR: Unsupported platform $(uname -s). Please file a feature request."
        exit 1
    ;;
esac

set_platform_vars
curl -sS https://byo-ntp.github.io/tools/chrony/disable.sh | sh
curl -sS https://byo-ntp.github.io/tools/ntp/disable.sh | sh
install
configure
start
telegraf