#!/bin/sh

set -e

# By Matt Simerson - 2025-06-16

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
        FreeBSD) test -f /usr/local/etc/rc.d/chronyd ;;
        Darwin) port installed chrony >/dev/null 2>&1 ;;
        Linux) systemctl list-unit-files | grep -q "^chrony\.service" ;;
        *)
            echo "ERR: Unsupported platform $(uname -s). Please file a feature request."
            exit 1
        ;;
    esac
}

stop() {
    case "$(uname -s)" in
        FreeBSD) service chronyd onestop ;;
        Darwin) ;;
        Linux) systemctl stop chrony ;;
        *)
            echo "ERR: Unsupported platform $(uname -s). Please file a feature request."
            exit 1
        ;;
    esac
}

disable() {
    case "$(uname -s)" in
        FreeBSD) sysrc -c chronyd_enable=NO || sysrc chronyd_enable=NO ;;
        Darwin) port unload chrony ;;
        Linux)
            if systemctl is-enabled chrony.service &>/dev/null; then
                sudo systemctl disable --now chrony.service
            fi
        ;;
        *)
            echo "ERR: Unsupported platform $(uname -s). Please file a feature request."
            exit 1
        ;;
    esac
}

if is_running chrony; then stop; fi
if service_exists; then disable; fi