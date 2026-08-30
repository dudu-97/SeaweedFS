#!/usr/bin/env bash
# =====================================================================
# 04-gerar-cloud-init.sh — gera, para as 5 VMs Ubuntu do cluster:
#   - o par de chaves exclusivo do cluster (uma vez, reaproveitado)
#   - user-data/meta-data/network-config + seed.iso de cada VM, com:
#       * IP ESTÁTICO (netplan), gateway = swfs-router, DNS público
#       * usuário com senha + SUA chave SSH (acesso host -> VM)
#       * chave privada/pública do cluster em ~/.ssh (VM <-> VM sem senha)
#       * /etc/hosts com todas as VMs + o roteador
#       * ~/.ssh/config sem prompt de host key entre os nós do lab
#       * disco de dados formatado/montado em /data (dono = usuário)
#       * binário `weed` já baixado e instalado em /usr/local/bin
#     (o único passo manual que sobra é rodar os comandos `weed
#     master/volume/filer/admin` -- veja README > Próximos passos)
#
# A VM swfs-router (BSD) NÃO entra aqui: ela é instalada manualmente.
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-config.env"

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

SEED_TOOL=""
if command -v cloud-localds >/dev/null 2>&1; then
    SEED_TOOL="cloud-localds"
elif command -v genisoimage >/dev/null 2>&1; then
    SEED_TOOL="genisoimage"
else
    die "Instale 'cloud-image-utils' (cloud-localds) ou 'genisoimage':
  sudo apt install cloud-image-utils"
fi
log "Gerador de seed ISO: $SEED_TOOL"

# --- URL de download do binário do SeaweedFS (pré-instalado via cloud-init) ---
if [[ "$SEAWEED_VERSION" == "latest" ]]; then
    SEAWEED_DOWNLOAD_URL="https://github.com/seaweedfs/seaweedfs/releases/latest/download/linux_amd64_large_disk.tar.gz"
else
    SEAWEED_DOWNLOAD_URL="https://github.com/seaweedfs/seaweedfs/releases/download/${SEAWEED_VERSION}/linux_amd64_large_disk.tar.gz"
fi
log "SeaweedFS será pré-instalado via cloud-init: $SEAWEED_DOWNLOAD_URL"

# --- chave SSH do HOST (para você acessar as VMs) ---------------------
if [[ ! -f "$SSH_PUBKEY_PATH" ]]; then
    warn "Chave SSH do host não encontrada em $SSH_PUBKEY_PATH, gerando uma nova..."
    ssh-keygen -t rsa -b 4096 -N "" -f "${SSH_PUBKEY_PATH%.pub}"
fi
HOST_PUBKEY="$(cat "$SSH_PUBKEY_PATH")"
log "Chave do host: $SSH_PUBKEY_PATH"

# --- chave SSH exclusiva do CLUSTER (para as VMs se acessarem entre si) ---
mkdir -p "$LAB_DIR"
if [[ ! -f "$CLUSTER_KEY_PATH" ]]; then
    log "Gerando par de chaves do cluster em $CLUSTER_KEY_PATH"
    ssh-keygen -t rsa -b 4096 -N "" -f "$CLUSTER_KEY_PATH" -C "cluster-swfs-lab"
else
    log "Reaproveitando par de chaves do cluster já existente em $CLUSTER_KEY_PATH"
fi
CLUSTER_PRIVKEY="$(cat "$CLUSTER_KEY_PATH")"
CLUSTER_PUBKEY="$(cat "${CLUSTER_KEY_PATH}.pub")"

# indenta um bloco de texto multilinha com o prefixo dado (para YAML)
indent() {
    local prefix="$1"
    while IFS= read -r line; do printf '%s%s\n' "$prefix" "$line"; done
}

# --- monta as linhas de /etc/hosts compartilhadas entre as VMs --------
HOSTS_ENTRIES="${ROUTER_LAN_IP} ${ROUTER_NAME} ${ROUTER_NAME}.${LAB_DOMAIN}"$'\n'
for vm in "${VM_NAMES[@]}"; do
    HOSTS_ENTRIES+="${VM_IP[$vm]} ${vm} ${vm}.${LAB_DOMAIN}"$'\n'
done

for vm in "${VM_NAMES[@]}"; do
    VM_DIR="$LAB_DIR/$vm"
    mkdir -p "$VM_DIR"

    PRIVKEY_INDENTED=$(printf '%s\n' "$CLUSTER_PRIVKEY" | indent "      ")
    HOSTS_INDENTED=$(printf '%s' "$HOSTS_ENTRIES" | indent "      ")

    cat > "$VM_DIR/user-data" <<EOF
#cloud-config
hostname: ${vm}
fqdn: ${vm}.${LAB_DOMAIN}
manage_etc_hosts: false

packages:
  - curl
  - tar
  - e2fsprogs

users:
  - default
  - name: ${VM_USER}
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: false
    ssh_authorized_keys:
      - ${HOST_PUBKEY}
      - ${CLUSTER_PUBKEY}

ssh_pwauth: true
chpasswd:
  expire: false
  users:
    - name: ${VM_USER}
      password: ${VM_PASSWORD}
      type: text
    - name: ubuntu
      password: ${VM_PASSWORD}
      type: text

write_files:
  - path: /etc/hosts
    append: true
    content: |
${HOSTS_INDENTED}

  # defer: true -- essenciais aqui. write_files roda ANTES do usuário
  # ${VM_USER} ser criado (módulo users-groups vem depois); sem defer,
  # gravar em /home/${VM_USER}/.ssh/... falha (diretório não existe
  # ainda) e derruba o write_files inteiro com uma exceção não tratada.
  - path: /home/${VM_USER}/.ssh/id_rsa
    owner: ${VM_USER}:${VM_USER}
    permissions: '0600'
    defer: true
    content: |
${PRIVKEY_INDENTED}

  - path: /home/${VM_USER}/.ssh/id_rsa.pub
    owner: ${VM_USER}:${VM_USER}
    permissions: '0644'
    defer: true
    content: |
      ${CLUSTER_PUBKEY}

  - path: /home/${VM_USER}/.ssh/config
    owner: ${VM_USER}:${VM_USER}
    permissions: '0600'
    defer: true
    content: |
      Host swfs-* 192.168.100.*
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null

runcmd:
  - systemctl enable --now ssh
  - chown -R ${VM_USER}:${VM_USER} /home/${VM_USER}/.ssh
  - chmod 700 /home/${VM_USER}/.ssh

  # --- disco de dados: formata (1x), monta em ${DATA_MOUNT_DIR} e dá o
  # dono certo ao ${VM_USER} -- sem isso, "weed master/volume/filer"
  # falha com "permission denied" ao criar suas pastas de estado.
  - [ bash, -c, "blkid ${DATA_DISK_DEVICE} >/dev/null 2>&1 || mkfs.ext4 -F -L swfs-data ${DATA_DISK_DEVICE}" ]
  - mkdir -p ${DATA_MOUNT_DIR}
  - [ bash, -c, "grep -q '^LABEL=swfs-data' /etc/fstab || echo 'LABEL=swfs-data ${DATA_MOUNT_DIR} ext4 defaults 0 2' >> /etc/fstab" ]
  - mount -a
  - chown ${VM_USER}:${VM_USER} ${DATA_MOUNT_DIR}

  # --- binário do SeaweedFS pré-instalado, pronto para "weed master/
  # volume/filer/admin" (passo manual, veja README > Próximos passos)
  - [ bash, -c, "command -v weed >/dev/null 2>&1 || curl -fsSL '${SEAWEED_DOWNLOAD_URL}' | tar -xz -C /usr/local/bin weed" ]
  - [ bash, -c, "weed version || true" ]
EOF

    cat > "$VM_DIR/meta-data" <<EOF
instance-id: ${vm}
local-hostname: ${vm}
EOF

    # IP estático via netplan, casando pela MAC (nome de interface pode
    # variar entre ensX/enpXsY conforme o barramento; set-name fixa "eth0")
    cat > "$VM_DIR/network-config" <<EOF
network:
  version: 2
  ethernets:
    eth0:
      match:
        macaddress: "${VM_MAC[$vm]}"
      set-name: eth0
      addresses:
        - ${VM_IP[$vm]}/${NET_PREFIX}
      gateway4: ${NET_GATEWAY}
      nameservers:
        addresses: [${NET_DNS// /, }]
EOF

    SEED_ISO="$VM_DIR/${vm}-seed.iso"
    log "$vm: gerando $SEED_ISO (IP estático ${VM_IP[$vm]}/${NET_PREFIX}, gw ${NET_GATEWAY})"
    if [[ "$SEED_TOOL" == "cloud-localds" ]]; then
        cloud-localds --network-config="$VM_DIR/network-config" "$SEED_ISO" "$VM_DIR/user-data" "$VM_DIR/meta-data"
    else
        genisoimage -output "$SEED_ISO" -volid cidata -joliet -rock \
            "$VM_DIR/user-data" "$VM_DIR/meta-data" "$VM_DIR/network-config" >/dev/null
    fi
done

# --- VM roteador (Ubuntu, mesma imagem-base das outras 5) --------------
# Mesmo mecanismo já validado nas 5 VMs acima. IP forwarding + NAT
# (MASQUERADE) para a rede isolada já saem prontos, via write_files +
# um serviço systemd (nada de pacote extra tipo iptables-persistent,
# que pede confirmação interativa no primeiro apt install).
ROUTER_DIR="$LAB_DIR/$ROUTER_NAME"
mkdir -p "$ROUTER_DIR"
ROUTER_LAN_NETWORK="${ROUTER_LAN_IP%.*}.0/${NET_PREFIX}"

cat > "$ROUTER_DIR/user-data" <<EOF
#cloud-config
hostname: ${ROUTER_NAME}
fqdn: ${ROUTER_NAME}.${LAB_DOMAIN}
manage_etc_hosts: false

packages:
  - iptables

users:
  - default
  - name: ${VM_USER}
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: false
    ssh_authorized_keys:
      - ${HOST_PUBKEY}
      - ${CLUSTER_PUBKEY}

ssh_pwauth: true
chpasswd:
  expire: false
  users:
    - name: ${VM_USER}
      password: ${VM_PASSWORD}
      type: text
    - name: ubuntu
      password: ${VM_PASSWORD}
      type: text

write_files:
  - path: /etc/hosts
    append: true
    content: |
${HOSTS_INDENTED}

  - path: /etc/sysctl.d/99-swfs-router.conf
    content: |
      net.ipv4.ip_forward=1

  - path: /etc/systemd/system/swfs-nat.service
    permissions: '0644'
    content: |
      [Unit]
      Description=NAT (MASQUERADE) do lab SeaweedFS para a rede isolada
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/sbin/iptables -t nat -A POSTROUTING -s ${ROUTER_LAN_NETWORK} ! -d ${ROUTER_LAN_NETWORK} -j MASQUERADE
      ExecStop=/usr/sbin/iptables -t nat -D POSTROUTING -s ${ROUTER_LAN_NETWORK} ! -d ${ROUTER_LAN_NETWORK} -j MASQUERADE

      [Install]
      WantedBy=multi-user.target

runcmd:
  - systemctl enable --now ssh
  - chown -R ${VM_USER}:${VM_USER} /home/${VM_USER}/.ssh 2>/dev/null || true
  - sysctl --system
  - systemctl daemon-reload
  - systemctl enable --now swfs-nat.service
EOF

cat > "$ROUTER_DIR/meta-data" <<EOF
instance-id: ${ROUTER_NAME}
local-hostname: ${ROUTER_NAME}
EOF

cat > "$ROUTER_DIR/network-config" <<EOF
network:
  version: 2
  ethernets:
    eth0:
      match:
        macaddress: "${ROUTER_WAN_MAC}"
      set-name: eth0
      dhcp4: true
    eth1:
      match:
        macaddress: "${ROUTER_LAN_MAC}"
      set-name: eth1
      addresses:
        - ${ROUTER_LAN_IP}/${NET_PREFIX}
EOF

ROUTER_SEED_ISO="$ROUTER_DIR/${ROUTER_NAME}-seed.iso"
log "$ROUTER_NAME: gerando $ROUTER_SEED_ISO (WAN=dhcp, LAN=${ROUTER_LAN_IP}/${NET_PREFIX}, NAT automático para ${ROUTER_LAN_NETWORK})"
if [[ "$SEED_TOOL" == "cloud-localds" ]]; then
    cloud-localds --network-config="$ROUTER_DIR/network-config" "$ROUTER_SEED_ISO" "$ROUTER_DIR/user-data" "$ROUTER_DIR/meta-data"
else
    genisoimage -output "$ROUTER_SEED_ISO" -volid cidata -joliet -rock \
        "$ROUTER_DIR/user-data" "$ROUTER_DIR/meta-data" "$ROUTER_DIR/network-config" >/dev/null
fi

log "Cloud-init pronto: IP estático, SSH host->VM, SSH VM<->VM (chave do cluster) e /etc/hosts configurados."
