#!/usr/bin/env bash
set -euo pipefail

CFG_DOWNLOAD=true
CFG_UPDATE=true
CFG_DOWNLOAD_ONLY=false
CFG_WINDOWS=true
CFG_REDOWNLOAD_ISOS=false
CFG_WINDOWS_VERSIONS_RAW=""
CFG_WINDOWS_LINKS_RAW=""
CFG_PARALLEL=4
CFG_DEBUG=false
CFG_STORAGE="local-lvm"
CFG_BASE_VMID="9000"
CFG_IMAGE_DIR="/tmp/images"
CFG_ISO_DIR="/tmp/iso"
CFG_DISABLE_EFI=false
CFG_DISABLE_TPM=false
CFG_DRY_RUN=false
CFG_SILENT=false
CFG_CONFIGURE=false
CFG_FIRST_RUN=false
CFG_ONLY=""

# `-g` is required: libs are sourced from `load()` in imageplus.sh; without it
# these vanish when `load` returns and wait_background_jobs sees an unset array.
declare -ga BACKGROUND_PIDS=()
declare -g _IMAGEPLUS_TRAP_INSTALLED=false

cleanup_background_jobs(){
  # Make sure leftover downloads/customizations don't keep running after Ctrl+C.
  # If the array is empty, bail out early (avoid a single empty-string element).
  if [[ ${#BACKGROUND_PIDS[@]} -eq 0 ]]; then
    return 0
  fi
  local pids=("${BACKGROUND_PIDS[@]}")
  BACKGROUND_PIDS=()
  [[ ${#pids[@]} -eq 0 ]] && return 0

  local pid
  for pid in "${pids[@]}"; do
    [[ -z "$pid" ]] && continue
    kill -0 "$pid" >/dev/null 2>&1 || continue
    kill "$pid" >/dev/null 2>&1 || true
  done
  # Give processes a moment to exit, then SIGKILL if needed.
  sleep 0.2
  for pid in "${pids[@]}"; do
    [[ -z "$pid" ]] && continue
    kill -0 "$pid" >/dev/null 2>&1 || continue
    kill -9 "$pid" >/dev/null 2>&1 || true
  done
}

install_traps_once(){
  [[ "$_IMAGEPLUS_TRAP_INSTALLED" == true ]] && return 0
  _IMAGEPLUS_TRAP_INSTALLED=true
  trap cleanup_background_jobs EXIT INT TERM
}

log(){
  if [[ "${CFG_SILENT:-false}" != true ]]; then
    echo "[INFO] $*"
  fi
}

debug(){
  if [[ "${CFG_DEBUG:-false}" == true ]]; then
    echo "[DBG] $*" >&2
  fi
}

enable_debug_trace(){
  if [[ "${CFG_DEBUG:-false}" == true ]]; then
    # Make debug mode show *everything* in console.
    CFG_SILENT=false
    export PS4='[TRACE] ${BASH_SOURCE##*/}:${LINENO}: '
    set -x
  fi
}

fail(){
  echo "[ERR] $*" >&2
  exit 1
}

run(){
  if [[ "${CFG_DRY_RUN:-false}" == true ]]; then
    echo "[DRYRUN] $*"
    return 0
  fi

  if [[ "${CFG_DEBUG:-false}" == true ]]; then
    debug "RUN: $*"
  fi

  if command -v timeout >/dev/null 2>&1; then
    if [[ "${CFG_SILENT:-false}" == true ]]; then
      timeout -k 10 600 "$@" >/dev/null 2>&1 || fail "Failed: $*"
    else
      timeout -k 10 600 "$@" || fail "Failed: $*"
    fi
  else
    if [[ "${CFG_SILENT:-false}" == true ]]; then
      "$@" >/dev/null 2>&1 || fail "Failed: $*"
    else
      "$@" || fail "Failed: $*"
    fi
  fi
}

try_run(){
  if [[ "${CFG_DRY_RUN:-false}" == true ]]; then
    echo "[DRYRUN] $*"
    return 0
  fi

  if [[ "${CFG_DEBUG:-false}" == true ]]; then
    debug "TRY: $*"
  fi

  if command -v timeout >/dev/null 2>&1; then
    if [[ "${CFG_SILENT:-false}" == true ]]; then
      timeout -k 10 600 "$@" >/dev/null 2>&1 || true
    else
      timeout -k 10 600 "$@" || true
    fi
  else
    if [[ "${CFG_SILENT:-false}" == true ]]; then
      "$@" >/dev/null 2>&1 || true
    else
      "$@" || true
    fi
  fi
}

run_in_background(){
  if [[ "${CFG_DRY_RUN:-false}" == true ]]; then
    echo "[DRYRUN] $*"
    return 0
  fi

  install_traps_once
  "$@" &
  BACKGROUND_PIDS+=("$!")
}

prune_background_pids(){
  if [[ ${#BACKGROUND_PIDS[@]} -eq 0 ]]; then
    return 0
  fi
  local alive=()
  local pid
  for pid in "${BACKGROUND_PIDS[@]}"; do
    [[ -z "$pid" ]] && continue
    if kill -0 "$pid" >/dev/null 2>&1; then
      alive+=("$pid")
    fi
  done
  if [[ ${#alive[@]} -eq 0 ]]; then
    BACKGROUND_PIDS=()
  else
    BACKGROUND_PIDS=("${alive[@]}")
  fi
}

wait_background_jobs(){
  local result=0
  local pid
  if [[ ${#BACKGROUND_PIDS[@]} -eq 0 ]]; then
    BACKGROUND_PIDS=()
    return 0
  fi
  for pid in "${BACKGROUND_PIDS[@]}"; do
    [[ -z "$pid" ]] && continue
    if ! wait "$pid"; then
      result=1
    fi
  done
  BACKGROUND_PIDS=()
  return "$result"
}

limit_background_jobs(){
  local max_jobs="${CFG_PARALLEL:-4}"
  prune_background_pids
  while [[ "${#BACKGROUND_PIDS[@]}" -ge "$max_jobs" ]]; do
    sleep 0.1
    prune_background_pids
  done
}

# ---------------- YAML ----------------
normalize_bool(){
  local value="${1:-}"
  case "${value,,}" in
    true|1|yes|y|on) echo true ;;
    *) echo false ;;
  esac
}

normalize_list(){
  local raw="$1"
  local -n out="$2"
  out=()
  raw="${raw//\"/}"
  raw="${raw//[/}"
  raw="${raw//]/}"
  raw="${raw//,/ }"
  for item in $raw; do
    item="${item// /}"
    [[ -n "$item" ]] && out+=("$item")
  done
}

parse_yaml(){
  local file="$1"
  while IFS=":" read -r raw_key raw_val; do
    [[ "$raw_key" =~ ^[[:space:]]*# ]] && continue
    local key="${raw_key//-/_}"
    key="${key^^}"
    local val="${raw_val# }"
    val="${val%% }"
    [[ -z "$key" ]] && continue
    case "$key" in
      DOWNLOAD|UPDATE|DOWNLOAD_ONLY|WINDOWS|DISABLE_EFI|DISABLE_TPM|REDOWNLOAD_ISOS|DEBUG)
        val="$(normalize_bool "$val")"
        ;;
      CUSTOM_WINDOWS_VERSIONS)
        key="WINDOWS_VERSIONS_RAW"
        ;;
      CUSTOM_WINDOWS_DOWNLOAD_LINKS)
        key="WINDOWS_LINKS_RAW"
        ;;
    esac
    export "CFG_${key}=$val"
  done < "$file"
}

ask_with_tty(){
  local prompt="$1"
  local default="$2"
  local answer
  local tty="/dev/tty"

  if [[ -e "$tty" && -r "$tty" && -w "$tty" ]]; then
    exec 3<>"$tty"
    printf '%s [%s]: ' "$prompt" "$default" >&3
    if ! IFS= read -r answer <&3; then
      exec 3>&-
      echo "$default"
      return
    fi
    exec 3>&-
    answer="${answer:-$default}"
    echo "$answer"
    return
  fi

  read -rp "$prompt [$default]: " answer
  answer="${answer:-$default}"
  echo "$answer"
}

ask_bool(){
  local prompt="$1"
  local default="$2"
  local answer
  while true; do
    answer="$(ask_with_tty "$prompt" "$default")"
    case "${answer,,}" in
      y|yes|true|1|on)
        echo true
        return
        ;;
      n|no|false|0|off)
        echo false
        return
        ;;
      *)
        echo "Please answer yes or no."
        ;;
    esac
  done
}

ask_text(){
  local prompt="$1"
  local default="$2"
  local answer
  answer="$(ask_with_tty "$prompt" "$default")"
  echo "$answer"
}

interactive_config(){
  local tty="/dev/tty"
  if [[ ! -t 0 && ! -e "$tty" ]]; then
    return
  fi

  log "🔧 No configuration found. Starting interactive setup."

  while true; do
    CFG_DOWNLOAD="$(ask_bool 'Download images?' 'yes')"
    CFG_UPDATE="$(ask_bool 'Update/customize images and create templates?' 'yes')"
    if [[ "$CFG_DOWNLOAD" == true || "$CFG_UPDATE" == true ]]; then
      break
    fi
    echo "At least one of download or update must be enabled."
  done

  CFG_DOWNLOAD_ONLY=false
  if [[ "$CFG_DOWNLOAD" == true && "$CFG_UPDATE" != true ]]; then
    CFG_DOWNLOAD_ONLY=true
  fi

  CFG_WINDOWS="$(ask_bool 'Download/create Windows templates?' 'yes')"
  CFG_REDOWNLOAD_ISOS="$(ask_bool 'Re-download existing ISOs?' 'no')"
  CFG_SILENT="$(ask_bool 'Suppress verbose output?' 'no')"
  CFG_DEBUG="$(ask_bool 'Enable debug logging?' 'no')"
  CFG_DISABLE_EFI="$(ask_bool 'Disable EFI disk creation?' 'no')"
  CFG_DISABLE_TPM="$(ask_bool 'Disable TPM state creation?' 'no')"
  CFG_STORAGE="$(ask_text 'Proxmox storage name' "$CFG_STORAGE")"
  CFG_BASE_VMID="$(ask_text 'Base VMID' "${CFG_BASE_VMID:-9000}")"
  CFG_PARALLEL="$(ask_text 'Parallel jobs' "${CFG_PARALLEL:-4}")"
  CFG_ONLY="$(ask_text 'Only process a single image name (leave empty for all)' "")"

  log "✅ Interactive setup complete."
}

save_config(){
  local f="$1"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<EOF
# imageplus configuration
download: ${CFG_DOWNLOAD:-true}
update: ${CFG_UPDATE:-true}
download_only: ${CFG_DOWNLOAD_ONLY:-false}
redownload_isos: ${CFG_REDOWNLOAD_ISOS:-false}
windows: ${CFG_WINDOWS:-true}
custom_windows_versions: ${CFG_WINDOWS_VERSIONS_RAW:-}
custom_windows_download_links: ${CFG_WINDOWS_LINKS_RAW:-}
parallel: ${CFG_PARALLEL:-4}
debug: ${CFG_DEBUG:-false}
storage: ${CFG_STORAGE:-local-lvm}
base_vmid: ${CFG_BASE_VMID:-9000}
disable_efi: ${CFG_DISABLE_EFI:-false}
disable_tpm: ${CFG_DISABLE_TPM:-false}
image_dir: ${CFG_IMAGE_DIR:-/tmp/images}
iso_dir: ${CFG_ISO_DIR:-/tmp/iso}
only: ${CFG_ONLY:-}
EOF
}

cleanup_artifacts(){
  if [[ "${CFG_DRY_RUN:-false}" == true ]]; then
    log "Dry-run: skipping artifact cleanup"
    return 0
  fi
  if [[ -d "${CFG_IMAGE_DIR}" ]]; then
    rm -rf "${CFG_IMAGE_DIR}"
    log "Removed temporary image directory: ${CFG_IMAGE_DIR}"
  fi
  if [[ -d "${CFG_ISO_DIR}" ]]; then
    rm -rf "${CFG_ISO_DIR}"
    log "Removed temporary ISO directory: ${CFG_ISO_DIR}"
  fi
}

ensure_pve_backup_excludes(){
  if [[ "${CFG_DRY_RUN:-false}" == true ]]; then
    log "Dry-run: skipping backup exclude check"
    return 0
  fi
  if ! command -v pvesh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    log "⚠ pvesh/jq/python3 not available; skipping backup exclude check"
    return 0
  fi

  local exclude_vms
  exclude_vms="$(printf '%s\n' "${CREATED_TEMPLATES[@]:-}" | awk -F: '{print $2}' | paste -sd, -)"
  [[ -z "$exclude_vms" ]] && return 0

  local job_ids
  job_ids=$(pvesh get /cluster/backup --output-format json | jq -r '.[].id' 2>/dev/null || true)
  if [[ -z "$job_ids" ]]; then
    log "No backup jobs found to inspect"
    return 0
  fi

  for job in $job_ids; do
    local job_json
    job_json=$(pvesh get /cluster/backup/"$job" --output-format json | jq -s '.' 2>/dev/null || true)
    [[ -z "$job_json" ]] && continue
    local all
    all=$(jq -r '.[0].all // empty' <<<"$job_json")
    local exclude
    exclude=$(jq -r '.[0].exclude // empty' <<<"$job_json")
    if [[ "$all" != "1" || -n "$exclude" ]]; then
      continue
    fi

    log "Backup job $job has all=1 and no exclude; updating /etc/pve/jobs.cfg"

    if [[ ! -f "/etc/pve/jobs.cfg" ]]; then
      log "⚠ /etc/pve/jobs.cfg not found; cannot update backup job excludes"
      continue
    fi

    python3 - <<PY
import pathlib, re
job = "$job"
exclude = "$exclude_vms"
path = pathlib.Path('/etc/pve/jobs.cfg')
text = path.read_text()
pattern = re.compile(r'(?m)^vzdump: ' + re.escape(job) + r'(?:\n[ \t].*)*')
m = pattern.search(text)
if not m:
    raise SystemExit(0)
block = m.group(0)
if re.search(r'(?m)^[ \t]*exclude\s+', block):
    raise SystemExit(0)
lines = block.splitlines()
out = []
inserted = False
for line in lines:
    out.append(line)
    if re.match(r'^[ \t]*enabled\b', line) and not inserted:
        out.append('        exclude ' + exclude)
        inserted = True
if not inserted:
    out.append('        exclude ' + exclude)
text = text[:m.start()] + '\n'.join(out) + text[m.end():]
path.write_text(text)
PY
    if [[ $? -eq 0 ]]; then
      log "✅ Added exclude list to backup job $job"
    else
      log "⚠ Failed to update /etc/pve/jobs.cfg for job $job"
    fi
  done
}

load_or_migrate_config(){
  local f="$1"
  local old="./images/.last_run.conf"

  if [[ -f "$f" ]]; then
    parse_yaml "$f"
    return
  fi

  if [[ -f "$old" ]]; then
    log "Migrating old config → YAML"
    # shellcheck source=../images/.last_run.conf
    source "$old"
    CFG_DOWNLOAD="$(normalize_bool "${DO_DOWNLOAD:-true}")"
    CFG_UPDATE="$(normalize_bool "${DO_UPDATE_IMAGES:-true}")"
    if [[ "${DO_DOWNLOAD:-false}" == true && "${DO_UPDATE_IMAGES:-false}" != true ]]; then
      CFG_DOWNLOAD_ONLY=true
    else
      CFG_DOWNLOAD_ONLY=false
    fi
    CFG_REDOWNLOAD_ISOS="$(normalize_bool "${REDOWNLOAD_ISOS:-false}")"
    CFG_WINDOWS="true"
    if [[ "$(normalize_bool "${WINDOWS_DISABLED:-false}")" == true ]]; then
      CFG_WINDOWS=false
    fi
    CFG_STORAGE="${STORAGE_IMPORT:-${CFG_STORAGE}}"
    CFG_BASE_VMID="${BASE_VMID:-${CFG_BASE_VMID}}"
    CFG_WINDOWS_VERSIONS_RAW="${WINDOWS_VERSIONS_RAW:-}"
    CFG_WINDOWS_LINKS_RAW="${WINDOWS_LINKS_RAW:-}"
    CFG_PARALLEL="${CFG_PARALLEL:-4}"
    CFG_DEBUG="$(normalize_bool "${DEBUG:-false}")"
  fi

  if [[ ! -f "$f" && ! -f "$old" ]]; then
    # shellcheck disable=SC2034
    CFG_FIRST_RUN=true
  fi
}

# ---------------- Preflight ----------------

# Tool -> Debian/Proxmox package name. "__pve__" marks binaries that ship with
# the Proxmox VE host (pve-manager) and cannot be installed via apt separately.
_imageplus_tool_packages(){
  cat <<'EOF'
curl curl
wget wget
aria2c aria2
jq jq
python3 python3
tar tar
gzip gzip
bzip2 bzip2
pbzip2 pbzip2
pigz pigz
xz xz-utils
qemu-img qemu-utils
virt-customize libguestfs-tools
timeout coreutils
mktemp coreutils
find findutils
awk gawk
sed sed
paste coreutils
qm __pve__
pvesh __pve__
pvesm __pve__
EOF
}

ensure_dependencies(){
  log "🔧 Checking required tools..."

  local -a missing_packages=()
  local -a missing_pve=()
  local seen=" "
  local tool pkg

  while read -r tool pkg; do
    [[ -z "$tool" ]] && continue
    # gunzip/bunzip2 ship in gzip/bzip2 — probe the package's canonical binary.
    if command -v "$tool" >/dev/null 2>&1; then
      continue
    fi
    if [[ "$pkg" == "__pve__" ]]; then
      missing_pve+=("$tool")
      continue
    fi
    if [[ "$seen" != *" $pkg "* ]]; then
      missing_packages+=("$pkg")
      seen+="$pkg "
    fi
  done < <(_imageplus_tool_packages)

  if [[ ${#missing_pve[@]} -gt 0 ]]; then
    log "⚠ Missing Proxmox tools (ship with pve-manager): ${missing_pve[*]}"
    log "  imageplus will continue, but Proxmox steps will fail unless this runs on a PVE host."
  fi

  if [[ ${#missing_packages[@]} -eq 0 ]]; then
    log "✅ All installable dependencies present"
    return 0
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    fail "Missing tools: ${missing_packages[*]} (no apt-get on this host — install manually)"
  fi

  local -a sudo_prefix=()
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo_prefix=(sudo)
    else
      fail "Missing tools: ${missing_packages[*]} — need root or sudo to install"
    fi
  fi

  log "📦 Installing missing packages: ${missing_packages[*]}"

  if [[ "${CFG_DRY_RUN:-false}" == true ]]; then
    echo "[DRYRUN] ${sudo_prefix[*]} apt-get update"
    echo "[DRYRUN] ${sudo_prefix[*]} DEBIAN_FRONTEND=noninteractive apt-get install -y ${missing_packages[*]}"
    return 0
  fi

  DEBIAN_FRONTEND=noninteractive "${sudo_prefix[@]}" apt-get update \
    || fail "apt-get update failed"
  DEBIAN_FRONTEND=noninteractive "${sudo_prefix[@]}" apt-get install -y "${missing_packages[@]}" \
    || fail "apt-get install failed for: ${missing_packages[*]}"

  local -a still_missing=()
  while read -r tool pkg; do
    [[ -z "$tool" || "$pkg" == "__pve__" ]] && continue
    command -v "$tool" >/dev/null 2>&1 || still_missing+=("$tool")
  done < <(_imageplus_tool_packages)

  if [[ ${#still_missing[@]} -gt 0 ]]; then
    fail "Tools still missing after install: ${still_missing[*]}"
  fi
  log "✅ All dependencies installed"
}

preflight_checks(){
  log "Verifying core dependencies..."
  local deps=(qm curl qemu-img)
  for d in "${deps[@]}"; do
    command -v "$d" >/dev/null || fail "Missing dependency: $d (run with deps installer enabled)"
  done
}

print_help(){
  cat <<'EOF'
Usage: ./imageplus.sh [OPTIONS]

Options:
  --update                  Download and update images, then create templates
  --update-images           Update/customize and create templates without downloading
  --download-only           Download images only
  --only <distro>           Process only the specified image name
  --storage <name>          Proxmox storage for disks and cloud-init
  --base-vm-id <id>         Starting VMID for created templates
  --custom-windows-versions <list>  Comma or JSON-like list of Windows versions to download and create templates for
  --custom-windows-download-links <list>  Comma or JSON-like list of Windows ISO download URLs corresponding to versions
  --redownload-isos         Re-download ISO files during update runs even if they already exist
  --parallel <n>            Number of parallel worker jobs for downloads/customization
  --configure               Run interactive configuration helper before execution
  --debug                   Enable debug logging
  --disable-windows         Do not download or create Windows templates
  --disable-efi             Disable EFI disk creation for templates
  --disable-tpm             Disable TPM state creation for templates
  --dry-run                 Print commands instead of executing them
  --silent                  Suppress non-error output
  -h, --help                Show this help message
EOF
}

parse_args(){
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --update)
        CFG_DOWNLOAD=true
        CFG_UPDATE=true
        CFG_DOWNLOAD_ONLY=false
        ;;
      --update-images)
        CFG_DOWNLOAD=false
        CFG_UPDATE=true
        CFG_DOWNLOAD_ONLY=false
        ;;
      --download-only)
        CFG_DOWNLOAD=true
        CFG_UPDATE=false
        CFG_DOWNLOAD_ONLY=true
        ;;
      --only)
        CFG_ONLY="${2:-}"
        shift
        ;;
      --storage)
        CFG_STORAGE="${2:-local-lvm}"
        shift
        ;;
      --base-vm-id)
        CFG_BASE_VMID="${2:-9000}"
        shift
        ;;
      --custom-windows-versions)
        CFG_WINDOWS_VERSIONS_RAW="${2:-}"
        shift
        ;;
      --custom-windows-download-links)
        CFG_WINDOWS_LINKS_RAW="${2:-}"
        shift
        ;;
      --redownload-isos)
        CFG_REDOWNLOAD_ISOS=true
        ;;
      --parallel)
        CFG_PARALLEL="${2:-4}"
        shift
        ;;
      --configure)
        # shellcheck disable=SC2034
        CFG_CONFIGURE=true
        ;;
      --debug)
        CFG_DEBUG=true
        CFG_SILENT=false
        enable_debug_trace
        ;;
      --disable-windows)
        CFG_WINDOWS=false
        ;;
      --disable-efi)
        CFG_DISABLE_EFI=true
        ;;
      --disable-tpm)
        CFG_DISABLE_TPM=true
        ;;
      --dry-run)
        CFG_DRY_RUN=true
        ;;
      --silent)
        CFG_SILENT=true
        ;;
      -h|--help)
        print_help
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
    shift
  done
}

print_summary(){
  echo
  echo "================ SUMMARY ================"
  echo "Download mode: ${CFG_DOWNLOAD:-true}"
  echo "Update mode: ${CFG_UPDATE:-true}"
  echo "Storage: ${CFG_STORAGE:-local-lvm}"
  echo "Base VMID: ${CFG_BASE_VMID:-9000}"
  echo "Windows enabled: ${CFG_WINDOWS:-true}"
  echo "Re-download ISOs: ${CFG_REDOWNLOAD_ISOS:-false}"
  echo "Parallel jobs: ${CFG_PARALLEL:-4}"
  echo "Debug: ${CFG_DEBUG:-false}"
  echo "EFI disabled: ${CFG_DISABLE_EFI:-false}"
  echo "TPM disabled: ${CFG_DISABLE_TPM:-false}"
  echo "Only: ${CFG_ONLY:-all}"
  echo
  echo "Downloaded images: ${#DOWNLOADS[@]}"
  [[ ${#DOWNLOADS[@]} -gt 0 ]] && printf '  - %s\n' "${DOWNLOADS[@]}"
  echo "Failed downloads: ${#FAILED_DOWNLOADS[@]}"
  [[ ${#FAILED_DOWNLOADS[@]} -gt 0 ]] && printf '  - %s\n' "${FAILED_DOWNLOADS[@]}"
  echo "Customized images: ${#CUSTOMIZED_IMAGES[@]}"
  [[ ${#CUSTOMIZED_IMAGES[@]} -gt 0 ]] && printf '  - %s\n' "${CUSTOMIZED_IMAGES[@]}"
  echo "Failed customizations: ${#FAILED_CUSTOMIZATIONS[@]}"
  [[ ${#FAILED_CUSTOMIZATIONS[@]} -gt 0 ]] && printf '  - %s\n' "${FAILED_CUSTOMIZATIONS[@]}"
  echo "Created templates: ${#CREATED_TEMPLATES[@]}"
  [[ ${#CREATED_TEMPLATES[@]} -gt 0 ]] && printf '  - %s\n' "${CREATED_TEMPLATES[@]}"
  echo "=========================================="
}
