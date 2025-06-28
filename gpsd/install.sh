#!/bin/sh

# By Matt Simerson - 2025-05-21
#
# This script installs and configures gpsd

set -e

TOOLS_URI="https://byo-ntp.github.io/tools"

is_running()
{
	case "$(uname -s)" in
		FreeBSD|Darwin) pgrep -q "$1" ;;
		Linux) pgrep -c "$1" > /dev/null 2>&1 ;;
		*)
			echo "ERR: Unsupported platform $(uname -s). Please file a feature request."
			exit 1
		;;
	esac
}

install_freebsd() {
    sysrc gpsd_enable=YES
    case "$NTP_REFCLOCKS" in
        # add the target of gps0 for ntp's GPSD-NG driver
        *127.127.46.*) sysrc gpsd_devices="/dev/$(readlink /dev/gps0)" ;;
        # everything else points to gps0
        *) sysrc gpsd_devices="/dev/gps0" ;;
    esac
    if [ -L "/dev/pps0" ]; then sysrc gpsd_devices+=" /dev/pps0"; fi
    sysrc gpsd_flags="--passive --speed 115200 --badtime --nowait"
    pkg install -y gpsd-nox11
    if is_running gpsd; then
        service gpsd restart
    else
        service gpsd start
    fi
}

install_linux() {
    apt install -y gpsd
    sed -i \
        -e '/^DEVICES/ s|""|"/dev/gps0 /dev/pps0"|' \
        -e '/^USBAUTO/ s/true/false/' \
        -e '/^GPSD_OPTIONS/ s/=""/="--passive --badtime --nowait --speed 115200"/' \
        /etc/default/gpsd
    systemctl enable gpsd
    if is_running gpsd; then
        service gpsd restart
    else
        service gpsd start
    fi
}

install_darwin() {
    if ! command -v port >/dev/null; then
        echo "ERR: MacPorts is not installed. Please install MacPorts first."
        exit 1
    fi

    port install gpsd

    GPSD_PLIST="/Library/LaunchDaemons/org.macports.gpsd.plist"
    if [ -f "$GPSD_PLIST" ]; then
        echo "INFO: preserving $GPSD_PLIST"
    else
        echo "INFO: creating $GPSD_PLIST"
        GPSD_SERIAL=$(ls /dev/cu.usb* | egrep 'usb(serial|modem)' | head -n 1)
        curl $GPSD_PLIST \
            | sed -e "s|@GPSD_SERIAL@|$GPSD_SERIAL|" \
            > "$TOOLS_URI/gpsd/org.macports.gpsd.plist"
        chmod 644 $GPSD_PLIST
    fi

    port load gpsd
}

case "$(uname -s)" in
	FreeBSD) install_freebsd ;;
	Linux)   install_linux   ;;
	Darwin)  install_darwin  ;;
	*)
		echo "ERR: Unsupported platform $(uname -s). Please file a feature request."
		exit 1
	;;
esac
