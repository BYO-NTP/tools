#!/bin/sh

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

stop_gpsd() {
    case "$(uname -s)" in
        FreeBSD)
            service gpsd onestop
            sysrc gpsd_enable=NO
        ;;
        Darwin)
            service gpsd stop
            port unload gpsd
        ;;
        Linux)
            systemctl stop gpsd
            systemctl disable gpsd
        ;;
        *)
            echo "ERR: Unsupported platform $(uname -s). Please file a feature request."
            exit 1
        ;;
    esac
}

if is_running gpsd; then
    stop_gpsd;
fi
