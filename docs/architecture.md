# Architecture

## Équipements

| Équipement | Rôle | Logiciel |
|---|---|---|
| R-CASA, R-RABAT | Routeurs de bord des sites | FRRouting (zebra, ospfd) |
| R-ISP | Cœur du backbone, simule Internet (`8.8.8.8` en loopback) | FRRouting |
| FW-CASA, FW-RABAT | Routage inter-VLAN, filtrage, NAT, VPN | nftables, strongSwan (IKEv2) |
| SW-CASA, SW-RABAT | Switchs d'accès, trunk 802.1Q vers le firewall | bridge Linux `vlan_filtering` |
| PC-A1, PC-B1 | Postes utilisateurs (VLAN 10) | — |
| SRV-A, SRV-B | Serveurs (VLAN 20), services sur 22, 443, 8080 | — |

Chaque équipement est un *network namespace* Linux : il a ses propres interfaces, sa table de routage
et ses règles de pare-feu, comme un équipement physique.

## Plan d'adressage

| Lien | Réseau | Adresses |
|---|---|---|
| R-CASA — R-ISP | 10.255.0.0/30 | .1 / .2 |
| R-ISP — R-RABAT | 10.255.0.4/30 | .5 / .6 |
| R-CASA — R-RABAT (secours, coût 100) | 10.255.0.8/30 | .9 / .10 |
| R-CASA — FW-CASA (WAN) | 198.51.100.0/30 | .1 / .2 |
| R-RABAT — FW-RABAT (WAN) | 203.0.113.0/30 | .1 / .2 |

| Site | VLAN | Réseau | Passerelle | Hôte |
|---|---|---|---|---|
| Casablanca | 10 utilisateurs | 10.10.10.0/24 | .1 | PC-A1 .10 |
| Casablanca | 20 serveurs | 10.10.20.0/24 | .1 | SRV-A .10 |
| Rabat | 10 utilisateurs | 10.20.10.0/24 | .1 | PC-B1 .10 |
| Rabat | 20 serveurs | 10.20.20.0/24 | .1 | SRV-B .10 |

Loopbacks : R-CASA 1.1.1.1, R-ISP 2.2.2.2 et 8.8.8.8, R-RABAT 3.3.3.3.
198.51.100.0/24 et 203.0.113.0/24 sont des plages réservées à la documentation (RFC 5737).

## Routage

- OSPF aire 0 entre les trois routeurs, réseaux point à point, authentification MD5.
- Timers hello 1 s et dead 4 s : une panne silencieuse est détectée en 4 s environ.
- Le lien direct R-CASA — R-RABAT a un coût de 100 : il ne sert que si le chemin par R-ISP (coût 30) tombe.
- Les interfaces vers les firewalls et les loopbacks sont *passives* : elles sont annoncées, mais aucune adjacence ne s'y forme.
- Les réseaux privés 10.10.0.0/16 et 10.20.0.0/16 ne sont **jamais** annoncés dans le backbone : on ne les atteint que par le tunnel. Le test T04 le vérifie.

## Politique de sécurité

Politique par défaut : **refus**. Tout ce qui n'est pas listé est bloqué et compté.

| Source | Destination | Autorisé | Test |
|---|---|---|---|
| Utilisateurs | Serveurs du site | TCP 22, 80, 443 et ping | T06, T07 |
| Utilisateurs | Internet | tout, avec NAT source | T10 |
| Serveurs | Internet | DNS, HTTPS, ping | — |
| Serveurs | Utilisateurs | **rien** (compteur `drop_servers_to_users`) | T08 |
| Utilisateurs | Site distant | ping et HTTPS, **uniquement dans le tunnel** (`rt ipsec exists`) | T13 |
| Site distant | Serveurs du site | HTTPS et ping, **uniquement si déchiffré** (`meta ipsec exists`) | T14, T15 |
| Pair IPsec | Firewall | UDP 500, 4500 et ESP | T11 |

Le NAT ne s'applique pas au trafic de site à site : il part dans le tunnel avec ses adresses d'origine.

## VPN IPsec

| Paramètre | Valeur |
|---|---|
| Échange de clés | IKEv2 |
| Phase IKE | AES-256-CBC, SHA-256, groupe DH 14 (MODP 2048) |
| Phase ESP | AES-256-CBC, HMAC-SHA-256 |
| Authentification | clé pré-partagée de 256 bits, **générée à chaque démarrage**, jamais dans le dépôt |
| Sélecteurs | 10.10.0.0/16 <-> 10.20.0.0/16 |
| Détection de pair mort | DPD toutes les 5 s, redémarrage automatique |

## Modes d'exécution

Le script détecte ce que le noyau sait faire et s'adapte, sans changer l'adressage ni la politique :

| Capacité du noyau | Mode normal | Mode de repli |
|---|---|---|
| 802.1Q et bridge | switchs VLAN avec trunk (`8021q`) | un segment par VLAN (`flat`), le test T09 est ignoré |
| ESP (XFRM) | chiffrement par le noyau (`kernel`) | chiffrement par strongSwan via TUN, encapsulé en UDP 4500 (`userspace`) |

Le mode utilisé est écrit en tête de `results/RESULTS.md`.
