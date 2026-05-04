# Application Gateway for Containers — pitch & talking points

Companion to [CLOUDSHELL.md](CLOUDSHELL.md). Read this *before* and *after* the live runbook — the runbook is hands-on-keyboard, this file is the narrative.

---

## Why this demo exists

This demo is owned by the **Application Gateway team**. It exists to show **what AGC unlocks for AKS customers** when you adopt it as the cluster's L7 ingress, end-to-end:

- **AGC as the AKS-managed front door.** Enabled with one flag at cluster create time. AKS provisions the AGC resource, the delegated subnet, and the workload identity. Customers don't run a controller, don't manage an identity, don't size a subnet — they just write Gateway API YAML.
- **Gateway API multi-site, day one.** A single AGC frontend serving three independent hostnames via three `HTTPRoute` objects. This is the canonical AGC pattern for multi-tenant clusters: one public IP, one cert pipeline, N sites.
- **Defense-in-depth behind AGC.** The AKS-team feature **ACNS L7 (Cilium)** layers HTTP-aware network policy *behind* AGC, so the same `POST /admin` that AGC happily forwards is dropped by Cilium at the pod boundary. AGC + ACNS is a story we own jointly with the AKS networking team and customers love it because the two stack cleanly.

### The customer problem AGC solves here

A platform team running multi-tenant AKS needs:

1. **One managed front door.** No nginx-ingress to patch, no Application Gateway v1 quirks, no manual TLS pipelines, no controller running on cluster nodes consuming pod IPs.
2. **First-class multi-site.** Add a hostname → add an `HTTPRoute`. No Azure-side reconfiguration, no listener juggling, no per-site IP.
3. **A networking story all the way to the pod.** AGC handles the public edge; ACNS L7 handles the in-cluster edge. Together they give the customer a single coherent zero-trust posture from internet → pod → pod.

### What this demo proves

All of the above, on a real cluster, in ~20 minutes:

- One AGC FQDN serves three different websites by hostname (Gateway API multi-site).
- Backend pods accept `GET /` and `GET /products`; everything else (`POST`, `PUT`, `DELETE`, `GET /admin`) is dropped by Cilium *before nginx sees it*.
- An in-cluster `client` pod can `GET /` from the contoso backend but is blocked from `POST` and from reaching fabrikam at all — the same L7 enforcement applies east-west.
- Backend pods cannot reach the public internet (default-deny egress) but DNS still works (explicit allow).
- **Eleven automated tests, all green.**

### The AGC pitch in one line

*Managed L7 ingress for AKS, with native Gateway API multi-site and an identity model that's invisible to the customer — and it composes with the AKS networking stack instead of fighting it.*

---

## What we're building (the 4-step ask)

The runbook in [CLOUDSHELL.md](CLOUDSHELL.md) implements this end-to-end. Each section number maps directly to one of these:

1. **Deploy AKS with Cilium and L7 policy** — Azure CNI Overlay + Cilium dataplane + ACNS L7. The cluster substrate AGC will plug into. ([docs](https://learn.microsoft.com/en-us/azure/aks/how-to-apply-l7-policies?tabs=cilium))
2. **Enable the AGC add-on** — managed-by-AKS Application Gateway for Containers. The headline feature. ([docs](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/quickstart-deploy-application-gateway-for-containers-alb-controller-addon))
3. **Multi-site on AGC** — three hostnames on one Gateway via Gateway API `HTTPRoute`s. The day-one AGC pattern customers ship to prod. ([docs](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/how-to-multiple-site-hosting-gateway-api?tabs=alb-managed))
4. **Default-deny ingress and egress** behind AGC, with explicit carve-outs. The defense-in-depth story that complements AGC's edge enforcement. Plus the bonus: an **east-west L7 policy** showing in-cluster traffic to an AGC backend is gated the same way as internet traffic.

**How long.** ~20 minutes end-to-end, mostly waiting for Azure to provision (`az aks create` ~7 min, AGC subnet association ~5 min). Hands-on keyboard time is maybe 5 min.

**Narration tip.** Read the talking points before each block in CLOUDSHELL.md out loud while it's running. The punch lines are in step 4 — you literally watch Cilium return `403` for `POST` while letting `GET` through, and you can tell the difference between "Cilium dropped you" (403) and "the app didn't have that path" (404).

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
