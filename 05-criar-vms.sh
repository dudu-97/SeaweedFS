#!/usr/bin/env bash
# =====================================================================
# 05-criar-vms.sh — define e inicia:
#   - as 5 VMs Ubuntu (master1/2/3 + vol1/2) via virt-install, na rede
#     isolada "seaweedfs-lab", com IP estático já embutido no seed
#   - a VM swfs-router (Ubuntu), com 2 NICs (WAN "default" + LAN
#     isolada), já com IP forwarding + NAT automatizados via cloud-init
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-config.env"

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

command -v virt-install >/dev/null 2>&1 || die "Instale: sudo apt install virtinst"

virsh net-info "$NET_NAME" >/dev/null 2>&1 || die "Rede '$NET_NAME' não existe. Rode antes: ./03-configurar-rede.sh"
if [[ "$(virsh net-info "$NET_NAME" | awk '/^Active/{print $2}')" != "yes" ]]; then
    log "Rede '$NET_NAME' inativa, iniciando..."
    virsh net-start "$NET_NAME"
fi

# --- as 5 VMs Ubuntu do cluster ---------------------------------------
for vm in "${VM_NAMES[@]}"; do
    if virsh dominfo "$vm" >/dev/null 2>&1; then
        warn "$vm já existe no libvirt, pulando (rode 07-destruir-lab.sh antes se quiser recriar)."
        continue
    fi

    VM_DIR="$LAB_DIR/$vm"
    OS_DISK="$VM_DIR/${vm}-os.qcow2"
    DATA_DISK="$VM_DIR/${vm}-data.qcow2"
    SEED_ISO="$VM_DIR/${vm}-seed.iso"

    for f in "$OS_DISK" "$DATA_DISK" "$SEED_ISO"; do
        [[ -f "$f" ]] || die "$f não encontrado. Rode antes: ./02-criar-discos.sh e ./04-gerar-cloud-init.sh"
    done

    log "Criando VM: $vm [${VM_ROLE[$vm]}] (IP ${VM_IP[$vm]}, MAC ${VM_MAC[$vm]})"
    virt-install \
        --name "$vm" \
        --memory "$VM_RAM_MB" \
        --vcpus "$VM_VCPUS" \
        --os-variant "$OS_VARIANT" \
        --disk path="$OS_DISK",format=qcow2,bus=virtio \
        --disk path="$DATA_DISK",format=qcow2,bus=virtio \
        --disk path="$SEED_ISO",device=cdrom \
        --network network="$NET_NAME",mac="${VM_MAC[$vm]}",model=virtio \
        --graphics none \
        --console pty,target_type=serial \
        --import \
        --noautoconsole
done

# --- VM roteador (Ubuntu, provisionada por cloud-init) -----------------
if virsh dominfo "$ROUTER_NAME" >/dev/null 2>&1; then
    warn "$ROUTER_NAME já existe no libvirt, pulando."
else
    ROUTER_DIR="$LAB_DIR/$ROUTER_NAME"
    ROUTER_DISK="$ROUTER_DIR/${ROUTER_NAME}-os.qcow2"
    ROUTER_SEED_ISO="$ROUTER_DIR/${ROUTER_NAME}-seed.iso"

    for f in "$ROUTER_DISK" "$ROUTER_SEED_ISO"; do
        [[ -f "$f" ]] || die "$f não encontrado. Rode antes: ./02-criar-discos.sh e ./04-gerar-cloud-init.sh"
    done

    log "Criando VM: $ROUTER_NAME (WAN ${ROUTER_WAN_IP} / LAN ${ROUTER_LAN_IP})"
    virt-install \
        --name "$ROUTER_NAME" \
        --memory "$ROUTER_RAM_MB" \
        --vcpus "$ROUTER_VCPUS" \
        --os-variant "$OS_VARIANT" \
        --disk path="$ROUTER_DISK",format=qcow2,bus=virtio \
        --disk path="$ROUTER_SEED_ISO",device=cdrom \
        --network network="$ROUTER_WAN_NETWORK",mac="$ROUTER_WAN_MAC",model=virtio \
        --network network="$NET_NAME",mac="$ROUTER_LAN_MAC",model=virtio \
        --graphics none \
        --console pty,target_type=serial \
        --import \
        --noautoconsole

    log "$ROUTER_NAME criada: 1ª interface = WAN (rede '$ROUTER_WAN_NETWORK', IP $ROUTER_WAN_IP), 2ª = LAN (rede '$NET_NAME', IP $ROUTER_LAN_IP)."
fi

log "VMs criadas. Aguarde 1-2 min o cloud-init terminar e confira com: ./06-status.sh"
