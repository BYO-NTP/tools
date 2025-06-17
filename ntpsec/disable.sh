#!/bin/sh

set -e

# By Matt Simerson - 2025-06-17

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

service_exists() {
    case "$(uname -s)" in
        FreeBSD) test -f /etc/rc.d/ntpd ;;
        Darwin) port installed ntpsec >/dev/null 2>&1 ;;
        Linux) systemctl list-unit-files | grep -q "^ntpsec\.service" ;;
        *)
            echo "ERR: Unsupported platform $(uname -s). Please file a feature request."
            exit 1
        ;;
    esac
}

stop() {
    case "$(uname -s)" in
        FreeBSD) service ntpd onestop ;;
        Darwin) ;;
        Linux) systemctl stop ntpsec ;;
        *)
            echo "ERR: Unsupported platform $(uname -s). Please file a feature request."
            exit 1
        ;;
    esac
}

disable() {
    case "$(uname -s)" in
        FreeBSD) sysrc -c ntpd_enable=NO || sysrc ntpd_enable=NO ;;
        Darwin) port unload ntpd ;;
        Linux)
            if systemctl is-enabled ntpsec.service &>/dev/null; then
                sudo systemctl disable --now ntpsec.service
            fi
        ;;
        *)
            echo "ERR: Unsupported platform $(uname -s). Please file a feature request."
            exit 1
        ;;
    esac
}

if is_running ntpd; then stop; fi
if service_exists; then disable; fi