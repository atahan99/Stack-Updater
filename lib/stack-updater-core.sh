#!/usr/bin/env bash
# Pure helpers for stack-updater (sourced by stack-updater.sh; also tested via bats).

normalize_image_ref_token() {
  local s="${1,,}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%%[[:space:]]*}"
  s="${s#\"}"
  s="${s%\"}"
  s="${s%%#*}"
  printf '%s' "$s"
}

compose_image_lines_from_content() {
  local c="${1:-}"
  echo "$c" | grep -iE '^[[:space:]]*image:[[:space:]]*' \
    | sed -E 's/^[[:space:]]*image:[[:space:]]*//I' \
    | sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' \
    | sed '/^$/d' || true
}

_cup_strip_digest() {
  printf '%s' "${1}" | sed -E 's/@sha256:[a-f0-9]+//Ig'
}

_cup_registry_strip_leading() {
  local r="${1,,}"
  r="${r#docker.io/}"
  r="${r#registry-1.docker.io/}"
  printf '%s' "$r"
}

_cup_library_expand() {
  local r="$1"
  [[ "$r" == */* ]] && printf '%s' "$r" && return 0
  printf 'library/%s' "$r"
}

_cup_image_refs_equivalent() {
  local a b ra rb la lb
  a="$(_cup_strip_digest "$(normalize_image_ref_token "${1:-}")")"
  b="$(_cup_strip_digest "$(normalize_image_ref_token "${2:-}")")"
  a="${a,,}"
  b="${b,,}"
  [[ -z "$a" || -z "$b" ]] && return 1
  [[ "$a" == "$b" ]] && return 0
  ra="$(_cup_registry_strip_leading "$a")"
  rb="$(_cup_registry_strip_leading "$b")"
  [[ "$ra" == "$rb" ]] && return 0
  la="$(_cup_library_expand "$ra")"
  lb="$(_cup_library_expand "$rb")"
  [[ "$la" == "$lb" ]] && return 0
  [[ "$ra" == "$lb" ]] && return 0
  [[ "$la" == "$rb" ]] && return 0
  return 1
}

# Shared jq predicate for Cup outdated entries (images + containers).
_cup_jq_is_outdated() {
  printf '%s' '((.result // empty | type == "object") and .result.has_update == true) or (.update_available == true)'
}

cup_outdated_image_lines_from_json() {
  local json="${1:-}" filter
  [[ -z "$json" ]] && return 0
  filter="$(_cup_jq_is_outdated)"
  echo "$json" | jq -r "
    (
      [ .images[]?
        | select(${filter})
        | (.reference // .image // .name // empty) | strings ]
      + [ .containers[]?
        | select(${filter})
        | (.image // .name // .reference // empty) | strings ]
    ) | .[] | select(length > 0)
  " 2>/dev/null | sort -u | sed '/^$/d' || true
}

_compose_images_match_cup_ref() {
  local compose_content="$1" cup_ref="$2"
  local img
  [[ -z "$cup_ref" ]] && return 1
  while IFS= read -r img; do
    [[ -z "$img" ]] && continue
    _cup_image_refs_equivalent "$img" "$cup_ref" && return 0
  done <<<"$(compose_image_lines_from_content "$compose_content")"
  return 1
}

# Sets SELECTIVE_CUP_MATCH_REF on match when called from selective redeploy path.
compose_images_match_cup_outdated() {
  local compose_content="$1" cup_json="$2"
  local outdated cup_ln
  SELECTIVE_CUP_MATCH_REF=""
  outdated="$(cup_outdated_image_lines_from_json "$cup_json")"
  [[ -z "$outdated" ]] && return 1
  while IFS= read -r cup_ln; do
    [[ -z "$cup_ln" ]] && continue
    if _compose_images_match_cup_ref "$compose_content" "$cup_ln"; then
      SELECTIVE_CUP_MATCH_REF="$cup_ln"
      return 0
    fi
  done <<<"$outdated"
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

portainer_normalize_version_sortkey() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%%[[:space:]]*}"
  s="${s#v}"
  s="${s#V}"
  s="${s#"${s%%[![:digit:].]*}"}"
  printf '%s' "$s"
}

_format_mm_ss() {
  local secs="${1:-0}"
  printf '%02d:%02d' $((secs / 60)) $((secs % 60))
}

_format_duration_secs() {
  local secs="${1:-0}" m s
  m=$((secs / 60))
  s=$((secs % 60))
  if [[ "$m" -gt 0 ]]; then
    printf '%dm %ds' "$m" "$s"
  else
    printf '%ds' "$s"
  fi
}

# Post-redeploy sleep seconds (dependency group uses container poll + DEPENDENCY_SETTLE_SECONDS separately).
stack_wait_seconds_for_group() {
  case "${1:-}" in
    dependent) printf '%s' "${DEPENDENT_STACK_SLEEP_SECONDS:-30}" ;;
    heavy) printf '%s' "${HEAVY_STACK_SLEEP_SECONDS:-45}" ;;
    remaining | *) printf '%s' "${DEFAULT_STACK_SLEEP_SECONDS:-10}" ;;
  esac
}

# Compose v2 project slug from Portainer stack name (lowercase, non-alnum -> hyphen).
compose_project_slug_from_stack_name() {
  local n="${1,,}"
  n="$(printf '%s' "$n" | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
  printf '%s' "${n:-unknown}"
}

# Validate 5-field cron expression (minute hour dom month dow).
stack_updater_cron_valid() {
  local expr="${1:-}"
  [[ -n "$expr" ]] || return 1
  local n
  n="$(printf '%s' "$expr" | awk '{print NF}')"
  [[ "$n" -eq 5 ]] || return 1
  printf '%s' "$expr" | grep -qE '^[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/A-Za-z-]+[[:space:]]+[0-9*,/-A-Za-z]+$' || return 1
  return 0
}

# Outputs os and arch on two lines (for registry digest selection).
docker_host_platform_os_arch() {
  local os arch
  os="$(docker version -f '{{.Server.Os}}' 2>/dev/null || echo linux)"
  arch="$(docker version -f '{{.Server.Arch}}' 2>/dev/null || echo "")"
  [[ -z "$arch" ]] && arch="$(uname -m 2>/dev/null || echo amd64)"
  case "$arch" in
    aarch64) arch=arm64 ;;
    x86_64) arch=amd64 ;;
  esac
  printf '%s\n%s' "$os" "$arch"
}

# Extract platform-matched digest from docker manifest inspect JSON (stdin or arg).
registry_digest_from_manifest_json() {
  local manifest="${1:-}" os arch
  if [[ -z "$manifest" ]]; then
    manifest="$(cat)"
  fi
  read -r os arch < <(docker_host_platform_os_arch)
  local d
  d="$(echo "$manifest" | jq -r --arg os "$os" --arg arch "$arch" '
    if (.manifests | type) == "array" and (.manifests | length) > 0 then
      ([
        .manifests[]
        | select(.platform != null and .platform.os == $os
            and (.platform.architecture == $arch
                 or ($arch == "arm64" and .platform.architecture == "arm" and .platform.variant == "v8")))
      ] | first | .digest? // empty)
    else
      (.Descriptor.digest // .config.digest // empty)
    end
  ' 2>/dev/null)"
  if [[ -z "$d" ]] && echo "$manifest" | jq -e '.manifests | type == "array"' >/dev/null 2>&1; then
    d="$(echo "$manifest" | jq -r '.manifests[0].digest? // empty' 2>/dev/null)"
  fi
  printf '%s' "${d:-}"
}
