#!/bin/sh

install_linux()
{
	curl -sS https://starship.rs/install.sh | sh

	apt install -y zsh zsh-autosuggestions
	chsh -s /usr/bin/zsh root

	curl -sSo ~/.zshrc https://byo-ntp.github.io/tools/zsh/config.txt

	test -d ~/.config || mkdir ~/.config
	curl -sSo ~/.config/starship.toml https://byo-ntp.github.io/tools/zsh/starship.txt
}

install_freebsd()
{
	pkg install -y zsh zsh-autosuggestions starship && \
	chpass -s zsh root

	fetch -qo ~/.zshrc https://byo-ntp.github.io/tools/zsh/config.txt

	test -d ~/.config || mkdir ~/.config
	fetch -qo ~/.config/starship.toml https://byo-ntp.github.io/tools/zsh/starship.txt
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
