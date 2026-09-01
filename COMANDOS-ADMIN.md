# Comandos de administração — SSH e SeaweedFS

Referência rápida de comandos usados no dia a dia deste lab: acesso SSH às
VMs e inspeção do cluster SeaweedFS (Master, Volume, Filer) direto de
dentro de cada VM. Ver `README.md` para a arquitetura completa e
`00-config.env` para as portas/IPs usados abaixo.

## Acesso SSH ao lab

O `~/.ssh/config` do host já define os aliases (`swfs-router`,
`swfs-master1/2/3`, `swfs-vol1/2`) com `ProxyJump swfs-router` — ou seja,
`ssh swfs-vol1` faz **dois** saltos SSH em sequência: primeiro o roteador
(`192.168.122.150`, a única perna do lab alcançável a partir do host),
depois a VM final na rede isolada (`192.168.100.0/24`).

### "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED" após um redeploy

Isso é esperado, não é um ataque: as chaves de host SSH de cada VM são
geradas pelo cloud-init no primeiro boot, então qualquer VM recriada
(disco novo ou seed de cloud-init novo) sobe com uma chave diferente da
que o seu `known_hosts` tinha guardado. Como o acesso passa por dois
saltos, às vezes o erro aparece **duas vezes seguidas** (uma para o
roteador, outra para a VM final) — se limpar só a primeira, a segunda
ainda vai barrar a conexão.

Depois de todo redeploy (`./deploy-lab.sh` ou recriação manual de
qualquer VM), rode isto uma vez no host para limpar as 6 entradas do lab
de uma vez (`known_hosts` usa `HashKnownHosts`, então não dá pra
editar/grepar o arquivo à mão — tem que ser via `ssh-keygen -R`):

```bash
for ip in 192.168.122.150 192.168.100.11 192.168.100.12 192.168.100.13 192.168.100.21 192.168.100.22; do
  ssh-keygen -f ~/.ssh/known_hosts -R "$ip"
done
```

Depois disso, o primeiro `ssh swfs-<vm>` volta a pedir para confirmar a
fingerprint (normal em host novo) — responda `yes` e segue o jogo.

> Alternativa mais cômoda (não aplicada ainda): adicionar
> `StrictHostKeyChecking no` + `UserKnownHostsFile /dev/null` aos blocos
> `Host swfs-router` e `Host swfs-master1 ... swfs-vol2` do
> `~/.ssh/config` — é o mesmo esquema que o `deploy-lab.sh` já usa
> internamente para checar se o roteador subiu. Faz sentido aqui porque
> são VMs efêmeras numa rede isolada só sua, sem risco real de MITM. Fica
> de fora por enquanto por ser uma mudança de segurança do `~/.ssh/config`
> do host, não do repositório do lab.

## `weed shell` — ponto de entrada único para inspecionar o cluster

O binário `weed` já está instalado em `/usr/local/bin/weed` em todas as 5
VMs do cluster (via cloud-init). De qualquer uma delas dá pra abrir um
shell interativo apontando para qualquer master — ele descobre o líder
Raft sozinho:

```bash
weed shell -master=192.168.100.11:9333
```

Comandos mais úteis dentro do shell para **analisar o ambiente** (sem
alterar nada):

| Comando | Para que serve |
|---|---|
| `cluster.status` | visão geral rápida do cluster |
| `cluster.ps` | status dos processos (masters/volumes/filers) conectados |
| `cluster.raft.ps` | status do quorum Raft — quem é líder, quem são os peers |
| `volume.list` | lista todos os volumes do cluster: id, servidor, tamanho usado/máximo, replicação, coleção |
| `collection.list` | lista as coleções (namespaces de buckets/volumes) existentes |
| `fs.ls /caminho` | lista arquivos/diretórios no Filer (namespace do S3 também aparece aqui) |
| `fs.du /caminho` | uso de disco de um caminho no Filer |
| `fs.meta.cat /caminho/arquivo` | metadados brutos de um arquivo no Filer |

Comandos que alteram estado (não usar só para inspecionar, mas bom saber
que existem): `volume.vacuum`, `volume.balance`, `volume.fix.replication`,
`volume.check.disk`, `volume.fsck` — todos exigem `lock` antes e `unlock`
depois no shell.

## Master (rodar via SSH em `swfs-master1`, `swfs-master2` ou `swfs-master3`, porta 9333)

```bash
systemctl status weed-master          # está rodando?
journalctl -u weed-master -f          # logs em tempo real (útil pra ver eleição Raft)

curl -s "http://localhost:9333/cluster/status?pretty=y"   # líder Raft + peers
curl -sI "http://localhost:9333/cluster/healthz"          # 200 = saudável
curl -s "http://localhost:9333/dir/status?pretty=y"       # topologia: datacenters/racks/volume servers
curl -s "http://localhost:9333/vol/status?pretty=y"       # todos os volumes, tamanho/replicação
curl -s "http://localhost:9333/dir/lookup?volumeId=1&pretty=y"  # em quais volume servers está o volume 1
```

A própria UI web do master (`http://192.168.100.11:9333/` — abrir do
host, ou via túnel) mostra a mesma topologia de forma visual.

## Volume (rodar via SSH em `swfs-vol1` ou `swfs-vol2`, porta 8080)

```bash
systemctl status weed-volume
journalctl -u weed-volume -f

curl -sI "http://localhost:8080/healthz"           # 200 = saudável
curl -s "http://localhost:8080/status?pretty=y"    # volumes hospedados nesse servidor, contagem de arquivos, deletados

df -h /data                                         # espaço em disco real (camada do SO, não do weed)
```

## Filer + S3 (rodam só em `swfs-vol1`, portas 8888 e 8333)

```bash
systemctl status weed-filer
journalctl -u weed-filer -f

curl -H "Accept: application/json" "http://localhost:8888/buckets/?pretty=y"   # listar buckets (S3) via Filer
curl -s "http://localhost:8888/caminho/?metadata=true&pretty=y"                # metadados de um diretório/arquivo

# S3 (usa as credenciais de S3_ACCESS_KEY/S3_SECRET_KEY do 00-config.env)
aws --endpoint-url http://localhost:8333 s3 ls
```

Dashboard admin (`weed admin`, visual, topologia + volumes + métricas):
`http://192.168.100.21:23646/` — mesma VM do filer/S3.

## Referência de portas (de `00-config.env`)

| Serviço | Porta | VM(s) |
|---|---|---|
| Master (Raft + HTTP API) | 9333 | swfs-master1/2/3 |
| Volume (HTTP API) | 8080 | swfs-vol1, swfs-vol2 |
| Filer (HTTP API) | 8888 | swfs-vol1 |
| S3 (API compatível) | 8333 | swfs-vol1 |
| Admin dashboard (web) | 23646 | swfs-vol1 |
