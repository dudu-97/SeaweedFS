#!/usr/bin/env bash
# =====================================================================
# 10-mapa-discos.sh — descobre "quem é" cada volume server do SeaweedFS:
#   porta (ex.: 8083)  ->  /dev/sdX dentro da VM  ->  disco no KVM
# Serve pra tirar o disco certo em teste de falha.
#
# Só lê (virsh dumpxml + SSH na VM); nada é alterado.
#
# Uso:
#   ./10-mapa-discos.sh                       # todos os volume nodes
#   ./10-mapa-discos.sh swfs-node01           # 1 node
#   ./10-mapa-discos.sh 192.168.100.51:8083   # 1 volume server (IP:porta)
#   ./10-mapa-discos.sh swfs-node01:8083      # idem, pelo nome da VM
# Com IP:porta (ou VM:porta) mostra também os comandos virsh pra
# remover (simular falha) e recolocar o disco, e salva o XML do disco.
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-config.env"

ARG="${1:-}"
TARGET_VMS=("${VOLUME_NODES[@]}")
ONLY_DISK=""

if [[ -n "$ARG" ]]; then
    HOST_PART="${ARG%%:*}"
    PORT_PART=""
    [[ "$ARG" == *:* ]] && PORT_PART="${ARG##*:}"

    VM_FOUND=""
    for v in "${VOLUME_NODES[@]}"; do
        if [[ "$v" == "$HOST_PART" || "${VM_IP[$v]}" == "$HOST_PART" ]]; then VM_FOUND="$v"; fi
    done
    [[ -n "$VM_FOUND" ]] || { echo "'$HOST_PART' não é um volume node (${VOLUME_NODES[*]})."; exit 1; }
    TARGET_VMS=("$VM_FOUND")

    if [[ -n "$PORT_PART" ]]; then
        ONLY_DISK=$((PORT_PART - SEAWEED_VOLUME_BASE_PORT))
        if (( ONLY_DISK < 0 || ONLY_DISK >= VOLUME_DISKS_PER_NODE )); then
            echo "Porta $PORT_PART fora do intervalo dos volume servers ($SEAWEED_VOLUME_BASE_PORT-$((SEAWEED_VOLUME_BASE_PORT + VOLUME_DISKS_PER_NODE - 1)))."
            exit 1
        fi
    fi
fi

JUMP="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6 -o BatchMode=yes -W %h:%p ${VM_USER}@${ROUTER_WAN_IP}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6 -o BatchMode=yes -o LogLevel=ERROR -o "ProxyCommand=$JUMP")

# Roda na VM: pra cada diskN, quem está montado em /data/diskN e o endereço SCSI.
REMOTE_CMD='for n in $(seq 0 '"$((VOLUME_DISKS_PER_NODE - 1))"'); do
  mp='"${DATA_MOUNT_DIR}"'/disk$n; src=$(findmnt -n -o SOURCE "$mp" 2>/dev/null || true)
  label=""; serial=""; addr=""
  if [ -n "$src" ]; then
    b=$(basename "$src")
    label=$(lsblk -dno LABEL "$src" 2>/dev/null || true)
    serial=$(lsblk -dno SERIAL "$src" 2>/dev/null || true)
    addr=$(basename "$(readlink -f /sys/block/$b/device 2>/dev/null)" 2>/dev/null || true)
  fi
  echo "$n|$mp|$src|$label|$serial|$addr"
done'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for vm in "${TARGET_VMS[@]}"; do
    ip="${VM_IP[$vm]}"
    : > "$TMP/guest.txt"
    GUEST_OK=1
    ssh -n "${SSH_OPTS[@]}" "${VM_USER}@${ip}" "$REMOTE_CMD" > "$TMP/guest.txt" 2>/dev/null || GUEST_OK=0

    if ! virsh dumpxml "$vm" > "$TMP/dom.xml" 2>/dev/null; then
        echo "== $vm: não achei a VM no libvirt =="; continue
    fi

    python3 - "$vm" "$ip" "$TMP/dom.xml" "$TMP/guest.txt" "$GUEST_OK" "$ONLY_DISK" \
        "$SEAWEED_VOLUME_BASE_PORT" "$VOLUME_DISKS_PER_NODE" "$DISK_CONTROLLER" "$DISK_BACKPLANE" "$LAB_DIR" <<'PY'
import sys, os
import xml.etree.ElementTree as ET

(vm, ip, xml_path, guest_path, guest_ok, only, base, ndisks, ctrl, bp, lab_dir) = sys.argv[1:12]
base, ndisks = int(base), int(ndisks)
only = int(only) if only != "" else None

kvm = {}
for disk in ET.parse(xml_path).getroot().findall("./devices/disk"):
    addr, tgt = disk.find("address"), disk.find("target")
    if disk.get("device") != "disk" or addr is None or tgt is None:
        continue
    if addr.get("type") != "drive" or tgt.get("bus") != "scsi":
        continue
    src = disk.find("source")
    clean = ET.fromstring(ET.tostring(disk))
    for a in clean.findall("alias"):
        clean.remove(a)
    kvm[int(addr.get("target"))] = dict(
        dev=tgt.get("dev"),
        serial=disk.findtext("serial") or "",
        file=src.get("file") if src is not None else "?",
        xml=ET.tostring(clean, encoding="unicode"),
    )

guest = {}
for line in open(guest_path):
    p = line.rstrip("\n").split("|")
    if len(p) == 6 and p[0].isdigit():
        guest[int(p[0])] = dict(mp=p[1], dev=p[2], label=p[3], serial=p[4], addr=p[5])

print(f"\n== {vm} ({ip}) ==")
if not kvm:
    print("  Nenhum disco SCSI com endereço fixo no libvirt — VM criada antes do 05-criar-vms.sh novo?")
    sys.exit(0)
if guest_ok != "1":
    print("  (SSH na VM falhou: colunas '/dev na VM', LABEL e SCSI ficam vazias; só o lado KVM é mostrado)")

def check(n):
    k, g = kvm.get(n), guest.get(n)
    if not k or not g or not g["dev"]:
        return "?"
    if g["serial"]:
        return "OK" if g["serial"] == k["serial"] else "DIVERGE"
    t = g["addr"].split(":")[2] if g["addr"].count(":") == 3 else ""
    return "OK" if t == str(n) else "DIVERGE"

rows = [n for n in range(ndisks) if only is None or n == only]
if only is None:
    print(f"  {'PORTA':<6} {'POS':<6} {'/dev na VM':<11} {'LABEL':<15} {'SCSI VM':<9} {'KVM alvo':<9} {'serial KVM':<19} {'ok':<8} qcow2")
    for n in rows:
        k, g = kvm.get(n), guest.get(n, {})
        print(f"  {base+n:<6} {ctrl}:{bp}:{n:<3} {g.get('dev','') or '-':<11} {g.get('label','') or '-':<15} "
              f"{g.get('addr','') or '-':<9} {k['dev'] if k else '-':<9} {k['serial'] if k else '-':<19} {check(n):<8} "
              f"{os.path.basename(k['file']) if k else '-'}")
    print(f"\n  Pra um disco específico (com comandos de remover/recolocar): ./10-mapa-discos.sh {vm}:<porta>")
else:
    n = only
    k, g = kvm.get(n), guest.get(n, {})
    if not k:
        print(f"  Disco {n} não existe no libvirt."); sys.exit(1)
    print(f"  Volume server {ip}:{base+n}  (disco {ctrl}:{bp}:{n})")
    print(f"    Na VM  : {g.get('dev') or '?'}  LABEL={g.get('label') or '?'}  montado em {g.get('mp','?')}  SCSI {g.get('addr') or '?'}")
    print(f"    No KVM : VM {vm}, disco alvo '{k['dev']}', serial {k['serial']}")
    print(f"             arquivo {k['file']}")
    print(f"    Conferência guest x KVM: {check(n)}")
    xml_file = os.path.join(lab_dir, vm, f"disco{n}.xml")
    try:
        open(xml_file, "w").write(k["xml"] + "\n")
        saved = True
    except OSError:
        saved = False
    print("\n  Simular falha (tira o disco a quente; só na VM rodando — um reboot/destroy+start traz de volta):")
    print(f"    virsh detach-disk {vm} {k['dev']} --live")
    print("  Recolocar o disco (mesmo endereço SCSI):")
    print(f"    virsh attach-device {vm} {xml_file} --live" + ("" if saved else "   # (não consegui salvar o XML)"))
PY
done
