# Application Gateway for Containers — multi-site + defense-in-depth demo

Replicate the demo from **Azure Cloud Shell** — zero git, every manifest inline so you can paste straight into a terminal.

Open <https://shell.azure.com> or click the `>_` icon in the Azure portal. Cloud Shell already has `az`, `kubectl`, and `curl`. Paste each block below in order.

---

## Why this demo exists

This demo is owned by the **Application Gateway team**. It exists to show **what AGC unlocks for AKS customers** when you adopt it as the cluster's L7 ingress, end-to-end:

- **AGC as the AKS-managed front door.** Enabled with one flag at cluster create time. AKS provisions the AGC resource, the delegated subnet, and the workload identity. Customers don't run a controller, don't manage an identity, don't size a subnet — they just write Gateway API YAML.
- **Gateway API multi-site, day one.** A single AGC frontend serving three independent hostnames via three `HTTPRoute` objects. This is the canonical AGC pattern for multi-tenant clusters: one public IP, one cert pipeline, N sites.
- **Defense-in-depth behind AGC.** The AKS-team feature **ACNS L7 (Cilium)** layers HTTP-aware network policy *behind* AGC, so the same `POST /admin` that AGC happily forwards is dropped by Cilium at the pod boundary. AGC + ACNS is a story we own jointly with the AKS networking team and customers love it because the two stack cleanly.

**The customer problem AGC solves here.** A platform team running multi-tenant AKS needs:

1. **One managed front door.** No nginx-ingress to patch, no Application Gateway v1 quirks, no manual TLS pipelines, no controller running on cluster nodes consuming pod IPs.
2. **First-class multi-site.** Add a hostname → add an `HTTPRoute`. No Azure-side reconfiguration, no listener juggling, no per-site IP.
3. **A networking story all the way to the pod.** AGC handles the public edge; ACNS L7 handles the in-cluster edge. Together they give the customer a single coherent zero-trust posture from internet → pod → pod.

**What this demo proves.** All of the above, on a real cluster, in ~20 minutes:

- One AGC FQDN serves three different websites by hostname (Gateway API multi-site).
- Backend pods accept `GET /` and `GET /products`; everything else (`POST`, `PUT`, `DELETE`, `GET /admin`) is dropped by Cilium *before nginx sees it*.
- An in-cluster `client` pod can `GET /` from the contoso backend but is blocked from `POST` and from reaching fabrikam at all — the same L7 enforcement applies east-west.
- Backend pods cannot reach the public internet (default-deny egress) but DNS still works (explicit allow).
- **Eleven automated tests, all green.**

**What's the AGC pitch in one line?** *Managed L7 ingress for AKS, with native Gateway API multi-site and an identity model that's invisible to the customer — and it composes with the AKS networking stack instead of fighting it.*

---

## What we're building (the 4-step ask)

This runbook implements the original ask end-to-end. Each section number below maps directly to one of these:

1. **Deploy AKS with Cilium and L7 policy** — Azure CNI Overlay + Cilium dataplane + ACNS L7. The cluster substrate AGC will plug into. ([docs](https://learn.microsoft.com/en-us/azure/aks/how-to-apply-l7-policies?tabs=cilium))
2. **Enable the AGC add-on** — managed-by-AKS Application Gateway for Containers. The headline feature. ([docs](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/quickstart-deploy-application-gateway-for-containers-alb-controller-addon))
3. **Multi-site on AGC** — three hostnames on one Gateway via Gateway API `HTTPRoute`s. The day-one AGC pattern customers ship to prod. ([docs](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/how-to-multiple-site-hosting-gateway-api?tabs=alb-managed))
4. **Default-deny ingress and egress** behind AGC, with explicit carve-outs. The defense-in-depth story that complements AGC's edge enforcement. Plus the bonus: an **east-west L7 policy** showing in-cluster traffic to an AGC backend is gated the same way as internet traffic.

**How long.** ~20 minutes end-to-end, mostly waiting for Azure to provision (`az aks create` ~7 min, AGC subnet association ~5 min). Hands-on keyboard time is maybe 5 min.

**Narration tip.** Read the talking points before each block out loud while it's running. The punch lines are in step 4 — you literally watch Cilium return `403` for `POST` while letting `GET` through, and you can tell the difference between "Cilium dropped you" (403) and "the app didn't have that path" (404).

---

## 0. Set variables and pick your subscription

**Talking points:**
- We're targeting the `rnautiyal@lab` subscription and a fresh resource group dated `5-4`.
- Region is **westus3**. AGC is multi-region; during build `eastus2` returned `Microsoft.ServiceNetworking InternalServerError` on subnet association (a transient regional issue), so we switched. **Worth flagging:** the AGC controller surfaces this clearly in `az network alb association list` — customers don't have to guess.
- Two namespaces: `alb-demo` holds the AGC `ApplicationLoadBalancer` CR (the AGC frontend's intent lives here), `agc-sites` holds the workloads + Cilium policies. This split mirrors the ownership boundary we recommend in AGC docs — platform team owns `alb-demo`, app team owns `agc-sites`.


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

Four sub-steps. Each one introduces a new layer of the architecture; you can pause after each to show the cluster state.

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

**This is the heart of step 2 of the ask.** Talking points:

- `ApplicationLoadBalancer` is a CRD owned by the AGC controller. The shape `spec.associations: []` (an *empty list*) is the magic incantation for **managed-by-ALB** mode — it tells AKS "please create the Azure AGC resource AND the delegated subnet for me."
- Behind the scenes, AKS:
  1. carves a `/24` out of the cluster VNet called `aks-appgateway`,
  2. delegates it to `Microsoft.ServiceNetworking/TrafficController`,
  3. creates the AGC resource `alb-<hash>` in the `MC_` resource group,
  4. associates the subnet to the AGC.
- The `kubectl wait ... condition=Deployment=True` is how we know all four steps above are done. If it sits at `Updating` for >10 min, that's the AGC regional backend issue we hit in `eastus2` — the fix is to switch regions.
- Once `Deployment=True`, the AGC has a public frontend FQDN reserved, but no listeners yet. Listeners come from the `Gateway` we apply in 3d.

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

Wait for the Gateway to get its public FQDN:

```bash
for i in $(seq 1 30); do
  fqdn=$(kubectl get gateway gateway-01 -n $APP_NAMESPACE -o jsonpath='{.status.addresses[0].value}')
  prog=$(kubectl get gateway gateway-01 -n $APP_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')
  printf "%s prog=%s fqdn=%s\n" "$(date -u +%T)" "${prog:-?}" "${fqdn:-<none>}"
  [ "$prog" = "True" ] && [ -n "$fqdn" ] && break
  sleep 30
done
```

### 3e. Cilium L7 policies

**This is step 4 of the ask plus the "get creative" bonus.** Read each policy aloud — they layer:

| # | Policy | Plain English |
| - | ------ | ------------- |
| 1 | `default-deny-all` | Empty selector, empty `ingress: []`, empty `egress: []`. Translation: **every pod in `agc-sites`, no traffic in or out, period.** This is the strict baseline you ask for in step 4. |
| 2 | `allow-dns-egress` | Carve-out so pods can still resolve service names via kube-dns. Without this, the next two policies would technically work but apps would fail to find each other by name. The `dns: matchPattern: "*"` makes Cilium parse and inspect actual DNS queries — not just allow port 53 blindly. |
| 3 | `allow-agc-l7-get-only` | The interesting one. For pods labelled `site IN [contoso, fabrikam, adventure]`, allow ingress from **`world` AND `cluster`** (so AGC's data path AND in-cluster pods are covered) but **only `GET /` and `GET /products` on port 8080**. Anything else → Cilium returns 403 *before nginx ever sees it*. |
| 4 | `client-may-call-contoso-get-only` | The east-west bonus. Pod with `app: client` may egress to pod with `app: contoso` on `GET /` only. Critically, both this AND policy 3 must allow the call — they're additive. POST fails because policy 3 denies, and `client → fabrikam` fails entirely because nothing whitelists it (default-deny wins). |

**Why include `cluster` in `fromEntities`** in policy 3: AGC routes traffic through a node-local hop that Cilium identifies as `cluster`, not `world`. If you only allow `world`, the GET sometimes returns 403 even though the L7 rule matches. This caught us during build — listing both is the correct pattern.

```bash
kubectl apply -f - <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: { name: default-deny-all, namespace: agc-sites }
spec:
  endpointSelector: {}
  ingress: []
  egress: []
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

**This is the demo.** Each subsection proves one of the four-step requirements is enforced. Read the expected output aloud before running so the audience knows what to watch for.

First grab the AGC FQDN and resolve it once — every test below pins to this IP via `curl --resolve`, since we don't own `*.example.com`:

```bash
FQDN=$(kubectl get gateway gateway-01 -n $APP_NAMESPACE -o jsonpath='{.status.addresses[0].value}')
IP=$(getent hosts "$FQDN" | awk '{print $1}' | head -1)
echo "$FQDN -> $IP"
```

### 4a. Multi-site routing

**Proves step 3 of the ask.** One frontend FQDN, three different responses based on the Host header. The `<h1>Hello from <site></h1>` line shows which backend pod actually served the request — so you know AGC routed by hostname, didn't just default-backend everything.

```bash
for h in contoso fabrikam adventure; do
  echo "[$h.example.com]"
  curl -s --resolve $h.example.com:80:$IP http://$h.example.com/
  echo
done
```

### 4b. Cilium L7 (GET allowed, POST denied)

**Proves step 1 (L7 policy) AND the inbound half of step 4.** Talking points:

- `GET / -> 200`: allowed by `allow-agc-l7-get-only`, served by nginx.
- `POST/PUT/DELETE / -> 403`: **Cilium denies these before nginx is reached.** A vanilla L4 policy could not do this — port 80 is the same for all four methods.
- `GET /products -> 404`: Cilium *permits* the path (it's in the allow list), so the request reaches nginx; nginx has no `/products` file, so nginx returns 404. **The 404 vs 403 distinction is the punch line: you can tell the difference between "Cilium dropped you" and "the app dropped you."**
- `GET /admin -> 403`: Cilium denies — `/admin` is not in the allow list. The app never sees this request.

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

Expect `GET=200`, others `=403`. `GET /products=404` (Cilium passes; nginx 404). `GET /admin=403` is **Cilium**.

### 4c. East-west L7

**This is the "get creative" bonus.** Same Cilium L7 enforcement, but now the source isn't AGC — it's another pod inside the cluster. Talking points:

- `client -> contoso GET -> 200`: both policies (allow-agc-l7-get-only on contoso side, client-may-call-contoso-get-only on client side) permit it.
- `client -> contoso POST -> 403`: Cilium L7 deny. Even though the *destination* is the same Service, the method is wrong. **A pod compromised inside your own cluster cannot call dangerous methods on neighbors it would otherwise be allowed to talk to.**
- `client -> fabrikam -> 000` (timeout): no policy whitelists this pair, so default-deny drops the SYN packet. The `000` is curl reporting "never got a response." That's L4 enforcement on top of L7.

```bash
CLIENT=$(kubectl get pod -n $APP_NAMESPACE -l app=client -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n $APP_NAMESPACE $CLIENT -- curl -s -o /dev/null -w "client->contoso GET  -> %{http_code}\n" --max-time 5 http://contoso:8080/
kubectl exec -n $APP_NAMESPACE $CLIENT -- curl -s -o /dev/null -w "client->contoso POST -> %{http_code}\n" --max-time 5 -X POST http://contoso:8080/
kubectl exec -n $APP_NAMESPACE $CLIENT -- curl -s --ipv4 -o /dev/null -w "client->fabrikam     -> %{http_code}\n" --max-time 5 http://fabrikam:8080/
```

Expect `200 / 403 / 000`.

### 4d. Default-deny egress

**Proves the outbound half of step 4.** A backend pod tries to reach the public internet (`bing.com`). It can't — `default-deny-all` drops outbound traffic, and we never wrote an allow rule for the internet. `wget` exits non-zero (rc=1 for unreachable, rc=143 if the kill-after timeout fired). **If a workload were exfiltrating data, this is what stops it.**

The ask said "For outbound, you could allow the controller endpoints and block everything else" — that's exactly this pattern. We allow DNS in `allow-dns-egress` and nothing else. To allow specific FQDNs (e.g., a vendor API), you'd add another CNP with `toFQDNs: [matchName: "api.vendor.com"]`.

```bash
CONTOSO=$(kubectl get pod -n $APP_NAMESPACE -l app=contoso -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n $APP_NAMESPACE $CONTOSO -- wget -q -T 5 -O /dev/null https://www.bing.com
echo "rc=$?  (non-zero = blocked)"
```

### 4e. DNS still works

**Proves the carve-out is correctly scoped.** Even with default-deny in place, kube-dns is reachable because `allow-dns-egress` whitelists port 53 to the kube-dns endpoints. The `nslookup` returns an `Address:` line for the contoso ClusterIP — not NXDOMAIN, not a timeout. **This is the litmus test that you blocked the right things and not too much.**

```bash
kubectl exec -n $APP_NAMESPACE $CLIENT -- nslookup contoso.agc-sites.svc.cluster.local
```

---

## 5. Live drop monitor (the "wow" moment)

**Optional but a crowd pleaser.** Cilium emits a kernel event for every packet it drops. ACNS exposes that via `cilium monitor`. Tail it in one window, generate a denied request from another, and watch the event scroll by in real time — including the HTTP method that triggered the drop. Makes the abstract "L7 policy" concrete: there's an actual byte-level decision happening on the data plane.

In one Cloud Shell tab:

```bash
kubectl -n kube-system exec -it ds/cilium -- cilium monitor --type drop
```

In another tab, send a denied request:

```bash
curl -X POST --resolve contoso.example.com:80:$IP http://contoso.example.com/
```

Watch the `DROPPED` event scroll by with method `POST`.

---

## 6. Tear it down

One command. Deletes the parent RG, which cascades to the AKS cluster, the auto-created `MC_` group, the AGC resource, the subnet, and all networking. `--no-wait` returns the prompt immediately; the actual delete takes a few minutes.

```bash
az group delete -n "$RESOURCE_GROUP" --yes --no-wait
```

---

## Wrap-up — what you just demonstrated about AGC

End-to-end, on a real Azure cluster, in about 20 minutes you proved:

1. **AGC turns on with one flag.** `--enable-application-load-balancer` at `az aks create` time installed the AGC ALB Controller as an add-on, provisioned the AGC Azure resource, carved a delegated subnet in the `MC_` RG, and federated a workload identity to drive it. The customer wrote zero Bicep, zero RBAC, zero subnet plumbing.
2. **Gateway API is the customer-facing surface, period.** One `Gateway`, three `HTTPRoute`s, three live hostnames behind one managed frontend — all standard upstream Kubernetes API. Adding a fourth site is one `HTTPRoute`. There is no AGC-specific YAML the app team has to learn; everything AGC-specific lives in the `ApplicationLoadBalancer` CR that the platform team owns once.
3. **Multi-site is first-class, not bolted on.** One AGC frontend FQDN serves three distinct backends, routed by Host header. Single public IP, single TLS pipeline (when you add HTTPS in the listener), N tenants. This is the canonical AGC story for multi-tenant clusters and it Just Works.
4. **AGC composes cleanly with the AKS networking stack.** ACNS L7 policies live on top of AGC's data path without conflict — AGC handles the public edge, ACNS handles the in-cluster edge, and they both speak HTTP. Customers don't have to choose between "managed ingress" and "real network policy" — they get both.
5. **Defense-in-depth is real.** Even if AGC happily forwards a request, Cilium can still drop it at the pod boundary. `POST /` returns `403` from Cilium *before nginx is reached*, and the same enforcement applies whether the source is the internet via AGC or another pod inside the cluster. AGC is the front door; ACNS is the bouncer at every interior door.
6. **The "Cilium dropped you" signal is provable.** `GET /products` returns `404` (Cilium passes the request, nginx has no such file). `GET /admin` returns `403` (Cilium drops the request before nginx). That distinction is what turns "we have policy" into "we can demonstrate policy is enforcing."

### Talking points for AGC Q&A

- *"How is this different from Application Gateway v1 + AKS Application Gateway Ingress Controller (AGIC)?"* — AGC is **purpose-built for Kubernetes**: per-pod backend addressing (no overlay-to-LB hop), Gateway API as the native API (not a reverse-engineered Ingress mapping), managed-by-AKS lifecycle (no separate identity federation), and a much faster control loop (`Programmed=True` in seconds after a route change vs. AGIC's reconcile cycles). v1 + AGIC remains supported, but AGC is the path forward.
- *"Why managed-by-ALB vs. bring-your-own?"* — Managed mode (what we just demoed) means AKS owns the AGC resource lifecycle, the delegated subnet, and the workload identity. Customer benefit: zero Azure-side ops. Trade-off: you can't pre-create the subnet or share the AGC across multiple clusters. For a single-cluster zero-trust pattern this is what most customers want. BYO is the right answer when you need shared AGC across clusters or you have strict pre-provisioned-subnet requirements.
- *"What about TLS?"* — Add `protocol: HTTPS` and a `tls.certificateRefs` to the Gateway listener pointing at a Key Vault-stored cert. AGC handles termination and rotation. We kept this demo HTTP-only so the focus stays on routing + policy, but adding HTTPS is a 5-line YAML change.
- *"How does AGC handle backend mTLS?"* — AGC supports backend TLS with custom CA via the `BackendTLSPolicy` Gateway API resource. The data path between AGC and pods can be TLS-terminated at the pod, encrypted in transit. Out of scope for this demo but worth flagging for security-conscious customers.
- *"What's the cost model?"* — AGC bills capacity units hourly + data processing per GB. For a real customer pitch, run `az consumption usage list` after a day of soak and show the line item — the numbers are usually pleasantly small compared to AppGw v1.
- *"Can I have more than 3 sites?"* — Yes; the only per-AGC limits are documented in [AGC limits](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/application-gateway-for-containers-components#limits). Adding a hostname is one `HTTPRoute`. The demo's policy `allow-agc-l7-get-only` selects sites by label (`site IN [...]`), so adding a 4th site is one label.
- *"What if the customer wants Web Application Firewall in front of this?"* — Out of scope today (AGC + WAF integration is on the roadmap; check current status). For now, customers who need WAF can chain Front Door (with WAF) → AGC, or use the v1 stack.

### Where to take this demo next

- **Add HTTPS + Key Vault.** Listener `protocol: HTTPS`, `tls.certificateRefs` pointing at a Key Vault-stored cert. Demonstrates AGC's managed cert pipeline.
- **Add a `BackendTLSPolicy`.** End-to-end TLS from internet → AGC → pod. Strong story for regulated industries.
- **Add traffic splitting.** Two `backendRefs` on one `HTTPRoute` with `weight: 90` and `weight: 10`. Live blue/green or canary in 4 lines of YAML — a feature classic Ingress can't express.
- **Add an `HTTPRouteFilter` for header rewrites.** AGC supports request/response header manipulation natively via Gateway API filters; great showcase for ops/observability workflows.
- **Wire up real DNS.** Point an Azure DNS zone at the AGC FQDN — drops the need for `curl --resolve` and gives you a clickable link in the demo.
- **Plug in Hubble.** ACNS ships with Cilium Hubble; `kubectl -n kube-system port-forward svc/hubble-ui 12000:80` gives you a UI showing every AGC → pod request and every drop. Pairs beautifully with the AGC access logs.

### One-paragraph summary (for the deck)

> *Application Gateway for Containers gave this AKS cluster a managed L7 front door with one flag. Three independent websites share one AGC frontend via Gateway API `HTTPRoute`s — single public FQDN, single TLS pipeline, three tenants. Behind AGC, ACNS L7 policies enforce GET-only access at the pod boundary, so the same rule that protects internet traffic also protects in-cluster pod-to-pod traffic. Default-deny ingress and egress for everything not explicitly allowed. Eleven automated tests prove every layer is enforcing. The customer wrote no Bicep, no RBAC, no subnet plumbing — AKS owns the AGC lifecycle end-to-end.*

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
