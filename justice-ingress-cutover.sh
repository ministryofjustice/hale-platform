#!/usr/bin/env bash
#
# justice-ingress-cutover.sh
#
# Manually applies, in a safe order, the cluster changes that these PRs will
# later make permanent:
#
#   hale-platform#452   (branch delete-canary-ingress-for-justice-site)
#       - www.justice.gov.uk moves from the canary ingress
#         (hale-platform-justice-ingress) onto the primary ingress
#         (hale-platform-ingress) in namespace hale-platform-prod
#       - canary ingress + wordpress-canary Service are removed
#
#   justice-gov-uk#548
#       - old primary ingress justice-gov-uk-production-ingress-modsec in
#         namespace justice-gov-uk-production is removed
#
# Precondition (already merged in hale-platform#453): the canary ingress has
# canary-weight "100", so all www.justice.gov.uk traffic is already served by
# the hale-platform pods. That is what makes every step below traffic-neutral.
#
# Order matters:
#   1. add-host        annotate hale-platform-ingress to allow the duplicate
#                      host, then add www.justice.gov.uk TLS + rule to it.
#                      (Two non-canary ingresses now claim the host; nginx keeps
#                      using the older one, and the weight-100 canary still
#                      sends everything to hale pods -> no traffic change.)
#   2. delete-old      delete the justice-gov-uk-production ingress.
#                      nginx now builds the www.justice.gov.uk server from
#                      hale-platform-ingress; canary still attached at 100%.
#   3. delete-canary   delete hale-platform-justice-ingress and the
#                      wordpress-canary Service. Traffic flows via the primary
#                      backend `wordpress` (same pods).
#   4. cleanup         remove the temporary duplicate-host annotations.
#
# Never do 2 before 1: the host would have no non-canary ingress.
# Never do 1 without the annotations: the admission policy will reject it.
#
# Afterwards, merge hale-platform#452 and justice-gov-uk#548 PROMPTLY:
#   - until #452 is merged, a CI deploy from main will re-create the canary
#     ingress + Service (harmless, but undoes step 3), and any *other* change
#     to the primary ingress template could drop the hand-patched host.
#   - helm upgrade tolerates the already-deleted canary resources.
#
# Usage:
#   ./justice-ingress-cutover.sh status
#   ./justice-ingress-cutover.sh backup
#   ./justice-ingress-cutover.sh add-host        [DRY_RUN=0 to apply]
#   ./justice-ingress-cutover.sh delete-old      [DRY_RUN=0 to apply]
#   ./justice-ingress-cutover.sh delete-canary   [DRY_RUN=0 to apply]
#   ./justice-ingress-cutover.sh cleanup         [DRY_RUN=0 to apply]
#   ./justice-ingress-cutover.sh verify
#
# DRY_RUN defaults to 1 (server-side dry run for patches, print-only for
# deletes). Set KUBE_CONTEXT to pin a kubectl context.

set -euo pipefail

DRY_RUN="${DRY_RUN:-1}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"

HALE_NS="hale-platform-prod"
HALE_PRIMARY_ING="hale-platform-ingress"
HALE_CANARY_ING="hale-platform-justice-ingress"
HALE_CANARY_SVC="wordpress-canary"

OLD_NS="justice-gov-uk-production"
OLD_ING="justice-gov-uk-production-ingress-modsec"

HOST="www.justice.gov.uk"
CERT_SECRET="justice-www-cert"

# Must be byte-identical (incl. order) on every ingress that shares the host.
DUP_NS_VALUE="justice-gov-uk-production,hale-platform-prod"

BACKUP_DIR="${BACKUP_DIR:-$(dirname "$0")/backup-$(date +%Y%m%d-%H%M%S)}"

# ---------------------------------------------------------------------------

k() {
  if [[ -n "$KUBE_CONTEXT" ]]; then
    kubectl --context "$KUBE_CONTEXT" "$@"
  else
    kubectl "$@"
  fi
}

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

dry_banner() {
  if [[ "$DRY_RUN" == "1" ]]; then
    warn "DRY_RUN=1 — nothing will be changed. Re-run with DRY_RUN=0 to apply."
  else
    warn "DRY_RUN=0 — THIS WILL CHANGE PRODUCTION."
  fi
}

confirm() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  read -r -p "Type 'yes' to continue: " ans
  [[ "$ans" == "yes" ]] || die "aborted"
}

ing_exists() { k get ingress "$2" -n "$1" >/dev/null 2>&1; }
svc_exists() { k get service "$2" -n "$1" >/dev/null 2>&1; }

primary_has_host() {
  k get ingress "$HALE_PRIMARY_ING" -n "$HALE_NS" -o json \
    | jq -e --arg h "$HOST" '.spec.rules[] | select(.host == $h)' >/dev/null 2>&1
}

primary_has_tls() {
  k get ingress "$HALE_PRIMARY_ING" -n "$HALE_NS" -o json \
    | jq -e --arg h "$HOST" '.spec.tls[] | select(.hosts[] == $h)' >/dev/null 2>&1
}

primary_has_dup_annotations() {
  k get ingress "$HALE_PRIMARY_ING" -n "$HALE_NS" -o json \
    | jq -e --arg v "$DUP_NS_VALUE" \
        '.metadata.annotations["allow-duplicate-host"] == "true"
         and .metadata.annotations["allowed-duplicate-ns"] == $v' >/dev/null 2>&1
}

canary_weight() {
  k get ingress "$HALE_CANARY_ING" -n "$HALE_NS" \
    -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/canary-weight}' 2>/dev/null || true
}

curl_probe() {
  # Quick external check; compare headers before/after each step.
  say "curl probe: https://$HOST/"
  curl -sS -o /dev/null -D - "https://$HOST/" \
    | grep -iE '^(HTTP/|server:|x-page-cache|x-cache|strict-transport|location:)' || true
  echo "--- /search?s=test (should be 200 from hale, not 404) ---"
  curl -sS -o /dev/null -w 'HTTP %{http_code}\n' "https://$HOST/search?s=test" || true
}

# ---------------------------------------------------------------------------

cmd_status() {
  say "kubectl context"
  k config current-context

  say "Ingresses in $HALE_NS"
  k get ingress -n "$HALE_NS" -o wide

  say "Ingresses in $OLD_NS"
  k get ingress -n "$OLD_NS" -o wide || warn "cannot list ingresses in $OLD_NS"

  say "State"
  printf '%-55s %s\n' "old primary $OLD_NS/$OLD_ING exists:"          "$(ing_exists "$OLD_NS" "$OLD_ING" && echo yes || echo no)"
  printf '%-55s %s\n' "canary $HALE_NS/$HALE_CANARY_ING exists:"       "$(ing_exists "$HALE_NS" "$HALE_CANARY_ING" && echo yes || echo no)"
  printf '%-55s %s\n' "canary weight:"                                  "$(canary_weight)"
  printf '%-55s %s\n' "canary svc $HALE_NS/$HALE_CANARY_SVC exists:"    "$(svc_exists "$HALE_NS" "$HALE_CANARY_SVC" && echo yes || echo no)"
  printf '%-55s %s\n' "primary has rule for $HOST:"                    "$(primary_has_host && echo yes || echo no)"
  printf '%-55s %s\n' "primary has TLS for $HOST:"                     "$(primary_has_tls && echo yes || echo no)"
  printf '%-55s %s\n' "primary has duplicate-host annotations:"        "$(primary_has_dup_annotations && echo yes || echo no)"
  printf '%-55s %s\n' "secret $HALE_NS/$CERT_SECRET exists:"           "$(k get secret "$CERT_SECRET" -n "$HALE_NS" >/dev/null 2>&1 && echo yes || echo no)"

  curl_probe
}

cmd_backup() {
  say "Backing up to $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  k get ingress "$HALE_PRIMARY_ING" -n "$HALE_NS" -o yaml > "$BACKUP_DIR/$HALE_NS.$HALE_PRIMARY_ING.yaml"
  ing_exists "$HALE_NS" "$HALE_CANARY_ING" && k get ingress "$HALE_CANARY_ING" -n "$HALE_NS" -o yaml > "$BACKUP_DIR/$HALE_NS.$HALE_CANARY_ING.yaml"
  svc_exists "$HALE_NS" "$HALE_CANARY_SVC" && k get service "$HALE_CANARY_SVC" -n "$HALE_NS" -o yaml > "$BACKUP_DIR/$HALE_NS.svc.$HALE_CANARY_SVC.yaml"
  ing_exists "$OLD_NS" "$OLD_ING" && k get ingress "$OLD_ING" -n "$OLD_NS" -o yaml > "$BACKUP_DIR/$OLD_NS.$OLD_ING.yaml"
  ls -la "$BACKUP_DIR"
  echo "Restore with: kubectl apply -f <file>  (strip status/resourceVersion/uid first if needed)"
}

cmd_add_host() {
  say "Step 1: add $HOST to $HALE_NS/$HALE_PRIMARY_ING"
  dry_banner

  # Preconditions
  ing_exists "$HALE_NS" "$HALE_PRIMARY_ING" || die "$HALE_PRIMARY_ING not found in $HALE_NS"
  k get secret "$CERT_SECRET" -n "$HALE_NS" >/dev/null 2>&1 || die "TLS secret $CERT_SECRET missing in $HALE_NS"
  local w; w="$(canary_weight)"
  if [[ "$w" != "100" ]]; then
    warn "canary weight is '$w', expected 100 (hale-platform#453). Traffic is NOT fully on hale pods yet."
    confirm
  fi

  local dry=()
  [[ "$DRY_RUN" == "1" ]] && dry=(--dry-run=server)

  # 1a. annotations so the duplicate-host admission policy accepts the host
  #     while $OLD_NS/$OLD_ING still exists. Same value/order as the other two.
  if primary_has_dup_annotations; then
    echo "annotations already present — skipping"
  else
    confirm
    k annotate ingress "$HALE_PRIMARY_ING" -n "$HALE_NS" "${dry[@]}" --overwrite \
      "allow-duplicate-host=true" \
      "allowed-duplicate-ns=$DUP_NS_VALUE"
  fi

  # 1b. TLS entry (mirrors values.yaml ingress.hosts -> certName)
  if primary_has_tls; then
    echo "TLS entry for $HOST already present — skipping"
  else
    k patch ingress "$HALE_PRIMARY_ING" -n "$HALE_NS" "${dry[@]}" --type=json -p "$(cat <<EOF
[{"op":"add","path":"/spec/tls/-","value":{"hosts":["$HOST"],"secretName":"$CERT_SECRET"}}]
EOF
)"
  fi

  # 1c. rule (mirrors the range over ingress.hosts in templates/ingress.yaml)
  if primary_has_host; then
    echo "rule for $HOST already present — skipping"
  else
    k patch ingress "$HALE_PRIMARY_ING" -n "$HALE_NS" "${dry[@]}" --type=json -p "$(cat <<EOF
[{"op":"add","path":"/spec/rules/-","value":{
  "host":"$HOST",
  "http":{"paths":[{"path":"/","pathType":"ImplementationSpecific",
    "backend":{"service":{"name":"wordpress","port":{"number":8080}}}}]}
}}]
EOF
)"
  fi

  if [[ "$DRY_RUN" != "1" ]]; then
    say "Result"
    k get ingress "$HALE_PRIMARY_ING" -n "$HALE_NS" -o json \
      | jq --arg h "$HOST" '{tls: [.spec.tls[] | select(.hosts[] == $h)], rule: [.spec.rules[] | select(.host == $h)]}'
    curl_probe
    echo
    echo "Expect: no change in behaviour (old ingress still wins the host; canary still 100%)."
    echo "Check ingress-nginx logs for warnings if you want:"
    echo "  kubectl -n ingress-controllers logs -l app.kubernetes.io/name=ingress-nginx --since=2m | grep -i '$HOST'"
  fi
}

cmd_delete_old() {
  say "Step 2: delete old primary $OLD_NS/$OLD_ING  (justice-gov-uk#548)"
  dry_banner

  primary_has_host || die "refusing: $HALE_PRIMARY_ING does not yet have a rule for $HOST (run add-host first)"
  primary_has_tls  || die "refusing: $HALE_PRIMARY_ING does not yet have TLS for $HOST (run add-host first)"
  if ! ing_exists "$OLD_NS" "$OLD_ING"; then
    echo "$OLD_ING already gone — nothing to do"
    return 0
  fi

  [[ -d "$BACKUP_DIR" ]] || warn "no backup dir found; run 'backup' first"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "would run: kubectl delete ingress $OLD_ING -n $OLD_NS"
    k delete ingress "$OLD_ING" -n "$OLD_NS" --dry-run=server
    return 0
  fi

  confirm
  k delete ingress "$OLD_ING" -n "$OLD_NS"
  echo "waiting 15s for ingress-nginx to reload..."
  sleep 15
  curl_probe
  echo
  echo "Expect: site still up, served by hale (TLS now from $CERT_SECRET)."
  echo "Note: #548's PR text names 'justice-gov-uk-dev-ingress' — that is the dev name; prod is $OLD_ING."
}

cmd_delete_canary() {
  say "Step 3: delete canary $HALE_NS/$HALE_CANARY_ING + Service $HALE_CANARY_SVC  (hale-platform#452)"
  dry_banner

  primary_has_host || die "refusing: $HALE_PRIMARY_ING does not have a rule for $HOST"
  ing_exists "$OLD_NS" "$OLD_ING" && die "refusing: old ingress $OLD_NS/$OLD_ING still exists; nginx would route the host to it (nginx-service). Run delete-old first."

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "would run: kubectl delete ingress $HALE_CANARY_ING -n $HALE_NS"
    echo "would run: kubectl delete service $HALE_CANARY_SVC -n $HALE_NS"
    ing_exists "$HALE_NS" "$HALE_CANARY_ING" && k delete ingress "$HALE_CANARY_ING" -n "$HALE_NS" --dry-run=server
    svc_exists "$HALE_NS" "$HALE_CANARY_SVC" && k delete service "$HALE_CANARY_SVC" -n "$HALE_NS" --dry-run=server
    return 0
  fi

  confirm
  ing_exists "$HALE_NS" "$HALE_CANARY_ING" && k delete ingress "$HALE_CANARY_ING" -n "$HALE_NS" || echo "canary ingress already gone"
  svc_exists "$HALE_NS" "$HALE_CANARY_SVC" && k delete service "$HALE_CANARY_SVC" -n "$HALE_NS" || echo "canary service already gone"
  echo "waiting 15s for ingress-nginx to reload..."
  sleep 15
  curl_probe
  echo
  echo "Expect: site still up, now via backend 'wordpress' on $HALE_PRIMARY_ING."
  echo "NOW merge hale-platform#452 — until then a CI deploy will re-create the canary resources."
}

cmd_cleanup() {
  say "Step 4: remove temporary duplicate-host annotations from $HALE_NS/$HALE_PRIMARY_ING"
  dry_banner
  ing_exists "$OLD_NS" "$OLD_ING" && die "refusing: old ingress still exists; annotations are still needed."
  if ! primary_has_dup_annotations; then
    echo "annotations not present — nothing to do"
    return 0
  fi
  local dry=()
  [[ "$DRY_RUN" == "1" ]] && dry=(--dry-run=server)
  confirm
  k annotate ingress "$HALE_PRIMARY_ING" -n "$HALE_NS" "${dry[@]}" \
    "allow-duplicate-host-" "allowed-duplicate-ns-"
}

cmd_verify() {
  cmd_status
  say "Expected end state"
  cat <<EOF
  old primary exists:            no
  canary exists:                 no
  canary svc exists:             no
  primary has rule/TLS for host: yes / yes
  duplicate-host annotations:    no (after cleanup)
EOF
  say "Ingress-nginx view of the host (optional)"
  echo "  kubectl -n ingress-controllers exec deploy/<modsec-controller> -- cat /etc/nginx/nginx.conf | grep -n -A3 'server_name $HOST'"
  say "Then merge: hale-platform#452, justice-gov-uk#548"
}

# ---------------------------------------------------------------------------

command -v kubectl >/dev/null || die "kubectl not found"
command -v jq >/dev/null      || die "jq not found"

case "${1:-}" in
  status)        cmd_status ;;
  backup)        cmd_backup ;;
  add-host)      cmd_add_host ;;
  delete-old)    cmd_delete_old ;;
  delete-canary) cmd_delete_canary ;;
  cleanup)       cmd_cleanup ;;
  verify)        cmd_verify ;;
  all)
    cmd_status; cmd_backup; cmd_add_host; cmd_delete_old; cmd_delete_canary; cmd_cleanup; cmd_verify ;;
  *)
    sed -n '2,60p' "$0"; exit 1 ;;
esac
