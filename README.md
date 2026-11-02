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

## 2. Run (realistic curl — natural RST, not forced)

`./reproducer.sh run` uses **curl** (interleaved upload/read) against **router-default**. Most iterations get HTTP 503; occasionally curl loses the race (`http_code=000` / exit ≠ 0). That intermittent failure is the real-life event — the script does **not** force RST.

```bash
# Against router-default (do NOT set --router-addr to a wait-for-body LB)
./reproducer.sh run --route edge --iterations 300
```

By default `UNTIL_RST=1`: stop at the first natural RST and print it:

```text
⚠  NATURAL RST event  kind=edge size=1048576B iter=47/300  http_code=000 curl_exit=56 ...
✓  Natural RST observed on baseline with realistic curl (not write-first forced)
```

| Column | Meaning |
| --- | --- |
| `HTTP_503` | curl read NOSRV 503 mid-upload (common) |
| `RST/ERR` | natural race — status line never seen |

Defaults: `SIZES=1048576`, `ITERATIONS=300`, `UNTIL_RST=1`. Use `--no-until-rst` to always run the full matrix.

Passthrough is a **negative control**.

### Optional — forced write-first detector (not realistic)

```bash
./reproducer.sh probe-writefirst --route edge --iterations 10
```

Almost always BrokenPipe — useful as a detector, **not** a simulation of a normal client.

### Useful flags

```bash
./reproducer.sh run --route edge|http|reencrypt|passthrough|all \
  --iterations 300 \
  --sizes 1048576 \
  --until-rst | --no-until-rst \
  --host <route-host> \
  --router-addr <lb-ip>    # pin to custom LB (fix compare only)
```
---

## 3. Troubleshoot

### “I never see RST with curl”

curl usually wins the race (HTTP 503). Raise iterations and keep hunting:

```bash
./reproducer.sh run --route edge --iterations 1000 --until-rst
```

| Detector | Typical result on router-default |
| --- | --- |
| `./reproducer.sh run` (curl) | Mostly 503; **occasional** natural RST |
| `./reproducer.sh probe-writefirst` | Almost always BrokenPipe (forced; not realistic) |
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

Full template customization is **not a supported OCP 4 feature** ([KCS 5477331](https://access.redhat.com/solutions/5477331)). Use only in lab / as a temporary demonstration.

### What the fix does

1. Clones live `openshift-ingress/router-default` (image, env, volumes, probes)
2. Extracts `haproxy-config.template` from a running default router pod
3. Injects into each HTTP frontend (after `http-request del-header Proxy`):

   ```haproxy
   http-request wait-for-body time 5s at-least 1k if METH_POST or METH_PUT or { method PATCH }
   ```

   Buffering the body before routing delays the NOSRV 503/RST sequence.

4. Creates:
   - ConfigMap `custom-haproxy-template-ocpbugs-129094`
   - Deployment `router-ocpbugs-129094` (`TEMPLATE_FILE`, `ROUTER_DISABLE_NAMESPACE_OWNERSHIP_CHECK=true`)
   - NetworkPolicy allowing egress/ingress (required when the namespace has deny-all)
   - LoadBalancer Service `router-ocpbugs-129094`

**Note:** HAProxy 2.8 on OCP does not define `METH_PATCH`; use `{ method PATCH }`.

### Apply

```bash
./reproducer.sh fix-apply
./reproducer.sh fix-status
```

Override the directive if needed:

```bash
export WAIT_FOR_BODY_LINE='http-request wait-for-body time 10s at-least 64k if METH_POST or METH_PUT'
./reproducer.sh fix-apply
```

Verify generated config:

```bash
oc -n openshift-ingress exec deploy/router-ocpbugs-129094 -- printenv TEMPLATE_FILE
oc -n openshift-ingress exec deploy/router-ocpbugs-129094 -- grep -n 'wait-for-body' haproxy.config
```

### Compare baseline vs fixed

```bash
# Prints default LB results, then custom LB (Host preserved via --resolve)
./reproducer.sh run-compare --route edge --iterations 30 --sizes 1024,1048576

# Or pin manually after fix-apply shows EXTERNAL-IP:
./reproducer.sh run --route edge --router-addr <CUSTOM_LB_IP> --iterations 10
```

On a successful mitigation, write-first BrokenPipe rate should drop vs router-default (ideally toward consistent HTTP 503).

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
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────────────┐
│ 1. setup        │────►│ 2. run (natural RST)│────►│ 3. fix-apply            │
│    NOSRV routes │     │    RACE OBSERVED   │     │    custom + wait-for-body│
└─────────────────┘     └──────────────────┘     └───────────┬─────────────┘
                                                             │
                                                             ▼
                                              ┌─────────────────────────────┐
                                              │ 4. run-compare / probe with │
                                              │    --router-addr CUSTOM_LB  │
                                              │ 5. fix-remove + cleanup     │
                                              └─────────────────────────────┘
```

```bash
./reproducer.sh setup
./reproducer.sh run --route edge --iterations 300         # hunt natural RST
./reproducer.sh fix-apply
./reproducer.sh run-compare --route edge --iterations 100
./reproducer.sh fix-remove
./reproducer.sh cleanup
```

---

## References

- [OCPBUGS-129094 — 503 for NOSRV routes can be dropped on Azure for large POSTs](https://issues.redhat.com/browse/OCPBUGS-129094)
- [KCS 5477331 — Custom HAProxy configuration on OpenShift 4](https://access.redhat.com/solutions/5477331)
- [KCS 5381141 — Modifying router configuration](https://access.redhat.com/solutions/5381141)
