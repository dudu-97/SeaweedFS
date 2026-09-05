# Lições aprendidas — rebuild Enterprise 5+2 (masters/filer/pgsql/s3front/7 volume nodes)

Registro histórico do debate e das descobertas feitas testando o lab
Enterprise (topologia 5+2 inspirada na arquitetura da empresa: LVS +
s3front + master/filer + pgsql + 7 volume nodes). Cada seção é uma
dúvida real que surgiu, o que foi testado ao vivo pra responder, e a
conclusão. Ver `RELATORIO.md` para os testes da rodada anterior (lab
OSS, replicação `000`/`010`).

## 1. Binário Enterprise: de onde vem, e o que muda

- Mesmo binário `weed`, baixado de outro repositório de releases
  (`seaweedfs/artifactory`, asset `weed-enterprise-linux_amd64_large_disk.tar.gz`),
  não do `seaweedfs/seaweedfs` (OSS). Sem autenticação pra baixar.
- Sem arquivo de licença configurado, roda com **trial padrão automático
  de 25TB** — mais que suficiente pra qualquer lab. `weed version` mostra
  `4.45-enterprise`; o log de boot do filer/s3 confirma
  `"Using default enterprise license (25TB capacity)"`.
- Mesmos flags do OSS pra master/volume/filer — o que muda de verdade é
  o `weed admin` (UI com Recovery/Point-in-Time Recovery, Table Buckets,
  Service Accounts, Policies, Concurrency Limits) e recursos internos
  (Object Lock, quota, EC customizável).

## 2. Object Lock — Governance vs Compliance, e o que "Set Default Retention" faz

- **Desmarcado**: bucket fica com Object Lock habilitado (capacidade
  existe, versionamento liga automático), mas nenhum objeto é retido
  por padrão — só fica imutável se o próprio upload já vier com headers
  de retenção (`x-amz-object-lock-mode` + `x-amz-object-lock-retain-until-date`).
- **Marcado com N dias**: todo objeto que chega **sem** header próprio
  herda essa retenção padrão do bucket automaticamente.
- **"0 dias" não é um terceiro estado** — o campo já limita 1-36500 (e o
  próprio schema do S3 Object Lock exige inteiro positivo). Não existe
  "marcado com retenção zero" via API/UI padrão.
- **Governance**: alguém com a permissão especial
  (`s3:BypassGovernanceRetention` / header `x-amz-bypass-governance-retention: true`)
  ainda consegue apagar antes do prazo. **Compliance**: ninguém consegue,
  nem root.
- **Ressalva encontrada, não testada a fundo**: issues abertas no GitHub
  (`#8350`, `#7194`) relatam que o modo Compliance às vezes não bloqueia
  o delete de verdade. Vale reproduzir no próprio lab antes de tratar
  como garantia sólida.

## 3. Quota × Versionamento — a pegadinha que "some" a cota do cliente

Provado com números reais do `poc-bucket`: a métrica lógica
(`SeaweedFS_s3_bucket_size_bytes`, é o que a cota compara) **soma a
versão atual + todas as versões antigas retidas**, não só o arquivo
"de hoje". Confirmado batendo a soma manual das versões (via listagem
do filer em `<objeto>.versions/`) contra a métrica — bateu com <1KB de
diferença.

**Implicação de negócio**: um cliente com versionamento ligado consome
mais cota a cada edição, mesmo que o arquivo final seja pequeno — até
alguém rodar o lifecycle (manual ou automático) pra podar o excesso.
Mesmo comportamento (às vezes surpreendente) do S3 da AWS.

## 4. Lifecycle não é em tempo real — é um passe diário, e dá pra forçar

Achado no `weed shell`: `s3.lifecycle.run-shard` — "manually run one
daily-replay pass for the given shards". Confirma que o lifecycle roda
como **varredura diária sharded (0-15 partições)**, igual à AWS de
verdade — não é reação instantânea a "1 dia" na regra.

Comando pra forçar (testado, funcionou — processou a regra do bucket
na hora):
```
s3.lifecycle.run-shard -s3=<ip-do-s3front>:<porta-s3+10000> -shards=0-15 -refresh=0
```
(porta gRPC = porta HTTP do `weed s3` + 10000, convenção padrão, se
`-port.grpc` não foi setado explicitamente).

## 5. Métricas de bucket — quais existem e onde ficam

Confirmado nas strings do binário e testado ao vivo:
- `SeaweedFS_s3_bucket_size_bytes` — lógico (dedup entre réplicas, mas
  soma todas as versões).
- `SeaweedFS_s3_bucket_physical_size_bytes` — físico real (réplicas +
  paridade EC, inclui não-vacuumado).
- `SeaweedFS_s3_bucket_quota_bytes`, `SeaweedFS_s3_bucket_read_only`.
- Expostas via `-metricsPort` no `weed s3` (Prometheus). Testado
  `fetch()` direto do navegador pra essa porta — **funcionou sem
  bloqueio de CORS** neste build.
- Criar/gerenciar bucket e quota também dá pra fazer via `weed shell`:
  `s3.bucket.create`, `s3.bucket.quota`, `s3.bucket.delete`,
  `s3.bucket.versioning`, `s3.bucket.lock`, `s3.bucket.owner`.

## 6. Quando um volume vira candidato a EC — e por que não é sobre tempo

Defaults confirmados via `weed scaffold -config=admin`:
```
[maintenance.erasure_coding]
enabled = true
fullness_ratio = 0.95        # volume precisa estar 95% do tamanho máximo
quiet_for_seconds = 3600     # sem nenhuma escrita por 1h
scan_interval_seconds = 3600 # admin varre de hora em hora
min_size_mb = 30
```
O `weed admin` varre a cada 1h procurando quem virou candidato; o
`weed worker` (jobType inclui "heavy"/erasure_coding) executa o
trabalho de verdade. **Não é reação instantânea** ao volume ficar
"quiet" — é uma checagem periódica.

## 7. Por que forçar EC em dado pequeno é um desastre de espaço (medido, não teórico)

Forçamos EC manual (`ec.encode -quietFor=0s -fullPercent=0`) em 5
volumes de teste (39KB a 1,1MB, ~1,9MB no total). Resultado: **73,4MB
físicos** — confirmado por `du` real nas 7 VMs, bateu com a métrica.

Causa raiz, achada na fonte (`weed/storage/erasure_coding/ec_encoder.go`,
compartilhada entre OSS/Enterprise):
```go
ErasureCodingLargeBlockSize = 1024 * 1024 * 1024  // 1 GB
ErasureCodingSmallBlockSize = 1024 * 1024         // 1 MB
```
`UniformBlockSize` arredonda cada shard pra cima até o múltiplo de 1MB
mais próximo — **todo shard tem no mínimo 1MiB no disco**, não importa
o tamanho real do conteúdo. É por isso que `fullness_ratio=0.95` e
`min_size_mb=30` existem: só valem a pena rodar EC quando o volume é
grande o bastante pra esse piso de 1MB por shard virar irrelevante
(fração ínfima de 30GB).

**Achado confirmado (retestado do zero no ambiente reconstruído)**:
`ec.config -set -dataShards=5 -parityShards=2` (verificado ativo via
`ec.config -get` antes de qualquer upload) **não é respeitado pelo
`weed shell ec.encode` manual**. Refizemos o teste do zero — upload de
um arquivo novo, ratio 5+2 já configurado desde antes, `ec.encode`
rodado depois — e contamos os arquivos reais no disco: **14 arquivos
`.ec00`-`.ec13` de novo**, esquema clássico 10+4, não 7. Não é
timing/cache — é reproduzível. Não existe flag
`-dataShards`/`-parityShards` no `ec.encode` (só em `ec.config`).

**Conclusão**: o `ec.config` parece só ser consultado pelo caminho
automático (scheduler do `weed admin` + `weed worker`), não pelo
comando manual do shell. **Ainda não testamos o caminho automático** —
é a próxima validação necessária antes de confiar que o 5+2 está
realmente ativo em produção. Vale reportar como achado reproduzível
pro suporte/dev da SeaweedFS: `ec.config -set` muda o que `ec.config
-get` mostra, mas não o que `ec.encode` manual realmente grava.

**Terceira confirmação, com dado real de 30MB (não mais artefato de
arquivo minúsculo)**: upload direto num volume (bypassando o
fragmentador de chunks do filer, pra garantir 1 volume = 1 needle de
30MB de verdade), `ec.encode` manual com 5+2 já configurado. Resultado:
**14 arquivos `.ec00`-`.ec13`, cada um exatamente 4.194.304 bytes (4 MiB)
uniformes** — de novo o layout clássico 10+4. Integridade dos dados
confirmada por MD5 idêntico antes/depois do EC. Ver
`RELATO-EC-RATIO-DEV.md` para o relato formal, pronto pra enviar.

## 8. EC não é a "primeira linha de defesa" — replicação é

Divergência com um colega: ele defendia que o SeaweedFS não deveria
esperar o volume ficar quase cheio pra rodar EC, porque nesse meio-tempo
um disco poderia falhar e perder o dado sem redundância nenhuma.

**Resolução, com PoC ao vivo**: replicação e EC são dois mecanismos
independentes. A doc oficial confirma — *"If the volume is replicated,
only one copy will be erasure encoded. All the original copies will be
purged after a successful erasure encoding."* — ou seja, a proteção
durante a espera vem da réplica, não do EC.

PoC rodado: upload com `?replication=010` (réplica extra em outro
rack), confirmado nos 2 racks via `volume.list`, **derrubado o volume
server de uma das 2 cópias** (`systemctl stop weed-volumeN`), arquivo
continuou 100% acessível pela cópia sobrevivente — sem nenhum EC ter
rodado. Rodar EC mais cedo não fecha essa janela de risco (sempre existe
um intervalo entre o write e o EC terminar); só troca "réplica
protegendo" por "overhead de padding de 1MiB" sem necessidade.

**Conclusão prática**: em produção, replicação ≠ `000` é obrigatório
pra proteger dado quente. O `000` deste lab foi escolha deliberada pra
isolar o teste de EC — não é recomendação de produção.

## 9. Racks — não são "tudo ou nada"

- `-rack` é rótulo do **servidor** (processo `weed volume` inteiro), não
  do volume/arquivo individual.
- Código de replicação `001` (outro servidor, mesmo rack) protege contra
  disco/servidor falhar **mesmo com 1 rack só** — só precisa de ≥2
  servidores físicos nele.
- `010` (outro rack) protege contra o rack inteiro cair (energia, switch
  compartilhado) — precisa de ≥2 racks de verdade.
- Conclusão errada de se evitar: "1 rack = sem redundância". Quem decide
  se existe redundância é o código de replicação, não a contagem de
  racks — racks só restringem quais códigos são fisicamente possíveis.

## Pendências para o próximo ambiente

1. Confirmar se o EC automático (admin+worker) respeita o ratio 5+2
   configurado — o manual (`ec.encode` via shell) não respeitou.
2. Automatizar o `ec.config -set -dataShards=5 -parityShards=2` no
   próprio processo de deploy (hoje é passo manual pós-deploy, fácil de
   esquecer).
3. Documentar cada teste novo como uma POC isolada (formato a definir),
   em vez de um único documento corrido como este.
