#!/usr/bin/env bash
# =============================================================================
#  Labo réseau et sécurité multi-sites — orchestration
#  Usage : sudo ./lab.sh up | test | down | status | shell <noeud>
#
#  Chaque équipement est un network namespace Linux :
#    routeurs  : FRRouting (zebra + ospfd)
#    firewalls : nftables + strongSwan (IPsec IKEv2)
#    switchs   : bridge Linux avec filtrage VLAN 802.1Q (si le noyau le permet)
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${LAB_STATE:-/tmp/netlab}"
NODES=(r-casa r-isp r-rabat fw-casa fw-rabat pc-a srv-a pc-b srv-b sw-casa sw-rabat)

c_ok=$'\e[32m'; c_ko=$'\e[31m'; c_dim=$'\e[2m'; c_b=$'\e[1m'; c_0=$'\e[0m'
log()  { printf '%s==>%s %s\n' "$c_b" "$c_0" "$*"; }
die()  { printf '%sErreur :%s %s\n' "$c_ko" "$c_0" "$*" >&2; exit 1; }
nsx()  { local n=$1; shift; ip netns exec "$n" "$@"; }

need_root() { [[ $EUID -eq 0 ]] || die "lance le labo avec sudo"; }
need_tools() {
  local miss=()
  for t in ip nft tcpdump python3 swanctl /usr/lib/frr/zebra /usr/lib/frr/ospfd /usr/lib/ipsec/charon; do
    command -v "$t" >/dev/null 2>&1 || [[ -x $t ]] || miss+=("$t")
  done
  ((${#miss[@]} == 0)) || die "outils manquants : ${miss[*]} (voir scripts/install.sh)"
}

# Le noyau gère-t-il les bridges VLAN et le 802.1Q ?
vlan_supported() {
  ip netns add vlanprobe 2>/dev/null || true
  local ok=1
  if nsx vlanprobe ip link add br0 type bridge vlan_filtering 1 2>/dev/null \
     && nsx vlanprobe ip link add d0 type dummy 2>/dev/null \
     && nsx vlanprobe ip link add link d0 name d0.10 type vlan id 10 2>/dev/null; then ok=0; fi
  ip netns del vlanprobe 2>/dev/null || true
  return $ok
}

# Le noyau sait-il chiffrer en ESP (CONFIG_INET_ESP) ? Sinon : ESP en espace utilisateur (kernel-libipsec).
esp_kernel_supported() {
  ip netns add espprobe 2>/dev/null || true
  local k; k=0x$(printf '%064d' 0) ok=1
  if nsx espprobe ip xfrm state add src 192.0.2.1 dst 192.0.2.2 proto esp spi 0x100 mode tunnel \
       enc 'cbc(aes)' "$k" auth-trunc 'hmac(sha256)' "$k" 128 2>/dev/null; then ok=0; fi
  ip netns del espprobe 2>/dev/null || true
  return $ok
}

# veth entre deux namespaces : link <ns1> <if1> <ns2> <if2>
link() {
  ip link add "$2" netns "$1" type veth peer name "$4" netns "$3"
  nsx "$1" ip link set "$2" up
  nsx "$3" ip link set "$4" up
}
addr()  { nsx "$1" ip addr add "$3" dev "$2"; }
route() { nsx "$1" ip route add "$2" via "$3"; }
fwd()   { nsx "$1" sysctl -qw net.ipv4.ip_forward=1; }

# ----------------------------------------------------------------------------- topologie
build_topology() {
  log "Création des équipements (namespaces)"
  for n in "${NODES[@]}"; do ip netns add "$n"; nsx "$n" ip link set lo up; done

  log "Backbone : R-CASA — R-ISP — R-RABAT + lien de secours R-CASA — R-RABAT"
  link r-casa eth0 r-isp   eth0; addr r-casa eth0 10.255.0.1/30; addr r-isp   eth0 10.255.0.2/30
  link r-isp  eth1 r-rabat eth0; addr r-isp  eth1 10.255.0.5/30; addr r-rabat eth0 10.255.0.6/30
  link r-casa eth2 r-rabat eth2; addr r-casa eth2 10.255.0.9/30; addr r-rabat eth2 10.255.0.10/30
  addr r-casa lo 1.1.1.1/32; addr r-isp lo 2.2.2.2/32; addr r-isp lo 8.8.8.8/32; addr r-rabat lo 3.3.3.3/32
  for r in r-casa r-isp r-rabat; do fwd "$r"; done

  log "Liens WAN des firewalls"
  link r-casa  eth1 fw-casa  wan; addr r-casa  eth1 198.51.100.1/30; addr fw-casa  wan 198.51.100.2/30
  link r-rabat eth1 fw-rabat wan; addr r-rabat eth1 203.0.113.1/30;  addr fw-rabat wan 203.0.113.2/30
  route fw-casa  default 198.51.100.1
  route fw-rabat default 203.0.113.1
  fwd fw-casa; fwd fw-rabat

  if vlan_supported; then
    VLAN_MODE=8021q
    log "LAN : switchs avec VLAN 802.1Q (trunk vers le firewall, ports d'accès vers les hôtes)"
    site_vlan casa  fw-casa  sw-casa  pc-a srv-a 10.10
    site_vlan rabat fw-rabat sw-rabat pc-b srv-b 10.20
  else
    VLAN_MODE=flat
    log "${c_dim}Noyau sans bridge/802.1Q : LAN en segments séparés (même adressage, mêmes règles)${c_0}"
    site_flat fw-casa  pc-a srv-a 10.10
    site_flat fw-rabat pc-b srv-b 10.20
  fi
  echo "$VLAN_MODE" > "$STATE/vlan_mode"
  if esp_kernel_supported; then echo kernel > "$STATE/esp_mode"
  else echo userspace > "$STATE/esp_mode"
       log "${c_dim}Noyau sans ESP : chiffrement IPsec en espace utilisateur (kernel-libipsec)${c_0}"; fi
}

# Site avec switch VLAN : <site> <fw> <sw> <pc> <srv> <préfixe>
site_vlan() {
  local fw=$2 sw=$3 pc=$4 srv=$5 p=$6
  nsx "$sw" ip link add br0 type bridge vlan_filtering 1
  nsx "$sw" ip link set br0 up
  link "$fw" trunk "$sw" p0
  link "$pc"  eth0 "$sw" p1
  link "$srv" eth0 "$sw" p2
  for port in p0 p1 p2; do nsx "$sw" ip link set "$port" master br0; done
  nsx "$sw" bridge vlan del dev p0 vid 1; nsx "$sw" bridge vlan add dev p0 vid 10; nsx "$sw" bridge vlan add dev p0 vid 20
  nsx "$sw" bridge vlan del dev p1 vid 1; nsx "$sw" bridge vlan add dev p1 vid 10 pvid untagged
  nsx "$sw" bridge vlan del dev p2 vid 1; nsx "$sw" bridge vlan add dev p2 vid 20 pvid untagged
  nsx "$fw" ip link add link trunk name lan10 type vlan id 10
  nsx "$fw" ip link add link trunk name lan20 type vlan id 20
  nsx "$fw" ip link set lan10 up; nsx "$fw" ip link set lan20 up
  hosts "$fw" "$pc" "$srv" "$p"
}

# Site sans VLAN : un segment par réseau
site_flat() {
  local fw=$1 pc=$2 srv=$3 p=$4
  link "$fw" lan10 "$pc"  eth0
  link "$fw" lan20 "$srv" eth0
  hosts "$fw" "$pc" "$srv" "$p"
}

hosts() {
  local fw=$1 pc=$2 srv=$3 p=$4
  addr "$fw" lan10 "$p.10.1/24"; addr "$fw" lan20 "$p.20.1/24"
  addr "$pc" eth0 "$p.10.10/24"; route "$pc" default "$p.10.1"
  addr "$srv" eth0 "$p.20.10/24"; route "$srv" default "$p.20.1"
}

# ----------------------------------------------------------------------------- services
start_frr() {
  local n=$1 d="$STATE/$1"
  mkdir -p "$d"; chmod 777 "$d"
  printf 'hostname %s\n' "$n" > "$d/zebra.conf"
  cp "$ROOT/configs/frr/$n.conf" "$d/ospfd.conf"
  local common=(-d -u frr -g frr -z "$d/zserv.api" --vty_socket "$d")
  nsx "$n" /usr/lib/frr/zebra "${common[@]}" -f "$d/zebra.conf" -i "$d/zebra.pid" --log "file:$d/zebra.log"
  nsx "$n" /usr/lib/frr/ospfd "${common[@]}" -f "$d/ospfd.conf" -i "$d/ospfd.pid" --log "file:$d/ospfd.log"
}

vty() { local n=$1; shift; vtysh --vty_socket "$STATE/$n" -c "$*"; }

start_firewall() {
  local n=$1 d="$STATE/$1" mode; mode=$(cat "$STATE/esp_mode")
  mkdir -p "$d"
  cp "$ROOT/configs/nftables/$n.nft" "$d/fw.nft"
  cp "$ROOT/configs/strongswan/$n.swanctl.conf" "$d/swanctl.conf"
  local plugins="random nonce openssl pem pkcs1 x509 revocation constraints pubkey kernel-netlink socket-default vici updown"
  local routes=no
  if [[ $mode == userspace ]]; then
    # ESP traité par charon via une interface TUN (ipsec0), encapsulé en UDP 4500.
    plugins="${plugins/kernel-netlink/kernel-libipsec kernel-netlink}"; routes=yes
    sed -i -e 's/oifname "wan" ip daddr \$REMOTE_NET rt ipsec exists/oifname "ipsec0" ip daddr $REMOTE_NET/' \
           -e 's/iifname "wan" meta ipsec exists/iifname "ipsec0"/' "$d/fw.nft"
    sed -i 's/^    version = 2$/    version = 2\n    encap = yes/' "$d/swanctl.conf"
  fi
  nsx "$n" nft -f "$d/fw.nft"

  cat > "$d/strongswan.conf" <<EOF
charon {
  # Plugins strictement nécessaires (pas de resolve, bypass-lan ni xfrmi : le labo reste isolé de l'hôte)
  load = $plugins
  install_routes = $routes
  install_virtual_ip = no
  plugins { vici { socket = unix://$d/charon.vici } }
  filelog { lab { path = $d/charon.log
                  default = 1
                  ike = 2
                  time_format = %H:%M:%S } }
}
EOF
  cp "$STATE/psk.conf" "$d/psk.conf"
  # /run privé : chaque firewall a son propre charon (pid, sockets).
  nsx "$n" unshare -m sh -c "mount -t tmpfs tmpfs /run && STRONGSWAN_CONF='$d/strongswan.conf' exec /usr/lib/ipsec/charon" \
    >"$d/charon.out" 2>&1 &
  for _ in $(seq 50); do [[ -S $d/charon.vici ]] && break; sleep 0.1; done
  [[ -S $d/charon.vici ]] || die "charon ne démarre pas sur $n (voir $d/charon.out)"
  STRONGSWAN_CONF="$ROOT/configs/strongswan/swanctl-client.conf" swanctl --load-all --file "$d/swanctl.conf" --uri "unix://$d/charon.vici" >"$d/swanctl-load.log" 2>&1 || die "chargement IPsec impossible sur $n (voir $d/swanctl-load.log)"
  grep -q "loaded 1 of 1 connections\|successfully loaded 1 connections" "$d/swanctl-load.log" || die "connexion IPsec non chargée sur $n (voir $d/swanctl-load.log)"
}

sw() { local n=$1; shift; STRONGSWAN_CONF="$ROOT/configs/strongswan/swanctl-client.conf" swanctl "$@" --uri "unix://$STATE/$n/charon.vici"; }

start_servers() {
  for srv in srv-a srv-b; do
    for port in 22 443 8080; do
      nsx "$srv" python3 -m http.server "$port" --bind 0.0.0.0 >/dev/null 2>&1 &
    done
  done
}

wait_ospf() {
  log "Attente de la convergence OSPF"
  for _ in $(seq 60); do
    if [[ $(vty r-isp "show ip ospf neighbor" | grep -c Full || true) -ge 2 ]] \
       && vty r-casa "show ip route 203.0.113.0/30" | grep -q "via eth0"; then return 0; fi
    sleep 0.5
  done
  die "OSPF n'a pas convergé"
}

# ----------------------------------------------------------------------------- commandes
cmd_up() {
  need_root; need_tools
  [[ -d $STATE ]] && cmd_down >/dev/null 2>&1 || true
  mkdir -p "$STATE"
  build_topology
  log "Routage : FRRouting (OSPF aire 0, authentification MD5)"
  for r in r-casa r-isp r-rabat; do start_frr "$r"; done
  wait_ospf
  log "Firewalls : nftables + IPsec IKEv2 (clé pré-partagée générée pour cette session)"
  printf 'secrets {\n  ike-lab {\n    id-1 = fw-casa.lab\n    id-2 = fw-rabat.lab\n    secret = "%s"\n  }\n}\n' \
    "$(head -c 32 /dev/urandom | base64 | tr -d '\n')" > "$STATE/psk.conf"
  chmod 600 "$STATE/psk.conf"
  start_firewall fw-casa
  start_firewall fw-rabat
  log "Établissement du tunnel"
  sw fw-casa --initiate --child lan-lan --timeout 15 >/dev/null
  start_servers
  log "${c_ok}Labo prêt${c_0} (LAN : $(cat "$STATE/vlan_mode"), ESP : $(cat "$STATE/esp_mode")). Lance : sudo ./lab.sh test"
}

cmd_down() {
  need_root
  for d in "$STATE"/*/; do
    [[ -d $d ]] || continue
    for p in "$d"*.pid; do [[ -f $p ]] && kill "$(cat "$p")" 2>/dev/null || true; done
  done
  for n in "${NODES[@]}"; do
    if ip netns pids "$n" >/dev/null 2>&1; then
      ip netns pids "$n" | xargs -r kill 2>/dev/null || true
      ip netns del "$n" 2>/dev/null || true
    fi
  done
  rm -rf "$STATE"
  log "Labo arrêté"
}

cmd_status() {
  need_root
  echo "${c_b}OSPF (R-ISP)${c_0}";        vty r-isp "show ip ospf neighbor"
  echo "${c_b}Routes OSPF (R-CASA)${c_0}"; vty r-casa "show ip route ospf"
  echo "${c_b}IPsec (FW-CASA)${c_0}";      sw fw-casa --list-sas
}

cmd_shell() {
  need_root; [[ -n ${1:-} ]] || die "usage : ./lab.sh shell <noeud>"
  exec ip netns exec "$1" bash
}

case "${1:-}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  test)   need_root; exec bash "$ROOT/scripts/tests.sh" ;;
  status) cmd_status ;;
  shell)  cmd_shell "${2:-}" ;;
  *) echo "Usage : sudo ./lab.sh up | test | status | shell <noeud> | down"; exit 1 ;;
esac
