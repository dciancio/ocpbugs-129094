# OCPBUGS-129094 — HAProxy NOSRV 503/RST Race Reproducer

Reproducer and lab mitigation for [OCPBUGS-129094](https://issues.redhat.com/browse/OCPBUGS-129094): large `POST` (≥ ~1 KiB) to a **non-passthrough** route whose Service has **no endpoints** (HAProxy `NOSRV`) returns **503** then **FIN/RST** so quickly that some clients never see the 503 (connection reset / BrokenPipe). Most visible via **Azure external LoadBalancer** paths.

This package:

1. Installs NOSRV fixtures (Service with empty Endpoints + Routes)
2. Runs curl and write-first probes against `router-default`
3. Documents why curl often hides the race
4. Applies an **unsupported** custom router with `http-request wait-for-body` to reduce the race

---

## Contents

| File | Purpose |
| --- | --- |
| `manifests.yaml` | Namespace, NOSRV Service, Routes (`http` / `edge` / `reencrypt` / `passthrough`) |
| `reproducer.sh` | Setup, run, probe, compare, cleanup; wraps the fix script |
| `fix-apply-custom-router.sh` | Clone `router-default`, inject wait-for-body, LB + NetworkPolicy |
| `README.md` | This document |

---

## Prerequisites

- `oc` logged into a cluster (Azure / ARO preferred for the original race)
- Default IngressController with an **externally reachable** LoadBalancer
- `curl`, `python3`, `bash`
- Run client tests from **outside** the cluster (not from a pod), unless you only need write-first BrokenPipe checks

```bash
oc whoami
oc -n openshift-ingress get svc router-default
```

---

## 1. Install (fixtures)

```bash
cd ocpbugs-129094
chmod +x reproducer.sh fix-apply-custom-router.sh
./reproducer.sh setup
./reproducer.sh status
```

Confirm:

- `endpoints/nosrv-backend` has **no** addresses (NOSRV precondition)
- Routes are Admitted (`nosrv-edge`, `nosrv-http`, `nosrv-reencrypt`, `nosrv-passthrough`)

Optional env:

| Variable | Default | Meaning |
| --- | --- | --- |
| `NS` | `ocpbugs-129094` | Fixture namespace |
| `WORKDIR` | `$TMPDIR/ocpbugs-129094` | Payload scratch dir |

---

## 2. Run (write-first — full body send)

`./reproducer.sh run` and `./reproducer.sh run-compare` both use a **write-first** client: they `sendall` the HTTP headers **and the entire POST body** before any `recv`. That matches SDKs that finish the upload before reading the status line.

```
write-first:  headers + full body ──► then read
curl:         write a bit ↔ read 503 ↔ stop upload (hides RST)
```

```bash
# Against router-default (do NOT set --router-addr to a wait-for-body LB)
./reproducer.sh run --route edge
```

Expect on baseline: **RST every iteration** (BrokenPipe during sendall).

| Column | Meaning |
| --- | --- |
| `RST/ERR` | BrokenPipe during full-body send (bug) |
| `HTTP_503` | Full body accepted, then NOSRV 503 (no RST during write) |

Defaults: `ROUTE_KIND=edge`, `SIZES=1048576`, `ITERATIONS=10` — override only when needed. Passthrough is a **negative control**.

Optional interleaved curl (usually hides the race):

```bash
./reproducer.sh run-curl --route edge -n 1000 --parallel 50 --until-rst
```

### Useful flags

```bash
./reproducer.sh run --route edge|http|reencrypt|passthrough|all \
  --iterations 10 \
  --sizes 1048576 \
  --host <route-host> \
  --router-addr <lb-ip>    # pin to custom LB (expect RST=0 if fix works)
```

---

## 3. Troubleshoot

### “I used curl and never saw RST”

**Expected.** Interleaved curl reads 503 mid-upload. Use write-first:

```bash
./reproducer.sh run --route edge --iterations 10
```
### Checklist

1. **Empty backends** — `oc -n ocpbugs-129094 get endpoints nosrv-backend` must show no addresses.
2. **Non-passthrough route** — use `edge` / `http` / `reencrypt`, not `passthrough`.
3. **Hit router-default** — DNS/LB should be the default Ingress Service, not a custom wait-for-body LB (`--router-addr` unset for bug repro).
4. **No wait-for-body on default** —  
   `oc -n openshift-ingress exec deploy/router-default -- grep -c wait-for-body haproxy.config` → `0`.
5. **External path** — prefer a client outside the cluster toward the public LB IP.
6. **Body size** — use ≥ 1 KiB; 1 MiB matches the bug report.
7. **Custom fix removed when reproducing** — `./reproducer.sh fix-remove` if you previously applied the mitigation.

### Quick diagnostics

```bash
./reproducer.sh status
oc -n openshift-ingress get svc router-default -o wide
oc -n ocpbugs-129094 get route nosrv-edge -o jsonpath='{.spec.host}{"\n"}'
```

---

## 4. Apply HAProxy fix (custom router + wait-for-body)

Full template customization is **not a supported OCP 4 feature** ([KCS 5477331](https://access.redhat.com/solutions/5477331)). Use only in lab / as a temporary demonstration. The durable answer is the product bug ([OCPBUGS-129094](https://issues.redhat.com/browse/OCPBUGS-129094)).

### Which fix really addresses the issue?

**Both `wait-for-body` and a large enough `tune.bufsize` are required for large POSTs.** Alone, neither fully stops the race for a 1 MiB write-first client.

| Piece | Role |
| --- | --- |
| `http-request wait-for-body` | **Behavioral fix** — hold routing until the body is buffered so NOSRV 503 is not sent while the client is still uploading |
| `tune.bufsize` / `ROUTER_BUF_SIZE` | **Capacity limit** — how much body HAProxy can hold while waiting |

`wait-for-body` stops when **any** of these happen: full body received, **buffer full**, `at-least` reached, or `time` expires (→ 408).

```
wait-for-body only (bufsize=32KiB)   → race returns after ~32KiB
bufsize only (no wait-for-body)      → still routes immediately → race
wait-for-body + bufsize ≥ body       → 503 after full body → no RST during write
```

- Raising `bufsize` **without** wait-for-body does **not** fix it (HAProxy still routes early).
- wait-for-body with default OpenShift `tune.bufsize 32768` only absorbs ~32 KiB, then NOSRV 503 → `timeout client-fin 1s` → RST during a 1 MiB `sendall`.

**Real fix (lab):** do not emit NOSRV 503/RST until the request body has been received up to the size you care about → **wait-for-body (mechanism) + bufsize ≥ max POST (enabler).**

### Recommended lab parameters (1 MiB write-first NOSRV POST)

```haproxy
tune.bufsize 2097152
http-request wait-for-body time 30s if METH_POST or METH_PUT or { method PATCH }
```

| Parameter | Recommendation | Why |
| --- | --- | --- |
| `at-least` | **Omit** (or `0`) | Small values (e.g. `1k`) end the wait early and bring the race back |
| `tune.bufsize` / `ROUTER_BUF_SIZE` | **≥ max POST body** to protect (here **2 MiB** for 1 MiB bodies) | Wait ends when the buffer fills |
| `time` | **30s** (lab); tune to slowest client × max body | Too low → 408 before the body finishes |
| Methods | `METH_POST or METH_PUT or { method PATCH }` | Body-bearing methods; HAProxy 2.8 has no `METH_PATCH` |

**Sizing rule:** `ROUTER_BUF_SIZE >= max(Content-Length)` for POSTs that can hit NOSRV. Larger bufsize uses more RAM **per connection** while waiting — keep it only as large as needed.

### Optimizations to minimize resources (large `tune.bufsize`)

Raising `tune.bufsize` to ~2 MiB raises the **per-stream buffer ceiling**. Peak buffer RAM is on the order of:

```text
≈ tune.bufsize × ~2 × maxconn   (+ process overhead)
```

Example: 100 concurrent connections × 2 MiB ≈ **~200 MiB** buffer budget (order of magnitude). You cannot make a 2 MiB buffer “small”; you **limit how many connections hold one** and **where** that bufsize is configured.

| Optimization | What to do | Why it helps |
| --- | --- | --- |
| Right-size bufsize | Prefer `>= max POST` (e.g. 1–1.5 MiB if that is enough), not an arbitrary large jump | Linear cut in per-connection RAM |
| Cap concurrency | Set a low process/frontend `maxconn` (or OpenShift router max connections) on the **custom** router | Strongest lever: bounds `maxconn × bufsize` |
| Dedicated router only | Keep large bufsize + `wait-for-body` on the lab/custom router — **not** fleet-wide `router-default` | Default traffic stays on 32 KiB buffers |
| Route sharding | Send only large-POST / NOSRV-risk apps to the “fat buffer” router | Limits who can consume 2 MiB buffers |
| Bound wait time | Keep `wait-for-body time` only as long as needed (30s lab; tighten if uploads are fast) | Stalled clients release big buffers sooner |
| Timeouts | Keep sane `timeout client` / `timeout http-request` | Avoid idle/stalled conns sitting on large buffers |
| Narrow ACLs | POST/PUT/PATCH only (correctness); still pair with **maxconn** | ACL alone does not shrink the global bufsize ceiling |

**Practical lab pattern:** custom router with `ROUTER_BUF_SIZE=2097152` + explicit low `maxconn`, leave `router-default` at stock 32 KiB.

#### Does Dynamic Configuration Manager (DCM) help minimize this memory?

**No — not for `tune.bufsize` connection memory.**

HAProxy / HAProxy Enterprise **Dynamic Configuration Manager** (and similar dynamic-config / runtime update features) help apply backend/map/ACL changes with less disruption and can avoid some **reload** cost (e.g. temporary double process or connection churn during a full config reload). That is orthogonal to steady-state data-plane RAM.

| Concern | DCM / dynamic config | What actually helps |
| --- | --- | --- |
| Per-connection buffers from large `tune.bufsize` | Does **not** reduce | Lower bufsize, lower `maxconn`, dedicated router |
| Reload spikes / config churn | May help somewhat | Still size `maxconn × bufsize` for peak |
| OpenShift router template reloads | Router still regenerates HAProxy config; dynamic features ≠ smaller buffers | Same as above |

**Bottom line:** DCM does not change “each active stream may hold up to `tune.bufsize`.” Treat resource control as **bufsize sizing + maxconn + blast-radius (dedicated router)**.

#### Free connections quickly (do not keep large buffers around)

Once the NOSRV 503 is sent, the connection (and its ~`tune.bufsize` buffer) should close. Stock OpenShift router already uses short FIN timers; keep-alive is the usual way idle sockets linger.

Default router timeouts (ddcaroovn / typical OCP):

| Setting | Typical default | Effect on “done → free” |
| --- | --- | --- |
| `timeout http-request` | 10s | Caps how long a request may sit incomplete |
| `timeout client` | 30s | Idle client data timeout |
| `timeout client-fin` | **1s** | After client/server starts closing, finish quickly |
| `timeout server-fin` | **1s** | Same on server side |
| `timeout http-keep-alive` | **300s** | Idle keep-alive sockets can linger up to 5 minutes |

**What to do on the custom (fat-buffer) router:**

1. **Prefer close after the response (lab-friendly)**  
   - Client: send `Connection: close` (this reproducer’s write-first client already does).  
   - HAProxy: `option httpclose` (or `http-server-close`) so the proxy does not hold the client connection for reuse after the 503.  
   Tradeoff: more handshakes; less idle RAM with large `bufsize`.

2. **Shorten keep-alive on that router only**  
   If you must leave keep-alive enabled, lower `timeout http-keep-alive` sharply on the custom router (e.g. **1–5s** lab) so idle conns die fast. Do **not** change this fleet-wide on `router-default` without assessing API/browser traffic.

3. **Keep FIN timers short**  
   Leave `timeout client-fin` / `timeout server-fin` at **1s** (stock). That is what tears down the socket quickly after 503 on NOSRV today.

4. **Bound the wait itself**  
   `wait-for-body time 30s` (or less) so a stalled upload cannot hold a 2 MiB buffer indefinitely; incomplete wait → 408 and close.

5. **Client hygiene**  
   Apps/SDKs should close the connection after the error response (or use `Connection: close` on the request). A client that parks on keep-alive still occupies proxy state until `timeout http-keep-alive`.

```haproxy
# Example knobs on the *custom* lab router only (unsupported template edit)
option httpclose
timeout http-keep-alive 5s
timeout client-fin 1s
timeout server-fin 1s
timeout http-request 10s
http-request wait-for-body time 30s if METH_POST or METH_PUT or { method PATCH }
```

**Goal:** request finishes → 503 (or 408) → FIN/close within ~1s → buffer returned. Avoid long `timeout http-keep-alive` on the same process that uses 2 MiB `tune.bufsize`.

#### Implementation steps (custom router — supported env vars)

OpenShift’s `haproxy-config.template` already maps env → timeouts. Prefer these on the **custom** Deployment (do **not** change `router-default` unless you intend cluster-wide impact).

| Goal | Env var on custom router | Maps to HAProxy | Lab default |
| --- | --- | --- | --- |
| Short idle keep-alive | `ROUTER_SLOWLORIS_HTTP_KEEPALIVE` | `timeout http-keep-alive` | `5s` (stock is `300s`) |
| Close when response completes idle | `ROUTER_IDLE_CLOSE_ON_RESPONSE=true` | `option idle-close-on-response` | `true` |
| Fast FIN after close | `ROUTER_CLIENT_FIN_TIMEOUT` | `timeout client-fin` | `1s` (stock) |
| Fast server FIN | `ROUTER_DEFAULT_SERVER_FIN_TIMEOUT` | `timeout server-fin` | `1s` (stock) |
| Cap concurrency | `ROUTER_MAX_CONNECTIONS` | `maxconn` | optional (e.g. `500`) |
| Large body buffer | `ROUTER_BUF_SIZE` | `tune.bufsize` | `2097152` |

**Step 1 — apply (prompts, flags, or `-y` for all recommended):**

```bash
# Interactive: Enter accepts each [recommended] value
./reproducer.sh fix-apply
./reproducer.sh fix-status

# Non-interactive: all recommended lab optimizations
./reproducer.sh fix-apply -y
./reproducer.sh fix-status

# Or pass parameters (skips prompt for those flags)
./reproducer.sh fix-apply \
  --buf-size 2097152 \
  --keep-alive 5s \
  --idle-close true \
  --client-fin 1s \
  --server-fin 1s
  # optional: --max-connections 500
./reproducer.sh fix-status

# Same via env (also skips prompt for that var)
export ROUTER_BUF_SIZE=2097152
./reproducer.sh fix-apply -y
./reproducer.sh fix-status
```

`fix-apply` always sets `ROUTER_DISABLE_NAMESPACE_OWNERSHIP_CHECK=true` and injects `wait-for-body` (plus the buffer/release env above). Always run `fix-status` after `fix-apply` to confirm each customization.

**Step 2 — optional manual verify on a Ready custom router pod:**

```bash
POD=$(oc -n openshift-ingress get pods -l app=router-ocpbugs-129094 -o jsonpath='{.items[0].metadata.name}')

oc -n openshift-ingress exec "$POD" -- printenv \
  ROUTER_BUF_SIZE \
  ROUTER_SLOWLORIS_HTTP_KEEPALIVE \
  ROUTER_IDLE_CLOSE_ON_RESPONSE \
  ROUTER_CLIENT_FIN_TIMEOUT \
  ROUTER_DEFAULT_SERVER_FIN_TIMEOUT

oc -n openshift-ingress exec "$POD" -- grep -nE \
  'tune.bufsize|timeout http-keep-alive|timeout client-fin|timeout server-fin|idle-close-on-response|wait-for-body' \
  haproxy.config
```

Expect something like:

```text
tune.bufsize 2097152
timeout client-fin 1s
timeout server-fin 1s
timeout http-keep-alive 5s
option idle-close-on-response
http-request wait-for-body time 30s ...
```

**Step 3 — prove RST still fixed, then that connections do not linger:**

```bash
./reproducer.sh run-compare --route edge --sizes 1048576
```

Optional: confirm keep-alive is short (custom LB only):

```bash
# After a write-first 503, socket should not sit in keep-alive for minutes.
# From the client, Connection: close (reproducer write-first already sends this).
```

**Step 4 — tighten further if needed (custom router only):**

```bash
export ROUTER_SLOWLORIS_HTTP_KEEPALIVE=1s
export ROUTER_MAX_CONNECTIONS=200
./reproducer.sh fix-apply
./reproducer.sh fix-status
```

**Manual patch (without re-running full apply):**

```bash
oc -n openshift-ingress set env deploy/router-ocpbugs-129094 \
  ROUTER_SLOWLORIS_HTTP_KEEPALIVE=5s \
  ROUTER_IDLE_CLOSE_ON_RESPONSE=true \
  ROUTER_CLIENT_FIN_TIMEOUT=1s \
  ROUTER_DEFAULT_SERVER_FIN_TIMEOUT=1s \
  ROUTER_BUF_SIZE=2097152

oc -n openshift-ingress rollout status deploy/router-ocpbugs-129094
```

Unsupported raw template edits such as `option httpclose` are unnecessary if `ROUTER_IDLE_CLOSE_ON_RESPONSE` + short `ROUTER_SLOWLORIS_HTTP_KEEPALIVE` + client `Connection: close` are in place.

### What the fix applicator does

1. Clones live `openshift-ingress/router-default` (image, env, volumes, probes)
2. Extracts `haproxy-config.template` from a running default router pod
3. Injects the recommended `wait-for-body` line into each HTTP frontend (after `http-request del-header Proxy`)
4. Sets `ROUTER_BUF_SIZE=2097152` so live `tune.bufsize` is 2 MiB
5. Sets connection-release env: `ROUTER_SLOWLORIS_HTTP_KEEPALIVE=5s`, `ROUTER_IDLE_CLOSE_ON_RESPONSE=true`, FIN timeouts `1s`
6. Creates:
   - ConfigMap `custom-haproxy-template-ocpbugs-129094`
   - Deployment `router-ocpbugs-129094` (`TEMPLATE_FILE`, `ROUTER_DISABLE_NAMESPACE_OWNERSHIP_CHECK=true`, `ROUTER_BUF_SIZE`)
   - NetworkPolicy allowing egress/ingress (required when the namespace has deny-all)
   - LoadBalancer Service `router-ocpbugs-129094`

### Apply

```bash
./reproducer.sh fix-apply -y          # recommended values, no prompts
./reproducer.sh fix-status            # always run after fix-apply
# ./reproducer.sh fix-apply           # interactive prompts with [recommended]
# ./reproducer.sh fix-status
# ./reproducer.sh fix-apply -h        # flags / recommended list
```

`fix-status` reports each row below as **APPLIED** / **STOCK** / **MISSING**, with the live `haproxy.config` **SECTION**.

### Customizations needed

| Customization | Required | Env / source | HAProxy directive | Section | Lab value | Stock default |
| --- | --- | --- | --- | --- | --- | --- |
| `wait-for-body` | yes (race fix) | template inject (`WAIT_FOR_BODY_LINE`) | `http-request wait-for-body …` | frontend ×3 (`public`, `fe_sni`, `fe_no_sni`) | `time 30s` (no `at-least`) | absent |
| large `tune.bufsize` | yes (for ≥1 MiB body) | `ROUTER_BUF_SIZE` | `tune.bufsize` | global | `2097152` | `32768` |
| short `http-keep-alive` | yes (release buffers) | `ROUTER_SLOWLORIS_HTTP_KEEPALIVE` | `timeout http-keep-alive` | defaults | `5s` | `300s` |
| `idle-close-on-response` | yes (release buffers) | `ROUTER_IDLE_CLOSE_ON_RESPONSE` | `option idle-close-on-response` | frontend ×3 | `true` | absent |
| `timeout client-fin` | keep short | `ROUTER_CLIENT_FIN_TIMEOUT` | `timeout client-fin` | defaults | `1s` | `1s` |
| `timeout server-fin` | keep short | `ROUTER_DEFAULT_SERVER_FIN_TIMEOUT` | `timeout server-fin` | defaults | `1s` | `1s` |
| custom `TEMPLATE_FILE` | yes (lab router) | `TEMPLATE_FILE` | — | deploy env | `/var/lib/haproxy/conf/custom/haproxy-config.template` | stock template |
| disable ns ownership check | yes (dual routers) | `ROUTER_DISABLE_NAMESPACE_OWNERSHIP_CHECK` | — | deploy env | `true` | unset / false |
| `maxconn` cap | optional | `ROUTER_MAX_CONNECTIONS` | `maxconn` | global, defaults | e.g. `500` | `50000` |
| ConfigMap template | yes (persists inject) | `custom-haproxy-template-ocpbugs-129094` | same as `wait-for-body` | ConfigMap → template | 3 wait-for-body hits | — |

Manual spot-check if needed:

```bash
oc -n openshift-ingress exec deploy/router-ocpbugs-129094 -- printenv ROUTER_BUF_SIZE
oc -n openshift-ingress exec deploy/router-ocpbugs-129094 -- \
  grep -nE 'wait-for-body|tune.bufsize|http-keep-alive|idle-close-on-response' haproxy.config
```

Override if needed:

```bash
export ROUTER_BUF_SIZE=2097152
export WAIT_FOR_BODY_LINE='http-request wait-for-body time 30s if METH_POST or METH_PUT or { method PATCH }'
./reproducer.sh fix-apply
./reproducer.sh fix-status
```

### Compare baseline vs fixed (`run-compare`)

Both sides use the **same write-first full-body send**.

```bash
./reproducer.sh fix-apply
./reproducer.sh fix-status
./reproducer.sh run-compare --route edge --sizes 1048576
```

Expect:

```text
1/2 BASELINE … RST=10/10 …
2/2 FIXED    … RST=0/10  HTTP_503=10/10 …
Verdict: wait-for-body + bufsize eliminates RST for full-body 1MiB POST
```

Manual pin:

```bash
./reproducer.sh run --route edge --router-addr <CUSTOM_LB_IP> --iterations 10
# want: RST=0/10 HTTP_503=10/10
```

### Remove the fix

```bash
./reproducer.sh fix-remove
```

---

## 5. Cleanup

```bash
./reproducer.sh fix-remove   # if applied
./reproducer.sh cleanup      # deletes fixture namespace
```

---

## 6. End-to-end flow (summary)

```text
╔══════════════════════════════════════╗
║  OCPBUGS-129094 lab flow             ║
╚══════════════════╤═══════════════════╝
                   │
                   ▼
        ┌──────────────────────┐
        │ 1. setup             │
        │    NOSRV fixtures    │
        └──────────┬───────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │ 2. run (write-first) │
        │    full body → RST   │
        └──────────┬───────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │ 3. fix-apply [-y]    │
        │    wait-for-body +   │
        │    bufsize + release │
        └──────────┬───────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │ 4. fix-status        │
        │    APPLIED / STOCK / │
        │    MISSING           │
        └──────────┬───────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │ 5. run-compare       │
        │    baseline RST vs   │
        │    fixed HTTP 503    │
        └──────────┬───────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │ 6. fix-remove        │
        └──────────┬───────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │ 7. cleanup           │
        └──────────────────────┘
```

```bash
./reproducer.sh setup
./reproducer.sh run --route edge
./reproducer.sh fix-apply -y
./reproducer.sh fix-status
./reproducer.sh run-compare --route edge
./reproducer.sh fix-remove
./reproducer.sh cleanup
```

---

## References

- [OCPBUGS-129094 — 503 for NOSRV routes can be dropped on Azure for large POSTs](https://issues.redhat.com/browse/OCPBUGS-129094)
- [KCS 5477331 — Custom HAProxy configuration on OpenShift 4](https://access.redhat.com/solutions/5477331)
- [KCS 5381141 — Modifying router configuration](https://access.redhat.com/solutions/5381141)
