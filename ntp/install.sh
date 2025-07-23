#!/bin/sh

# By Matt Simerson - 2025-05-19
#
# This script installs (if needed) and configures ntpd
# it is typically run like this:
#
#  curl -sS https://byo-ntp.github.io/tools/ntp/install.sh | sh

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

restrict default limited kod nomodify notrap noquery nopeer
restrict source  limited kod nomodify notrap noquery

restrict 127.0.0.1
restrict ::1
EOSEC

}

add_user_linux()
{
    # Create ntpd user and group
    if ! getent group ntpd >/dev/null; then
        groupadd -g 123 ntpd
    fi

    test -d /var/lib/ntp || mkdir /var/lib/ntp

    if ! getent passwd ntpd >/dev/null; then
        useradd --system -u 123 -g 123 -d /var/lib/ntp -s /sbin/nologin ntpd
        chown ntpd:ntpd /var/lib/ntp
    fi

    usermod -aG dialout ntpd
}

add_systemd_service()
{
    # Create systemd service file
    cat > /etc/systemd/system/ntpd.service <<EOSYS
[Unit]
Description=Network Time Protocol daemon
After=network.target
Documentation=man:ntpd(8)
# After=dev-gps0.device
# Requires=dev-gps0.device

[Service]
ExecStart=/usr/local/sbin/ntpd -c /usr/local/etc/ntp.conf -g -N -n
Restart=on-failure
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
CapabilityBoundingSet=CAP_SYS_TIME CAP_NET_BIND_SERVICE CAP_SYS_NICE CAP_SYS_RESOURCE
AmbientCapabilities=CAP_SYS_TIME CAP_NET_BIND_SERVICE CAP_SYS_NICE CAP_SYS_RESOURCE

[Install]
WantedBy=multi-user.target
EOSYS

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable ntpd
}

build_from_source()
{
    if [ -x "/usr/local/sbin/ntpd" ]; then return; fi
    apt install -y libssl-dev pps-tools
    cd ~
    wget -c -N https://downloads.nwtime.org/ntp/4.2.8/ntp-4.2.8p18.tar.gz
    tar -xzf ntp-4.2.8p18.tar.gz
    cd ntp-4.2.8p18
    ./configure
    make && make install
}

set_platform_vars()
{
    NTP_ETC_DIR=${NTP_ETC_DIR:="/usr/local/etc"}
    NTP_LOG_DIR=${NTP_LOG_DIR:="/var/log/ntp"}

    case "$(uname -s)" in
        Linux)
            NTP_DRIFTFILE="/var/lib/ntp/ntp.drift"
            NTP_LEAPFILE="/usr/share/zoneinfo/leap-seconds.list"
            ;;
        FreeBSD)
            NTP_ETC_DIR="/etc"
            NTP_DRIFTFILE="/var/db/ntpd.drift"
            NTP_LEAPFILE="/var/db/ntpd.leap-seconds.list"
            ;;
        Darwin)
            NTP_ETC_DIR="/opt/local/etc"
            NTP_LOG_DIR="/usr/local/var/ntp"
            ;;
    esac
}

install() {
    case "$NTP_REFCLOCKS" in
        *127.127.46.*|*127.127.28.*)
            curl -sS https://byo-ntp.github.io/tools/gpsd/install.sh | sh ;;
        *)  curl -sS https://byo-ntp.github.io/tools/gpsd/disable.sh | sh ;;
    esac

    test -d $NTP_ETC_DIR || mkdir -p $NTP_ETC_DIR
    test -d $NTP_LOG_DIR || mkdir $NTP_LOG_DIR

    case "$(uname -s)" in
        Linux)
            add_user_linux
            build_from_source
            ;;
        FreeBSD)
            # ntpd is installed by default, just enable it
            sysrc ntpd_program="/usr/sbin/ntpd"
            sysrc ntpd_config="$NTP_ETC_DIR/ntp.conf"
            sysrc ntpdate_config="$NTP_ETC_DIR/ntp.conf"
            # Grant ntpd access to serial devices by adding to the dialer group
            id ntpd | grep -q dialer || pw groupmod dialer -m ntpd
            ;;
        Darwin)
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
            add_systemd_service
            service ntpd start
            ;;
        FreeBSD)
            # for a systems (like Pis) that forget the time
            sysrc ntpdate_enable=YES
            sysrc ntpd_enable=YES
            sysrc ntpd_flags="-g -N"
            sysrc ntpd_user="root"
            chown ntpd:ntpd $NTP_LOG_DIR
            service ntpd start
            ;;
        Darwin)
            ;;
        *)
            echo "Unsupported OS: $(uname -s)"
            exit 1
            ;;
    esac
}

is_running()
{
    case "$(uname -s)" in
        FreeBSD|Darwin) pgrep -q "$1" ;;
        Linux) pgrep -c "$1" > /dev/null 2>&1 ;;
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

    echo -n "Configuring telegraf for ntp..."
    sed -e '/^#\[\[inputs.ntpq/ s/^#//g' \
        -e '/options.*-c peers/ s/#//g' \
        -e '/options.*-p/ s/#//g' \
        -e '/^\[\[inputs.chrony/ s/^\[/#[/' \
        -e '/:323/ s/server/#server/' \
        -e '/metrics.*sources/ s/[[:space:]]metrics/ #metrics/' \
        "$TG_ETC_DIR/telegraf.conf" > "$TG_ETC_DIR/telegraf.conf.new"
    mv -- "$TG_ETC_DIR/telegraf.conf.new" "$TG_ETC_DIR/telegraf.conf"
    echo "done"

    if is_running telegraf; then
        echo "Restarting telegraf to pick up changes..."
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
    *)
        echo "ERR: Unsupported platform $(uname -s). Please file a feature request."
        exit 1
    ;;
esac

set_platform_vars
curl -sS https://byo-ntp.github.io/tools/chrony/disable.sh | sh
curl -sS https://byo-ntp.github.io/tools/ntpsec/disable.sh | sh
install
configure
start
telegraf