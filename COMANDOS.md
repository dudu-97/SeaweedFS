# Comandos de administração — referência direta

Tudo abaixo foi testado neste lab (ver `HISTORICO.md` e `POC-I.md` a
`POC-V.md` para o contexto de cada um). Formato: o que o comando faz,
seguido do comando.

Entrar no shell administrativo, de qualquer VM do cluster (descobre o
líder Raft sozinho):
```
weed shell -master=<ip-master>:9333
```
Comandos que alteram estado (seção "Manutenção de volumes" abaixo) pedem
`lock` antes e `unlock` depois.

## Consultar o cluster e os volumes

Status geral do cluster e do quorum Raft
```
cluster.status
cluster.raft.ps
```

Listar todos os volumes: id, servidor, tamanho, replicação, coleção, shards EC
```
volume.list
```

Listar coleções (buckets) existentes
```
collection.list
```

Navegar/medir o namespace do Filer
```
fs.ls /caminho
fs.du /caminho
```

## Erasure Coding (EC)

Ver o ratio de EC configurado (global ou por coleção)
```
ec.config -get
```

Ajustar o ratio de EC (ex.: 5 dados + 2 paridade)
```
ec.config -set -dataShards=5 -parityShards=2
```

Gerar EC manualmente num volume específico
```
ec.encode -volumeId=<id> -quietFor=0s -fullPercent=0
```
Nota: em builds anteriores à 4.46 esse comando ignorava o `-dataShards`/
`-parityShards` de `ec.config` e sempre gravava o layout clássico 10+4
(bug que reportamos, corrigido na 4.46 — confirmar o layout gerado com
`volume.list` depois de atualizar).

Rebalancear shards EC entre racks/servidores depois do encode
```
ec.balance -collection=<coleção>
```

## Versionamento e bucket S3

Criar bucket (com Object Lock opcional)
```
s3.bucket.create -name=<bucket> [-withLock]
```

Ligar versionamento
```
s3.bucket.versioning -name=<bucket> -enable
```

Suspender versionamento
```
s3.bucket.versioning -name=<bucket> -suspend
```
Nota: o flag certo é `-enable`/`-suspend` (booleano) ou `-status=Enabled`/
`-status=Suspended` — `-enabled=true` não existe e falha. Versionamento só
é garantido quando o bucket é manipulado via API S3; upload direto no
Filer não respeita versionamento.

Definir cota de tamanho do bucket
```
s3.bucket.quota -name=<bucket> -op=set -sizeMB=<n>
```
Nota: a cota soma a versão atual **+ todas as versões antigas retidas**
(métrica `SeaweedFS_s3_bucket_size_bytes`), não só o arquivo mais recente
— mesmo comportamento da AWS. Ela só desce depois que o lifecycle podar
as versões antigas.

Apagar bucket
```
s3.bucket.delete -name=<bucket>
```

Forçar uma passada manual do lifecycle (por padrão roda ~1x/dia, sharded em 16 partições — útil pra testar regra de expiração sem esperar o ciclo automático)
```
s3.lifecycle.run-shard -s3=<ip-s3front>:<porta-s3+10000> -shards=0-15 -refresh=0
```
Nota: processa **todos** os buckets que têm regra de lifecycle configurada
de uma vez (não existe flag por bucket) — para isolar o teste a 1 bucket,
apague os demais antes.

## Manutenção de volumes (exigem lock/unlock)

```
lock
volume.vacuum            # libera espaço de arquivos deletados/sobrescritos
volume.balance           # rebalanceia volumes entre servidores
volume.fix.replication   # corrige réplicas faltando/incorretas
volume.check.disk        # verifica integridade dos dados no disco
volume.fsck              # verifica consistência (arquivos órfãos etc.)
unlock
```

## Verificação por papel (via SSH/console, fora do `weed shell`)

```bash
# Master (porta 9333)
curl -s "http://localhost:9333/cluster/status?pretty=y"
curl -s "http://localhost:9333/dir/status?pretty=y"   # topologia: dc/racks/volume servers
journalctl -u weed-master -f

# Volume (porta 8080)
curl -sI "http://localhost:8080/healthz"
curl -s  "http://localhost:8080/status?pretty=y"      # inclui DiskStatuses, 1 por disco
journalctl -u weed-volume -f

# Filer (porta 8888)
curl -H "Accept: application/json" "http://localhost:8888/buckets/?pretty=y"
journalctl -u weed-filer -f

# S3 front (porta 8333)
aws --endpoint-url http://localhost:8333 s3 ls
journalctl -u weed-s3 -f

# Admin + Worker
journalctl -u weed-admin -f    # scan de manutenção, detecção de EC
journalctl -u weed-worker -f   # execução das tarefas (ec_balance, balance...)
```
