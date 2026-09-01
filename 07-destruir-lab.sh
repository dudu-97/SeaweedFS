#!/usr/bin/env bash
# =====================================================================
# 07-destruir-lab.sh — destrói as VMs (5 do cluster + roteador) e apaga
# seus discos.
#
# Uso:
#   ./07-destruir-lab.sh              -> remove as VMs e seus discos
#   ./07-destruir-lab.sh --clean-net   -> além disso, remove a rede
#                                          isolada "seaweedfs-lab" (ela é
#                                          própria deste lab, não é a
#                                          rede "default" do sistema)
#   ./07-destruir-lab.sh --purge        -> além disso, apaga a imagem
#                                          base do Ubuntu e a chave do
#                                          cluster (a ISO do roteador,
#                                          se houver, NUNCA é apagada)
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-config.env"

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }

CLEAN_NET=false
PURGE=false
for arg in "$@"; do
    case "$arg" in
        --clean-net) CLEAN_NET=true ;;
        --purge)     CLEAN_NET=true; PURGE=true ;;
    esac
done

ALL_DOMAINS=("${VM_NAMES[@]}" "$ROUTER_NAME")

read -r -p "Isso vai destruir as VMs ${ALL_DOMAINS[*]} e apagar seus discos em '$LAB_DIR'. Confirma? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Cancelado."; exit 0; }

for vm in "${ALL_DOMAINS[@]}"; do
    if virsh dominfo "$vm" >/dev/null 2>&1; then
        log "Destruindo VM: $vm"
        virsh destroy "$vm" >/dev/null 2>&1 || true
        virsh undefine "$vm" --nvram >/dev/null 2>&1 || virsh undefine "$vm" >/dev/null 2>&1 || true
    else
        warn "VM '$vm' não existe no libvirt, pulando undefine."
    fi

    VM_DIR="$LAB_DIR/$vm"
    if [[ -d "$VM_DIR" ]]; then
        log "Removendo discos e cloud-init de $vm ($VM_DIR)"
        rm -rf "$VM_DIR"
    fi
done

if [[ "$CLEAN_NET" == "true" ]]; then
    if virsh net-info "$NET_NAME" >/dev/null 2>&1; then
        log "Removendo rede isolada '$NET_NAME'..."
        virsh net-destroy "$NET_NAME" >/dev/null 2>&1 || true
        virsh net-undefine "$NET_NAME" >/dev/null 2>&1 || true
    else
        warn "Rede '$NET_NAME' não existe, nada a remover."
    fi

    WAN_HOST_XML="<host mac='${ROUTER_WAN_MAC}' name='${ROUTER_NAME}-wan' ip='${ROUTER_WAN_IP}'/>"
    if virsh net-dumpxml "$ROUTER_WAN_NETWORK" 2>/dev/null | grep -q "mac='${ROUTER_WAN_MAC}'"; then
        log "Removendo reserva de IP WAN do roteador na rede '$ROUTER_WAN_NETWORK'..."
        WAN_DEL_ARGS=(--config)
        [[ "$(virsh net-info "$ROUTER_WAN_NETWORK" 2>/dev/null | awk '/^Active/{print $2}')" == "yes" ]] && WAN_DEL_ARGS=(--live --config)
        # Antes isso ignorava qualquer erro silenciosamente (|| true +
        # /dev/null) — se a remoção falhasse por qualquer motivo, o
        # script terminava normal e ninguém ficava sabendo que a reserva
        # sobrou órfã, só descobrindo no próximo deploy (erro de "já
        # existe" no 03-configurar-rede.sh). Agora o erro real aparece.
        if WAN_DEL_OUT="$(virsh net-update "$ROUTER_WAN_NETWORK" delete ip-dhcp-host "$WAN_HOST_XML" "${WAN_DEL_ARGS[@]}" 2>&1)"; then
            log "Reserva de IP WAN removida."
        else
            warn "Não consegui remover a reserva de IP WAN (MAC ${ROUTER_WAN_MAC}) em '$ROUTER_WAN_NETWORK': $WAN_DEL_OUT"
            warn "Remova manualmente antes do próximo deploy: virsh net-update $ROUTER_WAN_NETWORK delete ip-dhcp-host \"$WAN_HOST_XML\" --live --config"
        fi
    else
        warn "Reserva de IP WAN (MAC ${ROUTER_WAN_MAC}) não existe em '$ROUTER_WAN_NETWORK', nada a remover."
    fi
    warn "Rede WAN '$ROUTER_WAN_NETWORK' (ex: default) em si NUNCA é destruída — é do sistema, só a reserva foi removida."
fi

if [[ "$PURGE" == "true" ]]; then
    BASE_IMAGE_PATH="$IMAGES_DIR/$BASE_IMAGE_NAME"
    [[ -f "$BASE_IMAGE_PATH" ]] && { log "Removendo imagem Ubuntu"; rm -f "$BASE_IMAGE_PATH"; }
    [[ -f "$CLUSTER_KEY_PATH" ]] && { log "Removendo chave do cluster"; rm -f "$CLUSTER_KEY_PATH" "${CLUSTER_KEY_PATH}.pub"; }
fi

log "Lab destruído."
