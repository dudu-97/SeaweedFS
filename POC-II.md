# POC II — A cota considera só a versão atual, ou soma as versões antigas também?

## Contexto

Pensando em oferecer o serviço de storage S3 pra clientes (com cota por
bucket como parte do plano contratado): quando o versionamento está
ligado, um cliente que edita o mesmo arquivo várias vezes acumula
versões antigas retidas. A pergunta é o que a **cota** (o limite
configurado e a métrica que o sistema usa pra decidir se o bucket está
cheio) realmente enxerga.

## Pergunta

O dado considerado pra cota é:
1. **Só a versão corrente** de cada objeto (o que o cliente "vê" hoje
   ao listar o bucket), ou
2. **A versão corrente + todas as versões antigas retidas** (mesmo as
   que não aparecem mais numa listagem normal)?

## Duas hipóteses

1. **Só a versão atual conta** — cota reflete o "tamanho lógico atual"
   do bucket, do jeito que o cliente enxerga; versões antigas ficam de
   fora até alguém rodar uma limpeza/lifecycle.
2. **Todas as versões contam** — cota soma tudo que está fisicamente
   retido, corrente ou não; um cliente com versionamento ligado consome
   cota a cada edição, mesmo sem aumentar o tamanho "real" do dado dele.

## Pré-requisitos / acesso

- Master/Filer: `192.168.100.11:9333` / `:8888`
- Métricas Prometheus do S3 (bucket_size, bucket_physical_size, quota,
  read_only): `192.168.100.31:9327/metrics`

## Passo 0 — sintaxe real do comando de versionamento (corrigido)

A tentativa inicial com `-enabled=true` falhou — o flag certo é
`-enable` (booleano, sem valor) ou `-status=Enabled`:
```
Usage of s3.bucket.versioning:
  -enable        enable versioning on the bucket
  -name string   bucket name
  -status string versioning status: Enabled or Suspended
  -suspend       suspend versioning on the bucket
```

## Passo 1 — criar o bucket, ligar versionamento, setar uma cota pequena

Cota pequena de propósito (20MB) — é fácil de estourar em poucas
versões de um arquivo de 5MB, o que ajuda a enxergar o comportamento
rápido.

```bash
ssh swfs@192.168.100.11 "weed shell -master=192.168.100.11:9333" <<'EOF'
s3.bucket.create -name=poc2-quota-versionamento
s3.bucket.versioning -name=poc2-quota-versionamento -enable
s3.bucket.quota -name=poc2-quota-versionamento -op=set -sizeMB=20
EOF
```

## Passo 2 — gerar o arquivo de teste (5MB)

```bash
dd if=/dev/urandom of=/tmp/poc2-v1.bin bs=1M count=5
```

## Passo 3 — subir a versão 1, e checar a métrica

```bash
curl -T /tmp/poc2-v1.bin http://192.168.100.11:8888/buckets/poc2-quota-versionamento/arquivo.bin

curl -s http://192.168.100.31:9327/metrics | grep 'bucket="poc2-quota-versionamento"'
```
Anote `SeaweedFS_s3_bucket_size_bytes` e `SeaweedFS_s3_bucket_physical_size_bytes`.

## Passo 4 — sobrescrever a MESMA chave (gera versão 2), checar de novo

```bash
dd if=/dev/urandom of=/tmp/poc2-v2.bin bs=1M count=5
curl -T /tmp/poc2-v2.bin http://192.168.100.11:8888/buckets/poc2-quota-versionamento/arquivo.bin

curl -s http://192.168.100.31:9327/metrics | grep 'bucket="poc2-quota-versionamento"'
```
Compare com o passo 3: o `bucket_size_bytes` **dobrou** (somou v1+v2) ou
ficou **igual** (só reflete a v2, que é do mesmo tamanho da v1)?

## Passo 5 — repetir mais uma vez (versão 3) e ver se a cota já bloqueia

```bash
dd if=/dev/urandom of=/tmp/poc2-v3.bin bs=1M count=5
curl -v -T /tmp/poc2-v3.bin http://192.168.100.11:8888/buckets/poc2-quota-versionamento/arquivo.bin

curl -s http://192.168.100.31:9327/metrics | grep 'bucket="poc2-quota-versionamento"'
```
Repare no `HTTP status` do `curl -v` — se a soma de v1+v2+v3 (15MB)
ainda estiver sob os 20MB, deve aceitar; se já passar de 20MB, veja se
volta erro de cota/`read_only`. Também confira
`SeaweedFS_s3_bucket_read_only` na métrica.

## Passo 6 — conferir "na unha", direto no Filer (bate com a métrica?)

```bash
curl -s 'http://192.168.100.11:8888/buckets/poc2-quota-versionamento/arquivo.bin.versions/?pretty=y' \
  -H 'Accept: application/json' | python3 -m json.tool
```
Some manualmente o `FileSize` de cada versão listada e compare com o
`SeaweedFS_s3_bucket_size_bytes` do passo 5.

## O que registrar no resultado

- O `bucket_size_bytes` cresceu a cada versão nova, ou ficou estável?
- A soma manual das versões (passo 6) bate com a métrica?
- A 3ª versão foi aceita ou bloqueada por cota? Em que ponto exatamente
  (15MB, 20MB, outro valor)?
- Conclusão: hipótese 1 ou 2 — e o que isso significa pra um cliente
  real com versionamento ligado e cota contratada.

## Resultado (executado por Eduardo, 06/09/2026, com `Document1.docx`)

Bucket criado manualmente pela GUI depois de um erro de sintaxe no
Passo 1 (`-enabled` não existe, o flag certo é `-enable` — corrigido
acima). 4 versões de `Document1.docx` (edições reais, tamanhos
1.168.631 a 1.169.724 bytes) já existiam quando o monitoramento
começou:

```
soma manual das 4 versões:            4.676.975 bytes
SeaweedFS_s3_bucket_size_bytes:        4.677.552 bytes
SeaweedFS_s3_bucket_quota_bytes:      20.971.520 bytes (20MB)
SeaweedFS_s3_bucket_read_only:         0
```

**Confirma a Parte 1 da pergunta**: `bucket_size_bytes` bate com a soma
das 4 versões retidas (diferença de 577 bytes = overhead de metadado),
não com o tamanho de só a versão atual (1.168.631). **Hipótese 2
confirmada**: a cota soma versão corrente + todas as antigas retidas.

### Descoberta extra: nem todo upload gera versão — depende do caminho, não do conteúdo

No meio do teste, o usuário reenviou o mesmo `Document1.docx` sem
alteração por dois caminhos diferentes, monitorados ao vivo:

| Via | Nova entrada em `.versions/`? | `traffic_received_bytes_total` (métrica S3) |
|---|---|---|
| Demo de upload (porta 8090, SDK AWS real → API S3) | **Sim**, 2x (uma por envio) | Subiu exatamente o tamanho do arquivo, a cada envio |
| GUI do admin (porta 23646 → Filer nativo) | **Não**, nenhuma vez | **Não mudou nem 1 byte** |

A GUI do admin ainda assim inflou `object_count` (6→8) e
`physical_size_bytes` (+2,3MB) sem criar versão nenhuma — e minutos
depois parte desse espaço foi reciclado sozinho (`object_count` 8→7,
`physical_size_bytes` caiu de volta perto do `bucket_size_bytes`),
confirmando que era sobra de sobrescrita direta, não uma versão retida
de propósito.

**Causa**: versionamento S3 é implementado na camada da **API S3**
(headers `x-amz-version-id`, pasta `.versions/`). A GUI do admin fala
direto com o **namespace nativo do Filer** — o mesmo caminho de
`curl -T` usado na POC I — que não passa pela lógica de versionamento
nunca, porque ela não existe nessa camada. Não é sobre o conteúdo ter
mudado ou não: é sobre qual protocolo fez a escrita.

### Conclusão final

1. Cota soma **todas** as versões retidas, não só a atual — confirmado
   com dado real.
2. Versionamento só é garantido por clientes que falam a **API S3** de
   verdade (SDKs, `mc`, `aws s3`, `rclone` em modo S3). Ferramentas que
   acessam o storage por outro caminho (navegador de arquivos nativo,
   mounts, agentes proprietários) podem sobrescrever objetos em
   silêncio, **mesmo com versionamento ligado no bucket** — sem erro,
   sem aviso, e ainda consumindo cota com o dado órfão da sobrescrita
   até ser reciclado.
3. **Implicação comercial**: "versionamento ligado" não é uma garantia
   universal pro cliente — é uma garantia condicionada a como ele
   acessa o serviço. Vale documentar/avisar explicitamente quais
   ferramentas/protocolos de acesso preservam versionamento antes de
   vender isso como proteção de dado.

### Nota importante: a interface/ferramenta de acesso é o que decide, não o conteúdo do arquivo

Pra não deixar dúvida pra próxima leitura deste documento: o que
determina se uma versão é criada **não é** "o arquivo mudou ou não" —
é **qual caminho fez a escrita**:

- **Do lado do servidor**, o SeaweedFS versiona **todo `PUT` que chega
  pela API S3**, sempre, mesmo com conteúdo idêntico ao anterior — não
  existe comparação de conteúdo nessa camada. Qualquer aplicação que
  fale S3 de verdade (SDK/AWS CLI/`mc`/`rclone` em modo S3, e — no
  contexto real de uso — ferramentas como **S3Drive ou Veeam** apontando
  pra um endpoint S3) vai gerar uma versão nova a cada `PutObject` bem
  sucedido, igual ao que a página de upload-demo mostrou aqui.
- **Do lado do cliente**, porém, a ferramenta pode simplesmente **não
  enviar** o `PUT` se ela mesma detectar que não há mudança (comparação
  de hash/data de modificação antes de transmitir — comum em ferramentas
  de backup/sync, inclusive Veeam em certos modos, pra economizar
  banda). Nesse caso o SeaweedFS nunca recebeu nada pra versionar — não
  é uma falha de versionamento, é o cliente decidindo não reenviar.
- O caso que capturamos nesta POC (GUI do admin, porta 23646) é um
  terceiro cenário, diferente dos dois acima: o servidor **recebeu** a
  escrita, só que por um caminho (Filer nativo) que nunca aciona a
  lógica de versionamento, porque essa lógica só existe na camada da
  API S3.

**Resumindo pra quem for reler**: "todo PUT do mesmo arquivo gera
versão" é verdade **sempre que a aplicação fala a API S3 de verdade**
(caso do S3Drive/Veeam, no entendimento validado aqui) — a exceção
observada foi um caminho de acesso específico deste ambiente (o
navegador de arquivos nativo do admin) que não é uma aplicação S3, é
uma via alternativa de escrita direta no armazenamento.
