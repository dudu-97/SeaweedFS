#!/usr/bin/env bash
# =====================================================================
# 09-provisionar-cliente.sh — menu interativo para provisionar 1 cliente
# migrando de AWS: cria o usuário com a MESMA access key/secret key que
# ele já usava na AWS (transparente pro cliente), depois o bucket já
# como dono desse usuário, com imutabilidade/versionamento/cota/
# lifecycle definidos no menu.
#
# Usa a API REST do `weed admin` (mesma engrenagem por trás da dashboard
# em ${ADMIN_HOST}:${SEAWEED_ADMIN_PORT}), na ordem exigida pela própria
# API: 1) usuário  2) chave de acesso  3) bucket (já com owner=usuário)
# 4) lifecycle (limite de versões não-correntes).
#
# Hoje é 1 cliente por execução (menu -> resumo -> aplicar). Provisionar
# em massa (ex.: ler a tabela de clientes de um CSV) fica para depois.
#
# Segurança: no estado atual do lab, `weed admin` sobe sem
# -adminUser/-adminPassword (ver 04-gerar-cloud-init.sh) -- a API fica
# sem autenticação e em HTTP puro (sem TLS). Isso é aceitável pra um
# lab isolado, mas este script está lidando com credenciais AWS reais
# de clientes migrando -- antes de repetir esse processo em produção,
# vale configurar autenticação no `weed admin` e considerar TLS na
# frente dele (ex.: reverse proxy).
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-config.env"

ADMIN_IP="${VM_IP[$ADMIN_HOST]}"
BASE_URL="http://${ADMIN_IP}:${SEAWEED_ADMIN_PORT}/api"
RESP_TMP="$(mktemp)"
trap 'rm -f "$RESP_TMP"' EXIT

# --- helpers -----------------------------------------------------------

# call_api METHOD PATH [JSON_BODY]  ->  imprime o http_code, corpo fica em $RESP_TMP
call_api() {
    local method="$1" path="$2" body="${3:-}"
    if [[ -n "$body" ]]; then
        curl -sS -o "$RESP_TMP" -w '%{http_code}' -X "$method" \
            -H 'Content-Type: application/json' \
            --data-binary @- "$BASE_URL$path" <<<"$body"
    else
        curl -sS -o "$RESP_TMP" -w '%{http_code}' -X "$method" "$BASE_URL$path"
    fi
}

# apply_step "descrição" METHOD PATH [JSON_BODY]  -> aborta se não vier 2xx
apply_step() {
    local desc="$1" method="$2" path="$3" body="${4:-}"
    echo -n "==> ${desc}... "
    local code
    code=$(call_api "$method" "$path" "$body")
    if [[ "$code" == 2* ]]; then
        echo "ok (HTTP $code)"
    else
        echo "FALHOU (HTTP $code)"
        echo "--- resposta da API ---"
        cat "$RESP_TMP"
        echo
        echo "Abortado. Nada depois deste passo foi aplicado."
        exit 1
    fi
}

# --- checagem de conectividade -----------------------------------------

if ! curl -sS -o /dev/null -m 5 "$BASE_URL/config" 2>/dev/null; then
    echo "Não consegui alcançar o weed admin em ${BASE_URL}."
    echo "Confirme que ${ADMIN_HOST} (${ADMIN_IP}) está de pé e que o host"
    echo "tem rota até a rede do lab (veja 06-status.sh)."
    exit 1
fi

# --- menu ----------------------------------------------------------------

echo "=== Provisionar novo cliente (bucket + usuário admin) ==="
echo

read -r -p "Identificador do cliente (usado como bucket E como usuário, ex: codigo-do-cliente): " CLIENT_ID
if [[ -z "$CLIENT_ID" ]]; then
    echo "Identificador não pode ser vazio."
    exit 1
fi
BUCKET_NAME="$CLIENT_ID"
USERNAME="$CLIENT_ID"

read -r -p "Access Key ID (a mesma que o cliente já usava na AWS): " ACCESS_KEY
if [[ -z "$ACCESS_KEY" ]]; then
    echo "Access Key ID não pode ser vazio."
    exit 1
fi

read -rs -p "Secret Access Key (a mesma da AWS, não fica visível ao digitar): " SECRET_KEY
echo
if [[ -z "$SECRET_KEY" ]]; then
    echo "Secret Access Key não pode ser vazio."
    exit 1
fi

echo
read -r -p "Ativar imutabilidade (Object Lock)? [s/N] " WANT_LOCK
if [[ "$WANT_LOCK" =~ ^[Ss]$ ]]; then
    OBJECT_LOCK_ENABLED=true
    read -r -p "  Modo [GOVERNANCE/COMPLIANCE]: " OBJECT_LOCK_MODE
    OBJECT_LOCK_MODE="${OBJECT_LOCK_MODE^^}"
    if [[ "$OBJECT_LOCK_MODE" != "GOVERNANCE" && "$OBJECT_LOCK_MODE" != "COMPLIANCE" ]]; then
        echo "Modo inválido (precisa ser GOVERNANCE ou COMPLIANCE)."
        exit 1
    fi
    read -r -p "  Dias de retenção padrão (aplicados a cada objeto novo): " OBJECT_LOCK_DAYS
    SET_DEFAULT_RETENTION=true
else
    OBJECT_LOCK_ENABLED=false
    OBJECT_LOCK_MODE=""
    OBJECT_LOCK_DAYS=0
    SET_DEFAULT_RETENTION=false
fi

echo
echo "Versionamento é obrigatório aqui (é o que sustenta o Object Lock e"
echo "o limite de versões não-correntes abaixo) — já entra habilitado."

echo
read -r -p "Quantas versões NÃO-correntes manter, além da corrente? (padrão 2) " KEEP_NONCURRENT
KEEP_NONCURRENT="${KEEP_NONCURRENT:-2}"
if ! [[ "$KEEP_NONCURRENT" =~ ^[0-9]+$ ]]; then
    echo "Precisa ser um número inteiro."
    exit 1
fi

echo
read -r -p "Cota do bucket — tamanho (Enter = sem cota): " QUOTA_SIZE
if [[ -n "$QUOTA_SIZE" ]]; then
    if ! [[ "$QUOTA_SIZE" =~ ^[0-9]+$ ]]; then
        echo "Tamanho de cota precisa ser um número inteiro."
        exit 1
    fi
    read -r -p "  Unidade [MB/GB/TB] (padrão GB): " QUOTA_UNIT
    QUOTA_UNIT="${QUOTA_UNIT:-GB}"
    QUOTA_UNIT="${QUOTA_UNIT^^}"
    QUOTA_ENABLED=true
else
    QUOTA_SIZE=0
    QUOTA_UNIT="GB"
    QUOTA_ENABLED=false
fi

# --- resumo ----------------------------------------------------------------

echo
echo "=== Resumo — confira antes de aplicar ==="
printf "%-28s %s\n" "Identificador do cliente:" "$CLIENT_ID"
printf "%-28s %s\n" "Bucket:" "$BUCKET_NAME"
printf "%-28s %s\n" "Usuário (dono do bucket):" "$USERNAME"
printf "%-28s %s\n" "Access Key ID:" "$ACCESS_KEY"
printf "%-28s %s\n" "Secret Access Key:" "(oculto — $(( ${#SECRET_KEY} )) caracteres)"
if $OBJECT_LOCK_ENABLED; then
    printf "%-28s %s\n" "Imutabilidade (Object Lock):" "ativada — modo $OBJECT_LOCK_MODE, ${OBJECT_LOCK_DAYS} dia(s) padrão"
else
    printf "%-28s %s\n" "Imutabilidade (Object Lock):" "desativada"
fi
printf "%-28s %s\n" "Versionamento:" "ativado (obrigatório)"
printf "%-28s %s\n" "Versões não-correntes:" "$KEEP_NONCURRENT (além da corrente)"
if $QUOTA_ENABLED; then
    printf "%-28s %s\n" "Cota:" "${QUOTA_SIZE}${QUOTA_UNIT}"
else
    printf "%-28s %s\n" "Cota:" "sem cota"
fi
echo
echo "Ordem de aplicação: 1) criar usuário  2) anexar access key/secret"
echo "3) criar bucket (owner=$USERNAME)  4) aplicar lifecycle"
echo

read -r -p "Aplicar? [s/N] " CONFIRM
if ! [[ "$CONFIRM" =~ ^[Ss]$ ]]; then
    echo "Cancelado, nada foi criado."
    exit 0
fi

echo

# --- aplicação (ordem: usuário -> chave -> bucket -> lifecycle) -----------

USER_BODY=$(cat <<JSON
{"username":"${USERNAME}","email":"","actions":["Admin:${BUCKET_NAME}"],"generate_key":false,"policy_names":[]}
JSON
)
apply_step "Criando usuário ${USERNAME}" POST "/users" "$USER_BODY"

KEY_BODY=$(cat <<JSON
{"access_key":"${ACCESS_KEY}","secret_key":"${SECRET_KEY}"}
JSON
)
apply_step "Anexando access key/secret ao usuário" POST "/users/${USERNAME}/access-keys" "$KEY_BODY"

BUCKET_BODY=$(cat <<JSON
{"name":"${BUCKET_NAME}","region":"","quota_size":${QUOTA_SIZE},"quota_unit":"${QUOTA_UNIT}","quota_enabled":${QUOTA_ENABLED},"versioning_enabled":true,"object_lock_enabled":${OBJECT_LOCK_ENABLED},"object_lock_mode":"${OBJECT_LOCK_MODE}","set_default_retention":${SET_DEFAULT_RETENTION},"object_lock_duration":${OBJECT_LOCK_DAYS},"owner":"${USERNAME}"}
JSON
)
apply_step "Criando bucket ${BUCKET_NAME} (owner=${USERNAME})" POST "/s3/buckets" "$BUCKET_BODY"

LIFECYCLE_BODY=$(cat <<JSON
{"bucket":"${BUCKET_NAME}","rules":[{"status":"Enabled","newer_noncurrent_versions":${KEEP_NONCURRENT}}]}
JSON
)
apply_step "Aplicando lifecycle (manter ${KEEP_NONCURRENT} versão(ões) não-corrente(s))" PUT "/s3/buckets/${BUCKET_NAME}/lifecycle" "$LIFECYCLE_BODY"

echo
echo "Cliente ${CLIENT_ID} provisionado: bucket '${BUCKET_NAME}', usuário"
echo "'${USERNAME}' (access key ${ACCESS_KEY}) como admin do bucket."
