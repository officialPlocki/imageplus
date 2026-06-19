#!/usr/bin/env bash

# Format: name|format|url
#   format: empty (=raw, will be converted to qcow2), "qcow2" (no convert), "iso" (no convert)
# `-g` — see VMIDS comment below; sourced from `load()` in imageplus.sh.
declare -ga IMAGES=(
  "debian-11|qcow2|https://cdimage.debian.org/cdimage/cloud/bullseye/daily/latest/debian-11-generic-amd64-daily.qcow2"
  "debian-12|qcow2|https://cdimage.debian.org/cdimage/cloud/bookworm/daily/latest/debian-12-generic-amd64-daily.qcow2"
  "debian-13|qcow2|https://cdimage.debian.org/cdimage/cloud/trixie/daily/latest/debian-13-generic-amd64-daily.qcow2"
  "ubuntu-22.04|qcow2|https://cloud-images.ubuntu.com/daily/server/jammy/current/jammy-server-cloudimg-amd64.img"
  "ubuntu-24.04|qcow2|https://cloud-images.ubuntu.com/daily/server/noble/current/noble-server-cloudimg-amd64.img"
  "ubuntu-26.04|qcow2|https://cloud-images.ubuntu.com/daily/server/resolute/current/resolute-server-cloudimg-amd64.img"
  "almalinux-9|qcow2|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
  "proxmox-9.1|iso|https://elizon.app/proxmox-ve_9.1-1.iso"
  "opnsense-26.1.6|iso|https://pkg.opnsense.org/releases/26.1.6/OPNsense-26.1.6-dvd-amd64.iso.bz2"
)

# `-g` is critical: this file is sourced from inside the `load()` function in
# imageplus.sh, and a bare `declare -A` inside a function creates a LOCAL
# variable that vanishes the moment `load` returns. Without -g, later callers
# see VMIDS as unset and bash silently treats `${VMIDS[$name]}` as arithmetic
# on the key, where `ubuntu-24.04` parses as `ubuntu - 24.04` and trips
# `set -u` on the bare word `ubuntu`.
declare -gA VMIDS=(
  ["debian-11"]=0
  ["debian-12"]=1
  ["debian-13"]=2
  ["ubuntu-22.04"]=10
  ["ubuntu-24.04"]=11
  ["ubuntu-26.04"]=12
  ["almalinux-9"]=80
  ["proxmox-9.1"]=90
  ["opnsense-26.1.6"]=91
)

declare -g WINDOWS_VM_BASE_OFFSET=30
declare -ga WINDOWS_ISO_URLS=()

declare -ga DOWNLOADS=()
declare -ga FAILED_DOWNLOADS=()

is_iso_url(){
  local url="${1:-}"
  [[ "$url" =~ \.iso($|\?) ]] && return 0
  [[ "$url" =~ \.iso\.bz2($|\?) ]] && return 0
  [[ "$url" =~ \.iso\.gz($|\?) ]] && return 0
  return 1
}

image_file_for_name(){
  local name="$1"
  local url="$2"
  local format="${3:-}"
  if [[ "$format" == iso ]]; then
    printf '%s/%s.iso' "$CFG_ISO_DIR" "$name"
  elif [[ -z "$format" ]] && is_iso_url "$url"; then
    printf '%s/%s.iso' "$CFG_ISO_DIR" "$name"
  else
    printf '%s/%s.qcow2' "$CFG_IMAGE_DIR" "$name"
  fi
}

template_vmid(){
  local name="$1"
  local fallback="$2"
  local offset="${VMIDS[$name]-}"
  if [[ -n "$offset" ]]; then
    echo $((CFG_BASE_VMID + offset))
    return
  fi
  if [[ "$name" =~ ^windows- ]]; then
    local index="${3:-0}"
    echo $((CFG_BASE_VMID + WINDOWS_VM_BASE_OFFSET + index))
    return
  fi
  echo "$fallback"
}

build_windows_urls(){
  WINDOWS_ISO_URLS=()
  if [[ -n "${CFG_WINDOWS_VERSIONS_RAW:-}" ]]; then
    local versions=()
    local links=()
    normalize_list "$CFG_WINDOWS_VERSIONS_RAW" versions
    normalize_list "$CFG_WINDOWS_LINKS_RAW" links
    local i
    for i in "${!versions[@]}"; do
      local ver="${versions[$i]}"
      local link="${links[$i]:-}"
      if [[ -n "$ver" && -n "$link" ]]; then
        WINDOWS_ISO_URLS+=("$ver|$link")
      fi
    done
  fi
}

download_all(){
  mkdir -p "$CFG_IMAGE_DIR" "$CFG_ISO_DIR"

  log "INFO: download_all started; image_dir=$CFG_IMAGE_DIR iso_dir=$CFG_ISO_DIR only=${CFG_ONLY:-all} windows=${CFG_WINDOWS:-true}"
  build_windows_urls
  local status_file
  status_file="$(mktemp "${TMPDIR:-/tmp}/imageplus.download.XXXX")"
  local total=0
  local skipped=0

  for e in "${IMAGES[@]}"; do
    local name format url
    IFS='|' read -r name format url <<< "$e"
    if [[ -n "${CFG_ONLY:-}" && "${CFG_ONLY}" != "$name" ]]; then
      ((skipped+=1))
      continue
    fi
    ((total+=1))
  done

  if [[ $total -gt 0 ]]; then
    log "⬇ Scheduling $total download task(s) with parallel=$CFG_PARALLEL"
  else
    log "INFO: No download tasks scheduled (skipped=$skipped, images=${#IMAGES[@]})"
  fi

  for e in "${IMAGES[@]}"; do
    local name format url
    IFS='|' read -r name format url <<< "$e"
    if [[ -n "${CFG_ONLY:-}" && "${CFG_ONLY}" != "$name" ]]; then
      continue
    fi
    log "  • $name"
    limit_background_jobs
    run_in_background download_job "$name" "$url" "$format" "$status_file"
  done

  wait_background_jobs

  while IFS=":" read -r status name; do
    case "$status" in
      OK)
        DOWNLOADS+=("$name")
        ;;
      FAIL)
        FAILED_DOWNLOADS+=("$name")
        ;;
    esac
  done < "$status_file"

  rm -f "$status_file"

  if [[ "${CFG_WINDOWS:-true}" == true && ${#WINDOWS_ISO_URLS[@]} -gt 0 && ( -z "${CFG_ONLY:-}" || "${CFG_ONLY}" == "windows" ) ]]; then
    download_windows_assets
  fi
}

download_windows_assets(){
  mkdir -p "$CFG_ISO_DIR"
  local status_file
  status_file="$(mktemp "${TMPDIR:-/tmp}/imageplus.windows.download.XXXX")"

  local total=0
  for e in "${WINDOWS_ISO_URLS[@]}"; do
    local version="${e%%|*}"
    local url="${e#*|}"
    local target="$CFG_ISO_DIR/windows-$version.iso"
    if [[ -f "$target" ]]; then
      log "Skipping existing Windows ISO $version"
      DOWNLOADS+=("windows-$version")
      continue
    fi
    ((total+=1))
  done

  if [[ $total -gt 0 ]]; then
    log "⬇ Scheduling $total Windows download task(s) with parallel=$CFG_PARALLEL"
  fi

  local virtio_target="$CFG_ISO_DIR/virtio.iso"
  for e in "${WINDOWS_ISO_URLS[@]}"; do
    local version="${e%%|*}"
    local url="${e#*|}"
    local target="$CFG_ISO_DIR/windows-$version.iso"
    if [[ -f "$target" ]]; then
      continue
    fi
    log "  • windows-$version"
    limit_background_jobs
    run_in_background download_windows_job "$target" "windows-$version" "$url" "$status_file"
  done
  if [[ ! -f "$virtio_target" ]]; then
    log "⬇ Downloading virtio drivers"
    limit_background_jobs
    run_in_background download_windows_job "$virtio_target" "virtio" "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso" "$status_file"
  fi

  wait_background_jobs

  while IFS=":" read -r status name; do
    case "$status" in
      OK)
        DOWNLOADS+=("$name")
        ;;
      FAIL)
        FAILED_DOWNLOADS+=("$name")
        ;;
    esac
  done < "$status_file"
  rm -f "$status_file"
}

download_file(){
  local target="$1"
  local url="$2"
  local log_file
  log_file="$(mktemp "${TMPDIR:-/tmp}/imageplus.download.log.XXXX")"

  if [[ "${CFG_DRY_RUN:-false}" == true ]]; then
    echo "[DRYRUN] download $url -> $target"
    rm -f "$log_file"
    return 0
  fi

  local rc=1

  # Prefer aria2c: multi-connection downloads bypass the per-connection throttling
  # that Ubuntu/Debian cloud mirrors apply (single curl streams collapse to ~1 MB/s).
  if command -v aria2c >/dev/null 2>&1; then
    local target_dir target_name
    target_dir="$(dirname "$target")"
    target_name="$(basename "$target")"
    local -a aria_args=(
      --dir="$target_dir"
      --out="$target_name"
      --continue=true
      --max-connection-per-server=16
      --split=16
      --min-split-size=1M
      --max-tries=20
      --retry-wait=5
      --connect-timeout=30
      # 30s idle kill (was 120) — Proxmox's enterprise ISO mirror likes to
      # leave TCP sessions alive but stop sending data; long idle waits made
      # the whole download appear hung at 10 MiB / 1.7 GiB for minutes.
      --timeout=30
      # 10 KB/s per-connection floor: high enough to evict dead workers fast,
      # low enough that near-finished workers at the tail of a multi-connection
      # download (which naturally see their speed drop) aren't culled.
      --lowest-speed-limit=10K
      --max-file-not-found=10
      --auto-file-renaming=false
      --allow-overwrite=true
      --file-allocation=none
      --console-log-level=warn
      --summary-interval=0
    )
    # Hard wall-clock cap: aria2c lacks a built-in equivalent of curl's
    # --max-time, so a server that accepts TCP but never sends bytes can keep
    # it spinning on retries past every per-connection timeout. After 30 min
    # the partial is wiped below and we fall through to curl.
    local aria_timeout=""
    command -v timeout >/dev/null 2>&1 && aria_timeout="timeout -k 10 1800"
    if [[ "${CFG_DEBUG:-false}" == true ]]; then
      $aria_timeout aria2c "${aria_args[@]}" "$url" 2>&1 | tee "$log_file"
      rc=${PIPESTATUS[0]}
    else
      $aria_timeout aria2c "${aria_args[@]}" "$url" >"$log_file" 2>&1
      rc=$?
    fi
    if [[ $rc -eq 0 ]]; then
      rm -f -- "$target.aria2"
      rm -f "$log_file"
      return 0
    fi
    # aria2c may leave a sparse file (pieces written out of order). Resuming
    # with `curl -C -` against a sparse file would skip the holes and produce
    # a corrupt image, so wipe the partial + control file before the fallback.
    log "ℹ aria2c failed for $target (rc=$rc); clearing partial and falling back to curl"
    rm -f -- "$target" "$target.aria2"
  fi

  if command -v curl >/dev/null 2>&1; then
    local -a resume_args=()
    if [[ -f "$target" && -s "$target" ]]; then
      resume_args=(-C -)
    fi
    local -a curl_args=(
      -fSL
      --retry 10
      --retry-delay 2
      --retry-all-errors
      --retry-connrefused
      --retry-max-time 7200
      --connect-timeout 30
      # Bail when the stream throttles below 50 KB/s for 90s so --retry
      # reconnects on a fresh TCP session (Ubuntu mirrors love to slow-drip).
      # Lower than aria2c's threshold because curl is single-stream — momentary
      # dips don't have parallel workers to compensate.
      --speed-time 90
      --speed-limit 51200
      --max-time 7200
      -o "$target"
      "$url"
    )
    if [[ "${CFG_DEBUG:-false}" == true ]]; then
      curl -v "${resume_args[@]}" "${curl_args[@]}" 2>&1 | tee "$log_file"
      rc=${PIPESTATUS[0]}
    else
      curl "${resume_args[@]}" "${curl_args[@]}" >"$log_file" 2>&1
      rc=$?
    fi
    if [[ $rc -eq 0 ]]; then
      rm -f "$log_file"
      return 0
    fi
  fi

  if command -v wget >/dev/null 2>&1; then
    : >"$log_file"
    local -a wget_args=(
      --continue
      --tries=20
      --waitretry=2
      --timeout=60
      --read-timeout=60
      -O "$target"
      "$url"
    )
    if command -v timeout >/dev/null 2>&1; then
      if [[ "${CFG_DEBUG:-false}" == true ]]; then
        timeout -k 10 7200 wget --server-response --progress=dot:giga --no-verbose -o /dev/stderr "${wget_args[@]}" 2>&1 | tee "$log_file"
      else
        timeout -k 10 7200 wget --no-verbose -o "$log_file" "${wget_args[@]}" >/dev/null 2>&1
      fi
    else
      if [[ "${CFG_DEBUG:-false}" == true ]]; then
        wget --server-response --progress=dot:giga --no-verbose -o /dev/stderr "${wget_args[@]}" 2>&1 | tee "$log_file"
      else
        wget --no-verbose -o "$log_file" "${wget_args[@]}" >/dev/null 2>&1
      fi
    fi
    rc=$?
    if [[ $rc -eq 0 ]]; then
      rm -f "$log_file"
      return 0
    fi
  elif ! command -v curl >/dev/null 2>&1 && ! command -v aria2c >/dev/null 2>&1; then
    rc=127
    echo "No downloader available (need aria2c, curl, or wget)" >"$log_file"
  fi

  log "⚠ Download failed for $target (rc=$rc)"
  tail -n 50 "$log_file" 2>/dev/null | sed 's/^/    /' || true
  rm -f "$log_file"
  return $rc
}

download_image(){
  local name="$1"
  local url="$2"
  local format="${3:-}"
  local dest
  dest="$(image_file_for_name "$name" "$url" "$format")"
  if [[ -f "$dest" ]]; then
    log "Skipping existing $name ($dest)"
    return 0
  fi

  local tmpfile
  tmpfile="$(mktemp "${TMPDIR:-/tmp}/imageplus.${name}.XXXX")"
  if ! download_file "$tmpfile" "$url"; then
    rm -f "$tmpfile"
    return 1
  fi

  # Decompress / extract if needed; payload becomes the actual image file.
  # Use parallel decompressors when available — bunzip2/gunzip are single-
  # threaded and a half-gig archive can chew one core for 5–10 minutes
  # silently. Always log start so the run doesn't look hung.
  local payload="$tmpfile"
  local extra_cleanup=""
  local src_size_mb
  src_size_mb=$(( $(stat -c%s "$tmpfile" 2>/dev/null || echo 0) / 1048576 ))
  case "$url" in
    *.tar.gz|*.tgz)
      local tmpdir
      tmpdir="$(mktemp -d --tmpdir="${TMPDIR:-/tmp}" "imageplus.${name}.XXXX")"
      log "📦 Extracting $name (tar.gz, ${src_size_mb} MiB)"
      if command -v pigz >/dev/null 2>&1; then
        pigz -dc "$tmpfile" | tar -x -C "$tmpdir"
      else
        tar -xzf "$tmpfile" -C "$tmpdir"
      fi
      rm -f "$tmpfile"
      local found
      found="$(find "$tmpdir" -type f \( -name '*.qcow2' -o -name '*.img' -o -name '*.raw' -o -name '*.iso' \) | head -n1)"
      if [[ -z "$found" ]]; then
        rm -rf "$tmpdir"
        return 1
      fi
      payload="$found"
      extra_cleanup="$tmpdir"
      ;;
    *.gz)
      local decompressed="${tmpfile}.decompressed"
      log "📦 Decompressing $name (gz, ${src_size_mb} MiB)"
      if command -v pigz >/dev/null 2>&1; then
        pigz -dc "$tmpfile" > "$decompressed"
      else
        gunzip -c "$tmpfile" > "$decompressed"
      fi
      rm -f "$tmpfile"
      payload="$decompressed"
      ;;
    *.bz2)
      local decompressed="${tmpfile}.decompressed"
      log "📦 Decompressing $name (bz2, ${src_size_mb} MiB) — single-threaded bunzip2 is slow on big files"
      if command -v pbzip2 >/dev/null 2>&1; then
        pbzip2 -dc "$tmpfile" > "$decompressed"
      else
        bunzip2 -c "$tmpfile" > "$decompressed"
      fi
      rm -f "$tmpfile"
      payload="$decompressed"
      log "✅ Decompressed $name"
      ;;
    *.xz)
      local decompressed="${tmpfile}.decompressed"
      log "📦 Decompressing $name (xz, ${src_size_mb} MiB)"
      xz -dc -T0 "$tmpfile" > "$decompressed"
      rm -f "$tmpfile"
      payload="$decompressed"
      ;;
  esac

  # Place into final destination based on format column.
  #   iso, qcow2 -> just move (no conversion)
  #   empty/raw  -> convert raw -> qcow2
  local rc=0
  case "$format" in
    iso|qcow2)
      mv "$payload" "$dest" || rc=1
      ;;
    ""|raw)
      qemu-img convert -f raw -O qcow2 "$payload" "$dest" || rc=1
      rm -f "$payload"
      ;;
    *)
      log "⚠ Unknown image format '$format' for $name"
      rm -f "$payload"
      rc=1
      ;;
  esac

  [[ -n "$extra_cleanup" ]] && rm -rf "$extra_cleanup"
  return $rc
}

download_job(){
  local name="$1"
  local url="$2"
  local format="$3"
  local status_file="$4"

  log "⬇ Downloading $name"
  if download_image "$name" "$url" "$format"; then
    echo "OK:$name" >> "$status_file"
    log "✅ Downloaded $name"
  else
    echo "FAIL:$name" >> "$status_file"
    log "❌ Failed $name"
  fi
}

download_windows_job(){
  local target="$1"
  local name="$2"
  local url="$3"
  local status_file="$4"

  if download_file "$target" "$url"; then
    echo "OK:$name" >> "$status_file"
  else
    echo "FAIL:$name" >> "$status_file"
  fi
}
