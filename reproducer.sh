#!/usr/bin/env bash
# OCPBUGS-129094 reproducer
# Race: large POST to non-passthrough NOSRV route → HAProxy sends 503 then RST;
# on some paths (notably Azure external LB) the client intermittently sees RST
# (curl exit != 0 / http_code 000) instead of HTTP 503.
#
# Bug: https://issues.redhat.com/browse/OCPBUGS-129094
#
# Usage:
#   ./reproducer.sh setup
#   ./reproducer.sh run [...]              # DEFAULT: realistic curl — natural RST hunt
#   ./reproducer.sh probe-writefirst [...] # optional: write-first (always BrokenPipe)
#   ./reproducer.sh fix-apply|fix-status|fix-remove
#   ./reproducer.sh run-compare            # baseline vs wait-for-body custom LB
#   ./reproducer.sh cleanup|status
#
# Prereqs: oc logged into a cluster; curl. python3 only for probe-writefirst.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-ocpbugs-129094}"
MANIFESTS="${SCRIPT_DIR}/manifests.yaml"
FIX_SCRIPT="${SCRIPT_DIR}/fix-apply-custom-router.sh"
WORKDIR="${WORKDIR:-${TMPDIR:-/tmp}/ocpbugs-129094}"
# curl RST is intermittent (~0.5% on some paths) — default high enough to catch one
ITERATIONS="${ITERATIONS:-300}"
SIZES="${SIZES:-1048576}"
ROUTE_KIND="${ROUTE_KIND:-edge}"
HOST_OVERRIDE="${HOST_OVERRIDE:-}"
# When set, curl --resolve pins to this LB (custom wait-for-body router)
ROUTER_ADDR="${ROUTER_ADDR:-}"
# Stop after first natural RST (realistic event). Set UNTIL_RST=0 to always run full N.
UNTIL_RST="${UNTIL_RST:-1}"
# Body size for optional write-first probe only (not used by default run)
PROBE_BYTES="${PROBE_BYTES:-1048576}"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'
if [[ ! -t 1 ]]; then RED=; GREEN=; YELLOW=; CYAN=; NC=; fi

info()  { printf '%sℹ%s  %s\n' "$CYAN" "$NC" "$*"; }
ok()    { printf '%s✓%s  %s\n' "$GREEN" "$NC" "$*"; }
warn()  { printf '%s⚠%s  %s\n' "$YELLOW" "$NC" "$*"; }
err()   { printf '%s✗%s  %s\n' "$RED" "$NC" "$*" >&2; }

need_oc() {
  command -v oc >/dev/null || { err "oc not found"; exit 1; }
  oc whoami >/dev/null 2>&1 || { err "oc not logged in"; exit 1; }
}

route_name() {
  case "$1" in
    http)         echo nosrv-http ;;
    edge)         echo nosrv-edge ;;
    reencrypt)    echo nosrv-reencrypt ;;
    passthrough)  echo nosrv-passthrough ;;
    *) err "unknown route kind: $1"; exit 1 ;;
  esac
}

route_host() {
  local kind="$1" name host
  name="$(route_name "$kind")"
  if [[ -n "${HOST_OVERRIDE}" ]]; then
    host="${HOST_OVERRIDE}"
  else
    host="$(oc -n "$NS" get route "$name" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  fi
  [[ -n "$host" ]] || { err "could not resolve host for route/$name in $NS"; exit 1; }
  printf '%s' "$host"
}

route_url() {
  local kind="$1" host
  host="$(route_host "$kind")"
  case "$kind" in
    http) printf 'http://%s' "$host" ;;
    *)    printf 'https://%s' "$host" ;;
  esac
}

# Optional curl --resolve args when ROUTER_ADDR is set (custom LB / fixed router).
curl_resolve_args() {
  local kind="$1" host
  host="$(route_host "$kind")"
  if [[ -z "${ROUTER_ADDR}" ]]; then
    return 0
  fi
  case "$kind" in
    http) printf -- '--resolve %s:80:%s' "$host" "$ROUTER_ADDR" ;;
    *)    printf -- '--resolve %s:443:%s --resolve %s:80:%s' \
            "$host" "$ROUTER_ADDR" "$host" "$ROUTER_ADDR" ;;
  esac
}

custom_lb_addr() {
  oc -n openshift-ingress get svc router-ocpbugs-129094 \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null \
    || oc -n openshift-ingress get svc router-ocpbugs-129094 \
         -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null \
    || true
}

cmd_setup() {
  need_oc
  mkdir -p "$WORKDIR"
  info "Applying manifests to namespace ${NS}"
  oc apply -f "$MANIFESTS"
  info "Waiting for routes to be admitted..."
  local r
  for r in nosrv-http nosrv-edge nosrv-reencrypt nosrv-passthrough; do
    oc -n "$NS" wait --for=jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}'=True \
      "route/${r}" --timeout=120s 2>/dev/null \
      || oc -n "$NS" get route "$r" -o wide || true
  done
  info "Confirming Service has no endpoints (NOSRV precondition)"
  local ep
  ep="$(oc -n "$NS" get endpoints nosrv-backend -o jsonpath='{.subsets}' 2>/dev/null || echo '')"
  if [[ -z "$ep" || "$ep" == "null" ]]; then
    ok "Endpoints empty — NOSRV condition met"
  else
    warn "Endpoints not empty: ${ep} (race needs empty backends)"
  fi
  echo
  oc -n "$NS" get svc,endpoints,route
  echo
  ok "Setup complete. Run: $0 run   # curl vs baseline — hunts for a natural RST"
  info "Optional: $0 probe-writefirst  # write-first client (always BrokenPipe; not realistic)"
}

cmd_cleanup() {
  need_oc
  info "Deleting namespace ${NS}"
  oc delete namespace "$NS" --ignore-not-found --wait=false
  rm -rf "$WORKDIR"
  ok "Cleanup requested"
}

cmd_status() {
  need_oc
  oc -n "$NS" get svc,endpoints,route 2>/dev/null || warn "namespace ${NS} not found"
}

make_payload() {
  local bytes="$1" file="$2"
  dd if=/dev/urandom of="$file" bs=1 count="$bytes" status=none 2>/dev/null \
    || dd if=/dev/urandom of="$file" bs="$bytes" count=1 status=none
}

# One curl POST. Prints: http_code exitcode time_total size_upload
# Uses --data-binary and empty Expect to avoid 100-continue (matches bug repro).
# Extra args (e.g. --resolve) may follow payload.
do_one_post() {
  local url="$1" payload="$2" out rc
  shift 2
  set +e
  out="$(curl -sS -o /dev/null \
    --connect-timeout 10 \
    --max-time 120 \
    -k \
    -H 'Expect:' \
    -X POST \
    --data-binary "@${payload}" \
    "$@" \
    -w '%{http_code} %{exitcode} %{time_total} %{size_upload}' \
    "$url" 2>/dev/null)"
  rc=$?
  set -e
  # curl still emits -w on failure; do not also ||-printf (that double-prints).
  if [[ -n "$out" ]]; then
    printf '%s' "$out"
  else
    printf '000 %s 0 0' "$rc"
  fi
}

# Realistic curl matrix against baseline. Does NOT force RST — hunts for a natural
# race (http_code=000 / curl exit ≠ 0) while most iterations still see HTTP 503.
# With UNTIL_RST=1 (default), stops at the first RST event and prints it.
run_matrix_for_route() {
  local kind="$1" url iterations resolve_args
  iterations="$ITERATIONS"
  url="$(route_url "$kind")"
  # shellcheck disable=SC2206
  resolve_args=( $(curl_resolve_args "$kind") )
  info "Route kind=${kind} url=${url} max_iterations=${iterations} until_rst=${UNTIL_RST}"
  if [[ -n "${ROUTER_ADDR}" ]]; then
    info "Traffic pinned to router-addr=${ROUTER_ADDR} (custom / fixed path)"
  else
    info "Traffic via default DNS/LB (baseline path — realistic curl client)"
  fi

  local size payload i code exitc ttotal upload
  local -i ok503=0 fail_rst=0 other=0 ran=0
  local -i route_saw_rst=0

  IFS=',' read -r -a size_arr <<< "$SIZES"
  printf '\n%-10s %-8s %-10s %-10s %-10s %s\n' \
    "SIZE" "RAN" "HTTP_503" "RST/ERR" "OTHER" "NOTES"
  printf '%s\n' "--------------------------------------------------------------------------"

  for size in "${size_arr[@]}"; do
    size="$(echo "$size" | tr -d '[:space:]')"
    [[ -n "$size" ]] || continue
    payload="${WORKDIR}/body-${size}.bin"
    make_payload "$size" "$payload"
    ok503=0; fail_rst=0; other=0; ran=0

    for ((i = 1; i <= iterations; i++)); do
      ran=$((ran + 1))
      read -r code exitc ttotal upload <<< \
        "$(do_one_post "$url" "$payload" "${resolve_args[@]+"${resolve_args[@]}"}")"
      if [[ "$code" == "503" && "$exitc" == "0" ]]; then
        ok503=$((ok503 + 1))
      elif [[ "$code" == "000" || "$exitc" != "0" ]]; then
        # Natural race: RST/FIN before curl finished reading a status line
        fail_rst=$((fail_rst + 1))
        route_saw_rst=1
        warn "NATURAL RST event  kind=${kind} size=${size}B iter=${i}/${iterations}  http_code=${code} curl_exit=${exitc} time=${ttotal}s size_upload=${upload}"
        if [[ "${UNTIL_RST}" == "1" && "$kind" != "passthrough" ]]; then
          info "Stopping early (UNTIL_RST=1) — real-life RST observed without write-first force"
          break
        fi
      else
        other=$((other + 1))
      fi
      # progress every 50 iters when hunting
      if (( i % 50 == 0 && fail_rst == 0 )); then
        info "… ${i}/${iterations} still HTTP 503 (hunting natural RST)"
      fi
    done

    local note=""
    if [[ "$kind" == "passthrough" ]]; then
      note="neg-control (503 not expected)"
    elif (( fail_rst > 0 )); then
      note="NATURAL RST OBSERVED"
    elif (( ok503 == ran )); then
      note="all 503 (no RST this run — raise -n)"
    fi

    printf '%-10s %-8s %-10s %-10s %-10s %s\n' \
      "${size}B" "$ran" "$ok503" "$fail_rst" "$other" "$note"

    if [[ "${UNTIL_RST}" == "1" && "$fail_rst" -gt 0 && "$kind" != "passthrough" ]]; then
      break
    fi
  done
  echo
  # Stash for cmd_run exit status (0 = saw natural RST on non-passthrough)
  if [[ "$kind" != "passthrough" && "$route_saw_rst" -eq 1 ]]; then
    return 0
  elif [[ "$kind" == "passthrough" ]]; then
    return 0
  fi
  return 1
}

resolve_route_ip() {
  local host="$1"
  if [[ -n "${ROUTER_ADDR}" ]]; then
    printf '%s' "${ROUTER_ADDR}"
    return 0
  fi
  local ip
  ip="$(dig +short "$host" A 2>/dev/null | head -1 || true)"
  [[ -z "$ip" ]] && ip="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')"
  # macOS fallback
  [[ -z "$ip" ]] && ip="$(dscacheutil -q host -a name "$host" 2>/dev/null | awk '/ip_address:/{print $2; exit}')"
  printf '%s' "$ip"
}

# Optional write-first client (NOT the default). Sends full body before any read —
# almost always BrokenPipe on NOSRV. Useful as a detector, not a realistic client.
run_writefirst_for_route_size() {
  local kind="$1" bytes="$2" host ip port url_scheme iters
  iters="$ITERATIONS"
  host="$(route_host "$kind")"
  ip="$(resolve_route_ip "$host")"
  [[ -n "$ip" ]] || { err "could not resolve IP for $host (set --router-addr)"; return 1; }
  case "$kind" in
    http) port=80; url_scheme=http ;;
    *)    port=443; url_scheme=https ;;
  esac

  PROBE_HOST="$host" PROBE_IP="$ip" PROBE_PORT="$port" PROBE_SCHEME="$url_scheme" \
  PROBE_BYTES="$bytes" PROBE_ITERS="$iters" PROBE_KIND="$kind" python3 - <<'PY'
import collections, os, socket, ssl, sys

host = os.environ["PROBE_HOST"]
ip = os.environ["PROBE_IP"]
port = int(os.environ["PROBE_PORT"])
scheme = os.environ["PROBE_SCHEME"]
nbytes = int(os.environ["PROBE_BYTES"])
iters = int(os.environ["PROBE_ITERS"])
kind = os.environ.get("PROBE_KIND", "edge")
body = b"x" * nbytes
counts = collections.Counter()

def is_rst_symptom(exc):
    if isinstance(exc, (BrokenPipeError, ConnectionResetError)):
        return True
    if isinstance(exc, ssl.SSLError):
        msg = str(exc).lower()
        return any(x in msg for x in ("broken pipe", "eof", "reset", "syscall", "unexpected eof"))
    return False

for _ in range(iters):
    s = None
    try:
        raw = socket.create_connection((ip, port), timeout=30)
        try:
            raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        if scheme == "https":
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            s = ctx.wrap_socket(raw, server_hostname=host)
        else:
            s = raw
        s.settimeout(30)
        # Write headers + FULL body before any read — matches SDK clients that
        # lose the 503 to RST. Do not recv() until sendall completes.
        req = (
            f"POST / HTTP/1.1\r\nHost: {host}\r\n"
            f"Content-Length: {len(body)}\r\n"
            f"Connection: close\r\n\r\n"
        ).encode() + body
        s.sendall(req)
        data = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
        line = data.split(b"\r\n", 1)[0] if data else b""
        if b" 503" in line:
            counts["http_503"] += 1
        elif not data:
            counts["empty_reply_after_full_write"] += 1
        else:
            counts["other_http"] += 1
    except Exception as e:
        if is_rst_symptom(e):
            counts["rst_during_write"] += 1
        else:
            counts[f"err:{type(e).__name__}"] += 1
    finally:
        if s is not None:
            try:
                s.close()
            except Exception:
                pass

total = sum(counts.values()) or 1
rst = counts["rst_during_write"] + counts["empty_reply_after_full_write"]
http503 = counts["http_503"]
note = ""
if kind == "passthrough":
    note = "neg-control"
elif rst == total:
    note = "RST EVERY TIME"
elif rst > 0:
    note = "PARTIAL RST"
else:
    note = "NO RST (unexpected for NOSRV)"

print(f"{kind:12} {nbytes}B  iters={iters}  RST={rst}/{total}  HTTP_503={http503}/{total}  {note}")
print(f"  detail: {dict(counts)}")

if kind == "passthrough":
    sys.exit(0)
if rst == total:
    sys.exit(0)
sys.exit(1)
PY
}

cmd_run() {
  need_oc
  command -v curl >/dev/null || { err "curl not found"; exit 1; }
  mkdir -p "$WORKDIR"

  if ! oc -n "$NS" get svc nosrv-backend >/dev/null 2>&1; then
    err "Fixtures missing — run: $0 setup"
    exit 1
  fi

  local kinds=()
  case "$ROUTE_KIND" in
    all) kinds=(http edge reencrypt passthrough) ;;
    *)   kinds=("$ROUTE_KIND") ;;
  esac

  echo
  info "OCPBUGS-129094 — realistic curl baseline (does NOT force RST)"
  info "Interleaved upload/read like a normal HTTP client; hunts for a natural race"
  info "Body sizes: ${SIZES}  max_iters=${ITERATIONS}  UNTIL_RST=${UNTIL_RST}"
  if [[ -n "${ROUTER_ADDR}" ]]; then
    info "Traffic pinned to router-addr=${ROUTER_ADDR}"
  else
    info "Traffic via default DNS/LB (router-default baseline)"
  fi
  echo

  local k rc=0 saw=0
  for k in "${kinds[@]}"; do
    set +e
    run_matrix_for_route "$k"
    rc=$?
    set -e
    if [[ "$k" != "passthrough" && "$rc" -eq 0 ]]; then
      saw=1
      if [[ "${UNTIL_RST}" == "1" ]]; then
        break
      fi
    fi
  done
  echo
  if [[ "$saw" -eq 1 ]]; then
    ok "Natural RST observed on baseline with realistic curl (not write-first forced)"
  else
    warn "No natural RST in this run (curl often gets 503). Retry with -n 1000 or UNTIL_RST=1"
    info "Forced detector (not realistic): $0 probe-writefirst --iterations 10"
    return 1
  fi
  cat <<'EOF'

Interpretation
  NATURAL RST  — curl exit ≠ 0 / http_code=000 while uploading (real race)
  HTTP_503     — curl read the 503 mid-upload (common; race not visible this attempt)
  passthrough  — negative control (no HAProxy HTTP 503)

Optional forced detector:  ./reproducer.sh probe-writefirst --iterations 10
EOF
}

cmd_probe_writefirst() {
  need_oc
  command -v python3 >/dev/null || { err "python3 required"; exit 1; }
  mkdir -p "$WORKDIR"
  if ! oc -n "$NS" get svc nosrv-backend >/dev/null 2>&1; then
    err "Fixtures missing — run: $0 setup"
    exit 1
  fi
  local kinds=()
  case "$ROUTE_KIND" in
    all) kinds=(http edge reencrypt passthrough) ;;
    *)   kinds=("$ROUTE_KIND") ;;
  esac
  SIZES="${SIZES:-$PROBE_BYTES}"
  # For the probe, a small iteration count is enough (almost always RST)
  if [[ "${ITERATIONS}" -gt 30 ]]; then
    ITERATIONS=10
  fi
  echo
  warn "write-first probe — FORCED detector (not a realistic client)"
  info "Sends full body before any read; expects BrokenPipe nearly every time"
  echo
  printf '%s\n' "KIND         SIZE      RESULTS"
  printf '%s\n' "--------------------------------------------------------------------------"
  local k size
  IFS=',' read -r -a size_arr <<< "$SIZES"
  for k in "${kinds[@]}"; do
    for size in "${size_arr[@]}"; do
      size="$(echo "$size" | tr -d '[:space:]')"
      [[ -n "$size" ]] || continue
      run_writefirst_for_route_size "$k" "$size" || true
    done
  done
}

cmd_run_compare() {
  need_oc
  local addr
  addr="$(custom_lb_addr)"
  [[ -n "$addr" ]] || { err "custom LB not found — run: $0 fix-apply"; exit 1; }

  echo
  info "=== BASELINE (default Ingress LB / DNS) — realistic curl ==="
  ROUTER_ADDR="" UNTIL_RST="${UNTIL_RST:-1}" cmd_run || true

  echo
  info "=== FIXED (custom router + wait-for-body @ ${addr}) — realistic curl ==="
  ROUTER_ADDR="$addr" UNTIL_RST=0 cmd_run || true
}

usage() {
  cat <<'EOF'
OCPBUGS-129094 reproducer — NOSRV large-POST 503/RST race

Usage:
  ./reproducer.sh setup
  ./reproducer.sh run [--route edge|http|reencrypt|passthrough|all]
                      [--iterations N] [--sizes BYTES,...] [--host HOST]
                      [--router-addr IP|HOSTNAME] [--namespace NAME]
                      [--until-rst|--no-until-rst]
      # DEFAULT: realistic curl — hunts for a natural RST (does not force one)
  ./reproducer.sh probe-writefirst [...]  # optional forced BrokenPipe detector
  ./reproducer.sh fix-apply | fix-status | fix-remove
  ./reproducer.sh run-compare             # baseline vs wait-for-body custom LB
  ./reproducer.sh status | cleanup

Env defaults: NS=ocpbugs-129094 ITERATIONS=300 SIZES=1048576 ROUTE_KIND=edge
              UNTIL_RST=1 (stop at first natural RST)

Bug: https://issues.redhat.com/browse/OCPBUGS-129094
EOF
}

# --- arg parse ---
ACTION="${1:-}"
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --route|-r)       ROUTE_KIND="$2"; shift 2 ;;
    --iterations|-n)  ITERATIONS="$2"; shift 2 ;;
    --sizes)          SIZES="$2"; shift 2 ;;
    --host)           HOST_OVERRIDE="$2"; shift 2 ;;
    --router-addr)    ROUTER_ADDR="$2"; shift 2 ;;
    --namespace)      NS="$2"; shift 2 ;;
    --workdir)        WORKDIR="$2"; shift 2 ;;
    --until-rst)      UNTIL_RST=1; shift ;;
    --no-until-rst)   UNTIL_RST=0; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) err "unknown arg: $1"; usage; exit 1 ;;
  esac
done

case "${ACTION}" in
  setup)             cmd_setup ;;
  run)               cmd_run ;;
  run-curl)          cmd_run ;; # back-compat alias
  run-compare)       cmd_run_compare ;;
  probe-writefirst)  cmd_probe_writefirst ;;
  fix-apply)         bash "$FIX_SCRIPT" apply ;;
  fix-status)        bash "$FIX_SCRIPT" status ;;
  fix-remove)        bash "$FIX_SCRIPT" remove ;;
  cleanup)           cmd_cleanup ;;
  status)            cmd_status ;;
  ""|-h|--help)      usage; exit 0 ;;
  *) err "unknown action: ${ACTION}"; usage; exit 1 ;;
esac
