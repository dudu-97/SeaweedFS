# Lab SeaweedFS — KVM/libvirt + cloud-init + roteador automatizado

Lab de aprendizado para SeaweedFS: 5 VMs Ubuntu 24.04 (3 masters em
quorum Raft + 2 volume servers, um deles com filer/S3 embutido) numa
rede **isolada** do KVM, atrás de uma **VM roteadora** (mesma imagem
Ubuntu das demais) com IP forwarding + NAT já automatizados via
cloud-init — zero passo manual de infraestrutura.

Subir os *processos* do próprio SeaweedFS (`weed master/volume/filer`)
é manual (de propósito, para você aprender a topologia antes de
automatizar) — esse é o único passo manual do lab. Todo o resto (VMs,
discos, rede, SSH, NAT/internet, disco de dados formatado/montado e o
binário `weed` já instalado em cada VM) já sobe pronto com
`./deploy-lab.sh`.

> Tentamos primeiro um roteador **FreeBSD** via cloud-init (a imagem
> oficial usa uma ferramenta própria do FreeBSD chamada `nuageinit`, e
> não o cloud-init da Canonical) e esbarramos em limitações dela — veja
> "Notas técnicas" mais abaixo. Trocamos para Ubuntu para manter o lab
> 100% automático; a imagem FreeBSD continua em `Imagens/` caso você
> queira retomar esse estudo depois.

## Arquitetura

```
                         rede "default" (NAT do KVM, já existente)
                                    │
                              [ swfs-router ]  <- Ubuntu, NAT automático
                       WAN 192.168.122.150 │  │ LAN 192.168.100.1/24
                                           │  │
                    rede isolada "seaweedfs-lab" (sem DHCP, sem NAT)
                                           │
        ┌───────────┬───────────┬─────────┴─┬───────────┐
   swfs-master1 swfs-master2 swfs-master3 swfs-vol1   swfs-vol2
    .11 (raft)    .12 (raft)   .13 (raft)   .21         .22
                                          volume+filer  volume
                                          +S3 (rack1)   (rack2)
```

| VM             | Papel                                | IP                              |
|----------------|----------------------------------------|----------------------------------|
| swfs-router    | Roteador (gateway/NAT do lab, automático) | 192.168.122.150 (WAN) / 192.168.100.1 (LAN) |
| swfs-master1   | `weed master` (nó 1 do raft)            | 192.168.100.11                  |
| swfs-master2   | `weed master` (nó 2 do raft)            | 192.168.100.12                  |
| swfs-master3   | `weed master` (nó 3 do raft)            | 192.168.100.13                  |
| swfs-vol1      | `weed volume` (rack1) + filer + S3      | 192.168.100.21                  |
| swfs-vol2      | `weed volume` (rack2)                   | 192.168.100.22                  |

Por que essa topologia (e não só 3 VMs):
- **3 masters** — o SeaweedFS usa Raft para eleger o master líder. Com
  só 1 master você nunca vê eleição/failover, que é um dos aspectos
  mais interessantes de estudar no SeaweedFS.
- **2 volume servers em "racks" diferentes** — dá pra testar as regras
  de replicação do SeaweedFS (`-replication` tipo `001`, `010`, etc.),
  que decidem *onde* uma réplica pode ir com base em rack/DC. Com um só
  volume server isso não existe.
- **filer + S3 embutidos em swfs-vol1** — não precisa de VM dedicada
  para começar; dá pra estudar o filer (namespace tipo POSIX sobre o
  SeaweedFS) e a API S3 sem custo extra de máquina.

Cada VM do cluster tem 2 discos, como pedido: `${OS_DISK_SIZE}` de
sistema e `${DATA_DISK_SIZE}` de dados. O cloud-init já formata (ext4)
e monta o disco de dados em `/data` (dono: usuário `swfs`) no primeiro
boot — é esse `/data` que você aponta em `-mdir`/`-dir` ao rodar
`weed master`/`weed volume`.

## Organização de diretórios

```
SeaweedFS/
├── Imagens/                      # cloud images BASE, compartilhadas
│   ├── noble-server-cloudimg-amd64.img
│   └── FreeBSD-15.1-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2
├── swfs-master1/                 # estado de CADA VM: disco overlay
│   ├── swfs-master1-os.qcow2     # (backing file = imagem em Imagens/),
│   ├── swfs-master1-data.qcow2   # seed cloud-init e afins
│   └── swfs-master1-seed.iso
├── swfs-vol1/ swfs-vol2/ swfs-master2/ swfs-master3/ swfs-router/  # idem
├── cluster_key / cluster_key.pub # chave SSH exclusiva do cluster
├── 00-config.env ... 07-destruir-lab.sh
└── README.md
```

Regra para organizar isso no futuro, se você adicionar mais VMs/tipos
de imagem ao lab: **imagens-base (cloud images, ISOs) sempre em
`Imagens/`**, nunca soltas na raiz — são arquivos grandes e reutilizados
como backing file por várias VMs. **Estado por VM (discos overlay,
seed.iso, logs) sempre em uma pasta com o nome da própria VM**, criada
e destruída junto com ela. A raiz do projeto (`SeaweedFS/`) fica só com
os scripts, o `README.md`, o `00-config.env` e a chave do cluster.

## Rede isolada + roteador

A rede `seaweedfs-lab` é só um switch L2 isolado (sem `<ip>`/`<dhcp>`
no libvirt — sem NAT, sem servidor DHCP, e **sem IP do próprio host**
nela). Por isso os IPs das 5 VMs Ubuntu são **estáticos**, já embutidos
via cloud-init (netplan) — não tem DHCP para gerenciar, foi mantido
simples de propósito.

Quem dá saída para a internet a essa rede é a VM `swfs-router`, com
duas interfaces, ambas configuradas via cloud-init:
- **WAN**: rede `default` do KVM (NAT), IP fixo `192.168.122.150`
  (reservado por MAC em `03-configurar-rede.sh`).
- **LAN**: rede isolada `seaweedfs-lab`, IP fixo `192.168.100.1`.

IP forwarding e a regra de NAT (MASQUERADE, via `iptables` + um
serviço systemd habilitado no boot) já saem prontos no cloud-init do
roteador — nenhum passo manual necessário. Ao final do
`./deploy-lab.sh`, as 5 VMs já têm internet e já se enxergam entre si.

O host consegue SSH em qualquer VM do lab pulando pelo roteador (ele
tem uma perna em cada rede — o host não tem rota direta para
`192.168.100.0/24`):
```bash
ssh swfs@192.168.122.150                          # o roteador direto
ssh -J swfs@192.168.122.150 swfs@192.168.100.11    # qualquer VM do lab
```
(dica: um bloco de `~/.ssh/config` deixa isso transparente — veja
"Acesso SSH" abaixo.)

## Notas técnicas (bugs encontrados e corrigidos)

Duas coisas quebraram silenciosamente durante os testes e vale
registrar, porque não eram óbvias:

1. **A imagem oficial "CLOUDINIT" do FreeBSD não usa o cloud-init da
   Canonical** — usa uma ferramenta própria do FreeBSD chamada
   `nuageinit` (pacote `FreeBSD-nuageinit`). Ela lê o mesmo formato de
   seed (`user-data`/`meta-data`, cidata) e o `man nuageinit` documenta
   suporte a `write_files`/`runcmd`/`packages`, mas na prática (versão
   testada: FreeBSD 15.1) essas três diretivas não aplicaram — só
   `users`/`chpasswd`/`hostname` funcionaram. Foi por isso que o
   roteador virou Ubuntu: reaproveita o cloud-init já validado nas
   outras 5 VMs, sem essa incerteza.

2. **No cloud-init de verdade (Ubuntu), `write_files` roda ANTES do
   módulo `users-groups`.** Isso quebrou a distribuição da chave
   privada do cluster: os arquivos eram escritos em
   `/home/swfs/.ssh/...`, mas o usuário `swfs` (e portanto seu
   `$HOME`) ainda não existia nesse estágio — a gravação falhava com
   uma exceção não tratada, derrubando o `write_files` inteiro (por
   isso `/etc/hosts` também não era populado). A correção foi marcar
   essas entradas com `defer: true` (suportado desde cloud-init ~23.x,
   Ubuntu 24.04 já tem), que adia a escrita para depois da criação dos
   usuários. Veja o comentário no `04-gerar-cloud-init.sh` onde isso é
   usado.

Ambos os problemas foram confirmados ao vivo (SSH nas VMs, `journalctl`,
logs do cloud-init) antes de mexer nos scripts — o lab atual já reflete
as correções.

## Requisitos mínimos

**Testado em:** host Ubuntu 26.04 LTS, AMD Ryzen 5 2600 (6 núcleos/12
threads), 30 GB RAM, libvirt 12.0.0, qemu-img 10.2.1, cloud-init
26.1 — VMs guest em Ubuntu Server 24.04 LTS (cloud image "noble").

**Mínimo recomendado para rodar as 6 VMs simultaneamente:**

| Recurso | Mínimo | Por quê |
|---|---|---|
| CPU | 8 threads, com virtualização (Intel VT-x / AMD-V) exposta ao host | 5 VMs × 2 vCPU + roteador × 1 vCPU = 11 vCPU alocados (com overcommit; 8 threads físicas já rodam bem) |
| RAM | 16 GB (32 GB confortável) | 5 × 2 GB + roteador × 1 GB = 11 GB só de VMs; o host e o cache do KVM precisam de sobra |
| Disco | ~150 GB livres | 5 × (16 GB SO + 10 GB dados) + 10 GB do roteador + imagem-base (~600 MB) |
| KVM | `/dev/kvm` presente | confirme com `kvm-ok` (pacote `cpu-checker`) ou `ls /dev/kvm` |

Se o host tiver menos RAM/CPU, dá pra reduzir `VM_RAM_MB`/`VM_VCPUS` em
`00-config.env` — o cluster sobe com menos recursos, só fica mais lento
sob carga (não afeta o aprendizado da topologia/raft/replicação).

## Pré-requisitos

```bash
sudo apt update
sudo apt install -y virtinst libvirt-clients libvirt-daemon-system \
                     qemu-utils cloud-image-utils wget xz-utils
```

(no seu host já há `virt-install`, `qemu-img`, `xorriso` e `xz`; se não
tiver `cloud-image-utils`, o script cai para `genisoimage`.)

## Deploy — um único comando

```bash
chmod +x *.sh
./deploy-lab.sh
```

Ele roda, na ordem:

1. `01-baixar-imagem.sh` — baixa a cloud image Ubuntu 24.04 para
   `Imagens/` (uma vez; usada pelas 5 VMs e pelo roteador)
2. `02-criar-discos.sh` — disco de SO + disco de dados por VM do
   cluster, e o disco de SO do roteador (mesma imagem-base)
3. `03-configurar-rede.sh` — cria a rede isolada `seaweedfs-lab` e
   reserva o IP WAN fixo do roteador na rede `default`
4. `04-gerar-cloud-init.sh` — gera a chave do cluster + seed.iso (IP
   estático) de cada VM Ubuntu e do roteador (com NAT/forwarding já
   configurados); nas 5 VMs do cluster, o cloud-init também já baixa o
   binário `weed` e formata/monta o disco de dados em `/data` (veja
   "Requisitos mínimos" e `SEAWEED_VERSION` em `00-config.env`)
5. `05-criar-vms.sh` — sobe as 5 VMs do cluster + a VM do roteador,
   todas já provisionadas
6. `06-status.sh` — mostra estado/IP de todas as VMs, e um relatório
   de status do SeaweedFS por VM (binário instalado, disco montado,
   portas ativas de master/volume/filer/S3/admin)

Ao final, o lab já está com internet e SSH funcionando — nenhum passo
manual de infraestrutura pendente.

## Scripts individuais

Os passos continuam existindo soltos (`01` a `07`) caso queira rodar
de novo só uma etapa específica:

```bash
./01-baixar-imagem.sh
./02-criar-discos.sh
./03-configurar-rede.sh
./04-gerar-cloud-init.sh
./05-criar-vms.sh
./06-status.sh
./07-destruir-lab.sh
```

Todos são idempotentes: se um disco, VM ou rede já existe, o script
pula e avisa em vez de falhar.

## Acesso SSH

Direto ao roteador:
```bash
ssh swfs@192.168.122.150
```

Às VMs do lab, via ProxyJump pelo roteador:
```bash
ssh -J swfs@192.168.122.150 swfs@192.168.100.11   # swfs-master1
```

Para não digitar `-J` toda hora, um bloco assim no `~/.ssh/config` do
seu HOST (arquivo seu, os scripts não mexem nele) deixa transparente:
```
Host swfs-router
    HostName 192.168.122.150
    User swfs

Host swfs-master1 swfs-master2 swfs-master3 swfs-vol1 swfs-vol2
    ProxyJump swfs-router
    User swfs

Host swfs-master1
    HostName 192.168.100.11
Host swfs-master2
    HostName 192.168.100.12
Host swfs-master3
    HostName 192.168.100.13
Host swfs-vol1
    HostName 192.168.100.21
Host swfs-vol2
    HostName 192.168.100.22
```
Depois disso: `ssh swfs-master1` já funciona direto.

Senha de todos os usuários (`swfs`): `swfs123` (ou sua chave SSH,
adicionada automaticamente).

## Destruir

```bash
./07-destruir-lab.sh                 # remove as 6 VMs e seus discos
./07-destruir-lab.sh --clean-net      # + remove a rede isolada seaweedfs-lab
                                       #   e a reserva de IP WAN do roteador
./07-destruir-lab.sh --purge           # + remove as imagens em Imagens/ e a chave do cluster
```

A rede `default` do KVM (usada como WAN do roteador) **nunca** é
destruída — só a reserva de IP que este lab adicionou nela.

## Próximos passos (instalação manual do SeaweedFS)

O `./deploy-lab.sh` já deixa pronto, via cloud-init, nas 5 VMs do
cluster: o binário `weed` instalado em `/usr/local/bin` e o disco de
dados formatado, montado em `/data` e com dono certo (`swfs`). Confira
com `./06-status.sh` (mostra `BINARIO`/`DISCO` de cada VM). **O único
passo manual que resta — de propósito, para você aprender a topologia
antes de automatizar — é subir os processos do SeaweedFS**, um em cada
VM (recomendado: `tmux`/`screen`, ou `nohup ... &`, senão o processo
morre ao fechar a sessão SSH — veja "Pontos de atenção" abaixo):

```bash
# nos 3 masters (rodar em cada um, IP e -peers apontando para os 3):
weed master -mdir=/data -ip=192.168.100.11 \
  -peers=192.168.100.11:9333,192.168.100.12:9333,192.168.100.13:9333
  # (troque -ip para .12 e .13 nos outros dois masters)

# em swfs-vol1 (rack1) e swfs-vol2 (rack2):
weed volume -dir=/data -mserver=192.168.100.11:9333,192.168.100.12:9333,192.168.100.13:9333 \
  -ip=192.168.100.21 -dataCenter=dc1 -rack=rack1   # (rack2 e -ip=.22 na outra VM)

# filer + S3, só em swfs-vol1 (-defaultStoreDir evita gravar o metastore
# num caminho relativo ao diretório onde você rodou o comando, veja
# "Pontos de atenção"):
weed filer -master=192.168.100.11:9333,192.168.100.12:9333,192.168.100.13:9333 -s3 \
  -defaultStoreDir=/data

# painel admin (opcional, qualquer VM com o binário — ex: swfs-vol1):
weed admin -port=23646 -masters=192.168.100.11:9333,192.168.100.12:9333,192.168.100.13:9333
```

Depois de subir tudo, confirme com `./06-status.sh` (relatório de
portas ativas por VM) ou manualmente:
```bash
curl -s http://192.168.100.11:9333/cluster/status | jq .   # cluster raft
curl -s http://192.168.100.21:8888/                          # filer UI
curl -s http://192.168.100.21:8333/                          # S3 API
```
Do seu HOST, isso só funciona se você tiver adicionado a rota para a
rede isolada (veja "Pontos de atenção" abaixo) — senão rode o `curl`
de dentro de uma VM via SSH.

Quando quiser automatizar esses comandos também (systemd units, config
por role, etc.), me chama.

## Pontos de atenção (erros comuns na instalação manual)

Registro dos erros que apareceram testando o passo a passo acima, para
quem for repetir o lab não perder tempo com o mesmo problema:

1. **`curl ... --output` sem nome de arquivo** — `--output`/`-o` exige
   um argumento (`--output weed.tar.gz`). Sem o binário pré-instalado
   pelo cloud-init isso nem é mais necessário, mas fica registrado.

2. **`permission denied` ao rodar `weed master/volume/filer`** — se
   você formatou o disco de dados manualmente (`mkfs.ext4` + `mount`),
   o diretório raiz do filesystem nasce com dono `root:root`. O
   processo `weed` roda como usuário `swfs` e precisa de:
   ```bash
   sudo chown -R swfs:swfs /data
   ```
   O cloud-init atual já faz isso sozinho no primeiro boot (formata,
   monta e ajusta o dono) — só é relevante se você reformatar o disco
   na mão.

3. **`bind: cannot assign requested address` no `weed master`** —
   confira em qual VM você está antes de rodar o comando com `-ip=`
   fixo (`hostname` ou `ip -4 addr show`). Esse erro geralmente é
   sintoma de estar numa VM diferente da que você pretendia (ex:
   comando com `-ip=192.168.100.11` rodado dentro da `swfs-vol1`).

4. **`weed filer` falha com `stat ./filerldb2: no such file or
   directory`** — sem um `filer.toml`, o filer grava seu metastore
   (LevelDB) num caminho **relativo ao diretório onde o comando foi
   executado**. Se você estiver em `/` (comum logo após o SSH), o
   usuário `swfs` não tem permissão de criar pastas ali. Sempre passe
   `-defaultStoreDir=/data` explicitamente (ou dê `cd /data` antes).

5. **Testar uma porta de serviço na VM errada** — `9333` (master) só
   existe nos 3 masters; `8080` (volume), `8888` (filer) e `8333` (S3)
   só existem em `swfs-vol1`/`swfs-vol2`. "Não carrega nada" nessas
   portas na VM errada é esperado, não é bug. Tabela de referência:

   | Porta | Serviço | Onde roda |
   |---|---|---|
   | 9333 | master (API + raft) | swfs-master1/2/3 |
   | 8080 | volume server | swfs-vol1, swfs-vol2 |
   | 8888 | filer (UI + API, navegador de arquivos em `/buckets/`) | swfs-vol1 |
   | 8333 | S3 API (sem GUI própria — use um cliente S3 pra navegar) | swfs-vol1 |
   | 23646 | `weed admin` (painel web, mais próximo do dashboard do Ceph) | onde você rodar o comando |

6. **Host não alcança `192.168.100.0/24` (rede isolada) direto** — por
   desenho (veja "Rede isolada + roteador" acima), o host só tem rota
   pra rede `default` do KVM (`192.168.122.0/24`), não pra LAN isolada
   do lab. O roteador já tem `ip_forward=1` e nenhuma regra bloqueando
   `FORWARD`, então basta adicionar uma rota estática no HOST (não nas
   VMs — o gateway delas já é o roteador):
   ```bash
   sudo ip route add 192.168.100.0/24 via 192.168.122.150
   ```
   Pra persistir entre reboots do host, um serviço systemd oneshot
   (`After=libvirtd.service`) com esse `ip route add`/`del` no
   `ExecStart`/`ExecStop` — mesmo padrão do `swfs-nat.service` do
   roteador. Sem essa rota, `curl`/navegador no host não vai enxergar
   nenhuma VM do lab (funciona normalmente de dentro de qualquer VM via
   SSH, já que elas se enxergam entre si).

7. **Processo `weed` morre ao fechar a sessão SSH** — ele roda em
   foreground. Use `tmux`/`screen`, ou `nohup weed ... > /tmp/weed.log
   2>&1 &` seguido de `disown`, senão fechar o terminal mata o serviço.

## Reconfigurar

Tudo centralizado em `00-config.env`: nomes/IP/MAC das VMs e do
roteador, RAM/vCPU, tamanho dos discos, usuário/senha, chave SSH do
host, URLs das imagens-base e diretórios (`LAB_DIR`, `IMAGES_DIR`), e a
pré-instalação do SeaweedFS (`SEAWEED_VERSION` — "latest" ou uma tag
fixa, `DATA_DISK_DEVICE`, `DATA_MOUNT_DIR`).
