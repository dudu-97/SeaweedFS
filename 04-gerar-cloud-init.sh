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

# --- URL de download do binário do SeaweedFS Enterprise (pré-instalado
# via cloud-init) --- mesmo binário `weed` da edição open-source, só que
# de outro repositório de releases. Sem licença configurada, roda com o
# trial padrão automático (abaixo de 25TB é livre de licença; a única
# limitação é a janela de retenção do Data Recovery, 1h no trial).
if [[ "$SEAWEED_VERSION" == "latest" ]]; then
    SEAWEED_DOWNLOAD_URL="https://github.com/${SEAWEED_ENTERPRISE_REPO}/releases/latest/download/${SEAWEED_ENTERPRISE_ASSET}"
else
    SEAWEED_DOWNLOAD_URL="https://github.com/${SEAWEED_ENTERPRISE_REPO}/releases/download/${SEAWEED_VERSION}/${SEAWEED_ENTERPRISE_ASSET}"
fi
log "SeaweedFS Enterprise será pré-instalado via cloud-init: $SEAWEED_DOWNLOAD_URL"

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
for vm in "${MASTER_HOSTS[@]}"; do
    MASTER_PEERS+="${VM_IP[$vm]}:${SEAWEED_MASTER_PORT},"
done
MASTER_PEERS="${MASTER_PEERS%,}"
log "Masters do cluster: $MASTER_PEERS"

# --- lista de filers (ip:porta) -- cada master roda um filer junto, o
# s3front standalone usa essa lista pra falar com qualquer um deles ----
FILER_PEERS=""
for vm in "${MASTER_HOSTS[@]}"; do
    FILER_PEERS+="${VM_IP[$vm]}:${SEAWEED_FILER_PORT},"
done
FILER_PEERS="${FILER_PEERS%,}"
log "Filers do cluster: $FILER_PEERS"

# Diretório de estado no disco de SO, para papéis sem 2º disco (master,
# admin, s3front) -- só os volume nodes têm disco de dados dedicado.
STATE_DIR="/var/lib/seaweedfs"

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
    <thead><tr><th>Chave</th><th>Tamanho</th><th>Modificado</th><th></th></tr></thead>
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
  <legend>5. Métricas do bucket (SeaweedFS_s3_bucket_*)</legend>
  <label>Endpoint de métricas (Prometheus — porta separada da API S3)
    <input type="text" id="metricsEndpoint" value="">
  </label>
  <button onclick="checkBucketMetrics()">Consultar métricas</button>
  <table id="metricsTable">
    <thead><tr><th>Métrica</th><th>Valor</th></tr></thead>
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
document.getElementById('metricsEndpoint').value = window.location.protocol + '//' + window.location.hostname + ':9327/metrics';

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
      const btn = document.createElement('button');
      btn.textContent = 'Baixar';
      btn.onclick = () => downloadObject(obj.Key);
      tr.innerHTML = `<td>${obj.Key}</td><td>${obj.Size} B</td><td>${new Date(obj.LastModified).toLocaleString()}</td>`;
      const td = document.createElement('td');
      td.appendChild(btn);
      tr.appendChild(td);
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
      tr.innerHTML = `<td>${v.Key}</td><td style="font-family:monospace">${v.VersionId}</td><td>${v.type}</td><td>${v.IsLatest ? 'sim' : 'não'}</td><td>${new Date(v.LastModified).toLocaleString()}</td>`;
      const td = document.createElement('td');
      // delete marker não tem conteúdo -- não dá pra baixar nem restaurar, só apagar
      if (v.type === 'Versão') {
        const dlBtn = document.createElement('button');
        dlBtn.textContent = 'Baixar';
        dlBtn.onclick = () => downloadObject(v.Key, v.VersionId);
        td.appendChild(dlBtn);

        if (!v.IsLatest) {
          const restoreBtn = document.createElement('button');
          restoreBtn.textContent = 'Restaurar como atual';
          restoreBtn.onclick = () => restoreVersion(v.Key, v.VersionId);
          td.appendChild(restoreBtn);
        }
      }
      const delBtn = document.createElement('button');
      delBtn.textContent = 'Apagar esta versão';
      delBtn.onclick = () => deleteVersion(v.Key, v.VersionId);
      td.appendChild(delBtn);
      tr.appendChild(td);
      tbody.appendChild(tr);
    });
    log(`OK — ${rows.length} entrada(s) (versões + delete markers). "Apagar esta versão" remove só aquele VersionId específico — bem diferente de apagar a chave normal, que (com versionamento ligado) só cria um delete marker novo em vez de sumir com o histórico.`);
  });
}

function downloadObject(key, versionId) {
  if (!s3) { log('ERRO: clique em "Conectar" primeiro.'); return; }
  const bucket = document.getElementById('bucket').value.trim();
  const params = { Bucket: bucket, Key: key };
  if (versionId) params.VersionId = versionId;

  log(`GET ${bucket}/${key}${versionId ? '?versionId=' + versionId : ''}...`);
  s3.getObject(params, (err, data) => {
    if (err) { log(`FALHOU: ${err.message}`); return; }
    const blob = new Blob([data.Body], { type: data.ContentType || 'application/octet-stream' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = key.split('/').pop();
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
    log(`OK — baixado (${blob.size} bytes)${versionId ? ', versão ' + versionId : ', versão atual'}.`);
  });
}

function restoreVersion(key, versionId) {
  if (!s3) { log('ERRO: clique em "Conectar" primeiro.'); return; }
  const bucket = document.getElementById('bucket').value.trim();

  log(`GET ${bucket}/${key}?versionId=${versionId} (lendo o conteúdo da versão antiga)...`);
  s3.getObject({ Bucket: bucket, Key: key, VersionId: versionId }, (err, data) => {
    if (err) { log(`FALHOU ao ler a versão: ${err.message}`); return; }
    log(`PUT ${bucket}/${key} (gravando esse conteúdo como versão nova/atual)...`);
    s3.putObject({ Bucket: bucket, Key: key, Body: data.Body, ContentType: data.ContentType }, (err2, data2) => {
      if (err2) { log(`FALHOU ao restaurar: ${err2.message}`); return; }
      log(`OK — versão ${versionId} virou a atual (novo ETag=${data2.ETag}). O S3 não "reverte" de verdade — isso cria uma versão NOVA com o conteúdo antigo; o histórico continua íntegro, nada foi apagado.`);
      listVersions();
      listObjects();
    });
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

function checkBucketMetrics() {
  const bucket = document.getElementById('bucket').value.trim();
  const url = document.getElementById('metricsEndpoint').value.trim();

  log(`GET ${url} (Prometheus /metrics, filtrando bucket="${bucket}")...`);
  fetch(url).then(r => {
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return r.text();
  }).then(text => {
    const wanted = ['SeaweedFS_s3_bucket_size_bytes', 'SeaweedFS_s3_bucket_physical_size_bytes', 'SeaweedFS_s3_bucket_quota_bytes', 'SeaweedFS_s3_bucket_read_only'];
    const tbody = document.querySelector('#metricsTable tbody');
    tbody.innerHTML = '';
    let found = 0;
    text.split('\n').forEach(line => {
      if (!line || line.startsWith('#')) return;
      const m = line.match(/^(\S+?)\{([^}]*)\}\s+([0-9.eE+-]+)/);
      if (!m) return;
      const [, name, labels, value] = m;
      if (!wanted.includes(name) || !labels.includes(`bucket="${bucket}"`)) return;
      found++;
      const tr = document.createElement('tr');
      tr.innerHTML = `<td>${name}</td><td>${value}</td>`;
      tbody.appendChild(tr);
    });
    log(found ? `OK — ${found} métrica(s) pro bucket "${bucket}".` : `Nenhuma métrica encontrada pro bucket "${bucket}" ainda (o coletor demora alguns segundos após a primeira atividade, ou confira o nome do bucket).`);
  }).catch(err => {
    log(`FALHOU: ${err.message}. Se for erro de rede sem detalhe (CORS), o navegador bloqueia fetch() entre portas diferentes sem cabeçalho Access-Control-Allow-Origin — teste via terminal: curl ${url} | grep bucket`);
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

    # --- que papel(is) esta VM tem ------------------------------------
    IS_MASTER=false
    for m in "${MASTER_HOSTS[@]}"; do [[ "$vm" == "$m" ]] && IS_MASTER=true; done
    IS_VOLUME=false
    for n in "${VOLUME_NODES[@]}"; do [[ "$vm" == "$n" ]] && IS_VOLUME=true; done
    IS_S3FRONT=false
    for s in "${S3FRONT_HOSTS[@]}"; do [[ "$vm" == "$s" ]] && IS_S3FRONT=true; done
    IS_PGSQL=false
    [[ "$vm" == "$PGSQL_HOST" ]] && IS_PGSQL=true

    # pacotes extras por papel (a lista base -- curl/tar/e2fsprogs/python3
    # -- é igual pra todas as VMs, ver mais abaixo)
    EXTRA_PACKAGES=""
    $IS_PGSQL && EXTRA_PACKAGES="  - postgresql"

    # 2º disco (/dev/vdb) só existe nos volume nodes -- as demais VMs não
    # têm VM_DATA_DISK_SIZE preenchido em 00-config.env, então não têm
    # esse disco anexado (ver 02-criar-discos.sh e 05-criar-vms.sh).
    DATA_DISK_RUNCMD=""
    if $IS_VOLUME; then
        DATA_DISK_RUNCMD="
  # --- disco de dados: formata (1x), monta em ${DATA_MOUNT_DIR} e dá o
  # dono certo ao ${VM_USER} -- sem isso, \"weed volume\" falha com
  # \"permission denied\" ao criar suas pastas de estado.
  - [ bash, -c, \"blkid ${DATA_DISK_DEVICE} >/dev/null 2>&1 || mkfs.ext4 -F -L swfs-data ${DATA_DISK_DEVICE}\" ]
  - mkdir -p ${DATA_MOUNT_DIR}
  - [ bash, -c, \"grep -q '^LABEL=swfs-data' /etc/fstab || echo 'LABEL=swfs-data ${DATA_MOUNT_DIR} ext4 defaults 0 2' >> /etc/fstab\" ]
  - mount -a
  - chown ${VM_USER}:${VM_USER} ${DATA_MOUNT_DIR}"
    fi

    # --- unidades systemd + runcmd do(s) papel(is) desta VM -----------
    # Escritas em /etc (não em $HOME), então não precisam de "defer".
    WEED_UNITS=""
    WEED_RUNCMD=""

    if $IS_MASTER; then
        WEED_UNITS+="
  - path: /etc/systemd/system/weed-master.service
    permissions: '0644'
    content: |
      [Unit]
      Description=SeaweedFS Master
      After=network-online.target
      Wants=network-online.target

      [Service]
      ExecStart=/usr/local/bin/weed master -mdir=${STATE_DIR}/master -ip=${VM_IP[$vm]} -ip.bind=0.0.0.0 -peers=${MASTER_PEERS} -defaultReplication=${MASTER_DEFAULT_REPLICATION}
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
"
        WEED_RUNCMD+="
  - mkdir -p ${STATE_DIR}/master
  - systemctl daemon-reload
  - /usr/local/bin/svc-enable-now.sh weed-master.service"

        # Todo master roda um filer junto (era 1 VM dedicada antes; agora
        # os 3 masters/filers dividem carga e o s3front fala com qualquer
        # um deles). Metadado vai pro Postgres (pgsql01), não LevelDB
        # local -- é o gargalo de concorrência citado pela empresa.
        # O filer.toml é gerado ONE-SHOT via `weed scaffold` (contém o
        # template padrão inteiro, com [postgres] desabilitado); a
        # conexão de verdade entra via variável de ambiente no service
        # (WEED_POSTGRES_*), que sobrescreve só os campos citados --
        # convenção documentada em `weed scaffold -h`.
        WEED_UNITS+="
  - path: /etc/systemd/system/weed-filer.service
    permissions: '0644'
    content: |
      [Unit]
      Description=SeaweedFS Filer (metadados no Postgres, sem S3 embutido)
      After=network-online.target weed-master.service
      Wants=network-online.target

      [Service]
      Environment=WEED_POSTGRES_ENABLED=true
      Environment=WEED_POSTGRES_HOSTNAME=${VM_IP[$PGSQL_HOST]}
      Environment=WEED_POSTGRES_PORT=${PGSQL_PORT}
      Environment=WEED_POSTGRES_USERNAME=${PGSQL_USER}
      Environment=WEED_POSTGRES_PASSWORD=${PGSQL_PASSWORD}
      Environment=WEED_POSTGRES_DATABASE=${PGSQL_DB}
      Environment=WEED_LEVELDB2_ENABLED=false
      ExecStart=/usr/local/bin/weed filer -master=${MASTER_PEERS} -ip=${VM_IP[$vm]} -ip.bind=0.0.0.0
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
"
        WEED_RUNCMD+="
  - mkdir -p /etc/seaweedfs
  - /usr/local/bin/weed scaffold -config=filer -output=/etc/seaweedfs/
  - systemctl daemon-reload
  - /usr/local/bin/svc-enable-now.sh weed-filer.service"
    fi

    if $IS_VOLUME; then
        for ((i = 0; i < VOLUME_PROCS_PER_NODE; i++)); do
            VPORT=$((SEAWEED_VOLUME_BASE_PORT + i))
            WEED_UNITS+="
  - path: /etc/systemd/system/weed-volume${i}.service
    permissions: '0644'
    content: |
      [Unit]
      Description=SeaweedFS Volume Server ${i} (disco simulado ${i} de ${VOLUME_PROCS_PER_NODE})
      After=network-online.target
      Wants=network-online.target

      [Service]
      ExecStart=/usr/local/bin/weed volume -dir=${DATA_MOUNT_DIR}/volume${i} -mserver=${MASTER_PEERS} -ip=${VM_IP[$vm]} -ip.bind=0.0.0.0 -dataCenter=dc1 -rack=${VM_RACK[$vm]} -port=${VPORT}
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
"
            WEED_RUNCMD+="
  - mkdir -p ${DATA_MOUNT_DIR}/volume${i}"
        done
        WEED_RUNCMD+="
  - systemctl daemon-reload"
        for ((i = 0; i < VOLUME_PROCS_PER_NODE; i++)); do
            WEED_RUNCMD+="
  - /usr/local/bin/svc-enable-now.sh weed-volume${i}.service"
        done
    fi

    if $IS_S3FRONT; then
        WEED_UNITS+="
  - path: /etc/systemd/system/weed-s3.service
    permissions: '0644'
    content: |
      [Unit]
      Description=SeaweedFS S3 Gateway (standalone, fala com os filers dos masters)
      After=network-online.target
      Wants=network-online.target

      [Service]
      ExecStart=/usr/local/bin/weed s3 -filer=${FILER_PEERS} -ip=${VM_IP[$vm]} -ip.bind=0.0.0.0 -port=${SEAWEED_S3_PORT} -config=${STATE_DIR}/s3.json -metricsPort=${SEAWEED_S3_METRICS_PORT}
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target

  # Identidade S3 (accessKey/secretKey de 00-config.env).
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
  - mkdir -p ${STATE_DIR}
  - cp /root/s3.json ${STATE_DIR}/s3.json
  - chmod 600 ${STATE_DIR}/s3.json
  - systemctl daemon-reload
  - /usr/local/bin/svc-enable-now.sh weed-s3.service"
    fi

    if $IS_PGSQL; then
        # Postgres do apt já vem só ouvindo em localhost -- abre pra rede
        # isolada do lab (só ela, não pro mundo) e cria o role/database
        # que os filers usam. Idempotente: refaz sem erro se rodar de novo.
        WEED_RUNCMD+="
  - [ bash, -c, \"sed -i \\\"s/^#\\\\?listen_addresses.*/listen_addresses = '*'/\\\" /etc/postgresql/*/main/postgresql.conf\" ]
  - [ bash, -c, \"grep -q '${NET_GATEWAY%.*}.0/${NET_PREFIX}' /etc/postgresql/*/main/pg_hba.conf || echo 'host    all             all             ${NET_GATEWAY%.*}.0/${NET_PREFIX}        scram-sha-256' >> /etc/postgresql/*/main/pg_hba.conf\" ]
  - systemctl restart postgresql
  - [ bash, -c, \"sudo -u postgres psql -tc \\\"SELECT 1 FROM pg_roles WHERE rolname='${PGSQL_USER}'\\\" | grep -q 1 || sudo -u postgres psql -c \\\"CREATE USER ${PGSQL_USER} WITH PASSWORD '${PGSQL_PASSWORD}';\\\"\" ]
  - [ bash, -c, \"sudo -u postgres psql -tc \\\"SELECT 1 FROM pg_database WHERE datname='${PGSQL_DB}'\\\" | grep -q 1 || sudo -u postgres createdb -O ${PGSQL_USER} ${PGSQL_DB}\" ]
  # A tabela do filer store [postgres] clássico (diferente do [postgres2])
  # não é criada sozinha -- confirmado ao vivo, filer morre com
  # 'relation \\\"filemeta\\\" does not exist' sem isso. Schema exato do
  # comentário do \`weed scaffold -config=filer\`.
  - [ bash, -c, \"sudo -u postgres psql -d ${PGSQL_DB} -tc \\\"SELECT 1 FROM information_schema.tables WHERE table_name='filemeta'\\\" | grep -q 1 || sudo -u postgres psql -d ${PGSQL_DB} -c 'CREATE TABLE filemeta (dirhash BIGINT, name VARCHAR(65535), directory VARCHAR(65535), meta bytea, PRIMARY KEY (dirhash, name));'\" ]
  - [ bash, -c, \"sudo -u postgres psql -d ${PGSQL_DB} -c 'GRANT ALL PRIVILEGES ON TABLE filemeta TO ${PGSQL_USER};'\" ]"
    fi

    if $IS_MASTER && [[ "$vm" == "$ADMIN_HOST" ]]; then
        WEED_UNITS+="
  - path: /etc/systemd/system/weed-admin.service
    permissions: '0644'
    content: |
      [Unit]
      Description=SeaweedFS Admin (dashboard web -- Enterprise, inclui Recovery)
      After=network-online.target weed-master.service
      Wants=network-online.target

      [Service]
      ExecStart=/usr/local/bin/weed admin -port=${SEAWEED_ADMIN_PORT} -master=${MASTER_PEERS} -dataDir=${STATE_DIR}/admin
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
"
        WEED_RUNCMD+="
  - mkdir -p ${STATE_DIR}/admin
  - systemctl daemon-reload
  - /usr/local/bin/svc-enable-now.sh weed-admin.service"
    fi

    if [[ "$vm" == "$WORKER_HOST" ]]; then
        WEED_UNITS+="
  - path: /etc/systemd/system/weed-worker.service
    permissions: '0644'
    content: |
      [Unit]
      Description=SeaweedFS Worker (manutencao em background: EC encode, vacuum, balance)
      After=network-online.target weed-admin.service
      Wants=network-online.target

      [Service]
      ExecStart=/usr/local/bin/weed worker -admin=${VM_IP[$ADMIN_HOST]}:${SEAWEED_ADMIN_PORT} -jobType=all -workingDir=${STATE_DIR}/worker
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
"
        WEED_RUNCMD+="
  - mkdir -p ${STATE_DIR}/worker
  - systemctl daemon-reload
  - /usr/local/bin/svc-enable-now.sh weed-worker.service"
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
  - /usr/local/bin/svc-enable-now.sh weed-upload-demo.service"
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
${EXTRA_PACKAGES}

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

  # Com 13 VMs subindo juntas no mesmo host físico, o D-Bus do systemd
  # de cada VM pode ficar momentaneamente sobrecarregado durante o boot
  # e recusar um "systemctl enable --now" com "Connection timed out" --
  # não é erro de configuração, é contenção de CPU/boot. Esse helper
  # tenta de novo antes de desistir (usado no lugar da chamada direta
  # nos serviços do SeaweedFS, que sobem mais tarde no runcmd, quando a
  # carga de boot costuma estar mais alta).
  - path: /usr/local/bin/svc-enable-now.sh
    permissions: '0755'
    content: |
      #!/bin/sh
      for i in 1 2 3 4 5; do
          systemctl enable --now "\$1" && exit 0
          sleep 3
      done
      exit 1

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
${DATA_DISK_RUNCMD}

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

  - path: /usr/local/bin/svc-enable-now.sh
    permissions: '0755'
    content: |
      #!/bin/sh
      for i in 1 2 3 4 5; do
          systemctl enable --now "\$1" && exit 0
          sleep 3
      done
      exit 1

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
  - /usr/local/bin/svc-enable-now.sh swfs-nat.service
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
