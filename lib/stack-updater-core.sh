#!/usr/bin/env bash
# Pure helpers for stack-updater (sourced by stack-updater.sh; also tested via bats).

normalize_image_ref_token() {
  echo "${1,,}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e 's/#.*$//'
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

portainer_normalize_version_sortkey() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%%[[:space:]]*}"
  s="${s#v}"
  s="${s#V}"
  s="${s#"${s%%[![:digit:].]*}"}"
  printf '%s' "$s"
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
