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
- Every drop is observable in real time from the kernel (5).

---

## 0. Set variables and pick your subscription

**Talking points:**
- Set these to whatever subscription / region / resource group / cluster name you're using. The values below are placeholders — swap them for your own. The rest of the runbook references these variables, so you only edit them once here.
- Two namespaces: `$ALB_NAMESPACE` holds the AGC `ApplicationLoadBalancer` CR (the AGC frontend's intent lives here), `$APP_NAMESPACE` holds the workloads + Cilium policies. This split mirrors the ownership boundary we recommend in AGC docs — platform team owns the ALB namespace, app team owns the workload namespace.


```bash
export SUBSCRIPTION_ID="64d48c73-c5f4-4817-93d8-65908359d9b4"   # rnautiyal@lab
export LOCATION="westus3"
export RESOURCE_GROUP="5-4-agc-demo"
export AKS_NAME="agcdemo-aks"
export ALB_NAMESPACE="alb-demo"
export ALB_NAME="alb-demo"
export APP_NAMESPACE="agc-sites"

az account set --subscription "$SUBSCRIPTION_ID"
```

---

## 1. Register providers, install CLI extensions, create RG

**Talking points:**
- Azure resource providers are opt-in per subscription. The four we register are: **ContainerService** (AKS), **Network** (VNets/subnets), **ServiceNetworking** (the AGC backend — this is the one most people forget), and **OperationsManagement** (telemetry/log analytics that ACNS uses).
- `AdvancedNetworkingPreview` is the preview flag that gates the **L7 ACNS** capability — without it, the `--acns-advanced-networkpolicies L7` flag in the next step is rejected.
- `aks-preview` extension exposes that L7 flag in the CLI; the `alb` extension lets us inspect AGC resources (`az network alb ...`) directly during troubleshooting.
- The RG is the *parent* group. AKS will auto-create a sibling `MC_<rg>_<aks>_<region>` group for the nodes, AGC, and managed subnet — that's normal AKS behavior, not something we did.

One-time per subscription:

```bash
for rp in Microsoft.ContainerService Microsoft.Network Microsoft.ServiceNetworking Microsoft.OperationsManagement; do
  az provider register --namespace "$rp" --wait
done

# Only AdvancedNetworkingPreview is needed for ACNS L7. (An earlier draft of this
# guide also registered AzureServiceMeshPreview — that feature does not exist
# and is NOT required. Skip it.)
az feature register --namespace Microsoft.ContainerService --name AdvancedNetworkingPreview
az provider register --namespace Microsoft.ContainerService

az extension add --name aks-preview --upgrade --yes
az extension add --name alb         --upgrade --yes

az group create -n "$RESOURCE_GROUP" -l "$LOCATION"
```

---

## 2. Create the AKS cluster (~7 min)

**This is step 1 + step 2 of the ask in a single command.** Two flags do the heavy lifting — lead with these:

- **`--enable-acns --acns-advanced-networkpolicies L7`** — turns on **Advanced Container Networking Services (ACNS)** in L7 mode. This is the magic flag that lets Cilium understand HTTP — method, path, headers — not just ports. Everything in steps 4b–4e depends on this one flag.
- **`--enable-application-load-balancer`** — installs the **AGC add-on**. AKS provisions the ALB Controller, the workload-identity federation, the delegated subnet, and the AGC Azure resource itself. No Helm chart, no manual identity glue. Trade-off worth saying out loud: you can't customize the controller image — if a customer needs a fork, the managed add-on isn't for them.

The rest of the flags are supporting cast — mention briefly if asked:

- `--network-plugin azure --network-plugin-mode overlay` + `--network-dataplane cilium` — Azure CNI Overlay for IP plan, Cilium eBPF for the dataplane (required for L7).
- `--enable-gateway-api` — installs Gateway API CRDs and the `azure-alb-external` GatewayClass.
- `--enable-oidc-issuer --enable-workload-identity` — lets the AGC controller authenticate to Azure without secrets.
- `Standard_D4s_v5 × 2`, SSH disabled — modest, locked-down nodes; we never shell in.

After create, verify three things: nodes Ready, both `alb-controller` pods Running, GatewayClass `Accepted=True`. If any of those is wrong, nothing downstream will work.

```bash
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
kubectl get nodes
kubectl -n kube-system get pods -l app=alb-controller
kubectl get gatewayclass azure-alb-external
```

You should see 2 Ready nodes, 2 Running `alb-controller` pods, and `azure-alb-external` `Accepted=True`.

---

## 3. Deploy everything (manifests inline)

**What this whole section is doing.** Step 2 created an empty cluster with the AGC add-on installed but no traffic to handle. Step 3 *fills the cluster*: namespaces, the AGC frontend itself, the three sample apps, the routing rules that put those apps behind AGC, and the Cilium policies that lock everything down. After step 3 finishes you have:

- a public AGC frontend with a real Azure-assigned FQDN,
- three nginx pods serving three different sites,
- a Gateway + 3 HTTPRoutes wiring those sites to AGC by hostname,
- four Cilium policies enforcing default-deny + GET-only at every pod boundary,
- a `client` pod inside the cluster used to demonstrate east-west enforcement in step 4.

Four sub-steps. Each one introduces a new layer of the architecture; you can pause after each to show the cluster state.

- **3a Namespaces** — just two empty namespaces. Boring but they're the ownership boundary.
- **3b ApplicationLoadBalancer CR** — *this is what makes Azure provision the AGC frontend*. After 3b runs, you have a real public Azure resource with a real FQDN.
- **3c Sample apps + client pod** — the three nginx "tenants" plus a curl pod for east-west tests.
- **3d Gateway + HTTPRoutes** — the Gateway API objects that AGC translates into actual routing config ("send `contoso.example.com` to the contoso pod, etc.").
- **3e Cilium policies** — the four `CiliumNetworkPolicy` objects that switch every pod into default-deny and then carve out the specific HTTP methods/paths we want to allow.

### 3a. Namespaces

**Talking points:** trivial but worth calling out — `alb-demo` is where the controller's `ApplicationLoadBalancer` CR lives (think "AGC config"), `agc-sites` is where the workloads + policies live. Cilium policies in 3e scope only to `agc-sites`, so they only constrain the apps, not the controller.

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata: { name: alb-demo }
---
apiVersion: v1
kind: Namespace
metadata: { name: agc-sites }
EOF
```

### 3b. Tell AGC to provision a managed frontend (~5 min)

**This is the heart of step 2 of the ask — and this is where AGC actually comes into existence as an Azure resource.** Up until now, the AGC *add-on* was installed (the `alb-controller` pods are running), but no AGC frontend, no public IP, no subnet, nothing in the portal yet. Applying this one tiny YAML changes that.

Talking points:

- `ApplicationLoadBalancer` is a CRD owned by the AGC controller. Applying this CR is the customer's *declaration of intent*: "I want an AGC frontend." The controller watches for this object and reacts.
- The shape `spec.associations: []` (an *empty list*) is the magic incantation for **managed-by-ALB** mode. Empty list = "I don't want to bring my own subnet — AKS, please create everything for me." If a customer wanted to pre-create the subnet (BYO mode), they'd populate this list with a subnet reference. Empty list is what most customers want.
- The instant this CR is applied, AKS does **all** of the following on the customer's behalf, with **zero further input**:
  1. carves a `/24` out of the cluster VNet called `aks-appgateway`,
  2. delegates that subnet to `Microsoft.ServiceNetworking/TrafficController`,
  3. provisions the **Application Gateway for Containers** Azure resource (`alb-<hash>`) in the `MC_` resource group,
  4. associates the new subnet to the new AGC,
  5. federates the AGC's workload identity with the cluster's OIDC issuer so the controller can call ARM to keep this AGC in sync.
- This is what "managed-by-AKS" means in practice. The customer wrote 7 lines of YAML; AKS produced an Azure load balancer, a delegated subnet, and a workload identity. Compare with classic Application Gateway v1, where the customer would manually provision all three.
- The `kubectl wait ... condition=Deployment=True` is how we know all five steps above are done. If it sits at `Updating` for >10 min, that's typically a transient AGC regional backend issue — the fix is to switch regions.
- Once `Deployment=True`, the AGC has a public frontend FQDN reserved, but no listeners yet (no port 80, no port 443). Listeners come from the `Gateway` we apply in 3d. So at the end of 3b you have AGC "powered on but with no doors open"; in 3d we'll open the doors.

```bash
kubectl apply -f - <<EOF
apiVersion: alb.networking.azure.io/v1
kind: ApplicationLoadBalancer
metadata:
  name: $ALB_NAME
  namespace: $ALB_NAMESPACE
spec:
  associations: []
EOF

kubectl wait --for=condition=Deployment=True \
  applicationloadbalancer/$ALB_NAME -n $ALB_NAMESPACE --timeout=10m
```

### 3c. Three sample sites + a client pod

**Talking points:**

- Each "site" is one nginx pod fronted by a ClusterIP Service on port 8080. The HTML differs per site so we can prove from the response which backend served it — that's how we verify multi-site routing actually routes.
- **The labels matter for policies later**: each backend has both `app: <name>` and `site: <name>`. The L7 policy in 3e selects pods with `site IN [contoso, fabrikam, adventure]`, so adding a 4th site is one label away.
- The `client` pod is a tiny `curlimages/curl` container that just sleeps. We `kubectl exec` into it later to demonstrate **east-west** policy enforcement (in-cluster pod to in-cluster service). It has the label `app: client`, which the 4th policy targets.
- nginx listens on **8080**, not 80 — running unprivileged. The Gateway will translate the public port 80 into a backend hit on 8080.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata: { name: contoso-html, namespace: agc-sites }
data:
  index.html: |
    <html><body><h1>Hello from Contoso</h1><p>Served from contoso.example backend</p></body></html>
  default.conf: |
    server { listen 8080; root /usr/share/nginx/html; index index.html; }
---
apiVersion: v1
kind: ConfigMap
metadata: { name: fabrikam-html, namespace: agc-sites }
data:
  index.html: |
    <html><body><h1>Hello from Fabrikam</h1><p>Served from fabrikam.example backend</p></body></html>
  default.conf: |
    server { listen 8080; root /usr/share/nginx/html; index index.html; }
---
apiVersion: v1
kind: ConfigMap
metadata: { name: adventure-html, namespace: agc-sites }
data:
  index.html: |
    <html><body><h1>Hello from Adventure Works</h1><p>Served from adventure.example backend</p></body></html>
  default.conf: |
    server { listen 8080; root /usr/share/nginx/html; index index.html; }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: contoso, namespace: agc-sites, labels: { app: contoso, site: contoso } }
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
metadata: { name: contoso, namespace: agc-sites }
spec:
  selector: { app: contoso }
  ports: [{ port: 8080, targetPort: 8080 }]
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: fabrikam, namespace: agc-sites, labels: { app: fabrikam, site: fabrikam } }
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
metadata: { name: fabrikam, namespace: agc-sites }
spec:
  selector: { app: fabrikam }
  ports: [{ port: 8080, targetPort: 8080 }]
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: adventure, namespace: agc-sites, labels: { app: adventure, site: adventure } }
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
metadata: { name: adventure, namespace: agc-sites }
spec:
  selector: { app: adventure }
  ports: [{ port: 8080, targetPort: 8080 }]
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: client, namespace: agc-sites, labels: { app: client, role: client } }
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
EOF

for d in contoso fabrikam adventure client; do
  kubectl -n agc-sites rollout status deployment/$d
done
```

### 3d. Gateway + 3 HTTPRoutes (multi-site)

**This is step 3 of the ask: multi-site on a single AGC frontend.** Talking points:

- One `Gateway` (`gateway-01`) with a single HTTP listener on port 80. The annotations `alb-namespace` and `alb-name` link it to the `ApplicationLoadBalancer` we created in 3b — that's how the controller knows *which* AGC resource to program with this Gateway.
- Three `HTTPRoute`s, each binding a different hostname (`contoso.example.com`, `fabrikam.example.com`, `adventure.example.com`) to a different backend Service. **One Gateway, one public IP, three sites.** Adding a fourth site is just another HTTPRoute — no Azure-side changes.
- We don't actually own those hostnames; we'll use `curl --resolve` later to forge the Host header. In a real deployment you'd point DNS A/AAAA records at the AGC FQDN.
- **Cross-namespace caveat for prod:** in this demo Routes and Services live in the same namespace, so we don't need a `ReferenceGrant`. In a real multi-tenant setup where the `HTTPRoute` lives in a tenant namespace and the backend `Service` lives elsewhere, you must add a `ReferenceGrant` in the Service's namespace permitting that Route to refer across the boundary. Mention this when customers ask about the multi-team ownership model.
- `Programmed=True` is the condition that says AGC has finished applying our Gateway config to the data plane. After that, the FQDN actually serves traffic.

```bash
kubectl apply -f - <<EOF
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
EOF
```

### 3e. Cilium L7 policies

**What we're applying here.** Four `CiliumNetworkPolicy` (CNP) objects. CNP is Cilium's superset of Kubernetes `NetworkPolicy` — it speaks not just "allow port X from pod Y" but also "allow HTTP method M on path P" and "allow DNS queries matching pattern Q." That HTTP-aware piece is what ACNS L7 unlocks; vanilla Kubernetes NetworkPolicy can't express it.

**Why we need four of them.** Cilium policies are *additive whitelists* — each policy allows something, and traffic that isn't allowed by any policy gets dropped (once default-deny is engaged). So we layer them:

1. First, switch every pod in `$APP_NAMESPACE` into default-deny (`default-deny-all`). After this policy alone is applied, **nothing works** — not even DNS. That's intentional; we want to start from "deny everything" and explicitly carve out only what's needed.
2. Then add DNS as the first carve-out (`allow-dns-egress`) so apps can resolve service names.
3. Then carve out the **north-south path through AGC** with HTTP-method-and-path precision (`allow-agc-l7-get-only`) — this is what makes AGC → pod traffic work, but only for `GET /` and `GET /products`.
4. Finally carve out a specific **east-west path** (`client-may-call-contoso-get-only`) so the in-cluster `client` pod can call `contoso` — again, only `GET /`. This one is optional for ingress security but lets us demo east-west enforcement in 4c.

**This is step 4 of the ask plus the "get creative" bonus.** Each policy adds one specific allowance on top of default-deny. Read them as a stack:

**Policy 1 — `default-deny-all` (the baseline)**
- Selects every pod in `agc-sites` and denies all ingress + egress.
- After *just* this policy: nothing works, not even DNS. That's the point.
- Syntax gotcha: the rules are `ingress: [{}]` and `egress: [{}]` — one empty rule, **not** an empty list `[]`. Empty list means "this policy doesn't apply," which is a no-op (and shows `VALID=False`).

**Policy 2 — `allow-dns-egress` (the survival kit)**
- Lets every pod talk to kube-dns on port 53.
- `dns: matchPattern: "*"` makes Cilium *parse* the DNS query, not just blindly allow port 53. You could narrow it later (e.g. `*.cluster.local`).
- Without this, policies 3 and 4 would technically work but apps couldn't find each other by name.

**Policy 3 — `allow-agc-l7-get-only` (the north-south allow)**
- For pods labelled `site ∈ {contoso, fabrikam, adventure}`: allow inbound on port 8080, but only `GET /` and `GET /products`.
- Sources allowed: `world` **and** `cluster`. AGC traffic enters the pod via a node-local hop that Cilium tags as `cluster`, not `world` — if you only allow `world`, the GET sometimes returns 403 even when the path matches. List both. (This caught us during build.)
- Anything outside that allow-list — wrong method, wrong path — gets a Cilium-synthesized 403 *before nginx sees it*. That's the headline of step 4b.

**Policy 4 — `client-may-call-contoso-get-only` (the east-west allow)**
- Pod with `app: client` may call pod with `app: contoso` on `GET /` only.
- Both this policy AND policy 3 must permit the call — Cilium policies are **additive**, so the source's egress allow and the destination's ingress allow must agree.
- Why this matters in step 4c: `client → contoso POST` fails (policy 3 denies the method); `client → fabrikam` fails entirely (no policy whitelists it, default-deny wins).

**After these four are applied,** the cluster is in the final demo state: AGC traffic for `GET /` and `GET /products` works; everything else is dropped at the pod boundary, observable via `cilium monitor` in step 5.

```bash
kubectl apply -f - <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: { name: default-deny-all, namespace: agc-sites }
spec:
  endpointSelector: {}
  ingress:
    - {}
  egress:
    - {}
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: { name: allow-dns-egress, namespace: agc-sites }
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
metadata: { name: allow-agc-l7-get-only, namespace: agc-sites }
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
metadata: { name: client-may-call-contoso-get-only, namespace: agc-sites }
spec:
  endpointSelector: { matchLabels: { app: client } }
  egress:
    - toEndpoints: [{ matchLabels: { app: contoso } }]
      toPorts:
        - ports: [{ port: "8080", protocol: TCP }]
          rules:
            http:
              - { method: "GET", path: "/" }
EOF

kubectl get cnp -n $APP_NAMESPACE
```

All 4 should show `VALID=True`.

---

## 4. Test it — the actual demo

**Setup is over. From here on, every command demonstrates a customer-facing behavior of AGC and ACNS.** This is the section the audience came for. Don't rush it.

### The arc of step 4 in one paragraph

> *Setup built two things: an Azure-managed L7 load balancer (AGC) wired to three sample tenants, and a set of Cilium L7 policies (ACNS) clamped down on every pod inside the cluster. Step 4 proves both layers do exactly what we said. **4a shows AGC routing internet traffic in; 4a-bonus turns on Azure WAF on AGC to block OWASP-class attacks at the edge.** **4b–4e show ACNS deciding what traffic, from any source, is allowed to flow inside the cluster.** AGC is the front door. With WAF, it's a metal detector at the front door. ACNS is the security guard at every interior door.*

### Each `### 4x.` subsection has the same shape

1. Mini context table — which layer this test exercises.
2. Talking points.
3. The command.
4. Expected output.
5. What it proves.
6. Verdict + takeaway.

### Keep this table on screen during step 4:

| Tests | Layer being demonstrated | What's enforcing | Direction |
|---|---|---|---|
| **4a** Multi-site routing | **AGC** (the front door) | Gateway API `HTTPRoute` hostname matching on the AGC frontend | North-south: internet → cluster |
| **4a-bonus** SQLi / path-traversal blocked at the edge | **AGC + Azure WAF** (DRS 2.1) | `WebApplicationFirewallPolicy` CRD bound to the Gateway | North-south: internet → AGC (request never reaches the pod) |
| **4b** GET vs POST/PUT/DELETE, /products vs /admin | **ACNS L7** (the bouncer at the pod door) | `CiliumNetworkPolicy` L7 rules at the contoso/fabrikam/adventure pod | North-south *behind* AGC: AGC → pod |
| **4c** client → contoso GET/POST, client → fabrikam | **ACNS L7** (east-west, no AGC involved) | Same `CiliumNetworkPolicy` L7 rules, applied to in-cluster pod-to-pod | **East-west: pod ↔ pod** |
| **4d** Backend pod → bing.com | **ACNS** default-deny egress | `default-deny-all` CNP at the pod | East-west out: pod → internet |
| **4e** DNS still resolves | **ACNS** carve-out | `allow-dns-egress` CNP | East-west to kube-dns |
| **5** Live drop monitor | **ACNS** observability | `cilium monitor` reading kernel events | Whichever direction you generate traffic in |

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

- "One AGC, three hostnames, three backend pods."
- "Watch the IP — it's the same `$IP` for every request. **One public IP, three tenants.**"
- "The only thing that changes between these three calls is the `Host:` header. AGC reads the header, picks the backend."
- "There's no per-tenant Azure resource. Adding a fourth tenant is one more `HTTPRoute` YAML — zero Azure-side work."
- "This replaces a DIY ingress controller running on cluster nodes — you get a managed Azure load balancer, and Gateway API as the customer-facing surface."

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

**What it proves:**

- Same public IP for all three; only `Host:` differs. That's L7 hostname-based routing on the AGC frontend.
- Each `<h1>Hello from <site></h1>` line confirms a different backend pod served the request.
- Three `HTTPRoute` objects — upstream Kubernetes API — drove this. No AGC-specific YAML in the app team's hands.
- ACNS is silently waving these through because they match the `GET /` allow-list. We'll see it actively *deny* in 4b.

> **Verdict:** AGC brought traffic in (host-based routing on a single public IP). ACNS allowed it through (`GET /` is in the whitelist).

**Takeaway** — *"One flag at cluster create time, one Gateway+HTTPRoute YAML, and you have a managed multi-tenant L7 frontend that's invisible to your app teams."*

### 4a-bonus. Add WAF to AGC — the AGC superpower that ACNS alone can't give you

| Tests | Layer | What's enforcing | Direction |
|---|---|---|---|
| **4a-bonus** SQLi / path-traversal payload at the edge | **AGC + Azure WAF** (managed Default Rule Set 2.1) | `WebApplicationFirewallPolicy` CRD → `SecurityPolicy` → Azure WAF policy | North-south: internet → AGC (request never reaches the pod) |

**Why this slots into the AGC half of the demo:** WAF is an AGC capability. There's no DIY ingress controller path to Azure WAF on AKS L7 ingress — if you want native Azure WAF, you need AGC. So choosing AGC for managed Gateway API gets you native WAF too.

**Why both layers exist** (have this on screen during the test):

| Threat | AGC WAF (edge) | ACNS L7 (pod) |
|---|---|---|
| `?text=/etc/passwd` path-traversal payload from internet | **Blocks (DRS rule match)** | Wouldn't have triggered (path is `/`, method is GET — passes ACNS) |
| `POST /` from internet | Forwards (no WAF rule against bare POST) | **Blocks (method not in whitelist)** |
| `POST /` from a *compromised pod inside the cluster* | Doesn't see it | **Blocks (4c will prove this)** |
| Zero-day SQLi against `/products?id=...` | **Blocks (DRS pattern match)** | Wouldn't catch (path is allowed) |

AGC WAF stops signature-based attacks from the internet. ACNS L7 stops behavioral misuse from any source. Customers need both.

- "Stepping back — we've shown AGC routing and ACNS enforcement. Now we're lighting up the third leg: **AGC's built-in Azure WAF.**"
- "The line worth remembering: **WAF is what AGC unlocks for ACNS customers.** No AGC, no native WAF."
- "WAF on AGC uses the Azure-managed Default Rule Set 2.1 — same OWASP-class signatures as Front Door and standalone App Gateway WAF."
- "The wiring is two pieces: an Azure WAF policy resource that holds the rules, and a `WebApplicationFirewallPolicy` CRD that points the ALB Controller at it. We'll scope it to the whole Gateway so all three tenants are protected."
- "Watch the response codes. `200` for the legit request, `403` for the malicious one — and the 403 here is from **AGC**, not Cilium."

**Setup — create the Azure WAF policy and bind it via the CRD:**

> **Why we use a single atomic `update --set managedRules...`:** AGC WAF *only* supports `Microsoft_DefaultRuleSet` (DRS) 2.1 — no OWASP, no Bot Manager. But `az ... waf-policy create` requires `--type/--version` and only accepts OWASP. You cannot fix this with two separate calls (`remove OWASP` then `add DRS`) because:
> - `remove OWASP` fails with `NoValidPrimaryRuleSetsAttached` (a policy must always have one primary ruleset)
> - `add DRS` fails with `HasMultiplePrimaryRuleSets` (can't add a second one)
>
> So we create with the forced OWASP, then **swap the entire `managedRuleSets` array atomically** in a single `update`.

```bash
# 1a. Create the policy IF it doesn't already exist. We make this idempotent because
#     `az ... waf-policy create` is an upsert — re-running it on an existing policy that's
#     already attached to AGC will re-send `--type OWASP --version 3.2` and get rejected
#     with `ApplicationGatewayFirewallAttachAGCUnsupportedRuleSetVersion`. So: only create
#     if missing. The `update` calls below are themselves idempotent.
if ! az network application-gateway waf-policy show \
      --name agc-waf-policy --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  az network application-gateway waf-policy create \
    --name agc-waf-policy \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --type OWASP --version 3.2
else
  echo "WAF policy agc-waf-policy already exists — skipping create."
fi

# 1b. Atomically replace OWASP 3.2 with DRS 2.1 (the only ruleset AGC WAF supports) in one update.
az network application-gateway waf-policy update \
  --name agc-waf-policy --resource-group "$RESOURCE_GROUP" \
  --set "managedRules.managedRuleSets=[{\"ruleSetType\":\"Microsoft_DefaultRuleSet\",\"ruleSetVersion\":\"2.1\",\"ruleGroupOverrides\":[]}]"

# 1c. Set the policy to Prevention/Enabled.
az network application-gateway waf-policy update \
  --name agc-waf-policy --resource-group "$RESOURCE_GROUP" \
  --set policySettings.mode=Prevention policySettings.state=Enabled

# 1d. Sanity check — should show only Microsoft_DefaultRuleSet 2.1.
az network application-gateway waf-policy show \
  --name agc-waf-policy --resource-group "$RESOURCE_GROUP" \
  --query 'managedRules.managedRuleSets'

WAF_ID=$(az network application-gateway waf-policy show \
  --name agc-waf-policy --resource-group "$RESOURCE_GROUP" --query id -o tsv)
echo "$WAF_ID"

# 1e. Grant the ALB Controller's managed identity permission to "join" the WAF policy.
#     Without this, the CRD will sit in DeploymentFailed with LinkedAuthorizationFailed
#     ("does not have permission to perform 'microsoft.network/applicationgatewaywebapplicationfirewallpolicies/join/action'").
#     The ALB Controller add-on creates a managed identity in the AKS node RG. Naming varies
#     across add-on versions (`azurealb-*`, `<aks>-agentpool`, etc.), so we list and pick.
NODE_RG=$(az aks show -g "$RESOURCE_GROUP" -n "$AKS_NAME" --query nodeResourceGroup -o tsv)
echo "Node RG: $NODE_RG"
echo "Identities in node RG:"
az identity list -g "$NODE_RG" --query "[].{name:name,principalId:principalId}" -o table

# Pick the ALB controller identity. Naming varies across add-on versions:
#   - `applicationloadbalancer-<aks>` (current GA naming, e.g. applicationloadbalancer-agcdemo-aks)
#   - `azurealb-<aks>` (older preview naming)
# We match either pattern. If neither matches, set it manually from the table above.
ALB_PRINCIPAL_ID=$(az identity list -g "$NODE_RG" \
  --query "[?starts_with(name, 'applicationloadbalancer') || starts_with(name, 'azurealb')].principalId | [0]" -o tsv)

# If empty, set it manually from the table above (the ALB controller identity is the one
# whose name starts with `applicationloadbalancer-` or `azurealb-`):
# ALB_PRINCIPAL_ID=<paste-objectid-here>
echo "ALB Controller identity: $ALB_PRINCIPAL_ID"

az role assignment create \
  --assignee-object-id "$ALB_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Network Contributor" \
  --scope "$WAF_ID"

# 2. Bind it to our Gateway via the ALB Controller's WebApplicationFirewallPolicy CRD.
kubectl apply -f - <<EOF
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

# 3. Wait for the controller to reconcile, then confirm Programmed=True.
sleep 30
kubectl get webapplicationfirewallpolicy -n $APP_NAMESPACE agc-gateway-waf \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")]}{"\n"}'
```

> **If you applied the CRD before the role assignment** (or had any other permission issue at first reconcile), the controller caches the failure on the CRD. Force a re-reconcile by deleting and re-applying:
>
> ```bash
> kubectl delete webapplicationfirewallpolicy -n $APP_NAMESPACE agc-gateway-waf
> # then re-run the kubectl apply block above
> ```

> **If kubectl prints `the server has asked for the client to provide credentials`** \u2014 your Cloud Shell session lost the AKS cluster credentials (common after an idle disconnect). Re-run:
>
> ```bash
> az aks get-credentials -g "$RESOURCE_GROUP" -n "$AKS_NAME" --overwrite-existing
> ```

**Expected setup output:**

```text
/subscriptions/.../resourceGroups/5-4-agc-demo/providers/Microsoft.Network/applicationGatewayWebApplicationFirewallPolicies/agc-waf-policy
webapplicationfirewallpolicy.alb.networking.azure.io/agc-gateway-waf created
...
status:
  conditions:
  - reason: Programmed
    status: "True"
    type: Programmed
```

**Now run the actual test — one benign request, one malicious:**

> **If you're in a fresh Cloud Shell tab**, re-export `$APP_NAMESPACE` and re-derive `$IP` first, otherwise curl returns `000` (no DNS / empty `--resolve`):
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

**What it proves:**

- The 200 proves WAF didn't break the app. Same `GET /` we ran in 4a, still works.
- The two 403s came from **AGC**, not Cilium. ACNS L7 wouldn't have caught either — both are GETs to `/`, which is in the ACNS whitelist. Without WAF at the edge, both would have reached nginx.
- AGC WAF caught the *signature-based* attack. ACNS L7 (in 4b) catches the *behavioral* attack. Two layers, two rule philosophies, both running automatically.
- WAF runs in **Prevention** for prod and **Detection** for tuning. One CLI flag flips between them. You can scope WAF per-`HTTPRoute` to roll it out per-tenant.

> **Verdict:** AGC brought traffic in **and stopped malicious traffic at the edge** with Azure WAF (DRS 2.1). ACNS never had to look at the request — it died one layer earlier. Outer perimeter / inner perimeter, working together.

**Takeaway** — *"With AGC you don't pick between managed L7 ingress and WAF — you get both. Two YAMLs: a Gateway and a `WebApplicationFirewallPolicy`. Defense in depth, end to end."*

### 4b. ACNS L7 — deciding what traffic is *allowed* once it's inside

| Tests | Layer | What's enforcing | Direction |
|---|---|---|---|
| **4b** GET vs POST/PUT/DELETE, /products vs /admin | **ACNS L7** (the bouncer at the pod door) | `CiliumNetworkPolicy` L7 rules at the contoso/fabrikam/adventure pod | North-south *behind* AGC: AGC → pod |

- "In 4a, AGC routed traffic in. In 4b we send AGC some traffic that *shouldn't* succeed — and watch ACNS reject it."
- "AGC forwards all seven of these requests. AGC doesn't filter by method or path — it's a load balancer, not a security product."
- "The security boundary is **ACNS L7 at the pod**. Cilium has an HTTP-aware proxy in eBPF. It parses the actual method and path, then decides."
- "Two lines to watch: `POST / -> 403` and `GET /products -> 404`."
- "`POST / -> 403` — Cilium **synthesized** that 403. nginx never saw the request. The 403 bytes came from Cilium's proxy."
- "`GET /products -> 404` — Cilium **let it through** because `/products` is in the allow list. nginx looked, didn't find a `/products` file, returned 404."
- "**The 403 is from Cilium. The 404 is from nginx.** That's how you know L7 inspection is real, not blanket-block."
- "A vanilla Kubernetes NetworkPolicy could not produce this. It can only allow or deny port 8080 wholesale. ACNS L7 lets you say 'GET on 8080 yes, POST on 8080 no' — same port, different verb, different verdict."

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

**What it proves, line by line:**

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

**The story in one line:** The same Cilium L7 rules that protected the pod from AGC traffic in 4b also protect it from *other pods* in the cluster — even though AGC isn't anywhere on this path.

**AGC's role here:** **none.** Zero. AGC is not in the data path for any of these three tests. The `client` pod is calling the `contoso` Service directly via cluster DNS (`http://contoso:8080`). This is internal traffic AGC will never see — and that's precisely the point: AGC by itself can't help you with east-west security.

**ACNS's role here:** **everything, again.** And this is the half of the network AGC was never designed to touch. ACNS L7 enforces with the same precision (method, path, source identity) regardless of whether the source is the internet or another pod.

- "In 4b, the source was AGC. In 4c, the source is another pod *inside* the cluster. AGC is not involved at all. We're testing whether ACNS still enforces."
- "This matters because the most dangerous attack pattern in Kubernetes is *lateral movement*: an attacker compromises one pod — maybe via a vulnerable dependency, maybe a stolen token — and then pivots to richer pods inside the cluster. AGC, by definition, can't see this traffic."
- "Three calls. Watch the response codes carefully — they tell you three different stories."
- "`client → contoso GET → 200`: both ends agree this is allowed. `client-may-call-contoso-get-only` lets the client *send* a GET to contoso; `allow-agc-l7-get-only` lets contoso *receive* a GET from anywhere inside the cluster. **Both policies must permit it — they're additive whitelists.**"
- "`client → contoso POST → 403`: same destination, wrong method. Cilium's L7 proxy parsed the HTTP, saw POST, returned 403. A compromised `client` cannot escalate to writing data on contoso."
- "`client → fabrikam → 000`: this is different. **No policy whitelists `client → fabrikam` at all.** Default-deny kicks in *at L4* before any HTTP exchange happens. Cilium drops the SYN packet. curl prints `000` because it never received a response."
- "**403 vs 000 is itself a teaching moment.** 403 means Cilium let you *open the connection* and *send the request*, then explicitly rejected. 000 means Cilium never let the TCP handshake complete. Different layer, same result: denied. Customers can use this distinction in alerting — a 403 is a misbehaving caller you know about; a 000 is an attempt from a peer that should have no business reaching this pod at all."
- "This is what 'zero-trust east-west' actually looks like in practice. Not just 'mTLS between sidecars' — but pod-level identity, method-level enforcement, default-deny everywhere."

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

**What it proves:**

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

**The story in one line:** A backend pod tries to reach the public internet. ACNS silently drops the connection. A compromised pod can't exfiltrate data, can't phone home, can't pull a second-stage payload.

**AGC's role here:** **none.** This is outbound traffic from a pod. AGC is an *ingress* product — it does not handle pod egress. If you only had AGC and no ACNS, this `wget` to bing.com would succeed.

**ACNS's role here:** **everything.** `default-deny-all` made the contoso pod refuse to send traffic anywhere. `allow-dns-egress` carved out the one exception we wanted (DNS). The *internet* is not in any allow list, so the TCP connection to bing's IP gets silently dropped at the eBPF datapath — the pod's process sees a hung connection and an eventual timeout.

- "This is the inverse of 4b/4c. So far we've been controlling traffic *coming in* to pods. Now we're controlling traffic *going out* from pods."
- "Why does this matter? Almost every modern attack on Kubernetes ends with the compromised pod calling out — either to exfiltrate data, or to download a second-stage payload, or to phone home to a C2 server. If you cut off egress, you break the attack chain."
- "The customer ask explicitly said *'allow only the controller endpoints, deny everything else'* — that's exactly the pattern we're enforcing here. We allow DNS, and nothing else by default. Specific outbound destinations would be added with `toFQDNs: [matchName: 'api.vendor.com']` rules."
- "Notice we're using `bing.com` as the test target. The pod will resolve that to a real Microsoft IP — DNS works because we allowed it. But the actual TCP connection to that IP just hangs. That's the silent-drop signature."
- "There's no 'connection refused.' There's no ICMP unreachable. From the attacker's perspective, the network is a black hole — they can't even tell whether the destination is unreachable or whether they're being firewalled. That ambiguity is itself a defense."
- "After 5 seconds wget gives up; we print the exit code. **Non-zero is what we want.** rc=1 means wget failed; the pod could not reach the internet."

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

**What it proves:**

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

**The story in one line:** Default-deny doesn't mean "break the cluster." Workloads can still resolve service names because we explicitly allowed exactly that traffic — nothing more, nothing less.

**AGC's role here:** **none.** Pure pod-to-kube-dns traffic. AGC isn't on this path.

**ACNS's role here:** **the carve-out.** `allow-dns-egress` permits UDP/TCP 53 to pods labeled `k8s-app=kube-dns` in `kube-system`, with an L7 DNS rule that allows any name pattern. This is what makes default-deny survivable.

- "4d showed default-deny working. 4e shows that we didn't just 'unplug the network' — we built a *precise* allow list that keeps the apps functional."
- "The allow list has exactly one entry for egress that matters here: DNS to kube-dns. That's it. Yet the cluster keeps working because that one carve-out is the right one."
- "Watch this nslookup return a real IP. That tells you (a) the pod can reach kube-dns on port 53 and (b) Cilium parsed the DNS query at L7 and matched it against the `matchPattern: '*'` rule."
- "Compare with 4d, which was the same pod calling bing.com. DNS resolved — because we allowed DNS uniformly. But the *TCP connection* failed — because we didn't allow internet egress. Same pod, same Cilium policies, two different outcomes for two different network operations. **That precision is the demo.**"
- "If a customer wants stricter DNS — say, only resolve names ending in `*.contoso.com` — that's a one-line YAML change: replace `matchPattern: '*'` with `matchPattern: '*.contoso.com'`. Cilium will let those queries through and silently drop everything else, *including the queries themselves*, not just the eventual TCP connections."
- "This is the difference between 'we have policy' (an audit checkbox) and 'we can demonstrate policy is enforcing surgically' (a production posture)."

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

**What it proves:**

- **`Server: 10.0.0.10:53`** — that's the kube-dns ClusterIP. The client pod successfully reached it on port 53. Egress to *that* destination, on *that* port, with the *DNS protocol*, was permitted by `allow-dns-egress`.
- **`Address: 10.0.37.14`** — the resolved Service IP for contoso. A real DNS answer, not a timeout, not NXDOMAIN.
- **Compare with 4d.** Same pod resolved `www.bing.com` (DNS allowed) but couldn't connect to it (TCP denied). DNS is uniformly allowed (by name pattern `*`), but **TCP/UDP to anywhere except kube-dns:53** is dropped. That's the precision the customer ask demanded.

> **Verdict:** AGC not involved. ACNS allowed this one specific call (port 53 to kube-dns endpoints) because it's the carve-out we explicitly wrote.

**The takeaway to repeat to the customer:** *"We didn't break workloads' ability to discover services. We only blocked the actual data path to destinations that aren't on our allow list. That's the difference between 'lock it all down and break the app' and 'lock it all down and the app keeps working for the things you allowed.' And every one of those allow rules can be tightened further — down to specific FQDNs, methods, paths — with a one-line YAML change."*

---

## 5. Live drop monitor (the "wow" moment)

| Tests | Layer | What's enforcing | Direction |
|---|---|---|---|
| **5** Live drop monitor | **ACNS** observability | `cilium monitor` reading kernel events | Whichever direction you generate traffic in |

**The story in one line:** Watch ACNS's enforcement happen in real time. Every drop in step 4 produced a kernel event; this is how you see those events live.

**AGC's role here:** **none.** Observability of in-cluster traffic is an ACNS-side capability.

**ACNS's role here:** **everything.** `cilium monitor` is reading the eBPF event ring buffer on the agent that hosts the target pod. Every L7 verdict (allow / deny / proxy redirect) and every L4 drop produces an event with full identity and HTTP context.

- "This is the same enforcement layer you saw in 4b–4e. Now you're watching it from the kernel's perspective in real time."
- "It's eBPF, in-kernel, identity-based. The event isn't 'IP X talked to IP Y' — it's 'identity *client* in namespace *agc-sites* tried to POST to identity *contoso*, verdict DENIED.'"
- "This is the same data stream that feeds **Hubble** and Hubble UI, **Container Insights**, and **Azure Monitor for AKS**. You're seeing the source of truth — every aggregated dashboard is downstream of this exact event ring buffer."
- "Customers love this for two reasons: (1) it makes 'L7 policy' tangible — they can see real HTTP method strings — and (2) it proves the enforcement is happening at the dataplane, not in some cloud-side log aggregator that runs minutes behind."
- "Operationally, this is also how you'd debug a misbehaving allow rule: tail the monitor, generate the request, see exactly which rule made the decision."

In one Cloud Shell tab:

```bash
kubectl -n kube-system exec -it ds/cilium -- cilium monitor --type drop
```

In another tab, send a denied request. **Cloud Shell tabs don't share environment variables**, so re-export the basics first:

```bash
SUBSCRIPTION_ID="64d48c73-c5f4-4817-93d8-65908359d9b4"
RESOURCE_GROUP="5-4-agc-demo"
AKS_NAME="agcdemo-aks"
APP_NAMESPACE="agc-sites"

az account set --subscription "$SUBSCRIPTION_ID"
az aks get-credentials -g "$RESOURCE_GROUP" -n "$AKS_NAME" --overwrite-existing

FQDN=$(kubectl get gateway gateway-01 -n $APP_NAMESPACE -o jsonpath='{.status.addresses[0].value}')
IP=$(getent hosts "$FQDN" | awk '{print $1}' | head -1)

curl -X POST --resolve contoso.example.com:80:$IP http://contoso.example.com/
```

> **Errata note**: if you skip the re-export and `$IP` is empty, curl fails with `curl: (49) Couldn't parse CURLOPT_RESOLVE entry 'contoso.example.com:80:'` — that's the giveaway that the variable isn't set in this tab.

**Expected output in the monitor tab.** You'll see a few different event types as the denied POST flows through. The exact identity numbers and IPs differ per cluster, but the shape is:

```text
-> Request http from 0 ([reserved:world]) to 4521 ([k8s:app=contoso k8s:io.kubernetes.pod.namespace=agc-sites k8s:site=contoso]), identity 2->4521, verdict Denied POST http://contoso.example.com/ => 403
```

…and possibly an L4 drop event for related packets:

```text
xx drop (Policy denied) flow 0x4f3a2b1c to endpoint 4521, ifindex 12, file bpf_lxc.c:1843, , identity 2->4521: 10.224.0.5:42118 -> 10.244.1.7:8080 tcp ACK
```

**Why this is the expected output, line by line:**

| Field | Meaning | Why it matters |
|---|---|---|
| `-> Request http` | Cilium's L7 HTTP proxy intercepted the request | Confirms ACNS L7 is active; a plain L4 NetworkPolicy would have no `http` event at all. |
| `from 0 ([reserved:world])` | Source security identity. `reserved:world` = traffic that originated outside the cluster (i.e., from the AGC frontend, treated as "internet" from the pod's perspective) | Same identity AGC traffic gets — proves we're enforcing on the real production path, not a synthetic test. |
| `to 4521 ([k8s:app=contoso ... k8s:site=contoso])` | Destination identity, derived from the contoso pod's labels | These are the exact labels the policy matches on (`site IN [contoso, fabrikam, adventure]`). Proves Cilium identified the destination correctly. |
| `verdict Denied` | The policy engine's decision | This is the moneyshot. Not "rejected by app," not "firewalled" — `Denied` by the *network policy engine*. |
| `POST http://contoso.example.com/ => 403` | The exact HTTP request that was dropped, plus the synthesized response code | **Cilium parsed the HTTP method and path, decided POST wasn't whitelisted, and crafted the 403 itself.** That's why you saw `403` in step 4b — Cilium wrote it. nginx never saw the request. |
| `xx drop (Policy denied)` | Lower-level kernel-side drop event for L4 packets that were also dropped (e.g., the FIN tearing down the connection after the L7 deny) | Same decision, surfaced from the eBPF datapath. |
| `file bpf_lxc.c:1843` | The exact source line in Cilium's eBPF program that emitted the drop | Proves the drop happens **in the kernel datapath**, not in userspace. Sub-microsecond, no context switch. |
| `identity 2->4521` | Numeric form of the source/dest identities (2 = world, 4521 = contoso pods) | Cilium policy is **identity-based**, not IP-based. If the contoso pod is rescheduled to a new IP, the identity stays `4521` and the policy keeps working with no reconciliation. |

**What it proves overall:**

- **The decision is made in the kernel.** Not in nginx, not in a sidecar, not in a userspace controller polling logs. eBPF means microsecond-latency enforcement with no per-pod CPU overhead.
- **Cilium synthesized the 403.** This is why step 4b's `POST -> 403` is L7 enforcement, not just connection drop. The byte sequence the client received was a real HTTP/1.1 403 written by Cilium's proxy — including headers — even though nginx was never reached.
- **Identity-based, not IP-based.** The verdict was rendered against `identity=4521` (contoso's pod identity), which means it survives pod restarts, IP changes, scale-up, scale-down, and node-reschedules. This is what makes Cilium policy actually operable at scale.
- **Every drop is observable.** That same event stream feeds Hubble, Hubble UI, and any Prometheus/OpenTelemetry pipeline. Customers don't lose visibility when they turn on policy — they gain a dimension of it.

**Live-demo line:** *"Look at this. We didn't enable any logging. We didn't run a sniffer. Cilium just told us — in real time, from the kernel — that it dropped a POST from the AGC frontend to the contoso pod, and it even told us which line of its own eBPF code made the call. This is the data plane talking to us. That's why ACNS L7 customers don't need a separate observability product to know their policy is working."*

---

## 6. Tear it down

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
- **5 — Every drop is observable.** `cilium monitor` showed the kernel-level event for the denied POST: identity, HTTP method, the eBPF source line that made the call.

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

