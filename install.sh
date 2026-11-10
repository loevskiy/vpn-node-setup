#!/usr/bin/env bash
# =============================================================================
# vpn-node-setup / install.sh
#
# RU: Подготовка VPN-ноды (Remnawave remnanode + Xray: VLESS/Reality/XHTTP, Docker,
#     обычно network_mode: host) на Ubuntu 24.04. Один самодостаточный файл.
#     Двухфазная схема без риска потерять доступ:
#       1) install.sh --pubkey "..." ...         — всё настраивает, порт 22 ОСТАЁТСЯ открыт
#       2) проверьте вход: ssh -p <SSH_PORT> root@<IP> из второго окна
#       3) install.sh --pubkey "..." --finalize  — закрывает 22 и перезагружает
#     Тюнинг ядра/сети пересчитывается при КАЖДОЙ загрузке (vpn-node-tune.service)
#     по реальным CPU / RAM / скорости канала — после ресайза VM ничего делать не надо.
# EN: Lockout-safe two-phase VPN node bootstrap for Ubuntu 24.04. Kernel/network
#     tuning is recomputed from detected CPU/RAM/link speed at every boot.
#
# curl -fsSL https://raw.githubusercontent.com/loevskiy/vpn-node-setup/main/install.sh \
#   | sudo bash -s -- --pubkey "ssh-ed25519 AAAA... me" --ssh-port 49222 --vpn-ports 443 \
#       --panel-ip 203.0.113.10 --ipv6 2001:db8::1/64 --ipv6-gw fe80::1
# ... then, after testing login on the new port:
# curl -fsSL .../install.sh | sudo bash -s -- --pubkey "ssh-ed25519 AAAA... me" --ssh-port 49222 --finalize
#
# Flags (env fallback in brackets):
#   --pubkey KEY          [PUBKEY]        required: your SSH public key
#   --ssh-port N          [SSH_PORT]      default 49222
#   --vpn-ports LIST      [VPN_PORTS]     default "443"; comma list, each opened tcp+udp;
#                                         "8443/tcp" or "4443/udp" for one protocol
#   --node-port N         [NODE_PORT]     remnanode API port, default 2222
#   --panel-ip LIST       [PANEL_IP]      comma list of panel IPs allowed to NODE_PORT
#                                         (empty = NODE_PORT stays closed)
#   --ipv6 ADDR/PFX       [IPV6_ADDR]     optional static IPv6
#   --ipv6-gw GW          [IPV6_GW]       optional; fe80::/10 gateways get on-link
#   --ipv6-if IF          [IPV6_IF]       optional; default = IPv4 default-route NIC
#   --link-mbit N         [LINK_MBIT]     link speed if ethtool can't tell (default 1000)
#   --forwarding          [FORWARDING=1]  enable ip_forward (WireGuard-style setups)
#   --conntrack-skip      [CONNTRACK_SKIP=1] NOTRACK inbound VPN_PORTS (saves conntrack)
#   --dev-tools           [DEV_TOOLS=1]   also install build-essential, git, Node.js 24
#   --tz ZONE             [TZ]            default UTC
#   --finalize            [FINALIZE=1]    phase 2: close port 22 and reboot
#   --print-tuning        print computed tuning and exit (no changes);
#       --fake-cpus N --fake-mem-mb N     simulate other hardware with --print-tuning
# Idempotent. Contains no secrets.
# =============================================================================
set -euo pipefail

SSH_PORT=${SSH_PORT:-49222}; VPN_PORTS=${VPN_PORTS:-443}; NODE_PORT=${NODE_PORT:-2222}
PANEL_IP=${PANEL_IP:-}; IPV6_ADDR=${IPV6_ADDR:-}; IPV6_GW=${IPV6_GW:-}; IPV6_IF=${IPV6_IF:-}
LINK_MBIT=${LINK_MBIT:-}; FORWARDING=${FORWARDING:-0}; CONNTRACK_SKIP=${CONNTRACK_SKIP:-0}
DEV_TOOLS=${DEV_TOOLS:-0}; TZ_SET=${TZ:-UTC}; FINALIZE=${FINALIZE:-0}; PUBKEY=${PUBKEY:-}
PRINT_TUNING=0; FAKE_CPUS=""; FAKE_MEM_MB=""

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "== $*"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --pubkey) PUBKEY=$2; shift 2;;          --ssh-port) SSH_PORT=$2; shift 2;;
    --vpn-ports) VPN_PORTS=$2; shift 2;;    --node-port) NODE_PORT=$2; shift 2;;
    --panel-ip) PANEL_IP=$2; shift 2;;      --ipv6) IPV6_ADDR=$2; shift 2;;
    --ipv6-gw) IPV6_GW=$2; shift 2;;        --ipv6-if) IPV6_IF=$2; shift 2;;
    --link-mbit) LINK_MBIT=$2; shift 2;;    --tz) TZ_SET=$2; shift 2;;
    --forwarding) FORWARDING=1; shift;;     --conntrack-skip) CONNTRACK_SKIP=1; shift;;
    --dev-tools) DEV_TOOLS=1; shift;;       --finalize) FINALIZE=1; shift;;
    --print-tuning) PRINT_TUNING=1; shift;;
    --fake-cpus) FAKE_CPUS=$2; shift 2;;    --fake-mem-mb) FAKE_MEM_MB=$2; shift 2;;
    -h|--help) [ -f "$0" ] && head -c 2 "$0" | grep -q '#!' && sed -n '2,45p' "$0" || echo 'Flags: see README.md (https://github.com/loevskiy/vpn-node-setup)'; exit 0;;
    *) die "unknown flag: $1";;
  esac
done

# ---------------------------------------------------------------------------
# Boot-time tuner (written to /usr/local/sbin/vpn-node-tune, run every boot)
# ---------------------------------------------------------------------------
tune_script(){ cat <<'TUNE'
#!/usr/bin/env bash
# vpn-node-tune: recompute kernel/NIC tuning from current hardware. Args: [--dry-run]
set -uo pipefail
[ -f /etc/default/vpn-node-tune ] && . /etc/default/vpn-node-tune
DRY=0; [ "${1:-}" = --dry-run ] && DRY=1
clamp(){ local v=$1 lo=$2 hi=$3; [ "$v" -lt "$lo" ] && v=$lo; [ "$v" -gt "$hi" ] && v=$hi; echo "$v"; }
pow2(){ local v=$1 p=1; while [ $p -lt "$v" ]; do p=$((p*2)); done; echo $p; }
CPUS=${FAKE_CPUS:-$(nproc)}
MEM_MB=${FAKE_MEM_MB:-$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))}
MEM_B=$((MEM_MB*1024*1024)); PAGES=$((MEM_B/4096)); MEM_GB=$(( (MEM_MB+512)/1024 )); [ $MEM_GB -lt 1 ] && MEM_GB=1
IF=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
SPEED=""
if [ -z "${FAKE_CPUS:-}" ] && [ -n "$IF" ] && command -v ethtool >/dev/null; then
  SPEED=$(ethtool "$IF" 2>/dev/null | awk -F': ' '/Speed:/{gsub(/[^0-9]/,"",$2); print $2}')
fi
[[ "$SPEED" =~ ^[0-9]+$ ]] && [ "$SPEED" -gt 0 ] && [ "$SPEED" -lt 1000000 ] || SPEED=${LINK_MBIT:-1000}
SPEED=$(clamp "$SPEED" 100 100000)

# socket buffer max = BDP (speed x 200 ms) capped by RAM/32, floor 4 MB, cap 256 MB
BDP=$((SPEED*25000))
BUF=$(clamp "$BDP" 4194304 268435456); CAP=$((MEM_B/32)); [ $CAP -lt 4194304 ] && CAP=4194304; [ $BUF -gt $CAP ] && BUF=$CAP
DEF=$(clamp $((BUF/32)) 212992 2097152)            # rmem/wmem_default (UDP/QUIC sockets)
TCPMEM="$((PAGES*6/100)) $((PAGES*12/100)) $((PAGES*20/100))"
UDPMEM="$((PAGES*4/100)) $((PAGES*8/100)) $((PAGES*12/100))"
CT_MAX=$(clamp $((MEM_GB*65536)) 65536 4194304); CT_HASH=$(pow2 $((CT_MAX/4)))
BACKLOG=$(clamp $((SPEED*25)) 16384 262144)
BUDGET=$(clamp $((300 + SPEED/20 + CPUS*10)) 300 1200); BUDGET_US=$([ "$SPEED" -ge 10000 ] && echo 8000 || echo 4000)
SOMAX=$(clamp $((CPUS*4096)) 4096 65535)
FILEMAX=$(clamp $((MEM_MB*256)) 262144 16777216); NOFILE=1048576; NR_OPEN=$(( FILEMAX>NOFILE ? FILEMAX : NOFILE ))
MINFREE=$(clamp $((MEM_MB*1024*15/1000)) 16384 262144)
TWB=$(clamp $((MEM_MB*128)) 65536 2097152); ORPH=$(clamp $((MEM_MB*16)) 16384 262144)
RPSFLOW=$(clamp $((CPUS*8192)) 32768 1048576)
if   [ "$MEM_MB" -le 2560 ]; then ZRAM="ram / 2"
elif [ "$MEM_MB" -le 8704 ]; then ZRAM="ram / 4"
else ZRAM="off"; fi

SYSCTL="# generated by vpn-node-tune at boot: cpus=$CPUS mem=${MEM_MB}MB link=${SPEED}Mbit
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=$BUF
net.core.wmem_max=$BUF
net.core.rmem_default=$DEF
net.core.wmem_default=$DEF
net.core.optmem_max=65536
net.ipv4.tcp_rmem=4096 131072 $BUF
net.ipv4.tcp_wmem=4096 65536 $BUF
net.ipv4.tcp_mem=$TCPMEM
net.ipv4.udp_mem=$UDPMEM
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_max_tw_buckets=$TWB
net.ipv4.tcp_max_orphans=$ORPH
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.ip_local_port_range=1024 65535
net.core.somaxconn=$SOMAX
net.ipv4.tcp_max_syn_backlog=$SOMAX
net.core.netdev_max_backlog=$BACKLOG
net.core.netdev_budget=$BUDGET
net.core.netdev_budget_usecs=$BUDGET_US
net.core.rps_sock_flow_entries=$RPSFLOW
net.netfilter.nf_conntrack_max=$CT_MAX
net.netfilter.nf_conntrack_tcp_timeout_established=3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait=15
net.netfilter.nf_conntrack_tcp_timeout_close_wait=15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait=30
net.netfilter.nf_conntrack_udp_timeout=30
net.netfilter.nf_conntrack_udp_timeout_stream=120
fs.file-max=$FILEMAX
fs.nr_open=$NR_OPEN
vm.min_free_kbytes=$MINFREE
vm.swappiness=10
net.ipv4.ip_forward=${FORWARDING:-0}
net.ipv6.conf.all.forwarding=${FORWARDING:-0}
net.ipv4.conf.all.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
kernel.kptr_restrict=2
kernel.dmesg_restrict=1"

if [ $DRY = 1 ]; then
  printf 'cpus=%s mem=%sMB link=%sMbit | buf_max=%sMB default=%sKB tcp_mem(pages)=%s udp_mem=%s | conntrack_max=%s hash=%s | backlog=%s budget=%s/%sus somaxconn=%s | file-max=%s nofile=%s min_free=%sKB tw_buckets=%s orphans=%s rps_flow=%s zram=%s\n' \
    "$CPUS" "$MEM_MB" "$SPEED" $((BUF/1048576)) $((DEF/1024)) "$TCPMEM" "$UDPMEM" "$CT_MAX" "$CT_HASH" "$BACKLOG" "$BUDGET" "$BUDGET_US" "$SOMAX" "$FILEMAX" "$NOFILE" "$MINFREE" "$TWB" "$ORPH" "$RPSFLOW" "$ZRAM"
  exit 0
fi

modprobe tcp_bbr 2>/dev/null; modprobe nf_conntrack 2>/dev/null
[ -w /sys/module/nf_conntrack/parameters/hashsize ] && echo "$CT_HASH" > /sys/module/nf_conntrack/parameters/hashsize
echo "options nf_conntrack hashsize=$CT_HASH" > /etc/modprobe.d/vpn-node-conntrack.conf
echo "$SYSCTL" > /etc/sysctl.d/90-vpn-node.conf
sysctl -q -p /etc/sysctl.d/90-vpn-node.conf 2>&1 | grep -v '^$' || true
printf '* soft nofile %s\n* hard nofile %s\nroot soft nofile %s\nroot hard nofile %s\n' $NOFILE $NOFILE $NOFILE $NOFILE > /etc/security/limits.d/90-vpn-node.conf
if [ "$ZRAM" = off ]; then rm -f /etc/systemd/zram-generator.conf
else printf '[zram0]\nzram-size = %s\ncompression-algorithm = zstd\n' "$ZRAM" > /etc/systemd/zram-generator.conf; fi

# CPU governor (only if hypervisor exposes cpufreq)
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -w "$g" ] && echo performance > "$g" 2>/dev/null; done
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true

# NIC: rings to max, offloads, txqueuelen, RPS/RFS/XPS over all cores
mask_for(){ # $1 = cpu index or "all"; prints comma-separated 32-bit hex groups
  local n=$CPUS groups=$(( (CPUS+31)/32 )) out="" g bits
  for ((g=groups-1; g>=0; g--)); do
    if [ "$1" = all ]; then bits=$(( n-g*32 >= 32 ? 0xffffffff : (1<<(n-g*32))-1 ))
    else bits=$(( $1/32 == g ? 1<<($1%32) : 0 )); fi
    out+=$(printf '%08x' $bits); [ $g -gt 0 ] && out+=","
  done; echo "$out"; }
for dev in /sys/class/net/*; do
  d=${dev##*/}
  case "$d" in lo|docker*|veth*|br-*|virbr*|wg*|tun*|tap*) continue;; esac
  [ -e "$dev/device" ] || continue
  if command -v ethtool >/dev/null; then
    read -r RXM TXM < <(ethtool -g "$d" 2>/dev/null | awk '/Pre-set maximums/{m=1} /Current hardware/{m=0} m&&/^RX:/{r=$2} m&&/^TX:/{t=$2} END{print r+0, t+0}')
    [ "${RXM:-0}" -gt 0 ] && ethtool -G "$d" rx "$RXM" 2>/dev/null
    [ "${TXM:-0}" -gt 0 ] && ethtool -G "$d" tx "$TXM" 2>/dev/null
    ethtool -K "$d" gro on gso on tso on 2>/dev/null
  fi
  ip link set "$d" txqueuelen 10000 2>/dev/null
  RXQ=$(ls -d "$dev"/queues/rx-* 2>/dev/null | wc -l); [ "$RXQ" -lt 1 ] && RXQ=1
  if [ "$CPUS" -gt 1 ]; then
    for q in "$dev"/queues/rx-*; do
      echo "$(mask_for all)" > "$q/rps_cpus" 2>/dev/null
      echo $((RPSFLOW/RXQ)) > "$q/rps_flow_cnt" 2>/dev/null
    done
    i=0; for q in "$dev"/queues/tx-*; do echo "$(mask_for $((i % CPUS)))" > "$q/xps_cpus" 2>/dev/null; i=$((i+1)); done
  fi
done
echo "vpn-node-tune: cpus=$CPUS mem=${MEM_MB}MB link=${SPEED}Mbit buf_max=$BUF conntrack_max=$CT_MAX zram=$ZRAM"
exit 0
TUNE
}

if [ "$PRINT_TUNING" = 1 ]; then
  T=$(mktemp); tune_script > "$T"
  FAKE_CPUS=$FAKE_CPUS FAKE_MEM_MB=$FAKE_MEM_MB LINK_MBIT=$LINK_MBIT FORWARDING=$FORWARDING bash "$T" --dry-run; rm -f "$T"; exit 0
fi

# ---------------------------------------------------------------------------
[ "$(id -u)" = 0 ] || die "run as root (sudo)"
[ -n "$PUBKEY" ] || die "--pubkey is required (your own SSH public key)"
[[ "$PUBKEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9-]+|sk-[a-z0-9@.-]+)\ [A-Za-z0-9+/=]+ ]] || die "--pubkey does not look like an SSH public key"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] || die "bad --ssh-port"
[[ "$NODE_PORT" =~ ^[0-9]+$ ]] || die "bad --node-port"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
SSHD_DROPIN=/etc/ssh/sshd_config.d/00-vpn-node.conf

if [ "$FINALIZE" = 1 ]; then
  [ -f "$SSHD_DROPIN" ] || die "phase 1 not done yet"
  [ "$SSH_PORT" != 22 ] || die "SSH port is 22: nothing to close"
  ss -tln | grep -q ":${SSH_PORT}\b" || die "sshd not listening on ${SSH_PORT}; refusing to close 22"
  grep -qxF "$PUBKEY" /root/.ssh/authorized_keys || die "this --pubkey is not in root authorized_keys; refusing"
  log "Phase 2: closing port 22 and rebooting"
  sed -i '/^Port 22$/d' "$SSHD_DROPIN"; sshd -t; systemctl restart ssh.service
  ufw delete allow 22/tcp >/dev/null 2>&1 || true
  sed -i "s/^port = .*/port = ${SSH_PORT}/" /etc/fail2ban/jail.d/sshd.local; systemctl restart fail2ban
  ufw status verbose
  echo "Rebooting. Reconnect with: ssh -p ${SSH_PORT} root@<server-ip>"; sleep 2; systemctl reboot; exit 0
fi

log "1. SSH key"
install -d -m700 /root/.ssh
grep -qxF "$PUBKEY" /root/.ssh/authorized_keys 2>/dev/null || echo "$PUBKEY" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

log "2. full upgrade + HWE kernel + base tools"
apt-get update -q
apt-get -yq -o Dpkg::Options::=--force-confold full-upgrade
apt-get -yq -o Dpkg::Options::=--force-confold install linux-generic-hwe-24.04 ufw fail2ban python3-systemd \
  unattended-upgrades chrony curl ca-certificates gnupg ethtool irqbalance jq htop tmux zstd needrestart
if [ "$DEV_TOOLS" = 1 ]; then
  apt-get -yq install build-essential git rsync python3
  node -v 2>/dev/null | grep -q '^v24' || { curl -fsSL https://deb.nodesource.com/setup_24.x | bash -; apt-get -yq install nodejs; }
fi

log "3. snap: remove snaps (before stopping snapd), purge, block"
if command -v snap >/dev/null; then for sn in $(timeout 60 snap list 2>/dev/null | awk 'NR>1{print $1}' | tac); do timeout 300 snap remove --purge "$sn" || true; done; fi
for s in snapd.service snapd.socket snapd.seeded.service ModemManager.service multipathd.service multipathd.socket udisks2.service \
         apport.service motd-news.timer cups.service avahi-daemon.service bluetooth.service; do systemctl disable --now "$s" 2>/dev/null || true; done
apt-get -yq purge snapd apport popularity-contest packagekit 2>/dev/null || true
rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd /root/snap
printf 'Package: snapd\nPin: release a=*\nPin-Priority: -10\n' > /etc/apt/preferences.d/no-snap.pref

log "4. Docker CE from download.docker.com (Ubuntu docker.io purged)"
if ! dpkg -s docker-ce >/dev/null 2>&1; then
  systemctl stop docker.service docker.socket containerd.service 2>/dev/null || true
  apt-get -yq purge docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc \
    python3-docker python3-compose python3-dockerpty 2>/dev/null || true
  rm -rf /var/lib/docker /var/lib/containerd /etc/docker; ip link delete docker0 2>/dev/null || true
fi
rm -f /etc/apt/sources.list.d/docker*.list
install -d -m0755 /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nSigned-By: /etc/apt/keyrings/docker.asc\n' \
  "${UBUNTU_CODENAME:-$VERSION_CODENAME}" > /etc/apt/sources.list.d/docker.sources
printf 'Package: docker.io docker-compose docker-compose-v2 podman-docker containerd runc\nPin: release o=Ubuntu\nPin-Priority: -10\n' > /etc/apt/preferences.d/no-ubuntu-docker.pref
apt-get update -q
apt-get -yq install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
install -d /etc/docker
# No global "ip": "127.0.0.1" here: remnanode uses network_mode: host, so ufw rules apply to it directly.
# NOTE: ports PUBLISHED from bridge-mode containers (-p) bypass ufw — don't publish anything you don't want public.
cat > /etc/docker/daemon.json <<'CFG'
{ "log-driver": "local", "log-opts": {"max-size": "20m", "max-file": "3"}, "live-restore": true,
  "default-ulimits": {"nofile": {"Name": "nofile", "Soft": 1048576, "Hard": 1048576}} }
CFG
systemctl enable containerd docker >/dev/null 2>&1; systemctl restart docker

log "5. sshd: keys only, port ${SSH_PORT} (22 stays open until --finalize)"
rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf
sed -i -E 's/^(PasswordAuthentication|PermitRootLogin|X11Forwarding)\b/#&/' /etc/ssh/sshd_config
P22="Port 22"; [ -f "$SSHD_DROPIN" ] && ! grep -qx 'Port 22' "$SSHD_DROPIN" && P22=""
[ "$SSH_PORT" = 22 ] && P22=""
cat > "$SSHD_DROPIN" <<CFG
${P22}
Port ${SSH_PORT}
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
AllowAgentForwarding no
ClientAliveInterval 60
CFG
# Ubuntu 24.04 socket activation ignores Port in sshd_config -> plain ssh.service
systemctl disable --now ssh.socket 2>/dev/null || true
rm -f /etc/systemd/system/ssh.service.d/00-socket.conf; systemctl daemon-reload
sshd -t; systemctl enable ssh.service >/dev/null 2>&1; systemctl restart ssh.service
if [ -d /etc/cloud ]; then install -d /etc/cloud/cloud.cfg.d; printf 'ssh_pwauth: false\ndisable_root: false\n' > /etc/cloud/cloud.cfg.d/99-vpn-node.cfg; fi

log "6. ufw: deny inbound except SSH, VPN ports, node API from panel only"
sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
ufw --force reset >/dev/null
ufw default deny incoming; ufw default allow outgoing
[ "$FORWARDING" = 1 ] && { sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw; }
[ -n "$P22" ] && ufw allow 22/tcp
ufw allow "${SSH_PORT}/tcp"
IFS=',' read -ra VP <<< "$VPN_PORTS"; TRACK_PORTS=()
for p in "${VP[@]}"; do p=${p// /}; [ -z "$p" ] && continue
  case "$p" in */tcp|*/udp) ufw allow "$p"; TRACK_PORTS+=("$p");; *) ufw allow "${p}/tcp"; ufw allow "${p}/udp"; TRACK_PORTS+=("${p}/tcp" "${p}/udp");; esac
done
if [ -n "$PANEL_IP" ]; then IFS=',' read -ra PIPS <<< "$PANEL_IP"
  for ip in "${PIPS[@]}"; do ip=${ip// /}; [ -n "$ip" ] && ufw allow from "$ip" to any port "$NODE_PORT" proto tcp; done
else echo "WARN: --panel-ip not set: node API port ${NODE_PORT} stays CLOSED (panel can't reach the node)"; fi
# optional NOTRACK for inbound VPN traffic (raw table via ufw before.rules / before6.rules)
for f in /etc/ufw/before.rules /etc/ufw/before6.rules; do
  sed -i '/^# BEGIN vpn-node-notrack/,/^# END vpn-node-notrack/d' "$f"
  if [ "$CONNTRACK_SKIP" = 1 ]; then
    { echo "# BEGIN vpn-node-notrack"; echo "*raw"; echo ":PREROUTING ACCEPT [0:0]"; echo ":OUTPUT ACCEPT [0:0]"
      for tp in "${TRACK_PORTS[@]}"; do echo "-A PREROUTING -p ${tp#*/} --dport ${tp%/*} -j NOTRACK"; echo "-A OUTPUT -p ${tp#*/} --sport ${tp%/*} -j NOTRACK"; done
      echo "COMMIT"; echo "# END vpn-node-notrack"; } > "$f.new"; cat "$f" >> "$f.new"; mv "$f.new" "$f"; chmod 640 "$f"
  fi
done
ufw --force enable
printf '[sshd]\nenabled = true\nbackend = systemd\nport = %s\nmaxretry = 4\nbantime = 1h\njournalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd\n' "$( [ -n "$P22" ] && echo "22,${SSH_PORT}" || echo "${SSH_PORT}")" > /etc/fail2ban/jail.d/sshd.local
systemctl enable fail2ban >/dev/null 2>&1; systemctl restart fail2ban

log "7. boot-time auto-tuning service"
apt-get -yq install systemd-zram-generator 2>/dev/null || true
tune_script > /usr/local/sbin/vpn-node-tune; chmod 755 /usr/local/sbin/vpn-node-tune
printf 'LINK_MBIT=%s\nFORWARDING=%s\n' "${LINK_MBIT}" "${FORWARDING}" > /etc/default/vpn-node-tune
cat > /etc/systemd/system/vpn-node-tune.service <<'CFG'
[Unit]
Description=Recompute VPN node kernel/NIC tuning from current hardware
After=network-online.target
Wants=network-online.target
Before=docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpn-node-tune
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
CFG
echo tcp_bbr > /etc/modules-load.d/vpn-node.conf; echo nf_conntrack >> /etc/modules-load.d/vpn-node.conf
install -d /etc/systemd/system.conf.d; printf '[Manager]\nDefaultLimitNOFILE=1048576\n' > /etc/systemd/system.conf.d/90-vpn-node.conf
systemctl daemon-reload; systemctl enable vpn-node-tune.service >/dev/null 2>&1; systemctl restart vpn-node-tune.service || true
systemctl enable --now irqbalance fstrim.timer 2>/dev/null || true
install -d /etc/systemd/journald.conf.d; printf '[Journal]\nSystemMaxUse=500M\nMaxRetentionSec=14day\n' > /etc/systemd/journald.conf.d/90-vpn-node.conf
systemctl restart systemd-journald
echo 'Unattended-Upgrade::Automatic-Reboot "false";' > /etc/apt/apt.conf.d/52vpn-node-noreboot
timedatectl set-timezone "$TZ_SET" || true
apt-get -yq autoremove --purge

if [ -n "$IPV6_ADDR" ]; then
  log "8. IPv6 ${IPV6_ADDR}"
  [[ "$IPV6_ADDR" == */* ]] || IPV6_ADDR="${IPV6_ADDR}/64"
  IF=${IPV6_IF:-$(ip -4 route show default | awk '{print $5; exit}')}; [ -n "$IF" ] || die "can't detect NIC; use --ipv6-if"
  if ! ip -6 addr show dev "$IF" scope global | grep -qF "${IPV6_ADDR%%/*}/"; then
    { echo "network:"; echo "  version: 2"; echo "  ethernets:"; echo "    ${IF}:"; echo "      addresses: [\"${IPV6_ADDR}\"]"
      if [ -n "$IPV6_GW" ]; then echo "      routes:"; echo "        - to: \"::/0\""; echo "          via: \"${IPV6_GW}\""; [[ "$IPV6_GW" == fe80* ]] && echo "          on-link: true"; fi; true; } > /etc/netplan/60-vpn-node-ipv6.yaml
    chmod 600 /etc/netplan/*.yaml
    netplan generate
    V4=$(ip -4 -o addr show dev "$IF" scope global | awk '{print $4; exit}')
    if ! grep -rqF "$V4" /run/systemd/network/ || ! grep -rqF "$IPV6_ADDR" /run/systemd/network/; then
      rm -f /etc/netplan/60-vpn-node-ipv6.yaml; netplan generate; die "netplan merge lost IPv4/IPv6; IPv6 file removed, nothing applied"
    fi
    netplan apply
  fi
fi

echo; log "Computed tuning:"; /usr/local/sbin/vpn-node-tune --dry-run
cat <<MSG

==========================================================================
 ФАЗА 1 ГОТОВА / PHASE 1 DONE
 Сейчас проверьте вход на новом порту из ВТОРОГО окна (это не закрывайте):
 Now test login on the new port from a SECOND terminal (keep this one open):
     ssh -p ${SSH_PORT} root@<server-ip>
 Только если вход удался / Only if it worked:
     ... install.sh --pubkey "<same key>" --ssh-port ${SSH_PORT} --finalize
 (закроет порт 22 и перезагрузит в новое ядро / closes 22, reboots into new kernel)
==========================================================================
MSG
