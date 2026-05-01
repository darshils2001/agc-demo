#!/usr/bin/env bash
# Deploy the Application Gateway for Containers (managed-by-ALB-Controller),
# the three sites, the Gateway + HTTPRoutes, and the Cilium L7 policies.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
# shellcheck source=00-env.sh
source "$DIR/00-env.sh"

echo "==> Creating namespaces"
kubectl apply -f "$ROOT/manifests/10-namespaces.yaml"

echo "==> Provisioning the Application Gateway for Containers (managed by ALB Controller)"
# The minimal ApplicationLoadBalancer CR (no associations) tells the ALB
# Controller add-on to create an AGC resource using the AKS-managed subnet
# 'aks-appgateway' that the add-on already created in the MC_ resource group.
kubectl apply -f - <<EOF
apiVersion: alb.networking.azure.io/v1
kind: ApplicationLoadBalancer
metadata:
  name: $ALB_NAME
  namespace: $ALB_NAMESPACE
spec:
  associations: []
EOF

echo "==> Waiting for the AGC resource to be Deployed (up to 5 minutes)"
for _ in $(seq 1 60); do
  status=$(kubectl get applicationloadbalancer "$ALB_NAME" -n "$ALB_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Deployment")].status}' 2>/dev/null || true)
  if [[ "$status" == "True" ]]; then echo "  AGC Deployment=True"; break; fi
  echo "  ...still deploying"; sleep 5
done

echo "==> Deploying sample workloads (contoso/fabrikam/adventure + client)"
kubectl apply -f "$ROOT/manifests/20-sample-apps.yaml"
kubectl rollout status -n agc-sites deploy/contoso   --timeout=120s
kubectl rollout status -n agc-sites deploy/fabrikam  --timeout=120s
kubectl rollout status -n agc-sites deploy/adventure --timeout=120s
kubectl rollout status -n agc-sites deploy/client    --timeout=120s

echo "==> Creating Gateway + multi-site HTTPRoutes"
kubectl apply -f "$ROOT/manifests/21-gateway-and-routes.yaml"

echo "==> Waiting for Gateway to be Programmed and FQDN assigned"
for _ in $(seq 1 60); do
  fqdn=$(kubectl get gateway gateway-01 -n agc-sites -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
  if [[ -n "$fqdn" ]]; then echo "  Gateway FQDN: $fqdn"; break; fi
  sleep 5
done
[[ -n "${fqdn:-}" ]] || { echo "ERROR: Gateway never received an FQDN"; exit 1; }

echo "==> Applying Cilium L7 + default-deny policies"
kubectl apply -f "$ROOT/manifests/30-cilium-policies.yaml"

echo
echo "Demo deployed. Gateway FQDN:"
echo "  $fqdn"
echo
echo "Run demo/scripts/04-verify.sh to test."
