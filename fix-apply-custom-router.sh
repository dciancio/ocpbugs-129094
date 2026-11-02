#!/usr/bin/env bash
# OCPBUGS-129094 fix applicator
# Clones the cluster's managed router-default Deployment into an unmanaged
# custom router, injects http-request wait-for-body into haproxy-config.template,
# and exposes a separate LoadBalancer Service so traffic can be compared.
#
# Based on router-default from the ddcaroovn / ARO lab pattern (image, env,
# volumes, probes preserved; operator ownership labels removed).
#
# Usage:
#   ./fix-apply-custom-router.sh apply
#   ./fix-apply-custom-router.sh status
#   ./fix-apply-custom-router.sh remove
#
# Env:
#   INGRESS_NS=openshift-ingress
#   SOURCE_DEPLOY=router-default
#   CUSTOM_DEPLOY=router-ocpbugs-129094
#   CUSTOM_SVC=router-ocpbugs-129094
#   WAIT_FOR_BODY_LINE  — override the injected HAProxy directive
#   REPLICAS=1

set -euo pipefail

INGRESS_NS="${INGRESS_NS:-openshift-ingress}"
SOURCE_DEPLOY="${SOURCE_DEPLOY:-router-default}"
CUSTOM_DEPLOY="${CUSTOM_DEPLOY:-router-ocpbugs-129094}"
CUSTOM_SVC="${CUSTOM_SVC:-router-ocpbugs-129094}"
CUSTOM_CM="${CUSTOM_CM:-custom-haproxy-template-ocpbugs-129094}"
REPLICAS="${REPLICAS:-1}"
WORKDIR="${WORKDIR:-${TMPDIR:-/tmp}/ocpbugs-129094-fix}"
# Buffer POST/PUT/PATCH bodies before routing so NOSRV 503 is not emitted
# while the client is still uploading (mitigates 503 vs RST race).
#
# Do NOT use a small "at-least N" (e.g. 1k): wait ends after N bytes, then
# NOSRV 503/RST still races the remainder of a large upload.
# Even without at-least, HAProxy stops waiting when tune.bufsize is full
# (OCP router default 32768). Lab fix raises ROUTER_BUF_SIZE (default 2 MiB)
# so a 1 MiB NOSRV POST can be fully buffered before the 503 — eliminating
# the RST race for the reproducer payload. Memory cost; lab-only.
#
# HAProxy 2.8 (OCP router) has METH_POST/METH_PUT but not METH_PATCH —
# use `{ method PATCH }` for PATCH. POST is the OCPBUGS-129094 trigger.
#
# IMPORTANT: do not use ${VAR:-...{ }...} — the ACL's closing "}" terminates
# the parameter expansion early and can append a stray "}".
if [[ -z "${WAIT_FOR_BODY_LINE+x}" ]]; then
  WAIT_FOR_BODY_LINE='http-request wait-for-body time 30s if METH_POST or METH_PUT or { method PATCH }'
fi
# tune.bufsize via OpenShift router env (must be > body size to absorb full POST)
ROUTER_BUF_SIZE="${ROUTER_BUF_SIZE:-2097152}"

CYAN=$'\033[0;36m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
[[ -t 1 ]] || { CYAN=; GREEN=; YELLOW=; RED=; NC=; }
info() { printf '%sℹ%s  %s\n' "$CYAN" "$NC" "$*"; }
ok()   { printf '%s✓%s  %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s⚠%s  %s\n' "$YELLOW" "$NC" "$*"; }
err()  { printf '%s✗%s  %s\n' "$RED" "$NC" "$*" >&2; }

need_oc() {
  command -v oc >/dev/null || { err "oc not found"; exit 1; }
  oc whoami >/dev/null 2>&1 || { err "oc not logged in"; exit 1; }
  command -v python3 >/dev/null || { err "python3 required"; exit 1; }
}

inject_wait_for_body() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" "$WAIT_FOR_BODY_LINE" <<'PY'
import sys
src, dst, line = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src, encoding="utf-8", errors="replace").read()
marker = "# OCPBUGS-129094: buffer body before routing (NOSRV 503/RST race mitigation)"
if marker in text:
    # Already injected — refresh the directive line only
    import re
    text = re.sub(
        r"# OCPBUGS-129094:.*\n\s*http-request wait-for-body[^\n]*\n",
        marker + "\n  " + line + "\n",
        text,
    )
else:
    needle = "  http-request del-header Proxy\n"
    insert = needle + "\n  " + marker + "\n  " + line + "\n"
    count = text.count(needle)
    if count == 0:
        sys.stderr.write("ERROR: no 'http-request del-header Proxy' in template\n")
        sys.exit(1)
    text = text.replace(needle, insert)
    sys.stderr.write(f"Injected wait-for-body after {count} del-header Proxy site(s)\n")
open(dst, "w", encoding="utf-8").write(text)
PY
}

build_custom_deploy_json() {
  local source_json="$1" out_json="$2"
  python3 - "$source_json" "$out_json" "$CUSTOM_DEPLOY" "$CUSTOM_CM" "$REPLICAS" "$ROUTER_BUF_SIZE" <<'PY'
import json, sys
src, out, name, cm, replicas, bufsize = sys.argv[1:7]
d = json.load(open(src))
# Strip cluster status / ownership
for k in ("status", "managedFields"):
    d.pop(k, None)
md = d["metadata"]
for k in ("uid", "resourceVersion", "generation", "creationTimestamp",
          "managedFields", "selfLink", "generation"):
    md.pop(k, None)
md["name"] = name
md["namespace"] = d["metadata"].get("namespace", "openshift-ingress")
md["labels"] = {
    "app": name,
    "ocpbugs-129094": "custom-router",
}
md.pop("annotations", None)
md.pop("ownerReferences", None)

spec = d["spec"]
spec["replicas"] = int(replicas)
spec["selector"] = {"matchLabels": {"app": name}}
pod = spec["template"]
pod["metadata"] = {
    "labels": {"app": name, "ocpbugs-129094": "custom-router"},
    "annotations": (pod.get("metadata") or {}).get("annotations") or {},
}
# Drop operator hash annotation noise if present
ann = pod["metadata"]["annotations"]
for k in list(ann):
    if "ingresscontroller.operator" in k or k.startswith("kubectl.kubernetes.io"):
        ann.pop(k, None)

ps = pod["spec"]
# Ensure router SA
ps["serviceAccountName"] = ps.get("serviceAccountName") or "router"
# Drop operator topology spread that selects the default IC hash
ps.pop("topologySpreadConstraints", None)
c = ps["containers"][0]
c["name"] = "router"
# Allow slow first sync (large clusters / cold informers)
for probe_name in ("startupProbe", "readinessProbe", "livenessProbe"):
    probe = c.get(probe_name) or {}
    if probe_name == "startupProbe":
        probe["failureThreshold"] = 600
        probe["periodSeconds"] = 1
        c[probe_name] = probe

# Env updates
env = {e["name"]: e for e in c.get("env", [])}
def set_env(k, v):
    env[k] = {"name": k, "value": v}
set_env("ROUTER_SERVICE_NAME", name.replace("router-", "") if name.startswith("router-") else name)
set_env("TEMPLATE_FILE", "/var/lib/haproxy/conf/custom/haproxy-config.template")
# Required when a second router also serves the same routes as router-default
set_env("ROUTER_DISABLE_NAMESPACE_OWNERSHIP_CHECK", "true")
# Raise request buffer so wait-for-body can absorb large NOSRV POSTs (lab)
set_env("ROUTER_BUF_SIZE", str(bufsize))
# Unique stats identity; keep domain from source so route Host headers still match
if "ROUTER_CANONICAL_HOSTNAME" in env and "value" in env["ROUTER_CANONICAL_HOSTNAME"]:
    domain = env.get("ROUTER_DOMAIN", {}).get("value", "")
    set_env("ROUTER_CANONICAL_HOSTNAME", f"{name}.{domain}" if domain else name)
c["env"] = list(env.values())

# Volume + mount for custom template
vols = ps.setdefault("volumes", [])
vols = [v for v in vols if v.get("name") != "custom-haproxy-template"]
vols.append({
    "name": "custom-haproxy-template",
    "configMap": {"name": cm, "defaultMode": 420},
})
ps["volumes"] = vols
mounts = c.setdefault("volumeMounts", [])
mounts = [m for m in mounts if m.get("name") != "custom-haproxy-template"]
mounts.append({
    "name": "custom-haproxy-template",
    "mountPath": "/var/lib/haproxy/conf/custom",
    "readOnly": True,
})
c["volumeMounts"] = mounts

json.dump(d, open(out, "w"), indent=2)
print(f"Wrote custom Deployment JSON → {out}")
PY
}

cmd_apply() {
  need_oc
  mkdir -p "$WORKDIR"

  info "Using source Deployment ${INGRESS_NS}/${SOURCE_DEPLOY}"
  oc -n "$INGRESS_NS" get "deploy/${SOURCE_DEPLOY}" -o json > "${WORKDIR}/source-deploy.json"

  local pod
  pod="$(oc -n "$INGRESS_NS" get pod \
    -l "ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$pod" ]]; then
    pod="$(oc -n "$INGRESS_NS" get pod -l app="${SOURCE_DEPLOY}" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  fi
  [[ -n "$pod" ]] || { err "No running source router pod found"; exit 1; }
  info "Extracting haproxy-config.template from pod/${pod}"
  oc -n "$INGRESS_NS" exec "$pod" -- cat haproxy-config.template \
    > "${WORKDIR}/haproxy-config.template.stock"

  info "Injecting: ${WAIT_FOR_BODY_LINE}"
  inject_wait_for_body \
    "${WORKDIR}/haproxy-config.template.stock" \
    "${WORKDIR}/haproxy-config.template"

  grep -n 'wait-for-body' "${WORKDIR}/haproxy-config.template" | head -20 \
    || { err "injection failed"; exit 1; }

  info "Creating ConfigMap ${CUSTOM_CM}"
  oc -n "$INGRESS_NS" create configmap "$CUSTOM_CM" \
    --from-file=haproxy-config.template="${WORKDIR}/haproxy-config.template" \
    --dry-run=client -o yaml | oc apply -f -

  info "Building custom Deployment ${CUSTOM_DEPLOY}"
  build_custom_deploy_json \
    "${WORKDIR}/source-deploy.json" \
    "${WORKDIR}/custom-deploy.json"
  oc apply -f "${WORKDIR}/custom-deploy.json"
  # ConfigMap changes do not always roll the Deployment; force remount + haproxy regen
  info "Restarting ${CUSTOM_DEPLOY} so the new template is loaded"
  oc -n "$INGRESS_NS" rollout restart "deploy/${CUSTOM_DEPLOY}"

  info "Creating NetworkPolicy (openshift-ingress has deny-all; mirror router-default allow)"
  oc -n "$INGRESS_NS" apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${CUSTOM_DEPLOY}
  namespace: ${INGRESS_NS}
  labels:
    app: ${CUSTOM_DEPLOY}
    ocpbugs-129094: custom-router
spec:
  podSelector:
    matchLabels:
      app: ${CUSTOM_DEPLOY}
  policyTypes:
    - Ingress
    - Egress
  egress:
    - {}
  ingress:
    - ports:
        - port: http
          protocol: TCP
        - port: https
          protocol: TCP
        - port: metrics
          protocol: TCP
EOF

  info "Creating LoadBalancer Service ${CUSTOM_SVC}"
  oc -n "$INGRESS_NS" apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${CUSTOM_SVC}
  namespace: ${INGRESS_NS}
  labels:
    app: ${CUSTOM_DEPLOY}
    ocpbugs-129094: custom-router
spec:
  type: LoadBalancer
  selector:
    app: ${CUSTOM_DEPLOY}
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
    - name: https
      port: 443
      targetPort: https
      protocol: TCP
EOF

  info "Waiting for Deployment rollout..."
  oc -n "$INGRESS_NS" rollout status "deploy/${CUSTOM_DEPLOY}" --timeout=300s

  info "Waiting for LoadBalancer EXTERNAL-IP (may take a few minutes on Azure)..."
  local ip="" i
  for i in $(seq 1 60); do
    ip="$(oc -n "$INGRESS_NS" get svc "$CUSTOM_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -z "$ip" ]] && ip="$(oc -n "$INGRESS_NS" get svc "$CUSTOM_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    [[ -n "$ip" ]] && break
    sleep 5
  done

  # Verify on a Ready pod only (avoid stale terminating replicas)
  local cpod
  cpod="$(oc -n "$INGRESS_NS" get pods -l "app=${CUSTOM_DEPLOY}" -o json | python3 -c '
import json,sys
for p in json.load(sys.stdin)["items"]:
    cs=(p.get("status") or {}).get("containerStatuses") or [{}]
    if (p.get("status") or {}).get("phase")=="Running" and cs and cs[0].get("ready"):
        print(p["metadata"]["name"]); break
')"
  [[ -n "$cpod" ]] || { err "No Ready custom router pod"; exit 1; }
  info "Verifying generated haproxy.config in Ready pod/${cpod}"
  oc -n "$INGRESS_NS" exec "$cpod" -- printenv TEMPLATE_FILE
  oc -n "$INGRESS_NS" exec "$cpod" -- printenv ROUTER_BUF_SIZE || true
  oc -n "$INGRESS_NS" exec "$cpod" -- grep -nE 'wait-for-body|tune.bufsize' haproxy.config | head -20 \
    || warn "wait-for-body not yet in haproxy.config (reload pending?)"
  local bsz
  bsz="$(oc -n "$INGRESS_NS" exec "$cpod" -- awk '/tune.bufsize/{print $2; exit}' haproxy.config 2>/dev/null || true)"
  if [[ -z "$bsz" || "$bsz" -lt 1048576 ]]; then
    err "tune.bufsize=${bsz:-missing} < 1MiB — 1MiB POSTs will still RST; fix ROUTER_BUF_SIZE and re-apply"
    exit 1
  fi
  ok "tune.bufsize=${bsz} (>= 1MiB) + wait-for-body present"

  echo
  ok "Custom router applied"
  info "Service: ${INGRESS_NS}/${CUSTOM_SVC}"
  if [[ -n "$ip" ]]; then
    ok "EXTERNAL: ${ip}"
    echo
    info "Prove RST eliminated (write-first — not full-speed curl):"
    echo "  ./reproducer.sh run-compare --route edge --sizes 1048576"
    echo "  # or: ./reproducer.sh probe-writefirst --route edge --router-addr ${ip}"
  else
    warn "EXTERNAL-IP not ready yet — check: oc -n ${INGRESS_NS} get svc ${CUSTOM_SVC}"
  fi
  echo
  warn "Unsupported lab pattern: unmanaged custom template (not a supported OCP feature)."
}

cmd_status() {
  need_oc
  oc -n "$INGRESS_NS" get deploy,svc,pods -l ocpbugs-129094=custom-router 2>/dev/null || true
  oc -n "$INGRESS_NS" get "deploy/${CUSTOM_DEPLOY}" "svc/${CUSTOM_SVC}" 2>/dev/null || warn "custom router not found"
  local cpod
  cpod="$(oc -n "$INGRESS_NS" get pod -l "app=${CUSTOM_DEPLOY}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$cpod" ]]; then
    info "TEMPLATE_FILE=$(oc -n "$INGRESS_NS" exec "$cpod" -- printenv TEMPLATE_FILE 2>/dev/null || true)"
    oc -n "$INGRESS_NS" exec "$cpod" -- grep -c 'wait-for-body' haproxy.config 2>/dev/null \
      | awk '{print "wait-for-body lines in haproxy.config: "$1}'
  fi
}

cmd_remove() {
  need_oc
  info "Removing custom router resources"
  oc -n "$INGRESS_NS" delete deploy "$CUSTOM_DEPLOY" --ignore-not-found
  oc -n "$INGRESS_NS" delete svc "$CUSTOM_SVC" --ignore-not-found
  oc -n "$INGRESS_NS" delete networkpolicy "$CUSTOM_DEPLOY" --ignore-not-found
  oc -n "$INGRESS_NS" delete configmap "$CUSTOM_CM" --ignore-not-found
  ok "Removed ${CUSTOM_DEPLOY} / ${CUSTOM_SVC} / NetworkPolicy / ${CUSTOM_CM}"
}

usage() {
  cat <<EOF
OCPBUGS-129094 — apply custom router with wait-for-body

  $0 apply     Clone ${SOURCE_DEPLOY}, inject wait-for-body, expose LB
  $0 status
  $0 remove

Injected directive (override with WAIT_FOR_BODY_LINE):
  ${WAIT_FOR_BODY_LINE}
EOF
}

case "${1:-}" in
  apply)  cmd_apply ;;
  status) cmd_status ;;
  remove) cmd_remove ;;
  *) usage; exit 0 ;;
esac
