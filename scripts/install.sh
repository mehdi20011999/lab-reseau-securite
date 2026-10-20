#!/usr/bin/env bash
# Installe les dépendances du labo (Ubuntu 22.04 / 24.04, Debian 12, WSL2).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Lance ce script avec sudo"; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  iproute2 iputils-ping nftables tcpdump python3 \
  frr frr-pythontools \
  strongswan-swanctl strongswan-charon libcharon-extra-plugins libstrongswan-standard-plugins
# Le labo lance ses propres démons dans chaque namespace : les services système ne sont pas nécessaires.
systemctl disable --now frr strongswan 2>/dev/null || true
echo "Dépendances installées. Démarre le labo : sudo ./lab.sh up"
