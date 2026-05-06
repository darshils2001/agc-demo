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
- Pod-to-pod calls hit the same enforcement, with **no AGC in the path** (4c).
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

**Three things worth knowing** while the cluster builds:

- **L7 is preview-gated.** `AdvancedNetworkingPreview` must be registered or the L7 flag above is rejected. The four resource providers cover AKS, VNets, the AGC backend (`ServiceNetworking`), and ACNS telemetry.
- **WAF gets a CLI dance.** AGC WAF only supports DRS 2.1, but `waf-policy create` only accepts OWASP. We create with OWASP, then atomically swap the rule set to DRS 2.1 (and flip to Prevention/Enabled) in one update. The bash handles this for you.
- **The role assignment is mandatory.** The ALB Controller's managed identity needs `Network Contributor` on the WAF policy to attach it from the Kubernetes side. Without it, the WAF CRD fails with `LinkedAuthorizationFailed`. The MI naming varies by add-on version (`applicationloadbalancer-*` for GA, `azurealb-*` for older preview), so the script matches either.

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

**What this block does, at a glance:**

One `kubectl apply` lays down every Kubernetes object the demo needs. Read the manifest as **six layers** stacked on top of each other:

| # | Layer | What it does |
|---|---|---|
| 1 | **Two namespaces** | `$ALB_NAMESPACE` for the AGC frontend intent (platform team), `$APP_NAMESPACE` for workloads + policies (app team). Mirrors the ownership boundary AGC docs recommend. |
| 2 | **`ApplicationLoadBalancer` CR** | The *declaration of intent* that makes AGC come into existence. Empty `associations: []` = managed-by-ALB mode → AKS auto-creates the subnet, AGC resource, and workload-identity federation. **7 lines of YAML → a real Azure load balancer.** |
| 3 | **3 nginx tenants + 1 client pod** | Each tenant has site-specific HTML so 4a can prove which backend served the response. The `client` curl pod is for east-west tests in 4c. The `site:<name>` label is what Cilium policies match on. |
| 4 | **Gateway + 3 HTTPRoutes** | One Gateway on port 80, three `HTTPRoute`s binding `<site>.example.com` to each backend. **One public IP, three sites.** Adding a 4th tenant is one more HTTPRoute. |
| 5 | **4 `CiliumNetworkPolicy` objects** | The L7 lockdown. Additive whitelists on top of default-deny. *Detail below.* |
| 6 | **`WebApplicationFirewallPolicy` CRD** | The Kubernetes-side binding that attaches the WAF policy from step 1 to the Gateway. Scoped Gateway-wide → all three tenants protected. |

**The four Cilium policies, in plain English:**

1. **`default-deny-all`** — turn off the cluster. Every pod in `$APP_NAMESPACE` denies all ingress + egress. Nothing works after this alone (intentional). *Syntax tell:* `ingress: [{}]` (one empty rule = deny-all) ≠ `ingress: []` (no rule = no-op).
2. **`allow-dns-egress`** — turn DNS back on. Without it, the apps work but can't find each other.
3. **`allow-agc-l7-get-only`** — the **north-south** allow. The three tenant pods accept inbound 8080, but only `GET /` and `GET /products`. Anything else gets a Cilium-synthesized 403 *before nginx sees it*. (Both `world` and `cluster` are listed as sources because AGC traffic enters via a node-local hop tagged `cluster`, not `world` — caught us during build.)
4. **`client-may-call-contoso-get-only`** — the **east-west** allow. `client` may call `contoso` on `GET /` only. Cilium policies are additive: both source-egress AND destination-ingress must permit, which is why 4c shows three different verdicts (`200`, `403`, `000`) for three different policy interactions.

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
| **4c** client → contoso GET/POST, client → fabrikam | **ACNS L7** (east-west, no AGC involved) | Same `CiliumNetworkPolicy` L7 rules, applied to in-cluster pod-to-pod | **East-west: pod ↔ pod** |
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

### 4a-bonus. Add WAF to AGC — the AGC superpower that ACNS alone can't give you

| Tests | Layer | What's enforcing | Direction |
|---|---|---|---|
| **4a-bonus** SQLi / path-traversal payload at the edge | **AGC + Azure WAF** (managed Default Rule Set 2.1) | `WebApplicationFirewallPolicy` CRD → `SecurityPolicy` → Azure WAF policy | North-south: internet → AGC (request never reaches the pod) |

**What we're testing:** One benign request and two malicious ones (path-traversal payload, classic SQLi tautology), all hitting the same `GET /` path on contoso. AGC + Azure WAF inspects each one against the managed Default Rule Set 2.1 before forwarding.

**What it shows:**

- **WAF is what AGC unlocks for ACNS customers.** There's no DIY ingress path to native Azure WAF on AKS L7 ingress — choosing AGC for managed Gateway API gets you native WAF for free.
- WAF on AGC uses the Azure-managed Default Rule Set 2.1 — same OWASP-class signatures as Front Door and standalone App Gateway WAF.
- WAF runs at the **edge**; ACNS L7 runs at the **pod**. Two layers, two rule philosophies (signatures from the internet vs. behaviors from any source). Customers need both.
- We wired this up in 3f — the `WebApplicationFirewallPolicy` CRD is `Programmed=True`, scoped Gateway-wide so all three tenants are protected.

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
curl -s -o /dev/null -w "benign      GET /                       -> %{http_code}\n" \
  --resolve contoso.example.com:80:$IP http://contoso.example.com/

# Malicious — path-traversal payload in query string. DRS 2.1 will match.
curl -s -o /dev/null -w "malicious   GET /?text=/etc/passwd      -> %{http_code}\n" \
  --resolve contoso.example.com:80:$IP "http://contoso.example.com/?text=/etc/passwd"

# Malicious — classic SQLi tautology. DRS 2.1 will match.
curl -s -o /dev/null -w "malicious   GET /?id=1%20OR%201=1       -> %{http_code}\n" \
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

> **Verdict:** AGC brought traffic in **and stopped malicious traffic at the edge** with Azure WAF (DRS 2.1). ACNS never had to look at the request — it died one layer earlier. Outer perimeter / inner perimeter, working together.

**Takeaway** — *"With AGC you don't pick between managed L7 ingress and WAF — you get both. Two YAMLs: a Gateway and a `WebApplicationFirewallPolicy`. Defense in depth, end to end."*

### 4b. ACNS L7 — deciding what traffic is *allowed* once it's inside

| Tests | Layer | What's enforcing | Direction |
|---|---|---|---|
| **4b** GET vs POST/PUT/DELETE, /products vs /admin | **ACNS L7** (the bouncer at the pod door) | `CiliumNetworkPolicy` L7 rules at the contoso/fabrikam/adventure pod | North-south *behind* AGC: AGC → pod |

**What we're testing:** Send seven requests through AGC to the contoso pod — four different methods at `/`, then three different paths with GET. AGC forwards all seven; ACNS at the pod decides which ones live or die.

**What it shows:**

- AGC doesn't filter by method or path — it's a load balancer, not a security product. Every request reaches the pod's network interface.
- **ACNS L7 is what decides.** Cilium has an HTTP-aware proxy in eBPF. It parses the actual method and path and matches against `allow-agc-l7-get-only` (only `GET` on `/` and `/products`).
- Watch the **403 vs 404 distinction**: a `403` is Cilium synthesizing a denial *before* nginx sees the request; a `404` means Cilium let the request through and nginx returned the 404 itself. Different layer doing the work, depending on the rule.
- A vanilla Kubernetes NetworkPolicy could not produce this — it can only allow or deny port 8080 wholesale. ACNS L7 lets you say "GET on 8080 yes, POST on 8080 no" — same port, different verb, different verdict.

```bash
for m in GET POST PUT DELETE; do
  curl -s -o /dev/null -w "$m / -> %{http_code}\n" \
    --max-time 10 -X $m --resolve contoso.example.com:80:$IP http://contoso.example.com/
done
for p in / /products /admin; do
  curl -s -o /dev/null -w "GET $p -> %{http_code}\n" \
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

| Line | Who decided | What happened | Why it matters |
|---|---|---|---|
| `GET / -> 200` | nginx | AGC routed → ACNS allowed (`GET /` in whitelist) → nginx served the page | The happy path. Customers' actual users see this. |
| `POST / -> 403` | **ACNS** | AGC routed → **ACNS rejected the method** → nginx never saw it | Same port as GET. Vanilla L4 NetworkPolicy could not block this. |
| `PUT / -> 403` | **ACNS** | Same as POST | Default-deny on methods. Only GET is whitelisted. |
| `DELETE / -> 403` | **ACNS** | Same as POST | A compromised AGC route can't delete data on the pod. |
| `GET /products -> 404` | **nginx** | AGC routed → ACNS *allowed* (`/products` in whitelist) → nginx had no such file → returned 404 | **The proof point.** 404 means the request reached the app. ACNS is doing real L7 inspection, not blanket-blocking. |
| `GET /admin -> 403` | **ACNS** | AGC routed → **ACNS rejected the path** → nginx never saw `/admin` | The bouncer at the door rejected it. nginx never knew it was coming. |

**The 403-vs-404 distinction is the headline.** Anyone can build "deny everything." Showing *"allow this method on this path, deny that method on that path, pass the rest untouched all the way to the app"* — with the responses coming from different layers depending on the rule — is the unique value of AGC + ACNS L7.

> **Verdict:** AGC brought traffic in (every request reached AGC and was forwarded — same port, same destination). ACNS denied four and allowed three, based on the actual HTTP method and path, with the 403s synthesized by Cilium and the 200/404 served by nginx.

**Takeaway** — *"AGC delivered all seven requests. ACNS decided which four to drop and which three to forward. AGC owns *getting traffic in*. ACNS owns *deciding what gets to flow*."*

### 4c. ACNS L7 east-west — same enforcement, no AGC involved

| Tests | Layer | What's enforcing | Direction |
|---|---|---|---|
| **4c** client → contoso GET/POST, client → fabrikam | **ACNS L7** (east-west, no AGC involved) | Same `CiliumNetworkPolicy` L7 rules, applied to in-cluster pod-to-pod | **East-west: pod ↔ pod** |

**What we're testing:** Three calls from the in-cluster `client` pod directly to `contoso` and `fabrikam` Services via cluster DNS. AGC is not in the data path. Same Cilium L7 policies as 4b — but now the *source* is another pod, not the internet.

**What it shows:**

- The same Cilium L7 rules that protected contoso from AGC traffic in 4b also protect it from *other pods* in the cluster. **Source-agnostic enforcement.**
- This is the half of the network AGC was never designed to touch. AGC handles north-south ingress; ACNS handles east-west pod-to-pod with identity-based, bidirectional whitelists.
- Lateral movement (a compromised pod pivoting to richer ones inside the cluster) is the most dangerous attack pattern in Kubernetes. Without east-west L7 enforcement, you have no defense once an attacker is already inside.
- Watch the **403 vs 000 distinction** — they tell two different stories. `403` means Cilium let TCP complete and the HTTP request arrive, then synthesized a denial. `000` means Cilium dropped the SYN before TCP ever completed. Different layer, both denied. In production this distinction is alertable — a 403 is a misbehaving caller you know about; a 000 is a peer that should have no business reaching this pod at all.

```bash
CLIENT=$(kubectl get pod -n $APP_NAMESPACE -l app=client -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n $APP_NAMESPACE $CLIENT -- curl -s -o /dev/null -w "client->contoso GET  -> %{http_code}\n" --max-time 5 http://contoso:8080/
kubectl exec -n $APP_NAMESPACE $CLIENT -- curl -s -o /dev/null -w "client->contoso POST -> %{http_code}\n" --max-time 5 -X POST http://contoso:8080/
kubectl exec -n $APP_NAMESPACE $CLIENT -- curl -s --ipv4 -o /dev/null -w "client->fabrikam     -> %{http_code}\n" --max-time 5 http://fabrikam:8080/
```

**Expected output:**

```text
client->contoso GET  -> 200
client->contoso POST -> 403
client->fabrikam     -> 000
```

**What the output means:**

| Line | Who decided | What happened | What it tells the audience |
|---|---|---|---|
| `client->contoso GET -> 200` | nginx | Both `client-may-call-contoso-get-only` (egress on client) AND `allow-agc-l7-get-only` (ingress on contoso) permitted GET → nginx served | **Both ends must agree.** Cilium is enforcing identity-based, bidirectional whitelists. |
| `client->contoso POST -> 403` | **ACNS** | Cilium L7 proxy parsed HTTP, saw POST, synthesized 403 | Right pod, right port, **wrong method.** A compromised neighbor cannot escalate to dangerous methods even on services it can already reach. |
| `client->fabrikam -> 000` | **ACNS at L4** | TCP handshake never completed — Cilium silently dropped the SYN | **No policy whitelists `client → fabrikam`.** Default-deny kicks in *before HTTP exists*. From the attacker's perspective, fabrikam might as well not exist. |

> **Verdict:** AGC is not in this picture. ACNS allowed the one whitelisted call, denied the wrong-method call at L7 with a 403, and denied the unknown-peer call at L4 with a silent drop.

**The takeaway to repeat to the customer:** *"AGC controls the front door of the building. ACNS controls every interior door. Even when an attacker is already inside the cluster — even when the attacker is the *source* of malicious traffic — ACNS still enforces the exact same method-and-path rules. There is no 'trusted east-west' in zero-trust, and ACNS is what makes that real. AGC was never designed to touch this half of the traffic graph; ACNS is what completes the story."*

### 4d. ACNS default-deny egress — stopping pods from calling out

| Tests | Layer | What's enforcing | Direction |
|---|---|---|---|
| **4d** Backend pod → bing.com | **ACNS** default-deny egress | `default-deny-all` CNP at the pod | East-west out: pod → internet |

**What we're testing:** A backend pod (contoso) tries to `wget https://www.bing.com`. ACNS's `default-deny-all` should drop the connection silently.

**What it shows:**

- This is the inverse of 4b/4c — we've been controlling traffic *coming in* to pods. Now we're controlling traffic *going out*.
- AGC is irrelevant here. AGC is an *ingress* product — it does not handle pod egress. If you only had AGC and no ACNS, this `wget` would succeed.
- Almost every modern attack on Kubernetes ends with the compromised pod calling out — exfiltration, second-stage payload download, C2 callback. Cutting egress breaks the attack chain.
- Cilium silent-drops the SYN at the kernel — no RST, no ICMP unreachable, just a hung connection that eventually times out. From the attacker's perspective the network is a black hole, and that ambiguity is itself a defense.
- The pattern is the customer's explicit ask: *allow only the controller endpoints, deny everything else.* Specific outbound destinations would be added with `toFQDNs: [matchName: 'api.vendor.com']` rules.

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

- **DNS still resolves.** `getaddrinfo("www.bing.com")` succeeded — kube-dns was reached via `allow-dns-egress`. So this isn't "the cluster is broken," it's "the cluster is locked down with a DNS carve-out."
- **The TCP connection to bing's IP silently times out.** Cilium drops the SYN at the kernel level — no RST, no ICMP unreachable, no useful error. After 5s wget gives up. This is Cilium's documented default-deny behavior ([silent drop](https://docs.cilium.io/en/latest/security/policy/intro/#policy-deny-response-handling)).
- **`rc=1`** is the application-visible result. **If a workload were exfiltrating data, this is what stops it.** The attacker doesn't even get a useful error code to retry against.
- **AGC is not in this picture.** AGC is irrelevant to outbound pod traffic. ACNS owns this dimension entirely.

> **Verdict:** AGC not involved (this is outbound). ACNS denied the TCP connection silently at the eBPF datapath because no egress allow rule whitelists the public internet.

**The takeaway to repeat to the customer:** *"AGC handles inbound. ACNS handles inbound *and* outbound. With four `CiliumNetworkPolicy` objects we've built default-deny in both directions plus surgical carve-outs for DNS, AGC ingress, and one specific east-west call. A compromised pod can't talk to the internet, can't move laterally, and can't send the wrong HTTP method to its allowed neighbors. That's a complete zero-trust posture, end to end."*

### 4e. ACNS DNS carve-out — proving the lockdown is *precise*, not blunt

| Tests | Layer | What's enforcing | Direction |
|---|---|---|---|
| **4e** DNS still resolves | **ACNS** carve-out | `allow-dns-egress` CNP | East-west to kube-dns |

**What we're testing:** From inside the same locked-down namespace, can the client pod still resolve a Service name via cluster DNS?

**What it shows:**

- 4d showed default-deny working. 4e shows we didn't just "unplug the network" — we built a *precise* allow list that keeps apps functional. `allow-dns-egress` is the one carve-out that makes default-deny survivable.
- AGC is not on this path. Pure pod-to-kube-dns traffic.
- Compare with 4d: same pod, same policies. DNS resolved (allowed); TCP to bing didn't (denied). **Same network primitives, two outcomes — that precision is the demo.**
- The carve-out is tightenable. Replace `matchPattern: '*'` with `matchPattern: '*.contoso.com'` and Cilium silently drops every other DNS query *itself*, not just the eventual TCP connection.
- This is the difference between "we have policy" (an audit checkbox) and "we can demonstrate policy enforcing surgically" (a production posture).

```bash
kubectl exec -n $APP_NAMESPACE $CLIENT -- nslookup contoso.agc-sites.svc.cluster.local
```

**Expected output:**

```text
Server:         10.0.0.10
Address:        10.0.0.10:53


Name:   contoso.agc-sites.svc.cluster.local
Address: 10.0.37.14
```

**What the output means:**

- **`Server: 10.0.0.10:53`** — that's the kube-dns ClusterIP. The client pod successfully reached it on port 53. Egress to *that* destination, on *that* port, with the *DNS protocol*, was permitted by `allow-dns-egress`.
- **`Address: 10.0.37.14`** — the resolved Service IP for contoso. A real DNS answer, not a timeout, not NXDOMAIN.
- **Compare with 4d.** Same pod resolved `www.bing.com` (DNS allowed) but couldn't connect to it (TCP denied). DNS is uniformly allowed (by name pattern `*`), but **TCP/UDP to anywhere except kube-dns:53** is dropped. That's the precision the customer ask demanded.

> **Verdict:** AGC not involved. ACNS allowed this one specific call (port 53 to kube-dns endpoints) because it's the carve-out we explicitly wrote.

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
- **4c — ACNS enforces east-west too.** Pod-to-pod, no AGC in the path. `client → contoso GET` got `200`, `client → contoso POST` got `403`, `client → fabrikam` got `000` (TCP never completed). Three calls, three different layers of denial.
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

