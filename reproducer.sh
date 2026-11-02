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
#   ./reproducer.sh run [...]         # write-first: send FULL body before any read
#   ./reproducer.sh run-compare       # baseline vs fixed (both write-first)
#   ./reproducer.sh run-curl [...]    # optional interleaved curl hunt (hides race)
#   ./reproducer.sh fix-apply|fix-status|fix-remove
#   ./reproducer.sh cleanup|status
#
# Prereqs: oc logged into a cluster; python3 (write-first); curl only for run-curl.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-ocpbugs-129094}"
MANIFESTS="${SCRIPT_DIR}/manifests.yaml"
FIX_SCRIPT="${SCRIPT_DIR}/fix-apply-custom-router.sh"
WORKDIR="${WORKDIR:-${TMPDIR:-/tmp}/ocpbugs-129094}"
# write-first: small N is enough (baseline ≈ all RST; fixed ≈ all 503)
ITERATIONS="${ITERATIONS:-10}"
SIZES="${SIZES:-1048576}"
ROUTE_KIND="${ROUTE_KIND:-edge}"
HOST_OVERRIDE="${HOST_OVERRIDE:-}"
# When set, pin to this LB (custom wait-for-body router)
ROUTER_ADDR="${ROUTER_ADDR:-}"
# Used only by optional run-curl
UNTIL_RST="${UNTIL_RST:-1}"
PROBE_BYTES="${PROBE_BYTES:-1048576}"
CURL_LIMIT_RATE="${CURL_LIMIT_RATE:-0}"
PARALLEL="${PARALLEL:-20}"

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

# --- pretty output helpers ---
BOLD=$'\033[1m'
DIM=$'\033[2m'
[[ -t 1 ]] || { BOLD=; DIM=; }

hr()    { printf '%s────────────────────────────────────────────────────────────%s\n' "$DIM" "$NC"; }
banner() {
  local title="$1"
  echo
  hr
  printf '%s%s%s\n' "$BOLD" "$title" "$NC"
  hr
}
kv() { printf '  %-14s %s\n' "$1" "$2"; }

# Human-readable byte size (1048576 → 1MiB)
fmt_bytes() {
  local n="$1"
  if [[ "$n" -ge 1048576 && $((n % 1048576)) -eq 0 ]]; then
    printf '%sMiB' "$((n / 1048576))"
  elif [[ "$n" -ge 1024 && $((n % 1024)) -eq 0 ]]; then
    printf '%sKiB' "$((n / 1024))"
  else
    printf '%sB' "$n"
  fi
}

print_result_table_header() {
  printf '\n  %-8s  %-10s  %8s  %8s  %8s  %6s  %s\n' \
    "ROUTE" "SIZE" "POSTS" "HTTP_503" "RST/ERR" "OTHER" "RESULT"
  printf '  %s\n' "--------  ----------  --------  --------  --------  ------  ----------------"
}

print_result_row() {
  local route="$1" size_label="$2" posts="$3" h503="$4" rst="$5" other="$6" result="$7"
  local result_fmt="$result"
  case "$result" in
    *RST*|*RACE*) result_fmt="${YELLOW}${result}${NC}" ;;
    *503*|*PASS*|*OK*|*zero*|*clean*) result_fmt="${GREEN}${result}${NC}" ;;
  esac
  printf '  %-8s  %-10s  %8s  %8s  %8s  %6s  %b\n' \
    "$route" "$size_label" "$posts" "$h503" "$rst" "$other" "$result_fmt"
}

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
  ok "Setup complete. Run: $0 run   # write-first: full body before any read"
  info "Compare fix: $0 fix-apply && $0 run-compare"
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
  local limit_args=()
  if [[ -n "${CURL_LIMIT_RATE}" && "${CURL_LIMIT_RATE}" != "0" ]]; then
    limit_args=(--limit-rate "${CURL_LIMIT_RATE}")
  fi
  set +e
  out="$(curl -sS -o /dev/null \
    --connect-timeout 10 \
    --max-time 120 \
    -k \
    -H 'Expect:' \
    -X POST \
    --data-binary "@${payload}" \
    "${limit_args[@]+"${limit_args[@]}"}" \
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

# Classify one curl result line: "http_code exitcode time size_upload"
# Sets globals _cls_ok503 _cls_rst _cls_other (0/1).
classify_post_result() {
  local code="$1" exitc="$2"
  _cls_ok503=0; _cls_rst=0; _cls_other=0
  if [[ "$code" == "503" && "$exitc" == "0" ]]; then
    _cls_ok503=1
  elif [[ "$code" == "000" || "$exitc" != "0" ]]; then
    _cls_rst=1
  else
    _cls_other=1
  fi
}

# Baseline curl matrix — NOT forced (no write-first, no --limit-rate by default).
# Sequential full-speed almost always gets clean 503. PARALLEL concurrent
# full-speed curls (same interleaved client) raise the odds of natural exit 56.
run_matrix_for_route() {
  local kind="$1" url iterations resolve_args parallel
  iterations="$ITERATIONS"
  parallel="${PARALLEL}"
  [[ "$parallel" =~ ^[0-9]+$ && "$parallel" -ge 1 ]] || parallel=1
  url="$(route_url "$kind")"
  # shellcheck disable=SC2206
  resolve_args=( $(curl_resolve_args "$kind") )

  printf '\n  %sTarget%s\n' "$BOLD" "$NC"
  kv "route:" "$kind"
  kv "url:" "$url"
  kv "posts:" "${iterations}  (parallel=${parallel}, until_rst=${UNTIL_RST})"
  if [[ -n "${ROUTER_ADDR}" ]]; then
    kv "traffic:" "pinned → ${ROUTER_ADDR}"
  else
    kv "traffic:" "default DNS / router-default LB"
  fi
  kv "client:" "full-speed curl (interleaved; no write-first)"
  [[ -n "${CURL_LIMIT_RATE}" && "${CURL_LIMIT_RATE}" != "0" ]] && \
    kv "limit-rate:" "${CURL_LIMIT_RATE} (optional)"

  local size payload i code exitc ttotal upload size_label
  local -i ok503=0 fail_rst=0 other=0 ran=0
  local -i route_saw_rst=0
  local batch_dir j batch_n
  local header_printed=0

  IFS=',' read -r -a size_arr <<< "$SIZES"

  for size in "${size_arr[@]}"; do
    size="$(echo "$size" | tr -d '[:space:]')"
    [[ -n "$size" ]] || continue
    size_label="$(fmt_bytes "$size")"
    payload="${WORKDIR}/body-${size}.bin"
    make_payload "$size" "$payload"
    ok503=0; fail_rst=0; other=0; ran=0

    if [[ "$header_printed" -eq 0 ]]; then
      print_result_table_header
      header_printed=1
    fi
    printf '  %shunting%s %s × %s …\n' "$DIM" "$NC" "$kind" "$size_label"

    i=0
    while (( i < iterations )); do
      if [[ "$parallel" -eq 1 ]]; then
        i=$((i + 1))
        ran=$((ran + 1))
        read -r code exitc ttotal upload <<< \
          "$(do_one_post "$url" "$payload" "${resolve_args[@]+"${resolve_args[@]}"}")"
        classify_post_result "$code" "$exitc"
        if [[ "$_cls_ok503" -eq 1 ]]; then
          ok503=$((ok503 + 1))
        elif [[ "$_cls_rst" -eq 1 ]]; then
          fail_rst=$((fail_rst + 1))
          route_saw_rst=1
          printf '\n  %s▶ NATURAL RST/ERR%s  post %s/%s\n' "$YELLOW" "$NC" "$i" "$iterations"
          kv "http_code:" "$code"
          kv "curl_exit:" "$exitc"
          kv "time:" "${ttotal}s"
          kv "uploaded:" "$(fmt_bytes "${upload:-0}")"
          if [[ "${UNTIL_RST}" == "1" && "$kind" != "passthrough" ]]; then
            info "Stopping early (UNTIL_RST=1)"
            break
          fi
        else
          other=$((other + 1))
        fi
      else
        batch_n="$parallel"
        if (( i + batch_n > iterations )); then
          batch_n=$((iterations - i))
        fi
        batch_dir="${WORKDIR}/batch-$$-${i}"
        mkdir -p "$batch_dir"
        for ((j = 0; j < batch_n; j++)); do
          (
            do_one_post "$url" "$payload" "${resolve_args[@]+"${resolve_args[@]}"}" \
              > "${batch_dir}/${j}.out"
          ) &
        done
        wait
        for ((j = 0; j < batch_n; j++)); do
          i=$((i + 1))
          ran=$((ran + 1))
          read -r code exitc ttotal upload <<< "$(cat "${batch_dir}/${j}.out")"
          classify_post_result "$code" "$exitc"
          if [[ "$_cls_ok503" -eq 1 ]]; then
            ok503=$((ok503 + 1))
          elif [[ "$_cls_rst" -eq 1 ]]; then
            fail_rst=$((fail_rst + 1))
            route_saw_rst=1
            printf '\n  %s▶ NATURAL RST/ERR%s  post %s/%s\n' "$YELLOW" "$NC" "$i" "$iterations"
            kv "http_code:" "$code"
            kv "curl_exit:" "$exitc"
            kv "time:" "${ttotal}s"
            kv "uploaded:" "$(fmt_bytes "${upload:-0}")"
          else
            other=$((other + 1))
          fi
        done
        rm -rf "$batch_dir"
        if [[ "${UNTIL_RST}" == "1" && "$fail_rst" -gt 0 && "$kind" != "passthrough" ]]; then
          info "Stopping early (UNTIL_RST=1)"
          break
        fi
      fi
      if (( ran % 100 == 0 && fail_rst == 0 )); then
        printf '  %s… %s/%s clean HTTP 503%s\n' "$DIM" "$ran" "$iterations" "$NC"
      fi
    done

    local note=""
    if [[ "$kind" == "passthrough" ]]; then
      note="neg-control"
    elif (( fail_rst > 0 )); then
      note="RST OBSERVED"
    elif (( ok503 == ran )); then
      note="all clean 503"
    else
      note="mixed"
    fi

    print_result_row "$kind" "$size_label" "$ran" "$ok503" "$fail_rst" "$other" "$note"

    if [[ "${UNTIL_RST}" == "1" && "$fail_rst" -gt 0 && "$kind" != "passthrough" ]]; then
      break
    fi
  done
  echo
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

# Write-first client: send headers + FULL body (sendall) before any recv.
# Matches SDKs that finish the upload before reading the status line.
# Baseline NOSRV → BrokenPipe/RST; fixed (wait-for-body+bufsize) → HTTP 503.
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
  PROBE_BYTES="$bytes" PROBE_ITERS="$iters" PROBE_KIND="$kind" \
  PROBE_EXPECT="${PROBE_EXPECT:-rst}" python3 - <<'PY'
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
expect = os.environ.get("PROBE_EXPECT", "rst")  # rst | no_rst
note = ""
if kind == "passthrough":
    note = "neg-control"
elif rst == total:
    note = "RST EVERY TIME"
elif rst > 0:
    note = "PARTIAL RST"
elif http503 == total:
    note = "HTTP_503 EVERY TIME (no RST)"
else:
    note = "MIXED/OTHER"

def fmt_bytes(n):
    if n >= 1048576 and n % 1048576 == 0:
        return f"{n // 1048576}MiB"
    if n >= 1024 and n % 1024 == 0:
        return f"{n // 1024}KiB"
    return f"{n}B"

size_l = fmt_bytes(nbytes)
other = total - rst - http503
# Align with bash print_result_row columns
print(f"  {kind:<8}  {size_l:<10}  {total:>8}  {http503:>8}  {rst:>8}  {other:>6}  {note}")
if other > 0 or (rst not in (0, total) and http503 not in (0, total)):
    print(f"           detail: {dict(counts)}")

if kind == "passthrough":
    sys.exit(0)
if expect == "no_rst":
    sys.exit(0 if rst == 0 and http503 == total else 1)
# default: expect all RST (bug present on baseline)
sys.exit(0 if rst == total else 1)
PY
}

cmd_run() {
  need_oc
  command -v python3 >/dev/null || { err "python3 required for write-first client"; exit 1; }
  mkdir -p "$WORKDIR"

  if ! oc -n "$NS" get svc nosrv-backend >/dev/null 2>&1; then
    err "Fixtures missing — run: $0 setup"
    exit 1
  fi

  local kinds=() expect="rst" title_router="router-default (DNS/LB)"
  case "$ROUTE_KIND" in
    all) kinds=(http edge reencrypt passthrough) ;;
    *)   kinds=("$ROUTE_KIND") ;;
  esac
  if [[ -n "${ROUTER_ADDR}" ]]; then
    expect="no_rst"
    title_router="${ROUTER_ADDR} (pinned — expect no RST if fix works)"
  fi

  banner "OCPBUGS-129094  ·  run  ·  write-first (full body send)"
  kv "client:" "sendall(headers + full body) before any recv"
  kv "sizes:" "$SIZES"
  kv "iters:" "$ITERATIONS"
  kv "router:" "$title_router"
  kv "expect:" "$([[ "$expect" == "rst" ]] && echo "RST every iter (NOSRV race)" || echo "HTTP 503 every iter (RST=0)")"
  print_result_table_header

  local k size rc=0 any_fail=0
  IFS=',' read -r -a size_arr <<< "$SIZES"
  for k in "${kinds[@]}"; do
    for size in "${size_arr[@]}"; do
      size="$(echo "$size" | tr -d '[:space:]')"
      [[ -n "$size" ]] || continue
      set +e
      PROBE_EXPECT="$expect" ITERATIONS="$ITERATIONS" \
        run_writefirst_for_route_size "$k" "$size"
      rc=$?
      set -e
      if [[ "$k" != "passthrough" && "$rc" -ne 0 ]]; then
        any_fail=1
      fi
    done
  done

  banner "Summary"
  if [[ "$any_fail" -eq 0 ]]; then
    if [[ "$expect" == "rst" ]]; then
      ok "Full-body send hit RST every time (bug reproduced on baseline)"
    else
      ok "Full-body send got HTTP 503 with zero RST (fix path OK)"
    fi
  else
    if [[ "$expect" == "rst" ]]; then
      err "Expected RST on full-body send — check fixtures / router-default path"
    else
      err "Expected zero RST on fix path — check wait-for-body + tune.bufsize"
    fi
    return 1
  fi
  echo
  printf '  %sLegend%s\n' "$BOLD" "$NC"
  kv "RST/ERR:"  "BrokenPipe during sendall (503 lost to RST)"
  kv "HTTP_503:" "full body accepted, then NOSRV 503 (no RST during write)"
  echo
}

# Optional: interleaved curl (hides race). Not used by run / run-compare.
cmd_run_curl() {
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

  banner "OCPBUGS-129094  ·  run-curl  ·  interleaved (optional)"
  kv "note:" "Reads mid-upload — usually clean HTTP 503; RST rare"
  kv "sizes:" "$SIZES"
  kv "posts:" "$ITERATIONS"
  kv "parallel:" "$PARALLEL"
  echo

  local k rc=0 saw=0
  for k in "${kinds[@]}"; do
    set +e
    run_matrix_for_route "$k"
    rc=$?
    set -e
    if [[ "$k" != "passthrough" && "$rc" -eq 0 ]]; then
      saw=1
      [[ "${UNTIL_RST}" == "1" ]] && break
    fi
  done
  banner "Summary"
  if [[ "$saw" -eq 1 ]]; then
    ok "Natural RST/ERR seen with interleaved curl"
  else
    warn "No natural RST (typical for curl). Use: $0 run  # write-first full body"
    return 1
  fi
  echo
}

cmd_probe_writefirst() {
  # Back-compat alias → same as run (write-first full body)
  cmd_run
}

cmd_run_compare() {
  need_oc
  command -v python3 >/dev/null || { err "python3 required for write-first compare"; exit 1; }
  mkdir -p "$WORKDIR"
  local addr size cmp_iters rc size_label
  addr="$(custom_lb_addr)"
  [[ -n "$addr" ]] || { err "custom LB not found — run: $0 fix-apply"; exit 1; }

  cmp_iters="${COMPARE_ITERATIONS:-${ITERATIONS:-10}}"
  [[ "$cmp_iters" -gt 30 ]] && cmp_iters=10
  size="$(echo "${SIZES:-1048576}" | tr ',' '\n' | head -1 | tr -d '[:space:]')"
  size_label="$(fmt_bytes "$size")"
  [[ "$ROUTE_KIND" == "all" ]] && ROUTE_KIND=edge

  banner "OCPBUGS-129094  ·  run-compare  ·  write-first (full body send)"
  kv "question:" "Does wait-for-body + ROUTER_BUF_SIZE eliminate RST?"
  kv "client:" "sendall(headers + full body) before any recv"
  kv "route:" "$ROUTE_KIND"
  kv "body:" "$size_label ($size bytes)"
  kv "iters:" "$cmp_iters"
  kv "fixed LB:" "$addr"

  # --- baseline ---
  banner "1/2  BASELINE  ·  router-default"
  printf '  expect:  RST=%s/%s  (full-body send hits BrokenPipe)\n\n' "$cmp_iters" "$cmp_iters"
  print_result_table_header
  set +e
  ROUTER_ADDR="" ITERATIONS="$cmp_iters" PROBE_EXPECT=rst \
    run_writefirst_for_route_size "$ROUTE_KIND" "$size"
  rc=$?
  set -e
  echo
  if [[ "$rc" -ne 0 ]]; then
    err "Baseline did not RST every iter — check fixtures / LB path"
    return 1
  fi
  ok "Baseline: full-body send → RST reproduced"

  # --- fixed ---
  banner "2/2  FIXED  ·  custom router + wait-for-body"
  printf '  expect:  RST=0/%s   HTTP_503=%s/%s  (full body buffered, then 503)\n\n' \
    "$cmp_iters" "$cmp_iters" "$cmp_iters"
  print_result_table_header
  set +e
  ROUTER_ADDR="$addr" ITERATIONS="$cmp_iters" PROBE_EXPECT=no_rst \
    run_writefirst_for_route_size "$ROUTE_KIND" "$size"
  rc=$?
  set -e
  echo
  if [[ "$rc" -ne 0 ]]; then
    err "Fixed path still saw RST (or not all 503)"
    echo
    printf '  %sHint%s\n' "$BOLD" "$NC"
    kv "check:" "tune.bufsize >= body and wait-for-body in haproxy.config"
    kv "re-apply:" "./reproducer.sh fix-apply -y"
    return 1
  fi
  ok "Fixed: full-body send → HTTP 503, zero RST"

  banner "Verdict"
  ok "wait-for-body + bufsize eliminates RST for full-body ${size_label} POST"
  kv "baseline:" "RST every time (sendall BrokenPipe)"
  kv "fixed:"    "HTTP 503 every time (RST=0)"
  echo
  return 0
}

usage() {
  cat <<'EOF'
OCPBUGS-129094 reproducer — NOSRV large-POST 503/RST race

Usage:
  ./reproducer.sh setup
  ./reproducer.sh run [--route edge|http|reencrypt|passthrough|all]
                      [--iterations N] [--sizes BYTES,...]
                      [--host HOST] [--router-addr IP|HOSTNAME]
      # write-first: send FULL POST body before reading (default)
  ./reproducer.sh run-compare [--route edge] [--sizes BYTES]
      # baseline vs fixed — both write-first full-body send
  ./reproducer.sh run-curl [...]   # optional interleaved curl (hides race)
  ./reproducer.sh fix-apply [-y] [--buf-size N] [--keep-alive 5s] ...
  ./reproducer.sh fix-status | fix-remove
  ./reproducer.sh status | cleanup

Env defaults: NS=ocpbugs-129094 ITERATIONS=10 SIZES=1048576 ROUTE_KIND=edge

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
    --parallel|-p)    PARALLEL="$2"; shift 2 ;;
    --limit-rate)     CURL_LIMIT_RATE="$2"; shift 2 ;;
    --full-speed)     CURL_LIMIT_RATE=0; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) err "unknown arg: $1"; usage; exit 1 ;;
  esac
done

case "${ACTION}" in
  setup)             cmd_setup ;;
  run)               cmd_run ;;
  run-curl)          cmd_run_curl ;;
  run-compare)       cmd_run_compare ;;
  probe-writefirst)  cmd_probe_writefirst ;; # alias of run
  fix-apply)         bash "$FIX_SCRIPT" apply "${@:2}" ;;
  fix-status)        bash "$FIX_SCRIPT" status ;;
  fix-remove)        bash "$FIX_SCRIPT" remove ;;
  cleanup)           cmd_cleanup ;;
  status)            cmd_status ;;
  ""|-h|--help)      usage; exit 0 ;;
  *) err "unknown action: ${ACTION}"; usage; exit 1 ;;
esac
