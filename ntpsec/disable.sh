#!/bin/sh

set -e

# By Matt Simerson - 2025-06-17

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

service_exists() {
    case "$(uname -s)" in
        FreeBSD) test -f /etc/rc.d/ntpd ;;
        Darwin) port installed ntpsec | grep -q ntpsec ;;
        Linux) systemctl list-unit-files | grep -q "^ntpsec\.service" ;;
    esac
}

disable() {
    case "$(uname -s)" in
        FreeBSD) sysrc -c ntpd_enable=NO || sysrc ntpd_enable=NO ;;
        Darwin) sudo port uninstall ntpsec ;;
        Linux)
            if systemctl is-enabled ntpsec.service &>/dev/null; then
                sudo systemctl disable --now ntpsec.service
            fi
        ;;
    esac
}

case "$(uname -s)" in
    Darwin|FreeBSD|Linux) ;;
    *)  echo "ERR: Unsupported platform $(uname -s). Please file a feature request."
        exit 1
    ;;
esac

if service_exists; then
    if is_running ntpd; then stop; fi
    disable
fi
