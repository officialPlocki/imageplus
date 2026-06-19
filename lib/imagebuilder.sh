#!/usr/bin/env bash
set -euo pipefail

declare -ga CUSTOMIZED_IMAGES=()
declare -ga FAILED_CUSTOMIZATIONS=()

prepare_images(){
  mkdir -p "$CFG_IMAGE_DIR"
  for f in "$CFG_IMAGE_DIR"/*; do
    [[ -f "$f" ]] || continue
    case "$f" in
      *.img|*.raw)
        local dest="${f%.*}.qcow2"
        log "INFO: Converting $f to $dest"
        qemu-img convert -f raw -O qcow2 "$f" "$dest"
        rm -f "$f"
        ;;
    esac
  done
}

customize_all(){
  local status_file
  status_file="$(mktemp "${TMPDIR:-/tmp}/imageplus.customize.XXXX")"
  local total=0

  for img in "$CFG_IMAGE_DIR"/*.qcow2; do
    [[ -f "$img" ]] || continue
    local name
    name="$(basename "$img" .qcow2)"
    if [[ -n "${CFG_ONLY:-}" && "${CFG_ONLY}" != "$name" ]]; then
      continue
    fi
    ((total+=1))
  done

  if [[ $total -gt 0 ]]; then
    log "⚙ Scheduling $total customization task(s) with parallel=$CFG_PARALLEL"
  fi

  for img in "$CFG_IMAGE_DIR"/*.qcow2; do
    [[ -f "$img" ]] || continue
    local name
    name="$(basename "$img" .qcow2)"
    if [[ -n "${CFG_ONLY:-}" && "${CFG_ONLY}" != "$name" ]]; then
      continue
    fi
    log "  • $name"
    limit_background_jobs
    run_in_background customize_job "$img" "$status_file"
  done

  wait_background_jobs

  while IFS=":" read -r status name; do
    case "$status" in
      OK)
        CUSTOMIZED_IMAGES+=("$name")
        ;;
      FAIL)
        FAILED_CUSTOMIZATIONS+=("$name")
        ;;
    esac
  done < "$status_file"

  rm -f "$status_file"
}

customize_job(){
  local img="$1"
  local status_file="$2"
  local name
  name="$(basename "$img" .qcow2)"

  if customize "$img"; then
    echo "OK:$name" >> "$status_file"
  else
    echo "FAIL:$name" >> "$status_file"
  fi
}

customize() {
  local img="$1"
  local name
  name="$(basename "$img" .qcow2)"

  qemu-img resize "$img" +5G

  if [[ "$name" == ubuntu* ]]; then
    if ! virt-customize -a "$img" --run-command 'growpart /dev/sda 1' --run-command 'resize2fs /dev/sda1' --no-logfile >/dev/null 2>&1; then
      log "⚠ Failed to expand Ubuntu partition for $name; continuing with customization"
    fi
  fi

  if [[ "${CFG_DRY_RUN:-false}" == true ]]; then
    log "[DRYRUN] customize $name"
    return 0
  fi

  if [[ ! -f "$img" ]]; then
    log "⚠ Image not found: $img"
    return 1
  fi

  # OpenSSH uses first keyword occurrence wins across sshd_config + sshd_config.d.
  # 09-* enables password SSH when cloud-init did not deploy keys yet (vendor default user, e.g. ubuntu/debian).
  # First-boot cloud-init runcmd removes 09-* and adds 00-* when a real key appears in root or /home/*/.ssh.
  local tmp_script tmp_cloud tmp_dropin
  tmp_script="$(mktemp "${TMPDIR:-/tmp}/imageplus.sshd-if-keys.XXXX")"
  tmp_cloud="$(mktemp "${TMPDIR:-/tmp}/imageplus.99-proxmox.XXXX")"
  tmp_dropin="$(mktemp "${TMPDIR:-/tmp}/imageplus.sshd-fallback.XXXX")"

  cat > "$tmp_script" <<'EOS'
#!/bin/sh
set -eu
found=
for keys in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
  [ -f "$keys" ] || continue
  if grep -qE '^[^#]*(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|ssh-dss|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)' "$keys"; then
    found=1
    break
  fi
done
if [ "$found" = 1 ]; then
  rm -f /etc/ssh/sshd_config.d/09-imageplus-password-fallback.conf
  umask 022
  printf '%s\n' \
    '# imageplus: cloud-init deployed SSH keys — password SSH off' \
    'PasswordAuthentication no' \
    'PermitRootLogin prohibit-password' \
    'KbdInteractiveAuthentication no' \
    > /etc/ssh/sshd_config.d/00-imageplus-keyonly.conf
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
fi
EOS

  cat > "$tmp_cloud" <<'EOF'
datasource_list: [ NoCloud, ConfigDrive ]
runcmd:
  - [ /usr/local/sbin/imageplus-sshd-if-keys.sh ]
EOF

  cat > "$tmp_dropin" <<'EOF'
# imageplus: SSH password fallback when no cloud-init keys yet (removed at first boot if keys present)
PasswordAuthentication yes
EOF

  local common=(
    --run-command 'mkdir -p /etc/ssh/sshd_config.d /usr/local/sbin'
    --run-command 'echo "install algif_aead /bin/false" > /etc/modprobe.d/disable-algif.conf || true'
    --run-command 'rmmod algif_aead || true'
    --upload "$tmp_dropin:/etc/ssh/sshd_config.d/09-imageplus-password-fallback.conf"
    --upload "$tmp_script:/usr/local/sbin/imageplus-sshd-if-keys.sh"
    --run-command 'chmod +x /usr/local/sbin/imageplus-sshd-if-keys.sh'
    --upload "$tmp_cloud:/etc/cloud/cloud.cfg.d/99-proxmox.cfg"
    --run-command 'sed -i "s/KbdInteractiveAuthentication [Nn]o/#KbdInteractiveAuthentication no/" /etc/ssh/sshd_config || true'
    --run-command 'sed -i "s/[#M]axAuthTries 6/MaxAuthTries 20/" /etc/ssh/sshd_config || true'
    --run-command 'systemctl enable qemu-guest-agent || true'
    --run-command 'systemctl enable cron || true'
    --run-command 'cloud-init clean --logs --seed || true'
    --run-command 'truncate -s 0 /etc/machine-id || true'
    --run-command 'systemctl reload ssh || systemctl reload sshd || true'
  )

  local distro_cmds=()
  case "$name" in
    *debian*|*ubuntu*)
      distro_cmds=(
        --update
        --install 'qemu-guest-agent,sudo,curl,wget'
        --run-command 'systemctl enable qemu-guest-agent || true'
      )
      ;;
    *fedora*|*almalinux*|*alma*)
      distro_cmds=(
        --update
        --install 'qemu-guest-agent'
      )
      ;;
    *)
      distro_cmds=(
        --install 'qemu-guest-agent'
      )
      ;;
  esac

  local ok=false
  if [[ "${CFG_SILENT:-false}" == true ]]; then
    if virt-customize -a "$img" "${distro_cmds[@]}" "${common[@]}" --no-logfile >/dev/null 2>&1; then
      ok=true
    fi
  else
    if virt-customize -a "$img" "${distro_cmds[@]}" "${common[@]}" 2>&1 | sed -u "s/^/[$name] /"; then
      ok=true
    fi
  fi

  rm -f "$tmp_script" "$tmp_cloud" "$tmp_dropin"

  if [[ "$ok" == true ]]; then
    return 0
  fi
  return 1
}
