# POC V — Lifecycle em múltiplos buckets: passada global, mas contagem inconsistente

## Pergunta

Uma execução (automática ou manual) de lifecycle processa **todos os
buckets numa única passada**, aplicando a regra de **cada bucket**
individualmente? E essa contagem (`NewerNoncurrentVersions`) é
confiável quando vários buckets são processados juntos?

## Método

Repetido 5 vezes (lotes de 3 buckets cada, 15 buckets no total),
sempre com o mesmo procedimento:

1. Cria 3 buckets, liga versionamento em cada um.
2. Sobe 4 versões do mesmo arquivo em cada bucket (via API S3
   assinada de verdade — não upload direto no Filer, pra garantir que
   cada `PUT` gera versão, conforme já confirmado no POC II).
3. Configura lifecycle idêntico nos 3: manter só as **2 versões
   não-correntes mais novas** (`NewerNoncurrentVersions=2`) — com a
   versão atual, dá 3 no total esperado por bucket.
4. Dispara **uma única execução manual** de lifecycle, cobrindo todos
   os buckets de uma vez.
5. Conta quantas versões sobraram em cada bucket.

Esperado em todos: 4 → 3. Qualquer coisa diferente de 3 é anomalia.

## Comandos (pra rodar você mesmo, ou repetir o teste)

Este cluster não tem `mc`/`aws-cli`/`boto3` — as chamadas assinadas
(upload real via S3 e a config de lifecycle) usam um script Python
próprio, stdlib puro (SigV4 manual): copiado em
`swfs-master1:/tmp/s3sign.py`. Uso: `python3 s3sign.py <METODO> <bucket[/chave]> <query>`,
corpo da requisição via stdin.

```bash
# 1) Criar o bucket e ligar versionamento (via weed shell)
ssh swfs@192.168.100.11 "weed shell -master=192.168.100.11:9333" <<'EOF'
s3.bucket.create -name=poc5-bucket-x
s3.bucket.versioning -name=poc5-bucket-x -enable
EOF

# 2) Subir 4 versões do mesmo arquivo (PUT real via API S3, gera 1 versão por chamada)
ssh swfs@192.168.100.11 '
for i in 1 2 3 4; do
  echo "versao $i $(date +%s%N)" | python3 /tmp/s3sign.py PUT "poc5-bucket-x/arquivo.bin" ""
  sleep 1   # espaça os timestamps, evita ambiguidade de ordenacao
done
'

# 3) Configurar lifecycle: manter só as 2 versoes nao-correntes mais novas
ssh swfs@192.168.100.11 '
XML="<?xml version=\"1.0\" encoding=\"UTF-8\"?><LifecycleConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Rule><ID>keep-2-noncurrent</ID><Status>Enabled</Status><Filter><Prefix></Prefix></Filter><NoncurrentVersionExpiration><NewerNoncurrentVersions>2</NewerNoncurrentVersions></NoncurrentVersionExpiration></Rule></LifecycleConfiguration>"
printf "%s" "$XML" | python3 /tmp/s3sign.py PUT "poc5-bucket-x" "lifecycle="
'

# 4) Forcar 1 execucao manual do lifecycle (processa TODOS os buckets com regra, numa passada só)
ssh swfs@192.168.100.11 "echo 's3.lifecycle.run-shard -shards=0-15 -s3=192.168.100.31:18333 -refresh=0' | weed shell -master=192.168.100.11:9333"

# 5) Conferir quantas versoes sobraram (esperado: 3)
curl -s 'http://192.168.100.11:8888/buckets/poc5-bucket-x/arquivo.bin.versions/?pretty=y' -H 'Accept: application/json' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('Entries',[])))"
```

Repita os passos 1-3 pra mais buckets antes do passo 4, pra testar
vários de uma vez na mesma passada (foi assim que os 5 lotes abaixo
foram gerados — 3 buckets por lote, 1 execução do passo 4 por lote).

## Resultado consolidado (5 lotes, 15 buckets)

| Lote | Buckets | Resultado (versões restantes) | Anomalias |
|---|---|---|---|
| 1 | a, b, c | 2, 3, 2 | 2 de 3 |
| 2 | d, e, f | 3, 3, 3 | 0 de 3 |
| 3 | g, h, i | 2, 2, 3 | 2 de 3 |
| 4 | j, k, l | 3, 3, 3 | 0 de 3 |
| 5 | m, n, o | 3, 3, 2 | 1 de 3 |
| **Total** | **15 buckets** | | **5 de 15 (33%)** |

Sem padrão posicional claro: a anomalia não é sempre "o primeiro
bucket" nem "o último" do lote (apareceu em posições 1ª, 2ª e 3ª em
lotes diferentes) — consistente com uma condição de corrida ao
processar vários buckets na mesma passada, não com um erro
determinístico de lógica.

Em **nenhum** dos 15 casos a versão *atual* foi afetada — confirmado
via o atributo `Seaweed-X-Amz-Latest-Version-Id` da pasta `.versions`
de cada bucket anômalo, sempre apontando pra versão certa entre as
sobreviventes. A perda extra foi sempre entre as não-correntes (sobrou
1 em vez de 2).

## Conclusão

1. **Confirmado**: uma execução manual (e, por extensão, a automática)
   processa múltiplos buckets numa única passada global, cada um com
   sua própria regra — não existe agendamento por bucket (bate com o
   achado do POC IV, agora com prova direta: `loaded lifecycle for N
   bucket(s)` cresce a cada lote).
2. **Achado novo, com taxa confiável**: a contagem de
   `NewerNoncurrentVersions` erra em **~1 a cada 3 buckets** quando
   vários são processados na mesma passada — apaga 1 versão
   não-corrente a mais do que a regra manda. 33% numa amostra de 15 é
   alto demais pra ser coincidência.
3. **Sem risco de perda da versão atual** em nenhum teste — o erro é
   estritamente "reteve menos histórico do que devia", nunca "perdeu o
   dado vivo".
4. **Implicação prática**: um cliente que conta com "sempre guardo as
   últimas N versões" pode, de vez em quando, ficar com N-1 — pequeno
   pra a maioria dos casos, mas relevante se a garantia de retenção for
   parte do contrato/SLA vendido.

## Rodada extra — isolando a variável "quantos buckets na mesma passada"

Pergunta direta: o problema é do motor de lifecycle em geral, ou só
aparece quando **vários buckets são processados juntos**? Duas fases
novas, pra comparar:

### Fase A — 5 lotes de 5 buckets (25 buckets)

Mesmo procedimento, só que 5 buckets por lote em vez de 3.

| Lote | Buckets (versões restantes) | Anomalias |
|---|---|---|
| A | 3,2,3,2,3 | 2/5 |
| B | 3,3,3,3,3 | 0/5 |
| C | 2,2,2,3,2 | 4/5 |
| D | 3,2,3,3,2 | 2/5 |
| E | 3,3,3,3,3 | 0/5 |
| **Total** | **25 buckets** | **8/25 (32%)** |

Taxa praticamente idêntica à dos lotes de 3 (33%) — o tamanho do lote
não muda a taxa de forma proporcional, é sempre por volta de 1/3.

### Fase B — 5 buckets testados 1 de cada vez (isolado)

Antes desta fase, **apaguei os 41 buckets de teste anteriores**
(`s3.bucket.delete`), porque senão o comando ainda processaria todos
eles juntos mesmo criando "só 1 bucket novo" — o `run-shard` sempre
processa todo mundo que tem regra de lifecycle configurada, não dá pra
filtrar por bucket (mesmo achado do POC IV). Cada rodada abaixo criou 1
bucket, rodou o lifecycle sozinho, conferiu o resultado, e apagou o
bucket antes da próxima — confirmando a cada vez, pelo log
(`loaded lifecycle for 1 bucket(s)`), que era realmente só 1 bucket na
passada.

| Rodada | Bucket | `loaded lifecycle for` | Resultado |
|---|---|---|---|
| 1 | poc5-solo-1 | 1 bucket(s) | 3 — OK |
| 2 | poc5-solo-2 | 1 bucket(s) | 3 — OK |
| 3 | poc5-solo-3 | 1 bucket(s) | 3 — OK |
| 4 | poc5-solo-4 | 1 bucket(s) | 3 — OK |
| 5 | poc5-solo-5 | 1 bucket(s) | 3 — OK |
| **Total** | | | **5/5 (100% corretos, 0 anomalias)** |

### Conclusão desta rodada extra

**Isolado a 1 bucket por vez: zero falhas em 5 tentativas. Misturado
com outros buckets na mesma passada (lotes de 3 ou de 5): ~32-33% de
falha, em 40 buckets testados no total.** Isso fecha a causa com bem
mais confiança: **o defeito só se manifesta quando o motor de lifecycle
processa múltiplos buckets na mesma execução** — bate exatamente com a
hipótese de condição de corrida entre goroutines concorrentes por
shard (achada via símbolos do binário, seção abaixo), já que com 1
bucket só não existe concorrência nenhuma disputando o mesmo estado
compartilhado.

## Rodada de produção — caminho automático de verdade (10 buckets "clientes")

Todas as rodadas acima usaram o comando manual `s3.lifecycle.run-shard`
— que a própria documentação do comando descreve como um atalho de
teste, pensado pra rodar "sem montar o stack completo de admin+worker".
Faltava testar o caminho **automático de verdade**: o scheduler do
`weed-admin` disparando a tarefa e o `weed-worker` executando.

### Setup

10 buckets simulando clientes reais (`cliente-1` a `cliente-10`),
versionamento ligado, **cada um com uma regra de lifecycle diferente**
(manter de 1 a 9 versões não-correntes), 5 deles com upload feito por
usuários individuais provisionados via `s3.user.provision` (não admin).
10 versões por bucket. Depois, esperamos o ciclo diário automático
rodar sozinho (sem forçar nada manualmente) — confirmado via o
histórico persistido em `/var/lib/seaweedfs/admin/plugin/job_types/s3_lifecycle/runs.json`,
que sobrevive a restart do `weed-admin` (esse cluster já roda com
`-dataDir` configurado).

### Resultado — 10 de 10 corretos

| Bucket | Regra (manter N não-corr.) | Esperado (1+N) | Real |
|---|---|---|---|
| cliente-1 | 2 | 3 | 3 ✅ |
| cliente-2 | 3 | 4 | 4 ✅ |
| cliente-3 | 2 | 3 | 3 ✅ |
| cliente-4 | 4 | 5 | 5 ✅ |
| cliente-5 | 7 | 8 | 8 ✅ |
| cliente-6 | 5 | 6 | 6 ✅ |
| cliente-7 | 6 | 7 | 7 ✅ |
| cliente-8 | 1 | 2 | 2 ✅ |
| cliente-9 | 8 | 9 | 9 ✅ |
| cliente-10 | 9 | 10 | 10 ✅ (só tinha 9 não-correntes de início, nada a apagar) |

Todos os 10 buckets processados na **mesma execução** (`runs.json`:
`worker_id: w-swfs-m-725b`, `duration_ms: 2851`, `outcome: success`) —
e todos bateram exatamente com a regra configurada. Nenhuma anomalia,
mesmo sendo 10 buckets simultâneos, mais que qualquer lote manual
testado antes.

### Isso muda a conclusão principal

**O bug de contagem parece ser específico do comando manual
`s3.lifecycle.run-shard`, não do caminho de produção.** Isso é uma
notícia boa pro uso real (cliente com ciclo automático não é afetado,
até onde testamos), mas também reduz a urgência/gravidade do relato
formal — vale reportar mesmo assim (é um bug real, reprodutível, e pode
afetar quem usa o comando manual pra operação do dia a dia), só que com
essa ressalva importante em destaque, não como "todo lifecycle sofre
disso".

## Próximo passo

Relato atualizado abaixo com essa ressalva. Se quiser reforçar ainda
mais a certeza de que o automático está limpo, dá pra repetir esse
teste de 10 buckets mais 2-3 vezes em dias diferentes — só que aí
precisa esperar o ciclo diário de verdade, não dá pra forçar sem cair
de novo no caminho manual.

---

# Draft report (English, for the dev — review before sending)

> Rascunho pronto pra revisar mais algumas vezes antes de enviar, como
> pedido. Not sent yet.

## Report: `NoncurrentVersionExpiration` (`NewerNoncurrentVersions`) intermittently retains fewer versions than configured when multiple buckets are processed in the same lifecycle pass

### Environment

- SeaweedFS Enterprise, `weed version` → `8000GB 4.45-enterprise` (binary `weed-enterprise-linux_amd64_large_disk.tar.gz`, `seaweedfs/artifactory` releases).
- Cluster: 3 masters (raft) + filer (Postgres store) each, 1 standalone `weed s3`, 7 volume nodes.
- Lifecycle forced via `weed shell`: `s3.lifecycle.run-shard -shards=0-15 -s3=<s3front>:<s3-port+10000> -refresh=0`.
- Buckets created and configured via a self-signed SigV4 script (no `mc`/`aws-cli`/`boto3` available on this cluster) — plain `PutObject`/`PutBucketLifecycleConfiguration` calls, no non-standard behavior on the client side.

### Summary

**Important scope note up front**: everything below (the 32.5% failure rate) was produced using the **manual** `weed shell` command `s3.lifecycle.run-shard` — which its own `-h` text describes as a way to drive the lifecycle engine "without standing up the full admin+worker plugin stack", i.e. a test/CI shortcut, not the production code path. We separately ran the **real automatic path** (the `weed-admin` scheduler dispatching to `weed-worker`, no manual trigger at all) against 10 buckets with 10 different retention rules, and got **10/10 correct** — see "Automatic-path control" below. So this appears to be a defect in the manual command's code path specifically, not in the scheduled production job. Reporting it regardless since the manual command is a real, documented, supported tool (used for on-demand/CI expiration), but the severity for customers relying purely on the daily automatic cycle looks low based on what we've measured so far.

`NoncurrentVersionExpiration` with only `NewerNoncurrentVersions` set (no `NoncurrentDays`) is supposed to retain exactly the N newest noncurrent versions of every object and expire the rest on the next lifecycle pass. When a **single manual lifecycle invocation processes multiple buckets that each have their own copy of this rule**, some buckets intermittently end up with **one fewer noncurrent version than configured** — i.e. the rule over-deletes by exactly one version. The *current* version is never affected; only noncurrent-version retention undercounts.

Observed rate: **13 out of 40 buckets (32.5%)** across batched runs (5 batches of 3 + 5 batches of 5, one lifecycle invocation per batch). The same setup, run back-to-back with no other change, produced anywhere from 0/3 to 4/5 failing buckets from one batch to the next — ruling out a simple, deterministic off-by-one and pointing at a timing/ordering-dependent (likely concurrency) issue rather than a pure logic bug.

**Isolation control**: when the exact same steps are run with **only one bucket present** in the entire cluster (no other bucket carrying a lifecycle rule, confirmed via the tool's own `loaded lifecycle for 1 bucket(s)` log line), the failure **never occurred — 0 out of 5 independent single-bucket runs**, versus 32.5% across 40 buckets processed in multi-bucket batches. This strongly suggests the defect is specifically triggered by **concurrent processing of multiple buckets in the same pass**, not by the `NewerNoncurrentVersions` logic in isolation.

**Automatic-path control**: 10 buckets (`cliente-1`..`cliente-10`), versioning enabled, each with a *different* `NewerNoncurrentVersions` value (1 through 9), 10 PutObject versions each (5 of the 10 buckets written via dedicated non-admin IAM users provisioned with `s3.user.provision`, to rule out any credential-related variable too). No manual `run-shard` was ever invoked for this run — we just waited for the daily scheduler. Confirmed via the persisted run history (`/var/lib/seaweedfs/admin/plugin/job_types/s3_lifecycle/runs.json`, which survives `weed-admin` restarts since this cluster runs with `-dataDir` configured) that the scheduler fired once (`worker_id: w-swfs-m-725b`, `duration_ms: 2851`, `outcome: success`) and processed all 10 buckets together. Result: **all 10 buckets ended with exactly the configured retention (1+N versions), zero anomalies** — a cleaner multi-bucket batch than any manual run we tested, with more buckets and more retention-value diversity.

### Steps to reproduce

```
# Repeat N times (we used 5 batches of 3 buckets = 15 buckets total):

# 1. Create 3 fresh buckets, enable versioning on each
weed shell -master=<master>:9333
> s3.bucket.create -name=<bucket>
> s3.bucket.versioning -name=<bucket> -enable
  (repeat for 3 buckets)

# 2. PutObject the same key 4 times in each bucket (real signed S3 PUT,
#    ~1s apart, distinct body each time so each PUT is a genuine new version)
PUT /<bucket>/arquivo.bin   (x4 per bucket, x3 buckets)

# 3. Set identical lifecycle configuration on all 3 buckets:
PUT /<bucket>?lifecycle
<LifecycleConfiguration>
  <Rule>
    <ID>keep-2-noncurrent</ID>
    <Status>Enabled</Status>
    <Filter><Prefix></Prefix></Filter>
    <NoncurrentVersionExpiration>
      <NewerNoncurrentVersions>2</NewerNoncurrentVersions>
    </NoncurrentVersionExpiration>
  </Rule>
</LifecycleConfiguration>

# 4. Force ONE manual lifecycle pass covering all buckets at once:
> s3.lifecycle.run-shard -shards=0-15 -s3=<s3front>:<s3-port+10000> -refresh=0

# 5. Count remaining versions per bucket (expect 3: 1 current + 2 noncurrent)
GET /<bucket>/<key>.versions/   (Filer namespace listing)
```

For the isolation control, delete every other bucket first
(`s3.bucket.delete -name=<bucket>`) so the cluster has exactly one
bucket with a lifecycle rule, confirm the `run-shard` log line reads
`loaded lifecycle for 1 bucket(s)`, then repeat steps 1-5 with a single
bucket per trial (delete it before starting the next trial, to keep
each one isolated).

### Results (5 independent batches, 15 buckets)

| Batch | Buckets (versions remaining) | Expected each | Failures |
|---|---|---|---|
| 1 | 2, 3, 2 | 3 | 2/3 |
| 2 | 3, 3, 3 | 3 | 0/3 |
| 3 | 2, 2, 3 | 3 | 2/3 |
| 4 | 3, 3, 3 | 3 | 0/3 |
| 5 | 3, 3, 2 | 3 | 1/3 |
| **Total** | **15 buckets** | | **5/15 (33%)** |

No positional pattern within a batch — the failing bucket was 1st, 2nd, and 3rd in different batches, not consistently the first or last one processed. In every failing case, verified via the `.versions` directory's `Seaweed-X-Amz-Latest-Version-Id` extended attribute that the **current** version was untouched; the deficit was always among noncurrent versions (1 kept instead of 2).

### Results — batch size and isolation control

| Configuration | Buckets tested | Failures | Rate |
|---|---|---|---|
| 5 batches × 3 buckets, 1 pass per batch | 15 | 5 | 33% |
| 5 batches × 5 buckets, 1 pass per batch | 25 | 8 | 32% |
| **5 batches × 1 bucket, 1 pass per batch (isolated — verified via `loaded lifecycle for 1 bucket(s)`)** | **5** | **0** | **0%** |

Batch size (3 vs 5) doesn't change the rate — it stays close to 1/3 either way. The only variable that eliminated the failure entirely was reducing the pass to a single bucket. Before the isolation runs, every bucket from the earlier batches was deleted (`s3.bucket.delete`) so each isolated run's `run-shard` invocation genuinely had only one bucket with a lifecycle rule to process — otherwise the tool still evaluates every bucket that has a rule configured, regardless of which bucket was just created (there is no per-bucket flag on `s3.lifecycle.run-shard`).

### Suspected root cause (inferred from binary symbols, not from source review)

We don't have access to the Enterprise source, but the shipped binary retains Go build-info paths and fully-qualified symbol names, which point at a specific package and a concrete concurrency pattern:

```
.../enterprise/weed/s3api/s3lifecycle/noncurrent_since.go
.../enterprise/weed/s3api/s3lifecycle/due_at.go                 (s3lifecycle.ComputeDueAt)
.../enterprise/weed/s3api/s3lifecycle/dailyrun/run.go            (dailyrun.Run, Run.func1, Run.func2)
.../enterprise/weed/s3api/s3lifecycle/dailyrun/dispatch.go       (dispatchWithRetry, drainShardEvents)
.../enterprise/weed/s3api/s3lifecycle/dailyrun/walk_buckets.go   (WalkBuckets, walkBucketTree)
.../enterprise/weed/s3api/s3lifecycle/reader/reader.go           ((*Reader).Run, dispatchOne, awaitResponse)
.../enterprise/weed/s3api/s3lifecycle/engine/engine.go           ((*Engine).Snapshot, atomic.Pointer[engine.Snapshot])
.../enterprise/weed/s3api/s3lifecycle/engine/compile.go          ((*CompiledAction).markActive / .IsActive, engine.PriorState)
.../enterprise/weed/s3api/s3lifecycle/scheduler/configload.go    (scheduler.AllActivePriorStates)
```

Two things stand out:

1. `dailyrun.Run` / `startSharedSubscription` compile to closures captured in a struct that includes `*sync.WaitGroup` alongside `*map[int]chan *reader.Event` — i.e. the 16 shards (`-shards=0-15`) are fanned out to **concurrent goroutines**, one per shard, synchronized with a `WaitGroup`, each with its own event channel. A single `run-shard` invocation is genuinely parallel across shards, not sequential.
2. `engine.PriorState` is kept in a `map[s3lifecycle.ActionKey]engine.PriorState`, and `(*CompiledAction).markActive`/`.IsActive` read/write per-action state. "Prior state" strongly suggests this is exactly the bookkeeping needed to decide "how many newer noncurrent versions have already been accounted for" **across shards** — which is unavoidable if a single bucket's version entries can be spread across more than one of the 16 shards (plausible, since `dailyrun.entryShardID` hashes individual entries, not whole buckets).

**Hypothesis**: when a bucket's noncurrent versions are split across 2+ shards, the concurrent per-shard goroutines each need to consult/update the shared `PriorState` for that bucket's `ActionKey` to correctly enforce a *global* "keep N newest" count. If that shared state isn't fully synchronized against concurrent access from sibling shard-goroutines, the count of "already-kept newer versions" seen by one goroutine can be stale or double-counted, causing a version that should survive to be misclassified as excess and deleted. This would explain why the failure is intermittent and not tied to bucket position — it depends on shard assignment and goroutine scheduling timing on each run, not on the rule or the data itself.

The isolation control (0/5 failures with a single bucket vs. 13/40 with multiple buckets in the same pass) is consistent with this: with only one bucket in play, there's no sibling bucket/shard activity to race against, even though the same `sync.WaitGroup`/16-shard fan-out presumably still runs.

This is inference from symbol names, struct shapes, and the isolation experiment — **not** a confirmed code-level diagnosis, since we don't have the actual source to point at a specific line. Flagging it as a strong lead for whoever investigates on your end.

### Impact

**Revised down after the automatic-path control, see Summary.** The original concern was: a customer relying on "always keep my N most recent versions" as a data-retention guarantee (e.g. compliance, quota planning, rollback expectations) could silently end up with N-1 in about 1 out of 3 lifecycle passes that happen to process their bucket alongside others, since real deployments virtually always have more than one bucket with a lifecycle rule and both `s3.lifecycle.run-shard` and the daily scheduled run process every configured bucket together (no per-bucket invocation available).

However, the one real automatic-path run we captured (10 buckets, 10 different rules, scheduler-dispatched, no manual trigger) came back 10/10 correct — better than any manual-command batch we tested, including smaller ones. Taken together with the isolation control (0/5 failures single-bucket), the evidence so far points at the defect being **specific to the manual `run-shard` code path**, not the production scheduler. We'd still like this fixed — `run-shard` is a real, documented, supported command (used for CI/on-demand expiration per its own `-h` text) and anyone using it operationally would be affected — but we no longer believe customers relying purely on the automatic daily cycle are at risk, pending more automatic-path samples to confirm that holds up over multiple days.
