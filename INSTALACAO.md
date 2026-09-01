# Guia de instalação — para quem está clonando este lab pela primeira vez

Este guia é o caminho rápido: acesso ao repositório → clone → dependências
→ subir o lab. Para entender a arquitetura (o quê e o porquê de cada VM)
veja o `README.md`; para comandos de administração do cluster depois que
ele já estiver de pé, veja `COMANDOS-ADMIN.md`.

## 0. Requisitos antes de começar

- **Linux no host** (não roda em Windows/Mac — depende de KVM/libvirt).
  Testado em Ubuntu; qualquer distro com libvirt deve funcionar.
- **Virtualização habilitada na BIOS/UEFI** (Intel VT-x / AMD-V).
- **~11 GB de RAM livre** e **~141 GB de disco livre** para as 6 VMs
  (uso real inicial é bem menor — os discos são thin-provisioned; veja
  `README.md` > Requisitos para o detalhamento).
- Conta no GitHub, **adicionada como colaborador** no repositório
  privado `dudu-97/SeaweedFS` (peça para o Eduardo te convidar antes do
  próximo passo — sem isso o `git clone` dá 404/permissão negada).

## 1. Clonar o repositório

Confirme que a virtualização está disponível antes de gastar tempo com o resto:
```bash
kvm-ok || ls /dev/kvm
```
Se der erro, precisa habilitar VT-x/AMD-V na BIOS antes de continuar.

Clone via HTTPS (vai pedir seu usuário/senha do GitHub — use um
[Personal Access Token](https://github.com/settings/tokens) no lugar da
senha, o GitHub não aceita mais senha pura):
```bash
git clone https://github.com/dudu-97/SeaweedFS.git
cd SeaweedFS
```

Se preferir SSH (precisa ter uma chave SSH sua cadastrada no GitHub em
Settings → SSH and GPG keys):
```bash
git clone git@github.com:dudu-97/SeaweedFS.git
cd SeaweedFS
```

## 2. Instalar as dependências no host

```bash
sudo apt update
sudo apt install -y virtinst libvirt-clients libvirt-daemon-system \
                     qemu-utils cloud-image-utils wget xz-utils virt-manager
```

`virt-manager` é a ferramenta gráfica (Virtual Machine Manager) — não é
usada pelos scripts do lab, que são 100% via `virsh`/linha de comando,
mas vale instalar para abrir o **console gráfico** de qualquer VM (como
se fosse um monitor conectado nela), o que é útil pra debugar algo que
trava antes do SSH subir, ou só para bisbilhotar o boot. Depois de
instalado, é só abrir "Virtual Machine Manager" no menu de aplicativos,
ou `virt-manager` no terminal — as 6 VMs do lab aparecem lá assim que
`./deploy-lab.sh` as cria.

**Precisa reiniciar o computador depois de instalar esses pacotes? Não.**
A instalação sobe o serviço `libvirtd` sozinha e carrega os módulos de
kernel do KVM (`kvm_intel`/`kvm_amd`) automaticamente — nenhum reboot é
necessário só por causa do `apt install`. As duas únicas coisas que
*podem* pedir alguma ação depois de instalar:
- **Grupos `libvirt`/`kvm`**: se você rodou o `usermod -aG` abaixo, o
  Linux só aplica o novo grupo em sessões novas — basta **fazer
  logout/login** (não precisa reiniciar a máquina inteira; um reboot
  também resolve, mas é mais do que o necessário).
- **Virtualização desabilitada na BIOS/UEFI**: se o `kvm-ok` do passo 1
  falhou, aí sim é preciso reiniciar — mas para entrar na BIOS e habilitar
  VT-x/AMD-V, não por causa dos pacotes em si.

Seu usuário precisa conseguir falar com o libvirt sem `sudo` toda vez —
confirme que está nos grupos certos:
```bash
groups | grep -E "libvirt|kvm"
sudo usermod -aG libvirt,kvm "$USER"   # só se o comando acima não mostrou os dois grupos, depois faça logout/login
```

## 3. Subir o lab

Um comando só sobe as 6 VMs (roteador + 3 masters + 2 volumes), a rede
isolada e o cluster SeaweedFS já rodando dentro delas:
```bash
chmod +x *.sh
./deploy-lab.sh
```

Isso baixa a cloud image do Ubuntu na primeira vez (~600 MB), cria os
discos, a rede, e as VMs. No meio do processo ele pergunta o **modelo de
replicação padrão** do cluster — pode dar Enter e seguir com o padrão
(`000`, sem cópia extra) se for sua primeira vez explorando o lab. Leva
alguns minutos até o cluster inteiro responder.

## 4. Conferir se subiu certo

```bash
./06-status.sh
```
Espera-se `HTTP 200` / `UP` em todos os serviços (master ×3, volume ×2,
filer, S3, admin, demo de upload). Se algo aparecer diferente, rode de
novo depois de 1–2 min — pode ser só o cloud-init ainda instalando o
`weed` na VM.

## 5. Acessar as VMs

Adicione ao seu `~/.ssh/config` (facilita muito o dia a dia — sem isso,
todo `ssh` precisa do `-o ProxyCommand=...` pulando pelo roteador, veja
`README.md` > Acesso SSH):
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
Depois disso, `ssh swfs-vol1` (por exemplo) já funciona direto. Senha
padrão do usuário `swfs` em qualquer VM: `swfs123`.

Na primeira conexão o SSH vai pedir para confirmar a fingerprint de cada
VM (normal, é a primeira vez que seu host fala com ela) — responda `yes`.
Se você recriar o lab depois (`./07-destruir-lab.sh` + `./deploy-lab.sh`
de novo) e o SSH reclamar de "host key changed", isso é esperado — veja
o fix em `COMANDOS-ADMIN.md`.

## 6. Próximos passos

- `README.md` — arquitetura completa, conceitos do SeaweedFS (Master,
  Volume, Filer, replicação) e como testar a API S3.
- `COMANDOS-ADMIN.md` — comandos para inspecionar o cluster (`weed
  shell`, endpoints HTTP de cada serviço) e troubleshooting de SSH.
- `./07-destruir-lab.sh` quando terminar — derruba as 6 VMs (veja as
  variantes `--clean-net`/`--purge` no README para limpar mais a fundo).
