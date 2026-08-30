# Lab SeaweedFS — KVM/libvirt + cloud-init

Ambiente de laboratório para estudo do [SeaweedFS](https://github.com/seaweedfs/seaweedfs), completamente automatizado com KVM/libvirt e cloud-init: um comando sobe a topologia inteira — máquinas, rede, roteamento e o cluster SeaweedFS já rodando — e outro comando desmonta tudo.

## Objetivo do projeto

Oferecer um ambiente descartável e 100% reproduzível para aprender a arquitetura distribuída do SeaweedFS na prática: eleição de líder via Raft, replicação de dados por rack/datacenter, o papel do Filer e a API S3. Nenhum passo de infraestrutura é manual — da VM em branco ao cluster respondendo HTTP 200 é tudo `./deploy-lab.sh`. O foco fica inteiramente na experimentação (derrubar um master e observar o failover, testar políticas de replicação, usar a API S3) em vez de tarefas repetitivas de setup.

## Arquitetura

Seis máquinas virtuais Ubuntu Server 24.04, divididas em dois grupos:

```
                         rede "default" (NAT do KVM, já existente)
                                    │
                              [ swfs-router ]  <- NAT/forwarding automático
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

| VM             | Papel                                     | IP                                          |
|----------------|--------------------------------------------|----------------------------------------------|
| swfs-router    | Roteador (gateway/NAT do lab, automático)   | 192.168.122.150 (WAN) / 192.168.100.1 (LAN) |
| swfs-master1   | `weed master` — nó 1 do quorum Raft          | 192.168.100.11                              |
| swfs-master2   | `weed master` — nó 2 do quorum Raft          | 192.168.100.12                              |
| swfs-master3   | `weed master` — nó 3 do quorum Raft          | 192.168.100.13                              |
| swfs-vol1      | `weed volume` (rack1) + `weed filer` + S3   | 192.168.100.21                              |
| swfs-vol2      | `weed volume` (rack2)                       | 192.168.100.22                              |

A rede `seaweedfs-lab` é um switch L2 isolado no libvirt — sem DHCP, sem NAT, sem rota do host. A única saída para a internet (e a única forma de o host alcançar as 5 VMs) é através do `swfs-router`, que tem uma perna em cada rede e já sai da fábrica com IP forwarding e uma regra de NAT (MASQUERADE) habilitadas via cloud-init.

Por que 3 masters e 2 volumes em vez de uma topologia mínima:
- **3 masters** — o SeaweedFS usa Raft para eleger o master líder. Com um único master não há eleição nem failover para observar, que é um dos comportamentos mais didáticos do sistema.
- **2 volume servers em racks diferentes** — permite testar as regras de replicação do SeaweedFS (`-replication 001`, `010`, etc.), que decidem em qual rack/datacenter uma réplica pode ficar.
- **Filer + S3 embutidos em swfs-vol1** — evita uma VM dedicada só para isso; o Filer (namespace hierárquico) e a API S3 já ficam disponíveis sem custo extra de máquina.

## Requisitos

**Soma dos recursos alocados pela topologia (mínimo para rodar as 6 VMs simultaneamente):**

| Recurso | Mínimo | Composição |
|---|---|---|
| RAM | ~11 GB | 5 VMs × 2 GB + roteador × 1 GB |
| vCPU | 11 | 5 VMs × 2 vCPU + roteador × 1 vCPU (aceita overcommit do KVM) |
| Disco | ~141 GB livres | 5 × (16 GB SO + 10 GB dados) + 10 GB do roteador + ~600 MB da imagem-base |
| Virtualização | `/dev/kvm` presente | confirme com `kvm-ok` (pacote `cpu-checker`) ou `ls /dev/kvm` |

Os discos são thin-provisioned (qcow2 com backing file) — o espaço acima é o teto alocável, não o uso real inicial, que fica bem menor. RAM/vCPU por VM são configuráveis em `00-config.env` (`VM_RAM_MB`, `VM_VCPUS`) para hosts mais modestos, ao custo de desempenho sob carga.

**Ambiente em que este lab foi validado:**

| Item | Valor |
|---|---|
| CPU do host | AMD Ryzen 5 2600 (6 núcleos / 12 threads) |
| SO do host | Ubuntu 26.04 LTS |
| SO das VMs (guest) | Ubuntu Server 24.04 LTS (cloud image "noble") |
| libvirt / qemu-img / cloud-init | 12.0.0 / 10.2.1 / 26.1 |

## Conceitos do SeaweedFS

Uma introdução rápida ao vocabulário usado no restante deste documento:

- **Master** — o cérebro do cluster. Não guarda arquivos: mantém o mapa de qual *volume* está em qual *volume server*, distribui IDs de volume novos e elege um líder entre si via **Raft** (por isso 3 masters aqui, não 1). Fica em `192.168.100.11-13:9333`.
- **Volume / Volume Server** — a unidade real de armazenamento. Um *volume* é um arquivo grande onde o SeaweedFS empacota muitos arquivos pequenos ("needles") lado a lado, evitando o overhead de um filesystem tradicional por arquivo. O *volume server* é o processo que serve um ou mais volumes (`8080`) e informa ao master a qual **rack**/**datacenter** pertence — informação usada nas regras de replicação.
- **Filer** — camada opcional acima dos volumes que adiciona um namespace hierárquico (pastas/arquivos, como um filesystem POSIX) em vez de IDs de arquivo crus. Guarda seus próprios metadados (aqui, em LevelDB local) e expõe uma API HTTP em `8888`.
- **S3 API** — gateway compatível com o protocolo S3 da AWS, embutido no processo do Filer (`-s3`). Permite usar clientes/SDKs S3 comuns (`aws s3`, `mc`, boto3...) apontando para `8333`, sem precisar de um serviço externo.
- **Replicação** — configurada por volume (flag `-replication`, ex. `001`), decide quantas cópias existem e se elas podem ficar no mesmo rack, datacenter, ou obrigatoriamente separadas — é aqui que ter 2 volume servers em racks diferentes se torna útil neste lab.

## Passo a passo

### Pré-requisitos no host

```bash
sudo apt update
sudo apt install -y virtinst libvirt-clients libvirt-daemon-system \
                     qemu-utils cloud-image-utils wget xz-utils
```

### Deploy

```bash
chmod +x *.sh
./deploy-lab.sh
```

O script executa, em sequência:

1. **`01-baixar-imagem.sh`** — baixa a cloud image Ubuntu 24.04 para `Imagens/` (uma vez; reaproveitada pelas 5 VMs e pelo roteador).
2. **`02-criar-discos.sh`** — cria o disco de sistema e o de dados de cada VM do cluster, e o disco do roteador (todos como overlay da mesma imagem-base).
3. **`03-configurar-rede.sh`** — cria a rede isolada `seaweedfs-lab` e reserva o IP fixo do roteador na rede `default`.
4. **`04-gerar-cloud-init.sh`** — gera a chave SSH do cluster e o seed cloud-init de cada VM. Nas 5 VMs do cluster, o cloud-init resultante já inclui: IP estático, disco de dados formatado e montado em `/data`, o binário `weed` baixado, e o(s) serviço(s) systemd do papel da VM (`weed-master`, `weed-volume` e/ou `weed-filer`) habilitados para iniciar no boot.
5. **`05-criar-vms.sh`** — sobe o roteador primeiro (as demais VMs precisam de internet já no primeiro boot) e depois as 5 VMs do cluster.
6. **`06-status.sh`** — mostra o estado de cada VM e faz uma checagem HTTP em cada serviço do SeaweedFS.

Ao final, o cluster já está de pé — nenhum comando `weed` precisa ser digitado manualmente.

### Scripts individuais

Cada etapa também roda isolada, útil para refazer só um pedaço do lab:

```bash
./01-baixar-imagem.sh
./02-criar-discos.sh
./03-configurar-rede.sh
./04-gerar-cloud-init.sh
./05-criar-vms.sh
./06-status.sh
./07-destruir-lab.sh
```

Todos são idempotentes: se um disco, VM ou rede já existe, o script avisa e segue em frente em vez de falhar.

## Serviços e verificação

`./06-status.sh` testa, via SSH, o endpoint HTTP de cada serviço **de dentro da própria VM** (evita depender de rota do host para a rede isolada) e reporta o código de resposta:

| VM(s) | Serviço | Porta | Endpoint checado | Esperado |
|---|---|---|---|---|
| swfs-master1/2/3 | master | 9333 | `/cluster/status` | HTTP 200 |
| swfs-vol1, swfs-vol2 | volume | 8080 | `/status` | HTTP 200 |
| swfs-vol1 | filer | 8888 | `/` | HTTP 200 |
| swfs-vol1 | S3 API | 8333 | `/` (list buckets) | HTTP 200 |
| swfs-vol1 | admin (dashboard web) | 23646 | `/` | HTTP 200 |

Saída esperada logo após o deploy:

```
VM             BINARIO   DISCO     SERVIÇO   PORTA   HTTP   STATUS
swfs-master1   ok        ok        master    9333    200    UP
swfs-master2   ok        ok        master    9333    200    UP
swfs-master3   ok        ok        master    9333    200    UP
swfs-vol1      ok        ok        volume    8080    200    UP
               filer     8888      200       UP
               s3        8333      200       UP
swfs-vol2      ok        ok        volume    8080    200    UP
```

A API S3 não exige credenciais por padrão (nenhum `-s3.config` foi passado) — é o modo esperado para um lab, não para produção. Teste rápido de dentro de qualquer VM do cluster, sem depender de nenhum cliente S3 instalado:

```bash
curl -s http://192.168.100.21:8333/          # XML do ListBuckets (lista vazia no início)
curl -s http://192.168.100.21:8888/          # UI do Filer
```

Para um cliente S3 de verdade (`aws s3`, `mc`, etc.), instale o pacote correspondente na VM e aponte o `--endpoint-url`/alias para `http://192.168.100.21:8333`.

O `weed admin` (dashboard web, `swfs-vol1:23646`) mostra topologia do cluster, volumes, métricas e navegador de arquivos — descobre o filer automaticamente pelos masters, sem configuração adicional. Para abrir no navegador do host, um túnel SSH pelo roteador:
```bash
ssh -L 23646:192.168.100.21:23646 -o ProxyCommand="ssh -W %h:%p swfs@192.168.122.150" swfs@192.168.100.21
```
e depois acesse `http://localhost:23646` no host. Sem `-adminPassword`, a autenticação fica desabilitada — aceitável só para lab.

## Acesso SSH

Direto ao roteador:
```bash
ssh swfs@192.168.122.150
```

Às VMs do lab, pulando pelo roteador (o host não tem rota direta para a rede isolada):
```bash
ssh -o ProxyCommand="ssh -W %h:%p swfs@192.168.122.150" swfs@192.168.100.11
```

Um bloco assim no `~/.ssh/config` do host deixa isso transparente:
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
A partir daí, `ssh swfs-master1` já funciona direto. Senha padrão de todos os usuários (`swfs`): `swfs123` (ou a chave SSH do host, adicionada automaticamente).

## Destruir

```bash
./07-destruir-lab.sh                 # remove as 6 VMs e seus discos
./07-destruir-lab.sh --clean-net      # + remove a rede isolada e a reserva de IP do roteador
./07-destruir-lab.sh --purge           # + remove as imagens em Imagens/ e a chave do cluster
```

A rede `default` do KVM (usada como WAN do roteador) nunca é destruída — só a reserva de IP que este lab adicionou nela.

## Organização de diretórios

```
SeaweedFS/
├── Imagens/                      # cloud images base, compartilhadas
├── swfs-master1/                 # estado de cada VM: disco overlay,
├── swfs-vol1/  swfs-router/ ...  #   disco de dados, seed cloud-init
├── cluster_key / cluster_key.pub # chave SSH exclusiva do cluster
├── 00-config.env ... 07-destruir-lab.sh
└── README.md
```

Regra para extensões futuras: imagens-base sempre em `Imagens/` (arquivos grandes, reaproveitados como backing file); estado de cada VM sempre em uma pasta com o nome dela, criada e destruída junto. A raiz do projeto fica só com scripts, README, config e a chave do cluster.

## Notas técnicas

Dois comportamentos não documentados foram encontrados montando este lab e vale registrar para quem for adaptá-lo:

1. **A imagem oficial "CLOUDINIT" do FreeBSD não usa o cloud-init da Canonical** — usa uma ferramenta própria do FreeBSD chamada `nuageinit`. Ela lê o mesmo formato de seed (`user-data`/`meta-data`, cidata) e documenta suporte a `write_files`/`runcmd`/`packages` no `man nuageinit`, mas na versão testada (FreeBSD 15.1) essas três diretivas não tiveram efeito — só `users`/`chpasswd`/`hostname` funcionaram. Por isso o roteador deste lab usa Ubuntu em vez de FreeBSD.
2. **No cloud-init real (Ubuntu), o módulo `write_files` roda antes do módulo `users-groups`.** Escrever arquivos em `/home/<usuário>/...` sem o `defer: true` falha silenciosamente (o diretório ainda não existe) e derruba o `write_files` inteiro, inclusive entradas não relacionadas no mesmo arquivo. A correção está em `04-gerar-cloud-init.sh`, nas entradas marcadas com `defer: true`.

## Reconfigurar

Tudo está centralizado em `00-config.env`: nomes/IP/MAC das VMs e do roteador, RAM/vCPU, tamanho dos discos, usuário/senha, papéis do SeaweedFS (`FILER_HOST`, `VM_RACK`, portas), versão do SeaweedFS (`SEAWEED_VERSION` — `latest` ou uma tag fixa) e diretórios (`LAB_DIR`, `IMAGES_DIR`).
