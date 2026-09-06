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

## Próximo passo

Taxa de 33% em 15 tentativas já é evidência sólida o bastante pra virar
um relato formal pro dev, nos mesmos moldes de
`RELATO-EC-RATIO-DEV.md`/`RELATO-EC-AUTO-STUCK-DEV.md` — falta só
decidir se vale reproduzir mais uma vez com um bucket só (mais fácil de
isolar causa) antes de escrever, ou já registrar como está.

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

`NoncurrentVersionExpiration` with only `NewerNoncurrentVersions` set (no `NoncurrentDays`) is supposed to retain exactly the N newest noncurrent versions of every object and expire the rest on the next lifecycle pass. When a **single lifecycle invocation processes multiple buckets that each have their own copy of this rule**, some buckets intermittently end up with **one fewer noncurrent version than configured** — i.e. the rule over-deletes by exactly one version. The *current* version is never affected; only noncurrent-version retention undercounts.

Observed rate: **5 out of 15 buckets (33%)** across 5 independent batches (3 fresh buckets + 1 lifecycle invocation per batch). The same setup, run back-to-back with no other change, produced 2/3 failing buckets in one batch and 0/3 in the very next — ruling out a simple, deterministic off-by-one and pointing at a timing/ordering-dependent (likely concurrency) issue rather than a pure logic bug.

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

This is inference from symbol names and struct shapes, **not** a confirmed code-level diagnosis — we don't have the actual source to point at a specific line. Flagging it as a strong lead for whoever investigates on your end.

### Impact

A customer relying on "always keep my N most recent versions" as a data-retention guarantee (e.g. compliance, quota planning, rollback expectations) can silently end up with N-1 in about 1 out of 3 lifecycle passes that happen to process their bucket alongside others. The current/live object is never at risk — only historical version depth is affected, and only when versions are pruned via lifecycle across a multi-bucket pass.
