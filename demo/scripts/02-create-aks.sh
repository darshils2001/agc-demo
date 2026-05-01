#!/usr/bin/env bash
# Creates an AKS cluster combining all required features:
#   - Azure CNI Overlay + Cilium dataplane (Azure CNI Powered by Cilium)
#   - Advanced Container Networking Services (ACNS) with L7 policies
#   - OIDC issuer + workload identity (required for AGC ALB Controller add-on)
#   - AKS-managed Gateway API add-on
#   - Application Gateway for Containers (ALB Controller) add-on

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-env.sh
source "$DIR/00-env.sh"

az account set --subscription "$SUBSCRIPTION_ID"

echo "==> Creating AKS cluster $AKS_NAME (this takes ~8-12 minutes)"
az aks create \
  --resource-group "$RESOURCE_GROUP" \
  --name           "$AKS_NAME" \
  --location       "$LOCATION" \
  --node-count     2 \
  --node-vm-size   Standard_D4s_v5 \
  --network-plugin       azure \
  --network-plugin-mode  overlay \
  --network-dataplane    cilium \
  --enable-acns \
  --acns-advanced-networkpolicies L7 \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --enable-gateway-api \
  --enable-application-load-balancer \
  --generate-ssh-keys \
  -o table

echo "==> Fetching kubeconfig credentials"
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --overwrite-existing

echo "==> Verifying ALB Controller pods"
kubectl wait --for=condition=Ready pods -l app=alb-controller -n kube-system --timeout=300s
kubectl get pods -n kube-system -l app=alb-controller

echo "==> Verifying GatewayClass azure-alb-external"
kubectl get gatewayclass azure-alb-external -o yaml | head -25

echo "AKS cluster ready."
