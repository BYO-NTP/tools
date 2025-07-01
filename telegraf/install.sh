#!/bin/sh

# By Matt Simerson - 2025-06

set -e

TOOLS_URI="https://byo-ntp.github.io/tools"

install_telegraf_freebsd()
{
	pkg install -y telegraf smartmontools lsof sudo

	cat > /usr/local/etc/sudoers.d/telegraf << EOF
telegraf ALL=(ALL) NOPASSWD: /sbin/pfctl -s info
telegraf ALL=(ALL) NOPASSWD: /bin/ps
telegraf ALL=(ALL) NOPASSWD: /usr/local/sbin/ntpctl
telegraf ALL=(ALL) NOPASSWD: /usr/local/sbin/smartctl
EOF

	sysrc telegraf_enable=YES
}

install_telegraf_linux()
{
	curl --silent --location -O https://repos.influxdata.com/influxdata-archive.key && \
	echo "943666881a1b8d9b849b74caebf02d3465d6beb716510d86a39f6c8e8dac7515  influxdata-archive.key" | \
	sha256sum -c - && cat influxdata-archive.key | gpg --dearmor | \
	tee /etc/apt/trusted.gpg.d/influxdata-archive.gpg > /dev/null && \
	echo 'deb [signed-by=/etc/apt/trusted.gpg.d/influxdata-archive.gpg] https://repos.influxdata.com/debian stable main' | \
	tee /etc/apt/sources.list.d/influxdata.list
	apt-get update
	apt-get install -y telegraf sudo

	cat > /etc/sudoers.d/telegraf << EOF
telegraf ALL=(ALL) NOPASSWD: /usr/bin/vcgencmd
telegraf ALL=(ALL) NOPASSWD: /bin/ps
telegraf ALL=(ALL) NOPASSWD: /usr/sbin/ntpctl
telegraf ALL=(ALL) NOPASSWD: /usr/sbin/smartctl
EOF

	SERVICEFILE=/etc/systemd/system/multi-user.target.wants/telegraf.service
	# /lib/systemd/system/telegraf.service ?

	if [ -L "$SERVICEFILE" ]; then
		SERVICEFILE=$(readlink -f "$SERVICEFILE")
	else
		echo "ERR: $SERVICEFILE is not a symlink, fixing..."
		mv $SERVICEFILE /etc/systemd/system/
		ln -s /etc/systemd/system/telegraf.service $SERVICEFILE
	fi

	sed -i -e '/LimitMEMLOCK/ s/Limit/#Limit/' "$SERVICEFILE"
	systemctl daemon-reload

	echo 'TELEGRAF_OPTS="--debug"' > /etc/default/telegraf
}

install_telegraf_darwin()
{
	port install telegraf

	mkdir -p /opt/local/var/log/telegraf /opt/local/var/run/telegraf
	chown telegraf:telegraf /opt/local/var/run/telegraf \
		/opt/local/var/log/telegraf

	$FETCH /Library/LaunchDaemons/org.macports.telegraf.plist \
		"$TOOLS_URI/telegraf/org.macports.telegraf.plist"

	port load telegraf
}

install_temperature()
{
	test -d /usr/local/sbin || mkdir -p /usr/local/sbin
	$FETCH /usr/local/sbin/temperature.sh "$TOOLS_URI/telegraf/temperature.sh"
	chmod 755 /usr/local/sbin/temperature.sh
	chmod +x /usr/local/sbin/temperature.sh
}

configure_temperature()
{
	for i in cpu gpu disk; do
		OUT=$(/usr/local/sbin/temperature.sh $i)
		if [ -n "$OUT" ]; then
			cat >> "$TG_ETC_DIR/telegraf.conf" <<EOF

[[inputs.exec]]
  interval = "30s"
  commands = ["/usr/local/sbin/temperature.sh $i"]
  name_override = "$i"
  data_format = "influx"
EOF
		fi
	done

	OUT=$(/usr/local/sbin/temperature.sh freq)
	if [ -n "$OUT" ]; then
		cat >> "$TG_ETC_DIR/telegraf.conf" <<EOF

[[inputs.exec]]
  interval = "10s"
  commands = ["/usr/local/sbin/temperature.sh freq"]
  name_override = "cpu"
  data_format = "influx"
EOF
	fi
}

is_running()
{
	case "$(uname -s)" in
		FreeBSD|Darwin)
			pgrep -q "$1"
		;;
		Linux)
			pgrep -c "$1" > /dev/null 2>&1
		;;
		*)
			echo "ERR: Unsupported platform $(uname -s). Please file a feature request."
			exit 1
		;;
	esac
}

enable_chrony()
{
	sed -i '' \
		-e '/^#\[\[inputs.chrony/ s/^#//' \
		-e '/:323/ s/#//g' \
		-e '/metrics.*sources/ s/#//g' \
		-e '/^\[\[inputs.ntpq/ s/^\[/#[/' \
		-e '/-c peers/ s/options/#options/' \
		"$TG_ETC_DIR/telegraf.conf"
}

enable_ntpd()
{
	sed -i '' \
		-e '/^#\[\[inputs.ntpq/ s/^#//g' \
		-e '/-c peers/ s/#//g' \
		-e '/^\[\[inputs.chrony/ s/^\[/#[/' \
		-e '/:323/ s/server/#server/' \
		-e '/metrics.*sources/ s/metrics/#metrics/' \
		"$TG_ETC_DIR/telegraf.conf"
}

configure_ntpd()
{
	if is_running chronyd; then
		enable_chrony
	elif is_running ntpd; then
		enable_ntpd
	fi
}

install_telegraf_conf()
{
	$FETCH - "$TOOLS_URI/telegraf/telegraf.conf" \
		| sed -e "/hostname/ s/time.example.com/$(hostname)/" \
		> "$TG_ETC_DIR/telegraf.conf"

	if [ -n "$INFLUX_DB_HOST" ]; then
		sed -i -e "/INFLUX/ s/INFLUX_SERVER/$INFLUX_DB_HOST/" "$TG_ETC_DIR/telegraf.conf"
	fi

	configure_ntpd
	configure_temperature
}

if [ "$(id -u)" -ne 0 ]; then
	echo "ERR: This script must be run as root."
	exit 1
fi

case "$(uname -s)" in
	FreeBSD)
		FETCH="fetch -o"
		TG_ETC_DIR="/usr/local/etc"
		install_temperature
		install_telegraf_freebsd
		install_telegraf_conf
		;;
	Linux) 
		FETCH="curl -o"
		TG_ETC_DIR="/etc/telegraf"
		install_temperature
		install_telegraf_linux
		install_telegraf_conf
		;;
	Darwin)
		FETCH="curl -o"
		TG_ETC_DIR="/opt/local/etc/telegraf"
		install_telegraf_darwin
		;;
	*)
		echo "ERR: Unsupported platform $(uname -s). Please file a feature request."
		exit 1
	;;
esac
