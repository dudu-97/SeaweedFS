# Relatório de testes — SeaweedFS lab

Registro técnico das observações feitas durante os testes de upload/S3 no
lab (ver [README.md](README.md) para a arquitetura completa e
[00-config.env](00-config.env) para os parâmetros do ambiente).

## 1. Fluxo de recebimento de um arquivo (upload)

Quando um cliente (S3 API, `rclone`, `mc`, a página de demo, etc.) envia um
arquivo, o trabalho é dividido entre três papéis, cada um responsável por
uma parte diferente:

```
Cliente (assina a requisição com AWS Signature V4)
        │  PUT http://swfs-vol1:8333/<bucket>/<chave>
        ▼
Filer (swfs-vol1:8333) — plano de metadado
        │  quebra o arquivo em pedaços (chunks)
        │  para cada chunk, pede ao Master um volume+ID onde gravar
        ▼
Master (raft leader, um dos swfs-master1/2/3:9333) — plano de controle
        │  responde com um volume já "grávavel" existente
        │  se a reserva de volumes grávaveis estiver baixa, manda CRIAR
        │  volumes novos nos volume servers (em lote, não um por vez) e
        │  atualiza seu mapa de topologia em memória
        ▼
Volume Server (swfs-vol1 ou swfs-vol2:8080) — plano de dados
        │  recebe os bytes DIRETO do filer (não passa pelo master de novo)
        │  grava no arquivo .dat (append) + atualiza o índice .idx
        ▼
Filer grava o "manifesto" do arquivo (lista de chunks) no seu metadado
local (LevelDB, em /data/filer/filerldb2 no swfs-vol1)
```

Ponto chave da arquitetura: o **master nunca vê os bytes do arquivo** — ele
só aloca IDs e mantém o mapa de "o que está onde". Os bytes trafegam
direto entre o filer e o volume server. É essa separação que permite o
cluster escalar sem o master virar gargalo.

## 2. Observação prática: CPU/memória durante um upload paralelo

Teste realizado: 25 arquivos de 200MB (4,9GB no total) enviados com
`rclone copy --transfers 8` (8 uploads simultâneos), simulando vários
clientes gravando ao mesmo tempo.

**Padrão observado no virt-manager:** CPU subiu primeiro nos volume
servers (`swfs-vol1`/`swfs-vol2`), memória subiu logo depois nos masters.

**Explicação, confirmada consultando o cluster ao vivo:**

- **CPU nos volumes primeiro** — é o trabalho síncrono e direto: gravar os
  bytes no `.dat` (append) e calcular o checksum de cada needle. Reage na
  hora porque é I/O real acontecendo.
- **Memória nos masters logo depois** — à medida que os volumes existentes
  enchiam, o master precisou criar volumes novos para continuar aceitando
  escrita. Confirmado via `/dir/status` do master: o cluster tinha 14
  volumes no total após o teste (7 em cada rack), contra bem menos antes
  do teste. O SeaweedFS cria volumes em lote (não um de cada vez) quando a
  reserva de "volumes grávaveis" fica baixa — por isso o efeito aparece em
  rajada, um pouco depois do início do upload, não simultâneo. Cada volume
  novo é uma entrada a mais no mapa de topologia que o master mantém 100%
  em memória (RAM), nunca em disco — daí o aumento de memória.

**Sobre a memória "não baixar" no `swfs-vol2`:** checado com `free -h`
dentro das VMs, não `virsh`/virt-manager (mais confiável para essa
leitura):

| | `swfs-vol1` | `swfs-vol2` |
|---|---|---|
| RAM usada de verdade (`used`) | 546 MiB | 384 MiB |
| Cache de disco (`buff/cache`) | 906 MiB | 1,6 GiB |
| Disponível se precisar (`available`) | 1,4 GiB | 1,5 GiB |
| RSS do processo `weed` | ~100-210 MiB (3 processos: volume+filer+admin) | ~103 MiB (só volume) |

O processo `weed` em si usa pouca RAM nas duas VMs — o que ficou "alto" no
gráfico do virt-manager é `buff/cache`, não uso real de processo. O Linux
guarda uma cópia em cache de página na RAM livre depois de escrever muito
dado em disco (útil para uma leitura futura), e só libera esse cache
quando algum processo realmente precisa da memória — não é vazamento.
`swfs-vol2` roda só o volume server sozinho, sem outro processo disputando
aquela RAM livre, então o cache fica parado lá por mais tempo do que no
`swfs-vol1` (que roda volume + filer + admin, e por isso recicla esse
cache com mais frequência).

**Nota de capacidade:** `Free: 2` no `/dir/status` do master indica que só
sobra espaço calculado para ~2 volumes novos antes de precisar de mais
disco em `swfs-vol1`/`swfs-vol2` (10GB cada, `DATA_DISK_SIZE` em
`00-config.env`). Vale aumentar esse valor antes de rodar testes de carga
maiores.

## 3. Os arquivos de "nomes longos" vistos no armazenamento

Ao navegar no disco de dados dos volume servers aparecem arquivos como:

```
meu-bucket-teste_10.dat   730 MB
meu-bucket-teste_10.idx     5 KB
meu-bucket-teste_10.vif    194 B
meu-bucket-teste_13.dat   892 MB
...
```

Comparados com volumes mais antigos, sem nome de bucket:
```
4.dat   5.dat   6.dat   (criados antes de existir qualquer bucket)
```

**O que são:** cada um desses é um **volume físico** do SeaweedFS — o
arquivo grande onde ele empacota muitos objetos pequenos lado a lado (a
ideia central do SeaweedFS: evitar o overhead de um arquivo por objeto no
filesystem). O prefixo `meu-bucket-teste_` aparece porque, no SeaweedFS,
um bucket S3 é implementado como uma **collection**, e volumes de uma
collection nomeada levam o nome dela no arquivo físico. Volumes sem
collection (criados antes de qualquer bucket existir) ficam só com o
número (`4.dat`).

Cada volume tem 3 arquivos:
- **`.dat`** — os dados de verdade: os bytes de cada objeto/chunk gravado,
  um atrás do outro (append-only). É o arquivo grande.
- **`.idx`** — índice: mapeia o ID de cada "needle" (pedaço gravado) para
  a posição exata dentro do `.dat`, para leitura rápida sem varrer o
  arquivo inteiro.
- **`.vif`** — metadado do próprio volume (versão, tipo de replicação,
  collection) — pequeno, ~194 bytes, quase não muda.

**Correção a uma suposição:** não é "um arquivo longo = um chunk". É o
oposto — **um volume (`.dat`) contém muitos chunks/needles**, possivelmente
de vários objetos diferentes, todos compactados sequencialmente no mesmo
arquivo. Os `arquivo_01.bin` a `arquivo_25.bin` enviados no teste da seção
2, por exemplo, foram todos distribuídos entre os poucos volumes
disponíveis naquele momento (`meu-bucket-teste_10`, `_13`, `_14` no
`swfs-vol1`; `_11`, `_12` no `swfs-vol2`) — não um volume por arquivo.
Isso é o próprio propósito do SeaweedFS: agrupar muitos arquivos pequenos
em poucos arquivos grandes no disco, em vez de um inode por arquivo.

## Referências
- [README.md](README.md) — arquitetura do lab
- [00-config.env](00-config.env) — parâmetros do ambiente
- [LABS-TESTES-S3.md](LABS-TESTES-S3.md) — roteiro de testes usado (fora do Git, pessoal)
