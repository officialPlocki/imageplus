#!/usr/bin/env bash
set -euo pipefail

cat <<'EOF'
┃
┃   ██╗███╗   ███╗ █████╗  ██████╗ ███████╗
┃   ██║████╗ ████║██╔══██╗██╔════╝ ██╔════╝
┃   ██║██╔████╔██║███████║██║  ███╗█████╗
┃   ██║██║╚██╔╝██║██╔══██║██║   ██║██╔══╝
┃   ██║██║ ╚═╝ ██║██║  ██║╚██████╔╝███████╗
┃   ╚═╝╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝ plus
┃
┃   Proxmox Cloud Image Template Builder (plus)
┃   Copyright © Philippe Simon Pflug
┃   https://github.com/officialPlocki
┃   Hosting needed? https://elizon.app
┃
┃   Licensed under CC BY-NC-ND 4.0
┃   https://creativecommons.org/licenses/by-nc-nd/4.0/
┃
┃   DISCLAIMER
┃   This software is provided "as is", without warranty of any kind.
┃   The author shall not be held liable for any damages, data loss,
┃   service disruption or misconfiguration.
┃
┃   This tool performs DESTRUCTIVE operations:
┃   - Deletes and recreates virtual machines
┃   - Overwrites disks and templates
┃
┃   You are solely responsible for verifying all parameters,
┃   targets and environments before execution.
┃
┃   PRESS CTRL+C WITHIN 3 SECONDS TO ABORT.
┃
EOF

sleep 3
echo "🔧 Initializing..."

# Local install model:
# - `imageplus.sh` is meant to live permanently on the host.
# - It uses local `lib/*.sh` next to this script (no downloading on startup).

load() {
  local lib="$1"
  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  local local_lib="$script_dir/lib/$lib"
  if [[ ! -f "$local_lib" ]]; then
    echo "[ERR] Missing local library: $local_lib" >&2
    echo "[ERR] Install the full bundle (imageplus.sh + lib/*.sh) on this host." >&2
    exit 1
  fi

  local restore_nounset=false
  case "$-" in
    *u*) restore_nounset=true; set +u ;;
  esac
  # shellcheck disable=SC1090
  source "$local_lib"
  if [[ "$restore_nounset" == true ]]; then
    set -u
  fi
}

echo "🔄 Loading modules..."
load util.sh
load download.sh
load imagebuilder.sh
load proxmox.sh

CONFIG_FILE="imageplus.yml"

main() {
  ensure_dependencies
  preflight_checks
  load_or_migrate_config "$CONFIG_FILE"

  local original_args=("$@")
  parse_args "$@"

  if [[ "${CFG_FIRST_RUN:-false}" == true && ${#original_args[@]} -eq 0 ]]; then
    interactive_config
    save_config "$CONFIG_FILE"
    CFG_FIRST_RUN=false
  fi
  if [[ "${CFG_CONFIGURE:-false}" == true ]]; then
    interactive_config
    save_config "$CONFIG_FILE"
  fi

  if [[ "${CFG_DOWNLOAD_ONLY:-false}" == true ]]; then
    CFG_UPDATE=false
  fi

  log "🚀 Starting pipeline"

  if [[ "${CFG_AUTO_DELETE_UNSUPPORTED:-false}" == true ]]; then
    cleanup_unsupported_templates
  fi

  if [[ "${CFG_DOWNLOAD:-true}" == true ]]; then
    download_all
  fi

  if [[ "${CFG_UPDATE:-false}" == true ]]; then
    prepare_images
    customize_all
    create_all_templates
  elif [[ "${CFG_DOWNLOAD_ONLY:-false}" == true ]]; then
    log "📦 Download-only mode completed."
  fi

  print_summary
  ensure_pve_backup_excludes
  save_config "$CONFIG_FILE"
  cleanup_artifacts
  log "✅ Done"
}

main "$@"


# TODO: add again the auto-add for backup job exclusion