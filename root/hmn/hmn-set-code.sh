#!/bin/ash

set -eu

BASE="/root/hmn"
ENV_FILE="$BASE/hmn.env"
BACKUP_DIR="$BASE/backups"

mkdir -p "$BASE" "$BACKUP_DIR"
chmod 700 "$BASE" "$BACKUP_DIR"

echo "HideMyName access code setup"
echo

printf "Введи HideMyName access code: "
stty -echo 2>/dev/null || true
read -r CODE1
stty echo 2>/dev/null || true
echo

if [ -z "$CODE1" ]; then
  echo "ERROR: пустой код."
  exit 1
fi

printf "Повтори code: "
stty -echo 2>/dev/null || true
read -r CODE2
stty echo 2>/dev/null || true
echo

if [ "$CODE1" != "$CODE2" ]; then
  echo "ERROR: коды не совпали."
  exit 1
fi

case "$CODE1" in
  *[!0-9A-Za-z_-]*)
    echo "WARNING: в коде есть необычные символы."
    echo "Если это нормально для HideMyName — окей."
    ;;
esac

if [ -f "$ENV_FILE" ]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  cp "$ENV_FILE" "$BACKUP_DIR/hmn.env.$TS"
  chmod 600 "$BACKUP_DIR/hmn.env.$TS"
  echo "Старый env сохранён:"
  echo "  $BACKUP_DIR/hmn.env.$TS"
fi

umask 077

cat > "$ENV_FILE" <<EOF_ENV
# HideMyName local secrets/settings
# Created: $(date -Iseconds)

HMN_ACCESS_CODE='$CODE1'

# Current working default for VM101/client001
HMN_AWG_PARAM='1'
HMN_PROTOCOL='amneziawg1'

# HideMyName API
HMN_SERVERLIST_URL='https://hide-my-name.net/api/serverlist.php?out=js&wg'
HMN_CONFIG_URL='https://hide-my-name.net/api/vpn_get_config_wg.php'

# auto = use default dev from routing table 200
HMN_REQUEST_IFACE='auto'
EOF_ENV

chmod 600 "$ENV_FILE"

echo
echo "Готово. Код сохранён:"
echo "  $ENV_FILE"
echo
echo "Права:"
ls -l "$ENV_FILE"

unset CODE1 CODE2
