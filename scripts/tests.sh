#!/usr/bin/env bash
# =============================================================================
#  Tests automatiques du labo + captures réseau comme preuves
#  Produit : results/RESULTS.md, results/results.json, captures/*.pcap et *.txt
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${LAB_STATE:-/tmp/netlab}"
CAP="$ROOT/captures"; RES="$ROOT/results"
mkdir -p "$CAP" "$RES"
[[ -d $STATE ]] || { echo "Le labo n'est pas démarré : sudo ./lab.sh up"; exit 1; }

VLAN_MODE=$(cat "$STATE/vlan_mode"); ESP_MODE=$(cat "$STATE/esp_mode")
c_ok=$'\e[32m'; c_ko=$'\e[31m'; c_sk=$'\e[33m'; c_b=$'\e[1m'; c_0=$'\e[0m'

nsx() { local n=$1; shift; ip netns exec "$n" "$@"; }
vty() { local n=$1; shift; vtysh --vty_socket "$STATE/$n" -c "$*" 2>/dev/null; }
sw()  { local n=$1; shift; STRONGSWAN_CONF="$ROOT/configs/strongswan/swanctl-client.conf" swanctl "$@" --uri "unix://$STATE/$n/charon.vici" 2>/dev/null; }
ping_ok()  { nsx "$1" ping -c "${3:-2}" -W 1 -q "$2" >/dev/null 2>&1; }
tcp_ok()   { nsx "$1" timeout 3 bash -c "</dev/tcp/$2/$3" 2>/dev/null; }
counter()  { nsx "$1" nft -j list counter inet filter "$2" | python3 -c 'import json,sys; d=json.load(sys.stdin); print([o["counter"]["packets"] for o in d["nftables"] if "counter" in o][0])'; }

# capture <noeud> <interface> <nom> <filtre> -- commande...
capture() {
  local n=$1 ifc=$2 name=$3 filter=$4; shift 5
  nsx "$n" tcpdump -i "$ifc" -nn -U -w "$CAP/$name.pcap" "$filter" >/dev/null 2>&1 &
  local pid=$!; sleep 0.7
  "$@" >/dev/null 2>&1
  sleep 0.7; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  tcpdump -nn -r "$CAP/$name.pcap" ${CAP_FLAGS:-} 2>/dev/null > "$CAP/$name.txt"
}

declare -a IDS NAMES STATUS DETAILS
record() {  # record <id> <nom> <PASS|FAIL|SKIP> <détail>
  IDS+=("$1"); NAMES+=("$2"); STATUS+=("$3"); DETAILS+=("$4")
  local col=$c_ok; [[ $3 == FAIL ]] && col=$c_ko; [[ $3 == SKIP ]] && col=$c_sk
  printf '  %-4s %s%-5s%s %s\n       %s\n' "$1" "$col" "$3" "$c_0" "$2" "$4"
}
check() {  # check <id> <nom> <détail> <commande...>
  local id=$1 name=$2 detail=$3; shift 3
  if "$@"; then record "$id" "$name" PASS "$detail"; else record "$id" "$name" FAIL "$detail"; fi
}

echo "${c_b}Tests du labo${c_0}  (LAN : $VLAN_MODE, ESP : $ESP_MODE)"

# --- Routage --------------------------------------------------------------------------
echo "${c_b}Routage OSPF${c_0}"
nb=$(vty r-isp "show ip ospf neighbor" | grep -c Full)
check T01 "Adjacences OSPF établies sur R-ISP" "$nb voisins en état Full (attendu : 2)" test "$nb" -ge 2
check T02 "Route vers le site distant par le backbone" "R-CASA atteint 203.0.113.0/30 via R-ISP (coût 30)" \
  bash -c "vtysh --vty_socket $STATE/r-casa -c 'show ip route 203.0.113.0/30' | grep -q 'via eth0'"
check T03 "Authentification OSPF active" "MD5 activé sur les interfaces backbone" \
  bash -c "vtysh --vty_socket $STATE/r-isp -c 'show ip ospf interface eth0' | grep -qi 'cryptographic authentication enabled'"
check T04 "Réseaux privés absents du backbone" "Aucun routeur ne connaît 10.10.0.0/16 ni 10.20.0.0/16" \
  bash -c "! vtysh --vty_socket $STATE/r-isp -c 'show ip route' | grep -qE ' 10\.(10|20)\.'"
CAP_FLAGS="-v" capture r-isp eth0 ospf "proto ospf" -- sleep 3

# --- LAN et filtrage ---------------------------------------------------------------------
echo "${c_b}LAN, VLAN et filtrage${c_0}"
check T05 "Passerelle du VLAN utilisateurs" "PC-A1 -> 10.10.10.1" ping_ok pc-a 10.10.10.1
check T06 "Utilisateurs -> serveurs : HTTPS autorisé" "PC-A1 -> SRV-A:443" tcp_ok pc-a 10.10.20.10 443
check T07 "Utilisateurs -> serveurs : port non prévu refusé" "PC-A1 -> SRV-A:8080 (service actif mais bloqué)" \
  bash -c "! (ip netns exec pc-a timeout 3 bash -c '</dev/tcp/10.10.20.10/8080') 2>/dev/null"
before=$(counter fw-casa drop_servers_to_users)
ping_ok srv-a 10.10.10.10 1; after=$(counter fw-casa drop_servers_to_users)
check T08 "Serveurs -> utilisateurs bloqué et compté" "compteur drop_servers_to_users : $before -> $after" test "$after" -gt "$before"
if [[ $VLAN_MODE == 8021q ]]; then
  CAP_FLAGS="-e" capture fw-casa trunk vlan "vlan" -- bash -c "ip netns exec pc-a ping -c2 -W1 10.10.10.1; ip netns exec srv-a ping -c2 -W1 10.10.20.1"
  check T09 "Étiquetage 802.1Q sur le trunk" "trames vues avec 'vlan 10' et 'vlan 20'" \
    bash -c "grep -q 'vlan 10' $CAP/vlan.txt && grep -q 'vlan 20' $CAP/vlan.txt"
else
  record T09 "Étiquetage 802.1Q sur le trunk" SKIP "noyau sans 802.1Q : test exécuté par la CI GitHub Actions"
fi

# --- NAT ---------------------------------------------------------------------------------
echo "${c_b}NAT${c_0}"
capture r-isp eth0 nat "icmp and host 8.8.8.8" -- ip netns exec pc-a ping -c3 -W1 8.8.8.8
check T10 "Accès Internet avec NAT source" "PC-A1 -> 8.8.8.8, vu sur le backbone avec la source 198.51.100.2" \
  bash -c "grep -q '198.51.100.2 > 8.8.8.8' $CAP/nat.txt && ! grep -q '10.10.10.10 > 8.8.8.8' $CAP/nat.txt"

# --- VPN IPsec ---------------------------------------------------------------------------
echo "${c_b}VPN IPsec IKEv2${c_0}"
sw fw-casa --terminate --ike casa-rabat --timeout 5 >/dev/null
CAP_FLAGS="-v" capture r-isp eth0 ike "udp port 500 or udp port 4500" -- \
  bash -c "STRONGSWAN_CONF=$ROOT/configs/strongswan/swanctl-client.conf swanctl --initiate --child lan-lan --timeout 10 --uri unix://$STATE/fw-casa/charon.vici"
check T11 "Négociation IKEv2 capturée" "IKE_SA_INIT puis IKE_AUTH visibles dans ike.txt" \
  bash -c "grep -qi 'ikev2_init\|IKE_SA_INIT\|parent_sa' $CAP/ike.txt && grep -qi 'ikev2_auth\|IKE_AUTH\|child_sa\|NONESP-encap' $CAP/ike.txt"
check T12 "Tunnel établi" "IKE_SA ESTABLISHED et CHILD_SA INSTALLED sur FW-CASA" \
  bash -c "STRONGSWAN_CONF=$ROOT/configs/strongswan/swanctl-client.conf swanctl --list-sas --uri unix://$STATE/fw-casa/charon.vici 2>/dev/null | grep -q ESTABLISHED && STRONGSWAN_CONF=$ROOT/configs/strongswan/swanctl-client.conf swanctl --list-sas --uri unix://$STATE/fw-casa/charon.vici 2>/dev/null | grep -q INSTALLED"
capture r-isp eth0 ipsec "not proto ospf" -- ip netns exec pc-a ping -c5 -W1 10.20.10.10
esp=$(grep -c 'ESP(spi' "$CAP/ipsec.txt"); clear=$(grep -cE '10\.(10|20)\.[0-9]+\.[0-9]+ > 10\.(10|20)' "$CAP/ipsec.txt")
check T13 "Trafic de site à site chiffré" "$esp paquets ESP, $clear paquet en clair avec adresses privées (attendu : 0)" \
  test "$esp" -ge 10 -a "$clear" -eq 0
check T14 "Rabat -> serveur de Casablanca : HTTPS via tunnel" "PC-B1 -> SRV-A:443" tcp_ok pc-b 10.10.20.10 443
check T15 "Rabat -> serveur de Casablanca : SSH refusé" "PC-B1 -> SRV-A:22 bloqué par FW-CASA" \
  bash -c "! (ip netns exec pc-b timeout 3 bash -c '</dev/tcp/10.10.20.10/22') 2>/dev/null"

# --- Résilience --------------------------------------------------------------------------
echo "${c_b}Résilience${c_0}"
nsx pc-a ping -i 0.1 -c 150 -W 1 10.20.10.10 > "$RES/failover-ping.txt" 2>&1 &
pp=$!; sleep 2
nsx r-isp ip link set eth1 down; t_down=$(date +%s.%N)
wait "$pp"
sent=$(grep -oP '\d+(?= packets transmitted)' "$RES/failover-ping.txt"); recv=$(grep -oP '\d+(?= received)' "$RES/failover-ping.txt")
lost=$((sent - recv)); conv=$(python3 -c "print(round($lost*0.1,1))")
backup=$(vty r-casa "show ip route 203.0.113.0/30" | grep -c "via eth2")
nsx r-isp ip link set eth1 up
check T16 "Panne du lien R-ISP/R-RABAT : bascule sur le lien de secours" \
  "$lost paquets perdus sur $sent (perte de porteuse détectée immédiatement) ; trafic repris via le lien de secours" \
  test "$recv" -gt 0 -a "$backup" -ge 1 -a "$lost" -lt 100

# Panne silencieuse : le lien reste « up » mais ne transmet plus rien (cas d'une fibre dégradée).
# Seule l'expiration du dead-interval OSPF (4 s) peut la détecter.
for _ in $(seq 40); do vty r-casa "show ip route 203.0.113.0/30" | grep -q "via eth0" && break; sleep 0.5; done
nsx pc-a ping -i 0.1 -c 150 -W 1 10.20.10.10 > "$RES/silent-failure-ping.txt" 2>&1 &
pp=$!; sleep 2
nsx r-isp nft -f - <<'NFT'
table netdev chaos {
  chain in { type filter hook ingress device "eth1" priority 0; policy drop; }
}
NFT
wait "$pp"
nsx r-isp nft delete table netdev chaos
sent=$(grep -oP '\d+(?= packets transmitted)' "$RES/silent-failure-ping.txt"); recv=$(grep -oP '\d+(?= received)' "$RES/silent-failure-ping.txt")
lost=$((sent - recv)); conv=$(python3 -c "print(round($lost*0.1,1))")
check T17 "Panne silencieuse : détection par le dead-interval OSPF" \
  "$lost paquets perdus sur $sent, coupure d'environ ${conv} s (dead-interval : 4 s)" \
  test "$recv" -gt 0 -a "$lost" -gt 0 -a "$lost" -lt 100

# --- Rapport -----------------------------------------------------------------------------
pass=0; fail=0; skip=0
for s in "${STATUS[@]}"; do case $s in PASS) ((pass++));; FAIL) ((fail++));; SKIP) ((skip++));; esac; done
now=$(date '+%Y-%m-%d %H:%M %Z')
{
  echo "# Résultats des tests"
  echo
  echo "Généré automatiquement par \`sudo ./lab.sh test\` le $now."
  echo
  echo "| Environnement | Valeur |"
  echo "|---|---|"
  echo "| Noyau | \`$(uname -r)\` |"
  echo "| FRRouting | \`$(/usr/lib/frr/zebra --version 2>/dev/null | head -1 | awk '{print $NF}')\` |"
  echo "| strongSwan | \`$(/usr/lib/ipsec/charon --version 2>/dev/null | head -1 | awk '{print $NF}')\` |"
  echo "| nftables | \`$(nft --version | awk '{print $2}')\` |"
  echo "| LAN | \`$VLAN_MODE\` (8021q = switchs VLAN, flat = segments séparés si le noyau n'a pas le 802.1Q) |"
  echo "| ESP | \`$ESP_MODE\` (kernel = XFRM du noyau, userspace = kernel-libipsec encapsulé en UDP 4500) |"
  echo
  echo "**Bilan : $pass réussis, $fail échoués, $skip non applicables.**"
  echo
  echo "| # | Test | Statut | Détail |"
  echo "|---|---|---|---|"
  for i in "${!IDS[@]}"; do
    icon="✅"; [[ ${STATUS[$i]} == FAIL ]] && icon="❌"; [[ ${STATUS[$i]} == SKIP ]] && icon="⏭️"
    echo "| ${IDS[$i]} | ${NAMES[$i]} | $icon ${STATUS[$i]} | ${DETAILS[$i]} |"
  done
  echo
  echo "Les preuves sont dans [\`captures/\`](../captures) : fichiers \`.pcap\` à ouvrir dans Wireshark et leur décodage texte \`.txt\`."
} > "$RES/RESULTS.md"

python3 - "$RES/results.json" "$now" "$VLAN_MODE" "$ESP_MODE" <<PY
import json,sys
ids=$(printf '%s\n' "${IDS[@]}" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read().split()))')
st=$(printf '%s\n' "${STATUS[@]}" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read().split()))')
json.dump({"generated":sys.argv[2],"lan_mode":sys.argv[3],"esp_mode":sys.argv[4],
           "results":[{"id":i,"status":s} for i,s in zip(ids,st)]},open(sys.argv[1],"w"),indent=2)
PY

echo
echo "${c_b}Bilan : ${c_ok}$pass réussis${c_0}, ${c_ko}$fail échoués${c_0}, ${c_sk}$skip non applicables${c_0}  ->  results/RESULTS.md"
[[ $fail -eq 0 ]]
