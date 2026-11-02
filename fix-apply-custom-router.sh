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
#   ./fix-apply-custom-router.sh apply              # prompt (TTY) or use recommended
#   ./fix-apply-custom-router.sh apply -y           # all recommended, no prompts
#   ./fix-apply-custom-router.sh apply --buf-size 2097152 --keep-alive 5s ...
#   ./fix-apply-custom-router.sh status
#   ./fix-apply-custom-router.sh remove
#
# Env (same names as flags; set before invoke to skip prompt for that param):
#   INGRESS_NS SOURCE_DEPLOY CUSTOM_DEPLOY CUSTOM_SVC REPLICAS
#   WAIT_FOR_BODY_LINE ROUTER_BUF_SIZE ROUTER_SLOWLORIS_HTTP_KEEPALIVE
#   ROUTER_IDLE_CLOSE_ON_RESPONSE ROUTER_CLIENT_FIN_TIMEOUT
#   ROUTER_DEFAULT_SERVER_FIN_TIMEOUT ROUTER_MAX_CONNECTIONS

set -euo pipefail

INGRESS_NS="${INGRESS_NS:-openshift-ingress}"
SOURCE_DEPLOY="${SOURCE_DEPLOY:-router-default}"
CUSTOM_DEPLOY="${CUSTOM_DEPLOY:-router-ocpbugs-129094}"
CUSTOM_SVC="${CUSTOM_SVC:-router-ocpbugs-129094}"
CUSTOM_CM="${CUSTOM_CM:-custom-haproxy-template-ocpbugs-129094}"
REPLICAS="${REPLICAS:-1}"
WORKDIR="${WORKDIR:-${TMPDIR:-/tmp}/ocpbugs-129094-fix}"

# ---------------------------------------------------------------------------
# Recommended lab optimizations (shown as [recommended] when prompting).
#
# Do NOT use a small "at-least N" (e.g. 1k): wait ends after N bytes, then
# NOSRV 503/RST still races the remainder of a large upload.
# Even without at-least, HAProxy stops waiting when tune.bufsize is full
# (OCP router default 32768). Lab fix raises ROUTER_BUF_SIZE (2 MiB) so a
# 1 MiB NOSRV POST can be fully buffered before the 503.
#
# HAProxy 2.8 (OCP router) has METH_POST/METH_PUT but not METH_PATCH —
# use `{ method PATCH }` for PATCH.
#
# IMPORTANT: do not use ${VAR:-...{ }...} — the ACL's closing "}" terminates
# the parameter expansion early and can append a stray "}".
# ---------------------------------------------------------------------------
REC_WAIT_FOR_BODY_LINE='http-request wait-for-body time 30s if METH_POST or METH_PUT or { method PATCH }'
REC_ROUTER_BUF_SIZE='2097152'
REC_ROUTER_SLOWLORIS_HTTP_KEEPALIVE='5s'
REC_ROUTER_IDLE_CLOSE_ON_RESPONSE='true'
REC_ROUTER_CLIENT_FIN_TIMEOUT='1s'
REC_ROUTER_DEFAULT_SERVER_FIN_TIMEOUT='1s'
# Empty recommended = leave source router maxconn (optional cap e.g. 500)
REC_ROUTER_MAX_CONNECTIONS=''

# Tunables — may already be set via exported env; otherwise filled by
# CLI flags / interactive prompt / recommended defaults in resolve_apply_params.
# Do not force-clear here (would wipe caller exports).
APPLY_YES=0   # -y / --yes → skip prompts, use recommended for unset

CYAN=$'\033[0;36m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
BOLD=$'\033[1m'; DIM=$'\033[2m'
[[ -t 1 ]] || { CYAN=; GREEN=; YELLOW=; RED=; NC=; BOLD=; DIM=; }
info() { printf '%sℹ%s  %s\n' "$CYAN" "$NC" "$*"; }
ok()   { printf '%s✓%s  %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s⚠%s  %s\n' "$YELLOW" "$NC" "$*"; }
err()  { printf '%s✗%s  %s\n' "$RED" "$NC" "$*" >&2; }

# Prompt: "Label [recommended]: " — empty Enter → recommended.
# If var already non-empty (CLI/env), skip. APPLY_YES or non-TTY → recommended.
prompt_param() {
  # $1 = varname  $2 = label  $3 = recommended  $4 = optional help
  local varname="$1" label="$2" recommended="$3" help="${4:-}"
  local current="${!varname-}"
  if [[ -n "$current" ]]; then
    return 0
  fi
  local display_rec="$recommended"
  [[ -z "$display_rec" ]] && display_rec="<leave stock>"
  if [[ "$APPLY_YES" -eq 1 ]] || [[ ! -t 0 ]]; then
    printf -v "$varname" '%s' "$recommended"
    return 0
  fi
  [[ -n "$help" ]] && printf '  %s%s%s\n' "$DIM" "$help" "$NC"
  local ans=""
  printf '  %s%s%s [%s]: ' "$BOLD" "$label" "$NC" "$display_rec"
  IFS= read -r ans || true
  if [[ -z "$ans" ]]; then
    printf -v "$varname" '%s' "$recommended"
  else
    printf -v "$varname" '%s' "$ans"
  fi
}

resolve_apply_params() {
  # Prefer values already set via CLI parse or exported env (captured below).
  prompt_param WAIT_FOR_BODY_LINE \
    "WAIT_FOR_BODY_LINE" "$REC_WAIT_FOR_BODY_LINE" \
    "HAProxy directive injected into each HTTP frontend (omit small at-least)"
  prompt_param ROUTER_BUF_SIZE \
    "ROUTER_BUF_SIZE" "$REC_ROUTER_BUF_SIZE" \
    "tune.bufsize — must be >= max POST body (2 MiB for 1 MiB write-first)"
  prompt_param ROUTER_SLOWLORIS_HTTP_KEEPALIVE \
    "ROUTER_SLOWLORIS_HTTP_KEEPALIVE" "$REC_ROUTER_SLOWLORIS_HTTP_KEEPALIVE" \
    "timeout http-keep-alive — short so large buffers are not held idle (stock 300s)"
  prompt_param ROUTER_IDLE_CLOSE_ON_RESPONSE \
    "ROUTER_IDLE_CLOSE_ON_RESPONSE" "$REC_ROUTER_IDLE_CLOSE_ON_RESPONSE" \
    "option idle-close-on-response — close after response completes"
  prompt_param ROUTER_CLIENT_FIN_TIMEOUT \
    "ROUTER_CLIENT_FIN_TIMEOUT" "$REC_ROUTER_CLIENT_FIN_TIMEOUT" \
    "timeout client-fin — fast teardown after close"
  prompt_param ROUTER_DEFAULT_SERVER_FIN_TIMEOUT \
    "ROUTER_DEFAULT_SERVER_FIN_TIMEOUT" "$REC_ROUTER_DEFAULT_SERVER_FIN_TIMEOUT" \
    "timeout server-fin — fast teardown after close"
  prompt_param ROUTER_MAX_CONNECTIONS \
    "ROUTER_MAX_CONNECTIONS" "$REC_ROUTER_MAX_CONNECTIONS" \
    "maxconn cap (optional) — bounds maxconn × bufsize; empty = leave source default"

  # Always-on dual-router requirement (not prompted)
  info "ROUTER_DISABLE_NAMESPACE_OWNERSHIP_CHECK=true (required for dual routers)"

  echo
  info "Applying customizations:"
  printf '  %-40s %s\n' "WAIT_FOR_BODY_LINE" "$WAIT_FOR_BODY_LINE"
  printf '  %-40s %s\n' "ROUTER_BUF_SIZE" "$ROUTER_BUF_SIZE"
  printf '  %-40s %s\n' "ROUTER_SLOWLORIS_HTTP_KEEPALIVE" "$ROUTER_SLOWLORIS_HTTP_KEEPALIVE"
  printf '  %-40s %s\n' "ROUTER_IDLE_CLOSE_ON_RESPONSE" "$ROUTER_IDLE_CLOSE_ON_RESPONSE"
  printf '  %-40s %s\n' "ROUTER_CLIENT_FIN_TIMEOUT" "$ROUTER_CLIENT_FIN_TIMEOUT"
  printf '  %-40s %s\n' "ROUTER_DEFAULT_SERVER_FIN_TIMEOUT" "$ROUTER_DEFAULT_SERVER_FIN_TIMEOUT"
  printf '  %-40s %s\n' "ROUTER_MAX_CONNECTIONS" "${ROUTER_MAX_CONNECTIONS:-<leave stock>}"
  printf '  %-40s %s\n' "ROUTER_DISABLE_NAMESPACE_OWNERSHIP_CHECK" "true"
  echo
}

parse_apply_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)
        APPLY_YES=1; shift ;;
      --buf-size|--router-buf-size)
        ROUTER_BUF_SIZE="${2:-}"; shift 2 ;;
      --keep-alive|--http-keep-alive)
        ROUTER_SLOWLORIS_HTTP_KEEPALIVE="${2:-}"; shift 2 ;;
      --idle-close)
        ROUTER_IDLE_CLOSE_ON_RESPONSE="${2:-}"; shift 2 ;;
      --client-fin)
        ROUTER_CLIENT_FIN_TIMEOUT="${2:-}"; shift 2 ;;
      --server-fin)
        ROUTER_DEFAULT_SERVER_FIN_TIMEOUT="${2:-}"; shift 2 ;;
      --max-connections|--maxconn)
        ROUTER_MAX_CONNECTIONS="${2:-}"; shift 2 ;;
      --wait-for-body-line)
        WAIT_FOR_BODY_LINE="${2:-}"; shift 2 ;;
      -h|--help)
        usage_apply; exit 0 ;;
      *)
        err "unknown apply option: $1"
        usage_apply
        exit 1 ;;
    esac
  done
}

usage_apply() {
  cat <<EOF
Usage: $0 apply [options]

Interactive (TTY): prompts for each unset parameter; Enter accepts [recommended].
Non-interactive / -y: uses recommended values for anything not passed.

Options:
  -y, --yes                         Accept all recommended values (no prompts)
  --buf-size <bytes>                ROUTER_BUF_SIZE                 [${REC_ROUTER_BUF_SIZE}]
  --keep-alive <duration>           ROUTER_SLOWLORIS_HTTP_KEEPALIVE [${REC_ROUTER_SLOWLORIS_HTTP_KEEPALIVE}]
  --idle-close <true|false>         ROUTER_IDLE_CLOSE_ON_RESPONSE   [${REC_ROUTER_IDLE_CLOSE_ON_RESPONSE}]
  --client-fin <duration>           ROUTER_CLIENT_FIN_TIMEOUT       [${REC_ROUTER_CLIENT_FIN_TIMEOUT}]
  --server-fin <duration>           ROUTER_DEFAULT_SERVER_FIN_TIMEOUT [${REC_ROUTER_DEFAULT_SERVER_FIN_TIMEOUT}]
  --max-connections <n>             ROUTER_MAX_CONNECTIONS          [<leave stock>]
  --wait-for-body-line <directive>  WAIT_FOR_BODY_LINE              [lab wait-for-body]

Also always sets:
  ROUTER_DISABLE_NAMESPACE_OWNERSHIP_CHECK=true
  TEMPLATE_FILE=/var/lib/haproxy/conf/custom/haproxy-config.template

Examples:
  $0 apply
  $0 apply -y
  $0 apply --buf-size 2097152 --keep-alive 5s --idle-close true
  ROUTER_BUF_SIZE=1048576 $0 apply --keep-alive 1s
EOF
}

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
  python3 - "$source_json" "$out_json" "$CUSTOM_DEPLOY" "$CUSTOM_CM" "$REPLICAS" \
    "$ROUTER_BUF_SIZE" \
    "$ROUTER_SLOWLORIS_HTTP_KEEPALIVE" \
    "$ROUTER_IDLE_CLOSE_ON_RESPONSE" \
    "$ROUTER_CLIENT_FIN_TIMEOUT" \
    "$ROUTER_DEFAULT_SERVER_FIN_TIMEOUT" \
    "${ROUTER_MAX_CONNECTIONS}" <<'PY'
import json, sys
src, out, name, cm, replicas, bufsize, ka, idle_close, client_fin, server_fin, maxconn = sys.argv[1:12]
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
# Release connections quickly — avoid long keep-alive holding large buffers
set_env("ROUTER_SLOWLORIS_HTTP_KEEPALIVE", ka)          # timeout http-keep-alive
set_env("ROUTER_IDLE_CLOSE_ON_RESPONSE", idle_close)    # option idle-close-on-response
set_env("ROUTER_CLIENT_FIN_TIMEOUT", client_fin)        # timeout client-fin
set_env("ROUTER_DEFAULT_SERVER_FIN_TIMEOUT", server_fin)  # timeout server-fin
if maxconn:
    set_env("ROUTER_MAX_CONNECTIONS", str(maxconn))
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
  resolve_apply_params
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
  oc -n "$INGRESS_NS" exec "$cpod" -- printenv \
    ROUTER_BUF_SIZE ROUTER_SLOWLORIS_HTTP_KEEPALIVE ROUTER_IDLE_CLOSE_ON_RESPONSE \
    ROUTER_CLIENT_FIN_TIMEOUT ROUTER_DEFAULT_SERVER_FIN_TIMEOUT 2>/dev/null || true
  oc -n "$INGRESS_NS" exec "$cpod" -- grep -nE \
    'wait-for-body|tune.bufsize|timeout http-keep-alive|timeout client-fin|idle-close-on-response' \
    haproxy.config | head -30 \
    || warn "wait-for-body not yet in haproxy.config (reload pending?)"
  local bsz
  bsz="$(oc -n "$INGRESS_NS" exec "$cpod" -- awk '/tune.bufsize/{print $2; exit}' haproxy.config 2>/dev/null || true)"
  if [[ -z "$bsz" || "$bsz" -lt 1048576 ]]; then
    err "tune.bufsize=${bsz:-missing} < 1MiB — 1MiB POSTs will still RST; fix ROUTER_BUF_SIZE and re-apply"
    exit 1
  fi
  ok "tune.bufsize=${bsz} (>= 1MiB) + wait-for-body present"
  local ka_live idle_live
  ka_live="$(oc -n "$INGRESS_NS" exec "$cpod" -- awk '/timeout http-keep-alive/{print $NF; exit}' haproxy.config 2>/dev/null || true)"
  idle_live="$(oc -n "$INGRESS_NS" exec "$cpod" -- grep -c 'option idle-close-on-response' haproxy.config 2>/dev/null || echo 0)"
  if [[ "$ka_live" != "${ROUTER_SLOWLORIS_HTTP_KEEPALIVE}" ]]; then
    warn "timeout http-keep-alive=${ka_live:-missing} (wanted ${ROUTER_SLOWLORIS_HTTP_KEEPALIVE}) — check ROUTER_SLOWLORIS_HTTP_KEEPALIVE on the pod"
  else
    ok "timeout http-keep-alive=${ka_live}"
  fi
  if [[ "${idle_live:-0}" -lt 1 ]]; then
    warn "option idle-close-on-response missing — set ROUTER_IDLE_CLOSE_ON_RESPONSE=true"
  else
    ok "option idle-close-on-response present (${idle_live} site(s))"
  fi

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
  local BOLD=$'\033[1m' DIM=$'\033[2m' NC_LOCAL=$'\033[0m'
  [[ -t 1 ]] || { BOLD=; DIM=; NC_LOCAL=; }

  echo
  printf '%s────────────────────────────────────────────────────────────%s\n' "$DIM" "$NC_LOCAL"
  printf '%sOCPBUGS-129094  ·  fix-status  ·  custom router customizations%s\n' "$BOLD" "$NC_LOCAL"
  printf '%s────────────────────────────────────────────────────────────%s\n' "$DIM" "$NC_LOCAL"

  # --- resources ---
  local deploy_ok=0 svc_ok=0 cm_ok=0 np_ok=0
  oc -n "$INGRESS_NS" get "deploy/${CUSTOM_DEPLOY}" &>/dev/null && deploy_ok=1
  oc -n "$INGRESS_NS" get "svc/${CUSTOM_SVC}" &>/dev/null && svc_ok=1
  oc -n "$INGRESS_NS" get "cm/${CUSTOM_CM}" &>/dev/null && cm_ok=1
  oc -n "$INGRESS_NS" get "networkpolicy/${CUSTOM_DEPLOY}" &>/dev/null && np_ok=1

  printf '\n  %sResources%s (%s/%s)\n' "$BOLD" "$NC_LOCAL" "$INGRESS_NS" "$CUSTOM_DEPLOY"
  printf '  %-28s  %s\n' "Deployment" "$([[ "$deploy_ok" -eq 1 ]] && echo "present" || echo "MISSING")"
  printf '  %-28s  %s\n' "Service (LB)" "$([[ "$svc_ok" -eq 1 ]] && echo "present" || echo "MISSING")"
  printf '  %-28s  %s\n' "ConfigMap (template)" "$([[ "$cm_ok" -eq 1 ]] && echo "present" || echo "MISSING")"
  printf '  %-28s  %s\n' "NetworkPolicy" "$([[ "$np_ok" -eq 1 ]] && echo "present" || echo "MISSING")"

  if [[ "$deploy_ok" -ne 1 ]]; then
    warn "Custom router not applied — run: $0 apply"
    return 1
  fi

  local lb
  lb="$(oc -n "$INGRESS_NS" get svc "$CUSTOM_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -z "$lb" ]] && lb="$(oc -n "$INGRESS_NS" get svc "$CUSTOM_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  printf '  %-28s  %s\n' "EXTERNAL-IP" "${lb:-pending}"

  local ready avail
  ready="$(oc -n "$INGRESS_NS" get deploy "$CUSTOM_DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  avail="$(oc -n "$INGRESS_NS" get deploy "$CUSTOM_DEPLOY" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
  printf '  %-28s  %s ready / %s available\n' "Replicas" "${ready:-0}" "${avail:-0}"

  # Prefer Ready pod
  local cpod
  cpod="$(oc -n "$INGRESS_NS" get pods -l "app=${CUSTOM_DEPLOY}" -o json 2>/dev/null | python3 -c '
import json,sys
try:
    items=json.load(sys.stdin).get("items") or []
except Exception:
    items=[]
for p in items:
    cs=(p.get("status") or {}).get("containerStatuses") or [{}]
    if (p.get("status") or {}).get("phase")=="Running" and cs and cs[0].get("ready"):
        print(p["metadata"]["name"]); break
' 2>/dev/null || true)"

  if [[ -z "$cpod" ]]; then
    warn "No Ready pod — cannot inspect live haproxy.config"
    oc -n "$INGRESS_NS" get pods -l "app=${CUSTOM_DEPLOY}" -o wide 2>/dev/null || true
    return 1
  fi
  printf '  %-28s  %s\n' "Ready pod" "$cpod"

  # --- deploy env (desired) ---
  local env_json
  env_json="$(oc -n "$INGRESS_NS" get deploy "$CUSTOM_DEPLOY" -o json)"

  get_deploy_env() {
    local key="$1"
    printf '%s' "$env_json" | python3 -c '
import json,sys
key=sys.argv[1]
d=json.load(sys.stdin)
for e in d["spec"]["template"]["spec"]["containers"][0].get("env") or []:
    if e.get("name")==key:
        print(e.get("value",""))
        break
' "$key" 2>/dev/null || true
  }

  # --- live config from Ready pod ---
  local live_cfg live_env
  live_cfg="$(oc -n "$INGRESS_NS" exec "$cpod" -- cat haproxy.config 2>/dev/null || true)"
  live_env="$(oc -n "$INGRESS_NS" exec "$cpod" -- printenv 2>/dev/null || true)"

  get_live_env() {
    local key="$1"
    printf '%s\n' "$live_env" | awk -F= -v k="$key" '$1==k{print substr($0,index($0,"=")+1); exit}'
  }

  cfg_val() {
    # first matching line → print last whitespace-separated field (the value)
    local pat="$1"
    printf '%s\n' "$live_cfg" | awk "$pat"' {print $NF; exit}'
  }

  cfg_count() {
    local pat="$1" n
    n="$(printf '%s\n' "$live_cfg" | grep -cE "$pat" 2>/dev/null || true)"
    [[ -z "$n" ]] && n=0
    printf '%s' "$n"
  }

  cfg_line() {
    local pat="$1"
    printf '%s\n' "$live_cfg" | grep -E "$pat" | head -1 | sed 's/^[[:space:]]*//'
  }

  # Summarize which haproxy.config section(s) a directive lives in.
  # Examples: "global" | "defaults" | "frontend ×3 (public,fe_sni,fe_no_sni)" | "—"
  cfg_section() {
    local regex="$1"
    printf '%s\n' "$live_cfg" | python3 -c '
import re, sys
from collections import OrderedDict
regex = sys.argv[1]
pat = re.compile(regex)
sec_re = re.compile(
    r"^(global|defaults|frontend|backend|listen|peers|resolvers|"
    r"userlist|mailers|ring|program)\s*(\S+)?"
)
kind = name = None
hits = []
for raw in sys.stdin:
    s = raw.strip()
    if not s or s.startswith("#"):
        continue
    m = sec_re.match(s)
    if m:
        kind = m.group(1)
        name = m.group(2) or m.group(1)
        continue
    if pat.search(s):
        hits.append((kind or "?", name or "?"))
if not hits:
    print("—")
    raise SystemExit(0)
by = OrderedDict()
for k, n in hits:
    by.setdefault(k, [])
    if n not in by[k]:
        by[k].append(n)
parts = []
for k, names in by.items():
    if k in ("global", "defaults"):
        parts.append(k)
    elif len(names) == 1:
        parts.append(f"{k} {names[0]}")
    else:
        shown = ",".join(names[:3])
        extra = f"+{len(names)-3}" if len(names) > 3 else ""
        parts.append(f"{k} ×{len(names)} ({shown}{extra})")
print(", ".join(parts))
' "$regex" 2>/dev/null || echo "—"
  }

  local tf buf_env buf_live wfb_count wfb_line
  local ka_env ka_live idle_env idle_live
  local cfin_env cfin_live sfin_env sfin_live
  local own_env maxc_env maxc_live
  local sec_buf sec_wfb sec_ka sec_idle sec_cfin sec_sfin sec_maxc
  local cm_wfb=0 st_wfb st_buf st_ka st_idle st_cfin st_sfin st_tf st_own st_maxc st_cm
  local live_wfb live_buf live_ka live_idle live_cfin live_sfin live_tf live_own live_maxc live_cm

  tf="$(get_live_env TEMPLATE_FILE)"
  buf_env="$(get_deploy_env ROUTER_BUF_SIZE)"
  buf_live="$(cfg_val '/tune\.bufsize/')"
  sec_buf="$(cfg_section 'tune\.bufsize')"
  wfb_count="$(cfg_count 'http-request wait-for-body')"
  wfb_line="$(cfg_line 'http-request wait-for-body')"
  sec_wfb="$(cfg_section 'http-request wait-for-body')"
  ka_env="$(get_deploy_env ROUTER_SLOWLORIS_HTTP_KEEPALIVE)"
  ka_live="$(cfg_val '/timeout http-keep-alive/')"
  sec_ka="$(cfg_section 'timeout http-keep-alive')"
  idle_env="$(get_deploy_env ROUTER_IDLE_CLOSE_ON_RESPONSE)"
  idle_live="$(cfg_count 'option idle-close-on-response')"
  sec_idle="$(cfg_section 'option idle-close-on-response')"
  cfin_env="$(get_deploy_env ROUTER_CLIENT_FIN_TIMEOUT)"
  cfin_live="$(cfg_val '/timeout client-fin/')"
  sec_cfin="$(cfg_section 'timeout client-fin')"
  sfin_env="$(get_deploy_env ROUTER_DEFAULT_SERVER_FIN_TIMEOUT)"
  sfin_live="$(cfg_val '/timeout server-fin/')"
  sec_sfin="$(cfg_section 'timeout server-fin')"
  own_env="$(get_live_env ROUTER_DISABLE_NAMESPACE_OWNERSHIP_CHECK)"
  maxc_env="$(get_deploy_env ROUTER_MAX_CONNECTIONS)"
  maxc_live="$(cfg_val '/^[[:space:]]*maxconn /')"
  # lines are strip()'d in cfg_section — use Python \s (not POSIX [[:space:]])
  sec_maxc="$(cfg_section '^maxconn\s')"

  if [[ "$cm_ok" -eq 1 ]]; then
    cm_wfb="$(oc -n "$INGRESS_NS" get cm "$CUSTOM_CM" -o jsonpath='{.data.haproxy-config\.template}' 2>/dev/null \
      | grep -c 'wait-for-body' || true)"
    [[ -z "$cm_wfb" ]] && cm_wfb=0
  fi

  # --- status / live columns ---
  if [[ "${wfb_count:-0}" -ge 1 ]]; then
    st_wfb=APPLIED; live_wfb="${wfb_count} site(s)"
  else
    st_wfb=MISSING; live_wfb="not found"
  fi

  if [[ -n "$buf_live" && "$buf_live" -ge 1048576 ]]; then
    st_buf=APPLIED; live_buf="$buf_live"
  elif [[ -n "$buf_live" ]]; then
    st_buf=STOCK; live_buf="$buf_live"
  else
    st_buf=MISSING; live_buf="missing"
  fi

  if [[ -n "$ka_live" && "$ka_live" != "300s" ]]; then
    st_ka=APPLIED; live_ka="$ka_live"
  elif [[ "$ka_live" == "300s" ]]; then
    st_ka=STOCK; live_ka="300s"
  else
    st_ka=MISSING; live_ka="${ka_live:-missing}"
  fi

  if [[ "${idle_live:-0}" -ge 1 ]]; then
    st_idle=APPLIED; live_idle="${idle_live} site(s)"
  else
    st_idle=STOCK; live_idle="absent"
  fi

  if [[ "$cfin_live" == "1s" || -n "$cfin_env" ]]; then
    st_cfin=APPLIED; live_cfin="${cfin_live:-?}"
  else
    st_cfin=MISSING; live_cfin="${cfin_live:-missing}"
  fi

  if [[ "$sfin_live" == "1s" || -n "$sfin_env" ]]; then
    st_sfin=APPLIED; live_sfin="${sfin_live:-?}"
  else
    st_sfin=MISSING; live_sfin="${sfin_live:-missing}"
  fi

  if [[ "$tf" == *"/custom/"* ]]; then
    st_tf=APPLIED; live_tf="$tf"
  else
    st_tf=MISSING; live_tf="${tf:-unset}"
  fi

  if [[ "$own_env" == "true" ]]; then
    st_own=APPLIED; live_own="true"
  else
    st_own=MISSING; live_own="${own_env:-unset}"
  fi

  if [[ -n "$maxc_env" ]]; then
    st_maxc=APPLIED; live_maxc="${maxc_live:-?}"
  else
    st_maxc=STOCK; live_maxc="${maxc_live:-stock}"
  fi

  if [[ "${cm_wfb:-0}" -ge 1 ]]; then
    st_cm=APPLIED; live_cm="${cm_wfb} wait-for-body hit(s)"
  elif [[ "$cm_ok" -eq 1 ]]; then
    st_cm=MISSING; live_cm="no wait-for-body"
  else
    st_cm=MISSING; live_cm="ConfigMap absent"
  fi

  # Same shape as README "Customizations needed" + Live + Status
  # Rendered with Unicode box-drawing + ANSI colors for terminal legibility.
  printf '\n  %sCustomizations needed%s\n\n' "$BOLD" "$NC_LOCAL"
  SEC_WFB="$sec_wfb" SEC_BUF="$sec_buf" SEC_KA="$sec_ka" SEC_IDLE="$sec_idle" \
  SEC_CFIN="$sec_cfin" SEC_SFIN="$sec_sfin" SEC_MAXC="$sec_maxc" \
  LIVE_WFB="$live_wfb" LIVE_BUF="$live_buf" LIVE_KA="$live_ka" LIVE_IDLE="$live_idle" \
  LIVE_CFIN="$live_cfin" LIVE_SFIN="$live_sfin" LIVE_TF="$live_tf" LIVE_OWN="$live_own" \
  LIVE_MAXC="$live_maxc" LIVE_CM="$live_cm" \
  ST_WFB="$st_wfb" ST_BUF="$st_buf" ST_KA="$st_ka" ST_IDLE="$st_idle" \
  ST_CFIN="$st_cfin" ST_SFIN="$st_sfin" ST_TF="$st_tf" ST_OWN="$st_own" \
  ST_MAXC="$st_maxc" ST_CM="$st_cm" \
  GREEN="$GREEN" YELLOW="$YELLOW" RED="$RED" CYAN="$CYAN" NC="$NC" \
  BOLD="$BOLD" DIM="$DIM" \
  python3 - "$CUSTOM_CM" <<'PY'
import os, re, shutil, sys, textwrap

cm = sys.argv[1]
G = os.environ.get("GREEN", "")
Y = os.environ.get("YELLOW", "")
R = os.environ.get("RED", "")
C = os.environ.get("CYAN", "")
B = os.environ.get("BOLD", "")
D = os.environ.get("DIM", "")
N = os.environ.get("NC", "")

def mark(s):
    if s == "APPLIED":
        return f"{G}✓ APPLIED{N}"
    if s == "STOCK":
        return f"{Y}○ STOCK{N}"
    if s == "MISSING":
        return f"{R}✗ MISSING{N}"
    return s

def e(k, default="—"):
    v = os.environ.get(k, "")
    return v if v != "" else default

# Full directive text (no mid-token truncation)
WFB_DIR = (
    "http-request wait-for-body time 30s if METH_POST or METH_PUT "
    "or { method PATCH }"
)

rows = [
    ("wait-for-body", "yes (race fix)",
     "template inject (WAIT_FOR_BODY_LINE)", WFB_DIR,
     e("SEC_WFB"), "time 30s (no at-least)", "absent",
     e("LIVE_WFB"), e("ST_WFB")),
    ("large tune.bufsize", "yes (for ≥1 MiB body)",
     "ROUTER_BUF_SIZE", "tune.bufsize",
     e("SEC_BUF"), "2097152", "32768",
     e("LIVE_BUF"), e("ST_BUF")),
    ("short http-keep-alive", "yes (release buffers)",
     "ROUTER_SLOWLORIS_HTTP_KEEPALIVE", "timeout http-keep-alive",
     e("SEC_KA"), "5s", "300s",
     e("LIVE_KA"), e("ST_KA")),
    ("idle-close-on-response", "yes (release buffers)",
     "ROUTER_IDLE_CLOSE_ON_RESPONSE", "option idle-close-on-response",
     e("SEC_IDLE"), "true", "absent",
     e("LIVE_IDLE"), e("ST_IDLE")),
    ("timeout client-fin", "keep short",
     "ROUTER_CLIENT_FIN_TIMEOUT", "timeout client-fin",
     e("SEC_CFIN"), "1s", "1s",
     e("LIVE_CFIN"), e("ST_CFIN")),
    ("timeout server-fin", "keep short",
     "ROUTER_DEFAULT_SERVER_FIN_TIMEOUT", "timeout server-fin",
     e("SEC_SFIN"), "1s", "1s",
     e("LIVE_SFIN"), e("ST_SFIN")),
    ("custom TEMPLATE_FILE", "yes (lab router)",
     "TEMPLATE_FILE", "—",
     "deploy env",
     "/var/lib/haproxy/conf/custom/haproxy-config.template",
     "stock template",
     e("LIVE_TF"), e("ST_TF")),
    ("disable ns ownership check", "yes (dual routers)",
     "ROUTER_DISABLE_NAMESPACE_OWNERSHIP_CHECK", "—",
     "deploy env", "true", "unset / false",
     e("LIVE_OWN"), e("ST_OWN")),
    ("maxconn cap", "optional",
     "ROUTER_MAX_CONNECTIONS", "maxconn",
     e("SEC_MAXC"), "e.g. 500", "50000",
     e("LIVE_MAXC"), e("ST_MAXC")),
    ("ConfigMap template", "yes (persists inject)",
     cm, "same as wait-for-body",
     "ConfigMap → template", "3 wait-for-body hits", "—",
     e("LIVE_CM"), e("ST_CM")),
]

ansi = re.compile(r"\x1b\[[0-9;]*m")

def vis(s):
    return len(ansi.sub("", str(s)))

def term_width():
    try:
        return max(72, shutil.get_terminal_size((120, 24)).columns)
    except Exception:
        return 120

# Card layout: one boxed block per customization — always legible at any width.
# Uses Unicode box-drawing + ANSI color for Status / headers.
TW = term_width()
INNER = max(56, TW - 4)  # room for left/right borders + margins

def hline(left, mid, right, fill="─"):
    return f"{D}{left}{fill * INNER}{right}{N}"

def wrap_field(label, value, width):
    """Return list of display lines for a labeled field, wrapping value."""
    label_s = f"{label}:"
    pad = 12  # label column
    avail = max(20, width - pad - 1)
    raw = str(value)
    chunks = textwrap.wrap(raw, width=avail, break_long_words=True, replace_whitespace=False) or [""]
    lines = []
    for i, ch in enumerate(chunks):
        if i == 0:
            lines.append(f"{C}{label_s:<{pad}}{N}{ch}")
        else:
            lines.append(f"{'':<{pad}}{ch}")
    return lines

def row_line(content):
    # pad content to INNER visible width, then frame
    pad_n = INNER - vis(content)
    if pad_n < 0:
        # shouldn't happen if wrap_field is correct; hard-trim as fallback
        plain = ansi.sub("", content)
        content = plain[: INNER - 1] + "…"
        pad_n = INNER - vis(content)
    return f"{D}│{N}{content}{' ' * pad_n}{D}│{N}"

# Top border with embedded title
title_txt = " customizations (lab vs live) "
rest = INNER - vis(title_txt)
if rest < 0:
    title_txt = title_txt[:INNER]
    rest = 0
print(f"{D}╔{N}{B}{title_txt}{N}{D}{'═' * rest}╗{N}")

for idx, r in enumerate(rows):
    name, required, env, directive, section, lab, stock, live, status = r
    st = mark(status)

    # Title bar: name + status
    title = f" {B}{name}{N}"
    gap = INNER - vis(title) - vis(st) - 2
    if gap < 1:
        gap = 1
    print(row_line(f"{title}{' ' * gap}{st} "))

    for line in wrap_field("Required", required, INNER):
        print(row_line(f" {line}"))
    for line in wrap_field("Env", env, INNER):
        print(row_line(f" {line}"))
    for line in wrap_field("Directive", directive, INNER):
        print(row_line(f" {line}"))
    for line in wrap_field("Section", section, INNER):
        print(row_line(f" {line}"))
    for line in wrap_field("Lab", lab, INNER):
        print(row_line(f" {line}"))
    for line in wrap_field("Stock", stock, INNER):
        print(row_line(f" {line}"))
    for line in wrap_field("Live", live, INNER):
        print(row_line(f" {line}"))

    if idx < len(rows) - 1:
        print(hline("╠", "═", "╣", "═"))
    else:
        print(hline("╚", "═", "╝", "═"))
PY

  if [[ -n "${wfb_line:-}" && "$st_wfb" == "APPLIED" ]]; then
    printf '\n  wait-for-body live line: %s\n' "$wfb_line"
  fi

  printf '\n  %sLegend%s\n' "$BOLD" "$NC_LOCAL"
  printf '  %s✓ APPLIED%s  customization active in live config\n' "$GREEN" "$NC"
  printf '  %s○ STOCK%s    OpenShift/router default (not customized)\n' "$YELLOW" "$NC"
  printf '  %s✗ MISSING%s  expected lab customization absent\n' "$RED" "$NC"
  echo
  info "Re-apply: $0 apply"
  info "Compare:  ./reproducer.sh run-compare --route edge --sizes 1048576"
  echo
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
OCPBUGS-129094 — apply custom router with wait-for-body + buffer/release opts

  $0 apply [options]   Clone ${SOURCE_DEPLOY}, inject wait-for-body, expose LB
  $0 status
  $0 remove

  $0 apply -h          Show apply flags / recommended values

Interactive apply prompts for unset params; Enter accepts [recommended].
Pass flags or export env vars to set values without prompting.
Use -y to apply all recommended values non-interactively.
EOF
}

case "${1:-}" in
  apply)
    shift
    parse_apply_args "$@"
    cmd_apply
    ;;
  status) cmd_status ;;
  remove) cmd_remove ;;
  *) usage; exit 0 ;;
esac
