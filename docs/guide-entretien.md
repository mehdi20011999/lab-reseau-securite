# Guide d'entretien : expliquer le labo en 5 minutes

Avant d'ajouter ce projet à ton CV, tu dois pouvoir répondre à chacune de ces questions sans regarder le code.
Relance le labo, ouvre un shell sur un équipement (`sudo ./lab.sh shell fw-casa`) et vérifie chaque réponse par toi-même.

## Le pitch (30 secondes)

« J'ai construit un réseau multi-sites entièrement automatisé : deux sites reliés par un backbone OSPF,
chacun protégé par un firewall qui fait le filtrage entre VLAN, le NAT et un VPN IPsec IKEv2.
Un script démarre les 11 équipements, et une suite de 17 tests vérifie le routage, le filtrage,
le chiffrement et la reprise après panne, avec des captures réseau comme preuves.
La même suite tourne dans GitHub Actions à chaque modification. »

## Questions probables

**Pourquoi OSPF et pas des routes statiques ?**
Avec des routes statiques, la panne du lien R-ISP — R-RABAT couperait les sites jusqu'à une intervention manuelle.
Avec OSPF, le lien de secours prend le relais seul : environ 4 s de coupure sur une panne silencieuse, mesurée par le test T17 (`results/RESULTS.md`).

**Pourquoi un coût de 100 sur le lien de secours ?**
Pour qu'il ne soit choisi que si le chemin principal (coût 30) disparaît. Sinon OSPF préférerait le lien direct, plus court.

**À quoi sert l'authentification MD5 sur OSPF ?**
À empêcher un équipement non autorisé de former une adjacence et d'injecter de fausses routes. Le test T03 la vérifie et la capture `ospf.txt` montre `Authentication Type: MD5`.
(Limite à connaître : MD5 est ancien ; FRR supporte aussi HMAC-SHA via les key-chains.)

**Quelle différence entre IKE et ESP ?**
IKE (UDP 500, puis 4500) négocie les algorithmes et les clés et authentifie les pairs. ESP transporte les données chiffrées.
On peut avoir IKE établi et ESP en échec : c'est le premier problème de `problemes-resolus.md`.

**Pourquoi exclure le trafic de site à site du NAT ?**
Si le firewall traduisait 10.10.10.10 en 198.51.100.2 avant le chiffrement, l'adresse ne correspondrait plus aux sélecteurs du tunnel (10.10.0.0/16) et le paquet partirait en clair vers Internet, où il serait jeté.

**Comment prouves-tu que le trafic est chiffré ?**
Capture sur R-ISP pendant un ping entre les sites : uniquement des paquets `ESP(spi=…)`, aucun paquet ICMP avec une adresse 10.x (test T13, `captures/ipsec.txt`).

**Que fait `rt ipsec exists` dans nftables ?**
La règle ne s'applique que si le paquet va être chiffré par une politique IPsec. Si le tunnel tombe, le trafic vers Rabat est refusé au lieu de partir en clair.

**Pourquoi la politique par défaut est-elle « drop » ?**
C'est le principe de liste blanche : on ouvre seulement ce qui est nécessaire, tout le reste est refusé et compté (compteurs `drop_forward`, `drop_servers_to_users`).

**Que changerais-tu pour la production ?**
Authentification IPsec par certificats au lieu d'une clé pré-partagée, deux tunnels pour la redondance, journalisation centralisée (syslog vers un SIEM), supervision (SNMP ou Prometheus) et sauvegarde des configurations.

## Commandes à savoir taper

```bash
sudo ./lab.sh shell r-isp
vtysh --vty_socket /tmp/netlab/r-isp -c "show ip ospf neighbor"
sudo ip netns exec fw-casa nft list ruleset
sudo ip netns exec pc-a ping 10.20.10.10
sudo ip netns exec r-isp tcpdump -nn -i eth0 esp or udp port 4500
```
