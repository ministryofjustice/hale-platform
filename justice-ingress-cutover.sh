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
# ---------------------------------------------------------------------------
# WHERE THIS FLOW COMES FROM (it is NOT a documented runbook)
#
# The end state is defined by the two PRs. The ORDER and the guards below are
# derived from:
#
#  [CP-DUP] Cloud Platform user guide, "ingress with duplicate hostnames":
#           Gatekeeper rejects an Ingress (create AND update) whose host is
#           used in another namespace unless BOTH objects carry
#           allow-duplicate-host: "true" and an identical, same-order
#           allowed-duplicate-ns, plus external-dns aws-weight/set-identifier.
#           https://user-guide.cloud-platform.service.justice.gov.uk/documentation/deploying-an-app/ingress-with-duplicate-hostnames.html
#
#  [CP-WH]  cloud-platform-terraform-ingress-controller templates/values.yaml.tpl:
#           admissionWebhooks.enabled: false. So ingress-nginx's own
#           "host and path already defined" webhook is NOT in play on CP.
#
#  [NGX-1]  ingress-nginx controller.go createServers/getBackendServers:
#           canary ingresses never create a server or location (NoServer).
#           => a canary with no non-canary ingress for its host serves the
#              default backend (404, default cert). NEVER delete the old
#              primary before the host exists on hale-platform-ingress.
#
#  [NGX-2]  ingress-nginx store.go sortIngressSlice: ingresses are processed
#           oldest-CreationTimestamp first; for the same host+path+pathType
#           the first one wins and later ones are ignored ("Location already
#           configured"). Two non-canary ingresses for one host is therefore
#           tolerated, not an error. Which one wins depends on age — see
#           `status` output.
#
#  [NGX-3]  ingress-nginx getBackendServers location loop + issue #10090
#           (closed, fix PR #10091 NOT merged, `break` on pathType mismatch
#           still in main): same host + same path + DIFFERENT pathType on two
#           non-canary ingresses produces two `location "/"` blocks ->
#           nginx: [emerg] duplicate location -> the SHARED modsec controller
#           fails to reload for EVERY tenant. This is the one change here that
#           could hurt all hale sites. Guard: the rule we add to
#           hale-platform-ingress mirrors the LIVE path+pathType of the old
#           ingress, and we refuse to proceed otherwise. It also means
#           hale-platform#452 (which renders pathType ImplementationSpecific)
#           MUST NOT be deployed while the old ingress still exists, if the
#           old ingress uses a different pathType.
#
#  [NGX-4]  mergeAlternativeBackends requires path AND pathType to match for
#           a canary to attach. Empirically the canary IS attached today
#           (www.justice.gov.uk returns X-Version: next = hale; the old stack
#           returns X-Version: legacy), so we don't rely on reasoning here —
#           `status` checks the header.
#
#  [HELM]   Helm 3-way merge: spec.rules / spec.tls are atomic lists. A helm
#           upgrade that touches the ingress replaces them with the chart's
#           render. Merge #452 promptly after delete-canary, and avoid any
#           other ingress template change until then.
# ---------------------------------------------------------------------------
#
# Precondition (merged in hale-platform#453): canary-weight "100" so all
# www.justice.gov.uk traffic is already served by hale pods. That makes every
# step below traffic-neutral.
#
# Steps:
#   status         inspect; prints who "wins" the host (age) and live pathType
#   backup         dump all four objects to YAML
#   add-host       annotate hale-platform-ingress [CP-DUP], then add the
#                  www.justice.gov.uk TLS + rule, mirroring the old ingress's
#                  live path/pathType [NGX-3].
#   delete-old     delete the justice-gov-uk-production ingress (#548).
#                  Refuses unless add-host is in place [NGX-1].
#   delete-canary  delete hale-platform-justice-ingress + wordpress-canary.
#                  Refuses while the old ingress still exists.
#   cleanup        remove the temporary duplicate-host annotations.
#   verify         final state check.
#
# Usage:
#   ./justice-ingress-cutover.sh status
#   DRY_RUN=0 ./justice-ingress-cutover.sh add-host      (etc.)
#
# DRY_RUN defaults to 1: every mutating kubectl call (annotate/patch/delete)
# runs with --dry-run=server, so RBAC and admission are exercised but nothing
# is persisted. Set KUBE_CONTEXT to pin a kubectl context.

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

# Must be byte-identical (incl. order) on every ingress that shares the host [CP-DUP].
DUP_NS_VALUE="justice-gov-uk-production,hale-platform-prod"

# Header that distinguishes the stacks: hale => "next", old => "legacy".
EXPECT_X_VERSION="next"

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

ing_json() { k get ingress "$2" -n "$1" -o json; }

# Rule object for $HOST on the primary, or the literal `null` (never empty / never a jq error).
primary_rule_json() {
  ing_json "$HALE_NS" "$HALE_PRIMARY_ING" | jq -c --arg h "$HOST" '[(.spec.rules // [])[] | select(.host == $h)] | .[0] // null'
}
primary_has_host() { [[ "$(primary_rule_json)" != "null" ]]; }

primary_has_tls() {
  ing_json "$HALE_NS" "$HALE_PRIMARY_ING" \
    | jq -e --arg h "$HOST" '.spec.tls[] | select(.hosts[] == $h)' >/dev/null 2>&1
}

primary_has_dup_annotations() {
  ing_json "$HALE_NS" "$HALE_PRIMARY_ING" \
    | jq -e --arg v "$DUP_NS_VALUE" \
        '.metadata.annotations["allow-duplicate-host"] == "true"
         and .metadata.annotations["allowed-duplicate-ns"] == $v' >/dev/null 2>&1
}

# [CP-DUP] the OLD ingress must carry all four annotations too, or Gatekeeper rejects add-host.
old_has_dup_annotations() {
  ing_json "$OLD_NS" "$OLD_ING" \
    | jq -e --arg v "$DUP_NS_VALUE" \
        '.metadata.annotations["allow-duplicate-host"] == "true"
         and .metadata.annotations["allowed-duplicate-ns"] == $v
         and (.metadata.annotations["external-dns.alpha.kubernetes.io/aws-weight"] // "") != ""
         and (.metadata.annotations["external-dns.alpha.kubernetes.io/set-identifier"] // "") != ""' >/dev/null 2>&1
}

canary_weight() {
  k get ingress "$HALE_CANARY_ING" -n "$HALE_NS" \
    -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/canary-weight}' 2>/dev/null || true
}

# Live path/pathType of the old ingress's rule for $HOST — mirrored in add-host [NGX-3].
old_path()     { ing_json "$OLD_NS" "$OLD_ING" | jq -r --arg h "$HOST" '(.spec.rules // [])[] | select(.host == $h) | .http.paths[0].path'; }
old_pathtype() { ing_json "$OLD_NS" "$OLD_ING" | jq -r --arg h "$HOST" '(.spec.rules // [])[] | select(.host == $h) | .http.paths[0].pathType'; }

created() { k get ingress "$2" -n "$1" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || echo "-"; }

x_version() {
  # $1 = optional extra curl header
  curl -sS -o /dev/null -D - ${1:+-H "$1"} "https://$HOST/" 2>/dev/null \
    | awk 'tolower($1)=="x-version:" {gsub("\r","",$2); print $2}'
}

curl_probe() {
  say "curl probe: https://$HOST/"
  curl -sS -o /dev/null -D - "https://$HOST/" \
    | grep -iE '^(HTTP/|x-version|x-page-cache|strict-transport|location:)' || true
  local v; v="$(x_version)"
  local vc; vc="$(x_version 'X-Canary: always')"
  printf 'X-Version (plain)=%s  (X-Canary: always)=%s   [expect both "%s"; "legacy" = old stack]\n' \
    "${v:-<none>}" "${vc:-<none>}" "$EXPECT_X_VERSION"
  echo "--- /search?s=test ---"
  curl -sS -o /dev/null -w 'HTTP %{http_code}\n' "https://$HOST/search?s=test" || true
}

assert_served_by_hale() {
  local v; v="$(x_version)"
  [[ "$v" == "$EXPECT_X_VERSION" ]] || die "https://$HOST/ returned X-Version='$v', expected '$EXPECT_X_VERSION'. Traffic is not on hale — stop and investigate."
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
  printf '%-58s %s\n' "old primary $OLD_NS/$OLD_ING exists:"          "$(ing_exists "$OLD_NS" "$OLD_ING" && echo yes || echo no)"
  if ing_exists "$OLD_NS" "$OLD_ING"; then
  printf '%-58s %s\n' "old primary live path / pathType:"              "$(old_path) / $(old_pathtype)"
  fi
  printf '%-58s %s\n' "canary $HALE_NS/$HALE_CANARY_ING exists:"       "$(ing_exists "$HALE_NS" "$HALE_CANARY_ING" && echo yes || echo no)"
  printf '%-58s %s\n' "canary weight:"                                  "$(canary_weight)"
  printf '%-58s %s\n' "canary svc $HALE_NS/$HALE_CANARY_SVC exists:"    "$(svc_exists "$HALE_NS" "$HALE_CANARY_SVC" && echo yes || echo no)"
  printf '%-58s %s\n' "primary has rule for $HOST:"                    "$(primary_rule_json | jq -r 'if . == null or . == "" then "no" else "yes: " + (.http.paths[0].path) + " / " + (.http.paths[0].pathType) end' 2>/dev/null || echo no)"
  printf '%-58s %s\n' "primary has TLS for $HOST:"                     "$(primary_has_tls && echo yes || echo no)"
  printf '%-58s %s\n' "primary has duplicate-host annotations:"        "$(primary_has_dup_annotations && echo yes || echo no)"
  printf '%-58s %s\n' "old primary has duplicate-host annotations:"    "$(old_has_dup_annotations && echo yes || echo no)"
  printf '%-58s %s\n' "secret $HALE_NS/$CERT_SECRET exists:"           "$(k get secret "$CERT_SECRET" -n "$HALE_NS" >/dev/null 2>&1 && echo yes || echo no)"

  say "Creation timestamps (oldest non-canary ingress wins a shared host) [NGX-2]"
  printf '%-58s %s\n' "$OLD_NS/$OLD_ING:"          "$(created "$OLD_NS" "$OLD_ING")"
  printf '%-58s %s\n' "$HALE_NS/$HALE_PRIMARY_ING:" "$(created "$HALE_NS" "$HALE_PRIMARY_ING")"
  printf '%-58s %s\n' "$HALE_NS/$HALE_CANARY_ING:"  "$(created "$HALE_NS" "$HALE_CANARY_ING")"
  echo "If $HALE_PRIMARY_ING is OLDER than $OLD_ING, add-host itself moves the host's"
  echo "primary server to hale (backend 'wordpress'). Either way traffic stays on hale pods."

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
  ing_exists "$OLD_NS" "$OLD_ING"           || die "$OLD_NS/$OLD_ING not found — order assumption broken; re-check state before continuing"
  k get secret "$CERT_SECRET" -n "$HALE_NS" >/dev/null 2>&1 || die "TLS secret $CERT_SECRET missing in $HALE_NS"
  old_has_dup_annotations || die "$OLD_NS/$OLD_ING lacks the duplicate-host / external-dns annotations required on BOTH ingresses [CP-DUP]; Gatekeeper would reject the patch"
  local w; w="$(canary_weight)"
  if [[ "$w" != "100" ]]; then
    warn "canary weight is '$w', expected 100 (hale-platform#453). Traffic is NOT fully on hale pods yet."
    confirm
  fi
  assert_served_by_hale

  # [NGX-3] mirror the old ingress's live path + pathType exactly. A different
  # pathType for the same host+path on two non-canary ingresses produces a
  # duplicate nginx location and breaks the shared controller's reload.
  local path ptype
  path="$(old_path)"; ptype="$(old_pathtype)"
  [[ -n "$path" && -n "$ptype" && "$ptype" != "null" ]] || die "could not read live path/pathType from $OLD_NS/$OLD_ING"
  echo "old ingress live rule: path=$path pathType=$ptype  -> mirroring these on $HALE_PRIMARY_ING"
  if [[ "$ptype" != "ImplementationSpecific" ]]; then
    warn "old ingress pathType is '$ptype' but hale-platform#452 renders 'ImplementationSpecific'."
    warn "DO NOT merge/deploy #452 until delete-old has run, or the shared modsec controller will fail to reload [NGX-3]."
  fi

  local dry=()
  [[ "$DRY_RUN" == "1" ]] && dry=(--dry-run=server)

  # One prompt covers every mutation below, including re-runs where 1a is skipped.
  confirm

  # 1a. [CP-DUP] annotations so Gatekeeper accepts the duplicate host while
  #     $OLD_NS/$OLD_ING still exists. Same value/order as the other two.
  if primary_has_dup_annotations; then
    echo "annotations already present — skipping"
  else
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

  # 1c. rule — same shape as templates/ingress.yaml but with the LIVE path/pathType
  if primary_has_host; then
    echo "rule for $HOST already present — skipping: $(primary_rule_json)"
  else
    k patch ingress "$HALE_PRIMARY_ING" -n "$HALE_NS" "${dry[@]}" --type=json -p "$(cat <<EOF
[{"op":"add","path":"/spec/rules/-","value":{
  "host":"$HOST",
  "http":{"paths":[{"path":"$path","pathType":"$ptype",
    "backend":{"service":{"name":"wordpress","port":{"number":8080}}}}]}
}}]
EOF
)"
  fi

  if [[ "$DRY_RUN" != "1" ]]; then
    say "Result"
    ing_json "$HALE_NS" "$HALE_PRIMARY_ING" \
      | jq --arg h "$HOST" '{tls: [.spec.tls[] | select(.hosts[] == $h)], rule: [.spec.rules[] | select(.host == $h)]}'
    echo "waiting 20s for ingress-nginx to reload..."
    sleep 20
    curl_probe
    assert_served_by_hale
    echo
    echo "Expect: X-Version still '$EXPECT_X_VERSION'. Optional: check the modsec controller for reload errors:"
    echo "  kubectl -n ingress-controllers get events --sort-by=.lastTimestamp | grep -iE 'reload|emerg' | tail"
  fi
}

cmd_delete_old() {
  say "Step 2: delete old primary $OLD_NS/$OLD_ING  (justice-gov-uk#548)"
  dry_banner

  # [NGX-1] host must already exist on a non-canary ingress or it goes to the default backend.
  primary_has_host || die "refusing: $HALE_PRIMARY_ING does not yet have a rule for $HOST (run add-host first)"
  primary_has_tls  || die "refusing: $HALE_PRIMARY_ING does not yet have TLS for $HOST (run add-host first)"
  if ! ing_exists "$OLD_NS" "$OLD_ING"; then
    echo "$OLD_ING already gone — nothing to do"
    return 0
  fi
  assert_served_by_hale

  [[ -d "$BACKUP_DIR" ]] || warn "no backup dir found; run 'backup' first"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "would run: kubectl delete ingress $OLD_ING -n $OLD_NS"
    k delete ingress "$OLD_ING" -n "$OLD_NS" --dry-run=server
    return 0
  fi

  confirm
  k delete ingress "$OLD_ING" -n "$OLD_NS"
  echo "waiting 20s for ingress-nginx to reload..."
  sleep 20
  curl_probe
  assert_served_by_hale
  echo
  echo "Expect: site up, X-Version '$EXPECT_X_VERSION', TLS now from $CERT_SECRET."
  echo "Note: #548's PR text names 'justice-gov-uk-dev-ingress' — that is the dev name; prod is $OLD_ING."
  echo "It is now safe to merge hale-platform#452 at any point."
}

cmd_delete_canary() {
  say "Step 3: delete canary $HALE_NS/$HALE_CANARY_ING + Service $HALE_CANARY_SVC  (hale-platform#452)"
  dry_banner

  primary_has_host || die "refusing: $HALE_PRIMARY_ING does not have a rule for $HOST"
  primary_has_tls  || die "refusing: $HALE_PRIMARY_ING does not have TLS for $HOST"
  ing_exists "$OLD_NS" "$OLD_ING" && die "refusing: old ingress $OLD_NS/$OLD_ING still exists; the host's server may still be the old one. Run delete-old first."

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
  echo "waiting 20s for ingress-nginx to reload..."
  sleep 20
  curl_probe
  assert_served_by_hale
  echo
  echo "Expect: site up via backend 'wordpress' on $HALE_PRIMARY_ING."
  echo "NOW merge hale-platform#452 — until then a CI deploy re-creates the canary resources [HELM]."
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
  X-Version:                     $EXPECT_X_VERSION (plain and with X-Canary)
EOF
  say "Then merge: hale-platform#452, justice-gov-uk#548"
}

# ---------------------------------------------------------------------------

command -v kubectl >/dev/null || die "kubectl not found"
command -v jq >/dev/null      || die "jq not found"
command -v curl >/dev/null    || die "curl not found"

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
    # Help = the header comment block (everything up to `set -euo pipefail`).
    awk '/^set -euo pipefail/ {exit} NR > 1 && /^#/' "$0"; exit 1 ;;
esac
