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
./reproducer.sh run --route edge --iterations 10 --sizes 1048576
```

Expect on baseline: **RST every iteration** (BrokenPipe during sendall).

| Column | Meaning |
| --- | --- |
| `RST/ERR` | BrokenPipe during full-body send (bug) |
| `HTTP_503` | Full body accepted, then NOSRV 503 (no RST during write) |

Defaults: `SIZES=1048576`, `ITERATIONS=10`. Passthrough is a **negative control**.

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

### What the fix applicator does

1. Clones live `openshift-ingress/router-default` (image, env, volumes, probes)
2. Extracts `haproxy-config.template` from a running default router pod
3. Injects the recommended `wait-for-body` line into each HTTP frontend (after `http-request del-header Proxy`)
4. Sets `ROUTER_BUF_SIZE=2097152` so live `tune.bufsize` is 2 MiB
5. Creates:
   - ConfigMap `custom-haproxy-template-ocpbugs-129094`
   - Deployment `router-ocpbugs-129094` (`TEMPLATE_FILE`, `ROUTER_DISABLE_NAMESPACE_OWNERSHIP_CHECK=true`, `ROUTER_BUF_SIZE`)
   - NetworkPolicy allowing egress/ingress (required when the namespace has deny-all)
   - LoadBalancer Service `router-ocpbugs-129094`

### Apply

```bash
./reproducer.sh fix-apply
./reproducer.sh fix-status
```

Verify live config (expect `wait-for-body` and `tune.bufsize` ≥ 2097152):

```bash
oc -n openshift-ingress exec deploy/router-ocpbugs-129094 -- printenv ROUTER_BUF_SIZE
oc -n openshift-ingress exec deploy/router-ocpbugs-129094 -- \
  grep -nE 'wait-for-body|tune.bufsize' haproxy.config
```

Override if needed:

```bash
export ROUTER_BUF_SIZE=2097152
export WAIT_FOR_BODY_LINE='http-request wait-for-body time 30s if METH_POST or METH_PUT or { method PATCH }'
./reproducer.sh fix-apply
```

### Compare baseline vs fixed (`run-compare`)

Both sides use the **same write-first full-body send**.

```bash
./reproducer.sh fix-apply
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
┌─────────────────┐     ┌──────────────────────┐     ┌──────────────────────────────┐
│ 1. setup        │────►│ 2. run (write-first) │────►│ 3. fix-apply                 │
│    NOSRV routes │     │    full body → RST   │     │    wait-for-body + bufsize   │
└─────────────────┘     └──────────────────────┘     └──────────────┬───────────────┘
                                                                    │
                                                                    ▼
                                                     ┌──────────────────────────────┐
                                                     │ 4. run-compare (write-first) │
                                                     │    baseline RST vs fixed 503 │
                                                     │ 5. fix-remove + cleanup      │
                                                     └──────────────────────────────┘
```

```bash
./reproducer.sh setup
./reproducer.sh run --route edge --iterations 10 --sizes 1048576     # full-body → RST
./reproducer.sh fix-apply
./reproducer.sh run-compare --route edge --sizes 1048576             # baseline RST vs fixed 503
./reproducer.sh fix-remove
./reproducer.sh cleanup
```

---

## References

- [OCPBUGS-129094 — 503 for NOSRV routes can be dropped on Azure for large POSTs](https://issues.redhat.com/browse/OCPBUGS-129094)
- [KCS 5477331 — Custom HAProxy configuration on OpenShift 4](https://access.redhat.com/solutions/5477331)
- [KCS 5381141 — Modifying router configuration](https://access.redhat.com/solutions/5381141)
