#!/usr/bin/env bash
# =====================================================================
# 01-baixar-imagem.sh — baixa a cloud image Ubuntu (uma única vez),
# guardada em $IMAGES_DIR. Usada tanto pelas 5 VMs do cluster quanto
# pelo roteador.
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-config.env"

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

command -v wget >/dev/null 2>&1 || die "Instale o wget: sudo apt install wget"

mkdir -p "$IMAGES_DIR"

BASE_IMAGE_PATH="$IMAGES_DIR/$BASE_IMAGE_NAME"
if [[ -f "$BASE_IMAGE_PATH" ]]; then
    log "Imagem Ubuntu já existe em $BASE_IMAGE_PATH, nada a fazer."
else
    log "Baixando imagem Ubuntu: $BASE_IMAGE_URL"
    wget -O "$BASE_IMAGE_PATH" "$BASE_IMAGE_URL"
    log "Download concluído: $BASE_IMAGE_PATH"
fi
