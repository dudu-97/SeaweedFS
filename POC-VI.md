# POC VI — Tirar o dado de um disco que vai falhar, sem parar o ambiente

## Contexto

Um disco de um volume node foi identificado como próximo do fim da vida
útil (alerta de falha preditiva). A pergunta: **qual é o processo, no
`weed`, para tirar todo o dado desse disco e deixá-lo livre para
desativar e trocar, sem parar o ambiente e sem perder dado?**

Neste ambiente cada disco é um volume server (1 processo `weed volume`,
1 porta por disco). Esvaziar o disco é, portanto, esvaziar aquele volume
server.

## Resumo do resultado

- **Comando para esvaziar o disco:** `volumeServer.evacuate` (move todos
  os volumes do servidor, e os shards de EC, para os demais). O
  `volume.move` move um volume só, com destino escolhido por você. Os dois
  usam a mesma rotina de cópia e validação.
- **NÃO marcar o volume como `readonly` manualmente** (`volume.mark
  -readonly`). Com essa marcação, a movimentação de um volume de ~4 GB
  falhou 2 de 2 vezes (com `evacuate` e com `move`). Sem ela, funcionou.
- **Para manter transparente:** colocar o servidor em **modo de
  manutenção** (`volumeServer.state -maintenanceOn`) antes de evacuar. O
  master deixa de gravar nele e de criar volumes novos nele (segundo o
  código); as leituras continuam. Com esse modo, a evacuação do volume de
  4 GB funcionou no lab.
- Em todas as falhas a **origem ficou intacta**: a ferramenta só apaga o
  original depois que o destino é validado.

## Ambiente do teste (lab)

- Cluster Enterprise 4.47, 7 volume nodes × 8 discos = 56 volume servers,
  1 rack, replicação `000` (uma única cópia de cada volume), `.dat` de
  10 GB.
- Volume escolhido: **volume 12**, ~4,2 GB, ~1000 arquivos, de um bucket de
  teste, no volume server `192.168.100.51:8080` (swfs-node01, disco 0).
- Os testes foram feitos com o ambiente ligado; **não foi medido o impacto
  em clientes** durante a cópia (não havia carga de leitura/escrita
  controlada). Também não foi medido o tempo de cópia.

## Testes executados

| # | Volume | `readonly` manual antes? | Preparação | Comando | Resultado |
|---|---|---|---|---|---|
| 1 | 12 (4,2 GB) | sim | — | `volumeServer.evacuate -apply` | **falhou** |
| 2 | 5 (213 KB) | não | — | `volume.move` | ok |
| 3 | 5 (213 KB) | sim | — | `volume.move` | ok |
| 4 | 12 (4,2 GB) | não | — | `volume.move` | ok |
| 5 | 12 (4,2 GB) | sim | — | `volume.move` | **falhou** (mesmo erro) |
| 6 | 12 (4,2 GB) | não | modo de manutenção ligado | `volumeServer.evacuate -skipNonMoveable -retry 3 -apply` | **ok** |

Erro das falhas (1 e 5):
```
failed to mount or validate volume 12: target deleted count [1] is not same as origin deleted count [0]
```

### O que aconteceu em cada falha

- A cópia chegou perto do fim, o destino montou o volume e a validação
  comparou contadores: `FileCount` bateu, mas o destino contou 1 arquivo
  apagado e a origem contou 0. A cópia foi descartada.
- **A origem ficou intacta**: `.dat` e `.idx` sem alteração. O `.idx` da
  origem foi lido e não tem entrada de apagado (sem tombstone, sem chave
  repetida, sem tamanho zero).
- A ferramenta avisa `volume N keeps the readonly mark the move added;
  volume.mark -writable clears it`: o volume de origem continua
  `readonly`. Para reabrir: `volume.mark -node <ip:porta> -volumeId N
  -writable`.
- No destino sobrou um arquivo `.sdx` órfão (índice ordenado, que só é
  gerado para volume carregado como somente leitura). Removê-lo antes de
  tentar de novo no mesmo destino.

### Sucesso do teste 6 (evacuação com manutenção ligada)

```
> volumeServer.state -nodes 192.168.100.57:8085 -maintenanceOn
192.168.100.57:8085   -> Maintenance mode: yes
> volumeServer.evacuate -node 192.168.100.57:8085                       # simulação
  moving volume <bucket>_12 192.168.100.57:8085 => 192.168.100.54:8082
> volumeServer.evacuate -node 192.168.100.57:8085 -skipNonMoveable -retry 3 -apply
  moving volume <bucket>_12 192.168.100.57:8085 => 192.168.100.51:8081
  copying ... processed 130.00 MiB ... 3.81 GiB
  tailing volume 12 ...
  deleting volume 12 from 192.168.100.57:8085
  moved volume 12 from 192.168.100.57:8085 to 192.168.100.51:8081
```
Depois, no `volume.list`: o servidor de origem deixou de aparecer; o
volume 12 apareceu em `192.168.100.51:8081` com `Size:4195664344`,
`FileCount:1004`, `DeleteCount:0`, `ReadOnly:false`, idênticos ao que a
origem tinha.

## Achados e decisões

1. **`evacuate` ou `move`?** Para esvaziar um disco, `evacuate`: cobre
   todos os volumes e shards de EC de uma vez, e `-skipNonMoveable` /
   `-retry` evitam que um item ruim interrompa o resto. O `move` serve
   para um volume isolado, para escolher o destino, ou para limitar a
   velocidade (`-ioBytePerSecond`; o `evacuate` não tem essa opção).
2. **`readonly` manual: não usar.** A ferramenta já protege a consistência:
   copia, aplica as escritas que chegaram durante a cópia (`tailing`) e só
   então apaga a origem. Com a marcação manual, volumes grandes falharam.
   Um volume pequeno (5) passou mesmo marcado, então o efeito depende do
   volume; o limite não foi determinado.
3. **Modo de manutenção no lugar do `readonly`.** Pelo código do
   SeaweedFS, um servidor em manutenção "is being drained": o master não
   coloca volumes novos nele e não atribui novas escritas aos volumes que
   ele já tem; a exclusão da origem no fim de cada movimentação é permitida
   nesse modo. Por isso, em tese, os clientes não veem erro (as gravações
   vão para outros volumes) e nenhum dado novo chega ao disco enquanto ele
   é esvaziado. **Isso vem do código e não foi medido no lab** (o teste 6
   funcionou, mas sem tráfego de cliente): confirmar em produção pela
   validação V7.
4. **O destino muda entre a simulação e a execução.** Na simulação o volume
   12 iria para `192.168.100.54:8082`; no `-apply` foi para
   `192.168.100.51:8081`. Se o destino precisa ser previsível, usar
   `volume.move -target`.
5. **Dry-run do `evacuate` mostra o plano** (`moving volume ... => ...`)
   sem mover nada. Sem `-apply`, nada muda.

## O que não foi testado (limites desta POC)

- **Volumes em Erasure Coding.** O lab não tinha shards de EC no momento.
  O `evacuate` deveria movê-los, mas não foi observado.
- **Replicação diferente de `000`.** No lab cada volume tem uma única
  cópia. Com réplicas, o destino tem que respeitar o posicionamento
  (`ReplicaPlacement`); validar que cada volume continua com o mesmo número
  de cópias.
- **Impacto real em clientes** (latência de leitura, erros 5xx no S3)
  durante a cópia, e o **tempo** de cópia.
- **Volumes muito cheios** (perto do limite de 10 GB) e discos com muitos
  volumes ao mesmo tempo.
- **Causa raiz** do erro `deleted count` com `readonly` manual. Hipótese
  (não provada): o destino carrega um volume marcado `readonly` com o
  índice ordenado (`.sdx`) e conta 1 apagado a mais. Candidato a relato
  para o fornecedor.
- Durante os testes, o volume 7 (114 KB, collection padrão) passou a ocupar
  o disco `192.168.100.51:8080`, que estávamos usando como origem. A causa
  não foi determinada. Por isso, ao final de uma evacuação real, **conferir
  que o disco ficou de fato vazio** (validação V5 abaixo).

---

# PRODUÇÃO — Procedimento para esvaziar um disco

Substitua `<MASTER>` pelo endereço de um master (`ip:9333`) e `<NO>` pelo
`ip:porta` do volume server do disco (ex.: `10.0.0.21:8083`). Todos os
comandos `weed shell` abaixo são digitados numa sessão aberta com
`weed shell -master=<MASTER>`.

## 0. Regras que valem durante todo o procedimento

- **Não usar `volume.mark -readonly`.**
- **Não apagar nada à mão** (`rm`, `fs.rm`, `volume.delete`) nem
  desmontar/retirar o disco antes da validação V1–V5.
- **Não usar `-force`/`-apply` sem antes ter rodado a simulação.**
- Se qualquer passo falhar: parar, **não** apagar a origem, seguir a seção
  7.

## 1. Descobrir qual volume server é o disco com problema

Ponto de partida: a posição física do alerta (ex.: iDRAC "Disk 2 in
Backplane 1 of RAID Controller in Slot 7"). É preciso chegar ao
`ip:porta` do volume server. Na máquina do disco:

| Objetivo | Comando |
|---|---|
| Ver discos, serial e onde estão montados | `lsblk -o NAME,SERIAL,LABEL,SIZE,MOUNTPOINT` |
| Ligar o dispositivo físico (serial/slot) ao dispositivo Linux | comparar o serial do `lsblk` com o do iDRAC ou do `perccli`/`storcli` (conforme o seu controlador) |
| Ver qual pasta está montada em qual dispositivo | `findmnt -n -o SOURCE,TARGET /data/disk<N>` |
| Ver qual serviço/porta usa essa pasta | `systemctl cat weed-volume-disk<N>` (na linha `ExecStart` estão o `-dir=` e o `-port=`) |
| Confirmar que a porta está em uso pelo `weed` | `ss -ltnp` (procure a linha da `<porta>`; o processo deve ser o `weed`) |

Resultado esperado: um par **`<NO>`** (`ip:porta`) e o **diretório** do
disco. **Confirme o mapeamento duas vezes** (por serial e pelo
`-dir`/`-port` do serviço) antes de continuar: evacuar o disco errado
tira dado de um disco saudável (não perde dado, mas gera movimentação
desnecessária).

## 2. Baseline — como ver e o que anotar

Guarde tudo em arquivos com data, para comparar depois.

### 2.1 Volumes do disco: tamanho e número de arquivos de cada um

No `weed shell`, o comando é `volume.list`. Para guardar a saída completa
(fora do shell, no host de administração):
```bash
echo 'volume.list' | weed shell -master=<MASTER> > baseline-volume-list-$(date +%F-%H%M).txt
```
Tabela de um volume por linha (nó, id, tamanho, arquivos, apagados,
somente-leitura, collection) a partir desse arquivo:
```bash
awk '/^ *DataNode [0-9.]+:[0-9]+ hdd\(/{node=$2} /^ *volume Id:/{l=$0; gsub(/[ ,]+/," ",l); n=split(l,p," "); for(i=1;i<=n;i++) if(match(p[i],/^[A-Za-z]+:/)) f[substr(p[i],1,RLENGTH-1)]=substr(p[i],RLENGTH+1); printf "%-22s vol=%-4s size=%-12s files=%-6s deleted=%-4s ro=%-5s coll=%s\n", node,f["Id"],f["Size"],f["FileCount"],f["DeleteCount"],f["ReadOnly"],f["Collection"]}' baseline-volume-list-*.txt > baseline-volumes.txt
grep '^<NO>' baseline-volumes.txt        # só os volumes do disco a esvaziar
```
Exemplo de linha: `192.168.100.51:8080  vol=12  size=4157915104  files=995  deleted=0  ro=false  coll=<bucket>`.

Anote, **para cada volume do `<NO>`**: `size`, `files`, `deleted` e `ro`. A
coluna `coll` é o **bucket** dono do volume (vazio = collection padrão).
Se algum volume já aparece com `ro=true`, anote: ele estava assim antes.

**Totais do nó** (o que a evacuação precisa drenar):
```bash
grep -E '^ *DataNode <NO> \{' baseline-volume-list-*.txt
# ex.: DataNode 192.168.100.51:8080 {Size:4157915104 FileCount:995 DeletedFileCount:0 DeletedBytes:0}
```
**Total do cluster** (última linha do `volume.list`): `total size:… file_count:…`.

### 2.2 Shards de Erasure Coding no disco

```bash
grep -i 'ec volume' baseline-volume-list-*.txt
```
Anote os que estiverem sob `DataNode <NO>`. Sem linhas = sem EC nesse nó.

### 2.3 Espaço livre nos demais servidores (o destino cabe?)

Slots livres por servidor (`free:N`) e volumes existentes:
```bash
grep -E '^ *DataNode [0-9.]+:[0-9]+ hdd\(' baseline-volume-list-*.txt
# ex.: DataNode 192.168.100.51:8081 hdd(volume:2/8 active:2 free:6 remote:0)
```
Regra: a soma de `free` dos **outros** servidores tem que ser maior que o
número de volumes do `<NO>`. Além disso, confira o espaço em bytes nos
discos de destino: `df -h /data/disk*` em cada máquina; cada disco
destino precisa ter espaço livre maior que o maior volume que ele vai
receber (volume chega a 10 GB).

### 2.4 Bucket: contagem e checksum

Use o endpoint S3 do ambiente (`<S3>`, ex.: `http://<ip>:8333`) com uma
chave que leia o bucket. Os exemplos usam o `aws` CLI; `mc` ou `rclone`
fazem o mesmo. Os buckets afetados são os da coluna `coll` de
2.1. Como o bucket está espalhado por vários discos, compare **o bucket
inteiro** antes e depois.

**a) Quantidade de objetos e tamanho total:**
```bash
aws --endpoint-url <S3> s3 ls s3://<bucket> --recursive --summarize | tail -2
# Total Objects: N
#    Total Size: BYTES
```
Se o bucket tem versionamento, conte também as versões:
```bash
aws --endpoint-url <S3> s3api list-object-versions --bucket <bucket> \
  --query 'length(Versions)'
```

**b) Checksum da listagem (chave + tamanho + ETag de todos os objetos):**
compara o bucket inteiro sem baixar os dados. Vale como "impressão digital"
antes/depois:
```bash
aws --endpoint-url <S3> s3api list-objects-v2 --bucket <bucket> \
  --query 'Contents[].[Key,Size,ETag]' --output text | sort > baseline-<bucket>-objetos.tsv
sha256sum baseline-<bucket>-objetos.tsv
```
Anote o hash resultante e guarde o `.tsv`.

**c) Checksum do conteúdo de uma amostra:** baixa e calcula o hash do
dado de verdade em, por exemplo, 20 objetos escolhidos ao acaso:
```bash
shuf -n 20 baseline-<bucket>-objetos.tsv | cut -f1 > amostra.txt
while read -r k; do
  printf '%s  ' "$k"; aws --endpoint-url <S3> s3 cp "s3://<bucket>/$k" - | sha256sum
done < amostra.txt > baseline-<bucket>-amostra-sha256.txt
```
Guarde `amostra.txt` e o arquivo de hashes: depois da evacuação, os mesmos
20 objetos têm que dar exatamente os mesmos hashes.

### 2.5 Saúde geral antes de começar

```
cluster.check
volumeServer.state              # sem -nodes: mostra o estado de todos
```
Esperado: todos os nós respondendo; nenhum nó já em manutenção (a não ser
o que você planejou).

## 3. Preparação

1. **Janela e comunicação.** Não é necessário parar o ambiente, mas
   combine um horário de menor carga: a cópia consome disco e rede.
2. **Pausar automações que usam o `lock` do shell**: cron de EC, balance,
   vacuum agendado, jobs do admin/worker. A evacuação segura o `lock`
   durante toda a operação.
3. **Ter o baseline (seção 2) salvo** e o mapeamento do disco confirmado
   (seção 1).

## 4. Execução

No `weed shell`:

| Passo | Comando | O que esperar |
|---|---|---|
| 4.1 | `lock` | sem mensagem de erro |
| 4.2 | `volumeServer.state -nodes <NO> -maintenanceOn` | `<NO> -> Maintenance mode: yes` |
| 4.3 | `volumeServer.evacuate -node <NO>` (**simulação**) | `Running in simulation mode` e uma linha `moving volume <bucket>_<id> <NO> => <destino>` para **cada** volume do baseline. Nada é movido. |
| 4.4 | `volumeServer.evacuate -node <NO> -skipNonMoveable -retry 3 -apply` | por volume: `copying ... processed N MiB ...` → `tailing ...` → `deleting ...` → `moved volume <id> from <NO> to <destino>` |
| 4.5 | `unlock` | — |

Notas:
- No passo 4.3, confira que **todos os volumes do baseline aparecem** e
  que nenhum destino é o próprio `<NO>`. O destino do `-apply` pode ser
  diferente do da simulação (é normal).
- Para limitar o impacto, em vez do `evacuate` dá para mover volume a
  volume: `volume.move -source <NO> -target <destino> -volumeId <id>
  -ioBytePerSecond <bytes/s>` (com `lock`/`unlock` em volta).
- **Deixe o modo de manutenção ligado** até o disco ser trocado.

## 5. Validação — o que você deve ver e como

Faça V1 a V5 antes de qualquer ação no disco. V6 a V8 confirmam que o
ambiente segue saudável.

| # | O que verificar | Como | O que deve aparecer |
|---|---|---|---|
| **V1** | A evacuação terminou sem erro | Saída do passo 4.4 | Para **cada** volume, a sequência `copying` → `tailing` → `deleting` → `moved volume …`. Nenhuma linha começando com `error:`. |
| **V2** | O nó ficou sem volumes | `volume.list` e procure `<NO>` | O `<NO>` **não aparece** mais como DataNode com volumes (ou aparece com `volume:0/N`). Nenhuma linha `ec volume` sob ele. |
| **V3** | Cada volume chegou igual ao destino | `volume.list` e compare com `baseline-volumes.txt` (2.1): procure cada `vol=<id>` | Mesmo `Size`, mesmo `FileCount`, `DeleteCount:0` (ou o mesmo do baseline), `ReadOnly:false` (ou o mesmo do baseline), mesmo `ReplicaPlacement`. O volume aparece em **exatamente um** nó (se a replicação for `000`). |
| **V4** | Totais coerentes | Rodapé do `volume.list` (`total size` / `file_count`) vs. baseline | O tamanho e o `file_count` totais **não diminuem**. Podem subir se chegaram uploads novos durante a janela (os volumes movidos têm que manter os mesmos números individuais, V3). |
| **V5** | O disco físico ficou vazio | Na máquina do disco: `ls -la <diretório do disco>` e `df -h <diretório>` | Só devem existir `lost+found` e `vol_dir.uuid`. **Nenhum** arquivo `.dat`, `.idx`, `.sdx`, `.vif`, `.ecx`, `.ecj` ou `.ec00`, `.ec01`, ... `df` com uso mínimo (só metadados do sistema de arquivos). **Se sobrar algum arquivo, não retire o disco** (seção 7). |
| **V6** | Os dados estão íntegros pelo S3 | Repetir 2.4: `s3 ls --summarize`, o checksum da listagem e o hash da amostra | Mesmo `Total Objects` e `Total Size` (se não houve escrita no bucket); o `sha256sum` de `baseline-<bucket>-objetos.tsv` idêntico (se não houve escrita); os **hashes da amostra idênticos**. Se houve escrita durante a janela, compare só os objetos do baseline (todos têm que continuar iguais). |
| **V7** | Clientes não foram afetados | Logs e métricas do S3/Filer durante a janela: `journalctl -u weed-s3 --since "<início>"` (e o filer); métricas/monitoramento do ambiente | Sem aumento de erros 5xx nem de timeouts; leituras normais. |
| **V8** | Cluster e manutenção no estado certo | `cluster.check` e `volumeServer.state -nodes <NO>` | `cluster.check` sem falha nova; `<NO>` continua com `Maintenance mode: yes`. |

Opcional, mais pesado: `volume.scrub -volumeId <id>` num volume movido,
para verificar o conteúdo no destino.

## 6. Retirar o disco e colocar o novo

Só depois de V1–V5 aprovados:

1. Tirar o servidor do cluster: `volumeServer.leave -node <NO> -apply`
   (ele para de mandar heartbeat ao master).
2. Na máquina: `systemctl disable --now weed-volume-disk<N>`, confirmar que
   nada usa o diretório (`lsof +D <diretório>`), `umount <diretório>` e
   comentar/remover a linha do disco no `/etc/fstab`.
3. Trocar o disco fisicamente (o array/controlador conforme o seu
   procedimento).
4. Formatar e rotular o disco novo, montar em `<diretório>` (com o mesmo
   rótulo no `fstab`), ajustar o dono para o usuário do serviço.
5. `systemctl enable --now weed-volume-disk<N>`: o servidor volta ao
   cluster vazio, com o mesmo `ip:porta`.
6. `volumeServer.state -nodes <NO> -maintenanceOff` e confirme
   `Maintenance mode: no`. **Confira o estado**: como esse estado é
   guardado pelo volume server, ele pode ter sido perdido com o disco
   antigo.
7. Opcional: `volume.balance -apply` (e `ec.balance -apply`) para devolver
   dado ao disco novo.
8. Reativar as automações pausadas na seção 3.

## 7. Se algo falhar

- **A ferramenta só apaga a origem depois de validar o destino.** Se um
  volume falhar, ele continua no disco original. Não apague nada.
- **Erro `target deleted count [x] is not same as origin deleted
  count [y]`:** a cópia foi descartada; o volume de origem pode ter ficado
  `readonly` (a mensagem diz `keeps the readonly mark the move added`).
  1. No **destino** que falhou, procurar e apagar o `.sdx` órfão:
     `ls <diretório do destino> | grep '\.sdx$'`.
  2. Reabrir a origem: `volume.mark -node <NO> -volumeId <id> -writable`
     (se o volume ainda está lá).
  3. Confirmar que o volume **não** foi marcado `readonly` por você.
  4. Repetir com `volume.move -source <NO> -target <outro destino>
     -volumeId <id>`, sem `readonly` manual. Se falhar de novo, parar e
     abrir chamado com o fornecedor (anexar a saída completa).
- **Se precisar abortar tudo:** `volumeServer.state -nodes <NO>
  -maintenanceOff` e `unlock`. Os volumes que já foram movidos ficam nos
  destinos (consistentes); os demais ficam no disco original.
- **O disco piorou durante a cópia** (erros de leitura): não interromper de
  forma brusca; priorizar os volumes dos buckets mais críticos com
  `volume.move` um a um, e acompanhar `journalctl -u weed-volume-disk<N>`
  e o log do kernel (`dmesg`) na máquina.

## 8. Registro (preencher a cada execução)

| Item | Valor |
|---|---|
| Data, janela, executante | |
| Disco (posição física) / `<NO>` / diretório | |
| Volumes movidos (id, tamanho, arquivos) | |
| Tempo total e por volume | |
| Impacto observado em clientes (V7) | |
| Resultado V1 a V8 | |
| Problemas e como foram tratados | |
