# AKS + Cilium L7 + Application Gateway for Containers (AGC) Demo

End-to-end demo that combines:

- **AKS** with **Azure CNI Overlay + Cilium dataplane**
- **Advanced Container Networking Services (ACNS)** with **L7 network policies**
- **Application Gateway for Containers (AGC) — ALB Controller add-on (managed by AKS)**
- **Gateway API multi-site hosting** (3 hostnames behind one Gateway)
- **CiliumNetworkPolicy**: default-deny + L7 method/path allow-list for north-south *and* east-west traffic

The result is a cluster where:

- One AGC frontend serves `contoso.example.com`, `fabrikam.example.com`, `adventure.example.com`.
- Only `GET /` and `GET /products` reach backends; `POST`, `PUT`, `DELETE`, and other paths are dropped by Cilium L7 at the pod boundary (returns `403`).
- Pods cannot reach the internet (default-deny egress) but DNS still works (explicit allow).
- A `client` pod can `GET` Contoso but is blocked from `POST` Contoso and from talking to Fabrikam at all.

---

## Architecture

```
                Internet
                   │
                   ▼
   ┌───────────────────────────────────┐
   │  Application Gateway for          │
   │  Containers (AGC) frontend        │   single FQDN, 3 hostnames
   │  *.alb.azure.com                  │
   └───────────────────────────────────┘
                   │  (subnet "aks-appgateway", delegated to
                   │   Microsoft.ServiceNetworking/TrafficController,
                   │   in MC_<rg>_<aks>_<region>)
                   ▼
   ┌─────────────── AKS cluster ──────────────────────────────┐
   │ Gateway API: gateway-01 (gatewayClassName: azure-alb-external)
   │   ├─ HTTPRoute contoso   → svc/contoso  :8080
   │   ├─ HTTPRoute fabrikam  → svc/fabrikam :8080
   │   └─ HTTPRoute adventure → svc/adventure:8080
   │
   │ Cilium (ACNS L7) — namespace agc-sites:
   │   • default-deny-all                  (deny ingress + egress)
   │   • allow-dns-egress                  (kube-dns only)
   │   • allow-agc-l7-get-only             (GET / and GET /products)
   │   • client-may-call-contoso-get-only  (east-west: client → contoso GET only)
   └──────────────────────────────────────────────────────────┘
```

---

## Prerequisites

- Azure subscription with permission to register resource providers and create AKS clusters.
- Azure CLI **>= 2.79** (this demo was validated on **2.85.0**).
  Older versions break with `aks-preview` 20.x. Run `az upgrade` if needed.
- Bash (Linux / macOS / WSL / Git Bash on Windows).
- ~10 minutes of compute — the demo provisions 2× `Standard_D4s_v5` nodes.
- Region with AGC capacity. **`westus3` worked reliably**; `eastus2` returned `Microsoft.ServiceNetworking InternalServerError` on subnet association during testing — see [Troubleshooting](#troubleshooting).

CLI extensions are installed automatically by `01-prereqs.sh`:

| Extension       | Why                                                |
| --------------- | -------------------------------------------------- |
| `aks-preview`   | `--acns-advanced-networkpolicies L7` flag          |
| `alb`           | inspect `az network alb` and association resources |

---

## Layout

```
demo/
├── README.md                       <-- you are here
├── scripts/
│   ├── 00-env.sh                   environment variables (source this first)
│   ├── 01-prereqs.sh               register RPs/features, create RG, install extensions
│   ├── 02-create-aks.sh            create AKS w/ Cilium + ACNS L7 + AGC add-on
│   ├── 03-deploy-workloads.sh      ALB CR + sample apps + Gateway/HTTPRoutes + CNPs
│   ├── 04-verify.sh                PASS/FAIL test suite
│   └── 99-cleanup.sh               delete the resource group
└── manifests/
    ├── 10-namespaces.yaml
    ├── 11-applicationloadbalancer.yaml   (reference; script applies inline)
    ├── 20-sample-apps.yaml               3 nginx sites + a curl client
    ├── 21-gateway-and-routes.yaml        Gateway + 3 HTTPRoutes
    └── 30-cilium-policies.yaml           4 CiliumNetworkPolicies
```

---

## Run it

From the repo root:

```bash
# 1. Load env (edit SUBSCRIPTION_ID / LOCATION first if you want)
source demo/scripts/00-env.sh
az login
az account set --subscription "$SUBSCRIPTION_ID"

# 2. Register providers + features and create the resource group (~5 min the first time)
bash demo/scripts/01-prereqs.sh

# 3. Create the AKS cluster (Cilium + ACNS L7 + AGC add-on) — ~7 min
bash demo/scripts/02-create-aks.sh

# 4. Deploy ALB CR, sample apps, Gateway, HTTPRoutes, Cilium policies — ~5 min
#    The script waits for the AGC subnet association + Gateway Programmed=True.
bash demo/scripts/03-deploy-workloads.sh

# 5. Verify
bash demo/scripts/04-verify.sh
```

`kubectl` and `kubelogin` are installed by `az aks install-cli` into
`~/.azure-kubectl/` and `~/.azure-kubelogin/`. The scripts add those to `PATH`
automatically; if you launch a fresh shell, add:

```bash
export PATH="$HOME/.azure-kubectl:$HOME/.azure-kubelogin:$PATH"
```

---

## What each step does

### 02-create-aks.sh

```
az aks create \
  --network-plugin azure --network-plugin-mode overlay --network-dataplane cilium \
  --enable-acns --acns-advanced-networkpolicies L7 \
  --enable-gateway-api --enable-application-load-balancer \
  --enable-oidc-issuer --enable-workload-identity \
  --node-vm-size Standard_D4s_v5 --node-count 2 \
  --ssh-access disabled --generate-ssh-keys
```

Key flags:

| Flag | Purpose |
| ---- | ------- |
| `--network-dataplane cilium` | enables Cilium dataplane (required for L7 policies) |
| `--enable-acns --acns-advanced-networkpolicies L7` | turns on L7 CiliumNetworkPolicy + FQDN filtering |
| `--enable-application-load-balancer` | installs the AGC **ALB Controller add-on** (managed by AKS — uses workload identity automatically; no manual federation) |
| `--enable-gateway-api` | installs the Gateway API CRDs and `azure-alb-external` GatewayClass |

After the cluster is up, the script verifies the `alb-controller` pods in `kube-system` are Ready and that the `azure-alb-external` GatewayClass is `Accepted`.

### 03-deploy-workloads.sh

1. Creates namespaces `alb-demo` and `agc-sites`.
2. Applies an `ApplicationLoadBalancer` CR `alb-demo/alb-demo` with **`spec.associations: []`**. This is the *managed-by-ALB* mode — AKS automatically:
   - creates a delegated subnet `aks-appgateway` in `MC_<rg>_<aks>_<region>`,
   - provisions the AGC resource and frontend,
   - associates the subnet to the AGC.
3. Waits for the `Deployment` condition on the ALB CR to be `True`.
4. Applies sample apps (`contoso`, `fabrikam`, `adventure`, `client`) in `agc-sites`. Each backend is a single-pod nginx serving a unique HTML file from a ConfigMap.
5. Applies `Gateway gateway-01` (one HTTP listener on port 80) and three `HTTPRoute`s — one per hostname.
6. Polls the Gateway until `status.conditions[type=Programmed]=True` and prints the FQDN.
7. Applies Cilium policies (`30-cilium-policies.yaml`).

### Cilium policies (the heart of the demo)

`agc-sites` namespace, four policies layered:

| Policy | Effect |
| ------ | ------ |
| `default-deny-all` | empty `endpointSelector{}` and empty `ingress: []` / `egress: []` → **all pods, all directions denied** unless explicitly allowed below. |
| `allow-dns-egress` | every pod may UDP/53 to kube-dns and only valid `*.cluster.local`/`*.svc.*` lookups (Cilium L7 DNS). |
| `allow-agc-l7-get-only` | for pods labelled `site in (contoso,fabrikam,adventure)`, allow ingress **from `world` *and* `cluster`** (so AGC's NodePort traffic and east-west both apply) restricted to `GET /` and `GET /products` on port 8080. Anything else → 403. |
| `client-may-call-contoso-get-only` | demonstrates **east-west L7**: pod with `app=client` may egress to pod with `app=contoso` only on `GET /` :8080. |

Notes:

- The `world` *plus* `cluster` entities together cover AGC's data-plane source identity. `world` alone leaves a gap when the AGC node-local hop appears as cluster identity.
- The east-west allow on `client → contoso` is *additional* to the ingress allow on contoso; both must permit the call. POST works for neither.

---

## Validation (what 04-verify.sh checks)

| # | Test | Expected |
| -- | ---- | -------- |
| 1 | `GET http://contoso.example.com/` via FQDN | `200` + Contoso HTML |
| 1 | `GET http://fabrikam.example.com/` | `200` + Fabrikam HTML |
| 1 | `GET http://adventure.example.com/` | `200` + Adventure HTML |
| 2 | `POST http://contoso.example.com/` | `403` (Cilium L7) |
| 2 | `GET http://contoso.example.com/admin` | `403` (path not allowed) |
| 3 | `kubectl exec client -- curl contoso:8080` GET | `200` |
| 3 | `kubectl exec client -- curl -X POST contoso:8080` | `403` |
| 3 | `kubectl exec client -- curl fabrikam:8080` | timeout / `000` |
| 4 | `kubectl exec contoso -- curl https://www.bing.com` | timeout / `000` (default-deny egress) |
| 5 | `kubectl exec client -- nslookup contoso` | resolves (DNS allowed) |

Sample run from `westus3` during this build:

```
multi-site:           contoso=200 / fabrikam=200 / adventure=200       PASS
L7 ingress methods:   GET=200  POST=403  PUT=403  DELETE=403           PASS
L7 ingress paths:     GET /=200  GET /products=404  GET /admin=403     PASS
east-west:            client→contoso GET=200 POST=403 fabrikam=000     PASS
egress default-deny:  contoso→bing.com=000 (timeout)                   PASS
DNS allowed:          contoso resolves to 10.0.x.x                     PASS
```

`GET /products → 404` is correct: Cilium permits the path; nginx has no such file. `GET /admin → 403` is **Cilium**, not nginx, denying the request.

---

## Troubleshooting

### Subnet association stuck in `Failed`

```
az network alb association list --alb-name <alb> -g MC_<rg>_<aks>_<region> -o table
```

If the only association shows `Failed` repeatedly with `Microsoft.ServiceNetworking InternalServerError` (this happened in `eastus2` during build), the AGC regional backend is unhealthy. Options:

1. Delete + retry: `az network alb association delete -g MC_... --alb-name ... -n <as-...>` then `kubectl rollout restart deployment/alb-controller -n kube-system`.
2. **Switch regions.** `westus3` worked reliably during this build.

### `az aks create` fails with `ValueError` from aks-preview

Old core CLI + new `aks-preview` extension. Fix:

```bash
az upgrade        # to >= 2.85
az extension update -n aks-preview
```

### `kubectl: command not found`

```bash
az aks install-cli
export PATH="$HOME/.azure-kubectl:$HOME/.azure-kubelogin:$PATH"
```

### Gateway stays `Programmed=Unknown`

Check, in order:

```bash
kubectl get applicationloadbalancer -n alb-demo alb-demo -o yaml         # status.conditions
kubectl logs -n kube-system -l app=alb-controller --tail=200
az network alb association list --alb-name <alb> -g MC_... -o table     # must be Succeeded
```

The Gateway only programs after the ALB CR's `Deployment=True` and the subnet association is `Succeeded`.

### Cilium L7 returns 403 unexpectedly

Confirm the policy is `Valid`:

```bash
kubectl get cnp -n agc-sites
```

Use Hubble to see what Cilium is dropping (ACNS includes Hubble):

```bash
kubectl -n kube-system exec -it ds/cilium -- cilium monitor --type drop
```

---

## Cleanup

```bash
bash demo/scripts/99-cleanup.sh    # deletes the resource group, async
```

This removes the AKS cluster, the AGC resource, the managed `MC_` resource group, and all networking. Cost stops within a few minutes.

---

## References

- [Apply Cilium L7 policies in AKS (ACNS)](https://learn.microsoft.com/en-us/azure/aks/how-to-apply-l7-policies?tabs=cilium)
- [AGC ALB Controller add-on quickstart](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/quickstart-deploy-application-gateway-for-containers-alb-controller-addon)
- [AGC multi-site hosting with Gateway API](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/how-to-multiple-site-hosting-gateway-api?tabs=alb-managed)
