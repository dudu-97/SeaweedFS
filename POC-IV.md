# POC IV — Lifecycle não roda sozinho: por quê, e como lidar com isso em produção

## Contexto

Ao criar uma regra de Lifecycle (Limit noncurrent versions) num bucket
com versionamento, esperar alguns minutos não foi suficiente pra ver as
versões antigas sumirem. Duas perguntas surgiram: (1) o que significa
deixar o campo "after ___ days" em branco, e (2) por que a limpeza não
rodou ainda, e o que fazer numa arquitetura de produção pra clientes que
não podem esperar o ciclo natural do lifecycle.

## Pergunta 1 — o que "after ___ days" em branco significa

Resposta confirmada olhando o XML real salvo pro bucket
`poc2-quota-versionamento`:
```xml
<NoncurrentVersionExpiration>
  <NewerNoncurrentVersions>2</NewerNoncurrentVersions>
</NoncurrentVersionExpiration>
```
**Deixar em branco não grava `0`, nem "nunca expira" — a tag
`<NoncurrentDays>` simplesmente não é incluída na regra.** Sem essa
tag, a condição de expiração é **puramente por contagem**: mantém as N
versões não-correntes mais novas (aqui, 2) e qualquer coisa além disso
já fica elegível pra exclusão na próxima passada do lifecycle — **sem
nenhum prazo de carência**. É o oposto de "nunca": é a variante mais
agressiva possível (expira assim que ultrapassar a contagem, não espera
dias nenhum).

## Pergunta 2 — por que não rodou ainda

Consultei o status do scheduler de plugins (`weed admin`, endpoint
`/api/plugin/scheduler-status`):
```json
{"job_type": "s3_lifecycle", "next_detection_at": "2026-09-07T18:53:04Z", "reason": "next_detection_at"}
```
No momento da consulta eram `2026-09-06T23:17:08Z` — ou seja, a próxima
varredura de lifecycle estava agendada pra **~19h36min depois**. Isso
**não é bug/travamento** (diferente do que achamos com o `erasure_coding`
automático, que fica preso num loop de cancelar-e-recriar sem nunca
executar) — o `s3_lifecycle` está genuinamente agendado, só que o ciclo
é mesmo diário, exatamente como já documentado (`HISTORICO.md` seção
2.4: *"Lifecycle não é em tempo real — é um passe diário"*). Um log de
boot do admin mostrou um aviso (`"no filer available"`, às 15:48:20,
quando o admin subiu antes do filer estar pronto) — mas isso não
impediu o `s3_lifecycle` de se registrar e agendar normalmente.

**Forçar agora, manualmente** (comando já documentado no README/HISTORICO):
```bash
ssh swfs@192.168.100.11 "echo 's3.lifecycle.run-shard -shards=0-15 -s3=192.168.100.31:18333 -refresh=0' | weed shell -master=192.168.100.11:9333"
```

## Pergunta 3 — faz sentido, em produção, um cron a cada 30min pra 1 cliente específico?

**A ideia de forçar com mais frequência faz sentido — mas não dá pra
escopar por bucket, nem pelo agendamento nativo nem pelo comando
manual.** Confirmado nos dois lugares:
- O scheduler nativo (`/api/plugin/scheduler-status`) tem **1 único**
  `next_detection_at` pro job type `s3_lifecycle`, global pro cluster —
  não por bucket.
- O `s3.lifecycle.run-shard` processa **shards do keyspace inteiro**
  (`-shards=0-15`), não um bucket específico — não existe flag `-bucket`
  ou equivalente.

Ou seja: **não tem como acelerar o lifecycle só pra um cliente sem
acelerar pra todo mundo.** Um cron rodando `s3.lifecycle.run-shard` a
cada 30min é tecnicamente válido e é exatamente o uso que o próprio
comando prevê (a doc dele já cita rodar sob demanda) — mas o efeito é
**global**: todos os buckets com regra de lifecycle passam a ser
varridos a cada 30min, não só o cliente que pediu.

**Implicações antes de adotar isso em produção:**
- **Custo**: 48 passadas/dia em vez de 1 — cada passada percorre o
  meta-log de TODOS os buckets, não só o de interesse. Os flags
  `-runtime` (limite de tempo de parede) e `-events` (limite de eventos
  processados por passada) existem exatamente pra colocar um teto nesse
  custo por execução — vale usar os dois no cron, não rodar sem limite.
- **Não é "por cliente", é "pra todo mundo"**: se só 1 cliente entre
  vários precisa de SLA de limpeza rápida, rodar o cron beneficia (e
  custa) igual pros outros também — não tem como isolar.
- **Alternativa a considerar**: se o objetivo real é "não deixar o
  cliente perder cota por versão acumulada", pode fazer mais sentido
  configurar a cota dele já com folga pra absorver o atraso do ciclo
  diário, em vez de mudar a cadência de lifecycle do cluster inteiro —
  ou negociar que a garantia é "limpeza em até 24h", não "quase
  instantânea".

## Conclusão

1. Campo em branco = sem carência de dias, só a contagem de versões
   manda.
2. Lifecycle não travou — está agendado pra rodar em ~24h, mecanismo
   funcionando como documentado.
3. Um cron de 30min é possível e usa uma via já suportada pelo próprio
   SeaweedFS, mas afeta o cluster inteiro, não um bucket isolado — decidir
   com essa contrapartida em mente, e com `-runtime`/`-events` limitando
   o custo por execução.
