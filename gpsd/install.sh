#!/bin/sh

# By Matt Simerson - 2025-05-21
#
# This script installs and configures gpsd

set -e

install_freebsd() {
    sysrc gpsd_enable=YES
    sysrc gpsd_devices="/dev/gps0 /dev/pps0"
    sysrc gpsd_flags="--passive --speed 115200 --badtime --nowait"
    pkg install -y gpsd-nox11
    service gpsd start
}

install_linux() {
    apt install -y gpsd
    sed -i \
        -e '/^DEVICES/ s|""|"/dev/gps0 /dev/pps0"|' \
        -e '/^USBAUTO/ s/true/false/' \
        -e '/^GPSD_OPTIONS/ s/=""/="--passive --badtime --nowait --speed 115200"/' \
        /etc/default/gpsd
    systemctl enable gpsd
    service gpsd start
}

case "$(uname -s)" in
	FreeBSD)
		install_freebsd
	;;
	Linux)
		install_linux
	;;
	*)
		echo "ERR: Unsupported platform $(uname -s). Please file a feature request."
		exit 1
	;;
esac
