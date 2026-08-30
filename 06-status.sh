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
