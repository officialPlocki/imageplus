#!/usr/bin/env bash
set -euo pipefail

declare -ga CREATED_TEMPLATES=()

# Proxmox-side ISO storage. `qm set --ide2 /tmp/iso/foo.iso` rejects raw paths
# because they don't belong to any registered PVE storage. Templates must
# reference ISOs as `local:iso/foo.iso`, which physically live in
# /var/lib/vz/template/iso/.
PVE_ISO_STORAGE="${PVE_ISO_STORAGE:-local}"
PVE_ISO_DIR="${PVE_ISO_DIR:-/var/lib/vz/template/iso}"

# Move (or copy if cross-fs / mv refused) the downloaded ISO into the PVE ISO
# storage and return the storage-style reference (e.g. `local:iso/foo.iso`).
# Replaces any existing file with the same name. Logs go to stderr so the
# captured stdout is exactly the ref string.
import_iso_to_pve_storage(){
  local src="$1"
  local basename
  basename="$(basename "$src")"
  local dest="$PVE_ISO_DIR/$basename"

  if [[ "${CFG_DRY_RUN:-false}" == true ]]; then
    echo "[DRYRUN] mv -f $src $dest" >&2
    printf '%s:iso/%s' "$PVE_ISO_STORAGE" "$basename"
    return 0
  fi

  mkdir -p "$PVE_ISO_DIR"
  if [[ -f "$dest" ]]; then
    log "Replacing existing ISO at $dest" >&2
  else
    log "Importing $basename → $dest" >&2
  fi
  if ! mv -f "$src" "$dest" 2>/dev/null; then
    cp -f "$src" "$dest"
  fi
  printf '%s:iso/%s' "$PVE_ISO_STORAGE" "$basename"
}

get_storage_type(){
  local storage="$1"
  if command -v pvesm >/dev/null 2>&1; then
    pvesm status --storage "$storage" 2>/dev/null | awk 'NR==2 {print $2}'
  fi
}

build_disk_ref(){
  local storage="$1"
  local vmid="$2"
  printf '%s:vm-%s-disk-0' "$storage" "$vmid"
}

add_efi_and_tpm_to_vm(){
  local vmid="$1"
  local storage="$CFG_STORAGE"
  if [[ "${CFG_DISABLE_EFI:-false}" != true ]]; then
    local storage_type
    storage_type="$(get_storage_type "$storage" || true)"
    local efidisk_arg
    if [[ "$storage_type" == "dir" ]]; then
      efidisk_arg="${storage}:1,efitype=4m,format=qcow2,pre-enrolled-keys=1"
    else
      efidisk_arg="${storage}:1,efitype=4m,format=raw,pre-enrolled-keys=1"
    fi
    run qm set "$vmid" --efidisk0 "$efidisk_arg"
  fi

  if [[ "${CFG_DISABLE_TPM:-false}" != true ]]; then
    run qm set "$vmid" --tpmstate0 "${storage}:1,version=v2.0"
  fi
}

configure_vm_firewall(){
  local vmid="$1"
  if [[ "${CFG_DRY_RUN:-false}" == true ]]; then
    echo "[DRYRUN] write /etc/pve/firewall/$vmid.fw with ipfilter enabled + ipfilter-net0 ipset"
    return 0
  fi
  mkdir -p /etc/pve/firewall
  # `ipfilter: 1` in [OPTIONS] is what flips the per-NIC IP-filter switch in
  # the GUI to "Yes" — the ipset alone is just the whitelist and does NOT
  # enable filtering. The empty `[IPSET ipfilter-net0]` block is kept so the
  # ipset is visible in the GUI and ready for the operator to populate after
  # cloning (link-local IPv6 from MAC is auto-allowed by Proxmox).
  cat > "/etc/pve/firewall/$vmid.fw" <<'EOF'
[OPTIONS]
enable: 1
ipfilter: 1
policy_in: ACCEPT
policy_out: ACCEPT

[IPSET ipfilter-net0]

EOF
}

check_vmid_collisions(){
  local base_vmid="${CFG_BASE_VMID:-9000}"
  if ! command -v qm >/dev/null 2>&1; then
    return 0
  fi

  local existing_ids
  existing_ids=$(qm list 2>/dev/null | awk 'NR>1 {print $1}')
  local collisions=()

  for e in "${IMAGES[@]}"; do
    local name="${e%%|*}"
    if [[ -n "${CFG_ONLY:-}" && "${CFG_ONLY}" != "$name" ]]; then
      continue
    fi
    local target
    target="$(template_vmid "$name" "$base_vmid")"
    for id in $existing_ids; do
      if [[ "$id" == "$target" ]]; then
        collisions+=("$target")
      fi
    done
  done

  if [[ "${CFG_WINDOWS:-true}" == true ]]; then
    local windows_versions=()
    normalize_list "${CFG_WINDOWS_VERSIONS_RAW:-}" windows_versions
    for i in "${!windows_versions[@]}"; do
      local target=$((base_vmid + WINDOWS_VM_BASE_OFFSET + i))
      for id in $existing_ids; do
        if [[ "$id" == "$target" ]]; then
          collisions+=("$target")
        fi
      done
    done
  fi

  for iso in "$CFG_ISO_DIR"/*.iso; do
    [[ -f "$iso" ]] || continue
    local name
    name="$(basename "$iso" .iso)"
    if [[ "$name" == windows-* ]]; then
      continue
    fi
    if [[ -n "${CFG_ONLY:-}" && "${CFG_ONLY}" != "$name" ]]; then
      continue
    fi
    local target
    target="$(template_vmid "$name" "$((base_vmid + 100))")"
    for id in $existing_ids; do
      if [[ "$id" == "$target" ]]; then
        collisions+=("$target")
      fi
    done
  done

  if [[ ${#collisions[@]} -gt 0 ]]; then
    echo "⚠ VMID collision(s) detected in the expected range:"
    for c in "${collisions[@]}"; do
      echo "  - $c"
    done
    echo "Consider choosing a different base VMID to avoid overwriting existing VMs."
    return 1
  fi
  return 0
}

create_all_templates(){
  local found=false

  if ! check_vmid_collisions; then
    log "⚠ VMID collision(s) detected; continuing with creation may overwrite existing VMs."
  fi

  for e in "${IMAGES[@]}"; do
    local name="${e%%|*}"
    if [[ -n "${CFG_ONLY:-}" && "${CFG_ONLY}" != "$name" ]]; then
      continue
    fi
    local img="$CFG_IMAGE_DIR/$name.qcow2"
    [[ -f "$img" ]] || continue
    found=true
    local vmid
    vmid="$(template_vmid "$name" "${CFG_BASE_VMID:-9000}")"
    create_vm "$vmid" "$img" "$name"
  done

  if [[ "${CFG_WINDOWS:-true}" == true && ( -z "${CFG_ONLY:-}" || "${CFG_ONLY}" == "windows" ) ]]; then
    create_windows
  fi

  create_iso_templates

  if [[ "$found" == false && ${#CREATED_TEMPLATES[@]} -eq 0 ]]; then
    log "INFO: No images or ISOs were found for template creation."
  fi
}

create_vm(){
  local id="$1"
  local img="$2"
  local name="$3"

  log "▶ Creating VM $name ($id)"
  try_run qm destroy "$id" --purge
  run qm create "$id" --name "$name" --memory 512 --net0 virtio,bridge=vmbr0,firewall=1 --ostype l26
  run qm importdisk "$id" "$img" "$CFG_STORAGE"
  run qm set "$id" --scsihw virtio-scsi-pci --scsi0 "$(build_disk_ref "$CFG_STORAGE" "$id")" --ide2 "${CFG_STORAGE}:cloudinit" --boot c --bootdisk scsi0 --serial0 socket
  run qm set "$id" --machine q35 --agent enabled=1 --cpu host --onboot 1
  add_efi_and_tpm_to_vm "$id"
  configure_vm_firewall "$id"
  run qm template "$id"
  CREATED_TEMPLATES+=("$name:$id")
}

# ---------------- WINDOWS ----------------
create_windows(){
  local id=$((CFG_BASE_VMID + WINDOWS_VM_BASE_OFFSET))

  # Import virtio once before the loop — it's referenced by every Windows
  # template, and `import_iso_to_pve_storage` moves the source out of /tmp/iso.
  local virtio_ref=""
  if [[ -f "$CFG_ISO_DIR/virtio.iso" ]]; then
    virtio_ref="$(import_iso_to_pve_storage "$CFG_ISO_DIR/virtio.iso")"
  fi

  for iso in "$CFG_ISO_DIR"/windows-*.iso; do
    [[ -f "$iso" ]] || continue
    local name
    name="$(basename "$iso" .iso)"
    if [[ -n "${CFG_ONLY:-}" && "${CFG_ONLY}" != "$name" ]]; then
      continue
    fi
    log "▶ Creating Windows template $name ($id)"

    local windows_ref
    windows_ref="$(import_iso_to_pve_storage "$iso")"

    try_run qm destroy "$id" --purge
    run qm create "$id" \
      --name "$name" \
      --memory 4096 \
      --machine q35 \
      --bios ovmf \
      --net0 virtio,bridge=vmbr0,firewall=1

    run qm set "$id" \
      --cdrom "$windows_ref" \
      --scsi0 "${CFG_STORAGE}:32"

    if [[ -n "$virtio_ref" ]]; then
      run qm set "$id" \
        --ide2 "$virtio_ref",media=cdrom
    fi

    run qm set "$id" \
      --efidisk0 "${CFG_STORAGE}:1" \
      --tpmstate0 "${CFG_STORAGE}:1"

    configure_vm_firewall "$id"

    run qm template "$id"
    CREATED_TEMPLATES+=("$name:$id")

    ((id+=1))
  done
}

create_iso_templates(){
  for iso in "$CFG_ISO_DIR"/*.iso; do
    [[ -f "$iso" ]] || continue
    local name
    name="$(basename "$iso" .iso)"
    if [[ "$name" == windows-* ]]; then
      continue
    fi
    if [[ -n "${CFG_ONLY:-}" && "${CFG_ONLY}" != "$name" ]]; then
      continue
    fi

    local vmid
    vmid="$(template_vmid "$name" "$((CFG_BASE_VMID + 100))")"
    log "▶ Creating ISO template $name ($vmid)"
    local iso_ref
    iso_ref="$(import_iso_to_pve_storage "$iso")"
    try_run qm destroy "$vmid" --purge
    run qm create "$vmid" --name "$name" --memory 2048 --net0 virtio,bridge=vmbr0,firewall=1 --ostype l26
    run qm set "$vmid" --ide2 "$iso_ref",media=cdrom

    local storage_type
    storage_type="$(get_storage_type "$CFG_STORAGE" || true)"
    local disk_arg
    if [[ "$storage_type" == "dir" ]]; then
      disk_arg="${CFG_STORAGE}:32,format=qcow2"
    else
      disk_arg="${CFG_STORAGE}:32,format=raw"
    fi

    run qm set "$vmid" \
      --scsihw virtio-scsi-pci \
      --scsi0 "$disk_arg" \
      --ide0 "${CFG_STORAGE}:cloudinit" \
      --boot order=scsi0\;ide2 \
      --bootdisk scsi0 \
      --serial0 socket
    run qm set "$vmid" --machine q35 --agent enabled=1 --cpu host --onboot 1
    add_efi_and_tpm_to_vm "$vmid"
    configure_vm_firewall "$vmid"
    run qm template "$vmid"
    CREATED_TEMPLATES+=("$name:$vmid")
  done
}