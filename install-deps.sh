#!/usr/bin/env bash
# Install OS packages used by stack-updater.sh (Debian/Ubuntu today).
# Does not install Docker or Portainer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ="${SCRIPT_DIR}/requirements.txt"

as_root() {
  if [[ "${EUID:-0}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

summarize_cmd() {
  local name="$1"
  if have_cmd "$name"; then
    local p v
    p="$(command -v "$name")"
    v="$("$name" --version 2>/dev/null | head -1 || true)"
    [[ -n "$v" ]] && printf '%s: %s (%s)\n' "$name" "$p" "$v" || printf '%s: %s\n' "$name" "$p"
  else
    printf '%s: missing\n' "$name"
  fi
}

install_charm_gum() {
  if have_cmd gum; then
    echo "gum already installed: $(command -v gum)"
    return 0
  fi

  echo "Adding Charm APT repository for gum..."
  as_root mkdir -p /etc/apt/keyrings
  curl -fsSL https://repo.charm.sh/apt/gpg.key | as_root gpg --yes --dearmor -o /etc/apt/keyrings/charm.gpg
  echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | as_root tee /etc/apt/sources.list.d/charm.list >/dev/null
  as_root apt-get update -qq
  as_root apt-get install -y gum
}

read_requirements_pkgs() {
  local line
  PACKAGES=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ "$line" == "nala" ]] && continue
    PACKAGES+=("$line")
  done <"$REQ"
}

read_requirements_pkgs

if [[ "${#PACKAGES[@]}" -eq 0 ]]; then
  echo "No core packages listed in ${REQ}" >&2
  exit 1
fi

echo "Installing core packages: ${PACKAGES[*]}"
as_root apt-get update -qq
as_root apt-get install -y "${PACKAGES[@]}"

echo "Installing nala (optional; script falls back to apt-get if unavailable)..."
if as_root apt-get install -y nala 2>/dev/null; then
  :
else
  echo "WARN: nala could not be installed from APT (distro/repo). stack-updater.sh will use apt-get." >&2
fi

install_charm_gum

echo ""
echo "=== install-deps summary ==="
summarize_cmd jq
summarize_cmd curl
if have_cmd nala; then
  summarize_cmd nala
else
  printf '%s\n' "nala: missing, apt-get fallback will be used"
fi
if have_cmd gum; then
  summarize_cmd gum
else
  printf '%s\n' "gum: missing, simple prompt fallback will be used in stack-updater.sh"
fi
echo "Done."
