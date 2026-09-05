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
#       * binário `weed` baixado e instalado em /usr/local/bin
#       * o(s) serviço(s) systemd do papel da VM já habilitados e rodando
#         (weed-master / weed-volume / weed-filer+S3, conforme o papel)
#
# A VM swfs-router é gerada logo abaixo, também via cloud-init.
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-config.env"

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

# --- modelo de replicação padrão do cluster (-defaultReplication no master) ---
# Pergunta ANTES do deploy, porque não dá pra trocar depois sem reiniciar os
# masters (e redistribuir os volumes já criados). Sem isso, o SeaweedFS usa
# "000" por padrão -- só soma a capacidade de vol1+vol2, sem nenhuma cópia
# extra (testado e documentado no RELATORIO.md desta sessão). O código tem
# 3 dígitos -- datacenter/rack/node, confirmado ao vivo pela própria
# mensagem de erro do master ("001"->{"node":1}, "010"->{"rack":1},
# "100"->{"dc":1}) -- por isso é "010" que replica em outro RACK, não
# "001" (esse pediria outro SERVIDOR no mesmo rack, que este lab não tem).
# Nesta topologia (1 datacenter, 2 racks, 1 volume server por rack), só
# "000" e "010" fazem sentido de verdade -- os demais códigos exigiriam
# mais racks/datacenters/servidores do que o lab tem.
if [[ -t 0 ]]; then
    echo
    echo "Qual modelo de replicação padrão o cluster deve usar?"
    echo "  1) 000 - nenhuma (padrão do SeaweedFS) - soma a capacidade de vol1+vol2, sem redundância"
    echo "  2) 010 - 1 cópia extra em outro rack - todo arquivo grava em vol1 E replica em vol2 (ou vice-versa)"
    read -r -p "Escolha [1/2] (Enter = 1, mesmo comportamento de antes): " REPLICATION_CHOICE
    case "$REPLICATION_CHOICE" in
        2) MASTER_DEFAULT_REPLICATION="010" ;;
        *) MASTER_DEFAULT_REPLICATION="000" ;;
    esac
else
    warn "Stdin não é um terminal (execução não-interativa) -- usando replicação padrão 000."
    MASTER_DEFAULT_REPLICATION="000"
fi
log "Replicação padrão do cluster: -defaultReplication=$MASTER_DEFAULT_REPLICATION"

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

# --- lista de masters (ip:porta), usada por master/volume/filer -------
MASTER_PEERS=""
for vm in "${VM_NAMES[@]}"; do
    [[ "$vm" == *master* ]] && MASTER_PEERS+="${VM_IP[$vm]}:${SEAWEED_MASTER_PORT},"
done
MASTER_PEERS="${MASTER_PEERS%,}"
log "Masters do cluster: $MASTER_PEERS"

# --- página estática de demo de upload S3 (servida em $UPLOAD_DEMO_HOST) --
# Heredoc com aspas ('ENDHTML') de propósito: o JS abaixo usa template
# literals (`${bucket}`, `${file.name}`...) que NÃO podem passar pela
# expansão do bash do heredoc principal do user-data (que não é quotado,
# porque outros campos como ${VM_IP[$vm]} precisam ser expandidos). Aqui
# só os dois placeholders __S3_ACCESS_KEY__/__S3_SECRET_KEY__ são trocados
# manualmente depois, o resto do arquivo fica literal.
UPLOAD_DEMO_HTML=$(cat <<'ENDHTML'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<title>Demo de upload — SeaweedFS S3</title>
<style>
  body { font-family: -apple-system, Segoe UI, Roboto, sans-serif; max-width: 780px; margin: 40px auto; padding: 0 16px; color: #1a1a1a; }
  h1 { font-size: 1.3rem; }
  fieldset { border: 1px solid #ccc; border-radius: 6px; margin-bottom: 20px; }
  legend { font-weight: 600; padding: 0 6px; }
  label { display: block; margin-top: 10px; font-size: 0.85rem; color: #444; }
  input[type=text], input[type=password] { width: 100%; padding: 6px 8px; margin-top: 2px; box-sizing: border-box; font-family: monospace; }
  button { margin-top: 14px; padding: 8px 16px; cursor: pointer; }
  #log { background: #111; color: #0f0; font-family: monospace; font-size: 0.8rem; padding: 12px; border-radius: 6px; height: 220px; overflow-y: auto; white-space: pre-wrap; }
  table { width: 100%; border-collapse: collapse; margin-top: 10px; }
  th, td { text-align: left; padding: 4px 6px; border-bottom: 1px solid #ddd; font-size: 0.85rem; }
  .warn { background: #fff3cd; border: 1px solid #ffe69c; padding: 10px; border-radius: 6px; font-size: 0.85rem; margin-bottom: 20px; }
</style>
</head>
<body>

<h1>Demo de upload — bucket S3 do SeaweedFS</h1>

<div class="warn">
  <strong>Só para aprendizado.</strong> Esta página coloca a secret key
  direto no JavaScript do navegador — qualquer app "de verdade" (Veeam,
  backend, etc.) faz esse mesmo tipo de chamada, mas guarda a credencial no
  servidor/aplicativo, nunca visível num navegador.
</div>

<fieldset>
  <legend>1. Como o cliente S3 se conecta</legend>
  <label>Endpoint (URL do gateway S3)
    <input type="text" id="endpoint" value="">
  </label>
  <label>Bucket (crie antes com "mc mb", esta página não cria bucket)
    <input type="text" id="bucket" value="meu-bucket-teste">
  </label>
  <label>Access Key
    <input type="text" id="accessKey" value="__S3_ACCESS_KEY__">
  </label>
  <label>Secret Key
    <input type="password" id="secretKey" value="__S3_SECRET_KEY__">
  </label>
  <button onclick="connect()">Conectar</button>
</fieldset>

<fieldset>
  <legend>2. Upload</legend>
  <input type="file" id="fileInput">
  <br>
  <button onclick="upload()">Enviar arquivo</button>
</fieldset>

<fieldset>
  <legend>3. Objetos no bucket</legend>
  <button onclick="listObjects()">Listar</button>
  <table id="objTable">
    <thead><tr><th>Chave</th><th>Tamanho</th><th>Modificado</th></tr></thead>
    <tbody></tbody>
  </table>
</fieldset>

<fieldset>
  <legend>4. Versionamento e lifecycle</legend>
  <button onclick="checkVersioning()">Status do versionamento</button>
  <button onclick="listVersions()">Listar versões (inclui excluídas)</button>
  <table id="verTable">
    <thead><tr><th>Chave</th><th>Version ID</th><th>Tipo</th><th>Atual?</th><th>Modificado</th><th></th></tr></thead>
    <tbody></tbody>
  </table>
</fieldset>

<fieldset>
  <legend>Log (o que a página está mandando pro S3, passo a passo)</legend>
  <div id="log"></div>
</fieldset>

<script src="https://cdn.jsdelivr.net/npm/aws-sdk@2.1691.0/dist/aws-sdk.min.js"></script>
<script>
let s3 = null;

// endpoint padrão: mesmo host de onde esta página foi carregada, porta do
// gateway S3 -- funciona tanto acessando via túnel (localhost) quanto de
// dentro da rede do lab (IP da VM), sem precisar editar a página.
document.getElementById('endpoint').value = window.location.protocol + '//' + window.location.hostname + ':8333';

function log(msg) {
  const el = document.getElementById('log');
  const time = new Date().toLocaleTimeString();
  el.textContent += `[${time}] ${msg}\n`;
  el.scrollTop = el.scrollHeight;
}

function connect() {
  const endpoint = document.getElementById('endpoint').value.trim();
  const accessKeyId = document.getElementById('accessKey').value.trim();
  const secretAccessKey = document.getElementById('secretKey').value.trim();

  AWS.config.update({ accessKeyId, secretAccessKey, region: 'us-east-1' });

  s3 = new AWS.S3({
    endpoint: new AWS.Endpoint(endpoint),
    s3ForcePathStyle: true,   // essencial: SeaweedFS não faz virtual-hosted-style (bucket.dominio.com)
    signatureVersion: 'v4',
  });

  log(`Cliente S3 configurado: endpoint=${endpoint}, path-style=true, accessKey=${accessKeyId}`);
  log('Pronto para enviar/listar. Toda chamada abaixo é HTTP assinado com AWS Signature V4 — mesmo protocolo que o Veeam usa por baixo dos panos.');
}

function upload() {
  if (!s3) { log('ERRO: clique em "Conectar" primeiro.'); return; }
  const file = document.getElementById('fileInput').files[0];
  if (!file) { log('ERRO: escolha um arquivo primeiro.'); return; }
  const bucket = document.getElementById('bucket').value.trim();

  log(`PUT ${bucket}/${file.name} (${file.size} bytes, ${file.type || 'application/octet-stream'})...`);
  s3.putObject({
    Bucket: bucket,
    Key: file.name,
    Body: file,
    ContentType: file.type || 'application/octet-stream',
  }, (err, data) => {
    if (err) { log(`FALHOU: ${err.message}`); return; }
    log(`OK — ETag=${data.ETag}`);
    listObjects();
  });
}

function listObjects() {
  if (!s3) { log('ERRO: clique em "Conectar" primeiro.'); return; }
  const bucket = document.getElementById('bucket').value.trim();

  log(`GET ${bucket}/?list-type=2 (ListObjectsV2)...`);
  s3.listObjectsV2({ Bucket: bucket }, (err, data) => {
    if (err) { log(`FALHOU: ${err.message}`); return; }
    const tbody = document.querySelector('#objTable tbody');
    tbody.innerHTML = '';
    (data.Contents || []).forEach(obj => {
      const tr = document.createElement('tr');
      tr.innerHTML = `<td>${obj.Key}</td><td>${obj.Size} B</td><td>${new Date(obj.LastModified).toLocaleString()}</td>`;
      tbody.appendChild(tr);
    });
    log(`OK — ${(data.Contents || []).length} objeto(s) no bucket.`);
  });
}

function checkVersioning() {
  if (!s3) { log('ERRO: clique em "Conectar" primeiro.'); return; }
  const bucket = document.getElementById('bucket').value.trim();

  log(`GET ${bucket}/?versioning (GetBucketVersioning)...`);
  s3.getBucketVersioning({ Bucket: bucket }, (err, data) => {
    if (err) { log(`FALHOU: ${err.message}`); return; }
    log(`Status = "${data.Status || '(nunca habilitado)'}" — sem "Enabled", o lifecycle não tem versão antiga pra expirar, só o objeto atual.`);
  });
}

function listVersions() {
  if (!s3) { log('ERRO: clique em "Conectar" primeiro.'); return; }
  const bucket = document.getElementById('bucket').value.trim();

  log(`GET ${bucket}/?versions (ListObjectVersions)...`);
  s3.listObjectVersions({ Bucket: bucket }, (err, data) => {
    if (err) { log(`FALHOU: ${err.message}`); return; }
    const rows = [
      ...(data.Versions || []).map(v => ({ ...v, type: 'Versão' })),
      ...(data.DeleteMarkers || []).map(v => ({ ...v, type: 'Delete marker' })),
    ].sort((a, b) => a.Key === b.Key ? new Date(b.LastModified) - new Date(a.LastModified) : a.Key.localeCompare(b.Key));

    const tbody = document.querySelector('#verTable tbody');
    tbody.innerHTML = '';
    rows.forEach(v => {
      const tr = document.createElement('tr');
      const btn = document.createElement('button');
      btn.textContent = 'Apagar esta versão';
      btn.onclick = () => deleteVersion(v.Key, v.VersionId);
      tr.innerHTML = `<td>${v.Key}</td><td style="font-family:monospace">${v.VersionId}</td><td>${v.type}</td><td>${v.IsLatest ? 'sim' : 'não'}</td><td>${new Date(v.LastModified).toLocaleString()}</td>`;
      const td = document.createElement('td');
      td.appendChild(btn);
      tr.appendChild(td);
      tbody.appendChild(tr);
    });
    log(`OK — ${rows.length} entrada(s) (versões + delete markers). "Apagar esta versão" remove só aquele VersionId específico — bem diferente de apagar a chave normal, que (com versionamento ligado) só cria um delete marker novo em vez de sumir com o histórico.`);
  });
}

function deleteVersion(key, versionId) {
  if (!s3) { log('ERRO: clique em "Conectar" primeiro.'); return; }
  const bucket = document.getElementById('bucket').value.trim();

  log(`DELETE ${bucket}/${key}?versionId=${versionId}...`);
  s3.deleteObject({ Bucket: bucket, Key: key, VersionId: versionId }, (err) => {
    if (err) { log(`FALHOU: ${err.message}`); return; }
    log(`OK — versão ${versionId} de "${key}" apagada de vez (esse delete específico não é reversível nem cria delete marker).`);
    listVersions();
  });
}
</script>

</body>
</html>
ENDHTML
)
UPLOAD_DEMO_HTML="${UPLOAD_DEMO_HTML//__S3_ACCESS_KEY__/$S3_ACCESS_KEY}"
UPLOAD_DEMO_HTML="${UPLOAD_DEMO_HTML//__S3_SECRET_KEY__/$S3_SECRET_KEY}"

for vm in "${VM_NAMES[@]}"; do
    VM_DIR="$LAB_DIR/$vm"
    mkdir -p "$VM_DIR"

    PRIVKEY_INDENTED=$(printf '%s\n' "$CLUSTER_PRIVKEY" | indent "      ")
    HOSTS_INDENTED=$(printf '%s' "$HOSTS_ENTRIES" | indent "      ")

    # --- unidades systemd + runcmd do(s) papel(is) desta VM -----------
    # Escritas em /etc (não em $HOME), então não precisam de "defer".
    WEED_UNITS=""
    WEED_RUNCMD=""

    if [[ "$vm" == *master* ]]; then
        WEED_UNITS+="
  - path: /etc/systemd/system/weed-master.service
    permissions: '0644'
    content: |
      [Unit]
      Description=SeaweedFS Master
      After=network-online.target
      Wants=network-online.target

      [Service]
      ExecStart=/usr/local/bin/weed master -mdir=${DATA_MOUNT_DIR}/master -ip=${VM_IP[$vm]} -ip.bind=0.0.0.0 -peers=${MASTER_PEERS} -defaultReplication=${MASTER_DEFAULT_REPLICATION}
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
"
        WEED_RUNCMD+="
  - mkdir -p ${DATA_MOUNT_DIR}/master
  - systemctl daemon-reload
  - systemctl enable --now weed-master.service"
    fi

    if [[ "$vm" == *vol* ]]; then
        WEED_UNITS+="
  - path: /etc/systemd/system/weed-volume.service
    permissions: '0644'
    content: |
      [Unit]
      Description=SeaweedFS Volume Server
      After=network-online.target
      Wants=network-online.target

      [Service]
      ExecStart=/usr/local/bin/weed volume -dir=${DATA_MOUNT_DIR}/volume -mserver=${MASTER_PEERS} -ip=${VM_IP[$vm]} -ip.bind=0.0.0.0 -dataCenter=dc1 -rack=${VM_RACK[$vm]} -port=${SEAWEED_VOLUME_PORT}
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
"
        WEED_RUNCMD+="
  - mkdir -p ${DATA_MOUNT_DIR}/volume
  - systemctl daemon-reload
  - systemctl enable --now weed-volume.service"
    fi

    if [[ "$vm" == "$FILER_HOST" ]]; then
        WEED_UNITS+="
  - path: /etc/systemd/system/weed-filer.service
    permissions: '0644'
    content: |
      [Unit]
      Description=SeaweedFS Filer + API S3
      After=network-online.target weed-volume.service
      Wants=network-online.target

      [Service]
      ExecStart=/usr/local/bin/weed filer -master=${MASTER_PEERS} -ip=${VM_IP[$vm]} -ip.bind=0.0.0.0 -defaultStoreDir=${DATA_MOUNT_DIR}/filer -s3 -s3.config=${DATA_MOUNT_DIR}/filer/s3.json -s3.port=${SEAWEED_S3_PORT}
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target

  # Identidade S3 (accessKey/secretKey de 00-config.env). Escrita em
  # /root (existe desde o boot) em vez de \${DATA_MOUNT_DIR}/filer
  # diretamente: write_files roda ANTES do runcmd que monta o disco de
  # dados, então gravar direto no destino final ficaria escondido pelo
  # mount que vem depois -- o runcmd abaixo copia para o lugar certo
  # só depois do mount.
  - path: /root/s3.json
    permissions: '0600'
    content: |
      {
        \"identities\": [
          {
            \"name\": \"labuser\",
            \"credentials\": [
              {\"accessKey\": \"${S3_ACCESS_KEY}\", \"secretKey\": \"${S3_SECRET_KEY}\"}
            ],
            \"actions\": [\"Admin\", \"Read\", \"Write\"]
          }
        ]
      }
"
        WEED_RUNCMD+="
  - mkdir -p ${DATA_MOUNT_DIR}/filer
  - cp /root/s3.json ${DATA_MOUNT_DIR}/filer/s3.json
  - chmod 600 ${DATA_MOUNT_DIR}/filer/s3.json
  - systemctl daemon-reload
  - systemctl enable --now weed-filer.service"
    fi

    if [[ "$vm" == "$ADMIN_HOST" ]]; then
        WEED_UNITS+="
  - path: /etc/systemd/system/weed-admin.service
    permissions: '0644'
    content: |
      [Unit]
      Description=SeaweedFS Admin (dashboard web)
      After=network-online.target weed-volume.service
      Wants=network-online.target

      [Service]
      ExecStart=/usr/local/bin/weed admin -port=${SEAWEED_ADMIN_PORT} -master=${MASTER_PEERS} -dataDir=${DATA_MOUNT_DIR}/admin
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
"
        WEED_RUNCMD+="
  - mkdir -p ${DATA_MOUNT_DIR}/admin
  - systemctl daemon-reload
  - systemctl enable --now weed-admin.service"
    fi

    if [[ "$vm" == "$UPLOAD_DEMO_HOST" ]]; then
        UPLOAD_DEMO_HTML_INDENTED=$(printf '%s\n' "$UPLOAD_DEMO_HTML" | indent "      ")
        WEED_UNITS+="
  - path: /var/www/upload-demo/index.html
    permissions: '0644'
    content: |
${UPLOAD_DEMO_HTML_INDENTED}

  - path: /etc/systemd/system/weed-upload-demo.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Pagina de demo de upload S3 (estatica, so para teste)
      After=network-online.target
      Wants=network-online.target

      [Service]
      WorkingDirectory=/var/www/upload-demo
      ExecStart=/usr/bin/python3 -m http.server ${SEAWEED_UPLOAD_DEMO_PORT}
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
"
        WEED_RUNCMD+="
  - systemctl daemon-reload
  - systemctl enable --now weed-upload-demo.service"
    fi

    cat > "$VM_DIR/user-data" <<EOF
#cloud-config
hostname: ${vm}
fqdn: ${vm}.${LAB_DOMAIN}
manage_etc_hosts: false

packages:
  - curl
  - tar
  - e2fsprogs
  - python3

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
${WEED_UNITS}
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

  # --- binário do SeaweedFS: baixa com retry (o roteador pode ainda
  # estar de boot quando esta VM já tenta a internet) e instala.
  - [ bash, -c, "command -v weed >/dev/null 2>&1 || { i=0; until curl -fsSL -o /tmp/weed.tar.gz '${SEAWEED_DOWNLOAD_URL}' || [ \$i -ge 36 ]; do i=\$((i+1)); sleep 5; done; tar -xzf /tmp/weed.tar.gz -C /usr/local/bin weed && rm -f /tmp/weed.tar.gz; }" ]
  - [ bash, -c, "weed version || true" ]
${WEED_RUNCMD}
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
