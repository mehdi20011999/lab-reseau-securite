# Variante graphique : GNS3 et pfSense

Le labo automatisé est la version de référence. Cette variante reproduit la même architecture avec des
équipements virtuels et une interface graphique, plus proche des firewalls du marché (Fortinet, Palo Alto).
Elle prend 2 à 3 semaines et ne se teste pas automatiquement.

## Images
| Rôle | Image |
|---|---|
| Routeurs | appliance FRRouting (Marketplace GNS3) : reprendre `configs/frr/*.conf` |
| Firewalls | pfSense CE ou OPNsense (ISO gratuit, QEMU, 1 à 2 Go de RAM chacun) |
| Switchs | Ethernet switch intégré à GNS3 (ports `access` et `dot1q`) |
| Hôtes | VPCS ou conteneur Alpine |

Adressage, politique et paramètres IPsec : identiques à `architecture.md`.

## pfSense, pas à pas
1. **Interfaces > Assignments > VLANs** : VLAN 10 et 20 sur l'interface LAN, adresses .1 de chaque /24.
2. WAN statique (198.51.100.2/30, passerelle .1), décocher « Block private networks ».
3. **Firewall > NAT > Outbound** en mode *Hybrid* : une règle **No NAT** 10.10.0.0/16 vers 10.20.0.0/16, puis le NAT vers le WAN.
4. **Firewall > Rules** : reproduire le tableau de politique de `architecture.md`, avec « Log » sur les règles de blocage.
5. **VPN > IPsec** : Phase 1 IKEv2, AES-256, SHA-256, DH 14, clé pré-partagée ; Phase 2 en mode tunnel 10.10.0.0/16 <-> 10.20.0.0/16.
6. Vérifier **Status > IPsec** puis capturer dans GNS3 (clic droit sur un lien, « Start capture »).

Pour la certification Fortinet, la même démarche s'applique sur une VM FortiGate d'évaluation.
