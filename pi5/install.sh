#!/bin/sh

set -e

set_cpu_governor() {
    echo "Setting CPU governor to powersave"
    apt install -y cpufrequtils
    cpufreq-set -g powersave

    cat > /etc/systemd/system/set-cpu-governor.service <<EOG
[Unit]
Description=Set CPU Governor to powersave

[Service]
ExecStart=/usr/bin/cpufreq-set -g powersave
Type=oneshot

[Install]
WantedBy=multi-user.target

EOG

    systemctl daemon-reload
    systemctl enable set-cpu-governor.service
    systemctl start set-cpu-governor.service
}

disable_timesyncd() {
    echo "Disabling systemd-timesyncd"
    systemctl stop systemd-timesyncd
    systemctl disable systemd-timesyncd
}

disable_bluetooth() {
    echo "Disabling Bluetooth"
    for i in alsa-state bluetooth triggerhappy hciuart; do
        systemctl stop $i.service; systemctl disable $i.service
    done

    apt purge -y bluez bluez-firmware modemmanager
    grep -q '^dtoverlay=disable-bt' /boot/firmware/config.txt \
        || echo 'dtoverlay=disable-bt' >> /boot/firmware/config.txt
}

disable_wifi() {
    echo "Disabling WiFi"
    apt purge -y wpasupplicant wireless-tools

    grep -q '^dtoverlay=disable-wifi' /boot/firmware/config.txt \
        || echo 'dtoverlay=disable-wifi' >> /boot/firmware/config.txt
}

disable_audio() {
    echo "Disabling audio"
    grep -q audio=on /boot/firmware/config.txt \
        && sed -i -e 's/audio=on/audio=off/' /boot/firmware/config.txt
}

disable_zeroconf() {
    echo "Disabling zeroconf"
    systemctl stop avahi-daemon.service
    systemctl disable avahi-daemon.service
    apt purge -y avahi-daemon
}

set_hostname() {
    systemctl stop systemd-hostnamed
    systemctl disable systemd-hostnamed
    echo $(hostname) > /etc/hostname

    echo "
Welcome to $(hostname)!
" > /etc/motd
}

apt update && apt -y upgrade

set_cpu_governor
disable_timesyncd
disable_bluetooth
disable_wifi
disable_audio
disable_zeroconf
apt autoremove -y
