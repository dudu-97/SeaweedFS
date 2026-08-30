#!/usr/bin/env bash
# =====================================================================
# 02-criar-discos.sh — cria os discos de cada VM, todos como overlay
# (thin, backing file na imagem Ubuntu em $IMAGES_DIR):
#   - 5 VMs Ubuntu: disco de SO + disco de dados (para o SeaweedFS)
#   - 1 VM roteador: disco de SO (mesma imagem-base)
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-config.env"

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

command -v qemu-img >/dev/null 2>&1 || die "Instale o qemu-img: sudo apt install qemu-utils"

BASE_IMAGE_PATH="$IMAGES_DIR/$BASE_IMAGE_NAME"
[[ -f "$BASE_IMAGE_PATH" ]] || die "Imagem Ubuntu não encontrada em $BASE_IMAGE_PATH. Rode antes: ./01-baixar-imagem.sh"

for vm in "${VM_NAMES[@]}"; do
    VM_DIR="$LAB_DIR/$vm"
    mkdir -p "$VM_DIR"

    OS_DISK="$VM_DIR/${vm}-os.qcow2"
    DATA_DISK="$VM_DIR/${vm}-data.qcow2"

    if [[ -f "$OS_DISK" ]]; then
        warn "$vm: disco de SO já existe ($OS_DISK), pulando."
    else
        log "$vm: criando disco de SO (${OS_DISK_SIZE}, backing file na imagem base)"
        qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE_PATH" "$OS_DISK" "$OS_DISK_SIZE"
    fi

    if [[ -f "$DATA_DISK" ]]; then
        warn "$vm: disco de dados já existe ($DATA_DISK), pulando."
    else
        log "$vm: criando disco de dados (${DATA_DISK_SIZE}, cru, para o SeaweedFS)"
        qemu-img create -f qcow2 "$DATA_DISK" "$DATA_DISK_SIZE"
    fi
done

ROUTER_DIR="$LAB_DIR/$ROUTER_NAME"
mkdir -p "$ROUTER_DIR"
ROUTER_DISK="$ROUTER_DIR/${ROUTER_NAME}-os.qcow2"
if [[ -f "$ROUTER_DISK" ]]; then
    warn "$ROUTER_NAME: disco já existe ($ROUTER_DISK), pulando."
else
    log "$ROUTER_NAME: criando disco de SO (${ROUTER_DISK_SIZE}, backing file na imagem base)"
    qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE_PATH" "$ROUTER_DISK" "$ROUTER_DISK_SIZE"
fi

log "Discos prontos em $LAB_DIR/<vm>/"
