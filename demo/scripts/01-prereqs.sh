#!/usr/bin/env bash
# Prepares Azure subscription: extensions, resource providers, preview features.
# Idempotent — safe to re-run.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-env.sh
source "$DIR/00-env.sh"

az account set --subscription "$SUBSCRIPTION_ID"

echo "==> Installing/updating az CLI extensions"
az extension add --name aks-preview --upgrade --yes
az extension add --name alb         --upgrade --yes

echo "==> Registering resource providers"
for p in Microsoft.ContainerService Microsoft.Network Microsoft.NetworkFunction Microsoft.ServiceNetworking; do
  az provider register --namespace "$p" --consent-to-permissions -o none
done

echo "==> Registering AKS preview features (Gateway API + ALB Controller add-on)"
az feature register --namespace Microsoft.ContainerService --name ManagedGatewayAPIPreview     -o none
az feature register --namespace Microsoft.ContainerService --name ApplicationLoadBalancerPreview -o none

echo "==> Waiting for features to be Registered..."
for f in ManagedGatewayAPIPreview ApplicationLoadBalancerPreview; do
  while [[ "$(az feature show --namespace Microsoft.ContainerService --name "$f" --query properties.state -o tsv)" != "Registered" ]]; do
    sleep 15; echo "  ...still waiting for $f"
  done
  echo "  $f: Registered"
done

echo "==> Propagating feature registrations"
az provider register --namespace Microsoft.ContainerService -o none

echo "==> Creating resource group $RESOURCE_GROUP in $LOCATION"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o table

echo "Prereqs complete."
