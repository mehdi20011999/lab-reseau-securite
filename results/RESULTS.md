# Résultats des tests

Généré automatiquement par `sudo ./lab.sh test` le 2026-10-20 10:39 +00.

| Environnement | Valeur |
|---|---|
| Noyau | `6.18.44-fc-v139` |
| FRRouting | `8.4.4` |
| strongSwan | `5.9.13` |
| nftables | `v1.0.9` |
| LAN | `flat` (8021q = switchs VLAN, flat = segments séparés si le noyau n'a pas le 802.1Q) |
| ESP | `userspace` (kernel = XFRM du noyau, userspace = kernel-libipsec encapsulé en UDP 4500) |

**Bilan : 16 réussis, 0 échoués, 1 non applicables.**

| # | Test | Statut | Détail |
|---|---|---|---|
| T01 | Adjacences OSPF établies sur R-ISP | ✅ PASS | 2 voisins en état Full (attendu : 2) |
| T02 | Route vers le site distant par le backbone | ✅ PASS | R-CASA atteint 203.0.113.0/30 via R-ISP (coût 30) |
| T03 | Authentification OSPF active | ✅ PASS | MD5 activé sur les interfaces backbone |
| T04 | Réseaux privés absents du backbone | ✅ PASS | Aucun routeur ne connaît 10.10.0.0/16 ni 10.20.0.0/16 |
| T05 | Passerelle du VLAN utilisateurs | ✅ PASS | PC-A1 -> 10.10.10.1 |
| T06 | Utilisateurs -> serveurs : HTTPS autorisé | ✅ PASS | PC-A1 -> SRV-A:443 |
| T07 | Utilisateurs -> serveurs : port non prévu refusé | ✅ PASS | PC-A1 -> SRV-A:8080 (service actif mais bloqué) |
| T08 | Serveurs -> utilisateurs bloqué et compté | ✅ PASS | compteur drop_servers_to_users : 0 -> 1 |
| T09 | Étiquetage 802.1Q sur le trunk | ⏭️ SKIP | noyau sans 802.1Q : test exécuté par la CI GitHub Actions |
| T10 | Accès Internet avec NAT source | ✅ PASS | PC-A1 -> 8.8.8.8, vu sur le backbone avec la source 198.51.100.2 |
| T11 | Négociation IKEv2 capturée | ✅ PASS | IKE_SA_INIT puis IKE_AUTH visibles dans ike.txt |
| T12 | Tunnel établi | ✅ PASS | IKE_SA ESTABLISHED et CHILD_SA INSTALLED sur FW-CASA |
| T13 | Trafic de site à site chiffré | ✅ PASS | 10 paquets ESP, 0 paquet en clair avec adresses privées (attendu : 0) |
| T14 | Rabat -> serveur de Casablanca : HTTPS via tunnel | ✅ PASS | PC-B1 -> SRV-A:443 |
| T15 | Rabat -> serveur de Casablanca : SSH refusé | ✅ PASS | PC-B1 -> SRV-A:22 bloqué par FW-CASA |
| T16 | Panne du lien R-ISP/R-RABAT : bascule sur le lien de secours | ✅ PASS | 0 paquets perdus sur 150 (perte de porteuse détectée immédiatement) ; trafic repris via le lien de secours |
| T17 | Panne silencieuse : détection par le dead-interval OSPF | ✅ PASS | 37 paquets perdus sur 150, coupure d'environ 3.7 s (dead-interval : 4 s) |

Les preuves sont dans [`captures/`](../captures) : fichiers `.pcap` à ouvrir dans Wireshark et leur décodage texte `.txt`.
