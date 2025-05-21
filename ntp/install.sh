#!/bin/sh

# By Matt Simerson - 2025-05-19
#
# This script generates a configuration file for ntpd

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

ntpd_configure()
{
    conf_ntp_stats
    conf_ntp_servers

    test -d $NTP_ETC_DIR || mkdir -p $NTP_ETC_DIR
    NTP_CONFIG_FILE="> $NTP_ETC_DIR/ntp.conf"

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

    if ! getent passwd ntpd >/dev/null; then
        useradd -u 123 -g 123 -d /var/lib/ntp -s /sbin/nologin ntpd
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
ExecStart=/usr/local/sbin/ntpd -c /etc/ntp.conf -g -N -n
Restart=on-failure
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
CapabilityBoundingSet=CAP_SYS_TIME CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_SYS_TIME CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOSYS

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable ntpd
}

build_from_source()
{
    cd ~
    curl -O https://downloads.nwtime.org/ntp/4.2.8/ntp-4.2.8p18.tar.gz
    tar -xzf ntp-4.2.8p18.tar.gz
    cd ntp-4.2.8p18
    ./configure
    make && make install
}

NTP_LOGDIR=${NTP_LOGDIR:="/var/log/ntp"}

case "$(uname -s)" in
    Linux)
        NTP_ETC_DIR="/etc/ntp"
        NTP_DRIFTFILE="/var/lib/ntp/ntp.drift"
        NTP_LEAPFILE="/usr/share/zoneinfo/leap-seconds.list"
        NTP_LOGDIR="/var/log/ntp"
        apt install -y libssl-dev
        build_from_source
        ntpd_configure
        add_user_linux
        mkdir /var/lib/ntp
        chown ntpd:ntpd $NTP_LOGDIR /var/lib/ntp
        sed -i -e '/^IGNORE_DHCP/ s/""/"yes"/' /etc/default/ntpd
        # systemctl start ntpd
        ;;
    FreeBSD)
        NTP_ETC_DIR="/etc"
        NTP_DRIFTFILE="/var/db/ntpd.drift"
        NTP_LEAPFILE="/var/db/ntpd.leap-seconds.list"
        # for a systems (like Pis) that forget the time
        sysrc ntpdate_enable=YES
        sysrc ntpdate_config="$NTP_ETC_DIR/ntp.conf"
        sysrc ntpd_enable=YES
        sysrc ntpd_program="/usr/sbin/ntpd"
        sysrc ntpd_config="$NTP_ETC_DIR/ntp.conf"
        sysrc ntpd_flags="-g -N"
        sysrc ntpd_user="root"
        chown ntpd:ntpd $NTP_LOGDIR
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
