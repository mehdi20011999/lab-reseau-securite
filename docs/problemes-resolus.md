# Problèmes rencontrés pendant la mise au point

Chaque problème est décrit comme en exploitation : symptôme, diagnostic, cause, correction.

## 1. Le tunnel monte, mais aucun trafic ne passe

- **Symptôme** : `swanctl --list-sas` affiche l'IKE_SA `ESTABLISHED`, mais `--initiate` répond `establishing CHILD_SA 'lan-lan' failed`.
- **Diagnostic** : dans le journal du pair, `selected proposal: ESP:AES_GCM_16_256` puis `unable to install inbound and outbound IPsec SA (SAD) in kernel`. Le pair renvoie `NO_PROPOSAL_CHOSEN`.
- **Cause** : la négociation IKE réussit (elle est faite en espace utilisateur), mais le noyau refuse d'installer les clés ESP. `/proc/crypto` ne liste pas `gcm(aes)`.
- **Correction** : proposition ESP passée à `aes256-sha256` (CBC + HMAC), supportée partout. Leçon : une SA IKE établie ne prouve pas que le tunnel transporte des données ; il faut vérifier la CHILD_SA.

## 2. Même avec AES-CBC, le noyau refuse les clés ESP

- **Symptôme** : `unable to add SAD entry ... (FAILED)` avec n'importe quel algorithme.
- **Diagnostic** : un `ip xfrm state add ... proto esp` manuel échoue avec `Requested type not found`. La configuration du noyau montre `# CONFIG_INET_ESP is not set`.
- **Correction** : `lab.sh` teste désormais le support ESP au démarrage. S'il manque, il charge le plugin `kernel-libipsec` (ESP en espace utilisateur via une interface TUN, encapsulé en UDP 4500) et adapte les règles nftables à l'interface `ipsec0`.
- **Piège secondaire** : le plugin était chargé mais pas utilisé, car `kernel-netlink` était listé avant lui. Dans strongSwan, le premier plugin qui fournit l'interface IPsec du noyau l'emporte.

## 3. Chargement de la configuration IPsec refusé

- **Symptôme** : `loading connection 'casa-rabat' failed: invalid value for: auth`.
- **Cause** : `local { auth = psk  id = fw-casa.lab }` sur une seule ligne. Le format de swanctl attend une paire clé = valeur par ligne : la valeur lue était `psk  id = fw-casa.lab`.
- **Correction** : un paramètre par ligne.

## 4. FRRouting ne démarre pas

- **Symptôme** : `privs_init: user(root) is not part of vty group specified(frrvty)`.
- **Cause** : FRR vérifie que l'utilisateur d'exécution appartient au groupe qui protège ses sockets de contrôle.
- **Correction** : lancer les démons avec l'utilisateur dédié `frr` (`-u frr -g frr`), comme en production, plutôt que de les faire tourner en root.

## 5. strongSwan modifiait la configuration de la machine hôte

- **Symptôme** : le journal affichait `install DNS servers in '/etc/resolv.conf'` et `installed bypass policy` pour des réseaux locaux.
- **Cause** : sans liste explicite, charon charge tous ses plugins, dont `resolve` et `bypass-lan`.
- **Correction** : liste de plugins explicite dans `strongswan.conf` (principe du moindre privilège) et `/run` privé pour chaque firewall.

## 6. Mesure de convergence faussée au démarrage

- **Symptôme** : juste après le démarrage, R-CASA joignait Rabat par le lien de secours (coût 110) au lieu du backbone (coût 30).
- **Cause** : les adjacences étaient `Full`, mais le SPF n'avait pas fini de recalculer.
- **Correction** : le démarrage attend que la route vers 203.0.113.0/30 passe réellement par `eth0`.
