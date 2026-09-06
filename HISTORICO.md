# Histórico — tudo que já foi testado e descoberto neste lab

Registro único, em ordem cronológica, de tudo que foi validado ao vivo
neste lab desde o início. Consolida o que antes estava espalhado em
`RELATORIO.md`, `LICOES-EC-ENTERPRISE.md`, `LABS-TESTES-S3.md` e
`COMANDOS-EC-QUOTA-VERSIONAMENTO.md` (arquivos retirados depois desta
consolidação — ver `README.md` para a arquitetura atual e comandos de
referência). **A partir de agora, cada teste novo vira seu próprio
`POC-N.md`** — este documento só recebe achados já fechados, não vira a
crescer como um relatório corrido único.

---

# Parte 1 — Lab OSS (topologia original: 3 masters + swfs-vol1/vol2)

Testes feitos na primeira versão do lab, antes do rebuild para a
arquitetura Enterprise 5+2 (Parte 2). Topologia: `swfs-master1/2/3`
(raft) + `swfs-vol1` (volume + filer + S3 + admin, rack1) + `swfs-vol2`
(volume, rack2).

## 1.1 Fluxo de recebimento de um arquivo (upload)

Três papéis, cada um responsável por uma parte diferente:
```
Cliente (assina a requisição com AWS Signature V4)
        │  PUT http://swfs-vol1:8333/<bucket>/<chave>
        ▼
Filer (swfs-vol1:8333) — plano de metadado
        │  quebra o arquivo em pedaços (chunks)
        │  para cada chunk, pede ao Master um volume+ID onde gravar
        ▼
Master (raft leader) — plano de controle
        │  responde com um volume já "gravável" existente
        │  se a reserva de volumes graváveis estiver baixa, manda CRIAR
        │  volumes novos nos volume servers (em lote, não um por vez) e
        │  atualiza seu mapa de topologia em memória
        ▼
Volume Server — plano de dados
        │  recebe os bytes DIRETO do filer (não passa pelo master de novo)
        │  grava no arquivo .dat (append) + atualiza o índice .idx
        ▼
Filer grava o "manifesto" do arquivo (lista de chunks) no seu metadado local
```
Ponto chave: o **master nunca vê os bytes do arquivo** — só aloca IDs e
mantém o mapa de "o que está onde". Os bytes trafegam direto entre filer e
volume server — é essa separação que permite o cluster escalar sem o
master virar gargalo.

## 1.2 CPU/memória durante upload paralelo

Teste: 25 arquivos de 200MB (4,9GB total) via `rclone copy --transfers 8`.
Padrão observado: **CPU sobe primeiro nos volume servers** (I/O síncrono e
real: gravar + checksum de cada needle); **memória sobe depois nos
masters**, em rajada — o SeaweedFS cria volumes novos em lote quando a
reserva de "volumes graváveis" fica baixa, e cada volume novo é uma
entrada a mais no mapa de topologia mantido 100% em RAM pelo master.

`buff/cache` alto no gráfico do virt-manager ≠ uso real de processo — é
cache de página do Linux, liberado só quando algum processo precisa da
memória. Confirmar sempre com `free -h` dentro da VM, não pelo gráfico.

## 1.3 O que são os "arquivos de nomes longos" no disco

- **`.dat`/`.idx`/`.vif`** — um **volume físico** por trio: `.dat` são os
  bytes de verdade (append-only, muitos objetos empacotados lado a lado —
  essa é a ideia central do SeaweedFS: evitar 1 arquivo por objeto no
  filesystem); `.idx` mapeia needle→posição no `.dat`; `.vif` é metadado
  do próprio volume. Prefixo com nome de bucket = volume de uma
  *collection* nomeada; sem prefixo = criado antes de qualquer bucket
  existir. **Um volume contém muitos chunks/needles**, não o contrário.
- **`.uploads/*.part`** — não é o volume físico, é a área de **staging do
  S3 Multipart Upload** no namespace do Filer: cada parte de um upload
  multipart vira `NNNN_<uuid>.part` numa pasta de sessão, limpa ao
  `CompleteMultipartUpload`. `rclone` muda pra multipart automaticamente
  acima de `--s3-upload-cutoff` (200MiB por padrão, chunks de 5MiB) — por
  isso apareceu com arquivos de teste de exatamente 200MB. Não aparece no
  `mc ls` (a API S3 filtra de propósito), só navegando a árvore crua do
  Filer/admin dashboard.

## 1.4 Imutabilidade (S3 Object Lock / WORM)

![Comando -> log da limpeza](relatorio-assets/log-limpeza-weed-filer.svg)

- O Filer remove pastas vazias sozinho (`EmptyFolderCleaner`) e mantém um
  índice de "quem é dono de qual bucket" em `/buckets/.system/owners/`,
  também autolimpo — nenhum dos dois foi pedido explicitamente.
- Apagar só o *objeto* não libera volume — só apagar o *bucket* (a
  collection inteira) libera.
- **GOVERNANCE** — bloqueia delete/overwrite da versão travada; uma
  identidade com `s3:BypassGovernanceRetention` pode anular com
  `--bypass`. Protege contra erro operacional, não contra um admin do
  próprio sistema.
- **COMPLIANCE** — mesmo mecanismo de prazo, **sem nenhuma via de
  bypass** — testado com e sem `--bypass`, as duas tentativas voltaram
  `Access Denied`. Nem admin, nem root, nem o operador do cluster
  conseguem apagar antes do prazo vencer. Modo usado quando existe
  exigência regulatória de retenção (WORM). Consequência prática: uma vez
  configurado, nem o próprio administrador do lab tem como desfazer antes
  do prazo — definir um prazo curto em qualquer teste futuro.

## 1.5 Replicação — comportamento padrão do cluster

Bucket sem flag de replicação → `"replication": "000"`. Código de 3
dígitos **datacenter-rack-node** (confirmado forçando cada dígito
isoladamente e lendo o campo que o próprio erro do master devolveu:
`001`→`{"node":1}`, `010`→`{"rack":1}`, `100`→`{"dc":1}`):

| Código | Cópias totais | Onde ficam |
|---|---|---|
| `000` | 1 | nenhuma cópia extra |
| `001` | 2 | outro servidor, mesmo rack |
| `010` | 2 | outro rack, mesmo datacenter |
| `100` | 2 | outro datacenter |
| `110` | 3 | outro datacenter + outro rack |
| `200` | 3 | 2 datacenters extras |

Com `000`: capacidade É somada entre volume servers (pool único), mas
redundância NÃO é automática — cada arquivo vive num volume, em um único
servidor. Racks só **restringem** quais códigos são fisicamente possíveis
(ex.: `001` exige ≥2 servidores no mesmo rack) — "1 rack = sem redundância"
é conclusão errada: quem decide é o código de replicação, não a contagem
de racks.

---

# Parte 2 — Rebuild Enterprise 5+2 (13 VMs)

A partir daqui, topologia: 3 masters+filer (um deles com admin+worker),
`swfs-s3front1` (S3 gateway standalone), `swfs-pgsql01` (metadata store
dos filers), 7 volume nodes, EC 5+2. **Nota**: os achados abaixo (até a
seção 2.12) foram feitos quando cada volume node ainda rodava **2
processos `weed volume` dividindo 1 disco só** (14 "volume servers" no
total) — é essa topologia que causou o bug de capacidade em dobro achado
na seção 2.14. A partir da seção 2.14, o lab passou a usar **1 processo
por node com 8 discos independentes** (ver `README.md` atual) — os
achados anteriores continuam válidos (foram sobre o SeaweedFS em si, não
sobre a contagem de disco), só a contagem exata de "volume servers"
mudou de 14 processos para 7.

## 2.1 Binário Enterprise: de onde vem, o que muda

Mesmo binário `weed`, baixado de `seaweedfs/artifactory` (asset
`weed-enterprise-linux_amd64_large_disk.tar.gz`), não do repo OSS. Sem
licença configurada, roda com trial automático de **25TB**
(`weed version` → `...-enterprise`; log confirma "Using default
enterprise license"). Mesmos flags de master/volume/filer do OSS — o que
muda é o `weed admin` (Recovery, Table Buckets, Service Accounts,
Policies, Concurrency Limits) e recursos internos (Object Lock, quota, EC
customizável).

## 2.2 Object Lock — o que "Set Default Retention" faz de verdade

- **Desmarcado**: Object Lock habilitado, mas nada é retido por padrão —
  só imutável se o upload já vier com headers de retenção.
- **Marcado com N dias**: todo objeto sem header próprio herda essa
  retenção do bucket.
- **"0 dias" não é um terceiro estado** — campo limita 1-36500.
- Ressalva não testada a fundo: issues do GitHub (#8350, #7194) relatam
  que Compliance às vezes não bloqueia o delete de verdade — vale
  reproduzir antes de tratar como garantia sólida.

## 2.3 Quota × Versionamento — a pegadinha que "some" a cota do cliente

`SeaweedFS_s3_bucket_size_bytes` (métrica lógica, é o que a cota compara)
**soma a versão atual + todas as antigas retidas**, não só o arquivo de
hoje — confirmado batendo a soma manual das versões contra a métrica
(<1KB de diferença). Implicação de negócio: cliente com versionamento
ligado consome mais cota a cada edição, mesmo com arquivo final pequeno,
até alguém rodar o lifecycle pra podar o excesso. Mesmo comportamento da
AWS.

## 2.4 Lifecycle não é em tempo real — é um passe diário sharded

`s3.lifecycle.run-shard` no `weed shell` — "manually run one daily-replay
pass". Confirma varredura diária sharded (0-15 partições), igual à AWS —
não reage instantaneamente a "1 dia" na regra. Forçar:
```
s3.lifecycle.run-shard -s3=<ip-s3front>:<porta-s3+10000> -shards=0-15 -refresh=0
```

## 2.5 Métricas de bucket

- `SeaweedFS_s3_bucket_size_bytes` — lógico (soma todas as versões).
- `SeaweedFS_s3_bucket_physical_size_bytes` — físico real (réplicas +
  paridade EC, inclui não-vacuumado).
- `SeaweedFS_s3_bucket_quota_bytes`, `SeaweedFS_s3_bucket_read_only`.
- Expostas via `-metricsPort` do `weed s3` — `fetch()` direto do
  navegador funcionou sem bloqueio de CORS neste build.

## 2.6 Quando um volume vira candidato a EC — e por que não é sobre tempo

Defaults (`weed scaffold -config=admin`): `fullness_ratio=0.95`,
`quiet_for_seconds=3600`, `scan_interval_seconds=3600`, `min_size_mb=30`.
O `weed admin` varre periodicamente procurando candidatos; o `weed
worker` (jobType inclui "heavy"/erasure_coding) executa o trabalho.

**Confirmado ao vivo (05-06/09/2026, ver seção 2.10 abaixo para o relato
completo): o ciclo de varredura é fixo em 30min a partir do restart do
processo `weed-admin`, e `scan_interval_seconds` não tem efeito nenhum**
— baixar esse valor não acelera o ciclo, só muda quem qualifica quando o
ciclo (fixo) rodar.

## 2.7 Por que forçar EC em dado pequeno é um desastre de espaço (medido)

EC manual em 5 volumes de 39KB-1,1MB (~1,9MB total): **73,4MB físicos**
(confirmado por `du` real). Causa raiz (`ec_encoder.go`):
`UniformBlockSize` arredonda cada shard pra cima até o múltiplo de 1MB
mais próximo — todo shard tem no mínimo 1MiB no disco, não importa o
conteúdo real. É por isso que `fullness_ratio=0.95`/`min_size_mb=30`
existem.

**Bug confirmado, 3 vezes independentes, tamanhos crescentes** — reportado
formalmente em `RELATO-EC-RATIO-DEV.md`:

| Run | Dado de origem | Shards no disco | Tamanho de cada | Esperado p/ 5+2 |
|---|---|---|---|---|
| 1 | 5 volumes, 39KB-1,18MB | 14 (`.ec00`-`.ec13`) | 1.048.576 bytes (1MiB) uniforme | 7 |
| 2 | Arquivo de 50 bytes, coleção isolada, ratio confirmado antes do upload | 14 | 1.048.576 bytes | 7 |
| 3 | 1 needle de 30MB (upload direto no volume, bypassando o filer) | 14 | 4.194.304 bytes (4MiB) uniforme | 7 |

`ec.config -set -dataShards=5 -parityShards=2` muda o que `ec.config -get`
mostra, mas **não** o que `weed shell ec.encode` manual grava fisicamente
— sempre o layout clássico 10+4. Não existe flag
`-dataShards`/`-parityShards` no `ec.encode` (só no `ec.config`).
Integridade dos dados confirmada por MD5 idêntico antes/depois em todos os
runs.

**Run 4, feito bem depois (topologia trocada de 14 processos/7 racks para
7 processos/7 racks — seção 2.14) — descarta de vez a hipótese de que o
14 tivesse a ver com a contagem de servidores/racks disponíveis.**
Repetimos o `ec.encode` idêntico no cluster reconstruído (1 processo por
rack, dono de 8 discos, ou seja, agora **de verdade** só 7 volume
servers): resultado, os mesmos **14 shards** de sempre
(`mount 5.[0 1 2 3 4 5 6 7 8 9 10 11 12 13]`), sem mudar nada. Com só 7
alvos reais pra 14 shards, o algoritmo de colocação dobrou/triplicou em
alguns nós (`.51`, `.52`, `.53` ficaram com 3 shards cada; `.54` com 2;
`.55`/`.56`/`.57` com 1). Conclusão: o 10+4 é fixo, não depende do
tamanho do cluster — reforça a teoria de que o `ec.encode` manual chama
um caminho de código diferente (mais antigo, nunca atualizado pra ler
`ec.config`) do que o scanner automático, que lê certinho (seção 2.12).
Texto completo dessa 4ª rodada já incorporado em
`RELATO-EC-RATIO-DEV.md`.

## 2.8 EC não é a "primeira linha de defesa" — replicação é

Doc oficial: *"If the volume is replicated, only one copy will be
erasure encoded. All the original copies will be purged after a
successful erasure encoding."* — a proteção durante a espera pra virar EC
vem da réplica, não do EC. PoC ao vivo: upload com `?replication=010`,
confirmado nos 2 racks via `volume.list`, derrubado o volume server de
uma das 2 cópias — arquivo continuou 100% acessível pela cópia
sobrevivente, sem nenhum EC ter rodado. Rodar EC mais cedo não fecha essa
janela de risco (sempre existe intervalo entre o write e o EC terminar);
só troca "réplica protegendo" por overhead de padding sem necessidade.
**Conclusão prática**: em produção, replicação ≠ `000` é obrigatório pra
proteger dado quente — o `000` deste lab foi escolha deliberada pra
isolar o teste de EC.

## 2.9 Racks não são "tudo ou nada"

`-rack` é rótulo do **servidor** (processo `weed volume` inteiro), não do
volume/arquivo individual. `001` (outro servidor, mesmo rack) protege
contra disco/servidor falhar mesmo com 1 rack só (precisa ≥2 servidores
físicos nele); `010` (outro rack) protege contra o rack inteiro cair.
Quem decide se existe redundância é o código de replicação, não a
contagem de racks.

## 2.10 Onde foi parar o arquivo de 200MB — chunking, não replicação

Investigação pedida diretamente: por que um arquivo de 200MB, com
`replication=000`, não aparece concentrado num rack só? Achado via
manifesto de chunks do Filer (`GET .../arquivo?metadata=true` — devolve o
array `chunks[]`, um needle real por entrada):

- Arquivo (`arquivo_01.bin`, bucket `poc-versioning`, 209.715.200 bytes)
  foi fatiado pelo Filer em **50 chunks de 4MiB** (tamanho padrão de
  chunk do Filer) — não um `.dat` único.
- Os 50 chunks foram distribuídos entre **13 volumes diferentes,
  espalhados pelos 7 racks** (todos os 7 tocados).
- **Por quê, mesmo com `000`**: o código de replicação decide só quantas
  *cópias extras* de cada chunk existem — não tem nada a ver com manter
  os chunks de um mesmo arquivo juntos. O Filer pede ao Master um volume
  gravável a cada chunk (ou lote), e o Master aloca entre qualquer volume
  disponível no momento — 50 pedidos de alocação se espalham pelo pool
  inteiro.
- **Implicação de risco, também confirmada**: com `000`, perder o volume
  que hospeda até 1 desses 50 chunks torna o objeto inteiro irrecuperável
  (a leitura falha no offset daquele chunk) — mesmo que os outros 44MB+
  do arquivo estejam intactos em volumes saudáveis. Não existe
  reconstrução automática sem EC ou réplica.
- **Log de upload**: na verbosidade padrão (sem `-v`), nem `weed-filer`
  nem `weed-volume` logam uploads bem-sucedidos — só eventos de metadado
  e erros. O manifesto de chunks é a fonte de verdade mais granular
  disponível, não um log de acesso.

## 2.11 Shard Distribution da UI mostrando "11 Servers" em vez de 14

Pergunta direta sobre a tela do admin dashboard mostrando `14 Total
Shards / 1 Data Centers / 11 Servers`. Achado via `weed shell
volume.list` (mostra `ec volume id:N ... shards:[...]` por processo):

- Cluster tem 14 processos `weed volume` no total (7 nodes × 2). Um
  espalhamento perfeito daria 1 shard por processo = "14 Servers".
- Real: **3 processos ficaram com 2 shards cada** e **3 processos com
  0** — 11 processos distintos hospedando os 14 shards.
- Risco prático: perder um dos processos "duplicados" custa 2 shards de
  uma vez (metade da margem de segurança do 5+2 real, ou 2/14 do layout
  clássico 10+4 que estava de fato gravado), em vez do risco espalhado
  por 14 falhas independentes.
- `weed shell ec.balance -collection=<c>` é o comando que existe pra
  forçar o espalhamento ideal — ainda não testado neste lab.

## 2.12 EC automático: metade respeita o ratio, metade nunca executa

Teste desenhado especificamente pra responder a pendência "o EC
automático (admin+worker) respeita 5+2?" — resposta completa, com todas
as evidências de log, formalizada em `RELATO-EC-AUTO-STUCK-DEV.md`.
Resumo:

**Setup**: bucket `poc-ec` (criado com `-withLock`), `.dat` ajustado pra
selar em 10GB (`-volumeSizeLimitMB=10240` nos masters alcançáveis), envio
de um arquivo real de 11GB.

**Achado 1 — a suposição de "enche 1 volume até 10GB, abre outro" está
errada.** O Filer não enche sequencialmente: espalha os chunks entre
*todos* os volumes graváveis em paralelo (mesmo padrão da seção 2.10). Os
11GB caíram em 11 volumes diferentes, o maior com só 1,36GB (13,6% de
10GB) — longe do `fullness_ratio=0,95` exigido.

**Achado 2 — só qualificou porque um override antigo (de sessão anterior,
~21h) ainda estava ativo** no `weed-admin` (`fullness_ratio≈0`,
`min_size_mb=1`, `quiet_for_seconds=10`), tornando qualquer volume
"cheio o bastante" na prática.

**Achado 3 — confirma a pendência, pela metade: a detecção automática
RESPEITA o ratio configurado.** Log do scan, pra cada um dos 25 volumes
candidatos: `"planning destinations for volume N with EC ratio 5+2"` →
`"Successfully planned 7 destinations"` — 7 = 5+2, certinho, em 100% dos
volumes. Ao contrário do `ec.encode` manual (seção 2.7), que sempre trava
em 14 (10+4).

**Achado 4 — mas a tarefa planejada nunca é executada.** A cada scan
(fixo em 30min), o admin cancela as tarefas `erasure_coding` pendentes do
ciclo anterior e recria idênticas (`"Cancelled N stale pending
erasure_coding tasks before re-detection"`, 41 ocorrências em 45 scans).
O `weed-worker` está saudável e processa outros tipos de tarefa sem
problema (177 execuções de `balance`/`ec_balance` em 22h) — mas **zero
execuções do tipo `erasure_coding`** no mesmo período. A tarefa fica
presa num loop infinito: detectar → planejar (certo) → enfileirar →
cancelar → re-detectar, pra sempre, sem nunca rodar.

**Achado 5 (reconfirma a seção 2.6) — `scan_interval_seconds` é mesmo
ignorado.** 45 scans desde o último restart do `weed-admin`, todos
exatamente em `:13:54`/`:43:54` — ciclo fixo de 30min, mesmo com o
override pedindo 15s.

## 2.13 Limpeza do ambiente (rodada OSS)

Ao final da primeira rodada de testes (Parte 1), todo bucket/objeto foi
apagado e os volumes "avulsos" removidos direto no disco dos volume
servers (`weed-volume` parado, `.dat`/`.idx`/`.vif` apagados, serviço
religado — o processo solta os arquivos e reporta ao master que não tem
volume nenhum). Confirmado via `/dir/status`: `Max: 16, Free: 16,
Volumes: 0` nos dois racks, igual ao estado logo após o deploy.

## 2.14 Dashboard mostrando ~2x a capacidade real — e a correção definitiva

Pergunta direta do usuário: por que o dashboard admin (`/cluster/volume-servers`, `/storage/tiering`) mostrava um total de **956,9GB**, quando a capacidade física real do cluster era só **490GB** (7 nodes × 70GB)?

**Investigação**: comparei o `/status` (campo `DiskStatuses`) dos 2 processos `weed volume` do mesmo node (`swfs-node01`, portas 8080/8081) — **valores byte-a-byte idênticos** (`used`/`free`/`percent_free` iguais). Motivo: `/data/volume0` e `/data/volume1` eram só duas subpastas do **mesmo disco** (`/dev/vdb`, confirmado via `df`/`findmnt`/`lsblk`) — `statfs()` (a syscall por trás do `df` e do relatório de disco do `weed volume`) mede o **filesystem inteiro**, não a pasta específica. Cada processo reportava o disco físico inteiro como se fosse só dele; o dashboard, ao somar a capacidade de todos os "volume servers" registrados, não deduplicava por device — resultado: cada disco físico contado 2x (`14 processos × ~69,6GB ≈ 975GB`, bem perto dos 956,9GB mostrados).

**Veredito**: não é um bug clássico do SeaweedFS (o `statfs` por processo está correto — é o comportamento padrão de qualquer ferramenta baseada nele, `df` inclusive). É uma consequência direta da topologia do lab: 2 processos `weed volume` **compartilhando 1 disco físico só**, artifício usado pra simular "2 discos por node" com metade do hardware. Em produção (1 processo por servidor, cada disco um device de verdade) isso nunca aconteceria.

**Correção aplicada** (a pedido do usuário, pra aproximar da topologia real da empresa: 8 servidores, 1 desligado, 7 ativos, 8 discos de verdade cada):
- `00-config.env`: `VOLUME_DISKS_PER_NODE=8` discos **independentes** por volume node (arquivos `.qcow2` separados = devices virtio separados, não partições de 1 disco), 9GB cada (504GB brutos no total — escala de lab, mantendo a lógica dos 8 discos reais da empresa sem tentar replicar os 20TB/disco literais).
- `02-criar-discos.sh` / `05-criar-vms.sh`: criam e anexam os 8 discos (`-data1.qcow2` .. `-data8.qcow2`) como devices separados (`/dev/vdb` .. `/dev/vdi`).
- `04-gerar-cloud-init.sh`: cada device formatado e montado em `/data/disk1` .. `/data/disk8` (8 filesystems reais, não 8 pastas de 1 filesystem); **1 processo `weed volume` por node** (não mais 2), usando `-dir=/data/disk1,/data/disk2,...,/data/disk8` — é o jeito nativo do SeaweedFS de gerenciar um servidor multi-disco, e resolve o double-counting na raiz (cada disco vira um `statfs` próprio).
- `06-status.sh`: checagem de disco/serviço ajustada pra 1 processo + N mountpoints.

Efeito colateral bom, não só cosmético: antes, os 2 processos de um mesmo node apareciam pro Master como 2 "DataNodes" diferentes na mesma rack — o que pode ter contribuído pro achado da seção 2.11 (shards EC se concentrando "no mesmo servidor" sem que isso fosse óbvio, já que pareciam ser 2 servidores distintos). Com 1 processo por node, a topologia que o Master enxerga bate exatamente com a física: 1 rack = 1 servidor de verdade.

---

# Parte 3 — Infraestrutura do lab (achados operacionais, não do SeaweedFS)

## 3.1 Identidade S3 e `mc`

- O filer só aceita requisição **assinada** (todo cliente S3 de verdade —
  `mc`, `rclone`, `boto3`, `aws-cli`, `warp` — assina, mesmo com
  credenciais inventadas) se tiver uma identidade real configurada via
  `-s3.config`. Sem isso: `Signed request requires setting up SeaweedFS
  S3 authentication`. Corrigido criando `s3.json` e adicionando
  `-s3.config` ao `ExecStart` do serviço — **persistido** depois em
  `00-config.env` (`S3_ACCESS_KEY`/`S3_SECRET_KEY`) e
  `04-gerar-cloud-init.sh`, então qualquer redeploy já sobe com a
  identidade de fábrica.
- `dl.min.io` (download do `mc`) responde com redirect 302 pro GitHub —
  `curl -L` é obrigatório, senão `-O` sozinho salva a página HTML do
  redirect (~141 bytes) em vez do binário.

## 3.2 Fuso horário — corrigido de vez em 2026-09-06

Todas as VMs nascem de imagem cloud do Ubuntu em `Etc/UTC` por padrão —
nunca tinha sido configurado no cloud-init. Isso já tinha sido corrigido
uma vez em runtime (30/08/2026, via `timedatectl` direto nas VMs), mas
**não sobrevivia a um redeploy** (a VM recriada voltava pra UTC). Corrigido
de vez em 06/09/2026: adicionado `timezone: America/Sao_Paulo` nos dois
templates de cloud-init (`04-gerar-cloud-init.sh`, VMs normais e
roteador) — qualquer VM nova ou lab reconstruído já nasce no fuso
correto, sem passo manual.

## 3.3 SSH instável em algumas VMs sob carga do host

Observado em 06/09/2026: com as 13 VMs + `weed` de pé, o `sshd` de
algumas VMs específicas passou a responder `Connection reset by peer`
logo após o handshake TCP (`kex_exchange_identification`), de forma
consistente (não uma falha isolada) — mas **o processo `weed` daquelas
mesmas VMs continuou 100% saudável** (confirmado via `curl` nos endpoints
HTTP e `/cluster/status` mostrando os processos ativos e participando do
raft normalmente). Host nessa hora: `load average ~2.47`, ~1.8GB em swap
usado de 8GB. Hipótese mais provável: pressão de recursos do host afetando
especificamente o `sshd` (não o `weed`) nessas VMs — não investigado a
fundo por não bloquear o trabalho (o `weed shell`/API HTTP não depende de
SSH). Se acontecer de novo: usar o console gráfico
(`virt-manager`/`virt-viewer`) como alternativa — ver README.

## 3.4 Rota direta do host pra rede do lab (não documentada nos scripts)

Em algum momento passou a existir uma rota estática no host
(`192.168.100.0/24 via 192.168.122.150 dev virbr0`) que permite SSH/curl
diretos às VMs do lab a partir do terminal do host, sem
`ProxyCommand`/`ProxyJump` pelo roteador. **Essa rota não é criada por
nenhum script deste repositório** (`03-configurar-rede.sh` não mexe na
tabela de rotas do host) e não sobrevive a um reboot — foi adicionada
manualmente em algum momento. O acesso via `ProxyJump` continua sendo o
caminho garantido e documentado (README); a rota direta é só um atalho
observado, não uma dependência.

## 3.5 Acesso ao lab — nem sempre um terminal SSH do host

O jeito real de interagir com o lab é misto: às vezes console gráfico
(virt-manager, como um monitor conectado na VM), às vezes SSH do host —
depende do que a rede permite no momento (ver 3.4) e do que está sendo
depurado. Documentação/runbooks devem separar claramente qual comando
roda onde, em vez de assumir um único modo — foi fonte de confusão real
em versões anteriores dos docs deste lab.

---

# Relatos formais enviados/prontos para o dev

Os dois relatos abaixo também existem como arquivos standalone —
[RELATO-EC-RATIO-DEV.md](RELATO-EC-RATIO-DEV.md) e
[RELATO-EC-AUTO-STUCK-DEV.md](RELATO-EC-AUTO-STUCK-DEV.md) — prontos pra
copiar e enviar em inglês pro dev/suporte da SeaweedFS. Texto completo
reproduzido aqui para o histórico ficar autocontido.

## Relato 1 — `ec.encode` (weed shell) does not honor the configured EC ratio

### Environment

- SeaweedFS Enterprise, `weed version` → `8000GB 4.45-enterprise` (binary `weed-enterprise-linux_amd64_large_disk.tar.gz`, `seaweedfs/artifactory` releases, tag `4.45.1`).
- Default enterprise trial license (25TB), no custom license file.
- Cluster: 3 masters (raft) + filer (Postgres store) each, 1 standalone `weed s3`, 7 volume nodes.
- `ec.config -get` confirmed **`Global Default EC Ratio: 5+2`** before every test below.

### Summary

`ec.config -set -dataShards=5 -parityShards=2` updates what `ec.config -get` reports, and is saved to `/etc/seaweedfs/ec.conf` on the filer ("✓ Configuration saved to filer at /etc/seaweedfs/ec.conf"). However, running `ec.encode` manually via `weed shell` still physically writes the **classic 14-shard (10+4) layout** — `.ec00` through `.ec13` — instead of 7 shards. Confirmed 3 times independently, at increasing data sizes, ruling out a small-file/padding artifact.

### Steps to reproduce

```
# 1. Set the ratio and confirm it's active
weed shell -master=localhost:9333
> ec.config -set -dataShards=5 -parityShards=2
Global default EC ratio set to 5+2
✓ Configuration saved to filer at /etc/seaweedfs/ec.conf
> ec.config -get
Global Default EC Ratio: 5+2

# 2. Upload a normal (non-EC) volume with real data (any size — see results below)

# 3. Force-encode it (bypassing the fullness/quiet-time scheduler gates,
#    since we're testing manually rather than waiting for the automatic
#    admin+worker maintenance scan):
> lock
> ec.encode -volumeId=<id> -quietFor=0s -fullPercent=0
> unlock

# 4. Count the actual .ecNN shard files written to the volume servers'
#    data directories for that volume id.
```

### Results (3 independent runs)

| Run | Source data | Shard files found | Shard size (each) | Expected for 5+2 |
|---|---|---|---|---|
| 1 | 5 volumes, 39KB–1.18MB (poc-bucket) | **14 per volume** (`.ec00`–`.ec13`) | 1,048,576 bytes (1 MiB) uniform | 7 per volume |
| 2 | Fresh 50-byte file, isolated collection, ratio confirmed set *before* upload | **14** (`.ec00`–`.ec13`) | 1,048,576 bytes (1 MiB) uniform | 7 |
| 3 | Single 30MB needle (uploaded directly to a volume server, bypassing filer chunking, to rule out multi-chunk artifacts) | **14** (`.ec00`–`.ec13`) | 4,194,304 bytes (4 MiB) uniform | 7 |

Physical disk usage in all 3 runs matched `bucket_physical_size_bytes` almost exactly (confirmed via `du`/direct file listing on every volume node), so this isn't a metrics-reporting bug — the encoder itself is writing 14 real shard files.

Data integrity was verified after EC in run 3 (MD5 identical before/after, read back via the master-resolved file id).

### Run 4 — ruling out a topology-count coincidence

After runs 1-3, a reasonable alternate hypothesis came up: what if 14 isn't hardcoded, but happens to match some property of *that* cluster (e.g. total volume-server process count)? At the time of runs 1-3 the cluster had 14 `weed volume` **processes** spread across 7 racks (2 processes/rack, sharing 1 disk each — an artifact of the lab, not of SeaweedFS).

We since rebuilt the same cluster with **1 `weed volume` process per rack, each process owning 8 independent disks** (so now genuinely 7 volume-server processes, 7 racks, not 14 of anything). Re-ran the identical manual `ec.encode` reproduction on this new topology:

```
mount 5.[0 1 2 3 4 5 6 7 8 9 10 11 12 13]
```

Still exactly **14 shards** (`.ec00`-`.ec13`) — unchanged despite the process/rack count changing from 14 to 7. This rules out any dependency on the number of available volume servers or racks: 10+4 is emitted regardless of cluster size. With only 7 real placement targets for 14 shards, the placement logic just doubled/tripled up on some of them:

| Node | Shards | Count |
|---|---|---|
| .51 | 0, 6, 10 | 3 |
| .52 | 8, 9, 13 | 3 |
| .53 | 1, 7, 11 | 3 |
| .54 | 2, 12 | 2 |
| .55 | 3 | 1 |
| .56 | 4 | 1 |
| .57 | 5 | 1 |

### Working theory

Given the automatic maintenance-scanner path (`detection.go`, see Relato 2 below) *does* correctly read `ec.config` and plan `dataShards+parityShards` destinations, while the manual `weed shell ec.encode` command does not (confirmed across 4 runs, 2 different cluster topologies), our best guess is that this build has **two independent EC-encoding code paths**: a newer one wired to the configurable ratio (used by the automatic scanner), and an older/legacy one still hardcoded to the classic OSS 10+4 split (used by the manual shell command). Not a topology artifact — a real inconsistency between two code paths in the same binary.

## Relato 2 — automatic EC maintenance task is correctly planned (respects configured ratio) but never executed

### Environment

- SeaweedFS Enterprise, `weed version` → `8000GB 4.45-enterprise 7032a2d3` (same build as Relato 1).
- Cluster: 3 masters (raft) + filer (Postgres store), 1 standalone `weed s3`, 7 volume nodes (14 volume server processes), `weed admin` + `weed worker -jobType=all` both on the same host as master1.
- `ec.config -get` confirmed **`Global Default EC Ratio: 5+2`** throughout the test and at report time.
- `weed-admin` had been running for ~21h with a maintenance-threshold override already active (`/etc/systemd/system/weed-admin.service.d/override.conf`):
  ```
  WEED_MAINTENANCE_ERASURE_CODING_FULLNESS_RATIO=0.0000001
  WEED_MAINTENANCE_ERASURE_CODING_QUIET_FOR_SECONDS=10
  WEED_MAINTENANCE_ERASURE_CODING_SCAN_INTERVAL_SECONDS=15
  WEED_MAINTENANCE_ERASURE_CODING_MIN_SIZE_MB=1
  ```
  Confirmed loaded into the live process via `/proc/<pid>/environ`.

### Summary

Follow-up to Relato 1. We wanted to confirm whether the **automatic path** (the `weed admin` maintenance scanner + `weed worker`) respects the configured ratio, since the manual shell command does not.

**Good news:** the automatic detection/planning logic does respect the configured ratio — for every volume it evaluated, it explicitly planned **7 destinations (5 data + 2 parity)**, matching `ec.config`.

**Bug:** despite being planned correctly, the resulting `erasure_coding` maintenance task is **never dispatched to / executed by the worker**. It sits in a `pending` state, gets cancelled and recreated identically on every subsequent scan, forever. Over 22h of continuous `weed-worker` uptime (with `-jobType=all`), **zero** `erasure_coding` tasks executed, while **177** `balance`/`ec_balance` tasks executed successfully in the same window — so the worker itself is healthy and does process other maintenance task types.

There's also a secondary, previously-suspected finding we can now confirm with full history: `WEED_MAINTENANCE_ERASURE_CODING_SCAN_INTERVAL_SECONDS` has no effect — the scan cadence is fixed at 30 minutes from the `weed-admin` process start time, regardless of this env var.

### Steps to reproduce

```
# 1. Confirm ratio is set
weed shell -master=<master>:9333
> ec.config -get
Global Default EC Ratio: 5+2

# 2. Lower maintenance thresholds so any small/quiet volume qualifies
#    (systemd override on weed-admin.service, or scaffold config):
Environment=WEED_MAINTENANCE_ERASURE_CODING_FULLNESS_RATIO=0.0000001
Environment=WEED_MAINTENANCE_ERASURE_CODING_QUIET_FOR_SECONDS=10
Environment=WEED_MAINTENANCE_ERASURE_CODING_MIN_SIZE_MB=1
systemctl daemon-reload && systemctl restart weed-admin

# 3. Upload any real data so at least one normal (non-EC) volume exists
#    and goes quiet (no more writes for >10s).

# 4. Wait for a maintenance scan (fixed ~30min cadence from weed-admin's
#    last restart — see "scan interval" finding below) and inspect the
#    admin log:
journalctl -u weed-admin | grep -E "EC Detection|Task queued|Cancelled.*stale pending|Maintenance scan completed"

# 5. Inspect the worker log for actual execution:
journalctl -u weed-worker | grep -c erasure_coding   # count of any erasure_coding activity
journalctl -u weed-worker | grep -cE "balance_task|ec_balance_task"   # control: other task types
```

### Evidence

**1. Detection/planning respects the configured 5+2 ratio (all 25 candidate volumes, one scan):**
```
I0906 16:43:54.486162 admin_server.go:2349 Loaded EC configuration from filer /etc/seaweedfs/ec.conf: global=5+2, 0 collection overrides
I0906 16:43:54.486288 detection.go:252 EC Detection: Volume 22 meets all criteria, attempting to create task
I0906 16:43:54.486319 detection.go:282 EC Detection: ActiveTopology available, planning destinations for volume 22 with EC ratio 5+2
I0906 16:43:54.486391 detection.go:300 EC Detection: Successfully planned 7 destinations for volume 22
... (identical "Successfully planned 7 destinations" line for all 25 volumes: 22, 45-57, 66-76)
```

**2. The resulting task is queued, but with a self-cancelling lifecycle — every scan cancels the prior batch and recreates it from scratch:**
```
I0906 16:43:54.484270 maintenance_integration.go:277 Cancelled 14 stale pending erasure_coding tasks before re-detection
I0906 16:43:54.499695 maintenance_queue.go:205 Task queued: ec_vol_22_1788713034 (erasure_coding) volume 22 on 192.168.100.52:8080, priority 0, reason: Volume meets EC criteria: quiet for 72590.5s (>10s), fullness=0.0% (>0.0%), size=5.0MB (>1MB)
... (25 such "Task queued" lines total)
I0906 16:43:54.503926 maintenance_manager.go:367 Maintenance scan completed: found 29 tasks
```
`"Cancelled N stale pending erasure_coding tasks before re-detection"` appeared **41 times** in the admin log — i.e. on almost every one of the 45 scans since the last `weed-admin` restart, confirming this cancel+recreate cycle is systematic, not a one-off.

**3. The worker never actually runs an `erasure_coding` task, despite running other task types fine:**
```
$ journalctl -u weed-worker | grep -c 'erasure_coding'
0
$ journalctl -u weed-worker | grep -cE 'balance_task|ec_balance_task'
177
```
Sample of what the worker *does* execute successfully in the same window (task types `balance` and `ec_balance`, both unrelated to the stuck `erasure_coding` type):
```
I0906 16:17:03.367418 task.go:63 Starting balance task - moving volume
I0906 16:20:19.916735 balance_task.go:91 Balance task completed successfully: volume 17 moved from 192.168.100.53:8080.18080 to 192.168.100.54:8080.18080
I0906 16:45:00.786589 ec_balance_task.go:204 EC balance volume 8: [10.00] copying EC shard(s) 8.[1] from 192.168.100.53:8081 to 192.168.100.53:8080
I0906 16:45:01.064091 ec_balance_task.go:134 EC balance: successfully moved shard(s) [1] of volume 8 from 192.168.100.53:8081 to 192.168.100.53:8080
```
Worker was started with `-jobType=all` (`/usr/local/bin/weed worker -admin=<host>:23646 -jobType=all -workingDir=/var/lib/seaweedfs/worker`), so this isn't a job-type filtering flag issue on the worker side.

**4. Scan interval env var confirmed to have no effect — 45/45 scans landed on a fixed 30-minute grid from process start (`weed-admin` last restarted `2026-09-05 20:13:52`), despite `WEED_MAINTENANCE_ERASURE_CODING_SCAN_INTERVAL_SECONDS=15`:**
```
Sep 05 20:43:54 ... Maintenance scan completed: found 6 tasks
Sep 05 21:13:54 ... Maintenance scan completed: found 12 tasks
Sep 05 21:43:54 ... Maintenance scan completed: found 11 tasks
...
Sep 06 16:43:54 ... Maintenance scan completed: found 29 tasks
Sep 06 17:13:54 ... Maintenance scan completed: found 29 tasks
```
Every timestamp is exactly `:13:54` or `:43:54`, i.e. a fixed 1800s period, never 15s.

### Impact

In a cluster relying on the automatic maintenance scheduler (rather than manually invoking `ec.encode`, which we already reported ignores the ratio too), **volumes that qualify for erasure coding never actually get encoded** — they stay in their original, unprotected replication state indefinitely, even though the dashboard/logs show the system correctly identifying them as candidates and correctly planning a 5+2 layout for them. This is a silent failure: there's no error, just an endless detect → plan → queue → cancel → re-detect loop.

# Pendências / próximos passos

1. Confirmar se `weed shell ec.balance -collection=<c>` corrige a
   concentração de 2 shards no mesmo servidor (seção 2.11).
2. Aguardar resposta do dev/suporte sobre os dois relatos formais acima —
   não há workaround conhecido ainda para o EC automático travado.
3. Ver `POCS.md` para o índice dos testes documentados individualmente a
   partir de agora.
4. Cada teste novo a partir de agora vira um `POC-N.md` isolado — ver
   organização de diretórios no `README.md`.
