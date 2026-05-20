#!/usr/bin/env bash
set -Eeuo pipefail

########################################
# PORTAINER API STACK UPDATER
#
# Keeps Portainer in control — does not run docker compose directly.
#
# Config: bootstrap path is CONFIG_FILE env or config.env next to stack-updater.sh.
# LOG_FILE and (optional) a chained CONFIG_FILE are read from that file — see
# config.env.example. Environment overrides config. If LOG_FILE is unset after
# sourcing config, default is stack-updater.log beside this script (e.g. under
# /opt/scripts/Stack-Updater/). Set LOG_FILE here (or export it) to use another path.
#
# Interactive default: no arguments + TTY opens the menu; cron/non-TTY runs
# the full pipeline. Use --batch to force full run from an interactive shell.
########################################

STACK_UPDATER_VERSION="1.1.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/lib/stack-updater-core.sh" ]]; then
  # shellcheck source=lib/stack-updater-core.sh
  source "$SCRIPT_DIR/lib/stack-updater-core.sh"
fi

_ENV_CONFIG_SET="false"
[[ "${CONFIG_FILE+isset}" == "isset" ]] && _ENV_CONFIG_SET="true"

_BOOT_CONFIG="${CONFIG_FILE:-$SCRIPT_DIR/config.env}"

_ENV_LOG_SET="false"
if [[ "${LOG_FILE+isset}" == "isset" ]]; then
  _ENV_LOG_SET="true"
  _ENV_LOG_VAL="$LOG_FILE"
fi

CONFIG_FILE="$_BOOT_CONFIG"

########################################
# DEFAULT CONFIG (overridden by CONFIG_FILE)
########################################

DRY_RUN="false"

UPDATE_HOST_PACKAGES="true"
UPDATE_DOCKER_PACKAGES="true"
UPDATE_PORTAINER_CONTAINER="true"

PRUNE_UNUSED_IMAGES="true"
PRUNE_UNUSED_NETWORKS="true"
# Unused named volumes only (docker volume prune -f); volumes still attached to running containers are kept.
PRUNE_UNUSED_VOLUMES="false"

SKIP_HOST_IF_NONE="false"
SKIP_DOCKER_PKGS_IF_NONE="false"
STACK_UPDATE_PROMPT="false"

VERBOSE="false"
# quiet | verbose — see README; legacy VERBOSE=true forces verbose after config load.
OUTPUT_MODE="quiet"
CONFIRM_EACH_STEP="false"

SELECTIVE_STACK_REDEPLOY="true"
REDEPLOY_GIT_STACKS_IF_CUP_UNKNOWN="true"
REGISTRY_FAIL_POLICY="safe"

# TTY colors: auto (respect NO_COLOR), always (this script only; needs a TTY on stdout or stderr), never.
STACK_UPDATER_COLOR="always"
# Done glyph when colors OK: check (Unicode U+2713) | emoji (U+2705).
STACK_UPDATER_DONE_MARK="emoji"

CUP_ENABLED="false"
CUP_URL=""
# POST/GET /api/v3/refresh before JSON when true; timeout seconds for refresh + JSON curl.
CUP_REFRESH_BEFORE_CHECK="${CUP_REFRESH_BEFORE_CHECK:-true}"
CUP_REFRESH_TIMEOUT_SECONDS="${CUP_REFRESH_TIMEOUT_SECONDS:-60}"
# After stack redeploys, POST /api/v3/refresh so Cup UI/next run see new state (does not alter this run's summary).
CUP_REFRESH_AFTER_STACKS="${CUP_REFRESH_AFTER_STACKS:-true}"

SKIP_STACK_PHASE_IF_CUP_CLEAN="false"
SKIP_CLEANUP_IF_STACKS_SKIPPED="true"

PORTAINER_CONTAINER_NAME="portainer"
# lts|sts → portainer/portainer-ce:lts|sts; custom → use PORTAINER_IMAGE from config (tag or digest pin).
PORTAINER_RELEASE_STREAM="lts"
PORTAINER_IMAGE="portainer/portainer-ce:lts"
# Publish 8000 for Edge Agent. Legacy HTTP UI on 9000 is off unless enabled (see config.env.example).
PORTAINER_ENABLE_EDGE_PORT="true"
PORTAINER_ENABLE_LEGACY_HTTP_PORT="false"
# When true and Cup is enabled, skip docker pull for Portainer if Cup lists the image and reports no update.
PORTAINER_USE_CUP_PRECHECK="${PORTAINER_USE_CUP_PRECHECK:-true}"
# If true, non-interactive recreate requires PORTAINER_BACKUP_ACKNOWLEDGED=1; TTY may prompt once.
PORTAINER_REQUIRE_BACKUP_BEFORE_UPDATE="false"

DEFAULT_STACK_SLEEP_SECONDS=10
DEPENDENCY_SETTLE_SECONDS=90
DEPENDENT_STACK_SLEEP_SECONDS=30
HEAVY_STACK_SLEEP_SECONDS=45

# Portainer stack names (redeploy order / exclusions / extra sleeps).
DEPENDENCY_STACKS=()
DEPENDENT_STACKS=()
EXCLUDED_STACKS=()
HEAVY_STACKS=()

# Concurrency / exit policy (see config.env.example).
LOCK_FILE=""
SKIP_RUN_LOCK="false"
PIPELINE_HARD_FAILURE=0
EXIT_WARNINGS_AS_FAILURE="false"

# Notifications (optional).
NOTIFY_ON_FAILURE="true"
NOTIFY_ON_SUCCESS="false"
NOTIFY_COMMAND=""
NOTIFY_WEBHOOK_URL=""

# Log rotation (bytes; 0 = disabled).
LOG_MAX_BYTES="5242880"

# Portainer API TLS (default insecure for localhost Portainer HTTPS).
PORTAINER_TLS_VERIFY="false"
PORTAINER_CA_BUNDLE=""
PORTAINER_API_KEY_FILE=""

# Portainer recreate safety.
PORTAINER_RECREATE_ACK_DIVERGENCE="false"

# Image prune retention (e.g. 24h); empty = prune all unused (-af).
PRUNE_IMAGES_UNTIL=""

# Single-stack CLI override (empty = all stacks).
SINGLE_STACK_NAME=""

########################################
# CLI STATE (parsed before sourcing config)
########################################

AUTO_YES="false"
CHECK_ONLY="false"
DRY_RUN_CLI="false"
RUN_ALL="false"
TUI_MODE="false"
BATCH_MODE="false"
VERBOSE_CLI="false"
OUTPUT_MODE_CLI=""
CONFIRM_STEPS_CLI="false"
NO_COLOR_CLI="false"
SELF_TEST="false"
SHOW_VERSION="false"

EMPTY_INVOCATION="false"
declare -a PHASE_QUEUE=()

########################################
# RUNTIME: Portainer stacks cache (invalidated after Portainer self-update)
########################################

STACKS_JSON_CACHE=""

########################################
# RUN SUMMARY ACCUMULATORS (runtime)
########################################

STACK_PHASE_SKIPPED_DUE_CUP="false"
SUMMARY_PHASE_HOST="not_run"
SUMMARY_PHASE_DOCKER_PKGS="not_run"
SUMMARY_PHASE_PORTAINER="not_run"
SUMMARY_PHASE_STACKS="not_run"
SUMMARY_PHASE_CLEANUP="not_run"
STACKS_REDEPLOYED=()
STACKS_SKIPPED_REASONS=()
# RUN SUMMARY substeps under Phase stacks (set by deploy_* when stacks phase runs).
SUMMARY_STACK_SUB_DEPENDENCY=""
SUMMARY_STACK_SUB_DEPENDENT=""
SUMMARY_STACK_SUB_HEAVY=""
SUMMARY_STACK_SUB_REMAINING=""
# Set at pipeline entry (execute_full_pipeline / run_phases_list); consumed by print_run_summary duration line.
PIPELINE_START_EPOCH=""
# Set true only for execute_full_pipeline (enables full System status block).
FULL_UI_PIPELINE=""
# Phase durations (seconds); empty if phase did not run this invocation.
PHASE_SEC_HOST=""
PHASE_SEC_DOCKER_PKGS=""
PHASE_SEC_PORTAINER=""
PHASE_SEC_STACKS=""
PHASE_SEC_CLEANUP=""
# Subgroup counters for stacks phase (quiet UX metrics).
STACK_GRP_DEP_CHECKED=0
STACK_GRP_DEP_REDEPLOYED=0
STACK_GRP_DEP_FAILED=0
STACK_GRP_DEPENDENT_CHECKED=0
STACK_GRP_DEPENDENT_REDEPLOYED=0
STACK_GRP_DEPENDENT_FAILED=0
STACK_GRP_HEAVY_CHECKED=0
STACK_GRP_HEAVY_REDEPLOYED=0
STACK_GRP_HEAVY_FAILED=0
STACK_GRP_REMAINING_CHECKED=0
STACK_GRP_REMAINING_REDEPLOYED=0
STACK_GRP_REMAINING_FAILED=0
RUN_WARNING_COUNT=0
# Captured during docker pkgs phase for quiet System lines.
DOCKER_VER_DISPLAY=""
COMPOSE_VER_DISPLAY=""
# Set by print_run_summary; used by dispatch_cli exit status when stacks ran.
LAST_PIPELINE_EXIT_CODE=""
# Stack phase progress + verbose chronology (1-based index / total set in deploy_in_correct_order).
STACK_PROGRESS_TOTAL=0
STACK_PROGRESS_INDEX=0
declare -a STACK_RUN_LOG=()
# Last Cup counts from print_statistics_block (for RUN SUMMARY).
LAST_CUP_TRACKED=""
LAST_CUP_OUTDATED=""
LAST_CUP_CURRENT=""
LAST_CUP_UNKNOWN=""
# Cup: not_checked | ok | unreachable | parse_error — last successful JSON for selective / skip-gate reuse.
CUP_STATUS="not_checked"
CUP_LAST_ERROR=""
CUP_JSON_SNAPSHOT=""
# True after first pre-run Cup refresh+JSON path in this run (only cup_fetch_json arms refresh once).
CUP_REFRESH_DONE="false"
# Immutable Cup counts/json from the first successful parse this run (Run Summary / pipeline_end).
CUP_RUN_METRICS_LOCKED="false"
CUP_RUN_TRACKED=""
CUP_RUN_OUTDATED=""
CUP_RUN_CURRENT=""
CUP_RUN_UNKNOWN=""
CUP_RUN_JSON_SNAPSHOT=""
# Optional diagnostics after post-stack refresh only (never used for summary or redeploy decisions).
CUP_POST_TRACKED=""
CUP_POST_OUTDATED=""
CUP_POST_CURRENT=""
CUP_POST_UNKNOWN=""
CUP_POST_REFRESH_JSON=""
# Last HTTP code from cup_http_refresh_once (logging).
CUP_HTTP_REFRESH_LAST_CODE=""
# Set when quiet stack rows / subgroup block finished; blank line before CLEANUP banner.
QUIET_STACK_SECTION_DONE="false"
# Cleanup phase one-line summaries (set by cleanup_docker).
CLEANUP_IMAGE_SUMMARY=""
CLEANUP_NETWORK_SUMMARY=""
CLEANUP_VOLUME_SUMMARY=""
# Set when quiet-tree legend printed after title (avoid duplicate under Container updates).
QUIET_TREE_LEGEND_DONE="false"
# Last redeploy_stack_by_name outcome (for post-redeploy waits; reset each call).
STACK_LAST_ACTUAL_REDEPLOY=0
STACK_LAST_DRY_RUN_PLANNED_REDEPLOY=0
STACK_LAST_REDEPLOY_T0=0
STACK_LAST_REDEPLOY_SECS=0
# Seconds slept by the last stack_post_redeploy_wait_for_group call (log / aggregates).
STACK_LAST_POST_WAIT_SECS=0

# Runtime lock / temp tracking.
RUN_LOCK_ACQUIRED="false"
LOCK_FD=200
declare -a _TEMP_FILES=()
STACK_UPDATER_TRAP_REGISTERED="false"
USER_CANCELLED="false"

reset_full_pipeline_summaries() {
  _PORTAINER_DIGEST_STAT=""
  _PORTAINER_REG_DIGEST=""
  _PORTAINER_REG_VERSION=""
  _PORTAINER_VER_SERVER=""
  LAST_CUP_TRACKED=""
  LAST_CUP_OUTDATED=""
  LAST_CUP_CURRENT=""
  LAST_CUP_UNKNOWN=""
  CUP_STATUS="not_checked"
  CUP_LAST_ERROR=""
  CUP_JSON_SNAPSHOT=""
  CUP_REFRESH_DONE="false"
  CUP_RUN_METRICS_LOCKED="false"
  CUP_RUN_TRACKED=""
  CUP_RUN_OUTDATED=""
  CUP_RUN_CURRENT=""
  CUP_RUN_UNKNOWN=""
  CUP_RUN_JSON_SNAPSHOT=""
  CUP_POST_TRACKED=""
  CUP_POST_OUTDATED=""
  CUP_POST_CURRENT=""
  CUP_POST_UNKNOWN=""
  CUP_POST_REFRESH_JSON=""
  CUP_HTTP_REFRESH_LAST_CODE=""
  QUIET_STACK_SECTION_DONE="false"
  CLEANUP_IMAGE_SUMMARY=""
  CLEANUP_NETWORK_SUMMARY=""
  CLEANUP_VOLUME_SUMMARY=""
  QUIET_TREE_LEGEND_DONE="false"
  STACK_LAST_ACTUAL_REDEPLOY=0
  STACK_LAST_DRY_RUN_PLANNED_REDEPLOY=0
  STACK_LAST_REDEPLOY_T0=0
  STACK_LAST_REDEPLOY_SECS=0
  STACK_LAST_POST_WAIT_SECS=0
  STACK_PHASE_SKIPPED_DUE_CUP="false"
  SUMMARY_PHASE_HOST="not_run"
  SUMMARY_PHASE_DOCKER_PKGS="not_run"
  SUMMARY_PHASE_PORTAINER="not_run"
  SUMMARY_PHASE_STACKS="not_run"
  SUMMARY_PHASE_CLEANUP="not_run"
  STACKS_REDEPLOYED=()
  STACKS_SKIPPED_REASONS=()
  SUMMARY_STACK_SUB_DEPENDENCY=""
  SUMMARY_STACK_SUB_DEPENDENT=""
  SUMMARY_STACK_SUB_HEAVY=""
  SUMMARY_STACK_SUB_REMAINING=""
  QUIET_TREE_SECTION=""
  PIPELINE_START_EPOCH=""
  PHASE_SEC_HOST=""
  PHASE_SEC_DOCKER_PKGS=""
  PHASE_SEC_PORTAINER=""
  PHASE_SEC_STACKS=""
  PHASE_SEC_CLEANUP=""
  STACK_GRP_DEP_CHECKED=0
  STACK_GRP_DEP_REDEPLOYED=0
  STACK_GRP_DEP_FAILED=0
  STACK_GRP_DEPENDENT_CHECKED=0
  STACK_GRP_DEPENDENT_REDEPLOYED=0
  STACK_GRP_DEPENDENT_FAILED=0
  STACK_GRP_HEAVY_CHECKED=0
  STACK_GRP_HEAVY_REDEPLOYED=0
  STACK_GRP_HEAVY_FAILED=0
  STACK_GRP_REMAINING_CHECKED=0
  STACK_GRP_REMAINING_REDEPLOYED=0
  STACK_GRP_REMAINING_FAILED=0
  RUN_WARNING_COUNT=0
  PIPELINE_HARD_FAILURE=0
  DOCKER_VER_DISPLAY=""
  COMPOSE_VER_DISPLAY=""
  FULL_UI_PIPELINE=""
  LAST_PIPELINE_EXIT_CODE=""
  STACK_PROGRESS_TOTAL=0
  STACK_PROGRESS_INDEX=0
  STACK_RUN_LOG=()
}

reset_phases_list_summaries() {
  reset_full_pipeline_summaries
}

usage() {
  cat <<'EOF'
Portainer API stack updater

Usage:
  stack-updater.sh [options]

Options:
  --run-all              Full pipeline (host → docker pkgs → Portainer → stacks → cleanup)
  --batch, --no-menu     Full pipeline without opening the TTY menu (see defaults below)
  --phase PHASE          Run one or more phases (canonical order applied):
                         host | docker_pkgs | portainer | cup | stacks | cleanup
                         (cup = Cup API self-test: refresh, JSON, metrics, stack match hints)
  --check-only, --report No changes: connectivity, apt summary, optional Cup, stack list
  --dry-run              Log actions only (sets DRY_RUN=true)
  --yes                  Non-interactive (skip prompts; use with cron)
  --self-test            Read-only checks (deps, config parse, Portainer/Cup/Docker, log path); no mutations
  --tui                  Open interactive menu (same as no-args TTY; Gum or numbered prompts)
  -v, --verbose          Same as --output verbose (full detail + streams)
  -q, --quiet            Same as --output quiet (parent checklist + minimal TTY)
  --output MODE          quiet | verbose (legacy: standard → quiet; invalid → quiet)
  --confirm-steps        Prompt before each major step (TTY only; skipped with --yes)
  --no-color             Force plain output (same as STACK_UPDATER_COLOR=never)
  --version, -V          Print version and exit
  --stack NAME           Redeploy only this Portainer stack name (stacks phase)
  -h, --help             This help

Defaults:
  • No arguments + interactive TTY: opens the menu (output + confirmations + action list) unless STACK_UPDATER_MENU=false.
  • No arguments + non-TTY (e.g. cron): full pipeline; OUTPUT_MODE quiet unless overridden by CLI or env.
  • Any other flags: no menu unless --tui.

Environment:
  CONFIG_FILE   Bootstrap config path (default: config.env next to script)
  LOG_FILE      If set before launch, overrides LOG_FILE from config (default when unset: stack-updater.log beside script)
  STACK_UPDATER_MENU  If false (or 0|no), skip the TTY menu and run the full pipeline (same idea as --batch for menu only)
  PRUNE_NETWORKS  If set (1|0|true|false), overrides PRUNE_UNUSED_NETWORKS after config load
  PRUNE_VOLUMES    If set (1|0|true|false), overrides PRUNE_UNUSED_VOLUMES after config load
  PORTAINER_RELEASE_STREAM  lts | sts | custom — sets CE image tag (custom: use PORTAINER_IMAGE from config)
  PORTAINER_BACKUP_ACKNOWLEDGED  Set to 1 when PORTAINER_REQUIRE_BACKUP_BEFORE_UPDATE=true and stdin is not a TTY

See README.md and config.env.example (paths section).

Optional styling (quiet tree):
  STACK_UPDATER_COLOR   auto | always | never — auto respects NO_COLOR; always enables ANSI when stdout or stderr is a TTY (this script only).
  STACK_UPDATER_DONE_MARK  check | emoji — glyph for completed rows (emoji needs UTF-8 terminal/font).
  --no-color             CLI shortcut for plain output this run.
EOF
  echo "Version: ${STACK_UPDATER_VERSION}"
}

parse_cli() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help | -h)
        usage
        exit 0
        ;;
      --run-all)
        RUN_ALL="true"
        shift
        ;;
      --batch | --no-menu)
        BATCH_MODE="true"
        shift
        ;;
      --check-only | --report)
        CHECK_ONLY="true"
        shift
        ;;
      --dry-run)
        DRY_RUN_CLI="true"
        shift
        ;;
      --yes)
        AUTO_YES="true"
        shift
        ;;
      --self-test)
        SELF_TEST="true"
        shift
        ;;
      --tui)
        TUI_MODE="true"
        shift
        ;;
      -v | --verbose)
        VERBOSE_CLI="true"
        shift
        ;;
      -q | --quiet)
        OUTPUT_MODE_CLI="quiet"
        shift
        ;;
      --output)
        if [[ -z "${2:-}" ]]; then
          echo "ERROR: --output requires quiet|verbose" >&2
          exit 2
        fi
        OUTPUT_MODE_CLI="${2,,}"
        shift 2
        ;;
      --confirm-steps)
        CONFIRM_STEPS_CLI="true"
        shift
        ;;
      --no-color)
        NO_COLOR_CLI="true"
        shift
        ;;
      --version | -V)
        SHOW_VERSION="true"
        shift
        ;;
      --stack)
        if [[ -z "${2:-}" ]]; then
          echo "ERROR: --stack requires a stack name" >&2
          exit 2
        fi
        SINGLE_STACK_NAME="$2"
        [[ ${#PHASE_QUEUE[@]} -eq 0 ]] && PHASE_QUEUE+=(stacks)
        shift 2
        ;;
      --phase)
        if [[ -z "${2:-}" ]]; then
          echo "ERROR: --phase requires an argument" >&2
          exit 2
        fi
        PHASE_QUEUE+=("$2")
        shift 2
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
}

[[ $# -eq 0 ]] && EMPTY_INVOCATION="true"
parse_cli "$@"

if [[ "$SHOW_VERSION" == "true" ]]; then
  printf 'stack-updater %s\n' "${STACK_UPDATER_VERSION}"
  exit 0
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing config file: $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Optional second config: set CONFIG_FILE=/path/other.env in the first file to chain-load
# (skipped when bootstrap path was chosen via CONFIG_FILE environment variable).
if [[ "$_ENV_CONFIG_SET" == "false" ]] && [[ -n "${CONFIG_FILE:-}" ]] && [[ "$CONFIG_FILE" != "$_BOOT_CONFIG" ]] && [[ -f "$CONFIG_FILE" ]]; then
  _CHAIN="$CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$_CHAIN"
  CONFIG_FILE="$_CHAIN"
else
  CONFIG_FILE="$_BOOT_CONFIG"
fi

if [[ "$_ENV_LOG_SET" == "true" ]]; then
  LOG_FILE="$_ENV_LOG_VAL"
else
  LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/stack-updater.log}"
fi

[[ "$DRY_RUN_CLI" == "true" ]] && DRY_RUN="true"
[[ "$CONFIRM_STEPS_CLI" == "true" ]] && CONFIRM_EACH_STEP="true"

# OUTPUT_MODE: quiet | verbose (CLI > config; legacy standard → quiet; -v forces verbose; legacy VERBOSE=true → verbose)
if [[ "$VERBOSE_CLI" == "true" ]]; then
  OUTPUT_MODE="verbose"
elif [[ -n "${OUTPUT_MODE_CLI:-}" ]]; then
  OUTPUT_MODE="$OUTPUT_MODE_CLI"
else
  OUTPUT_MODE="${OUTPUT_MODE:-quiet}"
fi
case "${OUTPUT_MODE,,}" in
  standard) OUTPUT_MODE="quiet" ;;
esac
case "${OUTPUT_MODE}" in
  quiet | verbose) ;;
  *) OUTPUT_MODE="quiet" ;;
esac
if [[ "${VERBOSE:-false}" == "true" ]]; then
  OUTPUT_MODE="verbose"
fi
if [[ "$OUTPUT_MODE" == "verbose" ]]; then
  VERBOSE="true"
else
  VERBOSE="false"
fi

[[ "$NO_COLOR_CLI" == "true" ]] && STACK_UPDATER_COLOR="never"

# Command-line env overrides config for unused network prune: PRUNE_NETWORKS=0 ./stack-updater.sh
if [[ "${PRUNE_NETWORKS+set}" == "set" ]]; then
  case "${PRUNE_NETWORKS,,}" in
    1 | true | yes) PRUNE_UNUSED_NETWORKS="true" ;;
    0 | false | no) PRUNE_UNUSED_NETWORKS="false" ;;
  esac
fi

if [[ "${PRUNE_VOLUMES+set}" == "set" ]]; then
  case "${PRUNE_VOLUMES,,}" in
    1 | true | yes) PRUNE_UNUSED_VOLUMES="true" ;;
    0 | false | no) PRUNE_UNUSED_VOLUMES="false" ;;
  esac
fi

# Portainer CE image from release stream (lts|sts) or use PORTAINER_IMAGE as-is (custom).
portainer_apply_release_stream() {
  local s="${PORTAINER_RELEASE_STREAM:-lts}"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"
  case "$s" in
    lts) PORTAINER_IMAGE="portainer/portainer-ce:lts" ;;
    sts) PORTAINER_IMAGE="portainer/portainer-ce:sts" ;;
    custom) ;;
    *)
      printf '%s\n' "ERROR: PORTAINER_RELEASE_STREAM must be lts, sts, or custom (got: ${PORTAINER_RELEASE_STREAM:-})" >&2
      exit 1
      ;;
  esac
}
portainer_apply_release_stream

: "${PORTAINER_URL:?PORTAINER_URL is missing}"
: "${ENDPOINT_ID:?ENDPOINT_ID is missing}"
if [[ -z "${PORTAINER_API_KEY:-}" ]] && [[ ! -f "${PORTAINER_API_KEY_FILE:-}" ]]; then
  echo "ERROR: PORTAINER_API_KEY or PORTAINER_API_KEY_FILE is required." >&2
  exit 1
fi
build_curl_opts_and_auth

# Cup HTTP timeouts / refresh (config may set; normalize booleans and numeric timeout).
case "${CUP_REFRESH_BEFORE_CHECK,,}" in
  1 | true | yes) CUP_REFRESH_BEFORE_CHECK="true" ;;
  0 | false | no) CUP_REFRESH_BEFORE_CHECK="false" ;;
  *) CUP_REFRESH_BEFORE_CHECK="true" ;;
esac
CUP_REFRESH_TIMEOUT_SECONDS="${CUP_REFRESH_TIMEOUT_SECONDS:-60}"
CUP_REFRESH_TIMEOUT_SECONDS="${CUP_REFRESH_TIMEOUT_SECONDS//[^0-9]/}"
[[ -z "$CUP_REFRESH_TIMEOUT_SECONDS" ]] && CUP_REFRESH_TIMEOUT_SECONDS=60

case "${CUP_REFRESH_AFTER_STACKS,,}" in
  1 | true | yes) CUP_REFRESH_AFTER_STACKS="true" ;;
  0 | false | no) CUP_REFRESH_AFTER_STACKS="false" ;;
  *) CUP_REFRESH_AFTER_STACKS="true" ;;
esac

case "${PORTAINER_USE_CUP_PRECHECK,,}" in
  1 | true | yes) PORTAINER_USE_CUP_PRECHECK="true" ;;
  0 | false | no) PORTAINER_USE_CUP_PRECHECK="false" ;;
  *) PORTAINER_USE_CUP_PRECHECK="true" ;;
esac

LOCK_FILE="${LOCK_FILE:-$SCRIPT_DIR/.stack-updater.lock}"

case "${PORTAINER_TLS_VERIFY,,}" in
  1 | true | yes) PORTAINER_TLS_VERIFY="true" ;;
  *) PORTAINER_TLS_VERIFY="false" ;;
esac

case "${EXIT_WARNINGS_AS_FAILURE,,}" in
  1 | true | yes) EXIT_WARNINGS_AS_FAILURE="true" ;;
  *) EXIT_WARNINGS_AS_FAILURE="false" ;;
esac

case "${NOTIFY_ON_FAILURE,,}" in
  0 | false | no) NOTIFY_ON_FAILURE="false" ;;
  *) NOTIFY_ON_FAILURE="true" ;;
esac
case "${NOTIFY_ON_SUCCESS,,}" in
  1 | true | yes) NOTIFY_ON_SUCCESS="true" ;;
  *) NOTIFY_ON_SUCCESS="false" ;;
esac

LOG_MAX_BYTES="${LOG_MAX_BYTES:-5242880}"
LOG_MAX_BYTES="${LOG_MAX_BYTES//[^0-9]/}"
[[ -z "$LOG_MAX_BYTES" ]] && LOG_MAX_BYTES=0

build_curl_opts_and_auth() {
  CURL_OPTS=(--silent --show-error --fail)
  if [[ "${PORTAINER_TLS_VERIFY:-false}" != "true" ]]; then
    CURL_OPTS+=(--insecure)
  elif [[ -n "${PORTAINER_CA_BUNDLE:-}" && -f "${PORTAINER_CA_BUNDLE}" ]]; then
    CURL_OPTS+=(--cacert "$PORTAINER_CA_BUNDLE")
  fi
  local _pkey="${PORTAINER_API_KEY}"
  if [[ -n "${PORTAINER_API_KEY_FILE:-}" && -f "${PORTAINER_API_KEY_FILE}" ]]; then
    _pkey="$(tr -d '\r\n' <"${PORTAINER_API_KEY_FILE}")"
  fi
  AUTH_HEADER=(-H "X-API-Key: ${_pkey}")
}

_register_stack_updater_traps() {
  [[ "$STACK_UPDATER_TRAP_REGISTERED" == "true" ]] && return 0
  trap '_stack_updater_on_exit' EXIT
  trap '_stack_updater_on_signal' INT TERM
  trap '_err_trap' ERR
  STACK_UPDATER_TRAP_REGISTERED="true"
}
_register_stack_updater_traps

DOCKER_PKG_LIST=(
  docker-ce
  docker-ce-cli
  containerd.io
  docker-compose-plugin
  jq
  curl
)

CANONICAL_PHASE_ORDER=(host docker_pkgs portainer cup stacks cleanup)

phase_is_valid() {
  local p="$1" c
  for c in "${CANONICAL_PHASE_ORDER[@]}"; do
    [[ "$p" == "$c" ]] && return 0
  done
  return 1
}

########################################
# TTY / ANSI (respect https://no-color.org/ when NO_COLOR is set;
# STACK_UPDATER_COLOR=always overrides NO_COLOR for this script only)
########################################

_tty_ansi_ok() {
  [[ "${TERM:-}" != "dumb" ]] || return 1
  case "${STACK_UPDATER_COLOR:-auto}" in
    never) return 1 ;;
    always)
      [[ -t 1 ]] || [[ -t 2 ]] || return 1
      return 0
      ;;
    auto | *) [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] ;;
  esac
}

tty_color() {
  _tty_ansi_ok || {
    echo ""
    return
  }
  case "${1:-}" in
    green) printf '\033[32m' ;;
    yellow) printf '\033[33m' ;;
    red) printf '\033[31m' ;;
    blue) printf '\033[34m' ;;
    cyan) printf '\033[36m' ;;
    magenta) printf '\033[35m' ;;
    dim) printf '\033[2m' ;;
    reset) printf '\033[0m' ;;
    *) echo "" ;;
  esac
}

tty_checkmark() {
  case "${STACK_UPDATER_DONE_MARK:-check}" in
    emoji)
      if _tty_ansi_ok; then
        printf '%s%s%s' "$(tty_color green)" "✅" "$(tty_color reset)"
      else
        printf '%s' '✅'
      fi
      ;;
    check | *)
      if _tty_ansi_ok; then
        printf '%s%s%s' "$(tty_color green)" "✓" "$(tty_color reset)"
      else
        printf '+'
      fi
      ;;
  esac
}

# Status icons for stack rows / summaries: emoji | minimal | ascii (no new config keys).
_legend_mode() {
  if [[ "${STACK_UPDATER_COLOR:-auto}" == "never" ]] || ! _tty_ansi_ok; then
    printf '%s' "ascii"
    return
  fi
  case "${STACK_UPDATER_DONE_MARK:-check}" in
    emoji) printf '%s' "emoji" ;;
    *) printf '%s' "minimal" ;;
  esac
}

_leg_icon() {
  local key="${1:-}" mode
  mode="$(_legend_mode)"
  case "${mode}:${key}" in
    emoji:up_to_date) printf '%s' '✅' ;;
    minimal:up_to_date) printf '%s' '✓' ;;
    ascii:up_to_date) printf '%s' 'OK' ;;
    emoji:update_available) printf '%s' '⬆️' ;;
    minimal:update_available) printf '%s' '↑' ;;
    ascii:update_available) printf '%s' '^' ;;
    emoji:no_change) printf '%s' '⏸️' ;;
    minimal:no_change) printf '%s' '−' ;;
    ascii:no_change) printf '%s' '-' ;;
    emoji:skipped) printf '%s' '⏭️' ;;
    minimal:skipped) printf '%s' '»' ;;
    ascii:skipped) printf '%s' '>>' ;;
    emoji:failed) printf '%s' '❌' ;;
    minimal:failed) printf '%s' '×' ;;
    ascii:failed) printf '%s' 'X' ;;
    emoji:cleaned) printf '%s' '🧹' ;;
    minimal:cleaned) printf '%s' '~' ;;
    ascii:cleaned) printf '%s' '~' ;;
    emoji:in_progress) printf '%s' '🔄' ;;
    minimal:in_progress) printf '%s' '…' ;;
    ascii:in_progress) printf '%s' '...' ;;
    emoji:redeployed) printf '%s' '🔄' ;;
    minimal:redeployed) printf '%s' '…' ;;
    ascii:redeployed) printf '%s' '...' ;;
    emoji:warnings) printf '%s' '⚠️' ;;
    minimal:warnings) printf '%s' '!' ;;
    ascii:warnings) printf '%s' '!!' ;;
    *) printf '%s' '•' ;;
  esac
}

_quiet_tree_tty() {
  [[ -t 1 ]] && [[ "${OUTPUT_MODE:-quiet}" == "quiet" ]] && [[ "$CHECK_ONLY" != "true" ]]
}

# UI helpers: consistent quiet-tree presentation + LOG_FILE mirror for summaries.
ui_mirror_line() {
  _emit_log_file_ts "$*"
}

ui_section_heading() {
  local color_key="${1:-green}" title="$2"
  _quiet_tree_tty || return 0
  quiet_section_title "$color_key" "$title"
}

ui_indent_kv() {
  local indent="${1:-2}" key="$2" val="$3"
  _quiet_tree_tty || return 0
  _emit_log_file_ts "${key}: ${val}"
  printf '%*s%s%s%s%s\n' "$indent" "" "$(tty_color dim)" "${key}: " "$(tty_color reset)" "${val}"
}

# Extra newline between quiet-tree sections (e.g. after Portainer, before Update strategy).
ui_blank() {
  _quiet_tree_tty || return 0
  printf '\n'
}

_format_mm_ss() {
  local secs="${1:-0}"
  printf '%02d:%02d' $((secs / 60)) $((secs % 60))
}

# Human-readable duration (e.g. 3m 12s) — reusable reporting helper.
format_duration() {
  _format_duration_secs "${1:-0}"
}

########################################
# Reusable print helpers (quiet tree + log mirror)
########################################

# Quiet TTY: major '=' banners and centered subsection titles share this visible width.
QUIET_TREE_BANNER_WIDTH=60

# Center a plain-ASCII title in QUIET_TREE_BANNER_WIDTH columns with tty_color (NO_COLOR-safe).
quiet_tree_centered_colored_title() {
  local color_key="${1:-}" title="$2" width="${QUIET_TREE_BANNER_WIDTH:-60}" L pad_left pad_right
  L="${#title}"
  if [[ "$L" -ge "$width" ]]; then
    title="${title:0:$((width - 1))}"
    L="${#title}"
  fi
  pad_left=$(( (width - L) / 2 ))
  pad_right=$(( width - L - pad_left ))
  printf '%*s%s%s%s%*s\n' "$pad_left" "" "$(tty_color "$color_key")" "$title" "$(tty_color reset)" "$pad_right" ""
}

print_section() {
  local color_key="${1:-green}" title="$2"
  _quiet_tree_tty || return 0
  QUIET_TREE_SECTION="$title"
  _emit_log_file_ts "[section] ${title}"
  quiet_tree_centered_colored_title "$color_key" "$title"
  printf '\n'
}

# Equals-line banner: fixed width; '=' uses default color, title only uses tty_color (quiet TTY only).
# Title colors: UPDATES/CLEANUP green, CONTAINER UPDATES blue, STACK UPDATES cyan, RUN SUMMARY magenta.
quiet_print_tree_banner_rule() {
  local lab="$1" width="${QUIET_TREE_BANNER_WIDTH:-60}" L pad_left pad_right padL padR ckey="dim"
  _emit_log_file_ts "[banner-rule] ${lab}"
  # Fancy '=' banner only on quiet + interactive stdout; otherwise log a plain section (verbose / cron / pipes).
  if ! _quiet_tree_tty; then
    [[ "$CHECK_ONLY" == "true" ]] && return 0
    log_info "--- ${lab} ---"
    return 0
  fi
  case "$lab" in
    UPDATES | CLEANUP) ckey="green" ;;
    "CONTAINER UPDATES") ckey="blue" ;;
    "STACK UPDATES") ckey="cyan" ;;
    "RUN SUMMARY") ckey="magenta" ;;
    *) ckey="dim" ;;
  esac
  L="${#lab}"
  if [[ "$L" -ge "$width" ]]; then
    lab="${lab:0:$((width - 1))}"
    L="${#lab}"
  fi
  pad_left=$(( (width - L) / 2 ))
  pad_right=$(( width - L - pad_left ))
  padL="$(printf '%*s' "$pad_left" '' | tr ' ' '=')"
  padR="$(printf '%*s' "$pad_right" '' | tr ' ' '=')"
  # Reset so '=' are not dim/colored; wrap title only (NO_COLOR / STACK_UPDATER_COLOR via tty_color).
  printf '%s%s%s%s%s%s\n' "$(tty_color reset)" "$padL" "$(tty_color "$ckey")" "$lab" "$(tty_color reset)" "$padR"
  printf '\n'
}

print_info() {
  local indent="${1:-2}" msg="$2"
  _quiet_tree_tty || return 0
  _emit_log_file_ts "${msg}"
  printf '%*s%s%s%s\n' "$indent" "" "$(tty_color dim)" "${msg}" "$(tty_color reset)"
}

print_success() {
  local indent="${1:-2}" msg="$2"
  _quiet_tree_tty || return 0
  _emit_log_file_ts "[ok] ${msg}"
  printf '%*s%s %s\n' "$indent" "" "$(tty_checkmark)" "${msg}"
}

print_warning() {
  local indent="${1:-2}" msg="$2"
  _quiet_tree_tty || return 0
  _emit_log_file_ts "WARNING: ${msg}"
  if _tty_ansi_ok; then
    printf '%*s%s⚠️ %s%s\n' "$indent" "" "$(tty_color yellow)" "${msg}" "$(tty_color reset)" >&2
  else
    printf '%*sWARNING: %s\n' "$indent" "" "${msg}" >&2
  fi
}

print_error() {
  local indent="${1:-2}" msg="$2"
  _quiet_tree_tty || return 0
  _emit_log_file_ts "ERROR: ${msg}"
  if _tty_ansi_ok; then
    printf '%*s%s❌ %s%s\n' "$indent" "" "$(tty_color red)" "${msg}" "$(tty_color reset)" >&2
  else
    printf '%*sERROR: %s\n' "$indent" "" "${msg}" >&2
  fi
}

# True when quiet + stderr TTY: gates stack_finalize (print_info vs one-line stdout) and finish_progress clear.
# Live stack compare/redeploy lines are not drawn on stderr in quiet mode (see print_progress) — only LOG_FILE.
_stack_progress_live_ok() {
  [[ -t 2 ]] && [[ "${OUTPUT_MODE:-quiet}" == "quiet" ]] && [[ "$CHECK_ONLY" != "true" ]] && [[ "${TERM:-}" != "dumb" ]]
}

stack_progress_live_clear_safe() {
  [[ -t 2 ]] || return 0
  printf '\r\033[K' >&2 2>/dev/null || true
}

print_progress() {
  local msg="$1"
  # Quiet: never draw live stack lines on stdout or stderr. Carriage-return stderr updates interleave
  # badly with quiet-tree result rows on stdout in common terminals (ghost 🔄 lines). Audit via LOG_FILE only.
  if [[ "${OUTPUT_MODE:-quiet}" == "quiet" ]]; then
    _emit_log_file_ts "${msg}"
    return 0
  fi
  if _stack_progress_live_ok; then
    printf '\r\033[K%s' "$msg" >&2 2>/dev/null || true
    return 0
  fi
}

finish_progress() {
  if _stack_progress_live_ok; then
    stack_progress_live_clear_safe
  fi
  return 0
}

_stack_group_display_name() {
  case "${1:-}" in
    dependency) printf '%s' "Dependency stacks" ;;
    dependent) printf '%s' "Dependent stacks" ;;
    heavy) printf '%s' "Heavy stacks" ;;
    remaining) printf '%s' "Remaining stacks" ;;
    *) printf '%s' "${1:-}" ;;
  esac
}

_stack_compare_action_label() {
  if [[ "${CUP_ENABLED:-false}" == "true" ]]; then
    printf '%s' "comparing Cup vs compose"
  else
    printf '%s' "comparing registry vs local images"
  fi
}

_stack_state_glyph_verbose() {
  case "${1:-}" in
    unchanged | unchanged_dry) _leg_icon no_change ;;
    redeployed) _leg_icon update_available ;;
    failed) _leg_icon failed ;;
    dry | dry_run) _leg_icon skipped ;;
    skipped | excluded | skipped_dep) _leg_icon skipped ;;
    *) printf '%s' "•" ;;
  esac
}

stack_run_log_append() {
  local grp="$1" name="$2" state="$3" detail="$4"
  detail="${detail//|/ }"
  STACK_RUN_LOG+=("${STACK_PROGRESS_INDEX}|${STACK_PROGRESS_TOTAL}|${grp}|${name}|${state}|${detail}")
}

# vkey: unchanged | redeployed | failed | excluded | skipped_dep | dry_run
stack_finalize_stack_ui() {
  local grp="$1" name="$2" vkey="$3" detail="${4:-}" human="${5:-}"
  local st_display grp_lab line gl idx tot
  st_display="${human:-}"
  [[ -z "$st_display" ]] && st_display="$(_stack_ui_human_label "$vkey")"
  grp_lab="$(_stack_group_display_name "$grp")"

  finish_progress
  stack_run_log_append "$grp" "$name" "$vkey" "${detail:-}"
  # Verbose per-stack lines are emitted once from print_run_summary (avoids duplicate LOG_FILE rows).

  # Non-interactive / no stderr TTY: one permanent line per stack (no in-place rewrites).
  if ! _stack_progress_live_ok && [[ "${OUTPUT_MODE:-quiet}" == "quiet" ]] && [[ "$CHECK_ONLY" != "true" ]]; then
    idx="$STACK_PROGRESS_INDEX"
    tot="${STACK_PROGRESS_TOTAL:-0}"
    [[ "$tot" -le 0 ]] && tot="?"
    gl="$(_stack_state_glyph_verbose "$vkey")"
    line="${gl} [${idx}/${tot}] ${name} [${grp_lab}] — ${st_display}"
    if [[ "$vkey" == "redeployed" ]]; then
      line="${gl} [${idx}/${tot}] ${name} [${grp_lab}] — updated"
    elif [[ "$vkey" == "dry_run" ]]; then
      line="${gl} [${idx}/${tot}] ${name} [${grp_lab}] — dry-run (planned)"
    elif [[ -n "${detail:-}" ]]; then
      line="${line} (${detail})"
    fi
    _emit_log_file_ts "${line}"
    printf '%s\n' "$line"
    return 0
  fi

  _quiet_tree_tty || return 0
  [[ "${OUTPUT_MODE:-quiet}" != "quiet" ]] && return 0
  case "$vkey" in
    failed) print_error 4 "${name}: redeploy failed${detail:+ (${detail})}" ;;
    redeployed) print_info 4 "$(_leg_icon update_available) ${name}: updated" ;;
    dry_run) print_warning 4 "$(_leg_icon skipped) ${name}: dry-run (planned)" ;;
    unchanged | unchanged_dry) print_info 4 "$(_leg_icon no_change) ${name}" ;;
    excluded | skipped_dep | skipped) print_info 4 "$(_leg_icon skipped) ${name}: skipped" ;;
    *) print_info 4 "$(_leg_icon no_change) ${name}: ${st_display}" ;;
  esac
}

_stack_ui_human_label() {
  case "${1:-}" in
    unchanged) printf '%s' "unchanged" ;;
    redeployed) printf '%s' "redeployed" ;;
    failed) printf '%s' "failed" ;;
    excluded) printf '%s' "skipped" ;;
    skipped_dep) printf '%s' "skipped" ;;
    dry_run) printf '%s' "dry-run planned" ;;
    *) printf '%s' "${1:-unknown}" ;;
  esac
}

_stack_progress_render_line() {
  local grp="$1" name="$2" action="$3"
  local tot gname idx pad line
  idx="${STACK_PROGRESS_INDEX:-0}"
  tot="${STACK_PROGRESS_TOTAL:-0}"
  gname="$(_stack_group_display_name "$grp")"
  if [[ "$tot" -gt 0 ]]; then
    pad="$(printf '%02d' "$idx")/${tot}"
  else
    pad="$(printf '%02d' "$idx")/?"
  fi
  line="$(_leg_icon in_progress) [${pad}] ${name} [${gname}] — ${action}"
  print_progress "${line}"
}

stack_progress_begin_item() {
  local grp="$1" name="$2" action="$3"
  STACK_PROGRESS_INDEX=$((STACK_PROGRESS_INDEX + 1))
  _stack_progress_render_line "$grp" "$name" "$action"
}

stack_progress_action() {
  local grp="$1" name="$2" action="$3"
  [[ "${STACK_PROGRESS_INDEX:-0}" -eq 0 ]] && return 0
  _stack_progress_render_line "$grp" "$name" "$action"
}

compute_stack_deploy_total() {
  local n=0 sn
  for sn in "${DEPENDENCY_STACKS[@]}"; do
    [[ -n "$sn" ]] && n=$((n + 1))
  done
  for sn in "${DEPENDENT_STACKS[@]}"; do
    [[ -n "$sn" ]] && n=$((n + 1))
  done
  for sn in "${HEAVY_STACKS[@]}"; do
    [[ -z "$sn" ]] && continue
    array_contains "$sn" "${DEPENDENCY_STACKS[@]}" && continue
    array_contains "$sn" "${DEPENDENT_STACKS[@]}" && continue
    n=$((n + 1))
  done
  while IFS= read -r sn; do
    [[ -z "$sn" ]] && continue
    array_contains "$sn" "${DEPENDENCY_STACKS[@]}" && continue
    array_contains "$sn" "${DEPENDENT_STACKS[@]}" && continue
    array_contains "$sn" "${HEAVY_STACKS[@]}" && continue
    n=$((n + 1))
  done < <(get_all_stack_names_for_endpoint)
  STACK_PROGRESS_TOTAL=$n
  STACK_PROGRESS_INDEX=0
}

_stack_subgroup_bump() {
  local grp="${1:-}" kind="${2:-}"
  case "${grp}:${kind}" in
    dependency:checked) STACK_GRP_DEP_CHECKED=$((STACK_GRP_DEP_CHECKED + 1)) ;;
    dependency:redeployed) STACK_GRP_DEP_REDEPLOYED=$((STACK_GRP_DEP_REDEPLOYED + 1)) ;;
    dependency:failed) STACK_GRP_DEP_FAILED=$((STACK_GRP_DEP_FAILED + 1)) ;;
    dependent:checked) STACK_GRP_DEPENDENT_CHECKED=$((STACK_GRP_DEPENDENT_CHECKED + 1)) ;;
    dependent:redeployed) STACK_GRP_DEPENDENT_REDEPLOYED=$((STACK_GRP_DEPENDENT_REDEPLOYED + 1)) ;;
    dependent:failed) STACK_GRP_DEPENDENT_FAILED=$((STACK_GRP_DEPENDENT_FAILED + 1)) ;;
    heavy:checked) STACK_GRP_HEAVY_CHECKED=$((STACK_GRP_HEAVY_CHECKED + 1)) ;;
    heavy:redeployed) STACK_GRP_HEAVY_REDEPLOYED=$((STACK_GRP_HEAVY_REDEPLOYED + 1)) ;;
    heavy:failed) STACK_GRP_HEAVY_FAILED=$((STACK_GRP_HEAVY_FAILED + 1)) ;;
    remaining:checked) STACK_GRP_REMAINING_CHECKED=$((STACK_GRP_REMAINING_CHECKED + 1)) ;;
    remaining:redeployed) STACK_GRP_REMAINING_REDEPLOYED=$((STACK_GRP_REMAINING_REDEPLOYED + 1)) ;;
    remaining:failed) STACK_GRP_REMAINING_FAILED=$((STACK_GRP_REMAINING_FAILED + 1)) ;;
  esac
}

_endpoint_display_hint() {
  local hint=""
  case "${PORTAINER_URL:-}" in
    *"127.0.0.1"* | *"localhost"*) hint=" (local)" ;;
  esac
  printf '%s%s' "${ENDPOINT_ID:-?}" "$hint"
}

quiet_print_target_block() {
  local hn stack_n dock_n
  _quiet_tree_tty || return 0
  hn="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo 'unknown')"
  stack_n="$(get_all_stack_names_for_endpoint | grep -c . 2>/dev/null || echo 0)"
  stack_n="$(echo "$stack_n" | tr -d ' \t\n')"
  dock_n="$(docker_running_container_count 2>/dev/null || echo "?")"
  dock_n="${dock_n//[^0-9]/}"
  [[ -z "$dock_n" ]] && dock_n="?"
  ui_section_heading green "Target"
  ui_indent_kv 2 "Host" "$hn"
  ui_indent_kv 2 "Portainer" "reachable"
  ui_indent_kv 2 "Endpoint" "$(_endpoint_display_hint)"
  ui_indent_kv 2 "Stacks found" "${stack_n}"
  ui_indent_kv 2 "Docker containers (running)" "${dock_n}"
  printf '\n'
}

quiet_print_system_status_block() {
  local hp_lab dk_lab dv cv
  [[ "${FULL_UI_PIPELINE:-}" == "true" ]] || return 0
  _quiet_tree_tty || return 0
  hp_lab=$(_system_phase_plain_label host "${SUMMARY_PHASE_HOST}")
  dk_lab=$(_system_phase_plain_label docker_pkgs "${SUMMARY_PHASE_DOCKER_PKGS}")
  if [[ -z "${DOCKER_VER_DISPLAY:-}" ]]; then
    DOCKER_VER_DISPLAY="$(docker --version 2>/dev/null || echo '')"
    COMPOSE_VER_DISPLAY="$(docker compose version 2>/dev/null || echo '')"
  fi
  dv="${DOCKER_VER_DISPLAY#Docker version }"
  cv="${COMPOSE_VER_DISPLAY#Docker Compose version }"
  ui_section_heading green "System"
  ui_indent_kv 2 "$(tty_checkmark) Host packages" "${hp_lab}"
  if [[ -n "${DOCKER_VER_DISPLAY:-}" ]]; then
    ui_indent_kv 2 "$(tty_checkmark) Docker" "${dv%%,*}"
    ui_indent_kv 2 "$(tty_checkmark) Docker Compose" "${cv}"
  else
    ui_indent_kv 2 "Docker" "(see above / disabled)"
    ui_indent_kv 2 "Docker Compose" "(see above / disabled)"
  fi
  ui_indent_kv 2 "$(tty_checkmark) Docker-related apt packages" "${dk_lab}"
  printf '\n'
}

_system_phase_plain_label() {
  local phase="$1" val="$2"
  case "$val" in
    disabled) echo "disabled" ;;
    skipped_no_updates) echo "skipped (nothing to upgrade)" ;;
    dry-run) echo "dry-run" ;;
    ran | completed) echo "checked" ;;
    *) echo "${val}" ;;
  esac
}

quiet_print_update_strategy_block() {
  _quiet_tree_tty || return 0
  ui_blank
  ui_section_heading yellow "Update strategy"
  if [[ "${SELECTIVE_STACK_REDEPLOY:-false}" == "true" ]]; then
    ui_indent_kv 2 "Mode" "selective redeploy"
    if [[ "${CUP_ENABLED:-false}" == "true" ]]; then
      ui_indent_kv 2 "Compare" "Cup results vs compose images"
    else
      ui_indent_kv 2 "Compare" "registry digest vs local images"
    fi
  else
    ui_indent_kv 2 "Mode" "full redeploy (all stacks on endpoint)"
    ui_indent_kv 2 "Compare" "(not selective)"
  fi
  printf '\n'
}

quiet_print_stack_subgroup_metrics_block() {
  # Log-only subgroup counters (verbose: mirror to log; quiet TTY skips extra blank line here).
  if [[ "${OUTPUT_MODE:-quiet}" == "verbose" ]]; then
    ui_mirror_line "[stack-metrics] dependency checked=${STACK_GRP_DEP_CHECKED} redeployed=${STACK_GRP_DEP_REDEPLOYED} failed=${STACK_GRP_DEP_FAILED}"
    ui_mirror_line "[stack-metrics] dependent checked=${STACK_GRP_DEPENDENT_CHECKED} redeployed=${STACK_GRP_DEPENDENT_REDEPLOYED} failed=${STACK_GRP_DEPENDENT_FAILED}"
    ui_mirror_line "[stack-metrics] heavy checked=${STACK_GRP_HEAVY_CHECKED} redeployed=${STACK_GRP_HEAVY_REDEPLOYED} failed=${STACK_GRP_HEAVY_FAILED}"
    ui_mirror_line "[stack-metrics] remaining checked=${STACK_GRP_REMAINING_CHECKED} redeployed=${STACK_GRP_REMAINING_REDEPLOYED} failed=${STACK_GRP_REMAINING_FAILED}"
  else
    _emit_log_file_ts "[stack-metrics] dependency checked=${STACK_GRP_DEP_CHECKED} redeployed=${STACK_GRP_DEP_REDEPLOYED} failed=${STACK_GRP_DEP_FAILED}"
    _emit_log_file_ts "[stack-metrics] dependent checked=${STACK_GRP_DEPENDENT_CHECKED} redeployed=${STACK_GRP_DEPENDENT_REDEPLOYED} failed=${STACK_GRP_DEPENDENT_FAILED}"
    _emit_log_file_ts "[stack-metrics] heavy checked=${STACK_GRP_HEAVY_CHECKED} redeployed=${STACK_GRP_HEAVY_REDEPLOYED} failed=${STACK_GRP_HEAVY_FAILED}"
    _emit_log_file_ts "[stack-metrics] remaining checked=${STACK_GRP_REMAINING_CHECKED} redeployed=${STACK_GRP_REMAINING_REDEPLOYED} failed=${STACK_GRP_REMAINING_FAILED}"
  fi
  # Do not use `cmd && [[ ... ]] && printf` as the final statement: under `set -e`, a failed `[[` in quiet mode
  # makes this function return 1 and aborts the whole pipeline after stacks (before CLEANUP / RUN SUMMARY).
  if _quiet_tree_tty && [[ "${OUTPUT_MODE:-quiet}" == "verbose" ]]; then
    printf '\n'
  fi
}

quiet_print_cleanup_line() {
  local lab="$1"
  if ! _quiet_tree_tty; then
    log_info "${lab}"
    return 0
  fi
  # CLEANUP banner is printed before this line when cleanup is skipped.
  quiet_item_line 2 "${lab}"
}

# Compact subgroup totals on quiet TTY only when something redeployed or failed.
quiet_stack_group_summary() {
  local label="$1" checked="$2" redeployed="$3" failed="$4" line
  checked="$(_cup_sanitize_count "${checked:-0}")"
  redeployed="$(_cup_sanitize_count "${redeployed:-0}")"
  failed="$(_cup_sanitize_count "${failed:-0}")"
  [[ "$redeployed" =~ ^[0-9]+$ ]] && [[ "$failed" =~ ^[0-9]+$ ]] || return 0
  [[ "$((redeployed + failed))" -gt 0 ]] || return 0
  line="${label}: checked ${checked}, redeployed ${redeployed}, failed ${failed}"
  if [[ "${OUTPUT_MODE:-quiet}" == "verbose" ]]; then
    log_info "$line"
  else
    _emit_log_file_ts "$line"
  fi
}

# After cleanup_docker: dim lines from captured prune output (requires CLEANUP_* set by cleanup_docker).
# Same text on quiet TTY (checklist) or via log_info when verbose / non-TTY so cleanup is never "silent".
quiet_print_cleanup_summary() {
  if ! _quiet_tree_tty; then
    case "${SUMMARY_PHASE_CLEANUP:-}" in
      dry-run)
        log_info "Docker cleanup (dry run; prunes not executed)"
        log_info "$(_leg_icon skipped) Would run: docker image prune -af; docker network prune -f; docker volume prune -f — each when enabled in config."
        ;;
      failed)
        log_info "Docker cleanup finished with errors (see log)"
        log_info "$(_leg_icon failed) Prune output may be incomplete; check ${LOG_FILE}."
        ;;
      *)
        log_info "Docker cleanup completed"
        if [[ "${PRUNE_UNUSED_IMAGES:-false}" == "true" ]]; then
          if [[ -n "${CLEANUP_IMAGE_SUMMARY:-}" ]] && [[ "${CLEANUP_IMAGE_SUMMARY}" == *"Total reclaimed"* ]]; then
            log_info "$(_leg_icon cleaned) ${CLEANUP_IMAGE_SUMMARY}"
          else
            log_info "$(_leg_icon cleaned) Image prune completed"
          fi
        else
          log_info "$(_leg_icon no_change) Image prune: disabled"
        fi
        if [[ "${PRUNE_UNUSED_NETWORKS:-true}" == "true" ]]; then
          if [[ "${CLEANUP_NETWORK_SUMMARY:-}" == "__NO_CHANGE__" ]]; then
            log_info "$(_leg_icon no_change) No unused networks to prune"
          elif [[ -n "${CLEANUP_NETWORK_SUMMARY:-}" ]]; then
            log_info "$(_leg_icon cleaned) ${CLEANUP_NETWORK_SUMMARY}"
          else
            log_info "$(_leg_icon cleaned) Network prune completed"
          fi
        else
          log_info "$(_leg_icon no_change) Network prune: disabled"
        fi
        if [[ "${PRUNE_UNUSED_VOLUMES:-false}" == "true" ]]; then
          if [[ "${CLEANUP_VOLUME_SUMMARY:-}" == "__NO_CHANGE__" ]]; then
            log_info "$(_leg_icon no_change) No unused volumes to prune"
          elif [[ -n "${CLEANUP_VOLUME_SUMMARY:-}" ]]; then
            log_info "$(_leg_icon cleaned) ${CLEANUP_VOLUME_SUMMARY}"
          else
            log_info "$(_leg_icon cleaned) Volume prune completed"
          fi
        else
          log_info "$(_leg_icon no_change) Volume prune: disabled"
        fi
        ;;
    esac
    return 0
  fi
  if [[ "${SUMMARY_PHASE_CLEANUP:-}" == "dry-run" ]]; then
    quiet_item_line 2 "Docker cleanup (dry run; prunes not executed)"
    print_info 4 "$(_leg_icon skipped) Would run: docker image prune -af; docker network prune -f; docker volume prune -f — each when enabled in config."
    return 0
  fi
  if [[ "${SUMMARY_PHASE_CLEANUP:-}" == "failed" ]]; then
    quiet_item_line 2 "Docker cleanup finished with errors (see log)"
    print_info 4 "$(_leg_icon failed) Prune output may be incomplete; check ${LOG_FILE}."
    return 0
  fi
  quiet_item_line 2 "Docker cleanup completed"
  if [[ "${PRUNE_UNUSED_IMAGES:-false}" == "true" ]]; then
    if [[ -n "${CLEANUP_IMAGE_SUMMARY:-}" ]] && [[ "${CLEANUP_IMAGE_SUMMARY}" == *"Total reclaimed"* ]]; then
      print_info 4 "$(_leg_icon cleaned) ${CLEANUP_IMAGE_SUMMARY}"
    else
      print_info 4 "$(_leg_icon cleaned) Image prune completed"
    fi
  else
    print_info 4 "$(_leg_icon no_change) Image prune: disabled"
  fi
  if [[ "${PRUNE_UNUSED_NETWORKS:-true}" == "true" ]]; then
    if [[ "${CLEANUP_NETWORK_SUMMARY:-}" == "__NO_CHANGE__" ]]; then
      print_info 4 "$(_leg_icon no_change) No unused networks to prune"
    elif [[ -n "${CLEANUP_NETWORK_SUMMARY:-}" ]]; then
      print_info 4 "$(_leg_icon cleaned) ${CLEANUP_NETWORK_SUMMARY}"
    else
      print_info 4 "$(_leg_icon cleaned) Network prune completed"
    fi
  else
    print_info 4 "$(_leg_icon no_change) Network prune: disabled"
  fi
  if [[ "${PRUNE_UNUSED_VOLUMES:-false}" == "true" ]]; then
    if [[ "${CLEANUP_VOLUME_SUMMARY:-}" == "__NO_CHANGE__" ]]; then
      print_info 4 "$(_leg_icon no_change) No unused volumes to prune"
    elif [[ -n "${CLEANUP_VOLUME_SUMMARY:-}" ]]; then
      print_info 4 "$(_leg_icon cleaned) ${CLEANUP_VOLUME_SUMMARY}"
    else
      print_info 4 "$(_leg_icon cleaned) Volume prune completed"
    fi
  else
    print_info 4 "$(_leg_icon no_change) Volume prune: disabled"
  fi
}

# Dedupe colored section headers when the same logical section repeats (e.g. host then docker_pkgs).
QUIET_TREE_SECTION=""

quiet_ensure_section() {
  local color_key="$1" title="$2"
  _quiet_tree_tty || return 0
  [[ "${QUIET_TREE_SECTION:-}" == "$title" ]] && return 0
  QUIET_TREE_SECTION="$title"
  quiet_section_title "$color_key" "$title"
}

# Colored section header (quiet + TTY), centered in QUIET_TREE_BANNER_WIDTH.
quiet_section_title() {
  local color_key="${1:-}" title="$2"
  _quiet_tree_tty || return 0
  _emit_log_file_ts "[section] ${title}"
  quiet_tree_centered_colored_title "$color_key" "$title"
  printf '\n'
}

# Dim one-off status after Portainer checklist, before cache/API refresh (quiet + TTY).
quiet_activity_line() {
  _quiet_tree_tty || return 0
  _emit_log_file_ts "[activity] $*"
  printf '%s%s%s\n' "$(tty_color dim)" "$*" "$(tty_color reset)"
}

# Indented checklist row with green checkmark (quiet + TTY). Args: indent_spaces label...
quiet_item_line() {
  local indent="${1:-2}"
  shift
  local label="$*"
  _quiet_tree_tty || return 0
  _emit_log_file_ts "[done] ${label}"
  printf '%*s%s %s\n' "$indent" "" "$(tty_checkmark)" "$label"
}

# Dim sub-note under Stacks (selective mode, all-stacks mode, Cup skip notice).
quiet_subnote_dim() {
  _quiet_tree_tty || return 0
  _emit_log_file_ts "[note] $*"
  printf '  %s%s%s\n' "$(tty_color dim)" "$*" "$(tty_color reset)"
}

# Subgroup heading under Stacks (dependency / dependent / heavy / remaining).
quiet_stack_subgroup_title() {
  _quiet_tree_tty || return 0
  _emit_log_file_ts "[subgroup] $*"
  printf '  %s▸ %s%s\n' "$(tty_color cyan)" "$*" "$(tty_color reset)"
  printf '\n'
}

# ASCII box with title centered between side borders (inner width = outer_width - 2).
# Whole box is padded to align with QUIET_TREE_BANNER_WIDTH (same band as '=' banners).
quiet_print_ascii_title_box() {
  local title="${1:-Stack-Updater}" outer_width="${2:-31}" band="${QUIET_TREE_BANNER_WIDTH:-60}" inner_width pl pr L lpad
  inner_width=$((outer_width - 2))
  L="${#title}"
  if [[ "$L" -gt "$inner_width" ]]; then
    title="${title:0:$inner_width}"
    L="${#title}"
  fi
  pl=$(( (inner_width - L) / 2 ))
  pr=$((inner_width - L - pl))
  lpad=$(( (band - outer_width) / 2 ))
  [[ "$lpad" -lt 0 ]] && lpad=0
  printf '%*s+%s+\n' "$lpad" "" "$(printf '%*s' "$inner_width" '' | tr ' ' '-')"
  printf '%*s|%*s%s%*s|\n' "$lpad" "" "$pl" "" "$title" "$pr" ""
  printf '%*s+%s+\n' "$lpad" "" "$(printf '%*s' "$inner_width" '' | tr ' ' '-')"
}

# Figlet-style title once per pipeline (quiet + TTY); ASCII fallback if figlet missing.
quiet_print_title_banner() {
  _quiet_tree_tty || return 0
  _emit_log_file_ts "[banner] Stack-Updater"
  if command -v figlet >/dev/null 2>&1; then
    figlet -t "Stack-Updater" 2>/dev/null || figlet "Stack-Updater" 2>/dev/null || true
  else
    quiet_print_ascii_title_box "Stack-Updater" 31
  fi
  printf '\n'
  quiet_print_tree_banner_rule "UPDATES"
  _print_cup_legend_tty_compact
  QUIET_TREE_LEGEND_DONE="true"
  printf '\n'
}

# Legacy hook: stack outcomes are handled by stack_finalize_stack_ui.
quiet_stack_item_done() {
  _emit_log_file_ts "[stack] ${1} | ${2} | ${3}"
}

########################################
# LOGGING
# - OUTPUT_MODE: quiet | verbose (see README). Legacy standard → quiet.
# - LOG_FILE: always timestamped lines.
# - Quiet + TTY: user-facing lines omit leading timestamp on stdout (CHECK_ONLY keeps timestamps).
# - log_verbose: verbose, or always during --check-only (full report).
# - log_detail: verbose only.
# - progress_parent_done: quiet TTY checklist (timestamp only in LOG_FILE).
# - progress_child: verbose only ([..] lines).
########################################

_emit_log_file_ts() {
  local ts msg
  ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'NO-DATE')"
  msg="[ ${ts} ] $*"
  echo "$msg" >>"$LOG_FILE" 2>/dev/null || true
}

_emit_log_tty() {
  local ts msg full plain
  ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'NO-DATE')"
  full="[ ${ts} ] $*"
  plain="$*"

  if [[ ! -t 1 ]] || [[ "${TERM:-}" == "dumb" ]]; then
    echo "$full"
    return
  fi
  if [[ "${OUTPUT_MODE:-quiet}" == "quiet" ]] && [[ "$CHECK_ONLY" != "true" ]]; then
    echo "$plain"
  else
    echo "$full"
  fi
}

_emit_log() {
  _emit_log_file_ts "$*"
  _emit_log_tty "$*"
}

_emit_log_file_only() {
  _emit_log_file_ts "$*"
}

# Clear quiet_live stderr line (idempotent; safe from EXIT trap).
quiet_live_clear_safe() {
  [[ -t 2 ]] || return 0
  [[ "${OUTPUT_MODE:-quiet}" != "quiet" ]] && return 0
  [[ "$CHECK_ONLY" == "true" ]] && return 0
  printf '\r\033[K' >&2 2>/dev/null || true
}

quiet_live_clear() {
  quiet_live_clear_safe
}

# Single-line status on stderr (TTY + quiet). Not written to LOG_FILE.
quiet_live() {
  [[ -t 2 ]] || return 0
  [[ "${OUTPUT_MODE:-quiet}" != "quiet" ]] && return 0
  [[ "$CHECK_ONLY" == "true" ]] && return 0
  printf '\r\033[K%s' "$*" >&2 2>/dev/null || true
}

trap 'quiet_live_clear_safe; stack_progress_live_clear_safe' EXIT

log_step() {
  if [[ "${OUTPUT_MODE:-quiet}" == "quiet" ]] && [[ -t 1 ]] && [[ "$CHECK_ONLY" != "true" ]]; then
    _emit_log_file_ts "[step] $*"
    return 0
  fi
  _emit_log "[step] $*"
}

log_info() {
  _emit_log "$*"
}

log_verbose() {
  [[ "$CHECK_ONLY" == "true" ]] || [[ "${OUTPUT_MODE:-quiet}" == "verbose" ]] || return 0
  _emit_log "$*"
}

log_detail() {
  [[ "${OUTPUT_MODE:-quiet}" == "verbose" ]] || return 0
  _emit_log "$*"
}

progress_parent_done() {
  [[ -t 1 ]] || return 0
  [[ "${OUTPUT_MODE:-quiet}" != "quiet" ]] && return 0
  [[ "$CHECK_ONLY" == "true" ]] && return 0
  _emit_log_file_ts "[done] $*"
  printf '%s %s\n' "$(tty_checkmark)" "$*"
}

progress_child() {
  [[ "$CHECK_ONLY" == "true" ]] && return 0
  [[ "${OUTPUT_MODE:-quiet}" == "verbose" ]] || return 0
  _emit_log "[..] $*"
}

quiet_checklist_done() {
  progress_parent_done "$@"
}

log_warn() {
  RUN_WARNING_COUNT=$((RUN_WARNING_COUNT + 1))
  _emit_log_file_ts "WARNING: $*"
  if _tty_ansi_ok && [[ "${OUTPUT_MODE:-quiet}" == "quiet" ]] && [[ "$CHECK_ONLY" != "true" ]]; then
    printf '%sWARNING:%s %s\n' "$(tty_color yellow)" "$(tty_color reset)" "$*" >&2
    return 0
  fi
  _emit_log_tty "WARNING: $*"
}

log() {
  log_detail "$@"
}

mark_pipeline_hard_failure() {
  PIPELINE_HARD_FAILURE=1
}

user_cancel_exit() {
  USER_CANCELLED="true"
  _emit_log_file_ts "Run cancelled by user."
  exit 130
}

_mktemp_track() {
  local f
  f="$(mktemp)"
  _TEMP_FILES+=("$f")
  printf '%s' "$f"
}

_temp_cleanup() {
  local f
  for f in "${_TEMP_FILES[@]}"; do
    rm -f "$f" 2>/dev/null || true
  done
  _TEMP_FILES=()
}

release_run_lock() {
  [[ "$RUN_LOCK_ACQUIRED" != "true" ]] && return 0
  flock -u "$LOCK_FD" 2>/dev/null || true
  RUN_LOCK_ACQUIRED="false"
}

acquire_run_lock() {
  [[ "${SKIP_RUN_LOCK:-false}" == "true" ]] && return 0
  [[ "${SELF_TEST:-false}" == "true" ]] && return 0
  [[ "$RUN_LOCK_ACQUIRED" == "true" ]] && return 0
  LOCK_FILE="${LOCK_FILE:-$SCRIPT_DIR/.stack-updater.lock}"
  eval "exec ${LOCK_FD}>\"${LOCK_FILE}\""
  if ! flock -n "$LOCK_FD"; then
    echo "ERROR: Another stack-updater run is in progress (lock: ${LOCK_FILE})." >&2
    exit 75
  fi
  RUN_LOCK_ACQUIRED="true"
}

_stack_updater_on_exit() {
  _temp_cleanup
  release_run_lock
}

_stack_updater_on_signal() {
  _emit_log_file_ts "Received signal; exiting."
  exit 130
}

_err_trap() {
  local ec=$? line cmd
  line="${BASH_LINENO[0]:-?}"
  cmd="${BASH_COMMAND:-?}"
  _emit_log_file_ts "ERR trap: exit=${ec} line=${line} cmd=${cmd}"
}

rotate_log_if_needed() {
  local maxb="${LOG_MAX_BYTES:-0}" sz
  [[ "$maxb" -gt 0 ]] || return 0
  [[ -f "${LOG_FILE:-}" ]] || return 0
  sz="$(wc -c <"${LOG_FILE}" 2>/dev/null | tr -d ' ')" || return 0
  [[ "${sz:-0}" -gt "$maxb" ]] || return 0
  mv -f "${LOG_FILE}" "${LOG_FILE}.1" 2>/dev/null || true
  : >"${LOG_FILE}" 2>/dev/null || true
}

fail() {
  mark_pipeline_hard_failure
  _emit_log_file_ts "ERROR: $*"
  if _tty_ansi_ok && [[ "${OUTPUT_MODE:-quiet}" == "quiet" ]] && [[ "$CHECK_ONLY" != "true" ]]; then
    printf '%sERROR:%s %s\n' "$(tty_color red)" "$(tty_color reset)" "$*" >&2
  else
    _emit_log_tty "ERROR: $*"
  fi
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

run_apt_get() {
  local tmp ec line
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  if [[ "${OUTPUT_MODE:-quiet}" == "verbose" ]]; then
    apt-get "$@" || return $?
    return 0
  fi
  tmp="$(mktemp)"
  if apt-get "$@" >>"$tmp" 2>&1; then
    rm -f "$tmp"
    return 0
  fi
  ec=$?
  log_warn "apt-get $* failed (exit ${ec}); last lines:"
  while IFS= read -r line || [[ -n "$line" ]]; do
    _emit_log "$line"
  done < <(tail -40 "$tmp")
  rm -f "$tmp"
  return "$ec"
}

# Prefer nala for update/upgrade/autoremove when installed. Simulations stay on apt-get -s.
# Nala's `update` subcommand does not accept -y/--assume-yes (upstream); `install --only-upgrade`
# is not a reliable nala CLI mirror, so docker-only upgrades use apt-get even when nala exists.
run_pkg_mgr() {
  if [[ "$1" == "install" ]] && [[ " $* " == *" --only-upgrade "* ]]; then
    run_apt_get "$@"
    return $?
  fi
  if command -v nala >/dev/null 2>&1; then
    run_nala "$@"
  else
    run_apt_get "$@"
  fi
}

run_nala() {
  local tmp ec line
  local -a cmd=()
  local nf=(env DEBIAN_FRONTEND=noninteractive)

  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  case "$1" in
    # `nala update` only supports a small option set — no assume-yes on this subcommand.
    update) cmd=("${nf[@]}" nala update) ;;
    # Match split apt-get: refresh already done; keep autoremove as a separate step.
    upgrade) cmd=("${nf[@]}" nala upgrade -y --no-update --no-autoremove) ;;
    autoremove) cmd=("${nf[@]}" nala autoremove -y) ;;
    install) cmd=("${nf[@]}" nala "$@") ;;
    *) cmd=("${nf[@]}" nala "$@") ;;
  esac

  if [[ "${OUTPUT_MODE:-quiet}" == "verbose" ]]; then
    "${cmd[@]}" || return $?
    return 0
  fi
  tmp="$(mktemp)"
  if "${cmd[@]}" >>"$tmp" 2>&1; then
    rm -f "$tmp"
    return 0
  fi
  ec=$?
  _emit_log_file_ts "nala failed (exit ${ec}); falling back to apt-get. Last lines:"
  while IFS= read -r line || [[ -n "$line" ]]; do
    _emit_log_file_only "$line"
  done < <(tail -40 "$tmp")
  rm -f "$tmp"
  return "$ec"
}

run_docker() {
  local tmp ec line
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  if [[ "${OUTPUT_MODE:-quiet}" == "verbose" ]]; then
    docker "$@" || return $?
    return 0
  fi
  if [[ "${1:-}" == "pull" ]]; then
    quiet_live "docker pull ${2:-}…"
  fi
  tmp="$(mktemp)"
  if docker "$@" >>"$tmp" 2>&1; then
    [[ "${1:-}" == "pull" ]] && quiet_live_clear
    rm -f "$tmp"
    return 0
  fi
  ec=$?
  [[ "${1:-}" == "pull" ]] && quiet_live_clear
  log_warn "docker $* failed (exit ${ec}); last lines:"
  while IFS= read -r line || [[ -n "$line" ]]; do
    _emit_log "$line"
  done < <(tail -40 "$tmp")
  rm -f "$tmp"
  return "$ec"
}

confirm_step() {
  [[ "${CONFIRM_EACH_STEP:-false}" != "true" ]] && return 0
  [[ "$AUTO_YES" == "true" ]] && return 0
  if [[ ! -t 0 ]]; then
    log_warn "CONFIRM_EACH_STEP ignored (non-TTY); continuing."
    return 0
  fi
  local msg="$1"
  if command -v gum >/dev/null 2>&1; then
    gum confirm --default=false "$msg" || user_cancel_exit
    return 0
  fi
  local ans
  read -r -p "$msg [y/N] " ans || user_cancel_exit
  case "${ans,,}" in
    y | yes) return 0 ;;
    *) user_cancel_exit ;;
  esac
}

########################################
# BASIC HELPERS
########################################

array_contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

is_excluded_stack() {
  local name="$1"
  array_contains "$name" "${EXCLUDED_STACKS[@]}"
}

########################################
# Portainer — quiet-tree section (headings + substeps; no API behavior change)
########################################

portainer_quiet_ui_open() {
  _quiet_tree_tty || return 0
  print_section blue "Portainer"
}

# Verbose-only: registry/local digest diagnostic (not used for recreate decisions).
portainer_log_digest_diagnostics_verbose() {
  [[ "${UPDATE_PORTAINER_CONTAINER:-}" != "true" ]] && return 0
  [[ "${OUTPUT_MODE:-quiet}" != "verbose" ]] && return 0
  portainer_compute_digest_status
  _PORTAINER_VER_SERVER="$(portainer_api_server_version)"
  [[ -z "${_PORTAINER_VER_SERVER}" ]] && _PORTAINER_VER_SERVER="$(portainer_image_label_version)"
  log_verbose "Portainer digest (diagnostic only): stat=${_PORTAINER_DIGEST_STAT:-unknown} server=${_PORTAINER_VER_SERVER:-} registry_label=${_PORTAINER_REG_VERSION:-}"
}

portainer_backup_gate_before_recreate() {
  [[ "${PORTAINER_REQUIRE_BACKUP_BEFORE_UPDATE:-false}" != "true" ]] && return 0
  if [[ ! -t 0 ]] || [[ "$AUTO_YES" == "true" ]]; then
    [[ "${PORTAINER_BACKUP_ACKNOWLEDGED:-0}" == "1" ]] && return 0
    return 1
  fi
  local ans
  read -r -p "Have you taken a Portainer backup? [y/N] " ans || return 1
  case "${ans,,}" in y | yes) return 0 ;; *) return 1 ;; esac
}

portainer_warn_if_losing_legacy_http_port() {
  [[ "${PORTAINER_ENABLE_LEGACY_HTTP_PORT:-false}" == "true" ]] && return 0
  docker inspect "$PORTAINER_CONTAINER_NAME" >/dev/null 2>&1 || return 0
  local jb
  jb="$(docker inspect --format '{{json .HostConfig.PortBindings}}' "$PORTAINER_CONTAINER_NAME" 2>/dev/null || echo '{}')"
  echo "$jb" | grep -q '"9000/tcp"' || return 0
  print_warning 2 "Current Portainer publishes TCP 9000; the new container will not unless PORTAINER_ENABLE_LEGACY_HTTP_PORT=true (see config.env.example)."
}

portainer_warn_if_agent_present() {
  _quiet_tree_tty || return 0
  local names
  names="$(docker ps -a --format '{{.Names}}' 2>/dev/null || true)"
  echo "$names" | grep -Eiq 'portainer_agent|portainer-agent|portaineragent' || return 0
  print_warning 2 "Portainer recommends matching Agent version to Server version; this script does not upgrade agents."
}

portainer_quiet_ui_post_update() {
  case "${SUMMARY_PHASE_PORTAINER:-}" in
    skipped_image_current_cup)
      _emit_log_file_ts "$(_leg_icon up_to_date) Portainer image: up-to-date according to Cup (Cup pre-check)"
      ;;
  esac
  _quiet_tree_tty || return 0
  case "${SUMMARY_PHASE_PORTAINER:-}" in
    disabled) print_info 2 "$(_leg_icon skipped) Portainer container update disabled in config" ;;
    dry-run) print_info 2 "$(_leg_icon skipped) Portainer container dry-run; no changes applied" ;;
    skipped_image_current)
      print_info 2 "$(_leg_icon up_to_date) Portainer image: up-to-date"
      print_info 2 "$(_leg_icon up_to_date) Portainer container unchanged (image current)"
      ;;
    skipped_image_current_cup)
      print_info 2 "$(_leg_icon up_to_date) Portainer image: up-to-date"
      print_info 2 "$(_leg_icon no_change) Portainer container unchanged"
      ;;
    skipped_pull_failed)
      print_warning 2 "Portainer image check failed; keeping existing container"
      print_info 4 "   See log for details."
      print_info 2 "$(_leg_icon no_change) Portainer container unchanged"
      ;;
    skipped_backup_required)
      print_warning 2 "Portainer recreate skipped: backup not confirmed (set PORTAINER_BACKUP_ACKNOWLEDGED=1 for non-interactive, or answer y at prompt)."
      print_info 2 "$(_leg_icon up_to_date) Portainer container unchanged"
      ;;
    ran) print_success 2 "Portainer container recreated" ;;
    *) print_info 2 "Portainer container step finished (${SUMMARY_PHASE_PORTAINER:-ok})" ;;
  esac
}

portainer_quiet_ui_container_begin() {
  _quiet_tree_tty || return 0
  print_info 2 "$(_leg_icon in_progress) Refreshing Portainer container…"
}

portainer_quiet_ui_container_outcome() {
  portainer_quiet_ui_post_update
}

# After container step: invalidate, ping API, refresh catalog. Pass any non-empty first arg
# to suppress refresh_stacks_cache's quiet_live line (section already printed the substep).
portainer_quiet_ui_api_validate_and_refresh_cache() {
  local no_cat_live="${1:-}"
  if _quiet_tree_tty; then
    print_info 2 "$(_leg_icon in_progress) Re-validating Portainer API…"
  fi
  invalidate_stacks_cache
  check_requirements
  if _quiet_tree_tty; then
    print_info 2 "$(_leg_icon in_progress) Refreshing stack cache…"
  fi
  refresh_stacks_cache "${no_cat_live}"
  if _quiet_tree_tty; then
    print_info 2 "$(tty_checkmark) Portainer ready"
  fi
  return 0
}

invalidate_stacks_cache() {
  STACKS_JSON_CACHE=""
  progress_child "Invalidate stack catalog cache"
}

# Optional first arg: non-empty → skip quiet_live catalog line (used inside Portainer UI block).
refresh_stacks_cache() {
  local fetched ec=0 skip_live="${1:-}"
  if [[ -z "$skip_live" ]] && _quiet_tree_tty; then
    quiet_live "Refreshing Portainer stack catalog…"
  fi
  fetched="$(api_get "/api/stacks")" || ec=$?
  quiet_live_clear_safe
  [[ "$ec" -eq 0 ]] || return "$ec"
  STACKS_JSON_CACHE="$fetched"
  progress_child "Refresh stack catalog (Portainer)"
  return 0
}

api_get() {
  local path="$1"
  curl "${CURL_OPTS[@]}" \
    -H "${AUTH_HEADER[0]}" \
    "${PORTAINER_URL}${path}"
}

api_put_json() {
  local path="$1"
  local json_file="$2"
  curl "${CURL_OPTS[@]}" \
    -X PUT \
    -H "${AUTH_HEADER[0]}" \
    -H "Content-Type: application/json" \
    --data @"$json_file" \
    "${PORTAINER_URL}${path}"
}

########################################
# STACK DISCOVERY (cached)
########################################

get_all_stacks() {
  if [[ -z "$STACKS_JSON_CACHE" ]]; then
    refresh_stacks_cache
  fi
  printf '%s' "$STACKS_JSON_CACHE"
}

get_stack_id_by_name() {
  local stack_name="$1"
  local blob count
  blob="$(get_all_stacks)"
  count="$(echo "$blob" | jq -r --arg name "$stack_name" --argjson eid "$ENDPOINT_ID" '
    map(select(.Name == $name and .EndpointId == $eid)) | length
  ')"

  if [[ "$count" -gt 1 ]]; then
    fail "Multiple stacks named '$stack_name' found on endpoint $ENDPOINT_ID. Refusing to continue."
  fi

  if [[ "$count" -eq 0 ]]; then
    echo ""
    return 0
  fi

  echo "$blob" | jq -r --arg name "$stack_name" --argjson eid "$ENDPOINT_ID" '
    map(select(.Name == $name and .EndpointId == $eid)) | first | .Id
  '
}

get_stack_json_by_id() {
  local stack_id="$1"
  echo "$(get_all_stacks)" | jq -c --argjson sid "$stack_id" '
    map(select(.Id == $sid)) | first
  '
}

get_all_stack_names_for_endpoint() {
  echo "$(get_all_stacks)" | jq -r --argjson eid "$ENDPOINT_ID" '
    map(select(.EndpointId == $eid)) | .[].Name
  ' | sort
}

get_stack_file_content() {
  local stack_id="$1"
  api_get "/api/stacks/${stack_id}/file" | jq -r '.StackFileContent'
}

is_git_stack() {
  local stack_json="$1"
  echo "$stack_json" | jq -e '.GitConfig != null' >/dev/null 2>&1
}

build_env_json() {
  local stack_json="$1"
  echo "$stack_json" | jq -c '(.Env // [])'
}

########################################
# SELECTIVE REDEPLOY
########################################

SELECTIVE_CUP_JSON=""
SELECTIVE_LAST_REASON=""
SELECTIVE_CUP_MATCH_REF=""

init_selective_context() {
  SELECTIVE_CUP_JSON=""
  SELECTIVE_CUP_MATCH_REF=""
  if [[ "${SELECTIVE_STACK_REDEPLOY:-false}" != "true" ]]; then
    return 0
  fi
  if [[ "${CUP_ENABLED:-false}" == "true" ]]; then
    if [[ -n "${CUP_JSON_SNAPSHOT:-}" ]]; then
      SELECTIVE_CUP_JSON="$CUP_JSON_SNAPSHOT"
    else
      SELECTIVE_CUP_JSON="$(cup_fetch_json 2>/dev/null || true)"
    fi
    [[ -n "$SELECTIVE_CUP_JSON" ]] && cup_lock_snapshot_from_json_if_unlocked "$SELECTIVE_CUP_JSON" || true
    if [[ -z "$SELECTIVE_CUP_JSON" ]]; then
      if [[ "${CUP_STATUS:-}" != "ok" ]]; then
        log_warn "Selective mode: Cup JSON unavailable; all stacks treated as redeploy candidates (safe)."
      else
        _emit_log_file_ts "Selective mode: Cup snapshot missing; all stacks treated as redeploy candidates (safe)."
      fi
    fi
  fi
}

cup_outdated_image_lines_from_json() {
  local json="${1:-}"
  [[ -z "$json" ]] && return 0
  echo "$json" | jq -r '
    (
      [ .images[]?
        | select(
            ((.result // empty | type == "object") and .result.has_update == true)
            or (.update_available == true)
          )
        | (.reference // .image // .name // empty) | strings ]
      + [ .containers[]?
        | select(
            ((.result // empty | type == "object") and .result.has_update == true)
            or (.update_available == true)
          )
        | (.image // .name // .reference // empty) | strings ]
    ) | .[] | select(length > 0)
  ' 2>/dev/null | sort -u | sed '/^$/d' || true
}

compose_images_match_cup_outdated() {
  local compose_content="$1" cup_json="$2"
  local outdated img cup_ln
  SELECTIVE_CUP_MATCH_REF=""
  outdated="$(cup_outdated_image_lines_from_json "$cup_json")"
  [[ -z "$outdated" ]] && return 1
  while IFS= read -r img; do
    [[ -z "$img" ]] && continue
    while IFS= read -r cup_ln; do
      [[ -z "$cup_ln" ]] && continue
      if _cup_image_refs_equivalent "$img" "$cup_ln"; then
        SELECTIVE_CUP_MATCH_REF="$cup_ln"
        return 0
      fi
    done <<<"$outdated"
  done <<<"$(compose_image_lines_from_content "$compose_content")"
  return 1
}

registry_digest_for_image_ref() {
  local manifest
  manifest="$(docker manifest inspect "$1" 2>/dev/null)" || return 0
  registry_digest_from_manifest_json "$manifest"
}

local_digest_for_image_ref() {
  local rd
  rd="$(docker image inspect --format '{{index .RepoDigests 0}}' "$1" 2>/dev/null || true)"
  if [[ -n "$rd" && "$rd" == *@* ]]; then
    printf '%s' "${rd#*@}"
    return 0
  fi
  printf '%s' ""
}

# Sets global registry_selective_reason on first positive signal.
registry_selective_reason=""
registry_stack_needs_redeploy_from_compose() {
  registry_selective_reason=""
  local compose_content="$1" pol img rem loc
  pol="${REGISTRY_FAIL_POLICY:-safe}"
  while IFS= read -r img; do
    [[ -z "$img" ]] && continue
    rem="$(registry_digest_for_image_ref "$img")"
    if [[ -z "$rem" ]]; then
      if [[ "$pol" == "safe" ]]; then
        registry_selective_reason="manifest_fail_safe"
        return 0
      fi
      log_warn "Registry digest unavailable for ${img} (REGISTRY_FAIL_POLICY=strict; ignoring as update signal)."
      continue
    fi
    loc="$(local_digest_for_image_ref "$img")"
    if [[ -z "$loc" ]]; then
      registry_selective_reason="no_local_image"
      return 0
    fi
    if [[ "$loc" != *"$rem"* ]] && [[ "$loc" != *"${rem#sha256:}"* ]]; then
      registry_selective_reason="digest_mismatch"
      return 0
    fi
  done <<<"$(compose_image_lines_from_content "$compose_content")"
  registry_selective_reason=""
  return 1
}

selective_should_redeploy() {
  local stack_name="$1" stack_id="$2" stack_json="$3"
  SELECTIVE_LAST_REASON=""
  SELECTIVE_CUP_MATCH_REF=""
  if [[ "${SELECTIVE_STACK_REDEPLOY:-false}" != "true" ]]; then
    SELECTIVE_LAST_REASON="off"
    return 0
  fi

  local compose_content
  compose_content="$(get_stack_file_content "$stack_id" 2>/dev/null || true)"
  if [[ -z "${compose_content//[:space:]}" ]]; then
    SELECTIVE_LAST_REASON="compose_empty"
    return 0
  fi

  if [[ "${CUP_ENABLED:-false}" == "true" ]]; then
    if [[ -z "${SELECTIVE_CUP_JSON:-}" ]]; then
      SELECTIVE_LAST_REASON="cup_unreachable"
      return 0
    fi
    if compose_images_match_cup_outdated "$compose_content" "$SELECTIVE_CUP_JSON"; then
      SELECTIVE_LAST_REASON="cup_match"
      return 0
    fi
    if is_git_stack "$stack_json" && [[ "${REDEPLOY_GIT_STACKS_IF_CUP_UNKNOWN:-true}" == "true" ]]; then
      SELECTIVE_LAST_REASON="cup_git_unknown"
      return 0
    fi
    SELECTIVE_LAST_REASON="cup_no_match"
    return 1
  fi

  if registry_stack_needs_redeploy_from_compose "$compose_content"; then
    SELECTIVE_LAST_REASON="${registry_selective_reason:-registry}"
    return 0
  fi
  SELECTIVE_LAST_REASON="registry_current"
  return 1
}

########################################
# PREFLIGHT
########################################

check_requirements() {
  require_cmd curl
  require_cmd jq
  require_cmd docker
  progress_child "Verify curl, jq, docker"

  if [[ "$PORTAINER_API_KEY" == "PASTE_YOUR_PORTAINER_API_KEY_HERE" ]]; then
    fail "Set PORTAINER_API_KEY in $CONFIG_FILE first."
  fi

  log_detail "Checking Portainer API connectivity..."
  api_get "/api/stacks" >/dev/null \
    || fail "Cannot reach Portainer API or API key is invalid."
  progress_child "Ping Portainer API (stack list)"
  log_step "preflight: Portainer API OK"
}

########################################
# APT / PORTAINER PRE-CHECKS
########################################

count_host_upgradable() {
  apt-get update -qq 2>/dev/null || true
  apt-get -s upgrade 2>/dev/null | grep -c '^Inst ' || true
}

count_docker_pkg_upgradable() {
  local out
  out="$(apt-get -s install --only-upgrade "${DOCKER_PKG_LIST[@]}" 2>/dev/null || true)"
  echo "$out" | grep -c '^Inst ' || true
}

report_apt_summary() {
  log_verbose "--- APT summary ---"
  if [[ "$UPDATE_HOST_PACKAGES" == "true" ]]; then
    local n
    n="$(count_host_upgradable)"
    log_verbose "Host packages upgradable (approx count): ${n}"
  else
    log_verbose "Host package updates disabled in config."
  fi

  if [[ "$UPDATE_DOCKER_PACKAGES" == "true" ]]; then
    local d
    d="$(count_docker_pkg_upgradable)"
    log_verbose "Docker-related packages upgradable (simulate Inst lines): ${d}"
  else
    log_verbose "Docker package updates disabled in config."
  fi
}

# Repository prefix for PORTAINER_IMAGE (strip tag or digest suffix) for RepoDigest matching.
_portainer_image_repo_prefix() {
  local p="${PORTAINER_IMAGE%%@*}"
  if [[ "$p" == *:* ]]; then
    printf '%s' "${p%:*}"
  else
    printf '%s' "$p"
  fi
}

portainer_local_digest() {
  local pref digests d
  pref="$(_portainer_image_repo_prefix)"
  digests="$(docker image inspect --format '{{json .RepoDigests}}' "$PORTAINER_IMAGE" 2>/dev/null)" || {
    echo ""
    return
  }
  d="$(echo "$digests" | jq -r --arg p "$pref" '
    .[] | select(type == "string") | select(contains($p + "@"))
  ' 2>/dev/null | head -1)"
  [[ -z "$d" ]] && d="$(echo "$digests" | jq -r '.[0]? // empty' 2>/dev/null)"
  printf '%s' "${d:-}"
}

# Sets globals _PORTAINER_REG_DIGEST and _PORTAINER_REG_VERSION (OCI label when present) for PORTAINER_IMAGE.
portainer_load_registry_digest_and_version() {
  _PORTAINER_REG_DIGEST=""
  _PORTAINER_REG_VERSION=""
  local manifest os arch d ver
  manifest="$(docker manifest inspect "$PORTAINER_IMAGE" 2>/dev/null)" || return 0
  read -r os arch < <(docker_host_platform_os_arch)
  d="$(registry_digest_from_manifest_json "$manifest")"
  if [[ -z "$d" ]] && echo "$manifest" | jq -e '.manifests | type == "array"' >/dev/null 2>&1; then
    log_detail "Portainer registry digest: no platform match for ${os}/${arch}; manifest list had no matching entry."
  fi
  _PORTAINER_REG_DIGEST="${d:-}"
  ver="$(echo "$manifest" | jq -r --arg os "$os" --arg arch "$arch" '
    if (.manifests | type) == "array" and (.manifests | length) > 0 then
      ([
        .manifests[]
        | select(.platform != null and .platform.os == $os
            and (.platform.architecture == $arch
                 or ($arch == "arm64" and .platform.architecture == "arm" and .platform.variant == "v8")))
      ]
      | first
      | .annotations["org.opencontainers.image.version"]? // .annotations["version"]? // empty)
    else empty
    end
  ' 2>/dev/null)"
  if [[ -z "$ver" ]]; then
    ver="$(echo "$manifest" | jq -r '.. | objects | .["org.opencontainers.image.version"]? // empty | strings' 2>/dev/null | head -1)"
  fi
  _PORTAINER_REG_VERSION="${ver:-}"
}

# Running Portainer Server version string from API (no extra auth beyond existing key).
portainer_api_server_version() {
  local raw v
  raw="$(api_get "/api/status" 2>/dev/null || true)"
  v="$(echo "$raw" | jq -r '.Version // .version // empty' 2>/dev/null)"
  if [[ -z "$v" ]]; then
    raw="$(api_get "/api/system/status" 2>/dev/null || true)"
    v="$(echo "$raw" | jq -r '.Version // .version // empty' 2>/dev/null)"
  fi
  printf '%s' "${v:-}"
}

portainer_image_label_version() {
  docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$PORTAINER_IMAGE" 2>/dev/null | tr -d '\r\n' || true
}

# Heuristic: docker prune output indicates nothing reclaimed (0B or blank).
_docker_prune_reclaimed_zero() {
  local o="${1:-}"
  [[ -z "${o//[[:space:]]/}" ]] && return 0
  grep -qiE 'Total reclaimed( space)?:[[:space:]]*0[[:space:]]*B' <<<"$o" && return 0
  return 1
}

# True when docker network prune -f removed nothing (for quiet summary).
_docker_network_prune_no_removals() {
  local o="${1:-}"
  [[ -z "${o//[[:space:]]/}" ]] && return 0
  grep -qiE 'nothing found to prune|nothing to prune|no unused networks' <<<"$o" && return 0
  if _docker_prune_reclaimed_zero "$o"; then
    if grep -qi 'Deleted Networks:' <<<"$o"; then
      awk '/Deleted Networks:/{f=1;next} /^Total reclaimed/{f=0} f' <<<"$o" | grep -qE '[[:alnum:]._-]+' && return 1
    fi
    return 0
  fi
  return 1
}

# True when docker volume prune -f removed nothing.
_docker_volume_prune_no_removals() {
  local o="${1:-}"
  [[ -z "${o//[[:space:]]/}" ]] && return 0
  grep -qiE 'nothing found to prune|nothing to prune|no unused volumes' <<<"$o" && return 0
  if _docker_prune_reclaimed_zero "$o"; then
    if grep -qi 'Deleted Volume' <<<"$o"; then
      awk '/Deleted Volume/{f=1;next} /^Total reclaimed/{f=0} f' <<<"$o" | grep -qE '[[:alnum:]._-]+' && return 1
    fi
    return 0
  fi
  return 1
}

# Sets global _PORTAINER_DIGEST_STAT: unchanged | changed | unknown
portainer_compute_digest_status() {
  local loc rem
  portainer_load_registry_digest_and_version
  loc="$(portainer_local_digest)"
  rem="${_PORTAINER_REG_DIGEST:-}"
  if [[ -z "$loc" || -z "$rem" ]]; then
    _PORTAINER_DIGEST_STAT="unknown"
    log_detail "Portainer digest compare skipped (missing local or registry digest)."
    return 0
  fi
  if [[ "$loc" == *"$rem"* ]] || [[ "$loc" == *"${rem#sha256:}"* ]]; then
    _PORTAINER_DIGEST_STAT="unchanged"
  else
    _PORTAINER_DIGEST_STAT="changed"
  fi
}

########################################
# CUP & PIPELINE STATISTICS
########################################

_print_cup_legend_tty_compact() {
  _quiet_tree_tty || return 0
  [[ "${OUTPUT_MODE:-quiet}" == "quiet" ]] || return 0
  case "$(_legend_mode)" in
    emoji)
      printf '  %sLegend:%s\n' "$(tty_color dim)" "$(tty_color reset)"
      printf '    %s  ✅ Up-to-date      ⬆️ Updates available      ⏸️ No change%s\n' "$(tty_color dim)" "$(tty_color reset)"
      printf '    %s  ⏭️ Skipped         ❌ Failed                 🧹 Cleaned%s\n' "$(tty_color dim)" "$(tty_color reset)"
      ;;
    minimal)
      printf '  %sLegend:%s\n' "$(tty_color dim)" "$(tty_color reset)"
      printf '    %s  ✓ OK              ↑ updates                − none%s\n' "$(tty_color dim)" "$(tty_color reset)"
      printf '    %s  » skip            × fail                   ~ cleaned%s\n' "$(tty_color dim)" "$(tty_color reset)"
      ;;
    *)
      printf '  %sLegend:%s\n' "$(tty_color dim)" "$(tty_color reset)"
      printf '    %s  OK                ^ updates                - none%s\n' "$(tty_color dim)" "$(tty_color reset)"
      printf '    %s  >> skip           X fail                   ~ cleaned%s\n' "$(tty_color dim)" "$(tty_color reset)"
      ;;
  esac
}

# Digits only for safe display / comparisons (Cup jq counts).
_cup_sanitize_count() {
  local v="${1:-0}"
  v="${v//[^0-9]/}"
  [[ -z "$v" ]] && v="0"
  printf '%s' "$v"
}

# Icon for "Updates available: N" — same as legend / RUN SUMMARY (⬆️ even when N is 0).
cup_update_icon() {
  _leg_icon update_available
}

# Quiet-tree lines for Cup counts (aligns with Cup UI metrics when present).
print_cup_stats_tty() {
  local tracked="${1:-0}" outdated="${2:-0}" current="${3:-0}" unknown="${4:-0}"
  _quiet_tree_tty || return 0
  tracked="$(_cup_sanitize_count "$tracked")"
  outdated="$(_cup_sanitize_count "$outdated")"
  current="$(_cup_sanitize_count "$current")"
  unknown="$(_cup_sanitize_count "$unknown")"
  printf '  %s%s Tracked: %s%s\n' "$(tty_color dim)" "$(_leg_icon no_change)" "${tracked}" "$(tty_color reset)"
  printf '  %s%s Updates available: %s%s\n' "$(tty_color dim)" "$(cup_update_icon "$outdated")" "${outdated}" "$(tty_color reset)"
  printf '  %s%s Up-to-date: %s%s\n' "$(tty_color dim)" "$(_leg_icon up_to_date)" "${current}" "$(tty_color reset)"
  printf '  %s%s Unknown: %s%s\n' "$(tty_color dim)" "❔" "${unknown}" "$(tty_color reset)"
}

# POST then GET /api/v3/refresh. Sets CUP_HTTP_REFRESH_LAST_CODE. Returns 0 if any attempt returns 2xx.
cup_http_refresh_once() {
  local base sec code
  base="${CUP_URL%/}"
  sec="${CUP_REFRESH_TIMEOUT_SECONDS:-60}"
  CUP_HTTP_REFRESH_LAST_CODE=""
  [[ -z "$base" ]] && return 1
  code="$(curl -sS --max-time "$sec" -o /dev/null -w "%{http_code}" -X POST "${base}/api/v3/refresh" 2>/dev/null || printf '%s' "000")"
  CUP_HTTP_REFRESH_LAST_CODE="$code"
  [[ "$code" =~ ^2 ]] && return 0
  code="$(curl -sS --max-time "$sec" -o /dev/null -w "%{http_code}" "${base}/api/v3/refresh" 2>/dev/null || printf '%s' "000")"
  CUP_HTTP_REFRESH_LAST_CODE="$code"
  [[ "$code" =~ ^2 ]] && return 0
  return 1
}

# After refresh, poll GET /api/v3/json until cup_compute_counts succeeds or timeout (same seconds as CUP_REFRESH_TIMEOUT_SECONDS).
cup_poll_json_until_metrics_ready() {
  local label="${1:-poll}" sec0 now elapsed tracked _o _c _u json
  sec0="$(date +%s 2>/dev/null || echo 0)"
  while true; do
    json="$(cup_fetch_json_document 2>/dev/null)" || json=""
    if [[ -n "$json" ]]; then
      read -r tracked _o _c _u <<<"$(cup_compute_counts_from_json "$json")"
      if [[ "$tracked" != "-1" ]]; then
        log_verbose "Cup (${label}): JSON metrics ready (tracked=${tracked})."
        _emit_log_file_ts "Cup (${label}): JSON metrics ready (HTTP GET /api/v3/json, tracked=${tracked})."
        return 0
      fi
    fi
    now="$(date +%s 2>/dev/null || echo 0)"
    elapsed=$((now - sec0))
    [[ "$elapsed" -ge "${CUP_REFRESH_TIMEOUT_SECONDS:-60}" ]] && break
    sleep 3
  done
  log_warn "Cup (${label}): timed out after ${CUP_REFRESH_TIMEOUT_SECONDS:-60}s waiting for parseable JSON metrics (${CUP_URL:-})."
  _emit_log_file_ts "Cup (${label}): timed out waiting for parseable JSON metrics (${CUP_URL:-})."
  return 1
}

# After stack redeploys: refresh Cup for next run / UI only (never mutates CUP_JSON_SNAPSHOT, LAST_CUP_*, or CUP_RUN_*).
cup_refresh_after_stacks_if_configured() {
  [[ "${CUP_ENABLED:-false}" == "true" ]] || return 0
  [[ "${CUP_REFRESH_AFTER_STACKS:-true}" == "true" ]] || return 0
  [[ "${#STACKS_REDEPLOYED[@]}" -gt 0 ]] || return 0

  if [[ "$DRY_RUN" == "true" ]]; then
    log_verbose "Cup (post-stack): dry-run — would POST ${CUP_URL%/}/api/v3/refresh after ${#STACKS_REDEPLOYED[@]} redeploy(s)"
    _emit_log_file_ts "Cup (post-stack): dry-run; would refresh after ${#STACKS_REDEPLOYED[@]} redeploy(s) (skipped)."
    return 0
  fi

  local base json t o c u
  base="${CUP_URL%/}"
  log_verbose "Cup (post-stack): POST ${base}/api/v3/refresh after ${#STACKS_REDEPLOYED[@]} stack redeploy(s)"
  _emit_log_file_ts "Cup (post-stack): requesting /api/v3/refresh at ${base} (${#STACKS_REDEPLOYED[@]} redeploy(s); diagnostic only, not used for this run summary)"

  CUP_POST_TRACKED=""
  CUP_POST_OUTDATED=""
  CUP_POST_CURRENT=""
  CUP_POST_UNKNOWN=""
  CUP_POST_REFRESH_JSON=""

  if cup_http_refresh_once; then
    _emit_log_file_ts "Cup (post-stack): /api/v3/refresh HTTP ${CUP_HTTP_REFRESH_LAST_CODE}; polling /api/v3/json (diagnostic)"
    cup_poll_json_until_metrics_ready "post-stack" || true
    json="$(cup_fetch_json_document 2>/dev/null)" || json=""
    if [[ -n "$json" ]]; then
      read -r t o c u <<<"$(cup_compute_counts_from_json "$json")"
      if [[ "$t" != "-1" ]]; then
        CUP_POST_TRACKED="$t"
        CUP_POST_OUTDATED="$o"
        CUP_POST_CURRENT="$c"
        CUP_POST_UNKNOWN="$u"
        CUP_POST_REFRESH_JSON="$(echo "$json" | jq -c '{metrics:(.metrics//null)}' 2>/dev/null || echo "{}")"
        _emit_log_file_ts "Cup (post-stack): metrics after refresh — tracked=${t} updates_available=${o} up_to_date=${c} unknown=${u:-0}"
        log_verbose "Cup (post-stack): metrics after refresh — tracked=${t} updates=${o} up_to_date=${c} unknown=${u:-0}"
      fi
    fi
  else
    log_warn "Cup (post-stack): /api/v3/refresh failed (${CUP_URL:-} HTTP ${CUP_HTTP_REFRESH_LAST_CODE:-000}); Cup UI may be stale until next scan."
    _emit_log_file_ts "Cup (post-stack): /api/v3/refresh failed (HTTP ${CUP_HTTP_REFRESH_LAST_CODE:-000})"
  fi
  return 0
}

# Optional refresh before JSON (Cup /api/v3/refresh). Non-fatal on failure; used by cup_fetch_json.
cup_refresh_if_enabled() {
  [[ "${CUP_REFRESH_BEFORE_CHECK:-true}" == "true" ]] || return 0
  local base="${CUP_URL%/}"
  [[ -z "$base" ]] && return 0
  _emit_log_file_ts "Cup (pre-run): requesting /api/v3/refresh at ${base} (curl max-time ${CUP_REFRESH_TIMEOUT_SECONDS:-60}s per attempt)"
  log_verbose "Cup (pre-run): POST ${base}/api/v3/refresh (GET fallback if non-2xx)"
  if cup_http_refresh_once; then
    _emit_log_file_ts "Cup (pre-run): /api/v3/refresh HTTP ${CUP_HTTP_REFRESH_LAST_CODE}; polling /api/v3/json until metrics parseable (interval 3s, max ${CUP_REFRESH_TIMEOUT_SECONDS:-60}s)"
    log_verbose "Cup (pre-run): refresh ok HTTP ${CUP_HTTP_REFRESH_LAST_CODE}; polling JSON for metrics"
    cup_poll_json_until_metrics_ready "pre-run" || true
    return 0
  fi
  if [[ "${CUP_STATUS:-}" != "ok" ]]; then
    log_warn "Cup: /api/v3/refresh failed or timed out (${CUP_URL:-}); continuing with JSON fetch."
  else
    _emit_log_file_ts "Cup: /api/v3/refresh failed or timed out (${CUP_URL:-}); cached Cup metrics unchanged."
  fi
  return 0
}

# GET /api/v3/json only (no refresh). Used internally and by cup self-test between explicit steps.
cup_fetch_json_document() {
  local base sec
  base="${CUP_URL%/}"
  sec="${CUP_REFRESH_TIMEOUT_SECONDS:-60}"
  [[ -z "$base" ]] && return 1
  curl -sfS --max-time "$sec" "${base}/api/v3/json"
}

cup_fetch_json() {
  local base="${CUP_URL%/}"
  [[ -z "$base" ]] && return 1
  if [[ "${CUP_ENABLED:-false}" == "true" ]] && [[ "${CUP_REFRESH_DONE:-false}" != "true" ]]; then
    cup_refresh_if_enabled
    CUP_REFRESH_DONE="true"
  fi
  cup_fetch_json_document
}

# First successful Cup JSON this run: populate LAST_*, CUP_JSON_SNAPSHOT, and CUP_RUN_* (idempotent if already locked).
cup_lock_snapshot_from_json_if_unlocked() {
  local json="$1" tracked outdated current cup_unknown
  [[ "${CUP_ENABLED:-false}" == "true" ]] || return 0
  [[ "${CUP_RUN_METRICS_LOCKED:-false}" == "true" ]] && return 0
  [[ -z "$json" ]] && return 1
  read -r tracked outdated current cup_unknown <<<"$(cup_compute_counts_from_json "$json")"
  [[ "$tracked" == "-1" ]] && return 1
  tracked="$(_cup_sanitize_count "${tracked:-0}")"
  outdated="$(_cup_sanitize_count "${outdated:-0}")"
  current="$(_cup_sanitize_count "${current:-0}")"
  cup_unknown="$(_cup_sanitize_count "${cup_unknown:-0}")"
  CUP_STATUS="ok"
  CUP_LAST_ERROR=""
  CUP_JSON_SNAPSHOT="$json"
  LAST_CUP_TRACKED="$tracked"
  LAST_CUP_OUTDATED="$outdated"
  LAST_CUP_CURRENT="$current"
  LAST_CUP_UNKNOWN="$cup_unknown"
  CUP_RUN_TRACKED="$tracked"
  CUP_RUN_OUTDATED="$outdated"
  CUP_RUN_CURRENT="$current"
  CUP_RUN_UNKNOWN="$cup_unknown"
  CUP_RUN_JSON_SNAPSHOT="$json"
  CUP_RUN_METRICS_LOCKED="true"
  _emit_log_file_ts "Cup: locked run snapshot for summary (tracked=${tracked} updates_available=${outdated} up_to_date=${current} unknown=${cup_unknown})"
  log_verbose "Cup: run snapshot locked for Run Summary / selective (post-stack refresh will not replace these counts)"
  return 0
}

docker_running_container_count() {
  docker ps -q 2>/dev/null | wc -l | tr -d ' \t\n'
}

cup_compute_counts_from_json() {
  local json="$1"
  local out
  out="$(echo "$json" | jq -r '
    def num(v):
      (v // 0
       | if type == "string" then (tonumber? // 0) elif type == "number" then . else 0 end);
    if (.metrics | type) == "object" then
      "\(num(.metrics.monitored_images)) \(num(.metrics.updates_available)) \(num(.metrics.up_to_date)) \(num(.metrics.unknown))"
    else
      (if (.images | type) == "array" then .images
       elif (.containers | type) == "array" then .containers
       else null
       end) as $items
      | if $items == null then "-1 -1 -1 -1"
        else
          ($items | length) as $t
          | ($items | map(select(
                ((.result // empty | type == "object") and .result.has_update == true)
                or (.update_available == true)
              )) | length) as $o
          | ($t - $o) as $c
          | "\($t) \($o) \($c) 0"
        end
    end
  ' 2>/dev/null)" || out="-1 -1 -1 -1"
  [[ -z "${out:-}" ]] && out="-1 -1 -1 -1"
  echo "$out"
}

print_statistics_block() {
  local when="$1"
  local json_or_empty="$2"
  local dock_running tracked outdated current cup_unknown show_legend=false cup_tty=false

  dock_running="$(docker_running_container_count 2>/dev/null || echo "?")"
  dock_running="${dock_running//[^0-9]/}"
  [[ -z "$dock_running" ]] && dock_running="?"

  case "${when:-}" in
    pipeline_start | report) show_legend=true ;;
  esac

  if [[ "${when:-}" != "pipeline_end" ]] && _quiet_tree_tty && [[ "${OUTPUT_MODE:-quiet}" == "quiet" ]]; then
    cup_tty=true
  fi

  log_verbose "--- Statistics (${when}) ---"
  log_verbose "$(printf '%-32s | %s' "Docker containers (running)" "${dock_running}")"

  if [[ "$cup_tty" == "true" ]]; then
    quiet_print_tree_banner_rule "CONTAINER UPDATES"
  fi

  if [[ "$cup_tty" == "true" ]] && [[ "$show_legend" == "true" ]] && [[ "${CUP_ENABLED:-false}" == "true" ]] && [[ "${QUIET_TREE_LEGEND_DONE:-}" != "true" ]]; then
    _print_cup_legend_tty_compact
    QUIET_TREE_LEGEND_DONE="true"
  fi

  if [[ "${CUP_ENABLED:-false}" != "true" ]]; then
    log_verbose "$(printf '%-32s | %s' "Cup image tracking" "disabled (${CUP_URL:-no URL})")"
    log_verbose "--"
    LAST_CUP_TRACKED=""
    LAST_CUP_OUTDATED=""
    LAST_CUP_CURRENT=""
    LAST_CUP_UNKNOWN=""
    CUP_STATUS="not_checked"
    CUP_LAST_ERROR=""
    CUP_JSON_SNAPSHOT=""
    if [[ "$cup_tty" == "true" ]]; then
      print_info 4 "$(_leg_icon skipped) Cup: disabled (${CUP_URL:-no URL})"
    fi
    return 0
  fi

  if [[ "${when:-}" == "pipeline_end" ]]; then
    local _v_tr _v_ou _v_cu _v_un
    if [[ "${CUP_RUN_METRICS_LOCKED:-false}" == "true" ]]; then
      _v_tr="${CUP_RUN_TRACKED:-}"
      _v_ou="${CUP_RUN_OUTDATED:-}"
      _v_cu="${CUP_RUN_CURRENT:-}"
      _v_un="${CUP_RUN_UNKNOWN:-}"
      log_verbose "--- Statistics (pipeline_end): Cup run snapshot (locked for this run; no refetch) ---"
    else
      _v_tr="${LAST_CUP_TRACKED:-}"
      _v_ou="${LAST_CUP_OUTDATED:-}"
      _v_cu="${LAST_CUP_CURRENT:-}"
      _v_un="${LAST_CUP_UNKNOWN:-}"
      log_verbose "--- Statistics (pipeline_end): Cup metrics from cache (no refetch) ---"
    fi
    log_verbose "$(printf '%-32s | %s' "Docker containers (running)" "${dock_running}")"
    log_verbose "$(printf '%-32s | %s' "Cup entries tracked" "${_v_tr}")"
    log_verbose "$(printf '%-32s | %s' "Cup updates available" "${_v_ou}")"
    log_verbose "$(printf '%-32s | %s' "Cup up to date" "${_v_cu}")"
    log_verbose "$(printf '%-32s | %s' "Cup unknown" "${_v_un}")"
    log_verbose "--"
    return 0
  fi

  local json="$json_or_empty"
  if [[ -z "$json" ]]; then
    if ! json="$(cup_fetch_json 2>/dev/null)"; then
      if [[ "${CUP_STATUS:-}" == "ok" ]]; then
        _emit_log_file_ts "$(printf '%-32s | %s' "Cup (${CUP_URL})" "unreachable (cached metrics preserved)")"
        log_verbose "--"
        return 0
      fi
      CUP_STATUS="unreachable"
      CUP_LAST_ERROR="unreachable"
      log_warn "$(printf '%-32s | %s' "Cup (${CUP_URL})" "unreachable")"
      log_verbose "--"
      LAST_CUP_TRACKED=""
      LAST_CUP_OUTDATED=""
      LAST_CUP_CURRENT=""
      LAST_CUP_UNKNOWN=""
      if [[ "$cup_tty" == "true" ]]; then
        print_info 4 "$(_leg_icon failed) Cup: unreachable (${CUP_URL})"
      fi
      return 1
    fi
  fi

  read -r tracked outdated current cup_unknown <<<"$(cup_compute_counts_from_json "$json")"
  if [[ "$tracked" == "-1" ]]; then
    if [[ "${CUP_STATUS:-}" == "ok" ]]; then
      _emit_log_file_ts "Cup JSON: could not derive counts on refetch (schema mismatch?); cached metrics preserved."
      log_verbose "--"
      return 0
    fi
    CUP_STATUS="parse_error"
    CUP_LAST_ERROR="parse_error"
    log_warn "Cup JSON: could not derive counts (schema mismatch?)."
    log_verbose "--"
    LAST_CUP_TRACKED=""
    LAST_CUP_OUTDATED=""
    LAST_CUP_CURRENT=""
    LAST_CUP_UNKNOWN=""
    if [[ "$cup_tty" == "true" ]]; then
      print_info 4 "$(_leg_icon failed) Cup: could not parse counts (schema mismatch?)"
    fi
    return 1
  fi

  cup_lock_snapshot_from_json_if_unlocked "$json" || true
  tracked="$LAST_CUP_TRACKED"
  outdated="$LAST_CUP_OUTDATED"
  current="$LAST_CUP_CURRENT"
  cup_unknown="$LAST_CUP_UNKNOWN"

  log_verbose "$(printf '%-32s | %s' "Cup entries tracked" "${tracked}")"
  log_verbose "$(printf '%-32s | %s' "Cup updates available" "${outdated}")"
  log_verbose "$(printf '%-32s | %s' "Cup up to date" "${current}")"
  log_verbose "$(printf '%-32s | %s' "Cup unknown" "${cup_unknown}")"

  if [[ "$cup_tty" == "true" ]]; then
    print_cup_stats_tty "$tracked" "$outdated" "$current" "$cup_unknown"
    ui_mirror_line "[cup-stats] tracked=${tracked} updates=${outdated} up_to_date=${current} unknown=${cup_unknown}"
    printf '\n'
  fi

  if [[ "${OUTPUT_MODE:-quiet}" == "verbose" ]]; then
    {
      echo "$json" | jq -r '
        [
          (.images // [])[]?
          | select(
              ((.result // empty | type == "object") and .result.has_update == true)
              or (.update_available == true)
            )
          | {
              r: (.reference // .image // .name // ""),
              c: (.result.info.current_version // .result.info.current_tag // ""),
              n: (.result.info.new_version // .result.info.new_tag // ""),
              t: (.result.info.version_update_type // .result.info.type // "")
            },
          (.containers // [])[]?
          | select(
              ((.result // empty | type == "object") and .result.has_update == true)
              or (.update_available == true)
            )
          | {
              r: (.image // .name // .reference // ""),
              c: (.result.info.current_version // .result.info.current_tag // ""),
              n: (.result.info.new_version // .result.info.new_tag // ""),
              t: (.result.info.version_update_type // .result.info.type // "")
            }
        ]
        | map(select((.r | type == "string") and (.r | length) > 0))
        | group_by(.r)
        | map(.[0])
        | .[0:40][]
        | "outdated: \(.r) \(.c) → \(.n) \(.t)"
      ' 2>/dev/null | while read -r line; do
        [[ -n "$line" ]] && log_detail "  $line"
      done
    } || true
  fi

  log_verbose "--"
  return 0
}

print_pipeline_statistics() {
  local when="$1"
  print_statistics_block "$when" "" || true
}

report_cup_summary() {
  [[ "$CUP_ENABLED" == "true" ]] || return 0
  require_cmd curl
  # Cup table before stack prompt: bump quiet → verbose so rows are visible.
  local saved="${OUTPUT_MODE:-quiet}"
  [[ "$OUTPUT_MODE" == "quiet" ]] && OUTPUT_MODE="verbose"
  print_pipeline_statistics "cup_summary"
  OUTPUT_MODE="$saved"
  [[ "$OUTPUT_MODE" == "verbose" ]] && VERBOSE=true || VERBOSE=false
}

should_skip_stack_phase_for_cup() {
  [[ "${SKIP_STACK_PHASE_IF_CUP_CLEAN:-false}" == "true" ]] || return 1
  [[ "${CUP_ENABLED:-false}" == "true" ]] || return 1

  local json
  progress_child "Fetch Cup status (skip gate)"
  if [[ -n "${CUP_JSON_SNAPSHOT:-}" ]]; then
    json="$CUP_JSON_SNAPSHOT"
  elif ! json="$(cup_fetch_json 2>/dev/null)"; then
    if [[ "${CUP_STATUS:-}" == "ok" ]]; then
      _emit_log_file_ts "Cup unreachable at stack skip gate; not skipping stack phase (cached metrics preserved)."
    else
      log_warn "Cup unreachable — not skipping stack phase (would redeploy)."
    fi
    return 1
  fi

  local tracked outdated current _cuu
  read -r tracked outdated current _cuu <<<"$(cup_compute_counts_from_json "$json")"
  if [[ "$tracked" == "-1" ]]; then
    log_warn "Cup JSON unreadable — not skipping stack phase."
    return 1
  fi

  cup_lock_snapshot_from_json_if_unlocked "$json" || true

  if [[ "${outdated:-1}" -eq 0 ]]; then
    log_detail "Cup: outdated count is 0 (tracked=${tracked})."
    return 0
  fi

  return 1
}

# True if any image: line in compose content matches Cup outdated ref.
_cup_compose_stack_matches_outdated_ref() {
  local compose_content="$1" cup_ref="$2"
  local img
  [[ -z "$cup_ref" ]] && return 1
  while IFS= read -r img; do
    [[ -z "$img" ]] && continue
    _cup_image_refs_equivalent "$img" "$cup_ref" && return 0
  done <<<"$(compose_image_lines_from_content "$compose_content")"
  return 1
}

# One-shot Cup diagnostics (URL, refresh, JSON, metrics, outdated refs, Portainer compose matches).
cup_run_selftest_phase() {
  local base sec rf_ok js_ok json json_before t0 o0 c0 u0 tracked outdated current cup_unknown i ref stacks mline sid sc
  base="${CUP_URL%/}"
  sec="${CUP_REFRESH_TIMEOUT_SECONDS:-60}"

  log_step "cup: diagnostics (self-test)"
  log_info "Cup URL: ${CUP_URL:-}"
  log_info "CUP_REFRESH_BEFORE_CHECK=${CUP_REFRESH_BEFORE_CHECK:-}  CUP_REFRESH_TIMEOUT_SECONDS=${sec}  CUP_REFRESH_AFTER_STACKS=${CUP_REFRESH_AFTER_STACKS:-}"

  log_info "GET /api/v3/json before explicit refresh (read-only peek; full pipeline uses refresh+poll via cup_fetch_json first):"
  json_before=""
  if json_before="$(cup_fetch_json_document 2>/dev/null)" && [[ -n "$json_before" ]]; then
    read -r t0 o0 c0 u0 <<<"$(cup_compute_counts_from_json "$json_before")"
    if [[ "$t0" != "-1" ]]; then
      log_info "  metrics before explicit refresh — tracked=${t0} updates_available=${o0} up_to_date=${c0} unknown=${u0:-0}"
    else
      log_info "  (metrics not yet parseable from this JSON)"
    fi
  else
    log_info "  (GET /api/v3/json failed)"
  fi

  rf_ok="skipped (CUP_REFRESH_BEFORE_CHECK=false)"
  if [[ "${CUP_REFRESH_BEFORE_CHECK:-true}" == "true" ]]; then
    _emit_log_file_ts "Cup (phase cup): POST ${base}/api/v3/refresh (self-test)"
    log_info "Calling /api/v3/refresh (cup_http_refresh_once + optional poll)…"
    if cup_http_refresh_once; then
      rf_ok="ok HTTP ${CUP_HTTP_REFRESH_LAST_CODE}"
      cup_poll_json_until_metrics_ready "cup-phase" || true
    else
      rf_ok="failed HTTP ${CUP_HTTP_REFRESH_LAST_CODE:-000}"
    fi
  fi
  log_info "/api/v3/refresh: ${rf_ok}"

  json=""
  js_ok="failed"
  if json="$(cup_fetch_json_document 2>/dev/null)" && [[ -n "$json" ]]; then
    js_ok="ok"
  fi
  log_info "/api/v3/json (after refresh path): ${js_ok}"

  if [[ "$js_ok" != "ok" ]]; then
    log_warn "Cup self-test: no JSON body to parse."
    [[ "${CUP_REFRESH_BEFORE_CHECK:-true}" == "true" ]] && CUP_REFRESH_DONE="true"
    return 0
  fi

  log_info "Metrics after refresh path:"
  read -r tracked outdated current cup_unknown <<<"$(cup_compute_counts_from_json "$json")"
  if [[ "$tracked" == "-1" ]]; then
    log_warn "Parsed counts: (unreadable schema)"
  else
    log_info "  tracked=${tracked}  updates_available=${outdated}  up_to_date=${current}  unknown=${cup_unknown:-0}"
  fi

  log_info "Full pipeline: first successful Container Updates parse locks CUP_RUN_* for Run Summary; CUP_JSON_SNAPSHOT drives selective + Portainer Cup pre-check for that run."
  log_info "This process: CUP_RUN_METRICS_LOCKED=${CUP_RUN_METRICS_LOCKED:-false}  CUP_JSON_SNAPSHOT length=${#CUP_JSON_SNAPSHOT}"

  mline="$(echo "$json" | jq -c '.metrics // empty' 2>/dev/null || echo "")"
  if [[ -n "$mline" && "$mline" != "null" ]]; then
    log_info "Raw .metrics: ${mline}"
  else
    log_info "Raw .metrics: (absent)"
  fi

  log_info "First 10 outdated references (Cup) vs Portainer compose image: lines:"
  i=0
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    i=$((i + 1))
    [[ "$i" -gt 10 ]] && break
    stacks=""
    while IFS= read -r sname; do
      [[ -z "$sname" ]] && continue
      sid="$(get_stack_id_by_name "$sname" 2>/dev/null || true)"
      [[ -z "$sid" ]] && continue
      sc="$(get_stack_file_content "$sid" 2>/dev/null || true)"
      if _cup_compose_stack_matches_outdated_ref "$sc" "$ref"; then
        stacks="${stacks}${stacks:+ }${sname}"
      fi
    done < <(get_all_stack_names_for_endpoint)
    if [[ -n "$stacks" ]]; then
      log_info "  ${ref}  →  matched stack(s): ${stacks}"
    else
      log_info "  ${ref}  →  no Portainer compose image match on this endpoint"
    fi
  done < <(cup_outdated_image_lines_from_json "$json" | head -10)

  [[ "${CUP_REFRESH_BEFORE_CHECK:-true}" == "true" ]] && CUP_REFRESH_DONE="true"
  return 0
}

########################################
# FULL REPORT (check-only)
########################################

generate_report() {
  log_step "report: start (no changes)"
  check_requirements
  refresh_stacks_cache
  report_apt_summary
  print_pipeline_statistics "report"
  log_verbose "--- Portainer stacks on endpoint ${ENDPOINT_ID} ---"
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] && log_verbose "  stack: $name"
  done < <(get_all_stack_names_for_endpoint)
  if [[ "${CUP_ENABLED:-false}" == "true" ]]; then
    cup_run_selftest_phase || true
  fi
  log_step "report: complete"
}

########################################
# REDEPLOY METHODS
########################################

redeploy_git_stack() {
  local stack_id="$1"
  local stack_name="$2"

  log_step "redeploy git stack: ${stack_name} (id ${stack_id})"
  log_detail "PUT .../git/redeploy"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_detail "DRY RUN: PUT /api/stacks/${stack_id}/git/redeploy?endpointId=${ENDPOINT_ID}"
    return 0
  fi

  curl "${CURL_OPTS[@]}" \
    -X PUT \
    -H "${AUTH_HEADER[0]}" \
    "${PORTAINER_URL}/api/stacks/${stack_id}/git/redeploy?endpointId=${ENDPOINT_ID}" >/dev/null \
    || return 1
}

redeploy_regular_stack() {
  local stack_id="$1"
  local stack_name="$2"
  local stack_json="$3"

  local tmp_json tmp_compose env_json
  tmp_json="$(_mktemp_track)"
  tmp_compose="$(_mktemp_track)"

  get_stack_file_content "$stack_id" >"$tmp_compose" || true
  if [[ ! -s "$tmp_compose" ]] || [[ -z "$(tr -d '[:space:]' <"$tmp_compose")" ]]; then
    log_warn "Compose content empty for stack ${stack_name} (id ${stack_id}); aborting redeploy."
    rm -f "$tmp_json" "$tmp_compose"
    return 1
  fi
  env_json="$(build_env_json "$stack_json")"

  jq -n \
    --rawfile compose "$tmp_compose" \
    --argjson env "$env_json" \
    '{
      StackFileContent: $compose,
      Env: $env,
      Prune: false,
      PullImage: true
    }' >"$tmp_json"

  log_step "redeploy compose stack: ${stack_name} (id ${stack_id})"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_detail "DRY RUN: PUT /api/stacks/${stack_id}?endpointId=${ENDPOINT_ID}"
    rm -f "$tmp_json" "$tmp_compose"
    return 0
  fi

  api_put_json "/api/stacks/${stack_id}?endpointId=${ENDPOINT_ID}" "$tmp_json" >/dev/null \
    || {
      rm -f "$tmp_json" "$tmp_compose"
      return 1
    }

  rm -f "$tmp_json" "$tmp_compose"
}

redeploy_stack_by_name() {
  local stack_name="$1"
  local quiet_group="${2:-}"
  local _now

  STACK_LAST_ACTUAL_REDEPLOY=0
  STACK_LAST_DRY_RUN_PLANNED_REDEPLOY=0
  STACK_LAST_REDEPLOY_T0=0
  STACK_LAST_REDEPLOY_SECS=0

  progress_child "Resolve stack: ${stack_name}"

  if is_excluded_stack "$stack_name"; then
    log_detail "Skipping excluded stack: $stack_name"
    STACKS_SKIPPED_REASONS+=("${stack_name}|excluded")
    if [[ -n "$quiet_group" ]]; then
      stack_progress_begin_item "$quiet_group" "$stack_name" "skipped"
      stack_finalize_stack_ui "$quiet_group" "$stack_name" "excluded" "excluded" "skipped"
    fi
    return 0
  fi

  local stack_id stack_json

  stack_id="$(get_stack_id_by_name "$stack_name")"

  if [[ -z "$stack_id" ]]; then
    fail "Stack not found in Portainer on endpoint ${ENDPOINT_ID}: ${stack_name}"
  fi

  stack_json="$(get_stack_json_by_id "$stack_id")"

  if [[ -z "$stack_json" || "$stack_json" == "null" ]]; then
    fail "Could not load stack JSON for ${stack_name}"
  fi

  [[ -n "$quiet_group" ]] && _stack_subgroup_bump "$quiet_group" checked

  if [[ -n "$quiet_group" ]]; then
    stack_progress_begin_item "$quiet_group" "$stack_name" "checking"
  fi

  if [[ "${SELECTIVE_STACK_REDEPLOY:-false}" == "true" ]]; then
    [[ -n "$quiet_group" ]] && stack_progress_action "$quiet_group" "$stack_name" "$(_stack_compare_action_label)"
    if ! selective_should_redeploy "$stack_name" "$stack_id" "$stack_json"; then
      log_detail "Selective skip: ${stack_name} (${SELECTIVE_LAST_REASON:-unknown})"
      STACKS_SKIPPED_REASONS+=("${stack_name}|selective_${SELECTIVE_LAST_REASON:-skip}")
      [[ -n "$quiet_group" ]] && stack_finalize_stack_ui "$quiet_group" "$stack_name" "unchanged" "${SELECTIVE_LAST_REASON:-skip}" "unchanged"
      return 0
    fi
    [[ -n "$quiet_group" ]] && stack_progress_action "$quiet_group" "$stack_name" "redeploying"
    if [[ "$DRY_RUN" == "true" ]]; then
      log_detail "Selective dry-run: would redeploy ${stack_name} (${SELECTIVE_LAST_REASON:-ok})"
    fi
  else
    [[ -n "$quiet_group" ]] && stack_progress_action "$quiet_group" "$stack_name" "redeploying"
  fi

  log_detail "Processing stack: ${stack_name} / ID: ${stack_id}"

  STACK_LAST_REDEPLOY_T0="$(date +%s 2>/dev/null || echo 0)"

  if is_git_stack "$stack_json"; then
    progress_child "Trigger git redeploy: ${stack_name}"
    redeploy_git_stack "$stack_id" "$stack_name" || {
      STACKS_SKIPPED_REASONS+=("${stack_name}|redeploy_failed")
      [[ -n "$quiet_group" ]] && _stack_subgroup_bump "$quiet_group" failed
      [[ -n "$quiet_group" ]] && stack_finalize_stack_ui "$quiet_group" "$stack_name" "failed" "git redeploy" "failed"
      return 1
    }
  else
    progress_child "Prepare compose redeploy: ${stack_name}"
    redeploy_regular_stack "$stack_id" "$stack_name" "$stack_json" || {
      STACKS_SKIPPED_REASONS+=("${stack_name}|redeploy_failed")
      [[ -n "$quiet_group" ]] && _stack_subgroup_bump "$quiet_group" failed
      [[ -n "$quiet_group" ]] && stack_finalize_stack_ui "$quiet_group" "$stack_name" "failed" "compose redeploy" "failed"
      return 1
    }
  fi

  _now="$(date +%s 2>/dev/null || echo 0)"
  STACK_LAST_REDEPLOY_SECS=$((_now - STACK_LAST_REDEPLOY_T0))
  [[ "${STACK_LAST_REDEPLOY_SECS:-0}" -lt 0 ]] && STACK_LAST_REDEPLOY_SECS=0

  if [[ "$DRY_RUN" == "true" ]]; then
    STACK_LAST_DRY_RUN_PLANNED_REDEPLOY=1
    STACKS_SKIPPED_REASONS+=("${stack_name}|dry-run_planned")
    local _cup_dry=""
    if [[ "${SELECTIVE_STACK_REDEPLOY:-false}" == "true" ]] && [[ "${SELECTIVE_LAST_REASON:-}" == "cup_match" ]] && [[ -n "${SELECTIVE_CUP_MATCH_REF:-}" ]]; then
      _cup_dry="planned, Cup match: ${SELECTIVE_CUP_MATCH_REF}"
    else
      _cup_dry="planned, not applied"
    fi
    [[ -n "$quiet_group" ]] && stack_finalize_stack_ui "$quiet_group" "$stack_name" "dry_run" "${_cup_dry}" "dry-run planned"
  else
    STACK_LAST_ACTUAL_REDEPLOY=1
    STACKS_REDEPLOYED+=("$stack_name")
    [[ -n "$quiet_group" ]] && _stack_subgroup_bump "$quiet_group" redeployed
    local _cup_rd=""
    if [[ "${SELECTIVE_STACK_REDEPLOY:-false}" == "true" ]] && [[ "${SELECTIVE_LAST_REASON:-}" == "cup_match" ]] && [[ -n "${SELECTIVE_CUP_MATCH_REF:-}" ]]; then
      _cup_rd="Cup update matched ${SELECTIVE_CUP_MATCH_REF}"
    fi
    [[ -n "$quiet_group" ]] && stack_finalize_stack_ui "$quiet_group" "$stack_name" "redeployed" "${_cup_rd}" "redeployed"
  fi
}

########################################
# WAIT HELPERS
########################################

# Format seconds as MM:SS for stack-timing lines.
_stack_secs_to_mmss() {
  local s="${1:-0}"
  local m r
  m=$((s / 60))
  r=$((s % 60))
  printf '%02d:%02d' "$m" "$r"
}

# After redeploy_stack_by_name: one post-redeploy wait keyed by group (no duplicate default+group sleeps).
# Uses STACK_LAST_ACTUAL_REDEPLOY, STACK_LAST_DRY_RUN_PLANNED_REDEPLOY, STACK_LAST_REDEPLOY_SECS.
# Sets STACK_LAST_POST_WAIT_SECS to seconds slept (0 if skipped or dry-run).
stack_post_redeploy_wait_for_group() {
  local stack_name="$1"
  local group="$2"
  local redeploy_secs="${STACK_LAST_REDEPLOY_SECS:-0}"
  local t_ws tw tot

  STACK_LAST_POST_WAIT_SECS=0

  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ "${STACK_LAST_DRY_RUN_PLANNED_REDEPLOY:-0}" != "1" ]]; then
      _emit_log_file_ts "[wait] ${stack_name} unchanged; no wait"
      return 0
    fi
    case "$group" in
      dependency)
        _emit_log_file_ts "[wait] ${stack_name} dry-run; would run container readiness (poll) then ${DEPENDENCY_SETTLE_SECONDS}s dependency settle"
        ;;
      dependent)
        _emit_log_file_ts "[wait] ${stack_name} dry-run; would wait ${DEPENDENT_STACK_SLEEP_SECONDS}s after ${stack_name} (dependent)"
        ;;
      heavy)
        _emit_log_file_ts "[wait] ${stack_name} dry-run; would wait ${HEAVY_STACK_SLEEP_SECONDS}s after ${stack_name} (heavy)"
        ;;
      remaining)
        _emit_log_file_ts "[wait] ${stack_name} dry-run; would wait ${DEFAULT_STACK_SLEEP_SECONDS}s after ${stack_name}"
        ;;
      *)
        _emit_log_file_ts "[wait] ${stack_name} dry-run; would wait ${DEFAULT_STACK_SLEEP_SECONDS}s after ${stack_name}"
        ;;
    esac
    _emit_log_file_ts "[stack-timing] ${stack_name} redeploy=$(_stack_secs_to_mmss "$redeploy_secs") wait=00:00 total=$(_stack_secs_to_mmss "$redeploy_secs")"
    return 0
  fi

  if [[ "${STACK_LAST_ACTUAL_REDEPLOY:-0}" != "1" ]]; then
    _emit_log_file_ts "[wait] ${stack_name} unchanged; no wait"
    return 0
  fi

  t_ws="$(date +%s 2>/dev/null || echo 0)"
  case "$group" in
    dependency)
      _emit_log_file_ts "[wait] ${stack_name} redeployed; dependency settle (container check + ${DEPENDENCY_SETTLE_SECONDS}s)"
      progress_child "Wait for service container: ${stack_name}"
      wait_for_compose_project_running "$stack_name" 300 || true
      log_detail "Giving dependency stack '${stack_name}' ${DEPENDENCY_SETTLE_SECONDS}s to settle..."
      progress_child "Settling after dependency stack: ${stack_name} (${DEPENDENCY_SETTLE_SECONDS}s)"
      sleep "$DEPENDENCY_SETTLE_SECONDS"
      ;;
    dependent)
      _emit_log_file_ts "[wait] ${stack_name} redeployed; dependent wait ${DEPENDENT_STACK_SLEEP_SECONDS}s"
      sleep "$DEPENDENT_STACK_SLEEP_SECONDS"
      ;;
    heavy)
      _emit_log_file_ts "[wait] ${stack_name} redeployed; heavy wait ${HEAVY_STACK_SLEEP_SECONDS}s"
      sleep "$HEAVY_STACK_SLEEP_SECONDS"
      ;;
    remaining)
      _emit_log_file_ts "[wait] ${stack_name} redeployed; sleeping ${DEFAULT_STACK_SLEEP_SECONDS}s"
      sleep "$DEFAULT_STACK_SLEEP_SECONDS"
      ;;
    *)
      _emit_log_file_ts "[wait] ${stack_name} redeployed; sleeping ${DEFAULT_STACK_SLEEP_SECONDS}s"
      sleep "$DEFAULT_STACK_SLEEP_SECONDS"
      ;;
  esac
  tw=$(($(date +%s 2>/dev/null || echo 0) - t_ws))
  [[ "$tw" -lt 0 ]] && tw=0
  STACK_LAST_POST_WAIT_SECS=$tw
  tot=$((redeploy_secs + tw))
  _emit_log_file_ts "[stack-timing] ${stack_name} redeploy=$(_stack_secs_to_mmss "$redeploy_secs") wait=$(_stack_secs_to_mmss "$tw") total=$(_stack_secs_to_mmss "$tot")"
}

container_is_running() {
  local container_name="$1"
  local state
  state="$(docker container inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || echo "false")"
  [[ "$state" == "true" ]]
}

wait_for_container_running() {
  local container_name="$1"
  local timeout="${2:-300}"
  local waited=0

  log_detail "Waiting for container '${container_name}' to be running..."

  while [[ "$waited" -lt "$timeout" ]]; do
    if container_is_running "$container_name"; then
      log_step "container running: ${container_name}"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done

  log_warn "Timed out waiting for container '${container_name}'."
  return 1
}

# Wait for all containers in a Compose project (label com.docker.compose.project).
wait_for_compose_project_running() {
  local stack_name="$1"
  local timeout="${2:-300}"
  local project waited=0 ids id state health n=0
  project="$(compose_project_slug_from_stack_name "$stack_name")"
  log_detail "Waiting for compose project '${project}' (stack ${stack_name}) containers to be running..."

  while [[ "$waited" -lt "$timeout" ]]; do
    mapfile -t ids < <(docker ps -aq --filter "label=com.docker.compose.project=${project}" 2>/dev/null || true)
    n="${#ids[@]}"
    if [[ "$n" -eq 0 ]]; then
      if container_is_running "$stack_name"; then
        log_step "container running: ${stack_name} (name match)"
        return 0
      fi
      if [[ "$waited" -ge 15 ]]; then
        log_warn "No compose project containers found for '${project}' (stack ${stack_name}); skipping long wait."
        return 1
      fi
    else
      local all_ok=1
      for id in "${ids[@]}"; do
        [[ -n "$id" ]] || continue
        state="$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null || echo false)"
        health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null || echo none)"
        if [[ "$state" != "true" ]]; then
          all_ok=0
          break
        fi
        if [[ "$health" == "unhealthy" ]]; then
          all_ok=0
          break
        fi
        if [[ "$health" == "starting" ]]; then
          all_ok=0
        fi
      done
      if [[ "$all_ok" -eq 1 ]]; then
        log_step "compose project running: ${project} (${n} container(s))"
        return 0
      fi
    fi
    sleep 5
    waited=$((waited + 5))
  done
  log_warn "Timed out waiting for compose project '${project}' (stack ${stack_name})."
  return 1
}

########################################
# HOST / DOCKER PACKAGE UPDATES
########################################

update_host_packages() {
  if [[ "$UPDATE_HOST_PACKAGES" != "true" ]]; then
    log_detail "Skipping host package updates."
    SUMMARY_PHASE_HOST="disabled"
    return 0
  fi

  if [[ "$SKIP_HOST_IF_NONE" == "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
    local n
    n="$(count_host_upgradable)"
    if [[ "${n:-0}" -eq 0 ]]; then
      log_detail "SKIP_HOST_IF_NONE: no host upgrades detected; skipping apt upgrade."
      SUMMARY_PHASE_HOST="skipped_no_updates"
      return 0
    fi
  fi

  log_step "host packages: update / upgrade / autoremove"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_detail "DRY RUN: package manager update / upgrade / autoremove"
    SUMMARY_PHASE_HOST="dry-run"
    return 0
  fi

  quiet_live "Host packages: upgrade (may take a while)…"
  run_pkg_mgr upgrade -y || {
    mark_pipeline_hard_failure
    log_warn "host package upgrade failed"
  }
  quiet_live "Host packages: autoremove…"
  run_pkg_mgr autoremove -y || log_warn "host package autoremove failed"
  quiet_live_clear
  SUMMARY_PHASE_HOST="ran"
}

update_docker_packages() {
  if [[ "$UPDATE_DOCKER_PACKAGES" != "true" ]]; then
    log_detail "Skipping Docker package updates."
    SUMMARY_PHASE_DOCKER_PKGS="disabled"
    return 0
  fi

  if [[ "$SKIP_DOCKER_PKGS_IF_NONE" == "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
    local n
    n="$(count_docker_pkg_upgradable)"
    if [[ "${n:-0}" -eq 0 ]]; then
      log_detail "SKIP_DOCKER_PKGS_IF_NONE: no docker-related package upgrades simulated; skipping."
      SUMMARY_PHASE_DOCKER_PKGS="skipped_no_updates"
      return 0
    fi
  fi

  log_step "Docker-related apt packages: upgrade"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_detail "DRY RUN: install --only-upgrade docker-related packages"
    SUMMARY_PHASE_DOCKER_PKGS="dry-run"
    return 0
  fi

  quiet_live "Docker-related apt packages: upgrade…"
  run_pkg_mgr install -y --only-upgrade \
    "${DOCKER_PKG_LIST[@]}" \
    || {
      mark_pipeline_hard_failure
      log_warn "Docker package upgrade failed"
    }

  quiet_live_clear
  DOCKER_VER_DISPLAY="$(docker --version 2>/dev/null || echo 'Docker unavailable')"
  COMPOSE_VER_DISPLAY="$(docker compose version 2>/dev/null || echo 'Docker Compose unavailable')"
  _emit_log_file_ts "${DOCKER_VER_DISPLAY}"
  _emit_log_file_ts "${COMPOSE_VER_DISPLAY}"
  if ! _quiet_tree_tty; then
    printf '%s\n' "${DOCKER_VER_DISPLAY}"
    printf '%s\n' "${COMPOSE_VER_DISPLAY}"
  fi
  SUMMARY_PHASE_DOCKER_PKGS="ran"
}

########################################
# ORDERED DEPLOYMENT
########################################

deploy_dependency_stacks() {
  local stack_name dep_any_redeployed=0 dep_wait_total=0

  if _quiet_tree_tty; then
    printf '\n'
    quiet_stack_subgroup_title "$(_stack_group_display_name dependency)"
  fi
  if [[ "${#DEPENDENCY_STACKS[@]}" -eq 0 ]]; then
    if _quiet_tree_tty; then
      quiet_subnote_dim "(none configured)"
    fi
    log_detail "No dependency stacks configured."
    SUMMARY_STACK_SUB_DEPENDENCY="none configured"
    return 0
  fi

  log_step "stacks: dependency group (${#DEPENDENCY_STACKS[@]} configured)"
  progress_child "Dependency stacks (${#DEPENDENCY_STACKS[@]} in order)"

  for stack_name in "${DEPENDENCY_STACKS[@]}"; do
    [[ -n "$stack_name" ]] || continue

    if [[ "${SELECTIVE_STACK_REDEPLOY:-false}" == "true" ]]; then
      local _dsid _dsj
      _dsid="$(get_stack_id_by_name "$stack_name")"
      if [[ -z "$_dsid" ]]; then
        log_warn "Dependency stack not found (skipping): ${stack_name}"
        STACKS_SKIPPED_REASONS+=("${stack_name}|dependency_not_found")
        stack_progress_begin_item "dependency" "$stack_name" "checking"
        stack_finalize_stack_ui "dependency" "$stack_name" "skipped_dep" "not on endpoint" "skipped"
        continue
      fi
    fi

    redeploy_stack_by_name "$stack_name" "dependency" || {
      log_warn "Failed redeploying dependency stack '${stack_name}'. Continuing."
      continue
    }

    stack_post_redeploy_wait_for_group "$stack_name" dependency
    if [[ "${STACK_LAST_ACTUAL_REDEPLOY:-0}" == "1" ]]; then
      dep_any_redeployed=1
    fi
    dep_wait_total=$((dep_wait_total + STACK_LAST_POST_WAIT_SECS))
  done

  if [[ "$dep_any_redeployed" -eq 0 ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      _emit_log_file_ts "[wait] dependency group dry-run; no actual dependency settle"
      _emit_log_file_ts "[stack-timing] dependency_settle dry-run; no actual sleeps"
    else
      _emit_log_file_ts "[wait] dependency group unchanged; no dependency settle"
      _emit_log_file_ts "[stack-timing] dependency_settle skipped; no dependency stack redeployed"
    fi
  else
    _emit_log_file_ts "[stack-timing] dependency group finished; dependency_post_redeploy_wait_total=${dep_wait_total}s"
  fi

  quiet_stack_group_summary "$(_stack_group_display_name dependency)" "${STACK_GRP_DEP_CHECKED}" "${STACK_GRP_DEP_REDEPLOYED}" "${STACK_GRP_DEP_FAILED}"
  SUMMARY_STACK_SUB_DEPENDENCY="completed"
}

deploy_dependent_stacks() {
  local stack_name

  if _quiet_tree_tty; then
    printf '\n'
    quiet_stack_subgroup_title "$(_stack_group_display_name dependent)"
  fi
  if [[ "${#DEPENDENT_STACKS[@]}" -eq 0 ]]; then
    if _quiet_tree_tty; then
      quiet_subnote_dim "(none configured)"
    fi
    log_detail "No dependent stacks configured."
    SUMMARY_STACK_SUB_DEPENDENT="none configured"
    return 0
  fi

  log_step "stacks: dependent group (${#DEPENDENT_STACKS[@]} configured)"
  progress_child "Dependent stacks (${#DEPENDENT_STACKS[@]} in order)"

  for stack_name in "${DEPENDENT_STACKS[@]}"; do
    [[ -n "$stack_name" ]] || continue

    redeploy_stack_by_name "$stack_name" "dependent" || {
      log_warn "Failed redeploying dependent stack '${stack_name}'. Continuing."
      continue
    }

    stack_post_redeploy_wait_for_group "$stack_name" dependent
  done
  quiet_stack_group_summary "$(_stack_group_display_name dependent)" "${STACK_GRP_DEPENDENT_CHECKED}" "${STACK_GRP_DEPENDENT_REDEPLOYED}" "${STACK_GRP_DEPENDENT_FAILED}"
  SUMMARY_STACK_SUB_DEPENDENT="completed"
}

deploy_heavy_stacks() {
  local stack_name _hid

  if _quiet_tree_tty; then
    printf '\n'
    quiet_stack_subgroup_title "$(_stack_group_display_name heavy)"
  fi
  if [[ "${#HEAVY_STACKS[@]}" -eq 0 ]]; then
    if _quiet_tree_tty; then
      quiet_subnote_dim "(none configured)"
    fi
    log_detail "No heavy stacks configured."
    SUMMARY_STACK_SUB_HEAVY="none configured"
    return 0
  fi

  log_step "stacks: heavy group (${#HEAVY_STACKS[@]} configured)"
  progress_child "Heavy stacks (${#HEAVY_STACKS[@]} in config order)"

  for stack_name in "${HEAVY_STACKS[@]}"; do
    [[ -n "$stack_name" ]] || continue

    if array_contains "$stack_name" "${DEPENDENCY_STACKS[@]}" || array_contains "$stack_name" "${DEPENDENT_STACKS[@]}"; then
      continue
    fi

    _hid="$(get_stack_id_by_name "$stack_name")"
    if [[ -z "$_hid" ]]; then
      log_detail "Heavy stack not on endpoint (skipping): ${stack_name}"
      continue
    fi

    redeploy_stack_by_name "$stack_name" "heavy" || {
      log_warn "Failed redeploying heavy stack '${stack_name}'. Continuing."
      continue
    }

    stack_post_redeploy_wait_for_group "$stack_name" heavy
  done
  quiet_stack_group_summary "$(_stack_group_display_name heavy)" "${STACK_GRP_HEAVY_CHECKED}" "${STACK_GRP_HEAVY_REDEPLOYED}" "${STACK_GRP_HEAVY_FAILED}"
  SUMMARY_STACK_SUB_HEAVY="completed"
}

deploy_remaining_non_heavy_stacks() {
  local stack_name

  if _quiet_tree_tty; then
    printf '\n'
    quiet_stack_subgroup_title "$(_stack_group_display_name remaining)"
  fi
  log_step "stacks: remaining (non-heavy on endpoint)"
  progress_child "Remaining stacks (non-heavy on endpoint)"

  while IFS= read -r stack_name; do
    [[ -n "$stack_name" ]] || continue

    if array_contains "$stack_name" "${DEPENDENCY_STACKS[@]}"; then
      continue
    fi

    if array_contains "$stack_name" "${DEPENDENT_STACKS[@]}"; then
      continue
    fi

    if array_contains "$stack_name" "${HEAVY_STACKS[@]}"; then
      continue
    fi

    redeploy_stack_by_name "$stack_name" "remaining" || {
      log_warn "Failed redeploying ${stack_name}; continuing."
      continue
    }

    stack_post_redeploy_wait_for_group "$stack_name" remaining

  done < <(get_all_stack_names_for_endpoint)
  quiet_stack_group_summary "$(_stack_group_display_name remaining)" "${STACK_GRP_REMAINING_CHECKED}" "${STACK_GRP_REMAINING_REDEPLOYED}" "${STACK_GRP_REMAINING_FAILED}"
  SUMMARY_STACK_SUB_REMAINING="completed"
}

deploy_in_correct_order() {
  init_selective_context
  if [[ -n "${SINGLE_STACK_NAME:-}" ]]; then
    quiet_print_tree_banner_rule "STACK UPDATES"
    log_step "single stack redeploy: ${SINGLE_STACK_NAME}"
    compute_stack_deploy_total
    redeploy_stack_by_name "$SINGLE_STACK_NAME" "remaining" || mark_pipeline_hard_failure
    stack_post_redeploy_wait_for_group "$SINGLE_STACK_NAME" remaining
    finish_progress
    SUMMARY_PHASE_STACKS="completed"
    return 0
  fi
  compute_stack_deploy_total
  quiet_print_tree_banner_rule "STACK UPDATES"
  progress_child "Deploy stacks: dependencies → dependents → heavy → remaining"
  deploy_dependency_stacks
  deploy_dependent_stacks
  deploy_heavy_stacks
  deploy_remaining_non_heavy_stacks
  finish_progress
}

########################################
# PORTAINER SELF-UPDATE
########################################

# Returns 0 when docker pull for Portainer may be skipped: Cup lists this image and .result.has_update is explicitly false.
portainer_should_skip_pull_per_cup() {
  [[ "${PORTAINER_USE_CUP_PRECHECK:-true}" == "true" ]] || return 1
  [[ "${CUP_ENABLED:-false}" == "true" ]] || return 1
  local json ref hasup known
  if [[ -n "${CUP_JSON_SNAPSHOT:-}" ]]; then
    json="$CUP_JSON_SNAPSHOT"
  else
    json="$(cup_fetch_json_document 2>/dev/null)" || return 1
  fi
  [[ -z "$json" ]] && return 1
  while IFS=$'\t' read -r ref hasup known; do
    [[ -z "$ref" ]] && continue
    if _cup_image_refs_equivalent "$ref" "$PORTAINER_IMAGE"; then
      [[ "$known" != "1" ]] && return 1
      [[ "$hasup" == "true" ]] && return 1
      return 0
    fi
  done < <(echo "$json" | jq -r '
    .images[]?
    | select(.reference != null and (.reference | length) > 0)
    | . as $i
    | ($i.reference) as $r
    | (if ($i.result | type) == "object" and ($i.result | has("has_update"))
         then "\($r)\t\($i.result.has_update)\t1"
         else "\($r)\tfalse\t0"
       end)
  ' 2>/dev/null)
  return 1
}

# Pull Portainer image; quiet mode logs full daemon output to LOG_FILE only and shows a short TTY warning on failure.
portainer_docker_pull_image() {
  local tmp ec line
  [[ "$DRY_RUN" == "true" ]] && return 0
  if [[ "${OUTPUT_MODE:-quiet}" == "verbose" ]]; then
    docker pull "$PORTAINER_IMAGE" && return 0
    ec=$?
    RUN_WARNING_COUNT=$((RUN_WARNING_COUNT + 1))
    _emit_log_file_ts "Portainer docker pull failed (exit ${ec}); output was streamed to the terminal during verbose pull."
    log_verbose "Portainer docker pull failed (exit ${ec})."
    return "$ec"
  fi
  quiet_live "docker pull ${PORTAINER_IMAGE}…"
  tmp="$(_mktemp_track)"
  if docker pull "$PORTAINER_IMAGE" >>"$tmp" 2>&1; then
    quiet_live_clear
    rm -f "$tmp"
    return 0
  fi
  ec=$?
  quiet_live_clear
  RUN_WARNING_COUNT=$((RUN_WARNING_COUNT + 1))
  _emit_log_file_ts "Portainer docker pull failed (exit ${ec}); full output:"
  while IFS= read -r line || [[ -n "$line" ]]; do
    _emit_log_file_only "$line"
  done <"$tmp"
  rm -f "$tmp"
  if _quiet_tree_tty; then
    print_warning 2 "Portainer image check failed; keeping existing container"
    print_info 4 "   See log for details."
  else
    _emit_log_file_ts "WARNING: Portainer image check failed; keeping existing container (see ${LOG_FILE})."
    _emit_log_tty "WARNING: Portainer image check failed; keeping existing container (see ${LOG_FILE})."
  fi
  return "$ec"
}

# True when inspect JSON shows non-standard Portainer layout (extra mounts, networks, labels).
portainer_inspect_has_divergence() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  local nmount
  nmount="$(jq -r '.[0].Mounts | length // 0' "$f" 2>/dev/null)"
  [[ "${nmount:-0}" -gt 3 ]] && return 0
  if jq -e '.[0].Mounts[]? | select(.Destination=="/data") | select(.Type=="volume") | select(.Name != "portainer_data" and .Name != null)' "$f" >/dev/null 2>&1; then
    return 0
  fi
  local nm
  nm="$(jq -r '.[0].HostConfig.NetworkMode // "default"' "$f" 2>/dev/null)"
  [[ "$nm" != "default" && "$nm" != "bridge" && -n "$nm" ]] && return 0
  local extra_lbl
  extra_lbl="$(jq -r '.[0].Config.Labels // {} | keys[]' "$f" 2>/dev/null | grep -vcE '^(com\.docker|org\.opencontainers|io\.portainer)' || true)"
  [[ "${extra_lbl:-0}" -gt 0 ]] && return 0
  return 1
}

portainer_divergence_gate() {
  local f="$1"
  portainer_inspect_has_divergence "$f" || return 0
  log_warn "Portainer container has non-standard config (extra mounts, networks, or labels). Recreate may change behavior."
  case "${PORTAINER_RECREATE_ACK_DIVERGENCE:-false}" in
    1 | true | yes) return 0 ;;
  esac
  if [[ -t 0 ]] && [[ "$AUTO_YES" != "true" ]]; then
    if command -v gum >/dev/null 2>&1; then
      gum confirm "Proceed with non-standard Portainer recreate?" --default=false || return 1
      return 0
    fi
    local ans
    read -r -p "Proceed with non-standard Portainer recreate? [y/N] " ans || return 1
    case "${ans,,}" in y | yes) return 0 ;; *) return 1 ;; esac
  fi
  log_warn "Set PORTAINER_RECREATE_ACK_DIVERGENCE=1 to allow non-interactive recreate."
  return 1
}

# Build docker run -d argv from inspect; last element is image ref (caller may override).
portainer_build_run_args_from_inspect() {
  local inspect_file="$1"
  local -n _out=$2
  _out=()
  local restart
  restart="$(jq -r '.[0].HostConfig.RestartPolicy.Name // "always"' "$inspect_file" 2>/dev/null)"
  [[ "$restart" == "no" || -z "$restart" ]] && restart="always"
  _out+=(--name "$PORTAINER_CONTAINER_NAME" --restart="$restart")
  local hp cp has9443=0
  while IFS= read -r hp cp; do
    [[ -z "$hp" || -z "$cp" ]] && continue
    _out+=(-p "${hp}:${cp}")
    [[ "$hp" == "9443" && "$cp" == "9443" ]] && has9443=1
  done < <(jq -r '
    .[0].HostConfig.PortBindings // {}
    | to_entries[]
    | "\(.value[0].HostPort // "") \(.key | split("/")[0])"
  ' "$inspect_file" 2>/dev/null)
  [[ "$has9443" -eq 0 ]] && _out+=(-p "9443:9443")
  [[ "${PORTAINER_ENABLE_EDGE_PORT:-true}" == "true" ]] && _out+=(-p "8000:8000")
  [[ "${PORTAINER_ENABLE_LEGACY_HTTP_PORT:-false}" == "true" ]] && _out+=(-p "9000:9000")
  local mspec
  while IFS= read -r mspec; do
    [[ -n "$mspec" ]] && _out+=(-v "$mspec")
  done < <(jq -r '
    .[0].Mounts[]?
    | if .Type == "volume" and .Name then "\(.Name):\(.Destination)"
      elif .Source then "\(.Source):\(.Destination)"
      else empty end
  ' "$inspect_file" 2>/dev/null)
  if ! printf '%s\n' "${_out[@]}" | grep -q 'docker.sock'; then
    _out+=(-v /var/run/docker.sock:/var/run/docker.sock)
  fi
  if ! printf '%s\n' "${_out[@]}" | grep -q 'portainer_data'; then
    _out+=(-v portainer_data:/data)
  fi
  _out+=("$PORTAINER_IMAGE")
}

portainer_rollback_from_backup() {
  local backup="$1" new="$PORTAINER_CONTAINER_NAME"
  log_detail "Rolling back Portainer: removing failed new container and restoring ${backup}."
  run_docker stop "$new" 2>/dev/null || true
  run_docker rm -f "$new" 2>/dev/null || true
  run_docker rename "$backup" "$new" 2>/dev/null || true
  run_docker start "$new" 2>/dev/null || true
  log_warn "Portainer rolled back to previous container (${new})."
}

portainer_recreate_rollback_safe() {
  local backup="${PORTAINER_CONTAINER_NAME}_su_old"
  local inspect_tmp
  local -a run_args=()
  inspect_tmp="$(_mktemp_track)"
  docker inspect "$PORTAINER_CONTAINER_NAME" >"$inspect_tmp" 2>/dev/null || fail "Cannot inspect Portainer container ${PORTAINER_CONTAINER_NAME}"

  if ! portainer_divergence_gate "$inspect_tmp"; then
    SUMMARY_PHASE_PORTAINER="skipped_config_divergence"
    return 0
  fi

  portainer_build_run_args_from_inspect "$inspect_tmp" run_args
  log_detail "Planned Portainer recreate: docker run -d ${run_args[*]}"

  log_detail "Stopping and renaming ${PORTAINER_CONTAINER_NAME} -> ${backup} (rollback-safe)."
  run_docker stop "$PORTAINER_CONTAINER_NAME" || true
  sleep 2
  run_docker rename "$PORTAINER_CONTAINER_NAME" "$backup" || fail "Portainer rename for rollback failed"

  if ! run_docker run -d "${run_args[@]}"; then
    portainer_rollback_from_backup "$backup"
    mark_pipeline_hard_failure
    fail "Portainer redeploy failed; rolled back to previous container"
  fi

  if ! wait_for_portainer_api 180; then
    portainer_rollback_from_backup "$backup"
    mark_pipeline_hard_failure
    fail "Portainer API unavailable after recreate; rolled back to previous container"
  fi

  run_docker rm -f "$backup" 2>/dev/null || true
  log_detail "Portainer recreate succeeded; removed backup container ${backup}."
}

wait_for_portainer_api() {
  local timeout="${1:-180}"
  local waited=0

  log_detail "Waiting for Portainer API to become available..."

  while [[ "$waited" -lt "$timeout" ]]; do
    if [[ "${OUTPUT_MODE:-quiet}" == "quiet" ]]; then
      quiet_live "Waiting for Portainer API… (${waited}s / ${timeout}s)"
    elif [[ "$waited" -eq 0 ]] || [[ $((waited % 15)) -eq 0 ]]; then
      progress_child "Wait for Portainer API (${waited}s / ${timeout}s)"
    fi
    if api_get "/api/status" >/dev/null 2>&1; then
      quiet_live_clear
      log_step "Portainer API is available"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done

  quiet_live_clear
  fail "Portainer API did not become available within ${timeout}s."
}

update_portainer_container_if_enabled() {
  if [[ "$UPDATE_PORTAINER_CONTAINER" != "true" ]]; then
    log_detail "Skipping Portainer self-update."
    SUMMARY_PHASE_PORTAINER="disabled"
    return 0
  fi

  log_step "Portainer container: pull / recreate"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_detail "DRY RUN: docker pull ${PORTAINER_IMAGE}"
    log_detail "DRY RUN: docker stop/rm/run ${PORTAINER_CONTAINER_NAME}"
    SUMMARY_PHASE_PORTAINER="dry-run"
    return 0
  fi

  local running_id="" container_exists=0 post_pull_id="" skip_pull=0
  if docker inspect "$PORTAINER_CONTAINER_NAME" >/dev/null 2>&1; then
    running_id="$(docker inspect --format '{{.Image}}' "$PORTAINER_CONTAINER_NAME" 2>/dev/null || true)"
    container_exists=1
  fi

  skip_pull=0
  if portainer_should_skip_pull_per_cup; then
    post_pull_id="$(docker image inspect --format '{{.Id}}' "$PORTAINER_IMAGE" 2>/dev/null || true)"
    if [[ -n "$post_pull_id" ]]; then
      skip_pull=1
      log_detail "Portainer: Cup reports ${PORTAINER_IMAGE} current; skipping docker pull."
    fi
  fi
  if [[ "$skip_pull" -eq 1 ]] && [[ -n "$running_id" && -n "$post_pull_id" && "$running_id" != "$post_pull_id" ]]; then
    log_detail "Portainer: running container image ID differs from local despite Cup current; performing docker pull."
    skip_pull=0
    post_pull_id=""
  fi

  if [[ "$skip_pull" -eq 0 ]]; then
    if ! portainer_docker_pull_image; then
      log_detail "Portainer: docker pull failed; keeping existing container."
      SUMMARY_PHASE_PORTAINER="skipped_pull_failed"
      return 0
    fi
    post_pull_id="$(docker image inspect --format '{{.Id}}' "$PORTAINER_IMAGE" 2>/dev/null || true)"
  fi

  if [[ -z "$post_pull_id" ]]; then
    RUN_WARNING_COUNT=$((RUN_WARNING_COUNT + 1))
    log_warn "Portainer: no local image for ${PORTAINER_IMAGE}; skipping redeploy."
    SUMMARY_PHASE_PORTAINER="skipped_pull_failed"
    return 0
  fi

  if [[ "$container_exists" -eq 0 ]]; then
    if ! portainer_backup_gate_before_recreate; then
      log_warn "Portainer: container start blocked by backup policy."
      SUMMARY_PHASE_PORTAINER="skipped_backup_required"
      return 0
    fi
    if [[ "${PORTAINER_REQUIRE_BACKUP_BEFORE_UPDATE:-false}" != "true" ]]; then
      if _quiet_tree_tty; then
        print_warning 2 "Portainer backup recommended before install/upgrade (see Portainer documentation)."
      fi
    fi
    portainer_warn_if_agent_present
    if _quiet_tree_tty; then
      print_info 2 "$(_leg_icon update_available) Portainer image: update available"
    fi
    portainer_quiet_ui_container_begin
    local -a pub_new=()
    pub_new+=(-p "9443:9443")
    [[ "${PORTAINER_ENABLE_EDGE_PORT:-true}" == "true" ]] && pub_new+=(-p "8000:8000")
    [[ "${PORTAINER_ENABLE_LEGACY_HTTP_PORT:-false}" == "true" ]] && pub_new+=(-p "9000:9000")
    log_detail "Starting Portainer (${PORTAINER_IMAGE}) with portainer_data volume..."
    run_docker run -d \
      --name "$PORTAINER_CONTAINER_NAME" \
      --restart=always \
      "${pub_new[@]}" \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v portainer_data:/data \
      "$PORTAINER_IMAGE" \
      || fail "Portainer container start failed"
    wait_for_portainer_api 180
    SUMMARY_PHASE_PORTAINER="ran"
    return 0
  fi

  if [[ -n "$running_id" && "$running_id" == "$post_pull_id" ]]; then
    log_detail "Portainer container already uses image ID for ${PORTAINER_IMAGE}; skipping recreate."
    if [[ "$skip_pull" -eq 1 ]]; then
      SUMMARY_PHASE_PORTAINER="skipped_image_current_cup"
    else
      SUMMARY_PHASE_PORTAINER="skipped_image_current"
    fi
    return 0
  fi

  if ! portainer_backup_gate_before_recreate; then
    log_warn "Portainer recreate skipped: backup not confirmed."
    SUMMARY_PHASE_PORTAINER="skipped_backup_required"
    return 0
  fi

  if [[ "${PORTAINER_REQUIRE_BACKUP_BEFORE_UPDATE:-false}" != "true" ]]; then
    if _quiet_tree_tty; then
      print_warning 2 "Portainer backup recommended before upgrade (see Portainer documentation)."
    fi
  fi

  portainer_warn_if_losing_legacy_http_port
  portainer_warn_if_agent_present

  if _quiet_tree_tty; then
    print_info 2 "$(_leg_icon update_available) Portainer image: update available"
  fi
  portainer_quiet_ui_container_begin
  portainer_recreate_rollback_safe
  SUMMARY_PHASE_PORTAINER="ran"
}

########################################
# CLEANUP
########################################

cleanup_docker() {
  log_step "Docker cleanup (prune)"
  CLEANUP_IMAGE_SUMMARY=""
  CLEANUP_NETWORK_SUMMARY=""
  CLEANUP_VOLUME_SUMMARY=""

  if [[ "$DRY_RUN" == "true" ]]; then
    log_detail "DRY RUN: docker image prune -af"
    log_detail "DRY RUN: docker network prune -f"
    [[ "$PRUNE_UNUSED_VOLUMES" == "true" ]] && log_detail "DRY RUN: docker volume prune -f"
    SUMMARY_PHASE_CLEANUP="dry-run"
    return 0
  fi

  if [[ "$PRUNE_UNUSED_IMAGES" == "true" ]]; then
    log_detail "Pruning unused images only. Volumes are untouched."
    local imo
    if [[ -n "${PRUNE_IMAGES_UNTIL:-}" ]]; then
      imo="$(run_docker image prune -af --filter "until=${PRUNE_IMAGES_UNTIL}" 2>&1)" || true
    else
      imo="$(run_docker image prune -af 2>&1)" || true
    fi
    [[ -n "$imo" ]] && log_detail "docker image prune output (tail): $(echo "$imo" | tail -3)"
    CLEANUP_IMAGE_SUMMARY="$(printf '%s\n' "$imo" | grep -i 'Total reclaimed' | tail -n 1 | sed 's/^[[:space:]]*//' || true)"
    [[ -z "$CLEANUP_IMAGE_SUMMARY" ]] && CLEANUP_IMAGE_SUMMARY="$(printf '%s\n' "$imo" | grep -i 'deleted' | tail -n 1 | sed 's/^[[:space:]]*//' || true)"
    [[ -z "$CLEANUP_IMAGE_SUMMARY" ]] && CLEANUP_IMAGE_SUMMARY="$(printf '%s\n' "$imo" | tail -n 1 | sed 's/^[[:space:]]*//' || true)"
    [[ -z "$CLEANUP_IMAGE_SUMMARY" ]] && CLEANUP_IMAGE_SUMMARY="Image prune completed (no summary line from docker)."
  fi

  if [[ "$PRUNE_UNUSED_NETWORKS" == "true" ]]; then
    log_detail "Pruning unused networks."
    local nmo
    nmo="$(run_docker network prune -f 2>&1)" || true
    [[ -n "$nmo" ]] && log_detail "docker network prune output (tail): $(echo "$nmo" | tail -3)"
    if _docker_network_prune_no_removals "$nmo"; then
      CLEANUP_NETWORK_SUMMARY="__NO_CHANGE__"
    else
      CLEANUP_NETWORK_SUMMARY="$(printf '%s\n' "$nmo" | grep -E 'Deleted Networks|Total reclaimed' | tail -n 1 | sed 's/^[[:space:]]*//' || true)"
      [[ -z "$CLEANUP_NETWORK_SUMMARY" ]] && CLEANUP_NETWORK_SUMMARY="$(printf '%s\n' "$nmo" | tail -n 1 | sed 's/^[[:space:]]*//' || true)"
      [[ -z "$CLEANUP_NETWORK_SUMMARY" ]] && CLEANUP_NETWORK_SUMMARY="Network prune completed (no summary line from docker)."
    fi
  fi

  if [[ "$PRUNE_UNUSED_VOLUMES" == "true" ]]; then
    log_detail "Pruning unused Docker volumes (only volumes not referenced by any container)."
    local vmo
    vmo="$(run_docker volume prune -f 2>&1)" || true
    [[ -n "$vmo" ]] && log_detail "docker volume prune output (tail): $(echo "$vmo" | tail -3)"
    if _docker_volume_prune_no_removals "$vmo"; then
      CLEANUP_VOLUME_SUMMARY="__NO_CHANGE__"
    else
      CLEANUP_VOLUME_SUMMARY="$(printf '%s\n' "$vmo" | grep -iE 'Deleted Volumes|Total reclaimed' | tail -n 1 | sed 's/^[[:space:]]*//' || true)"
      [[ -z "$CLEANUP_VOLUME_SUMMARY" ]] && CLEANUP_VOLUME_SUMMARY="$(printf '%s\n' "$vmo" | tail -n 1 | sed 's/^[[:space:]]*//' || true)"
      [[ -z "$CLEANUP_VOLUME_SUMMARY" ]] && CLEANUP_VOLUME_SUMMARY="Volume prune completed (no summary line from docker)."
    fi
  fi

  SUMMARY_PHASE_CLEANUP="ran"
}

########################################
# PROMPTS / PHASES
########################################

prompt_stack_update_confirmation() {
  [[ "$STACK_UPDATE_PROMPT" != "true" ]] && return 0
  [[ "$AUTO_YES" == "true" ]] && return 0

  if [[ ! -t 0 ]]; then
    fail "STACK_UPDATE_PROMPT=true requires a TTY or use --yes for non-interactive runs."
  fi

  report_cup_summary || true

  local ans
  read -r -p "Proceed with Portainer stack redeploys? [y/N] " ans || true
  case "${ans,,}" in
    y | yes) return 0 ;;
    *) fail "Aborted before stack redeploy." ;;
  esac
}

normalize_phase_list() {
  local -A seen=()
  local p c
  for c in "${CANONICAL_PHASE_ORDER[@]}"; do
    for p in "${PHASE_QUEUE[@]}"; do
      if [[ "$p" == "$c" ]] && [[ -z "${seen[$c]:-}" ]]; then
        seen[$c]=1
        echo "$c"
      fi
    done
  done
}

run_phases_temp() {
  PHASE_QUEUE=("$@")
  run_phases_list "$(normalize_phase_list)"
}

confirm_tui_action() {
  local summary="$1"
  [[ "$AUTO_YES" == "true" ]] && return 0
  if command -v gum >/dev/null 2>&1; then
    gum confirm --default=false "$summary" || user_cancel_exit
    return 0
  fi
  local ans
  read -r -p "$summary [y/N] " ans || user_cancel_exit
  case "${ans,,}" in
    y | yes) return 0 ;;
    *) user_cancel_exit ;;
  esac
}

confirm_menu_action_unless_stepping() {
  [[ "${CONFIRM_EACH_STEP:-false}" == "true" ]] && return 0
  confirm_tui_action "$1"
}

run_tui_session_minimal() {
  local header="stack-updater v${STACK_UPDATER_VERSION} — session output"
  if command -v gum >/dev/null 2>&1; then
    local outmode confmode
    outmode="$(gum choose --header "$header" \
      "Quiet — minimal TTY: checklist + colors (default)" \
      "Verbose — full detail + streamed package/docker commands")" || outmode=""
    [[ -z "$outmode" ]] && outmode="Quiet — minimal TTY: checklist + colors (default)"
    case "$outmode" in
      *Verbose*) OUTPUT_MODE="verbose" ;;
      *) OUTPUT_MODE="quiet" ;;
    esac
    if [[ "$OUTPUT_MODE" == "verbose" ]]; then
      VERBOSE="true"
    else
      VERBOSE="false"
    fi
    confmode="$(gum choose --header "Confirmations for this session" "No extra prompts before phases (default)" "Confirm before each major step")" || confmode=""
    [[ -z "$confmode" ]] && confmode="No extra prompts before phases (default)"
    case "$confmode" in
      *Confirm*) CONFIRM_EACH_STEP="true" ;;
      *) CONFIRM_EACH_STEP="false" ;;
    esac
    return 0
  fi
  echo "$header"
  local om c
  echo "  1) Quiet (default)   2) Verbose"
  read -r -p "Output level [1-2]: " om || true
  case "${om:-1}" in
    2) OUTPUT_MODE="verbose" ;;
    *) OUTPUT_MODE="quiet" ;;
  esac
  if [[ "$OUTPUT_MODE" == "verbose" ]]; then
    VERBOSE="true"
  else
    VERBOSE="false"
  fi
  read -r -p "Confirm before each step? [y/N] " c || true
  case "${c,,}" in y | yes) CONFIRM_EACH_STEP="true" ;; *) CONFIRM_EACH_STEP="false" ;; esac
  return 0
}

run_tui_expert_pipeline_shell() {
  echo "Quiet tree: 1) always+emoji (default)  2) auto+check  3) never"
  local c yn
  read -r -p "Appearance [1-3]: " c || true
  case "${c:-1}" in
    2) STACK_UPDATER_COLOR="auto"; STACK_UPDATER_DONE_MARK="check" ;;
    3) STACK_UPDATER_COLOR="never"; STACK_UPDATER_DONE_MARK="check" ;;
    *) STACK_UPDATER_COLOR="always"; STACK_UPDATER_DONE_MARK="emoji" ;;
  esac
  echo "Pipeline flags (y/N, Enter = keep current):"
  read -r -p "Upgrade host packages? [Y/n]: " yn || true
  case "${yn,,}" in n | no) UPDATE_HOST_PACKAGES="false" ;; esac
  read -r -p "Upgrade Docker-related packages? [Y/n]: " yn || true
  case "${yn,,}" in n | no) UPDATE_DOCKER_PACKAGES="false" ;; esac
  read -r -p "Recreate Portainer if image changed? [Y/n]: " yn || true
  case "${yn,,}" in n | no) UPDATE_PORTAINER_CONTAINER="false" ;; esac
  read -r -p "Prune unused images after stacks? [Y/n]: " yn || true
  case "${yn,,}" in n | no) PRUNE_UNUSED_IMAGES="false" ;; esac
  read -r -p "Prune unused networks? [Y/n]: " yn || true
  case "${yn,,}" in n | no) PRUNE_UNUSED_NETWORKS="false" ;; esac
  read -r -p "Prune unused Docker volumes? [Y/n] (can delete data if a volume is unused): " yn || true
  case "${yn,,}" in n | no) PRUNE_UNUSED_VOLUMES="false" ;; esac
  read -r -p "SKIP host apt if nothing to upgrade? [y/N]: " yn || true
  case "${yn,,}" in y | yes) SKIP_HOST_IF_NONE="true" ;; esac
  read -r -p "SKIP Docker pkgs if nothing? [y/N]: " yn || true
  case "${yn,,}" in y | yes) SKIP_DOCKER_PKGS_IF_NONE="true" ;; esac
  read -r -p "SKIP stack phase if Cup reports 0 outdated? [y/N]: " yn || true
  case "${yn,,}" in y | yes) SKIP_STACK_PHASE_IF_CUP_CLEAN="true" ;; esac
  read -r -p "SKIP cleanup when stacks skipped (Cup gate)? [Y/n]: " yn || true
  case "${yn,,}" in n | no) SKIP_CLEANUP_IF_STACKS_SKIPPED="false" ;; esac
  read -r -p "Prompt before stack redeploys? [y/N]: " yn || true
  case "${yn,,}" in y | yes) STACK_UPDATE_PROMPT="true" ;; esac
  read -r -p "Selective redeploy (digest/Cup)? [Y/n]: " yn || true
  case "${yn,,}" in n | no) SELECTIVE_STACK_REDEPLOY="false" ;; *) SELECTIVE_STACK_REDEPLOY="true" ;; esac
  read -r -p "Redeploy git stacks when Cup unknown (selective)? [Y/n]: " yn || true
  case "${yn,,}" in n | no) REDEPLOY_GIT_STACKS_IF_CUP_UNKNOWN="false" ;; esac
  read -r -p "Registry policy strict (else safe)? [y/N]: " yn || true
  case "${yn,,}" in y | yes) REGISTRY_FAIL_POLICY="strict" ;; *) REGISTRY_FAIL_POLICY="safe" ;; esac
}

run_tui_expert_gum() {
  local appear preset
  appear="$(gum choose --header "Quiet tree appearance (this session)" \
    "Color always + emoji done row (default)" \
    "Respect NO_COLOR (auto) + checkmark" \
    "No ANSI colors (never)" \
    "Back")" || appear=""
  [[ -z "$appear" || "$appear" == "Back" ]] && return 0
  case "$appear" in
    *auto*) STACK_UPDATER_COLOR="auto"; STACK_UPDATER_DONE_MARK="check" ;;
    *never*) STACK_UPDATER_COLOR="never"; STACK_UPDATER_DONE_MARK="check" ;;
    *) STACK_UPDATER_COLOR="always"; STACK_UPDATER_DONE_MARK="emoji" ;;
  esac
  preset="$(gum choose --header "Pipeline & skip behavior (session)" \
    "Full script defaults (typical homelab)" \
    "Enable selective stack redeploy (Cup / digest)" \
    "Enable skip-if-clean (host, Docker pkgs when nothing to upgrade)" \
    "Skip stack phase when Cup reports zero image updates" \
    "Prompt before Portainer stack redeploys" \
    "Expert: set each flag" \
    "Back")" || preset=""
  [[ -z "$preset" || "$preset" == "Back" ]] && return 0
  case "$preset" in
    *selective*)
      SELECTIVE_STACK_REDEPLOY="true"
      ;;
    *skip-if-clean*)
      SKIP_HOST_IF_NONE="true"
      SKIP_DOCKER_PKGS_IF_NONE="true"
      ;;
    *Cup\ reports*)
      SKIP_STACK_PHASE_IF_CUP_CLEAN="true"
      ;;
    *Prompt\ before*)
      STACK_UPDATE_PROMPT="true"
      ;;
    *Expert*)
      _run_tui_pipeline_expert_gum
      ;;
  esac
}

run_tui_expert_options() {
  if command -v gum >/dev/null 2>&1; then
    run_tui_expert_gum || true
  else
    run_tui_expert_pipeline_shell || true
  fi
  return 0
}

SCHEDULE_CRON_MARKER="# stack-updater-managed"
SCHEDULE_SYSTEMD_MARKER="stack-updater-managed"

_stack_updater_script_abs() {
  printf '%s/stack-updater.sh' "$SCRIPT_DIR"
}

_stack_updater_cron_line() {
  local sched="$1" out quiet
  out="${OUTPUT_MODE:-quiet}"
  quiet="${2:-quiet}"
  [[ -n "$quiet" ]] && out="$quiet"
  printf '%s\n' "${SCHEDULE_CRON_MARKER}"
  printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
  printf 'CONFIG_FILE=%s LOG_FILE=%s\n' "$CONFIG_FILE" "${LOG_FILE:-$SCRIPT_DIR/stack-updater.log}"
  printf '%s flock -n %s %s --batch --yes --output %s\n' \
    "$sched" "${LOCK_FILE:-$SCRIPT_DIR/.stack-updater.lock}" \
    "$(_stack_updater_script_abs)" "$out"
}

_schedule_preset_to_cron() {
  case "$1" in
    daily_0400) printf '%s' '0 4 * * *' ;;
    weekly_sun_0400) printf '%s' '0 4 * * 0' ;;
    monthly_1st_0400) printf '%s' '0 4 1 * *' ;;
    *) printf '%s' "$1" ;;
  esac
}

_schedule_preset_to_systemd_calendar() {
  case "$1" in
    daily_0400) printf '%s' '*-*-* 04:00:00' ;;
    weekly_sun_0400) printf '%s' 'Sun *-*-* 04:00:00' ;;
    monthly_1st_0400) printf '%s' '*-*-01 04:00:00' ;;
    *) printf '%s' '*-*-* 04:00:00' ;;
  esac
}

_show_managed_cron_schedule() {
  local cr
  if ! cr="$(crontab -l 2>/dev/null)"; then
    printf '%s\n' "No user crontab or crontab unavailable."
    return 0
  fi
  if grep -q "${SCHEDULE_CRON_MARKER}" <<<"$cr"; then
    printf '%s\n' "--- Managed cron entries ---"
    awk -v m="$SCHEDULE_CRON_MARKER" '$0 ~ m || f {print; f=($0 ~ m)}' <<<"$cr"
  else
    printf '%s\n' "No managed cron entry (${SCHEDULE_CRON_MARKER})."
  fi
}

_show_managed_systemd_schedule() {
  local unit="/etc/systemd/system/stack-updater.timer"
  if [[ -f "$unit" ]]; then
    printf '%s\n' "--- stack-updater.timer ---"
    cat "$unit"
    [[ -f /etc/systemd/system/stack-updater.service ]] && printf '\n%s\n' "--- stack-updater.service ---" && cat /etc/systemd/system/stack-updater.service
  else
    printf '%s\n' "No systemd timer at ${unit}"
  fi
}

_install_managed_cron() {
  local sched="$1" line existing tmp
  sched="$(_schedule_preset_to_cron "$sched")"
  stack_updater_cron_valid "$sched" || fail "Invalid cron schedule: ${sched}"
  line="$(_stack_updater_cron_line "$sched")"
  existing="$(crontab -l 2>/dev/null | grep -v "${SCHEDULE_CRON_MARKER}" | grep -v 'stack-updater.sh' | grep -v 'flock -n.*stack-updater' || true)"
  tmp="$(_mktemp_track)"
  { printf '%s\n' "$existing"; printf '%s\n' "$line"; } >"$tmp"
  printf '%s\n' "Will install crontab entry:"
  printf '%s\n' "$line"
  confirm_menu_action_unless_stepping "Install/update root/user crontab with the line above?"
  crontab "$tmp"
  printf '%s\n' "Cron schedule installed."
}

_install_managed_systemd() {
  local preset="$1" cal svc timer
  cal="$(_schedule_preset_to_systemd_calendar "$preset")"
  svc="/etc/systemd/system/stack-updater.service"
  timer="/etc/systemd/system/stack-updater.timer"
  printf '%s\n' "Will write ${svc} and ${timer} (requires root)."
  confirm_menu_action_unless_stepping "Install systemd timer (${cal})?"
  sudo tee "$svc" >/dev/null <<EOF
[Unit]
Description=${SCHEDULE_SYSTEMD_MARKER} Stack Updater
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=CONFIG_FILE=${CONFIG_FILE}
Environment=LOG_FILE=${LOG_FILE:-$SCRIPT_DIR/stack-updater.log}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/bin/flock -n ${LOCK_FILE:-$SCRIPT_DIR/.stack-updater.lock} $(_stack_updater_script_abs) --batch --yes --output quiet
EOF
  sudo tee "$timer" >/dev/null <<EOF
[Unit]
Description=${SCHEDULE_SYSTEMD_MARKER} Stack Updater timer

[Timer]
OnCalendar=${cal}
Persistent=true

[Install]
WantedBy=timers.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now stack-updater.timer
  printf '%s\n' "Systemd timer enabled."
}

_remove_managed_cron() {
  local existing tmp
  existing="$(crontab -l 2>/dev/null | grep -v "${SCHEDULE_CRON_MARKER}" | grep -v 'stack-updater.sh' | grep -v 'flock -n.*stack-updater' || true)"
  tmp="$(_mktemp_track)"
  printf '%s' "$existing" >"$tmp"
  crontab "$tmp" 2>/dev/null || crontab -r 2>/dev/null || true
  printf '%s\n' "Removed managed cron entries."
}

_remove_managed_systemd() {
  sudo systemctl disable --now stack-updater.timer 2>/dev/null || true
  sudo rm -f /etc/systemd/system/stack-updater.service /etc/systemd/system/stack-updater.timer
  sudo systemctl daemon-reload 2>/dev/null || true
  printf '%s\n' "Removed stack-updater systemd units."
}

_pick_schedule_preset() {
  local p
  if command -v gum >/dev/null 2>&1; then
    p="$(gum choose --header "Schedule preset" \
      "daily_0400" "weekly_sun_0400" "monthly_1st_0400" "custom_cron" "Back")" || p=""
    [[ "$p" == "Back" || -z "$p" ]] && return 1
    if [[ "$p" == "custom_cron" ]]; then
      p="$(gum input --placeholder "0 4 * * *" --header "5-field cron expression")" || return 1
    fi
    printf '%s' "$p"
    return 0
  fi
  echo " 1) Daily 04:00  2) Weekly Sun 04:00  3) Monthly 1st 04:00  4) Custom cron  5) Back" >&2
  read -r -p "Preset [1-5]: " p || return 1
  case "$p" in
    1) printf '%s' 'daily_0400' ;;
    2) printf '%s' 'weekly_sun_0400' ;;
    3) printf '%s' 'monthly_1st_0400' ;;
    4) read -r -p "Cron expression: " p && printf '%s' "$p" ;;
    *) return 1 ;;
  esac
}

manage_scheduled_runs() {
  local action backend preset
  if command -v gum >/dev/null 2>&1; then
    action="$(gum choose --header "Manage scheduled runs" \
      "Install/update schedule" "Show current schedule" "Remove schedule" "Back")" || action=""
  else
    echo " 1) Install/update  2) Show  3) Remove  4) Back" >&2
    read -r -p "Choice: " action || action=""
    case "$action" in
      1) action="Install/update schedule" ;;
      2) action="Show current schedule" ;;
      3) action="Remove schedule" ;;
      *) action="Back" ;;
    esac
  fi
  [[ -z "$action" || "$action" == "Back" ]] && return 0
  case "$action" in
    "Show current schedule")
      _show_managed_cron_schedule
      _show_managed_systemd_schedule
      return 0
      ;;
    "Remove schedule")
      if command -v gum >/dev/null 2>&1; then
        backend="$(gum choose "cron" "systemd" "both")" || backend=""
      else
        read -r -p "Remove cron, systemd, or both? " backend || backend=""
      fi
      case "${backend,,}" in
        cron) _remove_managed_cron ;;
        systemd) _remove_managed_systemd ;;
        *) _remove_managed_cron; _remove_managed_systemd ;;
      esac
      return 0
      ;;
  esac
  if command -v gum >/dev/null 2>&1; then
    backend="$(gum choose --header "Scheduler backend (equal choice)" "cron" "systemd")" || backend=""
  else
    read -r -p "Backend (cron/systemd): " backend || backend=""
  fi
  [[ -z "$backend" ]] && return 0
  preset="$(_pick_schedule_preset)" || return 0
  case "${backend,,}" in
    systemd)
      if [[ ! -d /run/systemd/system ]] && [[ ! -d /run/systemd ]]; then
        log_warn "systemd does not appear to be PID 1; consider cron for LXC/minimal containers."
      fi
      _install_managed_systemd "$preset"
      ;;
    *)
      _install_managed_cron "$preset"
      ;;
  esac
}

_pick_action_menu_choice() {
  local hdr choice_raw
  hdr=$'Portainer stack updater — select action\nPhase actions may show more diagnostic output.'
  if command -v gum >/dev/null 2>&1; then
    choice_raw="$(gum choose --header "$hdr" \
      "Report only (no changes)" \
      "Run full update (all phases)" \
      "Dry-run full update (log only)" \
      "Phase: Host packages" \
      "Phase: Docker packages" \
      "Phase: Portainer container" \
      "Phase: Cup diagnostics" \
      "Phase: Stacks" \
      "Phase: Docker cleanup" \
      "Manage scheduled runs" \
      "Expert/session options" \
      "Exit")" || choice_raw=""
    printf '%s' "${choice_raw:-}"
    return 0
  fi
  printf '%s\n' "$hdr" >&2
  echo "  1) Report only (no changes)     2) Run full update (all phases)    3) Dry-run full update (log only)" >&2
  echo "  4) Phase: Host packages         5) Phase: Docker packages          6) Phase: Portainer container" >&2
  echo "  7) Phase: Cup diagnostics       8) Phase: Stacks                   9) Phase: Docker cleanup" >&2
  echo " 10) Manage scheduled runs      11) Expert/session options      12) Exit" >&2
  read -r -p "Choice [1-12]: " choice_raw || choice_raw=""
  case "${choice_raw:-}" in
    1) printf '%s' "Report only (no changes)" ;;
    2) printf '%s' "Run full update (all phases)" ;;
    3) printf '%s' "Dry-run full update (log only)" ;;
    4) printf '%s' "Phase: Host packages" ;;
    5) printf '%s' "Phase: Docker packages" ;;
    6) printf '%s' "Phase: Portainer container" ;;
    7) printf '%s' "Phase: Cup diagnostics" ;;
    8) printf '%s' "Phase: Stacks" ;;
    9) printf '%s' "Phase: Docker cleanup" ;;
    10) printf '%s' "Manage scheduled runs" ;;
    11) printf '%s' "Expert/session options" ;;
    12 | "") printf '%s' "Exit" ;;
    *) printf '%s' "Exit" ;;
  esac
}

_run_tui_pipeline_expert_gum() {
  gum confirm "Upgrade host packages?" --default=true && UPDATE_HOST_PACKAGES="true" || UPDATE_HOST_PACKAGES="false"
  gum confirm "Upgrade Docker-related packages?" --default=true && UPDATE_DOCKER_PACKAGES="true" || UPDATE_DOCKER_PACKAGES="false"
  gum confirm "Recreate Portainer container when image updates?" --default=true && UPDATE_PORTAINER_CONTAINER="true" || UPDATE_PORTAINER_CONTAINER="false"
  gum confirm "Prune unused images in cleanup?" --default=true && PRUNE_UNUSED_IMAGES="true" || PRUNE_UNUSED_IMAGES="false"
  gum confirm "Prune unused networks?" --default=true && PRUNE_UNUSED_NETWORKS="true" || PRUNE_UNUSED_NETWORKS="false"
  gum confirm "Prune unused Docker volumes? (unused only; can delete data if volumes become unused)" --default=false && PRUNE_UNUSED_VOLUMES="true" || PRUNE_UNUSED_VOLUMES="false"
  gum confirm "SKIP host apt when dry-run sim shows nothing?" --default=false && SKIP_HOST_IF_NONE="true" || SKIP_HOST_IF_NONE="false"
  gum confirm "SKIP Docker pkgs when sim shows nothing?" --default=false && SKIP_DOCKER_PKGS_IF_NONE="true" || SKIP_DOCKER_PKGS_IF_NONE="false"
  gum confirm "SKIP entire stacks phase when Cup reports 0 outdated?" --default=false && SKIP_STACK_PHASE_IF_CUP_CLEAN="true" || SKIP_STACK_PHASE_IF_CUP_CLEAN="false"
  gum confirm "SKIP cleanup when stacks phase skipped (Cup gate)?" --default=true && SKIP_CLEANUP_IF_STACKS_SKIPPED="true" || SKIP_CLEANUP_IF_STACKS_SKIPPED="false"
  gum confirm "Prompt before Portainer stack redeploys?" --default=false && STACK_UPDATE_PROMPT="true" || STACK_UPDATE_PROMPT="false"
  gum confirm "Selective stack redeploy (Cup / digest)?" --default=true && SELECTIVE_STACK_REDEPLOY="true" || SELECTIVE_STACK_REDEPLOY="false"
  gum confirm "Redeploy git stacks when Cup unknown (with selective)?" --default=true && REDEPLOY_GIT_STACKS_IF_CUP_UNKNOWN="true" || REDEPLOY_GIT_STACKS_IF_CUP_UNKNOWN="false"
  local pol
  pol="$(gum choose --header "Registry fail policy (selective, no Cup)" "safe (default)" "strict")" || pol="safe (default)"
  case "$pol" in
    *strict*) REGISTRY_FAIL_POLICY="strict" ;;
    *) REGISTRY_FAIL_POLICY="safe" ;;
  esac
}

run_tui_menu() {
  run_tui_session_minimal
  local choice
  while true; do
    choice="$(_pick_action_menu_choice)" || choice=""
    [[ -z "$choice" ]] && continue
    case "$choice" in
      "Exit")
        exit 0
        ;;
      "Manage scheduled runs")
        manage_scheduled_runs || true
        continue
        ;;
      "Expert/session options")
        run_tui_expert_options || true
        continue
        ;;
      "Report only (no changes)")
        generate_report
        continue
        ;;
      "Run full update (all phases)")
        confirm_menu_action_unless_stepping "Run full update on this host?"
        execute_full_pipeline
        exit "${LAST_PIPELINE_EXIT_CODE:-0}"
        ;;
      "Phase: Host packages")
        confirm_menu_action_unless_stepping "Run host package upgrade phase?"
        run_phases_temp host
        exit "${LAST_PIPELINE_EXIT_CODE:-0}"
        ;;
      "Phase: Docker packages")
        confirm_menu_action_unless_stepping "Upgrade Docker-related apt packages?"
        run_phases_temp docker_pkgs
        exit "${LAST_PIPELINE_EXIT_CODE:-0}"
        ;;
      "Phase: Portainer container")
        confirm_menu_action_unless_stepping "Recreate Portainer container if image changed?"
        run_phases_temp portainer
        exit "${LAST_PIPELINE_EXIT_CODE:-0}"
        ;;
      "Phase: Stacks")
        confirm_menu_action_unless_stepping "Redeploy all stacks via Portainer API?"
        run_phases_temp stacks
        exit "${LAST_PIPELINE_EXIT_CODE:-0}"
        ;;
      "Phase: Cup diagnostics")
        confirm_menu_action_unless_stepping "Run Cup API self-test (refresh + JSON + stack match hints)?"
        run_phases_temp cup
        exit "${LAST_PIPELINE_EXIT_CODE:-0}"
        ;;
      "Phase: Docker cleanup")
        confirm_menu_action_unless_stepping "Run docker image/network/volume prune per config?"
        run_phases_temp cleanup
        exit "${LAST_PIPELINE_EXIT_CODE:-0}"
        ;;
      "Dry-run full update (log only)")
        DRY_RUN="true"
        confirm_menu_action_unless_stepping "Dry-run full pipeline (no mutations)?"
        execute_full_pipeline
        exit "${LAST_PIPELINE_EXIT_CODE:-0}"
        ;;
      *)
        continue
        ;;
    esac
  done
}

run_stacks_phase_with_cup_gate() {
  STACK_PHASE_SKIPPED_DUE_CUP=false
  if should_skip_stack_phase_for_cup; then
    STACK_PHASE_SKIPPED_DUE_CUP=true
    SUMMARY_PHASE_STACKS="skipped_no_cup_updates"
    log_step "stacks: skipped (Cup reports no image updates; SKIP_STACK_PHASE_IF_CUP_CLEAN=true)"
    quiet_print_tree_banner_rule "STACK UPDATES"
    quiet_subnote_dim "Stacks phase skipped (Cup reports no image updates; SKIP_STACK_PHASE_IF_CUP_CLEAN)."
    return 0
  fi
  _emit_log_file_ts "[pipeline] stacks phase starting"
  prompt_stack_update_confirmation
  deploy_in_correct_order
  SUMMARY_PHASE_STACKS="completed"
}

maybe_cleanup_after_stack_phase() {
  if [[ "${SKIP_CLEANUP_IF_STACKS_SKIPPED:-true}" == "true" ]] && [[ "$STACK_PHASE_SKIPPED_DUE_CUP" == "true" ]]; then
    SUMMARY_PHASE_CLEANUP="skipped_no_stack_redeploys"
    log_step "cleanup: skipped (SKIP_CLEANUP_IF_STACKS_SKIPPED and stacks phase skipped)"
    return 0
  fi
  cleanup_docker || {
    SUMMARY_PHASE_CLEANUP="failed"
    RUN_WARNING_COUNT=$((RUN_WARNING_COUNT + 1))
    log_warn "Docker cleanup failed; continuing to run summary."
    return 0
  }
}

_pipeline_had_updates() {
  [[ "${#STACKS_REDEPLOYED[@]}" -gt 0 ]] && return 0
  [[ "${SUMMARY_PHASE_HOST:-}" == "ran" ]] && return 0
  [[ "${SUMMARY_PHASE_DOCKER_PKGS:-}" == "ran" ]] && return 0
  [[ "${SUMMARY_PHASE_PORTAINER:-}" == "ran" ]] && return 0
  return 1
}

run_stack_updater_notifications() {
  local status summary nf send=0
  nf="$(_count_redeploy_failed_in_notes)"
  if [[ "${nf:-0}" -gt 0 || "${PIPELINE_HARD_FAILURE:-0}" -eq 1 ]]; then
    status="failure"
    [[ "${NOTIFY_ON_FAILURE:-true}" == "true" ]] && send=1
  else
    status="success"
    [[ "${NOTIFY_ON_SUCCESS:-false}" == "true" ]] && _pipeline_had_updates && send=1
  fi
  [[ "$send" -eq 1 ]] || return 0
  summary="stacks_redeployed=${#STACKS_REDEPLOYED[@]} warnings=${RUN_WARNING_COUNT:-0}"
  export STACK_UPDATER_STATUS="$status" STACK_UPDATER_SUMMARY="$summary" LOG_FILE
  if [[ -n "${NOTIFY_COMMAND:-}" ]]; then
    bash -c "${NOTIFY_COMMAND}" 2>/dev/null || log_warn "NOTIFY_COMMAND failed"
  fi
  if [[ -n "${NOTIFY_WEBHOOK_URL:-}" ]]; then
    curl -sS --max-time 15 -X POST "${NOTIFY_WEBHOOK_URL}" \
      -H 'Content-Type: application/json' \
      -d "{\"title\":\"Stack Updater\",\"message\":\"${status}: ${summary}\",\"status\":\"${status}\"}" \
      >/dev/null 2>&1 || log_warn "NOTIFY_WEBHOOK_URL POST failed"
  fi
}

_count_redeploy_failed_in_notes() {
  local n=0 r
  for r in "${STACKS_SKIPPED_REASONS[@]}"; do
    [[ "${r#*|}" == "redeploy_failed" ]] && n=$((n + 1))
  done
  printf '%s' "$n"
}

_phase_secs_fmt_or_dash() {
  [[ -z "${1:-}" ]] && printf '%s' '—' && return
  _format_mm_ss "$1"
}

# RUN SUMMARY container rows only: pre-run Cup snapshot (CUP_RUN_* / LAST_*). Never CUP_POST_*.
_run_summary_resolve_cup_counts() {
  local dash="—"
  if [[ "${CUP_ENABLED:-false}" != "true" ]]; then
    printf '%s' "${dash}|${dash}|${dash}|${dash}"
    return 0
  fi
  if [[ "${CUP_RUN_METRICS_LOCKED:-false}" == "true" ]]; then
    printf '%s' "$(_cup_sanitize_count "${CUP_RUN_TRACKED:-0}")|$(_cup_sanitize_count "${CUP_RUN_OUTDATED:-0}")|$(_cup_sanitize_count "${CUP_RUN_CURRENT:-0}")|$(_cup_sanitize_count "${CUP_RUN_UNKNOWN:-0}")"
    return 0
  fi
  if [[ "${CUP_STATUS:-}" == "ok" ]] &&
    [[ "${LAST_CUP_TRACKED:-}" =~ ^[0-9]+$ ]] &&
    [[ "${LAST_CUP_OUTDATED:-}" =~ ^[0-9]+$ ]] &&
    [[ "${LAST_CUP_CURRENT:-}" =~ ^[0-9]+$ ]] &&
    [[ "${LAST_CUP_UNKNOWN:-}" =~ ^[0-9]+$ ]]; then
    printf '%s' "$(_cup_sanitize_count "${LAST_CUP_TRACKED}")|$(_cup_sanitize_count "${LAST_CUP_OUTDATED}")|$(_cup_sanitize_count "${LAST_CUP_CURRENT}")|$(_cup_sanitize_count "${LAST_CUP_UNKNOWN}")"
    return 0
  fi
  printf '%s' "${dash}|${dash}|${dash}|${dash}"
}

print_run_summary() {
  local _sum_banner="======================== RUN SUMMARY ========================"
  local s name reason glyph line elapsed end_ts nf nr checked_sum unchanged_ct skipped_ct total_elapsed
  local _cup_tr _cup_ou _cup_cu _cup_un
  nf="$(_count_redeploy_failed_in_notes)"
  nr="${#STACKS_REDEPLOYED[@]}"
  checked_sum=$((STACK_GRP_DEP_CHECKED + STACK_GRP_DEPENDENT_CHECKED + STACK_GRP_HEAVY_CHECKED + STACK_GRP_REMAINING_CHECKED))
  unchanged_ct=0
  skipped_ct=0
  for s in "${STACKS_SKIPPED_REASONS[@]}"; do
    [[ "$s" != *"|"* ]] && continue
    reason="${s#*|}"
    case "$reason" in
      excluded | dependency_not_found) skipped_ct=$((skipped_ct + 1)) ;;
      redeploy_failed) ;;
      dry-run_planned) unchanged_ct=$((unchanged_ct + 1)) ;;
      selective_* ) unchanged_ct=$((unchanged_ct + 1)) ;;
      *) ;;
    esac
  done

  IFS='|' read -r _cup_tr _cup_ou _cup_cu _cup_un <<<"$(_run_summary_resolve_cup_counts)"

  LAST_PIPELINE_EXIT_CODE=0
  [[ "${nf:-0}" -gt 0 ]] && LAST_PIPELINE_EXIT_CODE=1
  [[ "${PIPELINE_HARD_FAILURE:-0}" -eq 1 ]] && LAST_PIPELINE_EXIT_CODE=1
  if [[ "${EXIT_WARNINGS_AS_FAILURE:-false}" == "true" ]] && [[ "${RUN_WARNING_COUNT:-0}" -gt 0 ]]; then
    LAST_PIPELINE_EXIT_CODE=1
  fi
  run_stack_updater_notifications

  if _quiet_tree_tty; then
    printf '\n'
    quiet_print_tree_banner_rule "RUN SUMMARY"

    if [[ "${nf:-0}" -gt 0 ]]; then
      print_info 4 "$(_leg_icon failed) Result: failure"
    elif [[ "${nr:-0}" -gt 0 ]]; then
      print_info 4 "$(_leg_icon up_to_date) Result: success"
    else
      print_info 4 "$(_leg_icon up_to_date) Result: success"
    fi

    if [[ "${SUMMARY_PHASE_STACKS}" == "completed" ]]; then
      if [[ "${nf:-0}" -eq 0 ]] && [[ "${nr:-0}" -eq 0 ]]; then
        print_info 4 "$(_leg_icon no_change) Finished stack phase: no stacks redeployed."
      elif [[ "${nf:-0}" -eq 0 ]] && [[ "${nr:-0}" -gt 0 ]]; then
        print_info 4 "$(_leg_icon redeployed) Finished stack phase: ${nr} stack(s) redeployed."
      else
        print_info 4 "$(_leg_icon failed) Finished stack phase: ${nr} redeployed, ${nf} failure(s)."
      fi
    elif [[ "${SUMMARY_PHASE_STACKS}" == "skipped_no_cup_updates" ]]; then
      print_info 4 "$(_leg_icon skipped) Stacks phase skipped (Cup reports no image updates)."
    fi

    printf '\n'
    print_info 4 "Stack counts"
    printf '\n'
    print_info 4 "$(_leg_icon up_to_date) Checked:     ${checked_sum}"
    print_info 4 "$(_leg_icon redeployed) Redeployed:  ${nr}"
    print_info 4 "$(_leg_icon no_change) Unchanged:   ${unchanged_ct}"
    print_info 4 "$(_leg_icon skipped) Skipped:     ${skipped_ct}"
    print_info 4 "$(_leg_icon failed) Failed:      ${nf}"

    printf '\n'
    print_info 4 "Container counts"
    printf '\n'
    print_info 4 "$(_leg_icon no_change) Tracked:     ${_cup_tr}"
    print_info 4 "$(cup_update_icon) Updates available: ${_cup_ou}"
    print_info 4 "$(_leg_icon up_to_date) Up-to-date:  ${_cup_cu}"
    print_info 4 "❔ Unknown:     ${_cup_un}"

    printf '\n'
    print_info 4 "Warnings"
    printf '\n'
    print_info 4 "$(_leg_icon warnings) Warnings:    ${RUN_WARNING_COUNT:-0}"

    printf '\n'
    print_info 4 "Phase timings"
    printf '\n'
    print_info 4 "host:          $(_phase_secs_fmt_or_dash "${PHASE_SEC_HOST:-}")"
    print_info 4 "docker_pkgs:   $(_phase_secs_fmt_or_dash "${PHASE_SEC_DOCKER_PKGS:-}")"
    print_info 4 "portainer:     $(_phase_secs_fmt_or_dash "${PHASE_SEC_PORTAINER:-}")"
    print_info 4 "stacks:        $(_phase_secs_fmt_or_dash "${PHASE_SEC_STACKS:-}")"
    print_info 4 "cleanup:       $(_phase_secs_fmt_or_dash "${PHASE_SEC_CLEANUP:-}")"
    if [[ -n "${PIPELINE_START_EPOCH:-}" ]]; then
      end_ts="$(date +%s)"
      total_elapsed=$((end_ts - PIPELINE_START_EPOCH))
      print_info 4 "total:         $(_format_mm_ss "${total_elapsed}") ($(format_duration "${total_elapsed}"))"
    else
      print_info 4 "total:         —"
    fi

    printf '\n'
    print_info 4 "Log saved to:"
    print_info 4 "${LOG_FILE}"

    printf '\n'
    print_info 4 "Exit code: ${LAST_PIPELINE_EXIT_CODE}"
  else
    log_info ""
    log_info "${_sum_banner}"

    if [[ "${nf:-0}" -gt 0 ]]; then
      log_info "$(_leg_icon failed) Result: failure"
    elif [[ "${nr:-0}" -gt 0 ]]; then
      log_info "$(_leg_icon up_to_date) Result: success"
    else
      log_info "$(_leg_icon up_to_date) Result: success"
    fi

    if [[ "${SUMMARY_PHASE_STACKS}" == "completed" ]]; then
      if [[ "${nf:-0}" -eq 0 ]] && [[ "${nr:-0}" -eq 0 ]]; then
        if [[ -n "${CUP_RUN_OUTDATED:-${LAST_CUP_OUTDATED:-}}" ]] && [[ "${CUP_RUN_OUTDATED:-$LAST_CUP_OUTDATED}" =~ ^[0-9]+$ ]] && [[ "${CUP_RUN_OUTDATED:-$LAST_CUP_OUTDATED}" -gt 0 ]]; then
          log_info "$(_leg_icon no_change) Finished stack phase: no stacks redeployed. Cup reports ${CUP_RUN_OUTDATED:-$LAST_CUP_OUTDATED} image update(s) available; none required a Portainer stack touch for this run."
        else
          log_info "$(_leg_icon no_change) Finished stack phase: no stacks redeployed. No stack image updates were applied (selective / digest / Cup showed nothing to redeploy)."
        fi
      elif [[ "${nf:-0}" -eq 0 ]] && [[ "${nr:-0}" -gt 0 ]]; then
        log_info "$(_leg_icon redeployed) Finished stack phase: ${nr} stack(s) redeployed."
      else
        log_info "$(_leg_icon failed) Finished stack phase: ${nr} redeployed, ${nf} failure(s)."
      fi
    elif [[ "${SUMMARY_PHASE_STACKS}" == "skipped_no_cup_updates" ]]; then
      log_info "$(_leg_icon skipped) Stacks phase skipped (Cup reports no image updates)."
    fi

    log_info ""
    log_info "Stack counts"
    log_info "  $(_leg_icon up_to_date) Checked:     ${checked_sum}"
    log_info "  $(_leg_icon redeployed) Redeployed:  ${nr}"
    log_info "  $(_leg_icon no_change) Unchanged:   ${unchanged_ct}"
    log_info "  $(_leg_icon skipped) Skipped:     ${skipped_ct}"
    log_info "  $(_leg_icon failed) Failed:      ${nf}"

    log_info ""
    log_info "Container counts"
    log_info "  $(_leg_icon no_change) Tracked:     ${_cup_tr}"
    log_info "  $(cup_update_icon) Updates available: ${_cup_ou}"
    log_info "  $(_leg_icon up_to_date) Up-to-date:  ${_cup_cu}"
    log_info "  ❔ Unknown:     ${_cup_un}"

    log_info ""
    log_info "Warnings"
    log_info "  $(_leg_icon warnings) Warnings:    ${RUN_WARNING_COUNT:-0}"

    log_info ""
    log_info "Phase timings"
    log_info "  host:          $(_phase_secs_fmt_or_dash "${PHASE_SEC_HOST:-}")"
    log_info "  docker_pkgs:   $(_phase_secs_fmt_or_dash "${PHASE_SEC_DOCKER_PKGS:-}")"
    log_info "  portainer:     $(_phase_secs_fmt_or_dash "${PHASE_SEC_PORTAINER:-}")"
    log_info "  stacks:        $(_phase_secs_fmt_or_dash "${PHASE_SEC_STACKS:-}")"
    log_info "  cleanup:       $(_phase_secs_fmt_or_dash "${PHASE_SEC_CLEANUP:-}")"
    if [[ -n "${PIPELINE_START_EPOCH:-}" ]]; then
      end_ts="$(date +%s)"
      total_elapsed=$((end_ts - PIPELINE_START_EPOCH))
      log_info "  total:         $(_format_mm_ss "${total_elapsed}") ($(format_duration "${total_elapsed}"))"
    else
      log_info "  total:         —"
    fi

    log_info ""
    log_info "Log saved to:"
    log_info "  ${LOG_FILE}"

    log_info ""
    log_info "Exit code: ${LAST_PIPELINE_EXIT_CODE}"
  fi

  if [[ "${OUTPUT_MODE:-quiet}" == "verbose" ]]; then
    log_info ""
    log_info "-- Verbose: per-stack results (${#STACK_RUN_LOG[@]}) --"
    if [[ "${#STACK_RUN_LOG[@]}" -eq 0 ]]; then
      log_info "  (none — stacks phase did not run or produced no per-stack rows)"
    else
      local ent idx tot grp name vkey det grp_h glyph st_human pfx
      for ent in "${STACK_RUN_LOG[@]}"; do
        IFS='|' read -r idx tot grp name vkey det <<<"${ent}"
        grp_h="$(_stack_group_display_name "$grp")"
        glyph="$(_stack_state_glyph_verbose "$vkey")"
        case "$vkey" in
          unchanged) st_human="unchanged" ;;
          redeployed) st_human="redeployed" ;;
          failed) st_human="failed" ;;
          dry_run) st_human="dry-run planned" ;;
          excluded | skipped_dep) st_human="skipped" ;;
          *) st_human="$vkey" ;;
        esac
        pfx="${glyph} [$(printf '%02d' "${idx:-0}")/${tot}] ${name} [${grp_h}] — ${st_human}"
        [[ -n "${det:-}" ]] && pfx="${pfx} (${det})"
        log_info "  ${pfx}"
      done
    fi
  fi

  if ! _quiet_tree_tty; then
    log_info "============================================================="
  fi
}

run_phases_list() {
  local phases_raw="$1"
  local -a phases=()
  local ph _t
  while IFS= read -r line; do
    [[ -n "$line" ]] && phases+=("$line")
  done <<<"$phases_raw"

  [[ "${#phases[@]}" -eq 0 ]] && return 0

  acquire_run_lock
  rotate_log_if_needed
  reset_phases_list_summaries
  quiet_live_clear_safe
  PIPELINE_START_EPOCH="$(date +%s)"
  quiet_print_title_banner

  log_step "phase run start: ${phases[*]}"

  check_requirements
  refresh_stacks_cache
  quiet_print_target_block

  print_pipeline_statistics "pipeline_start"

  for ph in "${phases[@]}"; do
    case "$ph" in
      host)
        quiet_ensure_section green "System"
        confirm_step "Proceed with phase: host packages?"
        log_step "phase: host"
        _t="$(date +%s)"
        update_host_packages
        PHASE_SEC_HOST=$(($(date +%s) - _t))
        quiet_item_line 2 "Host packages"
        ;;
      docker_pkgs)
        quiet_ensure_section green "System"
        confirm_step "Proceed with phase: Docker apt packages?"
        log_step "phase: docker_pkgs"
        _t="$(date +%s)"
        update_docker_packages
        PHASE_SEC_DOCKER_PKGS=$(($(date +%s) - _t))
        quiet_item_line 2 "Docker-related apt packages"
        ;;
      portainer)
        portainer_quiet_ui_open
        portainer_log_digest_diagnostics_verbose
        confirm_step "Proceed with phase: Portainer container?"
        log_step "phase: portainer"
        _t="$(date +%s)"
        update_portainer_container_if_enabled
        PHASE_SEC_PORTAINER=$(($(date +%s) - _t))
        portainer_quiet_ui_container_outcome
        log_step "preflight: re-check Portainer API after Portainer phase"
        portainer_quiet_ui_api_validate_and_refresh_cache "no_catalog_live"
        _emit_log_file_ts "[pipeline] portainer phase complete"
        ;;
      cup)
        quiet_ensure_section green "System"
        confirm_step "Proceed with phase: Cup API diagnostics?"
        log_step "phase: cup"
        cup_run_selftest_phase || true
        ;;
      stacks)
        _emit_log_file_ts "[pipeline] update strategy printing"
        quiet_print_update_strategy_block
        _emit_log_file_ts "[pipeline] update strategy complete"
        confirm_step "Proceed with phase: redeploy all stacks?"
        log_step "phase: stacks"
        _t="$(date +%s)"
        run_stacks_phase_with_cup_gate
        PHASE_SEC_STACKS=$(($(date +%s) - _t))
        if [[ "$STACK_PHASE_SKIPPED_DUE_CUP" != "true" ]] && [[ "${SUMMARY_PHASE_STACKS}" == "completed" ]]; then
          quiet_print_stack_subgroup_metrics_block || true
        fi
        if _quiet_tree_tty; then
          QUIET_STACK_SECTION_DONE="true"
        fi
        _emit_log_file_ts "[pipeline] stacks phase complete"
        cup_refresh_after_stacks_if_configured || true
        ;;
      cleanup)
        if _quiet_tree_tty && [[ "${QUIET_STACK_SECTION_DONE:-false}" == "true" ]]; then
          printf '\n'
          QUIET_STACK_SECTION_DONE="false"
        fi
        quiet_print_tree_banner_rule "CLEANUP"
        confirm_step "Proceed with phase: Docker prune?"
        log_step "phase: cleanup"
        _emit_log_file_ts "[pipeline] cleanup phase starting"
        _t="$(date +%s)"
        cleanup_docker
        PHASE_SEC_CLEANUP=$(($(date +%s) - _t))
        _emit_log_file_ts "[pipeline] cleanup phase complete"
        quiet_print_cleanup_summary || true
        ;;
      *)
        fail "Unknown phase: $ph"
        ;;
    esac
  done

  log_step "phase run complete"

  print_pipeline_statistics "pipeline_end" || true
  _emit_log_file_ts "[pipeline] run summary printing"
  print_run_summary || true
  _emit_log_file_ts "[pipeline] run summary complete"
  _emit_log_file_ts "[pipeline] full pipeline complete"
}

execute_full_pipeline() {
  local _t
  acquire_run_lock
  rotate_log_if_needed
  reset_full_pipeline_summaries
  FULL_UI_PIPELINE="true"
  quiet_live_clear_safe
  PIPELINE_START_EPOCH="$(date +%s)"
  quiet_print_title_banner

  log_step "full pipeline start (v${STACK_UPDATER_VERSION})"

  confirm_step "Start full update? (preflight: Portainer API)"
  check_requirements
  refresh_stacks_cache

  quiet_print_target_block
  print_pipeline_statistics "pipeline_start"

  confirm_step "Run step: host package upgrades?"
  _t="$(date +%s)"
  update_host_packages
  PHASE_SEC_HOST=$(($(date +%s) - _t))

  confirm_step "Run step: Docker-related apt packages?"
  _t="$(date +%s)"
  update_docker_packages
  PHASE_SEC_DOCKER_PKGS=$(($(date +%s) - _t))

  quiet_print_system_status_block

  portainer_quiet_ui_open
  portainer_log_digest_diagnostics_verbose
  confirm_step "Run step: Portainer container refresh?"
  _t="$(date +%s)"
  update_portainer_container_if_enabled
  PHASE_SEC_PORTAINER=$(($(date +%s) - _t))
  portainer_quiet_ui_container_outcome

  log_step "preflight: re-check Portainer API after Portainer update"
  portainer_quiet_ui_api_validate_and_refresh_cache "no_catalog_live"
  _emit_log_file_ts "[pipeline] portainer phase complete"

  _emit_log_file_ts "[pipeline] update strategy printing"
  quiet_print_update_strategy_block
  _emit_log_file_ts "[pipeline] update strategy complete"

  confirm_step "Run step: redeploy stacks + cleanup?"
  _t="$(date +%s)"
  run_stacks_phase_with_cup_gate
  PHASE_SEC_STACKS=$(($(date +%s) - _t))

  if [[ "$STACK_PHASE_SKIPPED_DUE_CUP" != "true" ]] && [[ "${SUMMARY_PHASE_STACKS}" == "completed" ]]; then
    quiet_print_stack_subgroup_metrics_block || true
  fi

  if _quiet_tree_tty; then
    QUIET_STACK_SECTION_DONE="true"
  fi
  _emit_log_file_ts "[pipeline] stacks phase complete"
  cup_refresh_after_stacks_if_configured || true

  if _quiet_tree_tty && [[ "${QUIET_STACK_SECTION_DONE:-false}" == "true" ]]; then
    printf '\n'
    QUIET_STACK_SECTION_DONE="false"
  fi
  quiet_print_tree_banner_rule "CLEANUP"
  _emit_log_file_ts "[pipeline] cleanup phase starting"
  _t="$(date +%s)"
  maybe_cleanup_after_stack_phase
  PHASE_SEC_CLEANUP=$(($(date +%s) - _t))
  _emit_log_file_ts "[pipeline] cleanup phase complete"

  if [[ "${SUMMARY_PHASE_CLEANUP:-}" == "skipped_no_stack_redeploys" ]]; then
    quiet_print_cleanup_line "Docker cleanup skipped (no stack redeploys)."
  else
    quiet_print_cleanup_summary || true
  fi

  print_pipeline_statistics "pipeline_end" || true
  _emit_log_file_ts "[pipeline] run summary printing"
  print_run_summary || true
  _emit_log_file_ts "[pipeline] run summary complete"
  _emit_log_file_ts "[pipeline] full pipeline complete"

  log_step "full pipeline complete"
}

_stack_updater_menu_enabled() {
  case "${STACK_UPDATER_MENU:-}" in
    [Ff][Aa][Ll][Ss][E] | 0 | [Nn][Oo]) return 1 ;;
  esac
  return 0
}

run_self_test() {
  local fails=0 warns=0 json tracked _o _c _u logd
  printf '%s\n' "=== stack-updater self-test (read-only) ==="

  if bash -n "${BASH_SOURCE[0]}" 2>/dev/null; then
    printf '%-8s %s\n' PASS "bash -n stack-updater.sh"
  else
    printf '%-8s %s\n' FAIL "bash -n stack-updater.sh"
    fails=$((fails + 1))
  fi
  if [[ -f "$SCRIPT_DIR/lib/stack-updater-core.sh" ]] && bash -n "$SCRIPT_DIR/lib/stack-updater-core.sh" 2>/dev/null; then
    printf '%-8s %s\n' PASS "bash -n lib/stack-updater-core.sh"
  else
    printf '%-8s %s\n' FAIL "lib/stack-updater-core.sh missing or syntax error"
    fails=$((fails + 1))
  fi
  if [[ -f "${CONFIG_FILE:-}" ]] && bash -n "$CONFIG_FILE" 2>/dev/null; then
    printf '%-8s %s\n' PASS "bash -n config (${CONFIG_FILE})"
  else
    printf '%-8s %s\n' FAIL "bash -n config (${CONFIG_FILE:-missing})"
    fails=$((fails + 1))
  fi

  if command -v curl >/dev/null 2>&1; then
    printf '%-8s %s\n' PASS "curl ($(command -v curl))"
  else
    printf '%-8s %s\n' FAIL "curl missing"
    fails=$((fails + 1))
  fi
  if command -v jq >/dev/null 2>&1; then
    printf '%-8s %s\n' PASS "jq ($(command -v jq))"
  else
    printf '%-8s %s\n' FAIL "jq missing"
    fails=$((fails + 1))
  fi
  if command -v docker >/dev/null 2>&1; then
    printf '%-8s %s\n' PASS "docker ($(command -v docker))"
  else
    printf '%-8s %s\n' FAIL "docker missing"
    fails=$((fails + 1))
  fi

  if command -v gum >/dev/null 2>&1; then
    printf '%-8s %s\n' PASS "gum ($(command -v gum))"
  else
    printf '%-8s %s\n' WARN "gum missing (simple numbered prompt fallback)"
    warns=$((warns + 1))
  fi
  if command -v nala >/dev/null 2>&1; then
    printf '%-8s %s\n' PASS "nala ($(command -v nala))"
  else
    printf '%-8s %s\n' WARN "nala missing (apt-get fallback)"
    warns=$((warns + 1))
  fi

  if [[ "${PORTAINER_API_KEY:-}" == "PASTE_YOUR_PORTAINER_API_KEY_HERE" ]]; then
    printf '%-8s %s\n' FAIL "PORTAINER_API_KEY is still the placeholder in config"
    fails=$((fails + 1))
  else
    printf '%-8s %s\n' PASS "PORTAINER_API_KEY is set (not placeholder)"
  fi

  if docker info >/dev/null 2>&1; then
    printf '%-8s %s\n' PASS "docker daemon reachable"
  else
    printf '%-8s %s\n' FAIL "docker daemon not reachable"
    fails=$((fails + 1))
  fi

  if api_get "/api/stacks" >/dev/null 2>&1; then
    printf '%-8s %s\n' PASS "Portainer API: GET /api/stacks OK"
  else
    printf '%-8s %s\n' FAIL "Portainer API: GET /api/stacks failed"
    fails=$((fails + 1))
  fi
  if api_get "/api/endpoints/${ENDPOINT_ID}" >/dev/null 2>&1; then
    printf '%-8s %s\n' PASS "Portainer endpoint ${ENDPOINT_ID} reachable"
  else
    printf '%-8s %s\n' FAIL "Portainer endpoint ${ENDPOINT_ID} invalid or unreachable"
    fails=$((fails + 1))
  fi

  logd="$(dirname "${LOG_FILE:-}")"
  if [[ -n "$logd" && -d "$logd" && -w "$logd" ]] && { [[ ! -e "${LOG_FILE:-}" ]] || [[ -w "${LOG_FILE:-}" ]]; }; then
    printf '%-8s %s\n' PASS "log path writable (${LOG_FILE})"
  else
    printf '%-8s %s\n' FAIL "log path not writable (${LOG_FILE:-unset})"
    fails=$((fails + 1))
  fi

  if [[ "${CUP_ENABLED:-false}" == "true" ]]; then
    json="$(cup_fetch_json_document 2>/dev/null || true)"
    if [[ -z "$json" ]]; then
      printf '%-8s %s\n' WARN "Cup enabled but JSON fetch failed (${CUP_URL:-})"
      warns=$((warns + 1))
    else
      read -r tracked _o _c _u <<<"$(cup_compute_counts_from_json "$json")"
      if [[ "$tracked" != "-1" ]]; then
        printf '%-8s %s\n' PASS "Cup metrics parse OK (tracked=${tracked})"
      else
        printf '%-8s %s\n' WARN "Cup JSON present but metrics parse unclear"
        warns=$((warns + 1))
      fi
    fi
  else
    printf '%-8s %s\n' PASS "Cup disabled (skip JSON)"
  fi

  printf '%s\n' "--- session summary (no secrets) ---"
  printf 'OUTPUT_MODE=%s DRY_RUN=%s CUP_ENABLED=%s SELECTIVE_STACK_REDEPLOY=%s\n' \
    "${OUTPUT_MODE:-}" "${DRY_RUN:-}" "${CUP_ENABLED:-}" "${SELECTIVE_STACK_REDEPLOY:-}"
  printf '%s\n' "---"
  printf 'Fails: %s  Warnings: %s\n' "$fails" "$warns"
  [[ "$fails" -eq 0 ]]
}

dispatch_cli() {
  if [[ "$SELF_TEST" == "true" ]]; then
    run_self_test
    exit $?
  fi

  if [[ "$CHECK_ONLY" == "true" ]]; then
    generate_report
    exit 0
  fi

  if [[ "$TUI_MODE" == "true" ]]; then
    run_tui_menu
    exit 0
  fi

  if [[ "$BATCH_MODE" == "true" ]]; then
    execute_full_pipeline
    exit "${LAST_PIPELINE_EXIT_CODE:-0}"
  fi

  if [[ "$RUN_ALL" == "true" ]]; then
    execute_full_pipeline
    exit "${LAST_PIPELINE_EXIT_CODE:-0}"
  fi

  if [[ "${#PHASE_QUEUE[@]}" -gt 0 ]]; then
    local p normalized
    for p in "${PHASE_QUEUE[@]}"; do
      phase_is_valid "$p" || fail "Invalid phase: ${p} (use: ${CANONICAL_PHASE_ORDER[*]})"
    done
    normalized="$(normalize_phase_list)"
    [[ -n "$normalized" ]] || fail "No valid phases to run."
    run_phases_list "$normalized"
    exit "${LAST_PIPELINE_EXIT_CODE:-0}"
  fi

  if [[ "$EMPTY_INVOCATION" == "true" ]]; then
    if [[ -t 0 ]] && [[ -t 1 ]] && _stack_updater_menu_enabled; then
      run_tui_menu
      exit 0
    fi
    execute_full_pipeline
    exit "${LAST_PIPELINE_EXIT_CODE:-0}"
  fi

  execute_full_pipeline
  exit "${LAST_PIPELINE_EXIT_CODE:-0}"
}

dispatch_cli
