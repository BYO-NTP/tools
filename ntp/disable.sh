#!/bin/sh
# By Matt Simerson - 2025-06-17

set -e

is_running()
{
	case "$(uname -s)" in
		FreeBSD) pgrep -q ntpd ;;
        Darwin)
            # pgrep ntpd can match for ntp and ntpsec
            test -f /Library/LaunchDaemons/org.macports.ntp.plist && pgrep -q ntpd ;;
		Linux) pgrep -c ntpd > /dev/null 2>&1 ;;
		*)
			echo "ERR: Unsupported platform $(uname -s). Please file a feature request."
			exit 1
		;;
	esac
}

service_exists() {
    case "$(uname -s)" in
        FreeBSD) test -f /etc/rc.d/ntpd ;;
        Darwin) port installed ntp | grep -q ntp ;;
        Linux) systemctl list-unit-files | grep -q "^ntpd\.service" ;;
        *)
            echo "ERR: Unsupported platform $(uname -s). Please file a feature request."
            exit 1
        ;;
    esac
}

stop() {
    case "$(uname -s)" in
        FreeBSD) service ntpd onestop ;;
        Darwin) sudo port unload ntp ;;
        Linux) systemctl stop ntpd ;;
        *)
            echo "ERR: Unsupported platform $(uname -s). Please file a feature request."
            exit 1
        ;;
    esac
}

disable() {
    case "$(uname -s)" in
        FreeBSD) sysrc -c ntpd_enable=NO || sysrc ntpd_enable=NO ;;
        Darwin) port uninstall ntp ;;
        Linux)
            if systemctl is-enabled ntpd.service &>/dev/null; then
                sudo systemctl disable --now ntpd.service
            fi
        ;;
        *)
            echo "ERR: Unsupported platform $(uname -s). Please file a feature request."
            exit 1
        ;;
    esac
}

if is_running; then stop; fi
if service_exists; then disable; fi
