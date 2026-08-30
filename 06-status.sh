#!/usr/bin/env bash
# =====================================================================
# 06-status.sh — mostra estado/IP das VMs e o status HTTP de cada
# serviço do SeaweedFS (master/volume/filer/S3) rodando em cada uma.
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

# ProxyCommand explícito (mais confiável que "-J" puro com estas opções
# de host-key neste OpenSSH — "-J" não repassa as opções de forma
# consistente para o salto pelo roteador).
JUMP="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6 -o BatchMode=yes -W %h:%p ${VM_USER}@${ROUTER_WAN_IP}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6 -o BatchMode=yes -o "ProxyCommand=$JUMP")

echo
echo "Status dos serviços SeaweedFS (checado de dentro de cada VM, via SSH):"
printf "%-14s %-9s %-9s %-9s %-7s %-6s %-8s\n" "VM" "BINARIO" "DISCO" "SERVIÇO" "PORTA" "HTTP" "STATUS"
printf "%-14s %-9s %-9s %-9s %-7s %-6s %-8s\n" "----" "-------" "-----" "-------" "-----" "----" "------"

ANY_DOWN=0
for vm in "${VM_NAMES[@]}"; do
    ip="${VM_IP[$vm]}"

    # monta a lista de porta:caminho:papel que esta VM deveria expor
    CHECKS=()
    [[ "$vm" == *master* ]] && CHECKS+=("${SEAWEED_MASTER_PORT}:/cluster/status:master")
    [[ "$vm" == *vol* ]]    && CHECKS+=("${SEAWEED_VOLUME_PORT}:/status:volume")
    if [[ "$vm" == "$FILER_HOST" ]]; then
        CHECKS+=("${SEAWEED_FILER_PORT}:/:filer")
        CHECKS+=("${SEAWEED_S3_PORT}:/:s3")
    fi

    REMOTE_CMD='command -v weed >/dev/null 2>&1 && echo "BIN:ok" || echo "BIN:falta"; '
    REMOTE_CMD+='mountpoint -q '"${DATA_MOUNT_DIR}"' && echo "DISK:ok" || echo "DISK:falta"; '
    for c in "${CHECKS[@]}"; do
        port="${c%%:*}"
        rest="${c#*:}"
        path="${rest%%:*}"
        REMOTE_CMD+="code=\$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:${port}${path} 2>/dev/null); echo \"HTTP:${port}:\${code:-000}\"; "
    done

    if ! REMOTE_OUT=$(ssh -n "${SSH_OPTS[@]}" "${VM_USER}@${ip}" "$REMOTE_CMD" 2>/dev/null); then
        printf "%-14s %-9s %-9s %-9s %-7s %-6s %-8s\n" "$vm" "?" "?" "-" "-" "-" "SSH FALHOU"
        ANY_DOWN=1
        continue
    fi

    BIN=$(grep -oP '(?<=BIN:)\w+' <<<"$REMOTE_OUT")
    DISK=$(grep -oP '(?<=DISK:)\w+' <<<"$REMOTE_OUT")
    FIRST=1
    for c in "${CHECKS[@]}"; do
        port="${c%%:*}"; role="${c##*:}"
        code=$(grep -oP "(?<=HTTP:${port}:)\d+" <<<"$REMOTE_OUT")
        [[ "$code" == "200" ]] && ST="UP" || { ST="DOWN"; ANY_DOWN=1; }
        if [[ "$FIRST" == "1" ]]; then
            printf "%-14s %-9s %-9s %-9s %-7s %-6s %-8s\n" "$vm" "$BIN" "$DISK" "$role" "$port" "$code" "$ST"
            FIRST=0
        else
            printf "%-14s %-9s %-9s %-9s %-7s %-6s %-8s\n" "" "" "" "$role" "$port" "$code" "$ST"
        fi
    done
done

echo
if [[ "$ANY_DOWN" == "0" ]]; then
    echo "Todos os serviços responderam HTTP 200. Cluster de pé."
else
    echo "Algum serviço não respondeu 200 — se acabou de rodar ./deploy-lab.sh,"
    echo "aguarde mais 1-2 min (download do binário + boot) e rode de novo."
fi

echo
echo "Acesso ao roteador (direto, via WAN):"
echo "  ssh ${VM_USER}@${ROUTER_WAN_IP}"
echo
echo "Acesso às 5 VMs do lab (rede isolada — sem rota direta do host,"
echo "salte pelo roteador com ProxyCommand, veja README > Acesso SSH):"
echo "  ssh -o ProxyCommand=\"ssh -W %h:%p ${VM_USER}@${ROUTER_WAN_IP}\" ${VM_USER}@<IP-da-VM>"
echo "(senha de todas: ${VM_PASSWORD}, ou sua chave SSH)"
echo

read -r -p "Testar SSH sem senha entre as VMs (${VM_NAMES[0]} -> demais) agora? [y/N] " CONFIRM
if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    ORIGIN="${VM_NAMES[0]}"
    for vm in "${VM_NAMES[@]:1}"; do
        echo -n "  ${ORIGIN} -> ${vm} (${VM_IP[$vm]}): "
        if ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP[$ORIGIN]}" \
            "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes ${VM_USER}@${VM_IP[$vm]} 'hostname'" 2>/dev/null; then
            :
        else
            echo "FALHOU (VMs ainda de boot? aguarde e tente de novo)"
        fi
    done
fi
