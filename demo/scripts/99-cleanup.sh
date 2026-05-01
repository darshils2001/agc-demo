#!/usr/bin/env bash
# Tear everything down. Keeps the local kubeconfig context for safety.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-env.sh
source "$DIR/00-env.sh"

read -r -p "Delete resource group $RESOURCE_GROUP and ALL its resources? Type 'yes' to confirm: " ans
[[ "$ans" == "yes" ]] || { echo "Aborted."; exit 1; }
az group delete --name "$RESOURCE_GROUP" --yes --no-wait
echo "Deletion submitted."
