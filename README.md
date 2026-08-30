# Lab SeaweedFS — KVM/libvirt + cloud-init + roteador automatizado

Lab de aprendizado para SeaweedFS: 5 VMs Ubuntu 24.04 (3 masters em
quorum Raft + 2 volume servers, um deles com filer/S3 embutido) numa
rede **isolada** do KVM, atrás de uma **VM roteadora** (mesma imagem
Ubuntu das demais) com IP forwarding + NAT já automatizados via
cloud-init — zero passo manual de infraestrutura.

A instalação do próprio SeaweedFS é manual (de propósito, para você
aprender antes de automatizar) — esse é o único passo manual do lab;
todo o resto (VMs, discos, rede, SSH, NAT/internet) já sobe pronto com
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
sistema e `${DATA_DISK_SIZE}` de dados (use o disco de dados, ex.
`/dev/vdb`, como diretório de dados do `weed volume`/`weed master`).

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
   configurados)
5. `05-criar-vms.sh` — sobe as 5 VMs do cluster + a VM do roteador,
   todas já provisionadas
6. `06-status.sh` — mostra estado/IP de todas as VMs

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

Depois que o roteador estiver roteando e as 5 VMs tiverem internet, a
instalação manual do SeaweedFS (fora do escopo destes scripts, de
propósito) é basicamente:

```bash
# em cada uma das 5 VMs
curl -L https://github.com/seaweedfs/seaweedfs/releases/latest/download/linux_amd64_large_disk.tar.gz \
  | sudo tar -xz -C /usr/local/bin weed
sudo mkfs.ext4 /dev/vdb && sudo mkdir -p /data && sudo mount /dev/vdb /data

# nos 3 masters (rodar em cada um, apontando os --peers para os 3):
weed master -mdir=/data -ip=<meu-ip> \
  -peers=192.168.100.11:9333,192.168.100.12:9333,192.168.100.13:9333

# em swfs-vol1 (rack1) e swfs-vol2 (rack2):
weed volume -dir=/data -mserver=192.168.100.11:9333,192.168.100.12:9333,192.168.100.13:9333 \
  -ip=<meu-ip> -dataCenter=dc1 -rack=rack1   # (rack2 na outra VM)

# filer + S3, só em swfs-vol1:
weed filer -master=192.168.100.11:9333,192.168.100.12:9333,192.168.100.13:9333 -s3
```

Quando quiser automatizar isso depois (systemd units, config por
role, etc.), me chama.

## Reconfigurar

Tudo centralizado em `00-config.env`: nomes/IP/MAC das VMs e do
roteador, RAM/vCPU, tamanho dos discos, usuário/senha, chave SSH do
host, URLs das imagens-base e diretórios (`LAB_DIR`, `IMAGES_DIR`).
