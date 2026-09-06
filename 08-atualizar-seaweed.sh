#!/usr/bin/env bash
# =====================================================================
# 08-atualizar-seaweed.sh — atualiza o binário `weed` (SeaweedFS) nas 5
# VMs do cluster, uma de cada vez (rolling): para só o(s) serviço(s)
# daquela VM, troca o binário, sobe de novo e confere saúde antes de
# seguir pra próxima. Isso evita derrubar o quorum Raft dos masters
# (nunca mais de 1 fora por vez) e evita tirar os dois volumes do ar
# ao mesmo tempo.
#
# Uso:
#   ./08-atualizar-seaweed.sh          -> atualiza para a última
#                                          release do GitHub
#   ./08-atualizar-seaweed.sh 4.46     -> fixa uma versão/tag específica
#
# Antes de trocar, o binário atual de cada VM é salvo em
# /usr/local/bin/weed.bak-<timestamp> -- se algo der errado, o script
# para (não mexe nas VMs seguintes) e mostra o comando exato de rollback
# para a VM em questão.
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-config.env"

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
err()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; }

TARGET_VERSION="${1:-}"
if [[ -z "$TARGET_VERSION" ]]; then
    log "Nenhuma versão informada -- resolvendo a última release do GitHub..."
    TARGET_VERSION="$(curl -fsSL https://api.github.com/repos/seaweedfs/seaweedfs/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')"
    [[ -n "$TARGET_VERSION" ]] || { err "Não consegui resolver a última versão via GitHub API."; exit 1; }
fi
DOWNLOAD_URL="https://github.com/seaweedfs/seaweedfs/releases/download/${TARGET_VERSION}/linux_amd64_large_disk.tar.gz"

# Mesmo padrão de ProxyCommand do 06-status.sh: as 5 VMs do cluster só
# são alcançáveis saltando pelo roteador (rede isolada seaweedfs-lab).
JUMP="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6 -o BatchMode=yes -W %h:%p ${VM_USER}@${ROUTER_WAN_IP}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6 -o BatchMode=yes -o "ProxyCommand=$JUMP")

rssh() { # rssh <ip> <comando remoto>
    ssh -n "${SSH_OPTS[@]}" "${VM_USER}@$1" "$2"
}

get_version() { # get_version <ip>
    rssh "$1" "weed version 2>&1 | head -1" 2>/dev/null || echo "SSH FALHOU"
}

log "Versão alvo: $TARGET_VERSION"
log "URL: $DOWNLOAD_URL"
echo
echo "Versões atuais:"
ANY_UNREACHABLE=0
for vm in "${VM_NAMES[@]}"; do
    ver="$(get_version "${VM_IP[$vm]}")"
    printf "  %-14s %s\n" "$vm" "$ver"
    [[ "$ver" == "SSH FALHOU" ]] && ANY_UNREACHABLE=1
done
echo

if [[ "$ANY_UNREACHABLE" == "1" ]]; then
    err "Pelo menos uma VM não respondeu por SSH -- corrija o acesso antes de atualizar (rode ./06-status.sh)."
    exit 1
fi

read -r -p "Atualizar as 5 VMs para $TARGET_VERSION, uma de cada vez? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Cancelado."; exit 0; }
echo

update_binary() { # update_binary <ip> <backup_path>
    local ip="$1" backup="$2"
    rssh "$ip" "sudo cp -a /usr/local/bin/weed '$backup' && \
        curl -fsSL -o /tmp/weed.tar.gz '${DOWNLOAD_URL}' && \
        sudo tar -xzf /tmp/weed.tar.gz -C /usr/local/bin weed && \
        rm -f /tmp/weed.tar.gz"
}

rollback_hint() { # rollback_hint <ip> <backup_path> <serviços...>
    local ip="$1" backup="$2"; shift 2
    warn "Para reverter em $ip: sudo systemctl stop $*; sudo mv '$backup' /usr/local/bin/weed; sudo systemctl start $*"
}

wait_http() { # wait_http <ip> <porta> <caminho> <rótulo>
    local ip="$1" port="$2" path="$3" label="$4" i=0
    until [[ "$(rssh "$ip" "curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:${port}${path}" 2>/dev/null)" == "200" ]]; do
        i=$((i+1))
        if [[ "$i" -ge 24 ]]; then
            err "$label em $ip não respondeu HTTP 200 em 2min após reiniciar."
            return 1
        fi
        sleep 5
    done
    log "$label em $ip respondeu 200 (ok)."
}

wait_master_leader() { # wait_master_leader <ip>
    local ip="$1" i=0 out=""
    until out="$(rssh "$ip" "curl -s -m 5 http://127.0.0.1:${SEAWEED_MASTER_PORT}/cluster/status" 2>/dev/null)" \
        && grep -oP '(?<="Leader":")[^"]+' <<<"$out" | grep -q .; do
        i=$((i+1))
        if [[ "$i" -ge 24 ]]; then
            err "master em $ip não voltou a ver um líder Raft em 2min após reiniciar."
            return 1
        fi
        sleep 5
    done
    log "master em $ip vê líder do Raft (ok)."
}

# --- 1) masters, um de cada vez -- nunca mais de 1 fora, quorum de 3 preservado
for vm in "${VM_NAMES[@]}"; do
    [[ "$vm" == *master* ]] || continue
    ip="${VM_IP[$vm]}"
    backup="/usr/local/bin/weed.bak-$(date +%Y%m%d%H%M%S)"

    log "== $vm ($ip): parando weed-master, atualizando binário =="
    rssh "$ip" "sudo systemctl stop weed-master"

    if ! update_binary "$ip" "$backup"; then
        err "Falha ao baixar/instalar o binário em $vm."
        rssh "$ip" "sudo systemctl start weed-master" || true
        rollback_hint "$ip" "$backup" weed-master
        exit 1
    fi

    rssh "$ip" "sudo systemctl start weed-master"
    if ! wait_master_leader "$ip"; then
        rollback_hint "$ip" "$backup" weed-master
        exit 1
    fi
done

# --- 2) volumes (+ filer/S3/admin em quem os hospeda), um de cada vez -
for vm in "${VM_NAMES[@]}"; do
    [[ "$vm" == *vol* ]] || continue
    ip="${VM_IP[$vm]}"
    backup="/usr/local/bin/weed.bak-$(date +%Y%m%d%H%M%S)"

    SERVICES=(weed-volume)
    [[ "$vm" == "$FILER_HOST" ]] && SERVICES+=(weed-filer)
    [[ "$vm" == "$ADMIN_HOST" ]] && SERVICES+=(weed-admin)

    log "== $vm ($ip): parando ${SERVICES[*]}, atualizando binário =="
    rssh "$ip" "sudo systemctl stop ${SERVICES[*]}"

    if ! update_binary "$ip" "$backup"; then
        err "Falha ao baixar/instalar o binário em $vm."
        rssh "$ip" "sudo systemctl start ${SERVICES[*]}" || true
        rollback_hint "$ip" "$backup" "${SERVICES[*]}"
        exit 1
    fi

    rssh "$ip" "sudo systemctl start weed-volume"
    if ! wait_http "$ip" "$SEAWEED_VOLUME_PORT" "/status" "volume"; then
        rollback_hint "$ip" "$backup" "${SERVICES[*]}"
        exit 1
    fi

    if [[ "$vm" == "$FILER_HOST" ]]; then
        rssh "$ip" "sudo systemctl start weed-filer"
        if ! wait_http "$ip" "$SEAWEED_FILER_PORT" "/" "filer"; then
            rollback_hint "$ip" "$backup" "${SERVICES[*]}"
            exit 1
        fi
    fi

    if [[ "$vm" == "$ADMIN_HOST" ]]; then
        rssh "$ip" "sudo systemctl start weed-admin"
        if ! wait_http "$ip" "$SEAWEED_ADMIN_PORT" "/" "admin"; then
            rollback_hint "$ip" "$backup" "${SERVICES[*]}"
            exit 1
        fi
    fi
done

echo
log "Atualização concluída. Versões finais:"
for vm in "${VM_NAMES[@]}"; do
    ver="$(get_version "${VM_IP[$vm]}")"
    printf "  %-14s %s\n" "$vm" "$ver"
done
echo
echo "Confira o cluster de ponta a ponta com ./06-status.sh."
echo "Os binários antigos ficaram salvos em /usr/local/bin/weed.bak-* em cada VM"
echo "(apague-os quando tiver certeza de que não vai precisar reverter)."
