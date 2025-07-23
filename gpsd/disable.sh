#!/bin/sh

# By Matt Simerson - 2025-06-16

is_running()
{
    case "$(uname -s)" in
        FreeBSD|Darwin) pgrep -q "$1" ;;
        Linux) pgrep -c "$1" > /dev/null 2>&1 ;;
    esac
}

stop_gpsd() {
    case "$(uname -s)" in
        FreeBSD) service gpsd onestop ;;
        Darwin)  port unload gpsd ;;
        Linux)   systemctl stop gpsd ;;
    esac
}

service_exists() {
    case "$(uname -s)" in
        FreeBSD) test -f /usr/local/etc/rc.d/gpsd ;;
        Darwin) port installed gpsd | grep -q gpsd ;;
        Linux) systemctl list-unit-files | grep -q "^gpsd\.service" ;;
    esac
}

disable() {
    case "$(uname -s)" in
        FreeBSD) sysrc -c gpsd_enable=NO || sysrc gpsd_enable=NO ;;
        Darwin) sudo port uninstall gpsd ;;
        Linux)
            if systemctl is-enabled gpsd.service &>/dev/null; then
                sudo systemctl disable --now gpsd.service
            fi
        ;;
    esac
}

case "$(uname -s)" in
    FreeBSD|Darwin|Linux) ;;
    *)
        echo "ERR: Unsupported platform $(uname -s). Please file a feature request."
        exit 1
    ;;
esac

echo -n "BYO-NTP: does gpsd service exist..."
if service_exists; then
    echo "yes"
    echo -n "BYO-NTP: is gpsd running..."
    if is_running gpsd; then
        echo "yes"
        stop_gpsd
        echo 'BYO-NTP: gpsd stopped.'
    else
        echo "no"
    fi
    disable
else
    echo "no"
fi
