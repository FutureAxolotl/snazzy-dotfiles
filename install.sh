#!/usr/bin/sh
cp .doom.d/config.el ~/.doom.d/
cp BetterDiscord/themes/Snazzy.theme.css ~/.config/BetterDiscord/themes/
cp picom.conf ~/.config
cp -r .doom.d/scripts ~/.doom.d
cp -r wallpapers/ ~/Pictures/
cp -r sxhkd ~/.config
cp -r rofi ~/.config
cp .zshrc ~/
cp .p10k.zsh ~/
cp -r dunst ~/.config
cp -r polybar ~/.config
cp -r bspwm ~/.config
cp -r alacritty ~/.config
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
echo "Dotfiles copied. I hope you enjoy!:D "
