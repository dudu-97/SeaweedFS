#!/usr/bin/env bash
# =====================================================================
# 06-status.sh — mostra estado/IP das VMs e testa SSH entre elas
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-config.env"

printf "%-14s %-10s %-16s %-24s\n" "VM" "ESTADO" "IP" "PAPEL"
printf "%-14s %-10s %-16s %-24s\n" "----" "------" "--" "-----"

STATE="n/a"
virsh dominfo "$ROUTER_NAME" >/dev/null 2>&1 && STATE=$(virsh domstate "$ROUTER_NAME")
printf "%-14s %-10s %-16s %-24s\n" "$ROUTER_NAME" "$STATE" "$ROUTER_WAN_IP" "roteador (WAN, use este p/ SSH)"
printf "%-14s %-10s %-16s %-24s\n" "" "" "$ROUTER_LAN_IP" "roteador (LAN, gateway do lab)"

for vm in "${VM_NAMES[@]}"; do
    STATE="n/a"
    virsh dominfo "$vm" >/dev/null 2>&1 && STATE=$(virsh domstate "$vm")
    printf "%-14s %-10s %-16s %-24s\n" "$vm" "$STATE" "${VM_IP[$vm]}" "${VM_ROLE[$vm]}"
done

echo
echo "Status dos serviços SeaweedFS (SSH via jump pelo roteador):"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes"

declare -A PORT_ROLE=(
    [9333]="master"
    [8080]="volume"
    [8888]="filer"
    [8333]="s3"
    [23646]="admin"
)

printf "%-14s %-16s %-9s %-9s %-40s\n" "VM" "IP" "BINARIO" "DISCO" "PORTAS ATIVAS (papel)"
printf "%-14s %-16s %-9s %-9s %-40s\n" "----" "--" "-------" "-----" "---------------------"

for vm in "${VM_NAMES[@]}"; do
    ip="${VM_IP[$vm]}"
    if ! REMOTE_OUT=$(ssh -n $SSH_OPTS -J "${VM_USER}@${ROUTER_WAN_IP}" "${VM_USER}@${ip}" '
            command -v weed >/dev/null 2>&1 && echo "BIN:ok" || echo "BIN:falta"
            mountpoint -q /data && echo "DISK:ok" || echo "DISK:falta"
            ss -Hltn 2>/dev/null | awk "{print \$4}" | grep -oE "[0-9]+\$" | sort -u
        ' 2>/dev/null); then
        printf "%-14s %-16s %-9s %-9s %-40s\n" "$vm" "$ip" "?" "?" "SSH indisponível (VM ainda de boot?)"
        continue
    fi

    BIN=$(grep -oP '(?<=BIN:)\w+' <<<"$REMOTE_OUT")
    DISK=$(grep -oP '(?<=DISK:)\w+' <<<"$REMOTE_OUT")

    ROLES=""
    while read -r p; do
        [[ -z "$p" ]] && continue
        role="${PORT_ROLE[$p]:-}"
        [[ -n "$role" ]] && ROLES+="${p}(${role}) "
    done <<<"$(grep -E '^[0-9]+$' <<<"$REMOTE_OUT")"
    [[ -z "$ROLES" ]] && ROLES="nenhum serviço weed ativo"

    printf "%-14s %-16s %-9s %-9s %-40s\n" "$vm" "$ip" "$BIN" "$DISK" "$ROLES"
done
echo "(papel por porta: 9333=master  8080=volume  8888=filer  8333=S3  23646=admin)"
echo
echo "Acesso ao roteador (direto, via WAN):"
echo "  ssh ${VM_USER}@${ROUTER_WAN_IP}"
echo
echo "Acesso às 5 VMs do lab (rede isolada — sem rota direta do host,"
echo "salte pelo roteador com ProxyJump):"
echo "  ssh -J ${VM_USER}@${ROUTER_WAN_IP} ${VM_USER}@<IP-da-VM>"
echo "(senha de todas: ${VM_PASSWORD}, ou sua chave SSH)"
echo

read -r -p "Testar SSH sem senha entre as VMs (${VM_NAMES[0]} -> demais) agora? [y/N] " CONFIRM
if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"
    ORIGIN="${VM_NAMES[0]}"
    for vm in "${VM_NAMES[@]:1}"; do
        echo -n "  ${ORIGIN} -> ${vm} (${VM_IP[$vm]}): "
        if ssh $SSH_OPTS -J "${VM_USER}@${ROUTER_WAN_IP}" "${VM_USER}@${VM_IP[$ORIGIN]}" \
            "ssh $SSH_OPTS ${VM_USER}@${VM_IP[$vm]} 'hostname'" 2>/dev/null; then
            :
        else
            echo "FALHOU (VMs ainda de boot? aguarde e tente de novo)"
        fi
    done
fi
