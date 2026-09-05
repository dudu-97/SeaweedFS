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
banner "Aguardando o SeaweedFS instalar e subir nas 5 VMs (até ~5min)"
TRIES=0
STATUS_OUT=""
while (( TRIES < 20 )); do
    STATUS_OUT=$(bash "$SCRIPT_DIR/06-status.sh" <<< "n" 2>&1) || true
    grep -q "Todos os serviços responderam HTTP 200" <<< "$STATUS_OUT" && break
    TRIES=$((TRIES + 1))
    sleep 15
done

banner "06-status.sh"
echo "$STATUS_OUT"

banner "Aplicando ratio de erasure coding ${EC_DATA_SHARDS}+${EC_PARITY_SHARDS} (Enterprise)"
EC_MASTER="${MASTER_HOSTS[0]}"
# O filer pode ainda estar de boot/reiniciando bem nesse instante mesmo
# com o ./06-status.sh já 200 em tudo (ex: susceptível a corrida com o
# Postgres) -- tenta algumas vezes antes de desistir e só avisar.
EC_TRIES=0
EC_DONE=false
until $EC_DONE || (( EC_TRIES >= 6 )); do
    if EC_OUT=$(ssh $SSH_OPTS "${VM_USER}@${VM_IP[$EC_MASTER]}" \
        "echo 'ec.config -set -dataShards=${EC_DATA_SHARDS} -parityShards=${EC_PARITY_SHARDS}' | weed shell -master=localhost:${SEAWEED_MASTER_PORT} 2>&1" 2>&1) \
        && grep -qi "ratio set" <<< "$EC_OUT"; then
        echo "$EC_OUT"
        EC_DONE=true
    else
        EC_TRIES=$((EC_TRIES + 1))
        sleep 10
    fi
done
if ! $EC_DONE; then
    echo "Aviso: não consegui aplicar o ratio de EC depois de várias tentativas -- rode manualmente depois:"
    echo "  ssh ${VM_USER}@${VM_IP[$EC_MASTER]} \"echo 'ec.config -set -dataShards=${EC_DATA_SHARDS} -parityShards=${EC_PARITY_SHARDS}' | weed shell -master=localhost:${SEAWEED_MASTER_PORT}\""
    echo "Último erro: ${EC_OUT:-desconhecido}"
fi

echo
echo -e "\e[1;32mLab pronto — cluster SeaweedFS de pé (master/volume/filer/S3).\e[0m Acesso:"
echo
echo "  ssh ${VM_USER}@${ROUTER_WAN_IP}                                                     # roteador (direto)"
echo "  ssh -o ProxyCommand=\"ssh -W %h:%p ${VM_USER}@${ROUTER_WAN_IP}\" ${VM_USER}@<IP-da-VM>   # VMs do lab"
echo
for vm in "${VM_NAMES[@]}"; do
    echo "  $vm -> ${VM_IP[$vm]}   [${VM_ROLE[$vm]}]"
done
echo
echo "Se algum serviço ainda aparecer DOWN acima, é o download do binário"
echo "do SeaweedFS ainda em andamento — rode './06-status.sh' de novo em"
echo "1-2 min. Veja o README.md para a arquitetura e os endpoints."
