# Roteiro — Esvaziar um disco (`volumeServer.evacuate`) e trocá-lo

Passo a passo para uso em **produção**, montado a partir da POC VI e da
execução no lab de 20/09. Cada disco é um volume server (1 processo
`weed volume`, 1 porta): esvaziar o disco é esvaziar aquele volume server.

Como ler os comandos: nos blocos de terminal (`bash`), cada comando tem um comentário `#` dizendo o que
faz. Nos blocos do `weed shell`, os comandos ficam limpos (para poder colar) e uma tabela logo abaixo explica
cada um.

## Status de validação

| Parte | Estado |
|---|---|
| Evacuar um volume normal (`evacuate` com o servidor em manutenção) | **Validado no lab** duas vezes (POC VI: 4,2 GB; 20/09: 4,4 GB) |
| Evacuar com volumes em EC no cluster | Cluster já tinha EC, mas o servidor evacuado só tinha um volume normal. **Servidor com shards de EC ainda não testado** |
| Trocar o disco e colocá-lo de volta no cluster | **Em validação no lab** (marcar aqui quando concluir) |
| Impacto em clientes e tempo de cópia | **Não medidos** |

## Convenções
- `<MASTER>`: `ip:9333` de um master. `<NO>`: `ip:porta` do volume server do disco.
- `<bucket>`: bucket dono do volume. `<N>`: índice do disco. `<dir>`: ponto de montagem do disco.
- Comandos `weed shell` são digitados numa sessão aberta com `weed shell -master=<MASTER>`.
- Nomes de serviço, usuário e caminhos (`weed-volume-disk<N>`, `/data/disk<N>`, `swfs`) são os do
  lab: adapte aos de produção.

## 0. Regras durante todo o procedimento
- **Não usar `volume.mark -readonly`.** Com essa marcação, volumes grandes falharam na validação
  de cópia (POC VI). O modo de manutenção faz o papel de proteger o servidor.
- **Não apagar nada à mão** (`rm`, `fs.rm`, `volume.delete`) nem retirar o disco antes de validar V1–V5.
- **Sempre rodar a simulação** (`evacuate` sem `-apply`) antes do `-apply`.
- Se qualquer passo falhar: parar e ir para a seção 6. A origem só é apagada depois que o destino é validado.

## 1. Preparação

### 1.1 Liberar o `lock` e pausar automações
O `evacuate` segura o `lock` do shell durante toda a operação.
1. Esperar terminar qualquer rodada de EC em andamento. No master, o comando abaixo não deve mostrar nada:
   ```bash
   ps -eo args | grep -E "^weed shell" | grep -v grep   # lista processos "weed shell" ativos; vazio = nenhum rodando
   ```
   (Não use `pgrep -f "weed shell"` por SSH: ele casa com a própria linha de comando do SSH e dá falso positivo.)
   No lab, o primeiro `lock` ficou em `waiting for lock held by <ip do master>` porque o EC ainda rodava.
2. **Pausar o cron de EC** (senão ele pode converter o volume em EC, ou disputar o `lock`):
   ```bash
   sudo sed -i 's|^\*/30|#PAUSADO */30|' /etc/cron.d/swfs-ec   # comenta a linha do cron de EC (a rotina para de disparar)
   grep -v '^#' /etc/cron.d/swfs-ec | grep -c '\*/30'          # conta linhas de agendamento ainda ativas: deve dar 0
   ```
3. Se o `lock` esperar por `admin-plugin`, é o admin do SeaweedFS; costuma liberar sozinho.

### 1.2 Confirmar qual disco é (duas vezes)
Partindo do alerta (posição física, ex.: iDRAC "Disk N in Backplane B") até o `<NO>`:

| Objetivo | Comando (na máquina do disco) | O que faz |
|---|---|---|
| Discos, serial e onde estão montados | `lsblk -o NAME,SERIAL,LABEL,SIZE,MOUNTPOINT` | lista os discos com serial, label e ponto de montagem |
| Serial do dispositivo x serial do alerta | comparar com o iDRAC ou o `perccli`/`storcli` do seu controlador | liga o disco físico do alerta ao dispositivo Linux |
| Pasta montada em qual dispositivo | `findmnt -n -o SOURCE,TARGET <dir>` | mostra qual dispositivo está montado na pasta |
| Serviço e porta que usam a pasta | `systemctl cat weed-volume-disk<N>` (linha `ExecStart`: `-dir=` e `-port=`) | mostra a definição do serviço: pasta e porta do volume server |

**Lab (KVM):** `./10-mapa-discos.sh <ip>:<porta>` mostra `/dev/sdX`, label, disco alvo, serial e o arquivo qcow2.
Evacuar o disco errado não perde dado, mas gera movimentação desnecessária.

### 1.3 Baseline (guardar em arquivos com data)
```bash
# salva a topologia inteira (todos os volumes, com tamanho e nº de arquivos) num arquivo com data e hora
echo 'volume.list' | weed shell -master=<MASTER> > baseline-volume-list-$(date +%F-%H%M).txt
```
Uma linha por volume (nó, id, tamanho, arquivos, apagados, somente-leitura, bucket). O `awk` abaixo lê o arquivo
salvo, guarda em `node` o volume server da linha `DataNode`, extrai os campos `Id`, `Size`, `FileCount`,
`DeleteCount`, `ReadOnly` e `Collection` de cada linha `volume Id:` e imprime uma linha por volume:
```bash
awk '/^ *DataNode [0-9.]+:[0-9]+ hdd\(/{node=$2} /^ *volume Id:/{l=$0; gsub(/[ ,]+/," ",l); n=split(l,p," "); for(i=1;i<=n;i++) if(match(p[i],/^[A-Za-z]+:/)) f[substr(p[i],1,RLENGTH-1)]=substr(p[i],RLENGTH+1); printf "%-22s vol=%-4s size=%-12s files=%-6s deleted=%-4s ro=%-5s coll=%s\n", node,f["Id"],f["Size"],f["FileCount"],f["DeleteCount"],f["ReadOnly"],f["Collection"]}' baseline-volume-list-*.txt > baseline-volumes.txt
grep '^<NO>' baseline-volumes.txt                        # filtra só os volumes do disco a esvaziar (o que precisa chegar igual ao destino)
grep -A3 'DataNode <NO> hdd' baseline-volume-list-*.txt  # mostra o resumo do nó: volumes, espaço e totais
grep -i 'ec volume' baseline-volume-list-*.txt           # lista os shards de EC no cluster (anote os do <NO>)
```
Anote, para cada volume do `<NO>`: `size`, `files`, `deleted`, `ro`. A coluna `coll` é o `<bucket>`.

Bucket (contagem e checksum), com uma chave que leia o bucket (`aws`, `mc` ou `rclone`):
```bash
# conta os objetos e soma o tamanho do bucket (as duas últimas linhas: Total Objects e Total Size)
aws --endpoint-url <S3> s3 ls s3://<bucket> --recursive --summarize | tail -2
# lista chave, tamanho e ETag de todos os objetos, ordenada, e guarda no arquivo
aws --endpoint-url <S3> s3api list-objects-v2 --bucket <bucket> --query 'Contents[].[Key,Size,ETag]' --output text | sort > baseline-<bucket>-objetos.tsv
sha256sum baseline-<bucket>-objetos.tsv                  # hash único da listagem (impressão digital do bucket): guardar
shuf -n 20 baseline-<bucket>-objetos.tsv | cut -f1 > amostra.txt   # sorteia 20 objetos e guarda só o nome de cada um
# baixa cada objeto da amostra e calcula o hash do conteúdo de verdade (para comparar depois)
while read -r k; do printf '%s  ' "$k"; aws --endpoint-url <S3> s3 cp "s3://<bucket>/$k" - | sha256sum; done < amostra.txt > baseline-<bucket>-amostra-sha256.txt
```

### 1.4 Cabe nos demais servidores?
Os outros servidores precisam ter espaço e slots para todos os volumes do `<NO>`:
```bash
grep -E '^ *DataNode [0-9.]+:[0-9]+ hdd\(' baseline-volume-list-*.txt   # uma linha por servidor; "free:N" = slots livres
df -h                                                                    # (nos discos de destino) espaço livre; um volume chega ao limite configurado
```

## 2. Execução
No `weed shell`:
```
lock
volumeServer.state -nodes <NO> -maintenanceOn
volumeServer.evacuate -node <NO>
volumeServer.evacuate -node <NO> -skipNonMoveable -retry 3 -apply
unlock
```

| Comando | O que faz |
|---|---|
| `lock` | trava o cluster para operações administrativas: impede que outra tarefa (cron de EC, admin) mexa nos volumes ao mesmo tempo |
| `volumeServer.state -nodes <NO> -maintenanceOn` | coloca o servidor em modo de manutenção: o master deixa de gravar nele e de criar volumes nele (as leituras continuam) |
| `volumeServer.evacuate -node <NO>` | **simulação**: mostra para onde cada volume iria, sem mover nada |
| `volumeServer.evacuate -node <NO> -skipNonMoveable -retry 3 -apply` | move de verdade todos os volumes (e shards de EC) do servidor para os demais; `-skipNonMoveable` ignora o que não puder ser movido em vez de parar, e `-retry 3` tenta de novo até 3 vezes |
| `unlock` | libera o `lock` |

O que esperar:

| Passo | Saída esperada |
|---|---|
| `lock` | sem erro (ou `waiting for lock ...` seguido de `lock acquired`) |
| `-maintenanceOn` | `<NO> -> Maintenance mode: yes` |
| `evacuate` sem `-apply` | `Running in simulation mode` e `moving volume <bucket>_<id> <NO> => <destino>` para **cada** volume do baseline. Nada é movido |
| `evacuate ... -apply` | por volume: `copying ... processed N MiB` → `tailing` → `deleting` → `moved volume <id> from <NO> to <destino>` |

Nas mensagens do `-apply`: `copying` copia o volume para o destino, `tailing` aplica as escritas que chegaram durante
a cópia, e `deleting` apaga a origem só depois de o destino ser validado.

- **O destino do `-apply` pode ser diferente do da simulação** (observado nas duas execuções). Se precisar de
  destino fixo: `volume.move -source <NO> -target <destino> -volumeId <id>` (move um volume, com destino escolhido por você).
- Para limitar a carga: `volume.move ... -ioBytePerSecond <bytes/s>` (o `evacuate` não tem essa opção).
- **Deixar o servidor em manutenção** até terminar a troca do disco.

## 3. Validação (V1 a V5 antes de qualquer ação no disco)

| # | O que ver | Como | Esperado |
|---|---|---|---|
| V1 | Terminou sem erro | saída do `-apply` | para cada volume, `moved volume <id>`; nenhuma linha `error:` |
| V2 | Servidor sem volumes | `curl -s http://<NO>/status` (pergunta ao volume server o que ele guarda) ou `volume.list` | `"Volumes": []`; `volume.list` sem volumes nem `ec volume` sob `<NO>` |
| V3 | Cada volume igual no destino | `volume.list`, procurar `volume Id:<id>` e comparar com o baseline | mesmo `Size`, `FileCount`, `DeleteCount` e `ReadOnly`, em **um** servidor só |
| V4 | Totais coerentes | rodapé do `volume.list` | tamanho e nº de arquivos totais não diminuem |
| V5 | Disco físico vazio | na máquina: `ls -la <dir>` (lista o conteúdo) e `df -h <dir>` (mostra o uso) | só `lost+found` e `vol_dir.uuid` (nenhum `.dat`, `.idx`, `.vif`, `.sdx`, `.ec*`) |
| V6 | Dado íntegro pelo S3 | repetir a contagem, o checksum da listagem e a amostra do baseline | valores idênticos (se não houve escrita no bucket) |
| V7 | Clientes sem impacto | logs/métricas do S3 e do filer na janela | sem aumento de 5xx ou timeouts |
| V8 | Cluster e manutenção | `cluster.check` (testa a conectividade do master com todos os volume servers) e `volumeServer.state -nodes <NO>` (mostra o estado de manutenção) | sem falha nova; `Maintenance mode: yes` |

## 4. Troca do disco (só depois de V1–V5)

### 4A. Produção (disco físico)
1. Tirar o servidor do cluster (no `weed shell`): `lock`, `volumeServer.leave -node <NO> -apply`, `unlock`.

   | Comando | O que faz |
   |---|---|
   | `volumeServer.leave -node <NO> -apply` | faz o servidor parar de enviar heartbeat ao master: o master deixa de considerá-lo |
2. Na máquina: `sudo systemctl disable --now weed-volume-disk<N>` (para o serviço e impede que suba no boot);
   `sudo umount <dir>` (desmonta o disco); conferir `findmnt <dir>` vazio (confirma que desmontou).
3. Comentar a linha do disco no `/etc/fstab` (evita o boot esperar por um disco que saiu).
4. Trocar o disco fisicamente e fazer o controlador reconhecê-lo (RAID/virtual disk, se for o caso): procedimento do
   seu controlador, fora do escopo deste roteiro. Guardar o disco antigo até fechar a validação.

### 4B. Lab (KVM)
```bash
# weed shell:  lock / volumeServer.leave -node <NO> -apply / unlock     (tira o servidor do cluster, ver 4A)
# --- na VM ---
sudo systemctl disable --now weed-volume-disk<N>                        # para o serviço do disco e o desativa no boot
sudo umount /data/disk<N> && (findmnt /data/disk<N> || echo desmontado) # desmonta e confirma que a pasta ficou sem disco
sudo sed -i 's|^LABEL=<label> |#LABEL=<label> |' /etc/fstab             # comenta a linha do disco no fstab (evita o boot esperar por ele)
# --- no host, na pasta do projeto (o XML já vem de ./10-mapa-discos.sh <ip>:<porta>) ---
virsh detach-disk <vm> <alvo> --live --config                           # desconecta o disco da VM agora (--live) e de forma permanente (--config)
mv <vm>/<vm>-data<N>.qcow2 <vm>/<vm>-data<N>-ANTIGO.qcow2              # guarda o arquivo do disco antigo (não apaga)
qemu-img create -f qcow2 <vm>/<vm>-data<N>.qcow2 40G                    # cria o disco novo, vazio, thin, de 40 GB
virsh attach-device <vm> <vm>/disco<N>.xml --live --config              # conecta o disco novo no mesmo endereço SCSI e serial do antigo
```
O XML (`disco<N>.xml`) mantém o mesmo endereço SCSI e o mesmo serial do disco antigo.

## 5. Colocar o disco novo no cluster (produção e lab)
Na máquina (adapte nomes ao seu ambiente):
```bash
lsblk -o NAME,SIZE,SERIAL,LABEL                                # acha o disco novo pelo serial (aparece sem label nem sistema de arquivos)
sudo mkfs.ext4 -F -L <label> /dev/<dispositivo>                # formata o disco novo em ext4 com o label (CUIDADO: apaga o que houver no dispositivo)
sudo sed -i 's|^#LABEL=<label> |LABEL=<label> |' /etc/fstab    # reativa a linha do disco no fstab (monta pelo label)
sudo mount -a && findmnt <dir>                                 # monta o que está no fstab e confirma que o disco montou na pasta
sudo chown -R swfs:swfs <dir>                                  # dá a posse da pasta ao usuário do serviço
sudo systemctl enable --now weed-volume-disk<N>                # liga o serviço do volume server e o ativa no boot
curl -s http://localhost:<porta>/status | head -c 300          # pergunta ao volume server se ele já responde
```
**Aguarde o `curl` acima responder antes de ir ao `weed shell`.** Sob carga o volume server pode levar
alguns minutos para subir (no lab levou ~2 min). Nesse intervalo, `volumeServer.state` dá
`connection refused` na porta gRPC (`18<porta>`, ex.: `18083`): não é falha, é o processo ainda inicializando.
Confirme também que as duas portas estão escutando: `ss -ltn | grep -E ':(<porta>|18<porta>)\b'`.

No `weed shell`:
```
volumeServer.state -nodes <NO>
volumeServer.state -nodes <NO> -maintenanceOff
volume.list
```

| Comando | O que faz |
|---|---|
| `volumeServer.state -nodes <NO>` | mostra o estado de manutenção do servidor (`Maintenance mode: yes` ou `no`) |
| `volumeServer.state -nodes <NO> -maintenanceOff` | desliga a manutenção: o master volta a gravar e a criar volumes no servidor (só se ainda estiver `yes`) |
| `volume.list` | lista a topologia: o `<NO>` deve voltar com `volume:0/N` (vazio e disponível) |

Validação do disco novo:

| # | O que ver | Esperado |
|---|---|---|
| N1 | `df -h <dir>` | tamanho do disco novo, quase vazio |
| N2 | `systemctl is-active weed-volume-disk<N>` e `curl .../status` | `active` e resposta JSON |
| N3 | `volume.list` | `<NO>` de volta, com `volume:0/N` e a capacidade nova |
| N4 | `volumeServer.state -nodes <NO>` | `Maintenance mode: no` |
| N5 | slots livres / "volumes que ainda podem ser criados" no painel | voltam ao valor de antes da evacuação |

O servidor volta **vazio**. Para devolver dados a ele, no `weed shell`, com `lock`/`unlock`:

| Comando | O que faz |
|---|---|
| `volume.balance -apply` | redistribui volumes normais entre os servidores, dando dados ao disco novo |
| `ec.balance -apply` | redistribui os shards de EC entre os servidores |

Faça isso fora da janela do cron de EC. Depois de tudo, reativar o cron:
```bash
sudo sed -i 's|^#PAUSADO \*/30|*/30|' /etc/cron.d/swfs-ec      # descomenta a linha: o cron de EC volta a disparar a cada 30 min
```

## 6. Se algo falhar
- **A ferramenta só apaga a origem depois de validar o destino.** Se um volume falhar, ele continua no disco original.
- Erro `target deleted count [x] is not same as origin deleted count [y]`: a cópia foi descartada. No destino, remover
  o `.sdx` órfão (`ls <dir do destino> | grep '\.sdx$'` lista os arquivos `.sdx`); reabrir a origem se ficou somente leitura
  (`volume.mark -node <NO> -volumeId <id> -writable`, que volta o volume a aceitar escrita); repetir sem `readonly`
  manual, com `volume.move -source <NO> -target <outro destino> -volumeId <id>`. Se persistir, parar e abrir chamado.
- Abortar tudo: `volumeServer.state -nodes <NO> -maintenanceOff` (volta o servidor ao serviço) e `unlock`.
  O que já foi movido fica nos destinos, íntegro.
- Desfazer a troca de disco (lab): `virsh detach-disk`, voltar o `-ANTIGO.qcow2` ao nome original e `virsh attach-device`.
- Disco piorando durante a cópia: priorizar os volumes mais críticos com `volume.move` um a um e acompanhar
  `journalctl -u weed-volume-disk<N>` (log do serviço) e o `dmesg` (mensagens do kernel) da máquina.

## 7. Registro (preencher a cada execução)

| Item | Valor |
|---|---|
| Data, janela, executante | |
| Disco (posição física) / `<NO>` / `<dir>` / serial | |
| Volumes movidos (id, tamanho, arquivos, destino) | |
| Início e fim; tempo total | |
| Shards de EC no servidor antes/depois | |
| Resultado V1 a V8 | |
| Troca do disco e resultado N1 a N5 | |
| Problemas e como foram tratados | |

## 8. Execução de referência (lab, 20/09)
- Servidor `192.168.100.56:8083` (VM node06, disco 3, `/dev/sdd`, serial `swfs-node06-0-1-3`) com **1 volume normal**
  (`<bucket>_15`, 4.452 MB, 1.122 arquivos, gravável) e nenhum shard de EC.
- O primeiro `lock` ficou em `waiting for lock held by <master>`: o EC ainda rodava. Depois: `lock acquired`.
- Simulação: `moving volume <bucket>_15 192.168.100.56:8083 => 192.168.100.54:8085`.
- `-apply`: o destino foi **`192.168.100.53:8081`** (diferente da simulação). Cópia de 4,32 GiB em blocos de 130 MiB,
  depois `tailing`, `deleting` e `moved volume 15`. Sem nenhum erro. O servidor **ficou em manutenção** ao final.
- Troca do disco: o volume server novo demorou ~2 min para responder após o `systemctl enable --now` (o
  `volumeServer.state` deu `connection refused` na porta gRPC nesse intervalo). Depois de subir, o master já o
  enxergava com `volume:0/8`, disco de 40G e **`Maintenance mode: no`** sem ter rodado o `-maintenanceOff`
  (o estado de manutenção pode ficar guardado no disco do servidor; não confirmado).
- Tempo total e demais validações: **preencher** (não foram cronometrados).
