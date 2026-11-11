#!/usr/bin/env bash
# Установка ITtool на Ubuntu без sudo: зависимости, команда ittool, служба бота.
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
python3 -m venv "$DIR/.venv"
"$DIR/.venv/bin/pip" install -q -r "$DIR/requirements.txt"
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"
ln -sf "$DIR/ittool" "$HOME/.local/bin/ittool"
for svc in ittool-bot ittool-api; do
    sed "s|%h/ITtool|$DIR|" "$DIR/deploy/$svc.service" > "$HOME/.config/systemd/user/$svc.service"
done
systemctl --user daemon-reload
systemctl --user enable --now ittool-bot.service
systemctl --user enable --now ittool-api.service
echo "Готово: команда «ittool», службы — systemctl --user status ittool-bot ittool-api"
echo "Токен для приложения на iPhone: ittool api token"
echo "Чтобы бот работал и без входа в систему: loginctl enable-linger $USER"
