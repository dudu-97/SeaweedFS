#!/usr/bin/env bash
# =====================================================================
# 03-configurar-rede.sh — cria a rede ISOLADA do lab no libvirt.
#
# É só um switch L2 (bridge), sem <ip>/<dhcp>: sem NAT, sem DHCP, sem
# rota para fora. Quem dá saída para a internet é a VM swfs-router
# (BSD), que fica com uma perna nesta rede (LAN) e outra na rede
# "default" do KVM (WAN, NAT). Os IPs das VMs Ubuntu são estáticos,
# definidos via cloud-init no passo 04 — não há DHCP para gerenciar aqui.
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-config.env"

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

command -v virsh >/dev/null 2>&1 || die "Instale libvirt-clients / virsh."

if virsh net-info "$NET_NAME" >/dev/null 2>&1; then
    warn "Rede '$NET_NAME' já existe, pulando definição."
else
    log "Definindo rede isolada '$NET_NAME' (bridge $NET_BRIDGE, sem NAT/DHCP)"
    NET_XML="$LAB_DIR/.${NET_NAME}.xml"
    cat > "$NET_XML" <<EOF
<network>
  <name>${NET_NAME}</name>
  <bridge name='${NET_BRIDGE}' stp='on' delay='0'/>
</network>
EOF
    virsh net-define "$NET_XML"
    rm -f "$NET_XML"
fi

if [[ "$(virsh net-info "$NET_NAME" | awk '/^Active/{print $2}')" != "yes" ]]; then
    log "Iniciando rede '$NET_NAME'..."
    virsh net-start "$NET_NAME"
fi
virsh net-autostart "$NET_NAME" >/dev/null 2>&1 || true

# A rede WAN do roteador (ex: "default") precisa existir e estar ativa
virsh net-info "$ROUTER_WAN_NETWORK" >/dev/null 2>&1 || die "Rede WAN '$ROUTER_WAN_NETWORK' não existe no libvirt."
if [[ "$(virsh net-info "$ROUTER_WAN_NETWORK" | awk '/^Active/{print $2}')" != "yes" ]]; then
    log "Iniciando rede WAN '$ROUTER_WAN_NETWORK'..."
    virsh net-start "$ROUTER_WAN_NETWORK"
fi

# Reserva um IP fixo por MAC para a perna WAN do roteador na rede WAN.
# Sem isso, o IP do roteador nessa rede seria imprevisível, e você não
# teria como alcançar o lab isolado via SSH a partir do host.
WAN_NET_XML="$(virsh net-dumpxml "$ROUTER_WAN_NETWORK")"
WAN_HOST_XML="<host mac='${ROUTER_WAN_MAC}' name='${ROUTER_NAME}-wan' ip='${ROUTER_WAN_IP}'/>"
if grep -q "mac='${ROUTER_WAN_MAC}'" <<< "$WAN_NET_XML"; then
    warn "Reserva de IP WAN do roteador (MAC ${ROUTER_WAN_MAC}) já existe, pulando."
else
    log "Reservando ${ROUTER_WAN_IP} para $ROUTER_NAME (MAC ${ROUTER_WAN_MAC}) na rede '$ROUTER_WAN_NETWORK'"
    WAN_UPDATE_ARGS=(--config)
    [[ "$(virsh net-info "$ROUTER_WAN_NETWORK" | awk '/^Active/{print $2}')" == "yes" ]] && WAN_UPDATE_ARGS=(--live --config)
    # A checagem acima (grep no dumpxml) cobre o caso comum, mas não é à
    # prova de falhas (ex: a reserva foi adicionada por uma execução
    # anterior como root/sudo, cujo estado nem sempre bate 1:1 com o que
    # este usuário enxerga). Se o libvirt recusar por já existir, trata
    # como sucesso em vez de abortar o deploy inteiro por causa disso.
    if WAN_UPDATE_OUT="$(virsh net-update "$ROUTER_WAN_NETWORK" add-last ip-dhcp-host "$WAN_HOST_XML" "${WAN_UPDATE_ARGS[@]}" 2>&1)"; then
        :
    elif grep -qi "already exists" <<< "$WAN_UPDATE_OUT"; then
        warn "Reserva de IP WAN (MAC ${ROUTER_WAN_MAC}) já existia em '$ROUTER_WAN_NETWORK' (libvirt recusou duplicar) — seguindo em frente."
    else
        die "Falha ao reservar IP WAN em '$ROUTER_WAN_NETWORK': $WAN_UPDATE_OUT"
    fi
fi

log "Rede isolada '$NET_NAME' pronta (${NET_GATEWAY%.*}.0/${NET_PREFIX}, gateway = $ROUTER_NAME em $ROUTER_LAN_IP)."
log "Rede WAN do roteador: '$ROUTER_WAN_NETWORK' (NAT do KVM), IP fixo $ROUTER_WAN_IP — use-o para SSH/ProxyJump."
