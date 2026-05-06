# AGC + AKS multi-site demo — Cloud Shell runbook

Hands-on-keyboard runbook. Paste each block into **Azure Cloud Shell** (<https://shell.azure.com> or the `>_` icon in the portal — `az`, `kubectl`, `curl` are pre-installed). Zero git, every manifest inline.

> **The framing in one line:** **AGC brings traffic *into* the cluster. ACNS L7 controls how traffic flows *within* the cluster.** Two features, two directions, one zero-trust story. Step 4 demonstrates each layer independently.

> **Read [PITCH.md](PITCH.md) first** for the *why* (problem statement, what AGC unlocks, what this demo proves) and *afterwards* for the wrap-up, Q&A talking points, and next steps. This file is just the steps.

---

## Open the demo (read this out before running anything)

**What we're going to do today:**
- Stand up an AKS cluster with two add-ons: **AGC** (Application Gateway for Containers) for managed ingress, and **ACNS L7** (Advanced Container Networking Services) for in-cluster L7 policy.
- Wire three sample tenants — contoso, fabrikam, adventure — behind a single AGC public IP, then layer Cilium L7 policies on top of every pod.
- Turn on Azure WAF on AGC so the front door is also a metal detector.

**The story in one line:**
- **AGC brings traffic *into* the cluster.** With WAF, AGC also blocks signature-based attacks at the edge.
- **ACNS L7 decides what traffic, from any source, is allowed to flow *within* the cluster** — north-south behind AGC, east-west pod-to-pod, and outbound.
- Two add-ons, two directions, one zero-trust posture.

**What to watch for in step 4:**
- One public IP, three different `<h1>Hello from <site></h1>` responses (4a).
- WAF blocks SQLi and path-traversal at AGC; legit traffic still gets through (4a-bonus).
- `POST /` returns `403` from Cilium; `GET /products` returns `404` from nginx — proof L7 inspection is real (4b).
- Pod-to-pod calls hit the same enforcement (4c).
- Egress to the internet silently times out; DNS still resolves (4d, 4e).

---

## 1. Set up Azure (variables, providers, AKS cluster, WAF policy)

**What this block does, at a glance:**

One pasteable bash block stands up the entire Azure side of the demo:

1. Sets variables and picks the subscription.
2. Registers providers + the L7 preview feature, installs the `aks-preview` and `alb` CLI extensions.
3. Creates the resource group and the AKS cluster (~7 min).
4. Creates the Azure WAF policy and grants the ALB Controller permission to attach it.

When this finishes, you have an empty AKS cluster with both add-ons installed and a WAF policy waiting on the side, ready to be bound in step 2.

**The two flags that make this whole demo possible** — the rest is supporting cast:

- `--enable-acns --acns-advanced-networkpolicies L7` → turns on **Cilium L7** (HTTP-aware policy: method, path, headers). This is what makes 4b–4e work.
- `--enable-application-load-balancer` → installs the **AGC** add-on (controller, workload identity, delegated subnet — all auto-provisioned). This is what makes 4a possible.

Cluster create is the only slow step (~7 min). Everything else is fast.

```bash
# --- Variables (edit as needed) ---
export SUBSCRIPTION_ID="64d48c73-c5f4-4817-93d8-65908359d9b4"   # rnautiyal@lab
export LOCATION="westus3"
export RESOURCE_GROUP="5-4-agc-demo"
export AKS_NAME="agcdemo-aks"
export ALB_NAMESPACE="alb-demo"
export ALB_NAME="alb-demo"
export APP_NAMESPACE="agc-sites"

az account set --subscription "$SUBSCRIPTION_ID"

# --- Providers, preview feature, CLI extensions (one-time per subscription) ---
for rp in Microsoft.ContainerService Microsoft.Network Microsoft.ServiceNetworking Microsoft.OperationsManagement; do
  az provider register --namespace "$rp" --wait
done
az feature register --namespace Microsoft.ContainerService --name AdvancedNetworkingPreview
az provider register --namespace Microsoft.ContainerService
az extension add --name aks-preview --upgrade --yes
az extension add --name alb         --upgrade --yes

# --- Create RG and AKS cluster (~7 min) ---
az group create -n "$RESOURCE_GROUP" -l "$LOCATION"

az aks create \
  -g "$RESOURCE_GROUP" -n "$AKS_NAME" -l "$LOCATION" \
  --kubernetes-version 1.34.4 \
  --network-plugin azure --network-plugin-mode overlay --network-dataplane cilium \
  --enable-acns --acns-advanced-networkpolicies L7 \
  --enable-gateway-api --enable-application-load-balancer \
  --enable-oidc-issuer --enable-workload-identity \
  --node-vm-size Standard_D4s_v5 --node-count 2 \
  --ssh-access disabled --generate-ssh-keys

az aks get-credentials -g "$RESOURCE_GROUP" -n "$AKS_NAME" --overwrite-existing

# --- Sanity check ---
kubectl get nodes
kubectl -n kube-system get pods -l app=alb-controller
kubectl get gatewayclass azure-alb-external

# --- WAF policy with DRS 2.1 (atomic ruleset swap, set to Prevention/Enabled) ---
if ! az network application-gateway waf-policy show \
      --name agc-waf-policy --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  az network application-gateway waf-policy create \
    --name agc-waf-policy --resource-group "$RESOURCE_GROUP" --location "$LOCATION" \
    --type OWASP --version 3.2
fi
az network application-gateway waf-policy update \
  --name agc-waf-policy --resource-group "$RESOURCE_GROUP" \
  --set "managedRules.managedRuleSets=[{\"ruleSetType\":\"Microsoft_DefaultRuleSet\",\"ruleSetVersion\":\"2.1\",\"ruleGroupOverrides\":[]}]" \
        policySettings.mode=Prevention policySettings.state=Enabled

export WAF_ID=$(az network application-gateway waf-policy show \
  --name agc-waf-policy --resource-group "$RESOURCE_GROUP" --query id -o tsv)
echo "WAF_ID=$WAF_ID"

# --- Grant ALB Controller MI 'Network Contributor' on the WAF policy ---
NODE_RG=$(az aks show -g "$RESOURCE_GROUP" -n "$AKS_NAME" --query nodeResourceGroup -o tsv)
ALB_PRINCIPAL_ID=$(az identity list -g "$NODE_RG" \
  --query "[?starts_with(name,'applicationloadbalancer')||starts_with(name,'azurealb')].principalId | [0]" -o tsv)
echo "ALB Controller principalId: $ALB_PRINCIPAL_ID"
az role assignment create \
  --assignee-object-id "$ALB_PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --role "Network Contributor" --scope "$WAF_ID"
```

You should see 2 Ready nodes, 2 Running `alb-controller` pods, `azure-alb-external` `Accepted=True`, a populated `WAF_ID`, and a successful role assignment.

---

## 2. Apply all Kubernetes manifests (cluster contents + WAF binding)

**Meet the cast — three sample tenants and a snooping client:**

We're standing up a fake "shared cluster" that hosts three businesses. They're stock Microsoft sample names you'll see in any Azure demo:

| Pod | Hostname | Role in the demo |
|---|---|---|
| **`contoso`** | `contoso.example.com` | Our headline tenant. Pretty much every demo step lands on contoso — it's the one we route to in 4a, the target WAF inspects in 4a-bonus, the pod we send `GET` and `POST` against in 4b, the destination of the east-west call in 4c, and the pod we exec into for 4d and 4e. |
| **`fabrikam`** | `fabrikam.example.com` | Second tenant. Used in 4a to prove multi-site routing (different `<h1>` in the response), and in 4c as the *unwhitelisted* east-west target (the `000` case). |
| **`adventure`** | `adventure.example.com` | Third tenant. Used only in 4a multi-site routing. Proves "adding a 3rd tenant is one more HTTPRoute, zero Azure-side work." |
| **`client`** | *(no hostname — in-cluster only)* | A `curlimages/curl` pod that just sleeps. Step 4c `kubectl exec`s into it to make pod-to-pod calls. This is how we demo east-west enforcement. |

Each tenant is one nginx pod listening on **port 8080** with site-specific HTML (`Hello from Contoso`, etc.) so we can read the response body and prove which backend served it. We don't actually own `*.example.com` — step 4 forges the `Host:` header with `curl --resolve $IP`.

**What this block does, at a glance:**

One `kubectl apply` lays down every Kubernetes object the demo needs. Read the manifest as **six layers** stacked on top of each other:

| # | Layer | What it does |
|---|---|---|
| 1 | **Two namespaces** | `$ALB_NAMESPACE` for the AGC frontend intent (platform team), `$APP_NAMESPACE` for workloads + policies (app team). Mirrors the ownership boundary AGC docs recommend. |
| 2 | **`ApplicationLoadBalancer` CR** | The *declaration of intent* that makes AGC come into existence. Empty `associations: []` = managed-by-ALB mode → AKS auto-creates the subnet, AGC resource, and workload-identity federation. **7 lines of YAML → a real Azure load balancer.** |
| 3 | **contoso, fabrikam, adventure + client pod** | Three nginx tenants (each with their own ConfigMap-backed HTML) and one curl pod for east-west tests. Pods are labelled `site:<name>` so the L7 policy can select them. |
| 4 | **Gateway + 3 HTTPRoutes** | One Gateway on port 80; three `HTTPRoute`s pinning `contoso.example.com`, `fabrikam.example.com`, and `adventure.example.com` to their respective Services. **One public IP, three sites.** |
| 5 | **4 `CiliumNetworkPolicy` objects** | The L7 lockdown. Additive whitelists on top of default-deny. *Detail below.* |
| 6 | **`WebApplicationFirewallPolicy` CRD** | The Kubernetes-side binding that attaches the WAF policy from step 1 to the Gateway. Scoped Gateway-wide → all three tenants protected. |

**The four Cilium policies, in plain English:**

| # | Policy | What it does | Why it's there | Demonstrated in |
|---|---|---|---|---|
| 1 | **`default-deny-all`** | Drops every packet in and out of every pod in `$APP_NAMESPACE`. Nothing works after this alone — intentional. | The foundation of zero-trust. Everything else is an additive carve-out on top. *Syntax tell:* `ingress: [{}]` (one empty rule = deny-all) ≠ `ingress: []` (no rule = no-op). | 4d (the silent timeout to bing.com) |
| 2 | **`allow-dns-egress`** | Lets every pod make DNS lookups against kube-dns (port 53, the standard DNS port). | Without it nothing in Kubernetes works — service discovery, controllers, every client library breaks. The minimum carve-out you have to add. | 4e (nslookup succeeds) |
| 3 | **`allow-agc-l7-get-only`** | The three tenant pods accept inbound on 8080, but only `GET /` and `GET /products`. Anything else is dropped with a Cilium-synthesized 403 before nginx ever sees it. | The **north-south** allow. This is what turns AGC's "any HTTP method gets in" into "only the methods the app actually serves get in." (Sources are `world` AND `cluster` because AGC traffic enters via a node-local hop tagged `cluster` — caught us during build.) | 4b (`POST /` → 403, `GET /products` → 404 from nginx) |
| 4 | **`client-may-call-contoso-get-only`** | `client` pod is allowed to call `contoso` pod on `GET /` only. Nothing else east-west works. | The **east-west** allow. Cilium policies are additive — both source-egress AND destination-ingress must permit. That's why 4c gets three different verdicts (`200`, `403`, `000`) from three different policy interactions. | 4c (the three-verdict pod-to-pod test) |

**Things to remember when you're running step 4:**

- All four pods live in `$APP_NAMESPACE` (`agc-sites`). All Cilium policies and the WAF binding scope to that namespace / the Gateway.
- **Labels matter.** Each tenant has `site: <name>` — that's what `allow-agc-l7-get-only` matches on. `client` has `app: client` — that's what `client-may-call-contoso-get-only` matches on. If a customer asks "how do I add a 4th tenant?" the answer is *one HTTPRoute + add the new value to the `site` selector*.
- **Only `GET /` and `GET /products` are whitelisted** for the three tenants. Everything else returns 403 — that's the punchline of 4b.
- **Only `client → contoso GET /` is whitelisted** east-west. `client → contoso POST` returns 403 (L7 deny). `client → fabrikam` times out as `000` (L4 deny — no policy whitelists this pair at all). That distinction is the punchline of 4c.

**Operational note on WAF:** runs in **Prevention** for prod, **Detection** for tuning — one CLI flag flips between them. Can also be scoped per-`HTTPRoute` for per-tenant rollout.

**After applying, we wait for two green lights:**

- ALB CR reaches `Deployment=True` (AGC frontend provisioned, ~5 min).
- WAF CRD reaches `Programmed=True` (WAF live on the Gateway).

When both are true, the demo is ready.

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata: { name: $ALB_NAMESPACE }
---
apiVersion: v1
kind: Namespace
metadata: { name: $APP_NAMESPACE }
---
apiVersion: alb.networking.azure.io/v1
kind: ApplicationLoadBalancer
metadata: { name: $ALB_NAME, namespace: $ALB_NAMESPACE }
spec:
  associations: []
---
apiVersion: v1
kind: ConfigMap
metadata: { name: contoso-html, namespace: $APP_NAMESPACE }
data:
  index.html: |
    <html><body><h1>Hello from Contoso</h1><p>Served from contoso.example backend</p></body></html>
  default.conf: |
    server { listen 8080; root /usr/share/nginx/html; index index.html; }
---
apiVersion: v1
kind: ConfigMap
metadata: { name: fabrikam-html, namespace: $APP_NAMESPACE }
data:
  index.html: |
    <html><body><h1>Hello from Fabrikam</h1><p>Served from fabrikam.example backend</p></body></html>
  default.conf: |
    server { listen 8080; root /usr/share/nginx/html; index index.html; }
---
apiVersion: v1
kind: ConfigMap
metadata: { name: adventure-html, namespace: $APP_NAMESPACE }
data:
  index.html: |
    <html><body><h1>Hello from Adventure Works</h1><p>Served from adventure.example backend</p></body></html>
  default.conf: |
    server { listen 8080; root /usr/share/nginx/html; index index.html; }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: contoso, namespace: $APP_NAMESPACE, labels: { app: contoso, site: contoso } }
spec:
  replicas: 1
  selector: { matchLabels: { app: contoso } }
  template:
    metadata: { labels: { app: contoso, site: contoso } }
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports: [{ containerPort: 8080 }]
          volumeMounts:
            - { name: html, mountPath: /usr/share/nginx/html }
            - { name: conf, mountPath: /etc/nginx/conf.d }
      volumes:
        - name: html
          configMap: { name: contoso-html, items: [{ key: index.html, path: index.html }] }
        - name: conf
          configMap: { name: contoso-html, items: [{ key: default.conf, path: default.conf }] }
---
apiVersion: v1
kind: Service
metadata: { name: contoso, namespace: $APP_NAMESPACE }
spec:
  selector: { app: contoso }
  ports: [{ port: 8080, targetPort: 8080 }]
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: fabrikam, namespace: $APP_NAMESPACE, labels: { app: fabrikam, site: fabrikam } }
spec:
  replicas: 1
  selector: { matchLabels: { app: fabrikam } }
  template:
    metadata: { labels: { app: fabrikam, site: fabrikam } }
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports: [{ containerPort: 8080 }]
          volumeMounts:
            - { name: html, mountPath: /usr/share/nginx/html }
            - { name: conf, mountPath: /etc/nginx/conf.d }
      volumes:
        - name: html
          configMap: { name: fabrikam-html, items: [{ key: index.html, path: index.html }] }
        - name: conf
          configMap: { name: fabrikam-html, items: [{ key: default.conf, path: default.conf }] }
---
apiVersion: v1
kind: Service
metadata: { name: fabrikam, namespace: $APP_NAMESPACE }
spec:
  selector: { app: fabrikam }
  ports: [{ port: 8080, targetPort: 8080 }]
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: adventure, namespace: $APP_NAMESPACE, labels: { app: adventure, site: adventure } }
spec:
  replicas: 1
  selector: { matchLabels: { app: adventure } }
  template:
    metadata: { labels: { app: adventure, site: adventure } }
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports: [{ containerPort: 8080 }]
          volumeMounts:
            - { name: html, mountPath: /usr/share/nginx/html }
            - { name: conf, mountPath: /etc/nginx/conf.d }
      volumes:
        - name: html
          configMap: { name: adventure-html, items: [{ key: index.html, path: index.html }] }
        - name: conf
          configMap: { name: adventure-html, items: [{ key: default.conf, path: default.conf }] }
---
apiVersion: v1
kind: Service
metadata: { name: adventure, namespace: $APP_NAMESPACE }
spec:
  selector: { app: adventure }
  ports: [{ port: 8080, targetPort: 8080 }]
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: client, namespace: $APP_NAMESPACE, labels: { app: client, role: client } }
spec:
  replicas: 1
  selector: { matchLabels: { app: client } }
  template:
    metadata: { labels: { app: client, role: client } }
    spec:
      containers:
        - name: curl
          image: curlimages/curl:8.10.1
          command: ["sleep", "infinity"]
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: gateway-01
  namespace: $APP_NAMESPACE
  annotations:
    alb.networking.azure.io/alb-namespace: $ALB_NAMESPACE
    alb.networking.azure.io/alb-name: $ALB_NAME
spec:
  gatewayClassName: azure-alb-external
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes: { namespaces: { from: Same } }
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: contoso-route, namespace: $APP_NAMESPACE }
spec:
  parentRefs: [{ name: gateway-01 }]
  hostnames: ["contoso.example.com"]
  rules:
    - backendRefs: [{ name: contoso, port: 8080 }]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: fabrikam-route, namespace: $APP_NAMESPACE }
spec:
  parentRefs: [{ name: gateway-01 }]
  hostnames: ["fabrikam.example.com"]
  rules:
    - backendRefs: [{ name: fabrikam, port: 8080 }]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: adventure-route, namespace: $APP_NAMESPACE }
spec:
  parentRefs: [{ name: gateway-01 }]
  hostnames: ["adventure.example.com"]
  rules:
    - backendRefs: [{ name: adventure, port: 8080 }]
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: { name: default-deny-all, namespace: $APP_NAMESPACE }
spec:
  endpointSelector: {}
  ingress:
    - {}
  egress:
    - {}
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: { name: allow-dns-egress, namespace: $APP_NAMESPACE }
spec:
  endpointSelector: {}
  egress:
    - toEndpoints:
        - matchLabels:
            "k8s:io.kubernetes.pod.namespace": kube-system
            "k8s:k8s-app": kube-dns
      toPorts:
        - ports: [{ port: "53", protocol: ANY }]
          rules:
            dns: [{ matchPattern: "*" }]
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: { name: allow-agc-l7-get-only, namespace: $APP_NAMESPACE }
spec:
  endpointSelector:
    matchExpressions:
      - { key: site, operator: In, values: [contoso, fabrikam, adventure] }
  ingress:
    - fromEntities: [world, cluster]
      toPorts:
        - ports: [{ port: "8080", protocol: TCP }]
          rules:
            http:
              - { method: "GET", path: "/" }
              - { method: "GET", path: "/products" }
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: { name: client-may-call-contoso-get-only, namespace: $APP_NAMESPACE }
spec:
  endpointSelector: { matchLabels: { app: client } }
  egress:
    - toEndpoints: [{ matchLabels: { app: contoso } }]
      toPorts:
        - ports: [{ port: "8080", protocol: TCP }]
          rules:
            http:
              - { method: "GET", path: "/" }
---
apiVersion: alb.networking.azure.io/v1
kind: WebApplicationFirewallPolicy
metadata:
  name: agc-gateway-waf
  namespace: $APP_NAMESPACE
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: gateway-01
    namespace: $APP_NAMESPACE
  webApplicationFirewall:
    id: $WAF_ID
EOF

# --- Wait for everything to be ready (~5 min for AGC frontend) ---
kubectl wait --for=condition=Deployment=True \
  applicationloadbalancer/$ALB_NAME -n $ALB_NAMESPACE --timeout=10m

for d in contoso fabrikam adventure client; do
  kubectl -n $APP_NAMESPACE rollout status deployment/$d
done

kubectl get cnp -n $APP_NAMESPACE     # all 4 should show VALID=True
sleep 30
kubectl get webapplicationfirewallpolicy -n $APP_NAMESPACE agc-gateway-waf \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")]}{"
"}'
```

Expected: ALB CR `Deployment=True`, all 4 CNPs `VALID=True`, WAF `Programmed=True`. Step 4 is ready.

> **Troubleshooting:** if the WAF CRD shows `DeploymentFailed` with `LinkedAuthorizationFailed`, the role assignment from step 1 hadn't propagated when the controller first reconciled. Force a re-reconcile:
>
> ```bash
> kubectl delete webapplicationfirewallpolicy -n $APP_NAMESPACE agc-gateway-waf
> # then re-apply just that CRD from the block above
> ```

---

## 4. Test it — the actual demo

**Setup is over. From here on, every command demonstrates a customer-facing behavior of AGC and ACNS.** This is the section the audience came for. Don't rush it.

### The arc of step 4 in one paragraph

> *Setup built two things: an Azure-managed L7 load balancer (AGC) wired to three sample tenants, and a set of Cilium L7 policies (ACNS) clamped down on every pod inside the cluster. Step 4 proves both layers do exactly what we said. **4a shows AGC routing internet traffic in; 4a-bonus turns on Azure WAF on AGC to block OWASP-class attacks at the edge.** **4b–4e show ACNS deciding what traffic, from any source, is allowed to flow inside the cluster.** AGC is the front door. With WAF, it's a metal detector at the front door. ACNS is the security guard at every interior door.*

### Each `### 4x.` subsection has the same shape

1. Mini context table — which layer this test exercises.
2. **What we're testing** — one line, the action.
3. **What it shows** — high-level bullets: why this matters, what to watch for.
4. The command.
5. Expected output.
6. **What the output means** — line-by-line interpretation.
7. Verdict + takeaway.

### Keep this table on screen during step 4:

| Tests | Layer being demonstrated | What's enforcing | Direction |
|---|---|---|---|
| **4a** Multi-site routing | **AGC** (the front door) | Gateway API `HTTPRoute` hostname matching on the AGC frontend | North-south: internet → cluster |
| **4a-bonus** SQLi / path-traversal blocked at the edge | **AGC + Azure WAF** (DRS 2.1) | `WebApplicationFirewallPolicy` CRD bound to the Gateway | North-south: internet → AGC (request never reaches the pod) |
| **4b** GET vs POST/PUT/DELETE, /products vs /admin | **ACNS L7** (the bouncer at the pod door) | `CiliumNetworkPolicy` L7 rules at the contoso/fabrikam/adventure pod | North-south *behind* AGC: AGC → pod |
| **4c** client → contoso GET/POST, client → fabrikam | **ACNS L7** (east-west) | Same `CiliumNetworkPolicy` L7 rules, applied to in-cluster pod-to-pod | **East-west: pod ↔ pod** |
| **4d** Backend pod → bing.com | **ACNS** default-deny egress | `default-deny-all` CNP at the pod | East-west out: pod → internet |
| **4e** DNS still resolves | **ACNS** carve-out | `allow-dns-egress` CNP | East-west to kube-dns |

> *"AGC brings the request into the cluster — you'll see that in 4a, and you'll see AGC's WAF reject malicious traffic at the edge in 4a-bonus. From 4b on, ACNS decides what happens once that request is inside: behind AGC (4b), pod-to-pod (4c), and outbound (4d/4e)."*

### Set up the test variables

Grab the AGC FQDN once — every test below pins to this IP via `curl --resolve`, since we don't own `*.example.com`:

```bash
FQDN=$(kubectl get gateway gateway-01 -n $APP_NAMESPACE -o jsonpath='{.status.addresses[0].value}')
IP=$(getent hosts "$FQDN" | awk '{print $1}' | head -1)
echo "$FQDN -> $IP"
```

**Expected output** (FQDN and IP will differ each run):

```text
dae7c5atdqguhwa0.fz13.alb.azure.com -> 20.238.208.7
```

**What it proves:**

- `FQDN` populated → AGC frontend has been provisioned and the ALB Controller has written it back into `Gateway.status.addresses[]`.
- `IP` populated → public DNS already resolves the AGC hostname (Azure publishes it the moment AGC is ready).
- `20.x` is a Microsoft-owned range. Always use the FQDN in real configs — the IP is Azure-managed and can change.

### 4a. Multi-site routing — AGC bringing traffic *into* the cluster

| Tests | Layer | What's enforcing | Direction |
|---|---|---|---|
| **4a** Multi-site routing | **AGC** (the front door) | Gateway API `HTTPRoute` hostname matching on the AGC frontend | North-south: internet → cluster |

**What we're testing:** Three hostnames pointed at the same AGC public IP. We send a `GET /` to each one and check which backend pod replies.

**What it shows:**

- AGC is a single managed L7 frontend doing host-based routing for multiple tenants on one public IP — same `$IP` for every request, only the `Host:` header differs.
- The Kubernetes-side surface is upstream Gateway API. Three `HTTPRoute` objects, no AGC-specific YAML in the app team's hands. Adding a fourth tenant is one more `HTTPRoute`.
- This replaces a DIY ingress controller running on cluster nodes. AGC is the "bringing traffic *into* the cluster" half of the demo; 4b–4e show what ACNS does once the traffic is inside.

```bash
for h in contoso fabrikam adventure; do
  echo "[$h.example.com]"
  curl -s --resolve $h.example.com:80:$IP http://$h.example.com/
  echo
done
```

**Expected output:**

```text
[contoso.example.com]
<html><body><h1>Hello from Contoso</h1><p>Served from contoso.example backend</p></body></html>

[fabrikam.example.com]
<html><body><h1>Hello from Fabrikam</h1><p>Served from fabrikam.example backend</p></body></html>

[adventure.example.com]
<html><body><h1>Hello from Adventure Works</h1><p>Served from adventure.example backend</p></body></html>
```

**What the output means:**

- Same public IP for all three; only the `Host:` header differed → L7 hostname-based routing on the AGC frontend, exactly as advertised.
- Each `<h1>Hello from <site></h1>` line confirms a different backend pod served the request — three tenants, one frontend.
- ACNS is silently waving these through because `GET /` is in its whitelist. We'll see ACNS actively *deny* in 4b.

> **Verdict:** AGC brought traffic in (host-based routing on a single public IP). ACNS allowed it through (`GET /` is in the whitelist).

**Takeaway** — *"One flag at cluster create time, one Gateway+HTTPRoute YAML, and you have a managed multi-tenant L7 frontend that's invisible to your app teams."*

### 4a-bonus. Add WAF to AGC — the AGC superpower for ACNS customers

| Tests | Layer | What's enforcing | Direction |
|---|---|---|---|
| **4a-bonus** SQLi / path-traversal payload at the edge | **AGC + Azure WAF** (managed Default Rule Set 2.1) | `WebApplicationFirewallPolicy` CRD → `SecurityPolicy` → Azure WAF policy | North-south: internet → AGC (request never reaches the pod) |

**What we're testing:** One benign request and two malicious ones (path-traversal payload, classic SQLi tautology), all hitting the same `GET /` path on contoso. AGC + Azure WAF inspects each one against the managed Default Rule Set 2.1 before forwarding.

**What WAF actually adds, in plain English:**

Up to this point, AGC has been doing host-based routing — it reads the `Host:` header and forwards every request to the right pod. WAF turns that same front door into a **metal detector**: AGC now opens up every incoming request and checks the URL, query string, headers, and body against a managed library of attack signatures (SQL injection, cross-site scripting, path traversal, command injection, the OWASP Top 10) before it forwards anything. If a request matches a known-bad pattern, AGC rejects it with a 403 and the pod never sees it.

**Why this matters:**

- **It's a managed service, not a project.** Microsoft writes the rules, tunes them, and keeps them current as new CVEs land. You don't maintain a ModSecurity ruleset, you don't tune false positives at 3am, you don't update signatures — it's the same managed Default Rule Set 2.1 that powers Front Door and standalone App Gateway WAF.
- **It catches things ACNS cannot.** ACNS L7 enforces *behavior* (this method on this path is allowed). WAF enforces *content* (this query string contains a SQLi pattern). A malicious `GET /?id=1 OR 1=1` is still a `GET /` — ACNS would happily forward it because the method and path are whitelisted. WAF sees the payload and blocks it.
- **It runs at the edge.** Malicious requests die at the AGC frontend, not at the pod. Your application code, your nginx, your business logic — none of it ever sees an attack signature. That's less attack surface, less log noise, less load on the cluster.
- **It's two YAMLs.** One Azure WAF policy + one `WebApplicationFirewallPolicy` CRD bound to the Gateway. We wired this up in step 1 + step 2; right now it's `Programmed=True` and scoped Gateway-wide, so all three tenants are protected automatically.

**Why both layers exist** (have this table on screen during the test):

| Threat | AGC WAF (edge) | ACNS L7 (pod) |
|---|---|---|
| `?text=/etc/passwd` path-traversal payload from internet | **Blocks (DRS rule match)** | Wouldn't have triggered (path is `/`, method is GET — passes ACNS) |
| `POST /` from internet | Forwards (no WAF rule against bare POST) | **Blocks (method not in whitelist)** |
| `POST /` from a *compromised pod inside the cluster* | Doesn't see it | **Blocks (4c will prove this)** |
| Zero-day SQLi against `/products?id=...` | **Blocks (DRS pattern match)** | Wouldn't catch (path is allowed) |

**Now run the actual test — one benign request, two malicious:**

> **If you're running this in a *fresh Cloud Shell tab*, `$APP_NAMESPACE` and `$IP` won't be set.** Cloud Shell doesn't share environment variables between tabs — each tab is its own bash process with its own environment. The block below re-exports the namespace and re-derives the AGC FQDN+IP so `curl --resolve` has something to pin to. The `dig` fallback covers the case where `getent` returns empty (happens occasionally in Cloud Shell).
>
> ```bash
> export APP_NAMESPACE="agc-sites"
> FQDN=$(kubectl get gateway gateway-01 -n $APP_NAMESPACE -o jsonpath='{.status.addresses[0].value}')
> IP=$(getent hosts "$FQDN" | awk '{print $1}' | head -1)
> [ -z "$IP" ] && IP=$(dig +short "$FQDN" | head -1)
> echo "FQDN=$FQDN  IP=$IP"
> ```

```bash
# Benign — should still get 200 from contoso (proves WAF doesn't break good traffic).
curl -s -o /dev/null -w "benign      GET /                       -> %{http_code}
" \
  --resolve contoso.example.com:80:$IP http://contoso.example.com/

# Malicious — path-traversal payload in query string. DRS 2.1 will match.
curl -s -o /dev/null -w "malicious   GET /?text=/etc/passwd      -> %{http_code}
" \
  --resolve contoso.example.com:80:$IP "http://contoso.example.com/?text=/etc/passwd"

# Malicious — classic SQLi tautology. DRS 2.1 will match.
curl -s -o /dev/null -w "malicious   GET /?id=1%20OR%201=1       -> %{http_code}
" \
  --resolve contoso.example.com:80:$IP "http://contoso.example.com/?id=1%20OR%201=1"
```

**Expected output:**

```text
benign      GET /                       -> 200
malicious   GET /?text=/etc/passwd      -> 403
malicious   GET /?id=1 OR 1=1           -> 403
```

**What the output means:**

- `200` on the benign GET → WAF didn't break the app. Same `GET /` we ran in 4a, still works.
- Both `403`s came from **AGC**, not Cilium. ACNS L7 wouldn't have caught either — both are GETs to `/`, which is in the ACNS whitelist. Without WAF at the edge, both would have reached nginx.
- AGC WAF caught the *signature-based* attack. ACNS L7 (in 4b) catches the *behavioral* attack. Two layers, two rule philosophies, both running automatically.
- WAF runs in **Prevention** for prod, **Detection** for tuning. One CLI flag flips between them. Scope per-`HTTPRoute` to roll out per-tenant.

**What WAF just did that we didn't have before:**

- **It read the request body, not just the envelope.** In 4a, AGC looked at the `Host:` header and forwarded. Here, AGC opened up the URL and query string, scanned them against thousands of OWASP-class attack patterns, and rejected two of three. Same managed frontend, brand-new security capability.
- **It blocked attacks ACNS would have let through.** Both malicious requests were `GET /` — ACNS's allow list says yes. WAF said no, because it inspects *content*, not just method and path. That's the gap WAF closes.
- **The attack never touched the pod.** No CPU spent, no log entries on contoso, no chance for the request to find a zero-day in nginx or your app code. The 403 was rendered by the AGC frontend itself.
- **You didn't write any rules.** The Default Rule Set 2.1 ships with the policy. Microsoft maintains it. Your job was two YAMLs (the Azure WAF policy in step 1, the `WebApplicationFirewallPolicy` CRD in step 2) — the rules came with the service.

> **Verdict:** AGC brought traffic in **and stopped malicious traffic at the edge** with Azure WAF (DRS 2.1). ACNS never had to look at the request — it died one layer earlier. Outer perimeter / inner perimeter, working together.

**Takeaway** — *"With AGC you don't pick between managed L7 ingress and WAF — you get both. Two YAMLs: a Gateway and a `WebApplicationFirewallPolicy`. Defense in depth, end to end."*

### 4b. ACNS L7 — deciding what traffic is *allowed* once it's inside

| Tests | Layer | What's enforcing | Direction |
|---|---|---|---|
| **4b** GET vs POST/PUT/DELETE, /products vs /admin | **ACNS L7** (the bouncer at the pod door) | `CiliumNetworkPolicy` L7 rules at the contoso/fabrikam/adventure pod | North-south *behind* AGC: AGC → pod |

**What we're testing:** Send seven requests through AGC to the contoso pod — four different methods at `/`, then three different paths with GET. AGC forwards all seven; ACNS at the pod decides which ones live or die.

**What it shows:**

- AGC delivers every request to the pod — that's its job as the L7 frontend. **ACNS L7 is what decides** whether each request lives or dies, based on actual HTTP method and path.
- Cilium has an HTTP-aware proxy in eBPF. It parses the request and matches against `allow-agc-l7-get-only` (only `GET` on `/` and `/products`).
- Watch the **403 vs 404 distinction**: a `403` is Cilium synthesizing a denial *before* nginx sees the request; a `404` means Cilium let the request through and nginx returned the 404 itself. Different layer doing the work, depending on the rule.
- A vanilla Kubernetes NetworkPolicy could not produce this — it can only allow or deny port 8080 wholesale. ACNS L7 lets you say "GET on 8080 yes, POST on 8080 no" — same port, different verb, different verdict.

```bash
for m in GET POST PUT DELETE; do
  curl -s -o /dev/null -w "$m / -> %{http_code}
" \
    --max-time 10 -X $m --resolve contoso.example.com:80:$IP http://contoso.example.com/
done
for p in / /products /admin; do
  curl -s -o /dev/null -w "GET $p -> %{http_code}
" \
    --max-time 10 --resolve contoso.example.com:80:$IP http://contoso.example.com$p
done
```

**Expected output:**

```text
GET / -> 200
POST / -> 403
PUT / -> 403
DELETE / -> 403
GET / -> 200
GET /products -> 404
GET /admin -> 403
```

**What the output means, line by line:**

| Line | Who decided | What happened | Why it happened | Why it matters |
|---|---|---|---|---|
| `GET / -> 200` | nginx | AGC routed → ACNS allowed → nginx served the page | `GET /` is one of the two paths whitelisted in `allow-agc-l7-get-only`, so Cilium's L7 proxy passed it through and nginx served the homepage normally. | The happy path. Customers' actual users see this. |
| `POST / -> 403` | **ACNS** | AGC routed → **ACNS rejected the method** → nginx never saw it | Same path, different verb. The whitelist only allows `GET`, so Cilium's L7 proxy synthesized a `403` itself before the request ever reached nginx. | Same port as GET. Vanilla L4 NetworkPolicy could not block this. |
| `PUT / -> 403` | **ACNS** | Same as POST | Same reason as POST — `PUT` isn't on the whitelist, so it's denied at the pod boundary. | Default-deny on methods. Only GET is whitelisted. |
| `DELETE / -> 403` | **ACNS** | Same as POST | Same reason as POST — `DELETE` isn't on the whitelist either. | Method-level enforcement at the pod boundary. |
| `GET /products -> 404` | **nginx** | AGC routed → ACNS *allowed* → nginx had no such file → returned 404 | `GET /products` is on the whitelist, so Cilium passed it through. nginx itself doesn't have a `/products` page in this demo, so *nginx* returned the 404 — proving the request actually reached the app. | **The proof point.** 404 means the request reached the app. ACNS is doing real L7 inspection, not blanket-blocking. |
| `GET /admin -> 403` | **ACNS** | AGC routed → **ACNS rejected the path** → nginx never saw `/admin` | Same method as the 200 case, but `/admin` isn't on the whitelist. Cilium denied it at the pod door — nginx never knew the request existed. | The bouncer at the door rejected it. nginx never knew it was coming. |

**The 403-vs-404 distinction is the headline.** Anyone can build "deny everything." Showing *"allow this method on this path, deny that method on that path, pass the rest untouched all the way to the app"* — with the responses coming from different layers depending on the rule — is the unique value of AGC + ACNS L7.

> **Verdict:** AGC brought traffic in (every request reached AGC and was forwarded — same port, same destination). ACNS denied four and allowed three, based on the actual HTTP method and path, with the 403s synthesized by Cilium and the 200/404 served by nginx.

**Takeaway** — *"AGC delivered all seven requests. ACNS decided which four to drop and which three to forward. AGC owns *getting traffic in*. ACNS owns *deciding what gets to flow*."*

### 4c. ACNS L7 east-west — same enforcement, pod-to-pod

| Tests | Layer | What's enforcing | Direction |
|---|---|---|---|
| **4c** client → contoso GET/POST, client → fabrikam | **ACNS L7** (east-west) | Same `CiliumNetworkPolicy` L7 rules, applied to in-cluster pod-to-pod | **East-west: pod ↔ pod** |

**What we're testing:** Three calls from the in-cluster `client` pod directly to `contoso` and `fabrikam` Services via cluster DNS. This is purely pod-to-pod traffic. Same Cilium L7 policies as 4b — but now the *source* is another pod, not the internet.

**What it shows:**

- The same Cilium L7 rules that protected contoso from internet traffic in 4b also protect it from *other pods* in the cluster. **Source-agnostic enforcement.**
- ACNS owns the east-west dimension end-to-end — identity-based, bidirectional whitelists at the pod level.
- Lateral movement (a compromised pod pivoting to richer ones inside the cluster) is the most dangerous attack pattern in Kubernetes. ACNS L7 is what gives you a defense once an attacker is already inside.
- Watch the **403 vs 000 distinction** — they tell two different stories. `403` means Cilium let TCP complete and the HTTP request arrive, then synthesized a denial. `000` means Cilium dropped the SYN before TCP ever completed. Different layer, both denied. In production this distinction is alertable — a 403 is a misbehaving caller you know about; a 000 is a peer that should have no business reaching this pod at all.

```bash
CLIENT=$(kubectl get pod -n $APP_NAMESPACE -l app=client -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n $APP_NAMESPACE $CLIENT -- curl -s -o /dev/null -w "client->contoso GET  -> %{http_code}
" --max-time 5 http://contoso:8080/
kubectl exec -n $APP_NAMESPACE $CLIENT -- curl -s -o /dev/null -w "client->contoso POST -> %{http_code}
" --max-time 5 -X POST http://contoso:8080/
kubectl exec -n $APP_NAMESPACE $CLIENT -- curl -s --ipv4 -o /dev/null -w "client->fabrikam     -> %{http_code}
" --max-time 5 http://fabrikam:8080/
```

**Expected output:**

```text
client->contoso GET  -> 200
client->contoso POST -> 403
client->fabrikam     -> 000
```

**What the output means:**

| Line | Who decided | What happened | Why it happened | What it tells the audience |
|---|---|---|---|---|
| `client->contoso GET -> 200` | nginx | Both `client-may-call-contoso-get-only` (egress on client) AND `allow-agc-l7-get-only` (ingress on contoso) permitted GET → nginx served | This is the *one* east-west path explicitly allowed: `client` is whitelisted to send `GET /` to `contoso`, and `contoso` is whitelisted to accept `GET /`. Both sides agree, so Cilium passes the request and nginx serves the homepage. | **Both ends must agree.** Cilium is enforcing identity-based, bidirectional whitelists. |
| `client->contoso POST -> 403` | **ACNS** | Cilium L7 proxy parsed HTTP, saw POST, synthesized 403 | Same source, same destination, same port — only the verb changed. The whitelist between `client` and `contoso` only allows `GET`, so Cilium opens the request, sees `POST`, and synthesizes a `403` itself before the packet reaches contoso. | Right pod, right port, **wrong method.** A compromised neighbor cannot escalate to dangerous methods even on services it can already reach. |
| `client->fabrikam -> 000` | **ACNS at L4** | TCP handshake never completed — Cilium silently dropped the SYN | There is no policy anywhere that whitelists `client → fabrikam`. Default-deny kicks in at the network layer — Cilium drops the SYN packet before TCP ever connects, so curl can't even start an HTTP request. That's why you see `000` (no HTTP response code) instead of `403`. | **No policy whitelists `client → fabrikam`.** Default-deny kicks in *before HTTP exists*. From the attacker's perspective, fabrikam might as well not exist. |

> **Verdict:** ACNS allowed the one whitelisted call, denied the wrong-method call at L7 with a 403, and denied the unknown-peer call at L4 with a silent drop.

**The takeaway to repeat to the customer:** *"AGC controls the front door of the building. ACNS controls every interior door. Even when an attacker is already inside the cluster — even when the attacker is the *source* of malicious traffic — ACNS still enforces the exact same method-and-path rules. There is no 'trusted east-west' in zero-trust, and ACNS is what makes that real."*

### 4d. ACNS default-deny egress — stopping pods from calling out

| Tests | Layer | What's enforcing | Direction |
|---|---|---|---|
| **4d** Backend pod → bing.com | **ACNS** default-deny egress | `default-deny-all` CNP at the pod | East-west out: pod → internet |

**What we're testing:** Up to this point everything we've shown is about traffic coming **in** to the cluster — AGC routing requests in (4a), ACNS deciding which methods are allowed in (4b), and one pod calling another pod inside the cluster (4c). Now we flip the direction. We're going to `exec` into a backend pod (contoso) and have it try to reach the public internet — `wget https://www.bing.com`. The expectation: it should fail, and fail *silently*.

**What it shows:**

- **This is the egress story.** Inbound is only half of zero-trust. The other half is: *if a pod gets compromised, can it phone home?* That's what we're testing.
- **Why egress matters so much.** Almost every modern Kubernetes attack ends the same way — the compromised pod calls out. Data exfiltration, downloading a second-stage payload, beaconing to a command-and-control server. If you cut egress, you break the attack chain even after the pod is owned.
- **Who's enforcing this.** ACNS owns this dimension entirely. The `default-deny-all` CiliumNetworkPolicy says *no pod talks to anything by default*, and we've only carved out two exceptions: DNS (so pods can resolve names) and the specific contoso → fabrikam call from 4c.
- **Why "silent" matters.** Cilium drops the connection at the kernel — no TCP reset, no ICMP unreachable, no helpful error. The pod just hangs until it times out. To an attacker this looks like a network black hole, which is itself a defense — they can't tell if the destination is blocked, down, or doesn't exist.

```bash
CONTOSO=$(kubectl get pod -n $APP_NAMESPACE -l app=contoso -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n $APP_NAMESPACE $CONTOSO -- wget -q -T 5 -O /dev/null https://www.bing.com
echo "rc=$?  (non-zero = blocked)"
```

**Expected output:**

```text
wget: download timed out
command terminated with exit code 1
rc=1  (non-zero = blocked)
```

**What the output means:**

Read the three lines top to bottom — they tell the whole story:

- **DNS resolution worked.** The fact that `wget` got past the name-lookup step and started trying to connect tells you kube-dns was reachable. That's our `allow-dns-egress` carve-out doing its job. So this is not "the cluster is broken" — it's "the cluster is locked down, with DNS deliberately allowed."
- **The TCP connection went nowhere.** `wget` got an IP for bing.com and sent a SYN packet. Cilium dropped it at the eBPF datapath. No reset, no ICMP error, no "connection refused" — just nothing. After 5 seconds wget gave up: `download timed out`. This is Cilium's documented [silent-drop behavior](https://docs.cilium.io/en/latest/security/policy/intro/#policy-deny-response-handling) for default-deny.
- **`rc=1` is the punchline.** That non-zero exit code is what the workload sees. **If this pod were compromised and trying to exfiltrate data, this is the moment the attack dies.** No data leaves. The attacker doesn't even get a useful error to retry against — just a black hole.
- **Notice what's enforcing this.** Not AGC. Not a firewall sitting outside the cluster. Cilium, in-kernel, on the same node as the pod. The decision is made before the packet ever leaves the host.

**In plain English — what just happened, and what it proves:**

A pod inside our cluster tried to reach bing.com. It couldn't. After 5 seconds it gave up.

That's the whole story. We didn't get an error message saying "blocked." We didn't get "connection refused." We got *nothing* — a hung connection that timed out. To anyone (or anything) sitting in that pod, the public internet just doesn't exist.

This proves three things:

- **Pods can't phone home by default.** Even if a pod gets compromised tomorrow, it can't reach the internet to download malware, exfiltrate data, or check in with an attacker's server.
- **The block is silent on purpose.** An attacker poking around inside a compromised pod can't tell whether the destination is blocked, down, or doesn't exist. That ambiguity slows them down.
- **Cilium did this, not a network appliance.** No firewall rules, no NAT gateway config, no perimeter device. Just a Kubernetes YAML applied to the cluster.

> **Verdict:** ACNS denied the TCP connection silently at the eBPF datapath because no egress allow rule whitelists the public internet.

**The takeaway to repeat to the customer:** *"AGC handles inbound. ACNS handles inbound *and* outbound. With four `CiliumNetworkPolicy` objects we've built default-deny in both directions plus surgical carve-outs for DNS, AGC ingress, and one specific east-west call. A compromised pod can't talk to the internet, can't move laterally, and can't send the wrong HTTP method to its allowed neighbors. That's a complete zero-trust posture, end to end."*

### 4e. ACNS DNS carve-out — proving the lockdown is *precise*, not blunt

| Tests | Layer | What's enforcing | Direction |
|---|---|---|---|
| **4e** DNS still resolves | **ACNS** carve-out | `allow-dns-egress` CNP | East-west to kube-dns |

**What we're testing:** This is the **exact same pod** we just used in 4d (`$CONTOSO`). The *only* things that change are the tool we run inside it and where it's headed:

| | 4d | 4e |
|---|---|---|
| Pod we exec into | `$CONTOSO` | `$CONTOSO` (same pod) |
| Tool | `wget` (opens a TCP connection) | `nslookup` (sends a UDP/53 DNS query) |
| Destination | `https://www.bing.com` (public internet) | `contoso.agc-sites.svc.cluster.local` (kube-dns, in-cluster) |
| Expected result | Silent timeout (denied) | Instant answer (allowed) |

Nothing about the pod or its policies changed between the two commands — same namespace, same four CiliumNetworkPolicies attached. **The only thing that flips the outcome is the destination.** 4d's destination matches no allow rule, so Cilium drops it. 4e's destination — kube-dns on UDP/53 — is exactly what `allow-dns-egress` carves out, so Cilium permits it.

**What it shows:**

- **This is the "we didn't just unplug the network" test.** A blanket default-deny is easy. Anyone can write one. The hard part — and the customer's actual ask — is keeping apps *functional* while denying everything else. 4d proved we deny. 4e proves we deny *surgically*.
- **Why DNS is the carve-out that matters.** If pods can't do DNS, nothing in Kubernetes works. Service discovery breaks, controllers break, every client library breaks. So the very first allow rule in any zero-trust setup is "let pods talk to kube-dns." That's exactly what `allow-dns-egress` does — and nothing else.
- **The contrast with 4d is the whole story.** Same pod, same policies. Change the destination from "public IP on the internet" to "kube-dns on UDP/53" and the outcome flips from silent-drop to instant-answer. **Same pod, opposite outcomes** — that precision is what production-grade zero-trust looks like.
- **And it's tightenable.** Today the rule allows DNS to any name (`matchPattern: '*'`). Swap that to `matchPattern: '*.svc.cluster.local'` and Cilium will start dropping the DNS *queries themselves* for anything outside the cluster — before they even leave the node. One-line YAML change.

```bash
kubectl exec -n $APP_NAMESPACE $CONTOSO -- nslookup contoso.agc-sites.svc.cluster.local
```

**Expected output:**

```text
Server:         10.0.0.10
Address:        10.0.0.10:53


Name:   contoso.agc-sites.svc.cluster.local
Address: 10.0.37.14
```

**What the output means:**

This output is the mirror image of 4d's. There, `wget` printed `download timed out` and `rc=1` — a connection that went nowhere. Here:

- **`Server: 10.0.0.10:53`** — that's the kube-dns ClusterIP, on port 53. The pod opened a UDP/53 socket to it and got a reply. **This is the packet that 4d's wget couldn't have sent and lived.** The only reason it worked is that `allow-dns-egress` says "UDP/53 to pods labeled `k8s-app=kube-dns` is allowed."
- **`Address: 10.0.37.14`** — a real DNS answer for the contoso Service. Not a timeout, not NXDOMAIN, not "I/O error." Service discovery is fully functional.
- **Why the result is different from 4d.** Literally the same pod ran both commands. Nothing about the pod, the namespace, or the policies changed between them. The only difference was where the packet was headed: bing.com (off the allow list → silent drop) vs kube-dns (on the allow list → forwarded normally). The decision is made per-packet, in-kernel, against the four CNPs.
- **That's the whole zero-trust posture in one comparison.** Default-deny everywhere, plus a small set of explicit carve-outs. Anything on the list works normally. Anything off the list dies silently in the kernel. No app changes, no sidecars, no agents — just policy.

**In plain English — what just happened, and what it proves:**

The same pod that couldn't reach bing.com a moment ago just looked up another pod's address inside the cluster — and got an answer instantly.

Nothing about the pod changed. Same name, same labels, same four policies attached. The only difference is *where the packet was going*. Bing.com isn't on our allow list, so Cilium dropped it. Kube-dns *is* on the allow list (that's the `allow-dns-egress` policy), so Cilium let it through.

This proves three things:

- **Default-deny doesn't break the cluster.** Apps can still find each other by name. Service discovery still works. The carve-out for DNS is the one tiny exception that keeps Kubernetes itself running.
- **The lockdown is precise, not blunt.** We're not unplugging the network. We're saying "these specific destinations are allowed, everything else is denied," and Cilium enforces that decision per-packet.
- **You can tighten it further any time.** Today DNS to any name is allowed. One YAML edit and you can restrict it to just `*.svc.cluster.local` — dropping DNS queries for outside names before they even leave the node.

> **Verdict:** ACNS allowed this one specific call (port 53 to kube-dns endpoints) because it's the carve-out we explicitly wrote.

**The takeaway to repeat to the customer:** *"We didn't break workloads' ability to discover services. We only blocked the actual data path to destinations that aren't on our allow list. That's the difference between 'lock it all down and break the app' and 'lock it all down and the app keeps working for the things you allowed.' And every one of those allow rules can be tightened further — down to specific FQDNs, methods, paths — with a one-line YAML change."*

---

## 5. Tear it down

One command. Deletes the parent RG, which cascades to the AKS cluster, the auto-created `MC_` group, the AGC resource, the subnet, and all networking. `--no-wait` returns the prompt immediately; the actual delete takes a few minutes.

```bash
az group delete -n "$RESOURCE_GROUP" --yes --no-wait
```

> **Now read the [PITCH.md](PITCH.md) wrap-up section** for the takeaways, Q&A talking points, next steps, and one-paragraph summary.

---

## Recap — what we just did (read this out at the end)

Walk the audience back through the demo in plain language. Hit each bullet:

**What we built:**
- A single AKS cluster with two add-ons turned on at create time: **AGC** (Application Gateway for Containers) for ingress and **ACNS L7** (Advanced Container Networking Services) for in-cluster policy.
- Three sample tenants — contoso, fabrikam, adventure — fronted by **one** AGC public IP and **one** Gateway, with three `HTTPRoute` objects routing by hostname.
- Four `CiliumNetworkPolicy` objects: default-deny, DNS carve-out, an L7 GET-only allow for AGC traffic, and an east-west allow from the client pod to contoso.
- An **Azure WAF policy** with the managed Default Rule Set 2.1, attached to the Gateway via a `WebApplicationFirewallPolicy` CRD.

**What we proved, test by test:**
- **4a — AGC routes by hostname.** Same public IP, three different `<h1>Hello from <site></h1>` responses. One Gateway + three `HTTPRoute`s replaced what used to be a DIY ingress controller.
- **4a-bonus — AGC has WAF built in.** A SQLi payload and a path-traversal payload both hit `403` *at AGC*. nginx never saw them. Same `GET /` from 4a still returned `200` — WAF didn't break the app.
- **4b — ACNS L7 inspects HTTP.** `POST /` returned `403` (synthesized by Cilium); `GET /products` returned `404` (served by nginx). **403 from Cilium, 404 from nginx** — proof that L7 inspection is real, not blanket-block.
- **4c — ACNS enforces east-west too.** Pod-to-pod enforcement. `client → contoso GET` got `200`, `client → contoso POST` got `403`, `client → fabrikam` got `000` (TCP never completed). Three calls, three different layers of denial.
- **4d — ACNS blocks egress by default.** A backend pod tried to reach bing.com, got a silent timeout. No exfil, no C2.
- **4e — The lockdown is precise.** Same pod still resolves DNS through kube-dns, because we explicitly allowed it.

**The one-line story:**
- **AGC brings traffic *into* the cluster.** With WAF, AGC also blocks signature-based attacks at the edge.
- **ACNS L7 controls how traffic flows *within* the cluster** — north-south behind AGC, east-west pod-to-pod, and outbound to the internet.
- Two add-ons, one zero-trust posture, end to end.

**Why this matters to the customer:**
- Managed Azure load balancer instead of a DIY ingress controller running on cluster nodes.
- Native Azure WAF on AKS L7 ingress — only available through AGC.
- L7 enforcement at the pod with **identity-based, eBPF-speed** policy — no sidecar, no proxy injection, no per-pod CPU overhead.
- Everything driven by upstream Kubernetes APIs (Gateway API, NetworkPolicy CRDs) plus one Azure CRD per WAF policy.

---

## Q&A reference links (for live demo)

Keep this section open in another tab during Q&A.

- AKS + Cilium L7 policies — <https://learn.microsoft.com/azure/aks/how-to-apply-l7-policies> (`aka.ms/aks/l7-policies`)
- AGC ALB Controller add-on quickstart — <https://learn.microsoft.com/azure/application-gateway/for-containers/quickstart-deploy-application-gateway-for-containers-alb-controller-addon>
- AGC multi-site hosting (Gateway API) — <https://learn.microsoft.com/azure/application-gateway/for-containers/how-to-multiple-site-hosting-gateway-api>
- AGC components / connectivity / egress — <https://learn.microsoft.com/azure/application-gateway/for-containers/application-gateway-for-containers-components#connectivity>
- Azure WAF on AGC — <https://learn.microsoft.com/azure/application-gateway/for-containers/web-application-firewall-overview>
- Cilium HTTP-aware policy spec — <https://docs.cilium.io/en/stable/security/policy/language/#http>
- **Customer-facing self-service version of this demo:** <https://github.com/darshils2001/agc-l7-workshop>

