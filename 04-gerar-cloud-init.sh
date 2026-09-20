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
# Fixo em 000 (MASTER_DEFAULT_REPLICATION no 00-config.env): nenhuma cópia
# extra -- o objetivo do lab é testar erasure coding, não replicação. Sem
# prompt: com rack único, "010" (outro rack) nem seria possível.
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
    # NÃO usa /releases/latest/download: o repo de artefatos publica também
    # releases de outros produtos (ex.: vfs-0.2.x, sem o binário weed), e o
    # "latest" do GitHub pode cair numa delas -> 404 e VMs sem o weed.
    # Em vez disso, acha a release mais recente que realmente tem o asset.
    SEAWEED_RESOLVED_TAG="$(curl -fsSL -m 20 "https://api.github.com/repos/${SEAWEED_ENTERPRISE_REPO}/releases?per_page=30" 2>/dev/null \
        | ASSET="$SEAWEED_ENTERPRISE_ASSET" python3 -c '
import json, os, sys
asset = os.environ["ASSET"]
for r in json.load(sys.stdin):
    if not r.get("draft") and not r.get("prerelease") and any(a["name"] == asset for a in r.get("assets", [])):
        print(r["tag_name"]); break
' 2>/dev/null || true)"
    [[ -n "$SEAWEED_RESOLVED_TAG" ]] || die "Não consegui descobrir a release mais recente com o asset ${SEAWEED_ENTERPRISE_ASSET} em ${SEAWEED_ENTERPRISE_REPO} (API do GitHub fora do ar ou limite de requisições). Fixe SEAWEED_VERSION no 00-config.env (ex.: \"4.47\") e rode de novo."
    log "SeaweedFS Enterprise: 'latest' resolvido para a release ${SEAWEED_RESOLVED_TAG}"
    SEAWEED_DOWNLOAD_URL="https://github.com/${SEAWEED_ENTERPRISE_REPO}/releases/download/${SEAWEED_RESOLVED_TAG}/${SEAWEED_ENTERPRISE_ASSET}"
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
  :root {
    --bg: #f4f5f7;
    --card: #ffffff;
    --border: #e2e4e9;
    --text: #1a1c22;
    --text-dim: #6b7078;
    --accent: #2f5fd6;
    --accent-dim: #eaf0fd;
    --ok: #1f8a4c;
    --warn-bg: #fff6e0;
    --warn-border: #f0d896;
    --danger: #c23b3b;
    --radius: 10px;
  }
  * { box-sizing: border-box; }
  body {
    font-family: -apple-system, "Segoe UI", Roboto, sans-serif;
    background: var(--bg);
    color: var(--text);
    margin: 0;
    padding: 28px 20px 60px;
  }
  .wrap { max-width: 920px; margin: 0 auto; }
  header { display: flex; align-items: baseline; justify-content: space-between; flex-wrap: wrap; gap: 8px; margin-bottom: 4px; }
  h1 { font-size: 1.35rem; margin: 0; }
  .subtitle { font-size: 0.85rem; color: var(--text-dim); margin: 4px 0 18px; }
  .status { display: inline-flex; align-items: center; gap: 6px; font-size: 0.8rem; color: var(--text-dim); }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--danger); display: inline-block; }
  .dot.on { background: var(--ok); }

  .warn { background: var(--warn-bg); border: 1px solid var(--warn-border); padding: 10px 14px; border-radius: var(--radius); font-size: 0.82rem; margin-bottom: 18px; color: #6b5410; }

  .card { background: var(--card); border: 1px solid var(--border); border-radius: var(--radius); padding: 16px 18px; margin-bottom: 16px; }
  .card h2 { font-size: 0.95rem; margin: 0 0 12px; }

  .conn-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 10px 14px; align-items: end; }
  label { display: block; font-size: 0.78rem; color: var(--text-dim); margin-bottom: 4px; }
  input[type=text], input[type=password], select {
    width: 100%; padding: 7px 9px; font-size: 0.85rem; font-family: monospace;
    border: 1px solid var(--border); border-radius: 6px; background: #fbfbfc; color: var(--text);
  }
  input:focus, select:focus { outline: 2px solid var(--accent-dim); border-color: var(--accent); }

  button {
    padding: 8px 16px; font-size: 0.85rem; cursor: pointer;
    border: 1px solid var(--accent); background: var(--accent); color: #fff;
    border-radius: 6px; font-weight: 500;
  }
  button:hover { filter: brightness(1.08); }
  button.secondary { background: #fff; color: var(--accent); }
  button.ghost { background: transparent; color: var(--text-dim); border-color: var(--border); font-weight: 400; padding: 5px 10px; font-size: 0.78rem; }
  button.danger { background: #fff; color: var(--danger); border-color: var(--danger); }

  nav.tabs { display: flex; gap: 6px; margin: 18px 0 14px; flex-wrap: wrap; }
  nav.tabs button {
    background: transparent; color: var(--text-dim); border: 1px solid var(--border);
    border-radius: 999px; padding: 7px 16px; font-weight: 500;
  }
  nav.tabs button.active { background: var(--accent); color: #fff; border-color: var(--accent); }

  .tab-panel { display: none; }
  .tab-panel.active { display: block; }

  table { width: 100%; border-collapse: collapse; margin-top: 8px; font-size: 0.83rem; }
  th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--border); }
  th { color: var(--text-dim); font-weight: 500; font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.02em; }
  td button { padding: 4px 9px; font-size: 0.75rem; margin-right: 4px; }

  .tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; margin-top: 10px; }
  .tile { border: 1px solid var(--border); border-radius: 8px; padding: 10px 12px; background: #fbfbfc; }
  .tile .label { font-size: 0.72rem; color: var(--text-dim); text-transform: uppercase; letter-spacing: 0.03em; }
  .tile .value { font-family: monospace; font-size: 1.05rem; font-weight: 600; margin-top: 4px; }
  .tile .sub { font-size: 0.72rem; color: var(--text-dim); margin-top: 3px; }

  .bar-track { height: 18px; background: #eee; border-radius: 4px; overflow: hidden; margin-top: 12px; display: flex; }
  .bar-seg { height: 100%; }
  .bar-legend { display: flex; gap: 16px; margin-top: 8px; font-size: 0.78rem; color: var(--text-dim); flex-wrap: wrap; }
  .bar-legend .sw { display: inline-block; width: 9px; height: 9px; border-radius: 2px; margin-right: 5px; vertical-align: -1px; }

  .lock-fields { display: none; margin: 10px 0 0 0; padding: 10px 12px; background: var(--accent-dim); border-radius: 8px; }
  .lock-fields.show { display: grid; grid-template-columns: 1fr 2fr; gap: 10px; }

  progress { width: 100%; height: 16px; accent-color: var(--accent); }
  #progressWrap { display: none; margin-top: 12px; }
  #progressText { font-size: 0.78rem; color: var(--text-dim); margin-top: 4px; }

  .not-shown { background: #f5f5f5; border: 1px dashed #bbb; padding: 10px 12px; border-radius: 8px; font-size: 0.8rem; color: #555; margin-top: 14px; }

  .log-toggle { display: flex; justify-content: space-between; align-items: center; cursor: pointer; }
  #log { background: #111; color: #0f0; font-family: monospace; font-size: 0.78rem; padding: 12px; border-radius: 8px; height: 200px; overflow-y: auto; white-space: pre-wrap; margin-top: 10px; }
  #logCard.collapsed #log, #logCard.collapsed .log-hint { display: none; }
</style>
</head>
<body>
<div class="wrap">

<header>
  <h1>SeaweedFS S3 — demo interativa</h1>
  <span class="status"><span class="dot" id="connDot"></span><span id="connLabel">desconectado</span></span>
</header>
<div class="subtitle">Envio, listagem, versionamento, retenção e cota — direto pelo protocolo S3, sem intermediário.</div>

<div class="warn">
  <strong>Só para aprendizado.</strong> Esta página coloca a secret key direto no JavaScript do navegador — qualquer app "de verdade" (Veeam, backend, etc.) faz esse mesmo tipo de chamada, mas guarda a credencial no servidor/aplicativo, nunca visível num navegador.
</div>

<div class="card">
  <h2>Conexão</h2>
  <div class="conn-grid">
    <div>
      <label>Endpoint (gateway S3)</label>
      <input type="text" id="endpoint" value="">
    </div>
    <div>
      <label>Bucket</label>
      <input type="text" id="bucket" value="meu-bucket-teste">
    </div>
    <div>
      <label>Access Key</label>
      <input type="text" id="accessKey" value="__S3_ACCESS_KEY__">
    </div>
    <div>
      <label>Secret Key</label>
      <input type="password" id="secretKey" value="__S3_SECRET_KEY__">
    </div>
    <div><button onclick="connect()">Conectar</button></div>
  </div>
</div>

<nav class="tabs">
  <button class="active" onclick="switchTab('upload')" id="tabbtn-upload">Upload</button>
  <button onclick="switchTab('objetos')" id="tabbtn-objetos">Objetos</button>
  <button onclick="switchTab('versionamento')" id="tabbtn-versionamento">Versionamento</button>
  <button onclick="switchTab('retencao')" id="tabbtn-retencao">Retenção</button>
  <button onclick="switchTab('cota')" id="tabbtn-cota">Métricas</button>
</nav>

<div class="tab-panel active" id="tab-upload">
  <div class="card">
    <h2>Enviar arquivo</h2>
    <input type="file" id="fileInput">
    <div style="margin-top:12px;">
      <label style="display:inline-flex; align-items:center; gap:6px; margin-bottom:0;">
        <input type="checkbox" id="lockEnabled" onchange="document.getElementById('lockFields').classList.toggle('show', this.checked)" style="width:auto;">
        Aplicar retenção (Object Lock) neste upload
      </label>
    </div>
    <div class="lock-fields" id="lockFields">
      <div>
        <label>Dias de retenção (a partir de agora)</label>
        <input type="text" id="lockDays" value="1">
      </div>
      <div>
        <label>Modo</label>
        <select id="lockMode">
          <option value="GOVERNANCE">Governance (pode ser destravado por quem tem permissão especial)</option>
          <option value="COMPLIANCE">Compliance (ninguém destrava, nem admin, até a data vencer)</option>
        </select>
      </div>
    </div>
    <div><button style="margin-top:14px;" onclick="upload()">Enviar arquivo</button></div>
    <div id="progressWrap">
      <progress id="progressBar" value="0" max="100"></progress>
      <div id="progressText"></div>
    </div>
  </div>
</div>

<div class="tab-panel" id="tab-objetos">
  <div class="card">
    <h2>Objetos no bucket</h2>
    <button class="secondary" onclick="listObjects()">Listar</button>
    <table id="objTable">
      <thead><tr><th>Chave</th><th>Tamanho</th><th>Modificado</th><th></th></tr></thead>
      <tbody></tbody>
    </table>
  </div>
</div>

<div class="tab-panel" id="tab-versionamento">
  <div class="card">
    <h2>Status do versionamento</h2>
    <button class="secondary" onclick="checkVersioning()">Consultar status</button>
  </div>
  <div class="card">
    <h2>Atual vs. histórico retido</h2>
    <button class="secondary" onclick="analyzeVersions()">Analisar versões</button>
    <div class="tiles" id="versionTiles"></div>
    <div class="bar-track" id="versionBar"></div>
    <div class="bar-legend" id="versionLegend"></div>
  </div>
  <div class="card">
    <h2>Todas as versões (inclui excluídas)</h2>
    <button class="secondary" onclick="listVersions()">Listar versões</button>
    <table id="verTable">
      <thead><tr><th>Chave</th><th>Version ID</th><th>Tipo</th><th>Atual?</th><th>Modificado</th><th></th></tr></thead>
      <tbody></tbody>
    </table>
  </div>
</div>

<div class="tab-panel" id="tab-retencao">
  <div class="card">
    <h2>Retenção / imutável (Object Lock)</h2>
    <button class="secondary" onclick="analyzeRetention()">Verificar retenção por versão</button>
    <p style="font-size:0.8rem;color:var(--text-dim);margin-top:8px">Faz 1 chamada por versão (GetObjectRetention + GetObjectLegalHold) — processa até 300 versões nesta demo.</p>
    <div class="tiles" id="retentionTiles"></div>
  </div>
  <div class="card">
    <h2>Apagar com bypass de retenção (Governance)</h2>
    <p style="font-size:0.8rem;color:var(--text-dim);margin-top:0">Tenta apagar uma versão específica mandando <code>x-amz-bypass-governance-retention: true</code>. Em Governance, quem tem a permissão especial consegue apagar mesmo com retenção ativa. Em Compliance, ninguém consegue — nem com bypass — até a data vencer.</p>
    <div class="conn-grid" style="margin-top:10px">
      <div>
        <label>Chave (Key)</label>
        <input type="text" id="bypassKey">
      </div>
      <div>
        <label>Version ID</label>
        <input type="text" id="bypassVersionId">
      </div>
      <div><button class="danger" onclick="deleteWithBypass()">Tentar apagar com bypass</button></div>
    </div>
    <p style="font-size:0.78rem;color:var(--text-dim);margin-top:8px">Dica: vá em "Versionamento" → "Listar versões" e copie a Chave/Version ID de um objeto com retenção ativa.</p>
  </div>
  <div class="not-shown">
    <strong>O que esta página não mostra, de propósito:</strong> quanto do dado já virou Erasure Coding e quanto está marcado pra deletar aguardando vacuum. Essas duas informações são propriedade do <em>volume físico</em>, não do objeto S3 — só existem via administração do cluster (<code>weed shell</code>), nunca por credencial de cliente. Ver <code>COMANDOS-ADMIN.md</code> no repositório do lab.
  </div>
</div>

<div class="tab-panel" id="tab-cota">
  <div class="card">
    <h2>Dados consumidos — lógico, físico e cota</h2>
    <p style="font-size:0.8rem;color:var(--text-dim);margin:0 0 12px;line-height:1.5">
      Lógico/físico vêm direto do <code>/metrics</code> do gateway S3 (definição repassada pelo dev):<br>
      <code>bucket_size_bytes</code> — <strong>lógico</strong>: uma cópia do dado vivo.<br>
      <code>bucket_physical_size_bytes</code> — <strong>físico (em disco)</strong>: todas as réplicas + paridade EC, incluindo dado ainda não compactado pelo vacuum.<br>
      A <strong>cota abaixo é informativa</strong> — guardada por esta demo, não é a <code>s3.bucket.quota</code> real do SeaweedFS. Isso é proposital: a cota real do SeaweedFS trava o bucket sozinha ao estourar (loop de enforcement automático embutido no gateway, confirmamos isso ao vivo), sem flag pra acompanhar sem correr risco de lock. Aqui é só acompanhamento — nunca trava nada.
    </p>
    <div class="conn-grid" style="margin-bottom:12px">
      <div>
        <label>Cota informativa (MB) — vazio/0 remove</label>
        <input type="text" id="quotaMbInput" placeholder="ex.: 2048">
      </div>
      <div><button class="secondary" onclick="saveQuota()">Salvar cota</button></div>
    </div>
    <button class="secondary" onclick="checkQuota()">Consultar métricas</button>
    <div class="tiles" id="quotaTiles"></div>
    <div class="bar-track" id="quotaBar"></div>
    <div class="bar-legend" id="quotaLegend"></div>
    <div id="quotaMsg" style="font-size:0.8rem;color:var(--text-dim);margin-top:8px"></div>
  </div>
  <div class="not-shown">
    <strong>De onde vem esse número:</strong> a cota é configurada via <code>weed shell</code> (<code>s3.bucket.quota</code>) — fora do alcance de qualquer credencial S3, inclusive a desta página. O que você vê aqui vem de um proxy somente-leitura no próprio servidor da demo (<code>server.py</code>), que lê o <code>/metrics</code> Prometheus do gateway S3 (porta 9327, só em <code>localhost</code>) e devolve apenas os números do bucket pedido — o navegador nunca fala direto com <code>/metrics</code> nem enxerga credencial admin.
  </div>
</div>

<div class="card" id="logCard">
  <div class="log-toggle" onclick="document.getElementById('logCard').classList.toggle('collapsed')">
    <h2 style="margin:0">Log — o que a página está mandando pro S3, passo a passo</h2>
    <button class="ghost" type="button">mostrar/ocultar</button>
  </div>
  <div id="log"></div>
</div>

</div>

<script src="https://cdn.jsdelivr.net/npm/aws-sdk@2.1691.0/dist/aws-sdk.min.js"></script>
<script>
let s3 = null;

document.getElementById('endpoint').value = window.location.protocol + '//' + window.location.hostname + ':8333';

function switchTab(name) {
  document.querySelectorAll('.tab-panel').forEach(el => el.classList.remove('active'));
  document.querySelectorAll('nav.tabs button').forEach(el => el.classList.remove('active'));
  document.getElementById('tab-' + name).classList.add('active');
  document.getElementById('tabbtn-' + name).classList.add('active');
}

function log(msg) {
  const el = document.getElementById('log');
  const time = new Date().toLocaleTimeString();
  el.textContent += `[${time}] ${msg}\n`;
  el.scrollTop = el.scrollHeight;
}

function fmtBytes(n) {
  if (n < 1024) return n + ' B';
  const units = ['KB','MB','GB','TB'];
  let u = -1;
  do { n /= 1024; u++; } while (n >= 1024 && u < units.length - 1);
  return n.toFixed(2) + ' ' + units[u];
}

function tile(container, label, value, sub) {
  const div = document.createElement('div');
  div.className = 'tile';
  div.innerHTML = `<div class="label">${label}</div><div class="value">${value}</div>` + (sub ? `<div class="sub">${sub}</div>` : '');
  container.appendChild(div);
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

  document.getElementById('connDot').classList.add('on');
  document.getElementById('connLabel').textContent = accessKeyId + '@' + endpoint.replace(/^https?:\/\//, '');

  log(`Cliente S3 configurado: endpoint=${endpoint}, path-style=true, accessKey=${accessKeyId}`);
  log('Pronto para enviar/listar. Toda chamada abaixo é HTTP assinado com AWS Signature V4 — mesmo protocolo que o Veeam usa por baixo dos panos.');
}

function upload() {
  if (!s3) { log('ERRO: clique em "Conectar" primeiro.'); return; }
  const file = document.getElementById('fileInput').files[0];
  if (!file) { log('ERRO: escolha um arquivo primeiro.'); return; }
  const bucket = document.getElementById('bucket').value.trim();

  const params = {
    Bucket: bucket,
    Key: file.name,
    Body: file,
    ContentType: file.type || 'application/octet-stream',
  };

  const lockEnabled = document.getElementById('lockEnabled').checked;
  let logLine = `PUT ${bucket}/${file.name} (${file.size} bytes, ${file.type || 'application/octet-stream'})`;
  if (lockEnabled) {
    const days = parseFloat(document.getElementById('lockDays').value) || 0;
    const mode = document.getElementById('lockMode').value;
    const retainUntil = new Date(Date.now() + days * 24 * 60 * 60 * 1000);
    params.ObjectLockMode = mode;
    params.ObjectLockRetainUntilDate = retainUntil;
    logLine += ` com Object Lock (${mode}, até ${retainUntil.toLocaleString()})`;
  }
  log(logLine + ' — usando upload multipart pra ter barra de progresso...');

  const progressWrap = document.getElementById('progressWrap');
  const progressBar = document.getElementById('progressBar');
  const progressText = document.getElementById('progressText');
  progressWrap.style.display = 'block';
  progressBar.value = 0;
  progressText.textContent = 'Iniciando...';

  const mb = n => (n / (1024 * 1024)).toFixed(1);
  const managed = s3.upload(params, { partSize: 16 * 1024 * 1024, queueSize: 4 });
  managed.on('httpUploadProgress', p => {
    const pct = p.total ? Math.round((p.loaded / p.total) * 100) : 0;
    progressBar.value = pct;
    progressText.textContent = `${pct}% — ${mb(p.loaded)} MB / ${mb(p.total || file.size)} MB`;
  });
  managed.send((err, data) => {
    if (err) { log(`FALHOU: ${err.message}`); progressWrap.style.display = 'none'; return; }
    log(`OK — ETag=${data.ETag}`);
    progressText.textContent = 'Concluído.';
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
      btn.className = 'ghost';
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

function analyzeVersions() {
  if (!s3) { log('ERRO: clique em "Conectar" primeiro.'); return; }
  const bucket = document.getElementById('bucket').value.trim();
  log(`GET ${bucket}/?versions (ListObjectVersions), somando atual vs. histórico...`);

  s3.listObjectVersions({ Bucket: bucket }, (err, data) => {
    if (err) { log(`FALHOU: ${err.message}`); return; }
    const versions = data.Versions || [];
    const markers = data.DeleteMarkers || [];
    let current = 0, historic = 0;
    versions.forEach(v => { if (v.IsLatest) current += v.Size; else historic += v.Size; });

    const container = document.getElementById('versionTiles');
    container.innerHTML = '';
    const total = current + historic;
    tile(container, 'Versão atual', fmtBytes(current), (versions.filter(v=>v.IsLatest).length) + ' objeto(s)');
    tile(container, 'Histórico retido', fmtBytes(historic), (versions.filter(v=>!v.IsLatest).length) + ' versão(ões) antiga(s)');
    tile(container, 'Delete markers', markers.length, 'chaves sem conteúdo, só marcador');
    tile(container, '% que é histórico', total > 0 ? ((historic/total)*100).toFixed(1) + '%' : '0%', 'do total lógico deste bucket');

    const bar = document.getElementById('versionBar');
    bar.innerHTML = '';
    if (total > 0) {
      const curSeg = document.createElement('div');
      curSeg.className = 'bar-seg';
      curSeg.style.width = (current/total*100) + '%';
      curSeg.style.background = '#2f8f5b';
      const histSeg = document.createElement('div');
      histSeg.className = 'bar-seg';
      histSeg.style.width = (historic/total*100) + '%';
      histSeg.style.background = '#b87a1e';
      bar.appendChild(curSeg);
      bar.appendChild(histSeg);
    }
    document.getElementById('versionLegend').innerHTML =
      '<span><span class="sw" style="background:#2f8f5b"></span>versão atual</span>' +
      '<span><span class="sw" style="background:#b87a1e"></span>histórico retido (não-atual)</span>';

    log(`OK — ${versions.length} versão(ões) real(is) + ${markers.length} delete marker(s). Atual=${fmtBytes(current)}, histórico=${fmtBytes(historic)}.`);
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
      if (v.type === 'Versão') {
        const dlBtn = document.createElement('button');
        dlBtn.className = 'ghost';
        dlBtn.textContent = 'Baixar';
        dlBtn.onclick = () => downloadObject(v.Key, v.VersionId);
        td.appendChild(dlBtn);

        if (!v.IsLatest) {
          const restoreBtn = document.createElement('button');
          restoreBtn.className = 'ghost';
          restoreBtn.textContent = 'Restaurar como atual';
          restoreBtn.onclick = () => restoreVersion(v.Key, v.VersionId);
          td.appendChild(restoreBtn);
        }

        const bypassLinkBtn = document.createElement('button');
        bypassLinkBtn.className = 'ghost';
        bypassLinkBtn.textContent = 'Testar bypass →';
        bypassLinkBtn.onclick = () => {
          document.getElementById('bypassKey').value = v.Key;
          document.getElementById('bypassVersionId').value = v.VersionId;
          switchTab('retencao');
        };
        td.appendChild(bypassLinkBtn);
      }
      const delBtn = document.createElement('button');
      delBtn.className = 'ghost';
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

function deleteWithBypass() {
  if (!s3) { log('ERRO: clique em "Conectar" primeiro.'); return; }
  const bucket = document.getElementById('bucket').value.trim();
  const key = document.getElementById('bypassKey').value.trim();
  const versionId = document.getElementById('bypassVersionId').value.trim();
  if (!key || !versionId) { log('ERRO: preencha Chave e Version ID (ou use "Testar bypass →" na aba Versionamento).'); return; }

  log(`DELETE ${bucket}/${key}?versionId=${versionId} com header x-amz-bypass-governance-retention: true...`);
  s3.deleteObject({ Bucket: bucket, Key: key, VersionId: versionId, BypassGovernanceRetention: true }, (err) => {
    if (err) {
      log(`FALHOU (${err.code || err.statusCode}): ${err.message} — se a versão estiver em modo COMPLIANCE, este resultado é o esperado: nem bypass, nem credencial admin derruba a trava antes do prazo.`);
      return;
    }
    log(`OK — apagada mesmo com retenção ativa. Isso só funciona em modo GOVERNANCE, e só com a permissão especial (s3:BypassGovernanceRetention) — prova que Governance é destravável, Compliance não é.`);
    listVersions();
    analyzeRetention();
  });
}

function analyzeRetention() {
  if (!s3) { log('ERRO: clique em "Conectar" primeiro.'); return; }
  const bucket = document.getElementById('bucket').value.trim();
  log(`GET ${bucket}/?versions, depois GetObjectRetention/GetObjectLegalHold por versão...`);

  s3.listObjectVersions({ Bucket: bucket }, (err, data) => {
    if (err) { log(`FALHOU ao listar versões: ${err.message}`); return; }
    const versions = (data.Versions || []).slice(0, 300);
    if (versions.length === 0) { log('Nenhuma versão pra checar.'); return; }

    let lockedBytes = 0, lockedCount = 0, legalHoldBytes = 0, legalHoldCount = 0, checked = 0;
    const now = new Date();

    versions.forEach(v => {
      s3.getObjectRetention({ Bucket: bucket, Key: v.Key, VersionId: v.VersionId }, (err, ret) => {
        if (!err && ret.Retention && ret.Retention.RetainUntilDate && new Date(ret.Retention.RetainUntilDate) > now) {
          lockedBytes += v.Size;
          lockedCount++;
        }
        s3.getObjectLegalHold({ Bucket: bucket, Key: v.Key, VersionId: v.VersionId }, (err2, hold) => {
          if (!err2 && hold.LegalHold && hold.LegalHold.Status === 'ON') {
            legalHoldBytes += v.Size;
            legalHoldCount++;
          }
          checked++;
          if (checked === versions.length) {
            const container = document.getElementById('retentionTiles');
            container.innerHTML = '';
            tile(container, 'Sob retenção ativa', fmtBytes(lockedBytes), lockedCount + ' versão(ões)');
            tile(container, 'Sob legal hold', fmtBytes(legalHoldBytes), legalHoldCount + ' versão(ões)');
            tile(container, 'Verificadas', checked + ' / ' + (data.Versions||[]).length, versions.length < (data.Versions||[]).length ? 'limitado a 300 nesta demo' : 'todas');
            log(`OK — checadas ${checked} versões. ${lockedCount} sob retenção ativa (${fmtBytes(lockedBytes)}), ${legalHoldCount} sob legal hold (${fmtBytes(legalHoldBytes)}).`);
          }
        });
      });
    });
  });
}

function checkQuota() {
  const bucket = document.getElementById('bucket').value.trim();
  if (!bucket) { log('ERRO: informe um bucket.'); return; }

  log(`GET /api/quota?bucket=${bucket} — proxy local no server.py da demo, lê o /metrics do gateway S3 (porta 9327), não fala com S3 nem com weed shell...`);
  fetch('/api/quota?bucket=' + encodeURIComponent(bucket))
    .then(r => r.json().then(data => ({ ok: r.ok, data })))
    .then(({ ok, data }) => {
      if (!ok) { log(`FALHOU: ${data.error || 'erro desconhecido'}`); return; }

      const tiles = document.getElementById('quotaTiles');
      const bar = document.getElementById('quotaBar');
      const legend = document.getElementById('quotaLegend');
      const msg = document.getElementById('quotaMsg');
      tiles.innerHTML = '';
      bar.innerHTML = '';
      legend.innerHTML = '';
      msg.textContent = '';

      if (data.used_bytes === null || data.used_bytes === undefined) {
        msg.textContent = 'Sem métrica publicada ainda pra este bucket (precisa de pelo menos 1 request S3 nele antes de aparecer no /metrics).';
        log('OK — bucket ainda sem série no /metrics.');
        return;
      }

      tile(tiles, 'Lógico', fmtBytes(data.used_bytes), (data.object_count ?? '?') + ' objeto(s) — 1 cópia do dado vivo (soma versão atual + histórico retido)');

      if (data.physical_size_bytes !== null && data.physical_size_bytes !== undefined) {
        const overhead = data.used_bytes > 0 ? (data.physical_size_bytes / data.used_bytes) : null;
        tile(tiles, 'Físico (em disco)', fmtBytes(data.physical_size_bytes), overhead ? overhead.toFixed(2) + 'x o lógico — réplicas + paridade EC + não-vacuumado' : 'réplicas + paridade EC + não-vacuumado');
      }

      if (data.read_only) {
        msg.textContent = 'Atenção: este bucket está TRAVADO de verdade pelo SeaweedFS (existe uma s3.bucket.quota real configurada nele, fora desta demo) — isso não tem relação com a cota informativa abaixo.';
      }

      if (!data.has_quota) {
        tile(tiles, 'Cota informativa', 'não definida', 'defina no campo acima pra acompanhar consumo');
        log(`OK — usado=${fmtBytes(data.used_bytes)}, sem cota informativa definida.`);
        return;
      }

      const pct = data.quota_bytes > 0 ? (data.used_bytes / data.quota_bytes * 100) : 0;
      tile(tiles, 'Cota informativa', fmtBytes(data.quota_bytes), 'guardada nesta demo, não trava o bucket');
      tile(tiles, '% da cota usado', pct.toFixed(1) + '%', pct > 100 ? 'acima do informativo — SeaweedFS não trava por isso' : 'dentro do informativo');
      if (data.over_quota_bytes > 0) {
        tile(tiles, 'Excedente (informativo)', fmtBytes(data.over_quota_bytes), 'acima da cota informativa, sem efeito no SeaweedFS');
      }

      const overColor = '#b87a1e';
      const usedSeg = document.createElement('div');
      usedSeg.className = 'bar-seg';
      usedSeg.style.width = Math.min(pct, 100) + '%';
      usedSeg.style.background = pct > 100 ? overColor : '#2f8f5b';
      bar.appendChild(usedSeg);
      if (pct < 100) {
        const freeSeg = document.createElement('div');
        freeSeg.className = 'bar-seg';
        freeSeg.style.width = (100 - pct) + '%';
        freeSeg.style.background = '#e2e4e9';
        bar.appendChild(freeSeg);
      }
      legend.innerHTML =
        `<span><span class="sw" style="background:${pct > 100 ? overColor : '#2f8f5b'}"></span>usado</span>` +
        '<span><span class="sw" style="background:#e2e4e9"></span>livre até a cota informativa</span>';

      log(`OK — usado=${fmtBytes(data.used_bytes)}, cota informativa=${fmtBytes(data.quota_bytes)} (${pct.toFixed(1)}%)${pct > 100 ? ' — acima do informativo, mas SeaweedFS não trava por isso' : ''}.`);
    })
    .catch(e => log(`FALHOU: ${e.message} — o proxy /api/quota está no ar? (precisa do server.py rodando, não o "python -m http.server" puro)`));
}

function saveQuota() {
  const bucket = document.getElementById('bucket').value.trim();
  if (!bucket) { log('ERRO: informe um bucket.'); return; }
  const raw = document.getElementById('quotaMbInput').value.trim();
  const quota_mb = raw === '' ? 0 : parseFloat(raw);
  if (raw !== '' && (isNaN(quota_mb) || quota_mb < 0)) { log('ERRO: cota precisa ser um número positivo (ou vazio pra remover).'); return; }

  log(`POST /api/quota — salvando cota informativa de ${bucket} = ${quota_mb || 'removida'} MB (só grava num arquivo local da demo, não mexe no SeaweedFS)...`);
  fetch('/api/quota', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ bucket, quota_mb }),
  })
    .then(r => r.json().then(data => ({ ok: r.ok, data })))
    .then(({ ok, data }) => {
      if (!ok) { log(`FALHOU: ${data.error || 'erro desconhecido'}`); return; }
      log(quota_mb ? `OK — cota informativa salva.` : `OK — cota informativa removida.`);
      checkQuota();
    })
    .catch(e => log(`FALHOU: ${e.message}`));
}
</script>

</body>
</html>
ENDHTML
)
UPLOAD_DEMO_HTML="${UPLOAD_DEMO_HTML//__S3_ACCESS_KEY__/$S3_ACCESS_KEY}"
UPLOAD_DEMO_HTML="${UPLOAD_DEMO_HTML//__S3_SECRET_KEY__/$S3_SECRET_KEY}"

# --- rotina periodica de EC (cron no $ADMIN_HOST, ver EC_CRON_* no 00-config.env)
EC_ROTINA_SH=$(cat <<'ENDECROTINA'
#!/bin/bash
# swfs-ec-rotina.sh -- rotina periodica de Erasure Coding, chamada pelo cron
# (/etc/cron.d/swfs-ec) no master que hospeda o weed-admin. Faz o mesmo que
# a operacao manual no weed shell:
#   1) ec.encode: converte em EC os volumes cheios (>= EC_FULL_PERCENT) e sem
#      escrita ha EC_QUIET_FOR, em todas as colecoes (buckets);
#   2) ec.balance: reequilibra os shards EC entre os servidores.
# EC_FULL_PERCENT / EC_QUIET_FOR vem do cron.d (ou dos defaults abaixo).
MASTER="${SEAWEED_MASTER:-localhost:9333}"
FULL="${EC_FULL_PERCENT:-95}"
QUIET="${EC_QUIET_FOR:-1h}"
BATCH="${EC_BATCH_SIZE:-10}"
PAR="${EC_MAX_PARALLEL:-10}"

echo "=== $(date '+%F %T') rotina de EC (fullPercent=$FULL quietFor=$QUIET batchSize=$BATCH maxParallelization=$PAR) ==="
TMP=$(mktemp)
weed shell -master="$MASTER" <<CMDS 2>&1 | tee "$TMP"
lock
ec.encode -collection=*,_default -fullPercent=$FULL -quietFor=$QUIET -batchSize=$BATCH -maxParallelization=$PAR -verbose
ec.balance -apply -maxParallelization=$PAR
unlock
CMDS
RC=${PIPESTATUS[0]}
# o weed shell sai com 0 mesmo quando um comando falha; detecta o "error:" no texto
if grep -q '^error:' "$TMP"; then RC=1; fi
rm -f "$TMP"
echo "=== $(date '+%F %T') fim (weed shell exit $RC) ==="
exit $RC
ENDECROTINA
)

# --- página web de administração (criar usuário/bucket/permissões), servida
# em $UPLOAD_DEMO_HOST junto do demo de upload, em /admin.html. Fala com a API
# do weed admin via server.py (que faz o login com ADMIN_USER/ADMIN_PASSWORD)
# e é protegida por HTTP Basic com a mesma credencial. Heredoc quotado pelo
# mesmo motivo do UPLOAD_DEMO_HTML acima (JS com template literals).
UPLOAD_DEMO_ADMIN_HTML=$(cat <<'ENDADMINHTML'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<title>Administração — SeaweedFS</title>
<style>
  :root {
    --bg: #f4f5f7;
    --card: #ffffff;
    --border: #e2e4e9;
    --text: #1a1c22;
    --text-dim: #6b7078;
    --accent: #2f5fd6;
    --accent-dim: #eaf0fd;
    --ok: #1f8a4c;
    --warn-bg: #fff6e0;
    --warn-border: #f0d896;
    --danger: #c23b3b;
    --radius: 10px;
  }
  * { box-sizing: border-box; }
  body {
    font-family: -apple-system, "Segoe UI", Roboto, sans-serif;
    background: var(--bg);
    color: var(--text);
    margin: 0;
    padding: 28px 20px 60px;
  }
  .wrap { max-width: 760px; margin: 0 auto; }
  h1 { font-size: 1.35rem; margin: 0; }
  .subtitle { font-size: 0.85rem; color: var(--text-dim); margin: 4px 0 18px; }

  .warn { background: var(--warn-bg); border: 1px solid var(--warn-border); padding: 10px 14px; border-radius: var(--radius); font-size: 0.82rem; margin-bottom: 18px; color: #6b5410; }

  .card { background: var(--card); border: 1px solid var(--border); border-radius: var(--radius); padding: 16px 18px; margin-bottom: 16px; }
  .card h2 { font-size: 0.95rem; margin: 0 0 12px; }

  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 10px 14px; align-items: end; }
  label { display: block; font-size: 0.78rem; color: var(--text-dim); margin-bottom: 4px; }
  input[type=text], input[type=password], input[type=number], input[type=date], select {
    width: 100%; padding: 7px 9px; font-size: 0.85rem; font-family: monospace;
    border: 1px solid var(--border); border-radius: 6px; background: #fbfbfc; color: var(--text);
  }
  input:focus, select:focus { outline: 2px solid var(--accent-dim); border-color: var(--accent); }
  .check-row { display: flex; align-items: center; gap: 8px; margin: 4px 0 10px; }
  .check-row input[type=checkbox] { width: auto; }
  .check-row label { margin: 0; font-size: 0.85rem; color: var(--text); }

  fieldset { border: 1px solid var(--border); border-radius: 8px; padding: 10px 12px; margin: 10px 0 0; }
  fieldset[disabled] { opacity: 0.5; }
  legend { font-size: 0.78rem; color: var(--text-dim); padding: 0 4px; }

  button {
    padding: 8px 16px; font-size: 0.85rem; cursor: pointer;
    border: 1px solid var(--accent); background: var(--accent); color: #fff;
    border-radius: 6px; font-weight: 500;
  }
  button:hover { filter: brightness(1.08); }
  button.secondary { background: #fff; color: var(--accent); }
  button:disabled { opacity: 0.5; cursor: not-allowed; }

  table { width: 100%; border-collapse: collapse; margin-top: 4px; font-size: 0.83rem; }
  th, td { text-align: left; padding: 5px 8px; border-bottom: 1px solid var(--border); vertical-align: top; }
  th { color: var(--text-dim); font-weight: 500; }

  .not-shown { background: #f5f5f5; border: 1px dashed #bbb; border-radius: 8px; color: #555; }

  .steps { margin-top: 10px; font-size: 0.83rem; }
  .step { display: flex; gap: 8px; padding: 6px 0; border-bottom: 1px solid var(--border); }
  .step .badge { flex: 0 0 60px; font-weight: 600; }
  .step.ok .badge { color: var(--ok); }
  .step.fail .badge { color: var(--danger); }
  .step .detail { color: var(--text-dim); font-family: monospace; font-size: 0.76rem; white-space: pre-wrap; word-break: break-all; }

  #summaryCard, #resultCard { display: none; }

  nav.tabs { display: flex; gap: 6px; margin: 0 0 14px; flex-wrap: wrap; }
  nav.tabs button {
    background: transparent; color: var(--text-dim); border: 1px solid var(--border);
    border-radius: 999px; padding: 7px 16px; font-weight: 500;
  }
  nav.tabs button.active { background: var(--accent); color: #fff; border-color: var(--accent); }
  .tab-panel { display: none; }
  .tab-panel.active { display: block; }

  .perm-tag {
    display: inline-flex; align-items: center; gap: 4px; background: var(--accent-dim); color: var(--accent);
    border-radius: 999px; padding: 3px 6px 3px 10px; font-size: 0.76rem; margin: 2px 4px 2px 0;
  }
  .perm-tag button { all: unset; cursor: pointer; font-weight: 700; padding: 0 4px; line-height: 1; }
  .perm-tag button:hover { color: var(--danger); }
</style>
</head>
<body>
<div class="wrap">

<h1>Administração — SeaweedFS</h1>
<div class="subtitle">Página de teste do administrador — não é linkada do demo de upload, cliente nenhum vê isto.</div>

<div class="warn">
  <strong>Só para teste manual.</strong> Este servidor Python chama diretamente a API do <code>weed admin</code>
  (<span id="adminBaseLabel">carregando…</span>). Sem autenticação nesta página nem no <code>weed admin</code> hoje —
  não exponha esta porta fora do lab. Access key/secret key nunca são exibidas aqui, só do lado do próprio weed admin.
</div>

<nav class="tabs">
  <button class="active" onclick="switchTab('provision')" id="tabbtn-provision">Provisionar</button>
  <button onclick="switchTab('iam')" id="tabbtn-iam">Permissões (IAM)</button>
</nav>

<div class="tab-panel active" id="tab-provision">

<div class="card" id="formCard">
  <h2>1. Usuário (opcional)</h2>
  <div class="grid">
    <div>
      <label>Nome do usuário</label>
      <input type="text" id="userName" placeholder="nome-do-usuario" autocomplete="off">
    </div>
  </div>

  <div class="check-row" style="margin-top:14px;">
    <input type="checkbox" id="generateKey" onchange="toggleKeyMode()">
    <label for="generateKey">Gerar access key/secret automaticamente (em vez de migrar a chave da AWS)</label>
  </div>
  <div class="grid" id="manualKeyFields" style="margin-top:6px;">
    <div>
      <label>Access Key ID (da AWS)</label>
      <input type="text" id="accessKey" placeholder="AKIA..." autocomplete="off">
    </div>
    <div>
      <label>Secret Access Key (da AWS)</label>
      <input type="password" id="secretKey" placeholder="••••••••••••••••••••••••••••••••••••••" autocomplete="new-password">
    </div>
  </div>

  <h2 style="margin-top:22px;">2. Bucket (opcional)</h2>
  <div class="grid">
    <div>
      <label>Nome do bucket</label>
      <input type="text" id="bucketName" placeholder="nome-do-bucket" autocomplete="off">
    </div>
  </div>

  <div class="check-row" style="margin-top:14px;">
    <input type="checkbox" id="linkOwner">
    <label for="linkOwner">Tornar o usuário acima admin deste bucket (preenche o owner + permissão Admin)</label>
  </div>

  <div class="check-row" style="margin-top:10px;">
    <input type="checkbox" id="versioningEnabled" onchange="onVersioningToggle()">
    <label for="versioningEnabled">Ativar versionamento no bucket</label>
  </div>

  <div class="check-row" style="margin-top:4px;">
    <input type="checkbox" id="lockEnabled" onchange="toggleLockFields()">
    <label for="lockEnabled">Ativar Object Lock no bucket</label>
  </div>
  <fieldset id="lockFields" disabled>
    <legend>Object Lock</legend>
    <div class="grid">
      <div>
        <label>Modo</label>
        <select id="lockMode">
          <option value="GOVERNANCE">GOVERNANCE</option>
          <option value="COMPLIANCE">COMPLIANCE</option>
        </select>
      </div>
    </div>
    <div class="check-row" style="margin-top:10px;">
      <input type="checkbox" id="setDefaultRetention" onchange="toggleDefaultRetentionFields()">
      <label for="setDefaultRetention">Definir retenção padrão automática (aplica a todo objeto novo)</label>
    </div>
    <div class="grid" id="defaultRetentionFields" style="display:none;">
      <div>
        <label>Dias de retenção padrão</label>
        <input type="number" id="lockDays" min="1" value="30">
      </div>
    </div>
    <div class="not-shown" style="margin-top:8px; font-size:0.78rem; padding:8px 10px;">
      Sem retenção padrão, o Object Lock fica disponível no bucket mas cada
      objeto só é travado se quem enviar (ex: Veeam) mandar a própria data de
      retenção no PUT — é o caso normal de imutabilidade em backup.
    </div>
  </fieldset>

  <div class="check-row" style="margin-top:14px;">
    <input type="checkbox" id="lifecycleEnabled" onchange="toggleLifecycleFields()">
    <label for="lifecycleEnabled">Adicionar regra de lifecycle a este bucket</label>
  </div>
  <fieldset id="lifecycleFields" disabled>
    <legend>Ações (mesmas do editor nativo do weed admin)</legend>

    <div class="check-row">
      <input type="checkbox" id="actExpireDays" onchange="document.getElementById('expireDaysVal').disabled=!this.checked">
      <label for="actExpireDays">Expirar após</label>
      <input type="number" id="expireDaysVal" min="1" style="max-width:90px;" disabled>
      <span>dias</span>
    </div>

    <div class="check-row">
      <input type="checkbox" id="actExpireDate" onchange="document.getElementById('expireDateVal').disabled=!this.checked">
      <label for="actExpireDate">Expirar na data</label>
      <input type="date" id="expireDateVal" style="max-width:170px;" disabled>
    </div>

    <div class="check-row">
      <input type="checkbox" id="actDeleteMarker">
      <label for="actDeleteMarker">Remover marcadores de exclusão expirados (delete markers)</label>
    </div>

    <div class="check-row">
      <input type="checkbox" id="actNoncurrent" onchange="document.getElementById('noncurrentDaysVal').disabled=document.getElementById('noncurrentKeepVal').disabled=!this.checked">
      <label for="actNoncurrent">Limitar versões não-correntes</label>
    </div>
    <div class="grid" style="margin-left:26px; max-width:420px;">
      <div>
        <label>após (dias, opcional)</label>
        <input type="number" id="noncurrentDaysVal" min="0" disabled>
      </div>
      <div>
        <label>manter (mais recentes, opcional)</label>
        <input type="number" id="noncurrentKeepVal" min="0" value="2" disabled>
      </div>
    </div>

    <div class="check-row" style="margin-top:10px;">
      <input type="checkbox" id="actAbortMultipart" onchange="document.getElementById('abortDaysVal').disabled=!this.checked">
      <label for="actAbortMultipart">Abortar multipart incompletos após</label>
      <input type="number" id="abortDaysVal" min="1" style="max-width:90px;" disabled>
      <span>dias</span>
    </div>
  </fieldset>

  <div class="check-row" style="margin-top:14px;">
    <input type="checkbox" id="quotaEnabled" onchange="toggleQuotaFields()">
    <label for="quotaEnabled">Definir cota do bucket</label>
  </div>
  <fieldset id="quotaFields" disabled>
    <legend>Cota</legend>
    <div class="grid">
      <div>
        <label>Tamanho</label>
        <input type="number" id="quotaSize" min="1" value="100">
      </div>
      <div>
        <label>Unidade</label>
        <select id="quotaUnit">
          <option>MB</option>
          <option selected>GB</option>
          <option>TB</option>
        </select>
      </div>
    </div>
  </fieldset>

  <div style="margin-top:16px; display:flex; gap:10px;">
    <button onclick="showSummary()">Ver resumo</button>
  </div>
</div>

<div class="card" id="summaryCard">
  <h2>3. Resumo — confira antes de aplicar</h2>
  <table id="summaryTable"></table>
  <div style="margin-top:14px; display:flex; gap:10px;">
    <button class="secondary" onclick="backToForm()">Voltar e editar</button>
    <button id="applyBtn" onclick="apply()">Aplicar</button>
  </div>
</div>

<div class="card" id="resultCard">
  <h2>4. Resultado</h2>
  <div id="steps" class="steps"></div>
  <div style="margin-top:14px;">
    <button class="secondary" onclick="location.reload()">Provisionar outro</button>
  </div>
</div>

</div>

<div class="tab-panel" id="tab-iam">
  <div class="card">
    <h2>Permissões por bucket (IAM)</h2>
    <div class="subtitle" style="margin:0 0 12px;">Mesma ideia da tela de permissões do weed admin: cada usuário tem uma lista de ações no formato <code>Ação:bucket</code> (ou só <code>Ação</code>, sem bucket, pra valer em todos).</div>

    <div class="grid">
      <div>
        <label>Usuário</label>
        <select id="iamUser"></select>
      </div>
      <div>
        <label>Bucket</label>
        <select id="iamBucket">
          <option value="">* (todos os buckets)</option>
        </select>
      </div>
      <div>
        <label>Ação</label>
        <select id="iamAction">
          <option>Admin</option>
          <option>Read</option>
          <option>Write</option>
          <option>List</option>
          <option>Tagging</option>
        </select>
      </div>
      <div>
        <button onclick="grantPermission()">Conceder</button>
      </div>
    </div>
    <div id="iamStatus" style="margin-top:8px; font-size:0.82rem; color:var(--text-dim);"></div>

    <table style="margin-top:16px;">
      <thead><tr><th style="width:28%;">Usuário</th><th>Permissões</th></tr></thead>
      <tbody id="iamTableBody"><tr><td colspan="2">Carregando…</td></tr></tbody>
    </table>
    <div style="margin-top:12px;">
      <button class="secondary" onclick="loadIamData()">Recarregar</button>
    </div>
  </div>
</div>

</div>

<script>
const adminBaseLabel = document.getElementById('adminBaseLabel');
// só decorativo -- o próprio servidor sabe o endereço real do weed admin,
// isto aqui é pra deixar claro na tela pra onde a chamada vai.
adminBaseLabel.textContent = location.hostname + ' -> weed admin (ver ADMIN_API_BASE em server.py)';

function switchTab(name) {
  document.querySelectorAll('.tab-panel').forEach(el => el.classList.remove('active'));
  document.querySelectorAll('nav.tabs button').forEach(el => el.classList.remove('active'));
  document.getElementById('tab-' + name).classList.add('active');
  document.getElementById('tabbtn-' + name).classList.add('active');
  if (name === 'iam') loadIamData();
}

function toggleKeyMode() {
  const generating = document.getElementById('generateKey').checked;
  document.getElementById('manualKeyFields').style.display = generating ? 'none' : 'grid';
  document.getElementById('accessKey').disabled = generating;
  document.getElementById('secretKey').disabled = generating;
}

function onVersioningToggle() {
  // só reflete o estado do checkbox -- a trava de "obrigatório com lock"
  // é aplicada em toggleLockFields(), que roda depois se o Object Lock
  // também estiver marcado.
}

function toggleLockFields() {
  const on = document.getElementById('lockEnabled').checked;
  document.getElementById('lockFields').disabled = !on;
  const versioningCb = document.getElementById('versioningEnabled');
  if (on) {
    // Mesma regra do SeaweedFS/S3: Object Lock exige versionamento --
    // liga e trava o checkbox pra não dar pra desligar enquanto o lock
    // estiver ativo.
    versioningCb.checked = true;
    versioningCb.disabled = true;
  } else {
    versioningCb.disabled = false;
    document.getElementById('setDefaultRetention').checked = false;
    toggleDefaultRetentionFields();
  }
}
function toggleDefaultRetentionFields() {
  document.getElementById('defaultRetentionFields').style.display =
    document.getElementById('setDefaultRetention').checked ? 'grid' : 'none';
}
function toggleLifecycleFields() {
  document.getElementById('lifecycleFields').disabled = !document.getElementById('lifecycleEnabled').checked;
}
function toggleQuotaFields() {
  document.getElementById('quotaFields').disabled = !document.getElementById('quotaEnabled').checked;
}

function buildLifecycleRule() {
  if (!document.getElementById('lifecycleEnabled').checked) return null;
  const rule = {};
  if (document.getElementById('actExpireDays').checked) {
    rule.expiration_days = parseInt(document.getElementById('expireDaysVal').value || '0', 10);
  }
  if (document.getElementById('actExpireDate').checked) {
    rule.expiration_date = document.getElementById('expireDateVal').value;
  }
  if (document.getElementById('actDeleteMarker').checked) {
    rule.expired_object_delete_marker = true;
  }
  if (document.getElementById('actNoncurrent').checked) {
    const days = parseInt(document.getElementById('noncurrentDaysVal').value || '0', 10);
    const keep = parseInt(document.getElementById('noncurrentKeepVal').value || '0', 10);
    if (days > 0) rule.noncurrent_version_expiration_days = days;
    if (keep > 0) rule.newer_noncurrent_versions = keep;
  }
  if (document.getElementById('actAbortMultipart').checked) {
    rule.abort_multipart_days = parseInt(document.getElementById('abortDaysVal').value || '0', 10);
  }
  return Object.keys(rule).length ? rule : null;
}

function describeLifecycleRule(rule) {
  if (!rule) return 'nenhuma';
  const parts = [];
  if (rule.expiration_days) parts.push('expira objetos após ' + rule.expiration_days + ' dia(s)');
  if (rule.expiration_date) parts.push('expira objetos em ' + rule.expiration_date);
  if (rule.expired_object_delete_marker) parts.push('remove delete markers expirados');
  if (rule.noncurrent_version_expiration_days) parts.push('expira não-correntes após ' + rule.noncurrent_version_expiration_days + ' dia(s)');
  if (rule.newer_noncurrent_versions) parts.push('mantém ' + rule.newer_noncurrent_versions + ' não-corrente(s)');
  if (rule.abort_multipart_days) parts.push('aborta multipart após ' + rule.abort_multipart_days + ' dia(s)');
  return parts.join('; ') || 'regra vazia';
}

function readConfig() {
  return {
    user_name: document.getElementById('userName').value.trim(),
    generate_key: document.getElementById('generateKey').checked,
    access_key: document.getElementById('accessKey').value.trim(),
    secret_key: document.getElementById('secretKey').value,
    bucket_name: document.getElementById('bucketName').value.trim(),
    link_owner: document.getElementById('linkOwner').checked,
    versioning_enabled: document.getElementById('versioningEnabled').checked,
    object_lock_enabled: document.getElementById('lockEnabled').checked,
    object_lock_mode: document.getElementById('lockMode').value,
    set_default_retention: document.getElementById('setDefaultRetention').checked,
    object_lock_days: parseInt(document.getElementById('lockDays').value || '0', 10),
    lifecycle_rule: buildLifecycleRule(),
    quota_enabled: document.getElementById('quotaEnabled').checked,
    quota_size: parseInt(document.getElementById('quotaSize').value || '0', 10),
    quota_unit: document.getElementById('quotaUnit').value,
  };
}

function showSummary() {
  const cfg = readConfig();
  if (!cfg.user_name && !cfg.bucket_name) {
    alert('Preencha o nome do usuário e/ou do bucket -- pelo menos um dos dois.');
    return;
  }
  if (cfg.user_name && !cfg.generate_key && (!cfg.access_key || !cfg.secret_key)) {
    alert('Informe access key e secret key do usuário, ou marque "gerar automaticamente".');
    return;
  }
  if (cfg.link_owner && !(cfg.user_name && cfg.bucket_name)) {
    alert('Pra vincular como admin, preencha usuário E bucket.');
    return;
  }
  if (cfg.set_default_retention && !(cfg.object_lock_days > 0)) {
    alert('Informe dias de retenção > 0 para a retenção padrão.');
    return;
  }
  if (cfg.lifecycle_rule && cfg.lifecycle_rule.newer_noncurrent_versions && !cfg.versioning_enabled) {
    alert('"Limitar versões não-correntes" precisa de versionamento ativado.');
    return;
  }
  window._provisionCfg = cfg;

  const rows = [];
  if (cfg.user_name) {
    rows.push(['Usuário', cfg.user_name]);
    rows.push(['Credencial', cfg.generate_key
      ? 'gerada automaticamente pelo SeaweedFS (consulte no weed admin depois)'
      : 'informada — Access Key ' + cfg.access_key + ', Secret (oculto — ' + cfg.secret_key.length + ' caracteres)']);
  }
  if (cfg.bucket_name) {
    rows.push(['Bucket', cfg.bucket_name]);
    rows.push(['Owner do bucket', cfg.link_owner ? cfg.user_name + ' (admin)' : 'nenhum']);
    const lockDesc = !cfg.object_lock_enabled
      ? 'desativado'
      : cfg.object_lock_mode + (cfg.set_default_retention
          ? ', retenção padrão de ' + cfg.object_lock_days + ' dia(s) em todo objeto novo'
          : ', sem retenção padrão — cada objeto só trava se quem enviar pedir (ex: Veeam)');
    rows.push(['Versionamento', cfg.versioning_enabled
      ? (cfg.object_lock_enabled ? 'ativado (obrigatório com Object Lock)' : 'ativado')
      : 'desativado']);
    rows.push(['Object Lock', lockDesc]);
    rows.push(['Lifecycle', describeLifecycleRule(cfg.lifecycle_rule)]);
    rows.push(['Cota', cfg.quota_enabled ? (cfg.quota_size + cfg.quota_unit) : 'sem cota']);
  }
  rows.push(['Ordem de aplicação', (function() {
    const steps = [];
    if (cfg.user_name) {
      steps.push('criar usuário' + (cfg.generate_key ? ' (já com chave gerada)' : ''));
      if (!cfg.generate_key) steps.push('anexar chave');
    }
    if (cfg.bucket_name) {
      steps.push('criar bucket' + (cfg.link_owner ? ' (owner=' + cfg.user_name + ')' : ''));
      if (cfg.lifecycle_rule) steps.push('lifecycle');
    }
    return steps.map((s, i) => (i + 1) + ') ' + s).join('  ');
  })()]);

  document.getElementById('summaryTable').innerHTML = rows.map(([k, v]) =>
    '<tr><th>' + k + '</th><td>' + v + '</td></tr>'
  ).join('');

  document.getElementById('formCard').style.display = 'none';
  document.getElementById('summaryCard').style.display = 'block';
}

function backToForm() {
  document.getElementById('summaryCard').style.display = 'none';
  document.getElementById('formCard').style.display = 'block';
}

async function apply() {
  const btn = document.getElementById('applyBtn');
  btn.disabled = true;
  btn.textContent = 'Aplicando...';
  try {
    const resp = await fetch('/api/admin/provision', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(window._provisionCfg),
    });
    const data = await resp.json();
    renderResult(data);
  } catch (e) {
    renderResult({ success: false, steps: [{ name: 'Chamada ao servidor', ok: false, http_code: 0, response: String(e) }] });
  } finally {
    btn.disabled = false;
    btn.textContent = 'Aplicar';
  }
}

function renderResult(data) {
  document.getElementById('summaryCard').style.display = 'none';
  document.getElementById('resultCard').style.display = 'block';
  const stepsEl = document.getElementById('steps');
  const steps = data.steps || [];

  // O servidor já tira access_key/secret_key de toda resposta antes de
  // mandar pra cá -- de propósito, a credencial (migrada ou gerada) só deve
  // aparecer do lado do weed admin, nunca renderizada nesta página.
  const usedGeneratedKey = window._provisionCfg && window._provisionCfg.generate_key && window._provisionCfg.user_name;
  let calloutHtml = '';
  if (usedGeneratedKey && data.success) {
    calloutHtml =
      '<div class="not-shown" style="padding:12px 14px; margin-bottom:12px; border-color:var(--accent);">' +
        '<strong>Credencial gerada.</strong> Por design, esta página não mostra o valor —' +
        ' consulte em weed admin &gt; Object Store Users (ou <code>GET /api/users</code>) para pegar o access key/secret e repassar ao cliente.' +
      '</div>';
  }

  stepsEl.innerHTML = calloutHtml + (steps.map(s =>
    '<div class="step ' + (s.ok ? 'ok' : 'fail') + '">' +
      '<div class="badge">' + (s.ok ? 'OK' : 'FALHOU') + '</div>' +
      '<div>' + s.name + ' (HTTP ' + s.http_code + ')' +
        '<div class="detail">' + escapeHtml(typeof s.response === 'string' ? s.response : JSON.stringify(s.response)) + '</div>' +
      '</div>' +
    '</div>'
  ).join('') || '<div>Nenhum passo executado.</div>');
  if (!data.success) {
    stepsEl.innerHTML += '<div style="margin-top:8px; color: var(--danger);">Parou no primeiro passo que falhou — nada depois foi aplicado.</div>';
  }
}

// --- aba de Permissões (IAM) ---------------------------------------------

let iamUsers = [];
let iamBuckets = [];

async function loadIamData() {
  const status = document.getElementById('iamStatus');
  status.textContent = 'Carregando...';
  try {
    const resp = await fetch('/api/admin/iam');
    const data = await resp.json();
    if (!resp.ok) throw new Error(data.error || resp.status);
    iamUsers = data.users || [];
    iamBuckets = data.buckets || [];
    renderIamSelects();
    renderIamTable();
    status.textContent = '';
  } catch (e) {
    status.textContent = 'Erro ao carregar: ' + e.message;
  }
}

function renderIamSelects() {
  const userSel = document.getElementById('iamUser');
  const prevUser = userSel.value;
  userSel.innerHTML = iamUsers.map(u => '<option value="' + escapeAttr(u.username) + '">' + escapeHtml(u.username) + '</option>').join('');
  if (prevUser) userSel.value = prevUser;

  const bucketSel = document.getElementById('iamBucket');
  const prevBucket = bucketSel.value;
  bucketSel.innerHTML = '<option value="">* (todos os buckets)</option>' +
    iamBuckets.map(b => '<option value="' + escapeAttr(b.name) + '">' + escapeHtml(b.name) + '</option>').join('');
  bucketSel.value = prevBucket || '';
}

function renderIamTable() {
  const body = document.getElementById('iamTableBody');
  body.innerHTML = iamUsers.map(u => {
    const perms = (u.permissions || []).map(p =>
      '<span class="perm-tag">' + escapeHtml(p) +
        '<button data-revoke data-username="' + escapeAttr(u.username) + '" data-action="' + escapeAttr(p) + '" title="remover">×</button>' +
      '</span>'
    ).join('') || '<span style="color:var(--text-dim);">nenhuma</span>';
    return '<tr><td>' + escapeHtml(u.username) + '</td><td>' + perms + '</td></tr>';
  }).join('') || '<tr><td colspan="2">Nenhum usuário -- crie um na aba Provisionar.</td></tr>';
}

document.getElementById('iamTableBody').addEventListener('click', (e) => {
  const btn = e.target.closest('button[data-revoke]');
  if (!btn) return;
  applyIamChange(btn.dataset.username, btn.dataset.action, 'remove');
});

function grantPermission() {
  const username = document.getElementById('iamUser').value;
  const bucket = document.getElementById('iamBucket').value;
  const action = document.getElementById('iamAction').value;
  if (!username) { alert('Selecione um usuário (crie um na aba Provisionar se a lista estiver vazia).'); return; }
  const actionString = bucket ? (action + ':' + bucket) : action;
  applyIamChange(username, actionString, 'add');
}

async function applyIamChange(username, actionString, op) {
  const status = document.getElementById('iamStatus');
  status.textContent = 'Aplicando...';
  try {
    const resp = await fetch('/api/admin/iam/policy', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, action_string: actionString, op }),
    });
    const data = await resp.json();
    if (!resp.ok || !data.success) {
      status.textContent = 'Erro: ' + (data.error || data.detail || resp.status);
      return;
    }
    status.textContent = '';
    await loadIamData();
  } catch (e) {
    status.textContent = 'Erro: ' + e.message;
  }
}

function escapeHtml(s) {
  return String(s).replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
}
function escapeAttr(s) {
  return String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
}
</script>
</body>
</html>
ENDADMINHTML
)

UPLOAD_DEMO_SERVER_PY=$(cat <<'ENDPY'
#!/usr/bin/env python3
# Serve a página estática do demo e expõe /api/quota como proxy somente-leitura
# para o /metrics (Prometheus) do gateway S3 local — nunca fala com weed shell
# nem guarda credencial admin. Ver README/COMANDOS.md para o resto do contexto.
#
# A cota mostrada aqui é INFORMATIVA, guardada num arquivo local desta demo —
# não é a s3.bucket.quota real do SeaweedFS. Isso é deliberado: a cota real
# tem um loop de enforcement automático embutido no próprio weed s3
# (bucket_size_metrics.go) que trava o bucket sozinho ao estourar, em ambas
# as direções, sem flag pra desligar só o travamento mantendo o número visível.
# Pra ter cota visível sem nenhum risco de lock, a alternativa é não configurar
# quota real nenhuma e deixar essa demo acompanhar/exibir o número por conta
# própria, comparando com bucket_size_bytes (que é sempre real, vem do SeaweedFS
# independente de ter cota configurada ou não).
import base64
import hmac
import http.cookiejar
import http.server
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

METRICS_URL = "http://127.0.0.1:9327/metrics"
QUOTA_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "informational_quotas.json")

# /api/admin/provision é a exceção deliberada ao comentário acima: fala com
# a API REST do `weed admin` (usuário + bucket + lifecycle) e portanto grava
# credencial admin real. Existe só para o path /admin.html, que não é
# linkado do index.html nem pensado pra cliente ver -- é a página de teste
# admin descrita em 09-provisionar-cliente.sh, só que como página web em vez
# de script de terminal. Em produção fora do lab isso pediria autenticação
# nesta própria página, não só no weed admin.
# Esta cópia local usa o IP/porta atuais do lab (00-config.env: ADMIN_HOST
# + SEAWEED_ADMIN_PORT) direto, sem placeholder -- no heredoc embutido em
# 04-gerar-cloud-init.sh o mesmo valor entra como __ADMIN_API_HOST__ /
# __ADMIN_API_PORT__, substituído na hora do deploy (mesmo padrão já usado
# ali para __S3_ACCESS_KEY__/__S3_SECRET_KEY__).
ADMIN_API_BASE = os.environ.get("ADMIN_API_BASE", "http://192.168.100.11:23646/api")

METRIC_NAMES = {
    "SeaweedFS_s3_bucket_size_bytes": "used_bytes",
    "SeaweedFS_s3_bucket_physical_size_bytes": "physical_size_bytes",
    "SeaweedFS_s3_bucket_read_only": "read_only",
    "SeaweedFS_s3_bucket_object_count": "object_count",
}
LINE_RE = re.compile(r'^(\w+)\{bucket="([^"]*)"\}\s+([0-9eE.+-]+)\s*$')


def load_quotas():
    try:
        with open(QUOTA_FILE, encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_quotas(data):
    tmp = QUOTA_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
    os.replace(tmp, QUOTA_FILE)


def fetch_bucket_metrics(bucket):
    with urllib.request.urlopen(METRICS_URL, timeout=5) as resp:
        text = resp.read().decode("utf-8", "replace")

    values = {}
    for line in text.splitlines():
        m = LINE_RE.match(line)
        if not m:
            continue
        metric, line_bucket, raw_value = m.groups()
        if metric in METRIC_NAMES and line_bucket == bucket:
            values[METRIC_NAMES[metric]] = float(raw_value)
    return values


def build_quota_response(bucket):
    values = fetch_bucket_metrics(bucket)
    used = values.get("used_bytes")

    quotas = load_quotas()
    quota_mb = quotas.get(bucket)
    quota_bytes = quota_mb * 1024 * 1024 if quota_mb else None

    return {
        "bucket": bucket,
        "used_bytes": used,
        "physical_size_bytes": values.get("physical_size_bytes"),
        "object_count": values.get("object_count"),
        "has_quota": quota_bytes is not None,
        "quota_bytes": quota_bytes,
        "over_quota_bytes": (used - quota_bytes) if (used is not None and quota_bytes) else None,
        "read_only": bool(values.get("read_only")),
        "quota_source": "informational (guardada nesta demo, não é s3.bucket.quota real)",
    }


# O weed admin (4.47) só aceita conexões fora do loopback com senha: sessão
# por cookie (POST /login) + token CSRF (meta csrf-token de /admin) em
# X-CSRF-Token nas escritas. Credenciais = ADMIN_USER/ADMIN_PASSWORD do
# 00-config.env, sobrescrevíveis por variável de ambiente.
ADMIN_ROOT = ADMIN_API_BASE.rsplit("/api", 1)[0]
ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "swfslab-admin")
_admin_opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
_admin_csrf = None


def _admin_login():
    global _admin_csrf
    page = _admin_opener.open(ADMIN_ROOT + "/login", timeout=10).read().decode("utf-8", "replace")
    m = re.search(r'name="csrf_token" value="([^"]*)"', page)
    if not m:
        raise RuntimeError("não achei o token do formulário de login do weed admin")
    form = urllib.parse.urlencode({
        "username": ADMIN_USER, "password": ADMIN_PASSWORD, "csrf_token": m.group(1),
    }).encode("utf-8")
    after = _admin_opener.open(
        urllib.request.Request(ADMIN_ROOT + "/login", data=form, method="POST"), timeout=10
    ).read().decode("utf-8", "replace")
    m = re.search(r'name="csrf-token" content="([^"]*)"', after)
    if not m:
        raise RuntimeError("login no weed admin falhou (confira ADMIN_USER/ADMIN_PASSWORD)")
    _admin_csrf = m.group(1)


def admin_api_call(method, path, payload=None):
    """Chama a API REST do weed admin (ex: /s3/buckets, /users), já logado.
    Retorna (http_code, corpo_como_texto); http_code 0 = não deu pra
    conectar/logar."""
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    for attempt in (1, 2):
        try:
            if _admin_csrf is None:
                _admin_login()
            req = urllib.request.Request(
                ADMIN_API_BASE + path, data=data, method=method,
                headers={"Content-Type": "application/json", "X-CSRF-Token": _admin_csrf},
            )
            with _admin_opener.open(req, timeout=10) as resp:
                return resp.status, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            if e.code in (401, 403) and attempt == 1:
                globals()["_admin_csrf"] = None   # sessão expirou / token velho: refaz o login
                continue
            return e.code, e.read().decode("utf-8", "replace")
        except (urllib.error.URLError, RuntimeError) as e:
            return 0, str(getattr(e, "reason", e))
    return 0, "falha ao autenticar no weed admin"


def redact_secrets(value):
    """Remove access_key/secret_key de qualquer resposta antes dela voltar
    pro navegador -- a credencial (migrada ou gerada) só deve ficar visível
    do lado do weed admin (sua própria UI, ou GET /api/users), nunca
    renderizada nesta página de demo."""
    if isinstance(value, dict):
        return {
            k: ("(oculto -- consulte no weed admin)" if k in ("access_key", "secret_key") and isinstance(v, str) else redact_secrets(v))
            for k, v in value.items()
        }
    if isinstance(value, list):
        return [redact_secrets(v) for v in value]
    return value


def run_provisioning(cfg):
    """Roda só os passos que fazem sentido pro que foi preenchido: usuário
    sozinho, bucket sozinho, ou os dois -- usuário primeiro, pra poder virar
    owner do bucket quando link_owner estiver marcado. Para no primeiro
    passo que falhar."""
    steps = []
    user_name = cfg.get("user_name")
    bucket_name = cfg.get("bucket_name")
    link_owner = bool(cfg.get("link_owner")) and bool(user_name) and bool(bucket_name)

    def step(name, method, path, body):
        code, resp_body = admin_api_call(method, path, body)
        ok = 200 <= code < 300
        try:
            resp_json = json.loads(resp_body)
        except (json.JSONDecodeError, TypeError):
            resp_json = resp_body
        steps.append({"name": name, "ok": ok, "http_code": code, "response": redact_secrets(resp_json)})
        return ok

    if user_name:
        generate_key = cfg["generate_key"]
        # actions vazio quando não vinculado -- dá pra conceder permissões
        # depois pela aba de Permissões (IAM), sem precisar recriar o usuário.
        actions = [f"Admin:{bucket_name}"] if link_owner else []
        if not step("Criar usuário", "POST", "/users", {
            "username": user_name, "email": "", "actions": actions,
            "generate_key": generate_key, "policy_names": [],
        }):
            return steps

        # Com generate_key=true a própria criação do usuário já devolve a
        # credencial (sob a mesma redação acima) -- não existe um segundo
        # passo de "anexar chave" nesse caso.
        if not generate_key and not step("Anexar access key/secret", "POST", f"/users/{user_name}/access-keys", {
            "access_key": cfg["access_key"], "secret_key": cfg["secret_key"],
        }):
            return steps

    if bucket_name:
        owner = user_name if link_owner else ""
        bucket_step_name = f"Criar bucket (owner={owner})" if owner else "Criar bucket (sem owner)"
        if not step(bucket_step_name, "POST", "/s3/buckets", {
            "name": bucket_name, "region": "",
            "quota_size": cfg["quota_size"], "quota_unit": cfg["quota_unit"],
            "quota_enabled": cfg["quota_enabled"],
            "versioning_enabled": cfg["versioning_enabled"],
            "object_lock_enabled": cfg["object_lock_enabled"],
            "object_lock_mode": cfg["object_lock_mode"],
            "set_default_retention": cfg["set_default_retention"],
            "object_lock_duration": cfg["object_lock_days"] if cfg["set_default_retention"] else 0,
            "owner": owner,
        }):
            return steps

        # Lifecycle é opcional: sem regra nenhuma marcada no formulário, o
        # bucket fica só com versionamento (+ Object Lock, se ativado) e este
        # passo nem roda -- não força nenhum limite de versão sozinho.
        lifecycle_rule = cfg.get("lifecycle_rule")
        if lifecycle_rule:
            rule = {"status": "Enabled"}
            rule.update(lifecycle_rule)
            step("Aplicar lifecycle", "PUT", f"/s3/buckets/{bucket_name}/lifecycle", {
                "bucket": bucket_name,
                "rules": [rule],
            })
    return steps


def needs_admin_auth(path):
    return path == "/admin.html" or path.startswith("/api/admin/")


class Handler(http.server.SimpleHTTPRequestHandler):
    def _admin_auth_ok(self):
        """HTTP Basic com a mesma credencial do weed admin (ADMIN_USER/
        ADMIN_PASSWORD). /admin.html e /api/admin/* criam usuários e buckets
        com a credencial admin, então não podem ficar abertos pra rede."""
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            user, _, pwd = base64.b64decode(header[6:]).decode("utf-8").partition(":")
        except (ValueError, UnicodeDecodeError):
            return False
        return (hmac.compare_digest(user.encode(), ADMIN_USER.encode())
                and hmac.compare_digest(pwd.encode(), ADMIN_PASSWORD.encode()))

    def _deny_auth(self):
        body = b"Autenticacao necessaria (usuario/senha do weed admin)."
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Administracao SeaweedFS"')
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if needs_admin_auth(parsed.path) and not self._admin_auth_ok():
            return self._deny_auth()
        if parsed.path == "/api/admin/iam":
            return self._handle_iam_get()
        if parsed.path != "/api/quota":
            return super().do_GET()

        bucket = urllib.parse.parse_qs(parsed.query).get("bucket", [""])[0].strip()
        if not bucket:
            self._json(400, {"error": "informe ?bucket=<nome>"})
            return
        try:
            self._json(200, build_quota_response(bucket))
        except (urllib.error.URLError, OSError) as e:
            self._json(502, {"error": f"não consegui ler {METRICS_URL}: {e}"})

    def _read_json_body(self, max_len=4096):
        length = int(self.headers.get("Content-Length", 0))
        if length <= 0 or length > max_len:
            self._json(400, {"error": "corpo da requisição ausente ou grande demais"})
            return None
        try:
            return json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            self._json(400, {"error": "corpo inválido, esperado JSON"})
            return None

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if needs_admin_auth(parsed.path) and not self._admin_auth_ok():
            return self._deny_auth()
        if parsed.path == "/api/admin/provision":
            return self._handle_provision_post()
        if parsed.path == "/api/admin/iam/policy":
            return self._handle_iam_policy_post()
        if parsed.path != "/api/quota":
            self._json(404, {"error": "not found"})
            return

        body = self._read_json_body()
        if body is None:
            return

        bucket = str(body.get("bucket", "")).strip()
        if not bucket:
            self._json(400, {"error": "informe 'bucket'"})
            return

        quota_mb = body.get("quota_mb", None)
        quotas = load_quotas()
        if quota_mb in (None, 0, "0", ""):
            quotas.pop(bucket, None)
        else:
            try:
                quota_mb = float(quota_mb)
                if quota_mb <= 0:
                    raise ValueError
            except (TypeError, ValueError):
                self._json(400, {"error": "quota_mb precisa ser um número positivo (ou vazio/0 para remover)"})
                return
            quotas[bucket] = quota_mb
        save_quotas(quotas)

        try:
            self._json(200, build_quota_response(bucket))
        except (urllib.error.URLError, OSError) as e:
            self._json(502, {"error": f"cota salva, mas não consegui ler {METRICS_URL}: {e}"})

    def _handle_provision_post(self):
        body = self._read_json_body(max_len=8192)
        if body is None:
            return

        user_name = str(body.get("user_name", "")).strip()
        bucket_name = str(body.get("bucket_name", "")).strip()
        if not user_name and not bucket_name:
            self._json(400, {"error": "informe user_name e/ou bucket_name"})
            return

        link_owner = bool(body.get("link_owner"))
        if link_owner and not (user_name and bucket_name):
            self._json(400, {"error": "link_owner requer user_name e bucket_name preenchidos"})
            return

        generate_key = bool(body.get("generate_key"))
        access_key = str(body.get("access_key", "")).strip()
        secret_key = str(body.get("secret_key", "")).strip()
        if user_name and not generate_key and (not access_key or not secret_key):
            self._json(400, {"error": "informe access_key e secret_key, ou generate_key=true"})
            return

        object_lock_enabled = bool(body.get("object_lock_enabled"))
        object_lock_mode = str(body.get("object_lock_mode", "")).strip().upper()
        if bucket_name and object_lock_enabled and object_lock_mode not in ("GOVERNANCE", "COMPLIANCE"):
            self._json(400, {"error": "object_lock_mode precisa ser GOVERNANCE ou COMPLIANCE quando object_lock_enabled=true"})
            return

        # Mesma regra do SeaweedFS/S3: Object Lock exige versionamento --
        # força aqui também (não só na UI) pra quem chamar a API direto sem
        # passar por admin.html não conseguir criar uma combinação inválida.
        versioning_enabled = bool(body.get("versioning_enabled")) or object_lock_enabled

        # Object Lock e retenção padrão são independentes -- dá pra ativar o
        # lock no bucket (necessário pro cliente travar objeto por objeto,
        # ex: Veeam mandando a própria retain-until-date) sem forçar uma
        # regra padrão que exigiria pelo menos 1 dia em todo objeto novo.
        set_default_retention = bool(body.get("set_default_retention"))
        if set_default_retention and not object_lock_enabled:
            self._json(400, {"error": "set_default_retention requer object_lock_enabled"})
            return

        try:
            object_lock_days = int(body.get("object_lock_days") or 0)
            quota_size = int(body.get("quota_size") or 0)
        except (TypeError, ValueError):
            self._json(400, {"error": "object_lock_days e quota_size precisam ser números"})
            return
        if set_default_retention and object_lock_days <= 0:
            self._json(400, {"error": "object_lock_days precisa ser > 0 quando set_default_retention=true"})
            return

        lifecycle_rule = body.get("lifecycle_rule")
        if lifecycle_rule is not None and not isinstance(lifecycle_rule, dict):
            self._json(400, {"error": "lifecycle_rule precisa ser um objeto ou null"})
            return

        cfg = {
            "user_name": user_name,
            "bucket_name": bucket_name,
            "link_owner": link_owner,
            "generate_key": generate_key,
            "access_key": access_key,
            "secret_key": secret_key,
            "versioning_enabled": versioning_enabled,
            "object_lock_enabled": object_lock_enabled,
            "object_lock_mode": object_lock_mode,
            "set_default_retention": set_default_retention,
            "object_lock_days": object_lock_days,
            "lifecycle_rule": lifecycle_rule,
            "quota_enabled": bool(body.get("quota_enabled")),
            "quota_size": quota_size,
            "quota_unit": str(body.get("quota_unit", "GB") or "GB").strip().upper(),
        }

        steps = run_provisioning(cfg)
        success = bool(steps) and all(s["ok"] for s in steps)
        self._json(200, {"success": success, "steps": steps})

    def _handle_iam_get(self):
        """Lista usuários (com permissões) e buckets pra aba de IAM. Nunca
        inclui access_key/secret_key -- mesma regra de redação do resto
        desta página."""
        code, body = admin_api_call("GET", "/users")
        if not (200 <= code < 300):
            self._json(502 if code == 0 else code, {"error": f"weed admin: {body}"})
            return
        try:
            users_raw = json.loads(body).get("users") or []
        except json.JSONDecodeError:
            users_raw = []
        users = [{"username": u.get("username"), "permissions": u.get("permissions") or []} for u in users_raw]

        buckets = []
        code2, body2 = admin_api_call("GET", "/s3/buckets")
        if 200 <= code2 < 300:
            try:
                buckets = [{"name": b.get("name")} for b in (json.loads(body2).get("buckets") or [])]
            except json.JSONDecodeError:
                pass

        self._json(200, {"users": users, "buckets": buckets})

    def _handle_iam_policy_post(self):
        """Adiciona ou remove uma permissão (ex: 'Read:meu-bucket', ou
        'Admin' sem bucket = global) da lista de actions de um usuário.
        A API do weed admin só substitui a lista inteira, então lê o
        estado atual, ajusta, e reenvia."""
        body = self._read_json_body(max_len=2048)
        if body is None:
            return

        username = str(body.get("username", "")).strip()
        action_string = str(body.get("action_string", "")).strip()
        op = str(body.get("op", "")).strip()
        if not username or not action_string or op not in ("add", "remove"):
            self._json(400, {"error": "informe username, action_string e op ('add' ou 'remove')"})
            return

        code, resp_body = admin_api_call("GET", f"/users/{username}")
        if not (200 <= code < 300):
            self._json(502 if code == 0 else code, {"error": f"não encontrei o usuário: {resp_body}"})
            return
        try:
            current = json.loads(resp_body).get("actions") or []
        except json.JSONDecodeError:
            current = []

        if op == "add":
            new_actions = current if action_string in current else current + [action_string]
        else:
            new_actions = [a for a in current if a != action_string]

        code2, resp_body2 = admin_api_call("PUT", f"/users/{username}/policies", {"actions": new_actions})
        ok = 200 <= code2 < 300
        self._json(200 if ok else (502 if code2 == 0 else code2), {
            "success": ok,
            "actions": new_actions if ok else current,
            "detail": resp_body2,
        })

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8090
    # BIND_ADDR=127.0.0.1 ao rodar no host: /admin.html usa a credencial admin,
    # então não deve ficar aberto pra rede local.
    http.server.HTTPServer((os.environ.get("BIND_ADDR", "0.0.0.0"), port), Handler).serve_forever()
ENDPY
)

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

    # Discos de dados (só existem nos volume nodes). São
    # VOLUME_DISKS_PER_NODE discos INDEPENDENTES, cada um com a posição de
    # um disco de servidor Dell -- controladora:backplane:disco (ver
    # 00-config.env) -- formatado, rotulado e montado no seu próprio ponto
    # (${DATA_MOUNT_DIR}/disk0, /disk1, ...). Cada disco é achado pelo
    # endereço SCSI (target = índice do disco, definido no 05-criar-vms.sh),
    # não por /dev/sdX, cuja ordem não é garantida. Rótulo do ext4 (máx.
    # 16 chars): <nodeNN>-<ctrl>-<backplane>-<disco> (ex.: node01-0-1-2).
    DATA_DISK_RUNCMD=""
    if $IS_VOLUME; then
        NODE_SHORT="${vm#swfs-}"
        DATA_DISK_RUNCMD="
  # --- discos de dados: ${VOLUME_DISKS_PER_NODE} devices independentes, cada um
  # formatado (1x), rotulado pela posição e montado em ${DATA_MOUNT_DIR}/diskN,
  # dono certo pro ${VM_USER} -- sem isso, \"weed volume\" falha com
  # \"permission denied\" ao criar suas pastas de estado.
  - mkdir -p ${DATA_MOUNT_DIR}"
        for ((d = 0; d < VOLUME_DISKS_PER_NODE; d++)); do
            DISK_POS="${DISK_CONTROLLER}:${DISK_BACKPLANE}:${d}"
            DISK_LABEL="${NODE_SHORT}-${DISK_CONTROLLER}-${DISK_BACKPLANE}-${d}"
            DATA_DISK_RUNCMD+="
  - [ bash, -c, \"DEV=\$(/usr/local/bin/swfs-disk-dev.sh ${d}) && { blkid \$DEV >/dev/null 2>&1 || mkfs.ext4 -F -L ${DISK_LABEL} \$DEV; }\" ]
  - mkdir -p ${DATA_MOUNT_DIR}/disk${d}
  - [ bash, -c, \"grep -q '^LABEL=${DISK_LABEL} ' /etc/fstab || { echo '# KVM: ${vm} / ${vm}-data${d}.qcow2 | posicao ${DISK_POS} (ctrl:backplane:disco) | SCSI target ${d} | serial ${vm}-${DISK_CONTROLLER}-${DISK_BACKPLANE}-${d}' >> /etc/fstab; echo 'LABEL=${DISK_LABEL} ${DATA_MOUNT_DIR}/disk${d} ext4 defaults 0 2' >> /etc/fstab; }\" ]"
        done
        DATA_DISK_RUNCMD+="
  - mount -a
  - chown -R ${VM_USER}:${VM_USER} ${DATA_MOUNT_DIR}"
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
      ExecStart=/usr/local/bin/weed master -mdir=${STATE_DIR}/master -ip=${VM_IP[$vm]} -ip.bind=0.0.0.0 -peers=${MASTER_PEERS} -defaultReplication=${MASTER_DEFAULT_REPLICATION} -volumeSizeLimitMB=${MASTER_VOLUME_SIZE_LIMIT_MB}
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
        # local -- LevelDB embutido vira gargalo de concorrência com
        # múltiplos filers escrevendo ao mesmo tempo.
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
        # 1 processo `weed volume` POR DISCO (como no servidor físico), cada
        # um com sua porta (BASE_PORT + índice do disco) e seu diretório.
        # systemd não faz aritmética em unit template, então são
        # VOLUME_DISKS_PER_NODE units explícitas: weed-volume-disk<N>.service.
        # Helper que traduz índice do disco -> /dev/sdX pelo endereço SCSI
        # (usado na formatação, ver DATA_DISK_RUNCMD acima).
        WEED_UNITS+="
  - path: /usr/local/bin/swfs-disk-dev.sh
    permissions: '0755'
    content: |
      #!/bin/sh
      # uso: swfs-disk-dev.sh <índice do disco = SCSI target> -> imprime /dev/sdX
      for i in \$(seq 1 30); do
          for d in /sys/class/scsi_disk/*:0:\$1:0; do
              if [ -d \"\$d/device/block\" ]; then
                  echo \"/dev/\$(ls \"\$d/device/block\" | head -n 1)\"
                  exit 0
              fi
          done
          sleep 1
      done
      exit 1
"
        WEED_RUNCMD+="
  - systemctl daemon-reload"
        for ((d = 0; d < VOLUME_DISKS_PER_NODE; d++)); do
            DISK_POS="${DISK_CONTROLLER}:${DISK_BACKPLANE}:${d}"
            VOL_PORT=$((SEAWEED_VOLUME_BASE_PORT + d))
            WEED_UNITS+="
  - path: /etc/systemd/system/weed-volume-disk${d}.service
    permissions: '0644'
    content: |
      [Unit]
      Description=SeaweedFS Volume Server - disco ${DISK_POS} (${DATA_MOUNT_DIR}/disk${d}, porta ${VOL_PORT})
      After=network-online.target
      Wants=network-online.target
      RequiresMountsFor=${DATA_MOUNT_DIR}/disk${d}

      [Service]
      ExecStart=/usr/local/bin/weed volume -dir=${DATA_MOUNT_DIR}/disk${d} -mserver=${MASTER_PEERS} -ip=${VM_IP[$vm]} -ip.bind=0.0.0.0 -dataCenter=dc1 -rack=${VM_RACK[$vm]} -port=${VOL_PORT}
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
"
            WEED_RUNCMD+="
  - /usr/local/bin/svc-enable-now.sh weed-volume-disk${d}.service"
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
      ExecStart=/usr/local/bin/weed admin -ip=0.0.0.0 -port=${SEAWEED_ADMIN_PORT} -master=${MASTER_PEERS} -dataDir=${STATE_DIR}/admin -adminUser=${ADMIN_USER} -adminPassword=${ADMIN_PASSWORD}
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

    if [[ "$vm" == "$ADMIN_HOST" ]]; then
        EC_ROTINA_SH_INDENTED=$(printf '%s\n' "$EC_ROTINA_SH" | indent "      ")
        WEED_UNITS+="
  - path: /usr/local/bin/swfs-ec-rotina.sh
    permissions: '0755'
    content: |
${EC_ROTINA_SH_INDENTED}

  - path: /etc/cron.d/swfs-ec
    permissions: '0644'
    content: |
      # Rotina de Erasure Coding (ec.encode + ec.balance). Log: /var/log/swfs-ec-rotina.log
      EC_FULL_PERCENT=${EC_CRON_FULL_PERCENT}
      EC_QUIET_FOR=${EC_CRON_QUIET_FOR}
      EC_BATCH_SIZE=${EC_CRON_BATCH_SIZE}
      EC_MAX_PARALLEL=${EC_CRON_MAX_PARALLEL}
      ${EC_CRON_SCHEDULE} ${VM_USER} /usr/bin/flock -n /tmp/swfs-ec.lock /usr/local/bin/swfs-ec-rotina.sh >> /var/log/swfs-ec-rotina.log 2>&1

  - path: /etc/logrotate.d/swfs-ec
    permissions: '0644'
    content: |
      /var/log/swfs-ec-rotina.log {
          weekly
          rotate 4
          compress
          missingok
          notifempty
      }
"
        WEED_RUNCMD+="
  - touch /var/log/swfs-ec-rotina.log
  - chown ${VM_USER}:${VM_USER} /var/log/swfs-ec-rotina.log"
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
        UPLOAD_DEMO_SERVER_PY_INDENTED=$(printf '%s\n' "$UPLOAD_DEMO_SERVER_PY" | indent "      ")
        UPLOAD_DEMO_ADMIN_HTML_INDENTED=$(printf '%s\n' "$UPLOAD_DEMO_ADMIN_HTML" | indent "      ")
        WEED_UNITS+="
  - path: /var/www/upload-demo/index.html
    permissions: '0644'
    content: |
${UPLOAD_DEMO_HTML_INDENTED}

  - path: /var/www/upload-demo/admin.html
    permissions: '0644'
    content: |
${UPLOAD_DEMO_ADMIN_HTML_INDENTED}

  - path: /var/www/upload-demo/server.py
    permissions: '0644'
    content: |
${UPLOAD_DEMO_SERVER_PY_INDENTED}

  - path: /etc/systemd/system/weed-upload-demo.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Pagina de demo de upload S3 + /admin.html de administracao (so para teste)
      After=network-online.target
      Wants=network-online.target

      [Service]
      WorkingDirectory=/var/www/upload-demo
      Environment=ADMIN_API_BASE=http://${VM_IP[$ADMIN_HOST]}:${SEAWEED_ADMIN_PORT}/api
      Environment=ADMIN_USER=${ADMIN_USER}
      Environment=ADMIN_PASSWORD=${ADMIN_PASSWORD}
      ExecStart=/usr/bin/python3 /var/www/upload-demo/server.py ${SEAWEED_UPLOAD_DEMO_PORT}
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
timezone: America/Sao_Paulo

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
timezone: America/Sao_Paulo

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
