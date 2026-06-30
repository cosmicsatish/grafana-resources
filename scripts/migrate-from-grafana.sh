#!/usr/bin/env bash
# =============================================================================
# migrate-from-grafana.sh  —  Bootstrap GitOps CRs from an existing Grafana
# =============================================================================
# Queries the Grafana HTTP API and writes grafana-operator v5 CRs directly
# using jq/yq — no envsubst, no template files, no E2BIG risk.
#
# Resources exported (8 types):
#   - Grafana instance + credentials secret scaffold
#   - GrafanaDatasource (+ secrets scaffold for secure fields)
#   - GrafanaFolder
#   - GrafanaServiceAccount
#   - GrafanaDashboard + ConfigMap  (folder-mirrored directories)
#   - GrafanaAlertRuleGroup         (folder-mirrored directories)
#   - GrafanaContactPoint
#   - GrafanaNotificationPolicy
#
# Usage:
#   ./scripts/migrate-from-grafana.sh \
#     --url  https://grafana.example.com \
#     --token "$GRAFANA_TOKEN" \
#     --namespace grafana
#
# Authentication (one of):
#   --token <token>               Service account token (recommended)
#   --user  <u> --password <p>    Basic auth
#
# Options:
#   --namespace, -n <ns>          Kubernetes namespace (default: grafana)
#   --output-dir, -o <dir>        Root output directory (default: ./resources)
#   --select-type, -s <types>     Comma-separated types to export (default: all)
#                                 Values: instance,datasources,folders,teams,
#                                         service-accounts,dashboards,
#                                         alert-rule-groups,contact-points,
#                                         notification-policy
#   --force, -F                   Overwrite files that already exist
#   --dry-run                     Print what would be created, write nothing
#   --no-recreate                 Add finalizerPolicy: delete to all CRs
#   --instance-key <key>          Label key for instanceSelector (default: app)
#   --instance-val <val>          Label value (default: grafana)
#
# Requirements: bash 4+, curl, jq, yq v4+
# =============================================================================
set -euo pipefail

# ─── Bash version guard ───────────────────────────────────────────────────────
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "❌ bash 4+ required (current: $BASH_VERSION)" >&2
  echo "   macOS: brew install bash && use /opt/homebrew/bin/bash $0" >&2
  exit 1
fi

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()     { echo -e "${BOLD}${BLUE}[$(date -u '+%H:%M:%S')] $*${RESET}"; }
info()    { echo -e "  ${CYAN}→${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}⚠️  $*${RESET}"; }
fail()    { echo -e "  ${RED}❌ $*${RESET}"; exit 1; }
saved()   { echo -e "  ${GREEN}✅ $*${RESET}"; }
secret()  { echo -e "  ${YELLOW}🔑 $*${RESET}"; }
dryrun()  { echo -e "  ${CYAN}[dry-run]${RESET} $*"; }
skipped() { echo -e "  ${YELLOW}⏭  $(basename "$1")${RESET} (exists — use --force to overwrite)"; }

# ─── Dependency check ─────────────────────────────────────────────────────────
check_dep() { for d in "$@"; do command -v "$d" &>/dev/null || fail "Missing: $d"; done; }

# ─── Defaults ─────────────────────────────────────────────────────────────────
GRAFANA_URL=""
GRAFANA_USER="admin"
GRAFANA_PASSWORD=""
GRAFANA_TOKEN=""
NAMESPACE="grafana"
FORCE=false
DRY_RUN=false
NO_RECREATE=false
INSTANCE_KEY="app"
INSTANCE_VAL="grafana"
SELECT_TYPES=""

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$REPO/resources"
SECRETS_DIR=""
AUTH=()

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --url|-u)           GRAFANA_URL="$2";      shift 2 ;;
    --user)             GRAFANA_USER="$2";     shift 2 ;;
    --password|-p)      GRAFANA_PASSWORD="$2"; shift 2 ;;
    --token|-t)         GRAFANA_TOKEN="$2";    shift 2 ;;
    --namespace|-n)     NAMESPACE="$2";        shift 2 ;;
    --output-dir|-o)    OUTPUT_DIR="$2";       shift 2 ;;
    --select-type|-s)   SELECT_TYPES="$2";     shift 2 ;;
    --force|-F)         FORCE=true;            shift   ;;
    --dry-run)          DRY_RUN=true;          shift   ;;
    --instance-key)     INSTANCE_KEY="$2";     shift 2 ;;
    --instance-val)     INSTANCE_VAL="$2";     shift 2 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ -z "$GRAFANA_URL" ]] && { echo -e "${RED}Usage: $0 --url <url> --token <token> [opts]${RESET}"; exit 1; }
GRAFANA_URL="${GRAFANA_URL%/}"
SECRETS_DIR="$OUTPUT_DIR/secrets"

# ─── Helpers ──────────────────────────────────────────────────────────────────

# slug: lowercase kubernetes-safe name, max 52 chars
slug() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9-]/-/g; s/-\{2,\}/-/g; s/^-*//; s/-*$//' \
    | cut -c1-52
}

# Grafana API wrappers
gapi()  { curl -sSf "${AUTH[@]}" -H "Content-Type: application/json" "$GRAFANA_URL/api$1"; }
gprov() { curl -sSf "${AUTH[@]}" -H "Content-Type: application/json" "$GRAFANA_URL/api/v1/provisioning$1"; }

# Write a file atomically (temp + rename). Respects --force and --dry-run.
write_file() {
  local dest="$1" content="$2" is_secret="${3:-false}"
  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun "Would write: $dest"; return
  fi
  if [[ -f "$dest" ]] && [[ "$FORCE" == "false" ]]; then
    skipped "$dest"; return
  fi
  mkdir -p "$(dirname "$dest")"
  local tmp; tmp=$(mktemp "$(dirname "$dest")/.tmp.XXXXXX")
  # Strip trailing whitespace + trailing blank lines
  printf '%s\n' "$content" \
    | awk '{sub(/[[:space:]]+$/,"")} {a[++n]=$0} END{while(n>0&&a[n]=="")n--;for(i=1;i<=n;i++)print a[i]}' \
    > "$tmp"
  mv "$tmp" "$dest"
  if [[ "$is_secret" == "true" ]]; then secret "$dest"; else saved "$dest"; fi
}

# type_selected: returns 0 if the type is in SELECT_TYPES (or all selected)
type_selected() { [[ -z "$SELECT_TYPES" ]] || [[ ",$SELECT_TYPES," == *",$1,"* ]]; }

# ─── Folder cache (bash 4 associative arrays) ─────────────────────────────────
declare -A _FC=()    # uid → title
declare -A _FP=()    # uid → parentUid

load_folder_cache() {
  local json="$1"
  while IFS=$'\t' read -r uid title parent; do
    _FC["$uid"]="$title"
    _FP["$uid"]="${parent:-}"
  done < <(echo "$json" | jq -r '.[] | [.uid, .title, (.parentUid // "")] | @tsv')
}


folder_title() { echo "${_FC["${1:-}"]:-General}"; }

folder_path() {
  local uid="$1"
  local parts=()
  local cur="$uid"
  local depth=0
  while [[ -n "$cur" && $depth -lt 10 ]]; do
    local t="${_FC[$cur]:-}"
    [[ -z "$t" ]] && break
    parts=("$(slug "$t")" "${parts[@]}")
    cur="${_FP[$cur]:-}"
    ((depth++)) || true
  done
  [[ ${#parts[@]} -eq 0 ]] && echo "general" || (IFS=/; echo "${parts[*]}")
}

# ─── Shared YAML header (instanceSelector) ────────────────────────────────────
instance_selector() {
  cat <<YAML
  instanceSelector:
    matchLabels:
      ${INSTANCE_KEY}: ${INSTANCE_VAL}
YAML
}

# ─── INIT ─────────────────────────────────────────────────────────────────────
init() {
  check_dep curl jq yq

  if [[ -n "$GRAFANA_TOKEN" ]]; then
    AUTH=(-H "Authorization: Bearer $GRAFANA_TOKEN")
  elif [[ -n "$GRAFANA_PASSWORD" ]]; then
    AUTH=(-u "$GRAFANA_USER:$GRAFANA_PASSWORD")
  else
    fail "Provide --token or --password."
  fi

  local ver
  ver=$(gapi "/health" | jq -r '.version // "unknown"' 2>/dev/null || echo "unknown")
  [[ "$ver" == "unknown" ]] && fail "Cannot connect to Grafana at $GRAFANA_URL"

  log "Grafana Instance : ${BOLD}$GRAFANA_URL${RESET} (v$ver)"
  log "Target Namespace : ${BOLD}$NAMESPACE${RESET}"
  log "Output Directory : ${BOLD}$OUTPUT_DIR${RESET}"
  log "Force Overwrite  : ${BOLD}$FORCE${RESET}"
  log "Dry Run          : ${BOLD}$DRY_RUN${RESET}"
  [[ -n "$SELECT_TYPES" ]] && log "Selected Types   : ${BOLD}$SELECT_TYPES${RESET}"
  echo ""

  [[ "$DRY_RUN" == "false" ]] && mkdir -p "$SECRETS_DIR"
}

# ─── 0. Grafana Instance ──────────────────────────────────────────────────────
migrate_instance() {
  type_selected "instance" || return 0
  log "0/8  Grafana instance"
  mkdir -p "$OUTPUT_DIR/grafana"

  yaml=$(jq -n \
    --arg ns  "$NAMESPACE" \
    --arg ik  "$INSTANCE_KEY" \
    --arg iv  "$INSTANCE_VAL" \
    --arg url "$GRAFANA_URL" \
    '{
      apiVersion: "grafana.integreatly.org/v1beta1",
      kind: "Grafana",
      metadata: {
        name: "grafana",
        namespace: $ns,
        labels: { ($ik): $iv }
      },
      spec: {
        external: {
          url: $url,
          apiKey: {
            name: "grafana-cloud-credentials",
            key: "token"
          }
        }
      }
    }' | yq -P '.')
  write_file "$OUTPUT_DIR/grafana/grafana-instance.yaml" "$yaml"

  local secret_yaml
  secret_yaml=$(jq -n \
    --arg ns "$NAMESPACE" \
    '{
      apiVersion: "v1",
      kind: "Secret",
      metadata: {
        name: "grafana-cloud-credentials",
        namespace: $ns,
        annotations: {
          "grafana-operator/for": "Grafana/grafana-cloud-instance",
          "grafana-operator/secret-kind": "Grafana"
        }
      },
      stringData: { token: "CHANGE_ME" }
    }' | yq -P '.')
  write_file "$SECRETS_DIR/grafana-cloud-credentials.yaml" "$secret_yaml" "true"

  info "URL: ${BOLD}${GRAFANA_URL}${RESET}"
  warn "Create the API token secret before applying:"
  echo "      kubectl create secret generic grafana-cloud-credentials \\"
  echo "        --from-literal=token=<SERVICE_ACCOUNT_TOKEN> \\"
  echo "        --namespace ${NAMESPACE}"
  echo ""
}

# ─── 1. Datasources ───────────────────────────────────────────────────────────
migrate_datasources() {
  type_selected "datasources" || return 0
  log "1/8  Datasources"
  mkdir -p "$OUTPUT_DIR/datasources"

  local ds_json count
  ds_json=$(gapi "/datasources")
  count=$(echo "$ds_json" | jq 'length')
  [[ "$count" -eq 0 ]] && { info "No datasources found."; echo ""; return; }

  local idx=0
  while IFS= read -r ds; do
    ((idx++)) || true
    local name type url access isdefault basicauth basicuser secure_fields n secret_name uid

    name=$(echo "$ds"        | jq -r '.name')
    type=$(echo "$ds"        | jq -r '.type')
    url=$(echo "$ds"         | jq -r '.url // ""')
    access=$(echo "$ds"      | jq -r '.access // "proxy"')
    isdefault=$(echo "$ds"   | jq -r '.isDefault // false')
    basicauth=$(echo "$ds"   | jq -r '.basicAuth // false')
    basicuser=$(echo "$ds"   | jq -r '.basicAuthUser // ""')
    uid=$(echo "$ds"         | jq -r '.uid // ""')
    secure_fields=$(echo "$ds" | jq -r '(.secureJsonFields // {}) | to_entries[] | select(.value==true) | .key')

    n=$(slug "$name")
    secret_name="${n}-credentials"

    info "[${idx}/${count}] $name ($type)"

    # Build valuesFrom block (jq array) for any redacted secure fields
    local values_from_jq="[]"
    if [[ -n "$secure_fields" ]]; then
      local field_arr=()
      while IFS= read -r f; do [[ -n "$f" ]] && field_arr+=("$f"); done <<< "$secure_fields"

      if [[ ${#field_arr[@]} -gt 0 ]]; then
        # Secret scaffold
        local string_data_jq="{}"
        for f in "${field_arr[@]}"; do
          string_data_jq=$(echo "$string_data_jq" | jq --arg k "$f" '. + {($k): "CHANGE_ME"}')
        done

        local sec_yaml
        sec_yaml=$(jq -n \
          --arg ns  "$NAMESPACE" \
          --arg sn  "$secret_name" \
          --arg rn  "$name" \
          --argjson sd "$string_data_jq" \
          '{
            apiVersion: "v1", kind: "Secret",
            metadata: {
              name: $sn, namespace: $ns,
              annotations: {
                "grafana-operator/for": ("GrafanaDatasource/" + $rn),
                "grafana-operator/secret-kind": "GrafanaDatasource"
              }
            },
            stringData: $sd
          }' | yq -P '.')
        write_file "$SECRETS_DIR/${secret_name}.yaml" "$sec_yaml" "true"

        # valuesFrom array
        local vf_entries="[]"
        for f in "${field_arr[@]}"; do
          vf_entries=$(echo "$vf_entries" | jq \
            --arg f "$f" --arg sn "$secret_name" \
            '. + [{
              targetPath: ("secureJsonData." + $f),
              valueFrom: { secretKeyRef: { name: $sn, key: $f } }
            }]')
        done
        values_from_jq="$vf_entries"
      fi
    fi

    # Build spec.datasource object
    local ds_spec
    ds_spec=$(jq -n \
      --arg name  "$name" \
      --arg type  "$type" \
      --arg url   "$url" \
      --arg acc   "$access" \
      --arg uid   "$uid" \
      --argjson def "$isdefault" \
      --argjson ba  "$basicauth" \
      --arg bu    "$basicuser" \
      '{
        name: $name, type: $type, url: $url, access: $acc,
        uid: (if $uid != "" then $uid else null end),
        isDefault: $def,
        basicAuth: $ba,
        basicAuthUser: (if $ba then $bu else null end)
      } | del(.[] | nulls)')

    local yaml
    yaml=$(jq -n \
      --arg ns   "$NAMESPACE" \
      --arg n    "$n" \
      --arg ik   "$INSTANCE_KEY" \
      --arg iv   "$INSTANCE_VAL" \
      --arg uid  "$uid" \
      --argjson spec "$ds_spec" \
      --argjson vf   "$values_from_jq" \
      '{
        apiVersion: "grafana.integreatly.org/v1beta1",
        kind: "GrafanaDatasource",
        metadata: { name: $n, namespace: $ns },
        spec: {
          instanceSelector: { matchLabels: { ($ik): $iv } },
          resyncPeriod: "0s",
          uid: (if $uid != "" then $uid else null end),
          datasource: $spec,
          valuesFrom: (if ($vf | length) > 0 then $vf else null end)
        } | del(.spec.valuesFrom | nulls, .spec.uid | nulls)
      }' | yq -P '.')
    write_file "$OUTPUT_DIR/datasources/${n}.yaml" "$yaml"
  done < <(echo "$ds_json" | jq -c '.[]')
  echo ""
}

# ─── 2. Folders ───────────────────────────────────────────────────────────────
FOLDERS_JSON=""

migrate_folders() {
  FOLDERS_JSON=$(gapi "/folders?limit=5000")
  type_selected "folders" || { load_folder_cache "$FOLDERS_JSON"; return 0; }
  log "2/8  Folders"
  mkdir -p "$OUTPUT_DIR/folders"

  load_folder_cache "$FOLDERS_JSON"
  local count; count=$(echo "$FOLDERS_JSON" | jq 'length')
  [[ "$count" -eq 0 ]] && { info "No folders found."; echo ""; return; }

  local idx=0
  while IFS= read -r f; do
    ((idx++)) || true
    local title uid n
    title=$(echo "$f" | jq -r '.title')
    uid=$(echo "$f"   | jq -r '.uid')
    n=$(slug "$title")

    info "[${idx}/${count}] $title"

    local yaml
    yaml=$(jq -n \
      --arg ns    "$NAMESPACE" \
      --arg n     "$n" \
      --arg ik    "$INSTANCE_KEY" \
      --arg iv    "$INSTANCE_VAL" \
      --arg title "$title" \
      --arg uid   "$uid" \
      '{
        apiVersion: "grafana.integreatly.org/v1beta1",
        kind: "GrafanaFolder",
        metadata: { name: $n, namespace: $ns },
        spec: {
          instanceSelector: { matchLabels: { ($ik): $iv } },
          resyncPeriod: "0s",
          title: $title,
          uid: $uid
        }
      }' | yq -P '.')
    write_file "$OUTPUT_DIR/folders/${n}.yaml" "$yaml"
  done < <(echo "$FOLDERS_JSON" | jq -c '.[]')
  echo ""
}

# ─── 3. Teams (informational — no CRD in v5) ─────────────────────────────────
migrate_teams() {
  type_selected "teams" || return 0
  log "3/8  Teams (informational only)"
  warn "GrafanaTeam CRD does not exist in grafana-operator v5 — skipping."
  info "Teams must be managed via Grafana provisioning or HTTP API."
  local tj tc
  tj=$(gapi "/teams/search?perpage=1000") || return 0
  tc=$(echo "$tj" | jq '.teams | length // 0')
  [[ "$tc" -gt 0 ]] && { info "Found $tc team(s) (not exported):"; echo "$tj" | jq -r '.teams[] | "    - " + .name'; }
  echo ""
}

# ─── 4. Service Accounts ──────────────────────────────────────────────────────
migrate_service_accounts() {
  type_selected "service-accounts" || return 0
  log "4/8  Service Accounts"
  mkdir -p "$OUTPUT_DIR/service-accounts"

  local sa_json filter count
  sa_json=$(gapi "/serviceaccounts/search?perpage=1000")
  filter='if type=="object" and has("serviceAccounts") then .serviceAccounts elif type=="array" then . else [] end'
  count=$(echo "$sa_json" | jq "($filter) | length")
  [[ "$count" -eq 0 ]] && { info "No service accounts found."; echo ""; return; }

  local idx=0
  while IFS= read -r sa; do
    ((idx++)) || true
    local sa_name role disabled n
    sa_name=$(echo "$sa"  | jq -r '.name')
    role=$(echo "$sa"     | jq -r '.role // "Viewer"')
    [[ "$role" == "None" ]] && role="Viewer"
    disabled=$(echo "$sa" | jq -r '.isDisabled // false')
    n=$(slug "$sa_name")

    info "[${idx}/${count}] $sa_name ($role)"

    local yaml
    yaml=$(jq -n \
      --arg ns       "$NAMESPACE" \
      --arg n        "$n" \
      --arg sa_name  "$sa_name" \
      --arg role     "$role" \
      --argjson dis  "$disabled" \
      '{
        apiVersion: "grafana.integreatly.org/v1beta1",
        kind: "GrafanaServiceAccount",
        metadata: { name: $n, namespace: $ns },
        spec: {
          instanceName: "grafana",
          name: $sa_name,
          role: $role,
          isDisabled: $dis
        }
      }' | yq -P '.')
    write_file "$OUTPUT_DIR/service-accounts/${n}.yaml" "$yaml"
  done < <(echo "$sa_json" | jq -c "($filter) | .[]")
  echo ""
}

# ─── 5. Dashboards ────────────────────────────────────────────────────────────
migrate_dashboards() {
  type_selected "dashboards" || return 0
  log "5/8  Dashboards"

  local search_json count
  search_json=$(gapi "/search?type=dash-db&limit=5000")
  count=$(echo "$search_json" | jq 'length')
  [[ "$count" -eq 0 ]] && { info "No dashboards found."; echo ""; return; }

  local idx=0
  while IFS= read -r d; do
    ((idx++)) || true
    local title dash_uid folder_uid n folder_path folder_cr dash_dir

    title=$(echo "$d"      | jq -r '.title')
    dash_uid=$(echo "$d"   | jq -r '.uid')
    folder_uid=$(echo "$d" | jq -r '.folderUid // ""')
    n=$(slug "$title")

    if [[ -n "$folder_uid" && ${#_FC[@]} -gt 0 ]]; then
      folder_path=$(folder_path "$folder_uid")
      folder_cr=$(slug "$(folder_title "$folder_uid")")
    else
      folder_path="general"
      folder_cr=$(echo "$d" | jq -r '.folderTitle // "general"' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
      [[ -z "$folder_cr" || "$folder_cr" == "null" ]] && folder_cr="general"
    fi

    dash_dir="$OUTPUT_DIR/dashboards/${folder_path}"
    mkdir -p "$dash_dir"
    info "[${idx}/${count}] $title  →  dashboards/${folder_path}/"

    # Fetch full dashboard JSON — strip id, reset version
    local dash_json
    dash_json=$(gapi "/dashboards/uid/$dash_uid" | jq '.dashboard | del(.id) | .version = 0')

    # ── ConfigMap (stdin builds the entire object; no envsubst/E2BIG) ────────────
    local cm_yaml
    cm_yaml=$(echo "$dash_json" | jq \
      --arg ns "$NAMESPACE" \
      --arg n  "$n" \
      --arg ik "$INSTANCE_KEY" \
      --arg iv "$INSTANCE_VAL" \
      '{
        apiVersion: "v1",
        kind: "ConfigMap",
        metadata: {
          name: ($n + "-dashboard"),
          namespace: $ns,
          labels: { ($ik): $iv }
        },
        data: { "dashboard.json": (. | tojson) }
      }' | yq -P '.')
    write_file "$dash_dir/${n}-configmap.yaml" "$cm_yaml"

    # ── GrafanaDashboard CR ────────────────────────────────────────────────────
    local cr_yaml
    cr_yaml=$(jq -n \
      --arg ns  "$NAMESPACE" \
      --arg n   "$n" \
      --arg ik  "$INSTANCE_KEY" \
      --arg iv  "$INSTANCE_VAL" \
      --arg fr  "$folder_cr" \
      --arg uid "$dash_uid" \
      '{
        apiVersion: "grafana.integreatly.org/v1beta1",
        kind: "GrafanaDashboard",
        metadata: { name: $n, namespace: $ns },
        spec: {
          instanceSelector: { matchLabels: { ($ik): $iv } },
          resyncPeriod: "0s",
          folderRef: $fr,
          uid: $uid,
          configMapRef: {
            name: ($n + "-dashboard"),
            key: "dashboard.json"
          }
        }
      }' | yq -P '.')
    write_file "$dash_dir/${n}.yaml" "$cr_yaml"
  done < <(echo "$search_json" | jq -c '.[]')
  echo ""
}

# ─── 6. Alert Rule Groups ─────────────────────────────────────────────────────
migrate_alert_rule_groups() {
  type_selected "alert-rule-groups" || return 0
  log "6/8  Alert rule groups"

  local rules count
  rules=$(gprov "/alert-rules")
  count=$(echo "$rules" | jq 'length')
  [[ "$count" -eq 0 ]] && { info "No alert rules found."; echo ""; return; }

  # Unique (folderUID, ruleGroup) pairs
  local groups
  groups=$(echo "$rules" | jq -r '[.[] | {folderUID,ruleGroup}] | unique[] | .folderUID + "||" + .ruleGroup')
  local group_count; group_count=$(echo "$groups" | wc -l | tr -d ' ')

  local idx=0
  while IFS= read -r gk; do
    ((idx++)) || true
    local fuid rg folder_path folder_cr n alert_dir interval rules_json

    fuid="${gk%%||*}"
    rg="${gk##*||}"

    if [[ ${#_FC[@]} -gt 0 && -n "$fuid" ]]; then
      folder_path=$(folder_path "$fuid")
      folder_cr=$(slug "$(folder_title "$fuid")")
    else
      folder_path="general"; folder_cr="general"
    fi

    n="${folder_cr}-$(slug "$rg")"
    alert_dir="$OUTPUT_DIR/alerting/alert-rule-groups/${folder_path}"
    mkdir -p "$alert_dir"
    info "[${idx}/${group_count}] $rg  →  alerting/alert-rule-groups/${folder_path}/"

    # Evaluation interval from first rule
    interval=$(echo "$rules" | jq -r \
      --arg fuid "$fuid" --arg rg "$rg" \
      '[.[] | select(.folderUID==$fuid and .ruleGroup==$rg)] | first | .intervalSeconds // 60 | . / 60 | tostring + "m"')

    # Rules array — keep only operator-supported fields
    rules_json=$(echo "$rules" | jq \
      --arg fuid "$fuid" --arg rg "$rg" \
      '[.[] | select(.folderUID==$fuid and .ruleGroup==$rg) | {
        uid, title, condition,
        "for": .for,
        labels: (.labels // {}),
        annotations: (.annotations // {}),
        noDataState: (.noDataState // "NoData"),
        execErrState: (.execErrState // "Error"),
        isPaused: (.isPaused // false),
        data
      }]')

    local yaml
    yaml=$(echo "$rules_json" | jq \
      --arg ns       "$NAMESPACE" \
      --arg n        "$n" \
      --arg ik       "$INSTANCE_KEY" \
      --arg iv       "$INSTANCE_VAL" \
      --arg fr       "$folder_cr" \
      --arg rg       "$rg" \
      --arg interval "$interval" \
      '{
        apiVersion: "grafana.integreatly.org/v1beta1",
        kind: "GrafanaAlertRuleGroup",
        metadata: { name: $n, namespace: $ns },
        spec: {
          instanceSelector: { matchLabels: { ($ik): $iv } },
          resyncPeriod: "0s",
          folderRef: $fr,
          name: $rg,
          interval: $interval,
          rules: .
        }
      }' | yq -P '.')
    write_file "$alert_dir/${n}.yaml" "$yaml"
  done <<< "$groups"
  echo ""
}

# ─── 7. Contact Points ────────────────────────────────────────────────────────
# Known secure fields per contact-point type (Grafana redacts these).
cp_secure_fields() {
  case "$1" in
    email)        echo "" ;;
    pagerduty)    echo "integrationKey" ;;
    slack)        echo "url token" ;;
    webhook)      echo "url" ;;
    opsgenie)     echo "apiKey" ;;
    victorops)    echo "url" ;;
    pushover)     echo "apiToken userKey" ;;
    telegram)     echo "bottoken" ;;
    googlechat)   echo "url" ;;
    teams)        echo "url" ;;
    threema)      echo "api_secret" ;;
    discord)      echo "url" ;;
    sensugo)      echo "apikey" ;;
    line)         echo "token" ;;
    alertmanager) echo "basicAuthPassword" ;;
    dingding)     echo "url" ;;
    kafka)        echo "" ;;
    wecom)        echo "secret" ;;
    mqtt)         echo "password" ;;
    *)            echo "url apiKey token password" ;;
  esac
}

migrate_contact_points() {
  type_selected "contact-points" || return 0
  log "7/8  Contact points"
  mkdir -p "$OUTPUT_DIR/alerting/contact-points"

  local cp_json count
  cp_json=$(gprov "/contact-points")
  count=$(echo "$cp_json" | jq 'length')
  [[ "$count" -eq 0 ]] && { info "No contact points found."; echo ""; return; }

  local idx=0
  while IFS= read -r cp; do
    ((idx++)) || true
    local cp_name cp_type cp_uid dis_resolve settings_json n secret_name secure_flds

    cp_name=$(echo "$cp"     | jq -r '.name')
    cp_type=$(echo "$cp"     | jq -r '.type')
    dis_resolve=$(echo "$cp" | jq -r '.disableResolveMessage // false')
    settings_json=$(echo "$cp" | jq '.settings // {}')
    cp_uid=$(echo "$cp"      | jq -r 'if (.uid == "" or .uid == null) then "" else .uid end')
    n=$(slug "${cp_name}-${cp_type}")
    [[ -z "$cp_uid" ]] && cp_uid="$n"
    secret_name="${n}-credentials"

    info "[${idx}/${count}] $cp_name ($cp_type)"

    secure_flds=$(cp_secure_fields "$cp_type")
    local values_from_jq="[]"

    if [[ -n "$secure_flds" ]]; then
      local sd_jq="{}"
      local vf_entries="[]"
      for f in $secure_flds; do
        sd_jq=$(echo "$sd_jq" | jq --arg k "$f" '. + {($k): "CHANGE_ME"}')
        vf_entries=$(echo "$vf_entries" | jq \
          --arg f "$f" --arg sn "$secret_name" \
          '. + [{
            targetPath: ("settings." + $f),
            valueFrom: { secretKeyRef: { name: $sn, key: $f } }
          }]')
      done
      values_from_jq="$vf_entries"

      local sec_yaml
      sec_yaml=$(jq -n \
        --arg ns "$NAMESPACE" \
        --arg sn "$secret_name" \
        --arg rn "$cp_name" \
        --argjson sd "$sd_jq" \
        '{
          apiVersion: "v1", kind: "Secret",
          metadata: {
            name: $sn, namespace: $ns,
            annotations: {
              "grafana-operator/for": ("GrafanaContactPoint/" + $rn),
              "grafana-operator/secret-kind": "GrafanaContactPoint"
            }
          },
          stringData: $sd
        }' | yq -P '.')
      write_file "$SECRETS_DIR/${secret_name}.yaml" "$sec_yaml" "true"
    fi

    local yaml
    yaml=$(jq -n \
      --arg ns  "$NAMESPACE" \
      --arg n   "$n" \
      --arg ik  "$INSTANCE_KEY" \
      --arg iv  "$INSTANCE_VAL" \
      --arg cpn "$cp_name" \
      --arg uid "$cp_uid" \
      --arg t   "$cp_type" \
      --argjson dis "$dis_resolve" \
      --argjson set "$settings_json" \
      --argjson vf  "$values_from_jq" \
      '{
        apiVersion: "grafana.integreatly.org/v1beta1",
        kind: "GrafanaContactPoint",
        metadata: { name: $n, namespace: $ns },
        spec: {
          instanceSelector: { matchLabels: { ($ik): $iv } },
          resyncPeriod: "0s",
          uid: (if $uid != "" then $uid else null end),
          name: $cpn,
          receivers: [{
            uid: $uid,
            type: $t,
            disableResolveMessage: $dis,
            settings: $set
          }],
          valuesFrom: (if ($vf | length) > 0 then $vf else null end)
        } | del(.spec.valuesFrom | nulls, .spec.uid | nulls)
      }' | yq -P '.')
    write_file "$OUTPUT_DIR/alerting/contact-points/${n}.yaml" "$yaml"
  done < <(echo "$cp_json" | jq -c '.[]')
  echo ""
}

# ─── 8. Notification Policy ───────────────────────────────────────────────────
migrate_notification_policy() {
  type_selected "notification-policy" || return 0
  log "8/8  Notification policy"
  mkdir -p "$OUTPUT_DIR/alerting/notification-policies"

  local policy
  policy=$(gprov "/policies" 2>/dev/null || echo "null")
  [[ "$policy" == "null" || -z "$policy" ]] && { info "No notification policy found."; echo ""; return; }

  local yaml
  yaml=$(jq -n \
    --arg ns "$NAMESPACE" \
    --arg ik "$INSTANCE_KEY" \
    --arg iv "$INSTANCE_VAL" \
    --argjson pol "$policy" \
    '{
      apiVersion: "grafana.integreatly.org/v1beta1",
      kind: "GrafanaNotificationPolicy",
      metadata: { name: "default-notification-policy", namespace: $ns },
      spec: {
        instanceSelector: { matchLabels: { ($ik): $iv } },
        resyncPeriod: "0s",
        route: $pol
      }
    }' | yq -P '.')
  yaml=$(maybe_finalizer "$yaml")
  write_file "$OUTPUT_DIR/alerting/notification-policies/default-policy.yaml" "$yaml"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  init
  migrate_instance
  migrate_datasources
  migrate_folders        # always runs — populates folder cache
  migrate_teams
  migrate_service_accounts
  migrate_dashboards
  migrate_alert_rule_groups
  migrate_contact_points
  migrate_notification_policy

  local secret_count=0
  [[ "$DRY_RUN" == "false" ]] && \
    secret_count=$(find "$SECRETS_DIR" -maxdepth 2 -name "*.yaml" 2>/dev/null | wc -l | tr -d ' ')

  log "🎉 Migration complete!"
  echo ""
  info "Generated CRs     →  ${BOLD}${OUTPUT_DIR}/${RESET}"
  info "Secret scaffolds  →  ${BOLD}${SECRETS_DIR}/${RESET} (${secret_count} files with CHANGE_ME)"
  echo ""
  [[ "$secret_count" -gt 0 ]] && {
    warn "ACTION REQUIRED: Fill in CHANGE_ME values in ${SECRETS_DIR}/*.yaml"
    echo "       Do NOT commit files with real credential values to git."
    echo ""
  }
  [[ "$NO_RECREATE" == "true" ]] && \
    info "finalizerPolicy: delete set — deleting a CR also removes it from Grafana."
  echo ""
  info "Next step — apply all resources:"
  echo "       make apply NAMESPACE=${NAMESPACE}"
  echo ""
}

main
