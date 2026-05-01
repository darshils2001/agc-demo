#!/usr/bin/env bash
# Source this file to set the demo's environment variables.
# Usage:  source demo/scripts/00-env.sh

export SUBSCRIPTION_ID="64d48c73-c5f4-4817-93d8-65908359d9b4"   # rnautiyal@lab
export LOCATION="westus3"
export RESOURCE_GROUP="rg-agc-cilium-demo"
export PREFIX="agcdemo"
export AKS_NAME="${PREFIX}-aks"
export ALB_NAMESPACE="alb-demo"
export ALB_NAME="alb-demo"
export APP_NAMESPACE="agc-sites"

echo "Demo environment loaded:"
echo "  SUBSCRIPTION_ID=$SUBSCRIPTION_ID"
echo "  RESOURCE_GROUP=$RESOURCE_GROUP   LOCATION=$LOCATION"
echo "  AKS_NAME=$AKS_NAME"
echo "  ALB_NAMESPACE=$ALB_NAMESPACE  ALB_NAME=$ALB_NAME"
echo "  APP_NAMESPACE=$APP_NAMESPACE"
