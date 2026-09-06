# POC I — O que acontece quando envio o dado com replicação 000 por padrão?

**Status: concluída.** Ver "Resultado" no final do documento.

## Pergunta

Com `replication=000` (padrão deste cluster — nenhuma cópia extra), um
arquivo enviado pro bucket fica **inteiro em 1 único volume (`.dat`)**,
no volume que o Master apontou, ou o Filer já **quebra o arquivo em
chunks e espalha entre volumes/racks diferentes**, mesmo sem nenhuma
cópia extra configurada?

## Duas hipóteses

1. **Fica inteiro**: sem replicação, o Filer grava o arquivo como 1
   objeto só, num volume só — "sem replicação" = "sem fragmentação
   também", o dado vira 1 needle grande num `.dat`.
2. **Fragmenta mesmo assim**: o Filer sempre quebra o arquivo em chunks
   (isso seria independente do código de replicação, que só decide
   quantas *cópias extras* de cada chunk existem), e os chunks acabam
   espalhados por vários volumes/racks — mesmo sem nenhuma redundância
   entre eles.

Replicação e fragmentação são conceitualmente coisas diferentes no
SeaweedFS (uma decide *quantas cópias*, a outra decide *em quantos
pedaços*), mas vale confirmar ao vivo em vez de assumir.

## Pré-requisitos / acesso

Endpoints deste lab (ver `README.md` > Acesso SSH se `curl`/`ssh` direto
não alcançar a rede isolada a partir do seu terminal):
- Master: `192.168.100.11:9333` (ou `.12`/`.13`)
- Filer: `192.168.100.11:8888` (ou `.12`/`.13`)
- S3: `192.168.100.31:8333`, credenciais em `00-config.env`
  (`S3_ACCESS_KEY=swfslab`, `S3_SECRET_KEY=71a332182078ebf7f7a1257df152e16b474d1eb2`)

## Passo 1 — confirmar o estado antes do upload

```bash
# replicação padrão do cluster (deve mostrar "000")
curl -s http://192.168.100.11:9333/dir/status | python3 -m json.tool | grep -A2 '"replication"'

# baseline: quais volumes existem e seus tamanhos, ANTES do upload
# (pra depois comparar e ver quais mudaram / surgiram)
ssh swfs@192.168.100.11 "echo 'volume.list' | weed shell -master=192.168.100.11:9333" > /tmp/volumes-antes.txt
cat /tmp/volumes-antes.txt
```

## Passo 2 — criar o bucket

```bash
ssh swfs@192.168.100.11 "echo 's3.bucket.create -name=poc1-replicacao000' | weed shell -master=192.168.100.11:9333"
```

## Passo 3 — gerar o arquivo de teste (~100MB)

```bash
dd if=/dev/urandom of=/tmp/poc1-arquivo-100mb.bin bs=1M count=100
md5sum /tmp/poc1-arquivo-100mb.bin   # guarda esse hash pra conferir integridade depois, se quiser
```

## Passo 4 — enviar o arquivo

Direto pelo Filer (não precisa de cliente S3 instalado — o Filer aceita
PUT simples e trata como um objeto do bucket):

```bash
curl -v -T /tmp/poc1-arquivo-100mb.bin \
  http://192.168.100.11:8888/buckets/poc1-replicacao000/poc1-arquivo-100mb.bin
```

## Passo 5 — checar o manifesto de chunks do objeto (o coração da pergunta)

```bash
curl -s 'http://192.168.100.11:8888/buckets/poc1-replicacao000/poc1-arquivo-100mb.bin?metadata=true' \
  | python3 -m json.tool
```

Olhe o array `"chunks"`:
- **1 chunk só**, com `"size"` = o tamanho inteiro do arquivo → hipótese 1 (ficou inteiro).
- **Vários chunks**, cada um com um `"fid"` (`volume_id`, `file_key`, `cookie`) diferente → hipótese 2 (fragmentou). Anote quantos chunks e quais `volume_id` aparecem.

## Passo 6 — ver em quais volumes/racks os chunks caíram

```bash
ssh swfs@192.168.100.11 "echo 'volume.list' | weed shell -master=192.168.100.11:9333" > /tmp/volumes-depois.txt
diff /tmp/volumes-antes.txt /tmp/volumes-depois.txt
```

Cruze os `volume_id` do passo 5 com a saída do `volume.list`: em qual
`rack`/IP cada um está, e se são 1 volume só ou vários espalhados.

## Passo 7 (opcional) — checar se há log do upload

```bash
ssh swfs@192.168.100.11 "sudo journalctl -u weed-filer --since '-5 min' --no-pager"
```
(Já vimos em testes anteriores que, na verbosidade padrão, uploads bem-sucedidos normalmente não geram log — se não aparecer nada, não é erro seu; o manifesto de chunks do passo 5 é a fonte de verdade.)

## O que registrar no resultado

- Quantos chunks o objeto tem, e o tamanho de cada um.
- Quantos `volume_id` distintos apareceram, e em quantos racks/IPs diferentes.
- Se algum volume novo foi criado (comparando passo 1 vs passo 6).
- Conclusão: hipótese 1 ou 2 — e se fragmentou, se isso muda sua expectativa sobre o risco de perder 1 volume com `replication=000` (um único disco perdido pode derrubar o objeto inteiro, mesmo ele tendo "só" 100MB).

## Resultado (executado por Eduardo, 06/09/2026)

Arquivo de 100MB (`104.857.600` bytes) enviado pro bucket
`poc1-replicacao000` via `curl -T` direto no Filer (`HTTP 201`, MD5
`iTjwv4AtQpBbhUxFPXOruQ==`).

**Manifesto de chunks** (`?metadata=true`): **25 chunks, todos de
exatamente 4.194.304 bytes (4 MiB)** — `25 × 4.194.304 = 104.857.600`,
bate exato com o tamanho do arquivo, sem sobra. Distribuição por volume:

| Volume | Rack / Node | Chunks | Bytes |
|---|---|---|---|
| 25 | rack4 (192.168.100.54) | 14 | ~58,7 MB |
| 26 | rack5 (192.168.100.55) | 9 | ~37,7 MB |
| 27 | rack2 (192.168.100.52) | 2 | ~8,4 MB |

Os chunks se intercalam entre os 3 volumes ao longo do arquivo (não é
"enche um volume, abre outro" — offsets crescentes alternam entre
volume 25 e 26, com o 27 entrando só perto do fim). O `diff` do
`volume.list` antes/depois confirma: `DataCenter dc1` foi de
`FileCount:4` para `FileCount:31` (+25 chunks +2 escritas de metadado do
Filer, não relacionadas ao arquivo) e `Size` subiu ~104,86MB — bate com
o arquivo + cabeçalho de needle por chunk. Nenhum chunk caiu na camada
de TTL "3M" que já existia no cluster (layout separado, não usado por
este teste).

### Conclusão

**Hipótese 2 confirmada**: mesmo com `replication=000` (nenhuma cópia
extra), o arquivo **não** ficou inteiro num `.dat` só — foi fragmentado
em 25 chunks e espalhado por **3 racks diferentes**. Replicação e
fragmentação são mecanismos independentes: `000` decide só quantas
cópias extras de cada chunk existem (zero), não se o arquivo fica
inteiro em algum lugar.

**Risco na prática**: perder sozinho o volume 25 (rack4) já derruba mais
da metade do arquivo (14 de 25 chunks) — um objeto de "apenas" 100MB não
está protegido por estar "em um bucket só"; a granularidade real de
risco é o chunk/volume, não o objeto.
