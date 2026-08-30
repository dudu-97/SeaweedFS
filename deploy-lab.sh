#!/usr/bin/env bash
# =====================================================================
# deploy-lab.sh — roda TODA a sequência de criação do lab, na ordem
# correta, sem precisar executar script por script.
#
#   01-baixar-imagem.sh -> 02-criar-discos.sh -> 03-configurar-rede.sh
#   -> 04-gerar-cloud-init.sh -> 05-criar-vms.sh -> 06-status.sh
#
# Uso:
#   ./deploy-lab.sh
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-config.env"

banner() { echo -e "\n\e[1;36m==== $* ====\e[0m"; }

STEPS=(
    "01-baixar-imagem.sh"
    "02-criar-discos.sh"
    "03-configurar-rede.sh"
    "04-gerar-cloud-init.sh"
    "05-criar-vms.sh"
)

for step in "${STEPS[@]}"; do
    banner "$step"
    bash "$SCRIPT_DIR/$step"
done

banner "Aguardando o roteador terminar o cloud-init (SSH + NAT prontos)"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=4 -o BatchMode=yes"
TRIES=0
until ssh $SSH_OPTS "${VM_USER}@${ROUTER_WAN_IP}" true 2>/dev/null; do
    TRIES=$((TRIES + 1))
    if (( TRIES > 36 )); then
        echo "Aviso: roteador ainda não respondeu por SSH após 3min. Confira com ./06-status.sh mais tarde."
        break
    fi
    sleep 5
done
sleep 15   # tempo extra para o runcmd (pacotes + NAT) terminar após o SSH subir

banner "06-status.sh"
bash "$SCRIPT_DIR/06-status.sh" <<< "n"

echo
echo -e "\e[1;32mLab pronto — VMs, rede e internet já configurados.\e[0m Acesso:"
echo
echo "  ssh ${VM_USER}@${ROUTER_WAN_IP}                                   # roteador (direto)"
echo "  ssh -J ${VM_USER}@${ROUTER_WAN_IP} ${VM_USER}@<IP-da-VM>            # VMs do lab (via ProxyJump)"
echo
for vm in "${VM_NAMES[@]}"; do
    echo "  $vm -> ${VM_IP[$vm]}   [${VM_ROLE[$vm]}]"
done
echo
echo "As 5 VMs já se enxergam entre si (SSH sem senha, chave do cluster)"
echo "e já têm internet (NAT automático pelo '$ROUTER_NAME'). Próximo"
echo "passo: instalar o SeaweedFS manualmente — veja o README.md, seção"
echo "'Próximos passos'."
