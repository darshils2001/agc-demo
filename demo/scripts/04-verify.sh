#!/usr/bin/env bash
# Walks through every demo expectation and prints PASS/FAIL.
# Tests:
#   1. AGC multi-site:  3 hostnames return their unique pages.
#   2. AGC L7 ingress policy:  GET=200, POST=403, GET /admin=403.
#   3. East-west L7:           client -> contoso GET=200, POST=403,
#                              client -> fabrikam timeout (default-deny).
#   4. Default-deny egress:    backend pod cannot curl bing.com (timeout).
#   5. DNS egress allowed:     pods can still resolve names.
#
# Works on Linux/macOS/WSL/Git Bash.

set -uo pipefail

# Avoid MSYS path mangling on Git Bash (Windows) when passing URLs/paths to kubectl exec.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-env.sh
source "$DIR/00-env.sh"

PASS=0; FAIL=0

resolve_host() {
  local host="$1" out=""
  if command -v getent >/dev/null 2>&1; then
    out=$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -1)
  fi
  if [[ -z "$out" ]] && command -v python >/dev/null 2>&1; then
    out=$(python -c "import socket,sys
try: print(socket.gethostbyname(sys.argv[1]))
except Exception: pass" "$host" 2>/dev/null)
  fi
  if [[ -z "$out" ]] && command -v python3 >/dev/null 2>&1; then
    out=$(python3 -c "import socket,sys
try: print(socket.gethostbyname(sys.argv[1]))
except Exception: pass" "$host" 2>/dev/null)
  fi
  if [[ -z "$out" ]] && command -v nslookup >/dev/null 2>&1; then
    out=$(nslookup "$host" 2>/dev/null | awk '/^Address: /{print $2; exit}')
  fi
  echo "$out"
}

fqdn=$(kubectl get gateway gateway-01 -n agc-sites -o jsonpath='{.status.addresses[0].value}')
ip=$(resolve_host "$fqdn")
if [[ -z "$ip" ]]; then
  echo "ERROR: could not resolve AGC FQDN '$fqdn'" >&2
  exit 1
fi
echo "AGC FQDN: $fqdn  ($ip)"
echo

echo "[1] Multi-site routing"
for site in contoso fabrikam adventure; do
  body=$(curl -sk --max-time 10 --resolve "${site}.example.com:80:$ip" "http://${site}.example.com/" || true)
  if echo "$body" | grep -qi "Hello from"; then
    printf "  [PASS] %s.example.com -> %s\n" "$site" "$(echo "$body" | grep -oE 'Hello from [A-Za-z ]+' | head -1)"
    PASS=$((PASS+1))
  else
    printf "  [FAIL] %s.example.com (got: %s)\n" "$site" "${body:0:80}"
    FAIL=$((FAIL+1))
  fi
done
echo

echo "[2] AGC L7 ingress policy (GET allowed, POST denied)"
get_code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 --resolve "contoso.example.com:80:$ip" "http://contoso.example.com/")
post_code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 -X POST --resolve "contoso.example.com:80:$ip" "http://contoso.example.com/" -d 'x=1')
admin_code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 --resolve "contoso.example.com:80:$ip" "http://contoso.example.com/admin")
[[ "$get_code"   == "200" ]] && { echo "  [PASS] GET  /        -> 200";              PASS=$((PASS+1)); } || { echo "  [FAIL] GET / got $get_code";                          FAIL=$((FAIL+1)); }
[[ "$post_code"  == "403" ]] && { echo "  [PASS] POST /        -> 403 (L7 deny)";    PASS=$((PASS+1)); } || { echo "  [FAIL] POST / got $post_code (expected 403)";         FAIL=$((FAIL+1)); }
[[ "$admin_code" == "403" ]] && { echo "  [PASS] GET  /admin   -> 403 (L7 deny)";    PASS=$((PASS+1)); } || { echo "  [FAIL] GET /admin got $admin_code (expected 403)";    FAIL=$((FAIL+1)); }
echo

echo "[3] East-west L7 (client pod)"
client_pod=$(kubectl get pod -n agc-sites -l app=client -o jsonpath='{.items[0].metadata.name}')
# --ipv4 prevents curl from retrying via IPv6 (which would print '000000' on a deny).
ew_get=$(kubectl exec -n agc-sites "$client_pod" -- curl -s --ipv4 -o /dev/null -w "%{http_code}" --max-time 5 http://contoso:8080/ 2>/dev/null || echo "000")
ew_post=$(kubectl exec -n agc-sites "$client_pod" -- curl -s --ipv4 -o /dev/null -w "%{http_code}" --max-time 5 -X POST http://contoso:8080/ -d 'x=1' 2>/dev/null || echo "000")
ew_fab=$(kubectl exec -n agc-sites "$client_pod" -- curl -s --ipv4 -o /dev/null -w "%{http_code}" --max-time 5 http://fabrikam:8080/ 2>/dev/null || echo "000")
[[ "$ew_get"  == "200" ]] && { echo "  [PASS] client -> contoso  GET  -> 200";       PASS=$((PASS+1)); } || { echo "  [FAIL] client->contoso GET got $ew_get";              FAIL=$((FAIL+1)); }
[[ "$ew_post" == "403" ]] && { echo "  [PASS] client -> contoso  POST -> 403 (L7)";  PASS=$((PASS+1)); } || { echo "  [FAIL] client->contoso POST got $ew_post";            FAIL=$((FAIL+1)); }
# Default-deny drops the SYN, so curl returns 000 (timeout). Anything other than 200 means blocked.
[[ "$ew_fab"  != "200" ]] && { echo "  [PASS] client -> fabrikam blocked (code=$ew_fab)"; PASS=$((PASS+1)); } || { echo "  [FAIL] client->fabrikam got $ew_fab (expected non-200)"; FAIL=$((FAIL+1)); }
echo

echo "[4] Default-deny egress (backend pod cannot reach Internet)"
contoso_pod=$(kubectl get pod -n agc-sites -l app=contoso -o jsonpath='{.items[0].metadata.name}')
# nginx:alpine ships busybox wget. Some images don't honor -T reliably; bound the whole exec
# from the outside via a small inline timeout (kill the kubectl exec process if it runs too long).
egress_test() {
  kubectl exec -n agc-sites "$contoso_pod" -- wget -q -T 5 -O /dev/null https://www.bing.com >/dev/null 2>&1 &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    [[ $waited -ge 10 ]] && { kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; }
    sleep 1; waited=$((waited+1))
  done
  wait "$pid"; return $?
}
if egress_test; then
  echo "  [FAIL] contoso reached bing.com (egress NOT blocked)"; FAIL=$((FAIL+1))
else
  echo "  [PASS] contoso -> bing.com blocked"; PASS=$((PASS+1))
fi
echo

echo "[5] DNS egress allowed"
# Resolve a same-namespace service via the in-cluster DNS server. The first 'Address:'
# line is the resolver itself; we want a SECOND address line meaning the answer succeeded.
dns_lines=$(kubectl exec -n agc-sites "$client_pod" -- nslookup contoso.agc-sites.svc.cluster.local 2>/dev/null | grep -c "^Address" || true)
if [[ "${dns_lines:-0}" -ge 2 ]]; then
  echo "  [PASS] DNS resolution still works (got answer from kube-dns)"; PASS=$((PASS+1))
else
  echo "  [FAIL] DNS resolution failed (lines=$dns_lines)"; FAIL=$((FAIL+1))
fi
echo

echo "===================="
echo "Result: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
