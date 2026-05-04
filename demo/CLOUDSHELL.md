# AGC + AKS multi-site demo — Cloud Shell runbook

Hands-on-keyboard runbook. Paste each block into **Azure Cloud Shell** (<https://shell.azure.com> or the `>_` icon in the portal — `az`, `kubectl`, `curl` are pre-installed). Zero git, every manifest inline.

> **The framing in one line:** **AGC brings traffic *into* the cluster. ACNS L7 controls how traffic flows *within* the cluster.** Two features, two directions, one zero-trust story. Step 4 demonstrates each layer independently.

> **Read [PITCH.md](PITCH.md) first** for the *why* (problem statement, what AGC unlocks, what this demo proves) and *afterwards* for the wrap-up, Q&A talking points, and next steps. This file is just the steps.

---

## 0. Set variables and pick your subscription

**Talking points:**
- Set these to whatever subscription / region / resource group / cluster name you're using. The values below are placeholders — swap them for your own. The rest of the runbook references these variables, so you only edit them once here.
- Pick a region where AGC is generally available and your subscription has capacity for a small AKS cluster. AGC is multi-region; if a particular region returns transient `Microsoft.ServiceNetworking` errors during AGC subnet association, switch regions and retry. The AGC controller will surface these errors clearly in `az network alb association list`.
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

**This is step 1 + step 2 of the ask in a single command.** Talking points to hit while it's provisioning:

- `--network-plugin azure --network-plugin-mode overlay` — pods get IPs from a non-routable overlay (`10.244.0.0/16`), which keeps the VNet plan small. Pod-to-pod still works directly because Cilium handles encapsulation.
- `--network-dataplane cilium` — replaces kube-proxy/iptables with Cilium's eBPF dataplane. Required for L7 enforcement; Azure NPM can't do L7.
- `--enable-acns --acns-advanced-networkpolicies L7` — turns on **Advanced Container Networking Services** in L7 mode. This is what makes Cilium understand HTTP method/path/header rules — not just port rules.
- `--enable-application-load-balancer` — installs the **AGC add-on**: two `alb-controller` pods in `kube-system`. They watch Gateway API objects in the cluster and translate them into AGC config in Azure.
- `--enable-gateway-api` — installs the upstream Gateway API CRDs (`Gateway`, `HTTPRoute`, `GatewayClass`) and registers `azure-alb-external` as the implementing GatewayClass.
- `--enable-oidc-issuer --enable-workload-identity` — required so AGC's controller can authenticate to Azure as a workload identity (no client secrets, no service principal handoff).
- `Standard_D4s_v5 x 2` — modest size; the demo doesn't need more. SSH disabled because we don't ever shell into the nodes.

After create, we pull credentials and verify three things: nodes Ready, both `alb-controller` pods Running, and the GatewayClass `Accepted=True`. If any of those is wrong, nothing downstream will work.

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

**This is step 4 of the ask plus the "get creative" bonus.** Read each policy aloud — they layer:

| # | Policy | Plain English |
| - | ------ | ------------- |
| 1 | `default-deny-all` | Empty selector, one empty rule for `ingress` and one for `egress` (`[{}]`, **not** `[]`). Translation: **every pod in `agc-sites`, no traffic in or out, period.** Cilium's rule: a policy with a non-empty `ingress`/`egress` section flips the endpoint into default-deny for that direction. An *empty* list (`[]`) means "this rule does not apply at ingress/egress" — i.e., a no-op, which is why an `[]` version shows `VALID=False`. Use `[{}]`. |
| 2 | `allow-dns-egress` | Carve-out so pods can still resolve service names via kube-dns. Without this, the next two policies would technically work but apps would fail to find each other by name. The `dns: matchPattern: "*"` makes Cilium parse and inspect actual DNS queries — not just allow port 53 blindly. |
| 3 | `allow-agc-l7-get-only` | The interesting one. For pods labelled `site IN [contoso, fabrikam, adventure]`, allow ingress from **`world` AND `cluster`** (so AGC's data path AND in-cluster pods are covered) but **only `GET /` and `GET /products` on port 8080**. Anything else → Cilium returns 403 *before nginx ever sees it*. |
| 4 | `client-may-call-contoso-get-only` | The east-west bonus. Pod with `app: client` may egress to pod with `app: contoso` on `GET /` only. Critically, both this AND policy 3 must allow the call — they're additive. POST fails because policy 3 denies, and `client → fabrikam` fails entirely because nothing whitelists it (default-deny wins). |

**Why include `cluster` in `fromEntities`** in policy 3: AGC routes traffic through a node-local hop that Cilium identifies as `cluster`, not `world`. If you only allow `world`, the GET sometimes returns 403 even though the L7 rule matches. This caught us during build — listing both is the correct pattern.

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

## 4. Test it

**This is the demo.** Each subsection proves one of the four-step requirements is enforced. Read the "Expected output" block aloud *before* running so the audience knows what to watch for, then read the "What it proves" block *after*.

**Mental model for the next ten tests** — keep this on screen the whole time:

| Tests | Layer being demonstrated | What's enforcing | Direction |
|---|---|---|---|
| **4a** Multi-site routing | **AGC** (the front door) | Gateway API `HTTPRoute` hostname matching on the AGC frontend | North-south: internet → cluster |
| **4b** GET vs POST/PUT/DELETE, /products vs /admin | **ACNS L7** (the bouncer at the pod door) | `CiliumNetworkPolicy` L7 rules at the contoso/fabrikam/adventure pod | North-south *behind* AGC: AGC → pod |
| **4c** client → contoso GET/POST, client → fabrikam | **ACNS L7** (east-west, no AGC involved) | Same `CiliumNetworkPolicy` L7 rules, applied to in-cluster pod-to-pod | **East-west: pod ↔ pod** |
| **4d** Backend pod → bing.com | **ACNS** default-deny egress | `default-deny-all` CNP at the pod | East-west out: pod → internet |
| **4e** DNS still resolves | **ACNS** carve-out | `allow-dns-egress` CNP | East-west to kube-dns |
| **5** Live drop monitor | **ACNS** observability | `cilium monitor` reading kernel events | Whichever direction you generate traffic in |

> **One sentence to repeat at the start of step 4:** *"AGC is what brought the request into the cluster — you'll see that work in 4a. From 4b onward, ACNS L7 controls what happens to that request once it's inside the cluster: north-south *behind* AGC (4b), pod-to-pod east-west (4c), and outbound (4d/4e)."*

First grab the AGC FQDN and resolve it once — every test below pins to this IP via `curl --resolve`, since we don't own `*.example.com`:

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

### 4a. Multi-site routing

**Proves step 3 of the ask. This is the AGC half — traffic *into* the cluster.** One frontend FQDN, three different responses based on the Host header. The `<h1>Hello from <site></h1>` line shows which backend pod actually served the request — so you know AGC routed by hostname, didn't just default-backend everything.

**The AGC framing for this test:** *"Everything happening in 4a is AGC's job. AGC is the only Azure resource a packet from the internet touches before it lands on a pod. North-south traffic is its world. Notice: one public IP, three tenants, routed purely by Host header — that's Gateway API multi-site working as designed."*

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

- **One AGC frontend, one public IP, three tenants.** All three requests hit the same `$IP`; the only difference is the `Host:` header set by `curl --resolve`.
- **Gateway API multi-site is real.** Each `HTTPRoute` matched its hostname and routed to the right Service. Adding a fourth site is one more `HTTPRoute`, no Azure-side change.
- **The L7 allow rule lets `GET /` through.** This is the happy path — the thing customers actually want their users to do.
- **This is the AGC headline shot.** *One FQDN, three independent websites, zero infrastructure reconfiguration.*

### 4b. Cilium L7 (GET allowed, POST denied)

**Proves step 1 (L7 policy) AND the inbound half of step 4. The story shifts here: AGC got us *into* the cluster, ACNS now controls what happens *within* it.** This is the punch line of the entire demo — the difference between L4 ("port 80 is allowed") and L7 ("GET on port 80 is allowed, POST is not").

**Hand-off line from 4a to 4b:** *"AGC just forwarded every one of those requests, no questions asked — that's its job. Watch what the bouncer at the pod door (ACNS L7) does to the bad ones. Same destination, same port, but the verb and path now matter."*

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

| Line | What happened | Why |
|---|---|---|
| `GET / -> 200` | AGC routed → Cilium L7 proxy matched `GET /` rule → forwarded to nginx → 200 | The whitelisted method/path. The happy path. |
| `POST / -> 403` | AGC happily forwarded → **Cilium L7 proxy rejected** before nginx | Same port, same path, different verb. **A vanilla L4 NetworkPolicy could not block this.** |
| `PUT / -> 403` | Same as POST | Default-deny on methods. Only GET is whitelisted. |
| `DELETE / -> 403` | Same as POST | Same. |
| `GET /products -> 404` | Cilium **passed the request** (allowed by `GET /products` rule) → nginx had no such file → returned 404 | **THE KEY MOMENT.** 404 (not 403) means the request reached the app. Proves Cilium is actually doing L7 inspection, not blanket-blocking. |
| `GET /admin -> 403` | Cilium dropped (path not whitelisted); nginx never saw the request | The bouncer at the door rejected it. nginx never knew it was coming. |

**The 404-vs-403 distinction is the single most important slide of the talk.** Anyone can build "deny everything." Proving you can build "deny-all-except-this-method-on-this-path-and-pass-everything-else-untouched" is the AGC + ACNS L7 differentiator vs. classic ingress + L4 NetworkPolicy.

### 4c. East-west L7

**This is the "get creative" bonus — and it's the *east-west* half of the framing.** Same Cilium L7 enforcement as 4b, but the source isn't AGC anymore. **There is no AGC in this picture at all.** One pod inside the cluster (`client`) is talking directly to another pod (`contoso`, `fabrikam`) over the cluster's internal network. ACNS L7 is enforcing on a path AGC never sees.

**The ACNS framing for this test:** *"AGC controls the front door of the building. ACNS controls every interior door. Even if a pod is already inside the cluster — even if it's been compromised and is now the *source* of malicious traffic — ACNS still enforces the same method-and-path rules. There is no 'trusted east-west' in a zero-trust posture, and ACNS is what makes that real. This is the half of the traffic graph AGC was never designed to touch."*

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

| Line | What happened | Why |
|---|---|---|
| `client->contoso GET -> 200` | Both `client-may-call-contoso-get-only` and `allow-agc-l7-get-only` permit GET → request reached nginx | **Both ends must agree.** Egress policy on client + ingress policy on contoso both whitelist this exact call. |
| `client->contoso POST -> 403` | Cilium L7 proxy parsed the HTTP, saw POST, returned 403 | Right pod, right port, **wrong method.** A compromised neighbor cannot call dangerous methods even on services it would otherwise reach. |
| `client->fabrikam -> 000` | TCP handshake never completed — Cilium silently dropped the SYN | **No policy whitelists `client → fabrikam`.** Default-deny kicks in at L3/L4, before HTTP exists. curl reports `000` for "never got a response." |

**Talking point:** *"403 vs 000 is itself a signal. 403 means Cilium spoke HTTP back to us — it accepted the connection, parsed the request, then rejected at L7. 000 means Cilium never even let the TCP handshake complete. Different layer, same result: denied. Customers can use this distinction in their alerting to tell the difference between a misbehaving app (403) and a totally unknown peer (000)."*

### 4d. Default-deny egress

**Proves the outbound half of step 4.** A backend pod tries to reach the public internet (`bing.com`). It can't — `default-deny-all` drops outbound traffic, and we never wrote an allow rule for the internet.

The ask said *"For outbound, you could allow the controller endpoints and block everything else"* — that's exactly this pattern. We allow DNS in `allow-dns-egress` and nothing else. To allow specific FQDNs (e.g., a vendor API), you'd add another CNP with `toFQDNs: [matchName: "api.vendor.com"]`.

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

- **DNS still resolves.** `getaddrinfo("www.bing.com")` succeeds — kube-dns is reached via `allow-dns-egress`, returns a real public IP. So this isn't "the cluster is broken."
- **The TCP connection to that IP silently times out.** Cilium drops the SYN at the kernel level — no RST, no ICMP unreachable, no useful error. After 5s, wget gives up. This is Cilium's documented default-deny behavior ([silent drop](https://docs.cilium.io/en/latest/security/policy/intro/#policy-deny-response-handling)).
- **`rc=1`** confirms the application would see this as a failure. **If a workload were exfiltrating data, this is what stops it.** The attacker doesn't even get a useful error code to retry against.

**Talking point:** *"DNS works because we explicitly allowed it. The TCP connection to bing's actual IP just hangs forever. There's no listener missing, there's no firewall returning 'connection refused' — Cilium silently absorbs the packet at the eBPF datapath. From the attacker's perspective, the network is a black hole."*

### 4e. DNS still works

**Proves the carve-out is correctly scoped.** Even with default-deny in place, kube-dns is reachable because `allow-dns-egress` whitelists port 53 to the kube-dns endpoints with the L7 DNS rule `matchPattern: "*"` (any name allowed). **This is the litmus test that you blocked the right things and not too much.**

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
- **Compare with 4d.** Same pod resolved `www.bing.com` (DNS allowed) but couldn't connect to it (TCP denied). DNS is uniformly allowed (by name pattern `*`), but **TCP/UDP to anywhere except kube-dns:53** is dropped. That's the precision the ask demanded.

**Talking point:** *"We didn't break workloads' ability to discover services. We only blocked the actual data path. That's the difference between 'lock it all down and break the app' and 'lock it all down and the app keeps working for the things you allowed.' And if a customer wants per-name DNS allowlisting — `matchPattern: '*.contoso.com'` instead of `*` — that's one YAML line away."*

---

## 5. Live drop monitor (the "wow" moment)

**Optional but a crowd pleaser.** Cilium emits a kernel event for every packet it drops. ACNS exposes that via `cilium monitor`. Tail it in one window, generate a denied request from another, and watch the event scroll by in real time — including the HTTP method that triggered the drop. Makes the abstract "L7 policy" concrete: there's an actual byte-level decision happening on the data plane.

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

## Notes for Cloud Shell specifically

- **Session timeouts**: Cloud Shell idle-disconnects after 20 min. If you come back later, just re-run the variable block (step 0) and `az aks get-credentials` to reattach.
- **Variables don't persist** across sessions. If you reconnect, paste step 0 again before doing anything else.
- **No `python` quirks**: Cloud Shell's `getent hosts` works fine.
- **Storage**: Cloud Shell mounts a persistent `~/clouddrive` if you want to save these snippets to a file.

---

## Errata / fixes (running list)

As issues come up running these instructions, the fix is recorded here.

| Date | Symptom | Fix |
| --- | --- | --- |
| 2026-05-04 | `(FeatureNotFound) The feature 'AzureServiceMeshPreview' could not be found.` | That feature doesn't exist and isn't needed for this demo. Step 1 above no longer registers it — only `AdvancedNetworkingPreview` is registered. |
| 2026-05-04 | In step 5 (cilium monitor), second tab fails with `curl: (49) Couldn't parse CURLOPT_RESOLVE entry 'contoso.example.com:80:'` | Cloud Shell tabs are independent shells — `$IP` and `$APP_NAMESPACE` from tab 1 aren't visible in tab 2. Re-export the variables and re-run `az aks get-credentials` + the FQDN/IP lookup at the top of every new tab. Step 5 above now shows the full re-export. |
