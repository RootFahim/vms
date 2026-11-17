#!/usr/bin/env bash
# =============================================================================
# RF VM MANAGER - QEMU/KVM Virtual Machine Manager
# =============================================================================
set -euo pipefail

# ------------------------------- Globals ------------------------------------
RFVM_VERSION="1.0.0"
RFVM_BASE="/var/lib/rfvm"
RFVM_VMS="${RFVM_BASE}/vms"
RFVM_IMAGES="${RFVM_BASE}/images"
RFVM_PORTS_LOCK="${RFVM_BASE}/ports.lock"
RFVM_LOG="${RFVM_BASE}/rfvm.log"
RFVM_BRIDGE="${RFVM_BRIDGE:-br0}"

# Colors
if [[ -t 1 ]]; then
  C_RST=$'\e[0m'; C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'
  C_BLU=$'\e[34m'; C_MAG=$'\e[35m'; C_CYN=$'\e[36m'; C_WHT=$'\e[1;37m'
  C_DIM=$'\e[2m'; C_BOLD=$'\e[1m'
else
  C_RST=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_MAG=""; C_CYN=""
  C_WHT=""; C_DIM=""; C_BOLD=""
fi

# --------------------------- Logging / UI ------------------------------------
log() {
  local msg="[$(date '+%F %T')] $*"
  mkdir -p "$RFVM_BASE"
  echo "$msg" >> "$RFVM_LOG"
}

info()   { echo -e "${C_BLU}[i]${C_RST} $*"; }
ok()     { echo -e "${C_GRN}[✓]${C_RST} $*"; }
warn()   { echo -e "${C_YEL}[!]${C_RST} $*"; }
err()    { echo -e "${C_RED}[✗]${C_RST} $*" >&2; }
die()    { err "$*"; exit 1; }

pause() { read -rp "${C_DIM}Press ENTER to continue...${C_RST}" _ || true; }

banner() {
  clear
  cat <<EOF
${C_CYN}${C_BOLD}
 ██████╗ ███████╗    ██╗   ██╗███╗   ███╗
 ██╔══██╗██╔════╝    ██║   ██║████╗ ████║
 ██████╔╝█████╗      ██║   ██║██╔████╔██║
 ██╔══██╗██╔══╝      ╚██╗ ██╔╝██║╚██╔╝██║
 ██║  ██║██║          ╚████╔╝ ██║ ╚═╝ ██║
 ╚═╝  ╚═╝╚═╝           ╚═══╝  ╚═╝     ╚═╝
        ${C_WHT}MANAGER v${RFVM_VERSION}${C_CYN}  ·  QEMU/KVM Virtualization
${C_RST}
EOF
}

# --------------------------- Validations -------------------------------------
valid_name()    { [[ "$1" =~ ^[a-z][a-z0-9-]{1,30}$ ]]; }
valid_port()    { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_hostname(){ [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]]; }
valid_user()    { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }

port_in_use_host() {
  local p="$1"
  ss -ltn "sport = :${p}" 2>/dev/null | awk 'NR>1{print; exit}' | grep -q . && return 0
  return 1
}

# Atomically reserve a port. Returns 0 on success.
reserve_port() {
  local p="$1" vm="$2"
  mkdir -p "$RFVM_BASE"
  touch "$RFVM_PORTS_LOCK"
  (
    flock -x 9
    if grep -q "^${p} " "$RFVM_PORTS_LOCK"; then
      echo "Port ${p} already reserved by $(awk -v p="$p" '$1==p{print $2}' "$RFVM_PORTS_LOCK")" >&2
      exit 2
    fi
    echo "${p} ${vm}" >> "$RFVM_PORTS_LOCK"
  ) 9>"${RFVM_PORTS_LOCK}.lock" || return 1
  return 0
}

release_port() {
  local p="$1"
  [[ -f "$RFVM_PORTS_LOCK" ]] || return 0
  (
    flock -x 9
    grep -v "^${p} " "$RFVM_PORTS_LOCK" > "${RFVM_PORTS_LOCK}.tmp" || true
    mv "${RFVM_PORTS_LOCK}.tmp" "$RFVM_PORTS_LOCK"
  ) 9>"${RFVM_PORTS_LOCK}.lock"
}

port_from_vm() { awk -v n="$1" '$2==n{print $1; exit}' "$RFVM_PORTS_LOCK" 2>/dev/null || true; }

# ---------------------------- Dependencies -----------------------------------
detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then echo apt; return; fi
  if command -v dnf >/dev/null 2>&1;     then echo dnf; return; fi
  if command -v yum >/dev/null 2>&1;     then echo yum; return; fi
  echo none
}

ensure_root() { [[ $EUID -eq 0 ]] || die "Must run as root."; }

install_deps() {
  ensure_root
  local pm; pm=$(detect_pkg_mgr)
  [[ "$pm" == "none" ]] && die "Unsupported host: no apt/dnf/yum."

  local pkgs=()
  case "$pm" in
    apt) pkgs=(qemu-system-x86 qemu-utils cloud-image-utils wget curl openssh-client iproute2 bridge-utils genisoimage) ;;
    dnf|yum) pkgs=(qemu-kvm qemu-img cloud-utils wget curl openssh-clients iproute bridge-utils genisoimage) ;;
  esac

  local missing=()
  for p in "${pkgs[@]}"; do
    case "$pm" in
      apt) dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p") ;;
      dnf|yum) rpm -q "$p" >/dev/null 2>&1 || missing+=("$p") ;;
    esac
  done
  [[ ${#missing[@]} -eq 0 ]] && { ok "All dependencies present."; return; }

  info "Installing: ${missing[*]}"
  case "$pm" in
    apt) apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" ;;
    dnf|yum) "$pm" install -y "${missing[@]}" ;;
  esac
  ok "Dependencies installed."
}

check_deps() {
  local missing=()
  for c in qemu-system-x86_64 qemu-img cloud-localds wget ss; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Missing: ${missing[*]}"
    read -rp "Install dependencies now? [y/N]: " a
    [[ "$a" =~ ^[Yy]$ ]] && install_deps || die "Cannot continue without dependencies."
  fi
}

kvm_available() {
  [[ -r /dev/kvm && -w /dev/kvm ]] && return 0
  return 1
}

# ---------------------------- OS Catalog -------------------------------------
# name|label|url
OS_CATALOG=(
  "ubuntu2204|Ubuntu 22.04 LTS|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  "ubuntu2404|Ubuntu 24.04 LTS|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  "debian11|Debian 11 (bullseye)|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2"
  "debian12|Debian 12 (bookworm)|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
  "fedora|Fedora Cloud 40|https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-40-1.14.x86_64.qcow2"
  "centos9|CentOS Stream 9|https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"
  "alma9|AlmaLinux 9|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
  "rocky9|Rocky Linux 9|https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
)

os_lookup() {
  local key="$1"
  for entry in "${OS_CATALOG[@]}"; do
    IFS='|' read -r k label url <<< "$entry"
    [[ "$k" == "$key" ]] && { echo "$label|$url"; return 0; }
  done
  return 1
}

list_os_menu() {
  banner
  echo -e "${C_WHT}Select Operating System:${C_RST}\n"
  local i=1
  for entry in "${OS_CATALOG[@]}"; do
    IFS='|' read -r k label url <<< "$entry"
    printf "  ${C_CYN}%2d)${C_RST} %s\n" "$i" "$label"
    ((i++))
  done
  echo
}

pick_os() {
  list_os_menu
  local n; read -rp "Choice [1-${#OS_CATALOG[@]}]: " n
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#OS_CATALOG[@]} )) || { err "Invalid"; return 1; }
  local entry="${OS_CATALOG[$((n-1))]}"
  IFS='|' read -r k label url <<< "$entry"
  PICKED_OS_KEY="$k"; PICKED_OS_LABEL="$label"; PICKED_OS_URL="$url"
}

fetch_image() {
  local key="$1" url="$2"
  mkdir -p "$RFVM_IMAGES"
  local out="${RFVM_IMAGES}/${key}.qcow2"
  if [[ -s "$out" ]]; then
    ok "Image cached: $out"
    IMAGE_PATH="$out"
    return 0
  fi
  info "Downloading $(basename "$url") ..."
  if ! wget -q --show-progress -O "${out}.part" "$url"; then
    rm -f "${out}.part"
    err "Download failed."; return 1
  fi
  mv "${out}.part" "$out"
  ok "Image ready: $out"
  IMAGE_PATH="$out"
}

# ----------------------------- VM helpers ------------------------------------
vm_dir()      { echo "${RFVM_VMS}/$1"; }
vm_conf()     { echo "${RFVM_VMS}/$1/vm.conf"; }
vm_disk()     { echo "${RFVM_VMS}/$1/disk.qcow2"; }
vm_seed()     { echo "${RFVM_VMS}/$1/seed.iso"; }
vm_pid()      { echo "${RFVM_VMS}/$1/qemu.pid"; }
vm_log()      { echo "${RFVM_VMS}/$1/console.log"; }

vm_exists() { [[ -f "$(vm_conf "$1")" ]]; }

list_vms() {
  [[ -d "$RFVM_VMS" ]] || return 0
  find "$RFVM_VMS" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
}

load_vm() {
  local name="$1"
  vm_exists "$name" || { err "VM '$name' not found."; return 1; }
  # shellcheck disable=SC1090
  ( source "$(vm_conf "$name")"; declare -p VM_NAME VM_ID VM_OS VM_OS_LABEL VM_USER VM_HOSTNAME \
      VM_RAM VM_CPUS VM_DISK VM_SSH_PORT VM_NET_MODE VM_BRIDGE VM_CREATED VM_DISPLAY \
      > "/tmp/rfvm_load.$$" )
  source "/tmp/rfvm_load.$$"; rm -f "/tmp/rfvm_load.$$"
}

vm_running() {
  local name="$1" pidf; pidf=$(vm_pid "$name")
  [[ -f "$pidf" ]] || return 1
  local pid; pid=$(cat "$pidf" 2>/dev/null || true)
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

vm_status_str() {
  if vm_running "$1"; then echo "${C_GRN}● RUNNING${C_RST}"; else echo "${C_DIM}○ STOPPED${C_RST}"; fi
}

vm_ip() {
  local name="$1"
  vm_running "$name" || { echo "-"; return; }
  local mac port
  mac=$(grep -oP 'MAC=\K.*' "$(vm_conf "$name")" 2>/dev/null | head -1 || true)
  # Prefer neighbor table, fallback to SLIRP gateway guess
  local ip
  ip=$(ip neigh show 2>/dev/null | awk -v m="$mac" 'tolower($0) ~ tolower(m) {print $1; exit}')
  if [[ -z "${ip:-}" ]]; then
    # For NAT, guest usually gets 10.0.2.15
    port=$(port_from_vm "$name" || true)
    [[ -n "${port:-}" ]] && ip="127.0.0.1(NAT)"
  fi
  echo "${ip:--}"
}

# ------------------------- Systemd unit mgmt ---------------------------------
systemd_unit() { echo "/etc/systemd/system/rfvm-${1}.service"; }

write_systemd_unit() {
  local name="$1"
  local unit; unit=$(systemd_unit "$name")
  cat > "$unit" <<EOF
[Unit]
Description=RFVM VM ${name}
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=$(vm_pid "$name")
ExecStart=/usr/local/sbin/rfvm-internal-start ${name}
ExecStop=/usr/local/sbin/rfvm-internal-stop ${name}
Restart=no

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

install_internal_helpers() {
  cat > /usr/local/sbin/rfvm-internal-start <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/local/sbin/rfvm --daemon-start "$1"
EOF
  cat > /usr/local/sbin/rfvm-internal-stop <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/local/sbin/rfvm --daemon-stop "$1"
EOF
  chmod +x /usr/local/sbin/rfvm-internal-start /usr/local/sbin/rfvm-internal-stop
  # Self-install main script
  local self; self="$(readlink -f "$0")"
  if [[ "$self" != "/usr/local/sbin/rfvm" ]]; then
    cp -f "$self" /usr/local/sbin/rfvm && chmod +x /usr/local/sbin/rfvm
  fi
}

# ---------------------------- QEMU launch ------------------------------------
build_qemu_args() {
  local name="$1"
  load_vm "$name" || return 1
  local args=()

  # Machine / acceleration
  if kvm_available; then
    args+=(-enable-kvm -cpu host -machine q35,accel=kvm)
  else
    args+=(-machine q35 -cpu max)
    warn "KVM unavailable; running with TCG (slow)."
  fi

  args+=(
    -name "$VM_NAME"
    -m "$VM_RAM"
    -smp "$VM_CPUS"
    -pidfile "$(vm_pid "$name")"
    -daemonize
    -D "$(vm_dir "$name")/qemu.log"
    -serial "file:$(vm_log "$name")"
    -monitor "unix:$(vm_dir "$name")/monitor.sock,server,nowait"
  )

  # Disk
  args+=(
    -drive "file=$(vm_disk "$name"),if=virtio,format=qcow2,cache=writeback,discard=unmap"
    -drive "file=$(vm_seed "$name"),if=virtio,format=raw,readonly=on"
  )

  # Networking
  if [[ "$VM_NET_MODE" == "bridge" ]]; then
    local tap="rfvm-${VM_NAME:0:10}"
    # Tap created by qemu via helper; require bridge to exist
    args+=(-netdev "bridge,id=net0,br=${VM_BRIDGE},helper=/usr/lib/qemu/qemu-bridge-helper")
  else
    # NAT / SLIRP with hostfwd
    args+=(-netdev "user,id=net0,hostfwd=tcp::${VM_SSH_PORT}-:22")
  fi
  args+=(-device "virtio-net-pci,netdev=net0")

  # Display
  if [[ "$VM_DISPLAY" == "gui" ]]; then
    args+=(-vga virtio)
  else
    args+=(-nographic -display none)
  fi

  echo "${args[@]}"
}

start_vm_internal() {
  local name="$1"
  load_vm "$name" || return 1
  if vm_running "$name"; then ok "VM '$name' already running."; return 0; fi

  # Check port availability (NAT)
  if [[ "$VM_NET_MODE" == "nat" ]]; then
    if port_in_use_host "$VM_SSH_PORT"; then
      err "SSH port ${VM_SSH_PORT} is already in use on host."
      return 1
    fi
  fi

  local args; args=$(build_qemu_args "$name")
  # shellcheck disable=SC2086
  if ! qemu-system-x86_64 $args; then
    err "QEMU failed to start '$name'."
    return 1
  fi
  sleep 1
  if vm_running "$name"; then
    ok "VM '$name' started (pid $(cat "$(vm_pid "$name")"))."
    log "started VM $name"
    return 0
  fi
  err "VM '$name' did not come up. See $(vm_dir "$name")/qemu.log"
  return 1
}

stop_vm_internal() {
  local name="$1"
  load_vm "$name" || return 1
  vm_running "$name" || { ok "VM '$name' already stopped."; return 0; }
  local pid; pid=$(cat "$(vm_pid "$name")")
  kill -TERM "$pid" 2>/dev/null || true
  for _ in {1..20}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    warn "Graceful shutdown timed out; sending SIGKILL to qemu pid $pid."
    kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$(vm_pid "$name")"
  ok "VM '$name' stopped."
  log "stopped VM $name"
}

# -------------------------- VM creation flow ---------------------------------
gen_vm_id() { echo "rfvm-$(date +%s)-$RANDOM"; }

create_vm() {
  banner
  echo -e "${C_WHT}── Create New VM ──${C_RST}\n"

  local name
  while :; do
    read -rp "VM name (lowercase, dashes ok): " name
    valid_name "$name" || { err "Invalid name (a-z start, a-z0-9-, ≤31)."; continue; }
    vm_exists "$name" && { err "VM '$name' already exists."; continue; }
    break
  done

  local hostname; read -rp "Hostname [${name}]: " hostname; hostname=${hostname:-$name}
  valid_hostname "$hostname" || die "Invalid hostname."

  pick_os || return 1
  local os_key="$PICKED_OS_KEY" os_label="$PICKED_OS_LABEL" os_url="$PICKED_OS_URL"

  local user
  while :; do
    read -rp "Username: " user
    valid_user "$user" && break
    err "Invalid username."
  done

  local pass pass2
  while :; do
    read -rsp "Password: " pass; echo
    read -rsp "Confirm:  " pass2; echo
    [[ "$pass" == "$pass2" && ${#pass} -ge 8 ]] && break
    err "Passwords differ or too short (≥8)."
  done

  local ram cpus disk
  read -rp "RAM MB [2048]: " ram; ram=${ram:-2048}
  [[ "$ram" =~ ^[0-9]+$ ]] && (( ram >= 512 )) || die "RAM must be ≥512."
  read -rp "CPU cores [2]: " cpus; cpus=${cpus:-2}
  [[ "$cpus" =~ ^[0-9]+$ ]] && (( cpus >= 1 && cpus <= 64 )) || die "CPUs 1-64."
  read -rp "Disk size GB [20]: " disk; disk=${disk:-20}
  [[ "$disk" =~ ^[0-9]+$ ]] && (( disk >= 5 )) || die "Disk must be ≥5GB."

  local net_mode
  echo "Network mode:"
  echo "  1) NAT (user-mode, port-forward SSH)"
  echo "  2) Bridge (${RFVM_BRIDGE})"
  read -rp "Choice [1]: " nm; nm=${nm:-1}
  case "$nm" in
    1) net_mode="nat" ;;
    2) net_mode="bridge"
       ip link show "$RFVM_BRIDGE" >/dev/null 2>&1 || die "Bridge ${RFVM_BRIDGE} does not exist." ;;
    *) die "Invalid" ;;
  esac

  local ssh_port=""
  if [[ "$net_mode" == "nat" ]]; then
    while :; do
      read -rp "SSH host port [2222]: " ssh_port; ssh_port=${ssh_port:-2222}
      valid_port "$ssh_port" || { err "Invalid port."; continue; }
      port_in_use_host "$ssh_port" && { err "Port in use on host."; continue; }
      reserve_port "$ssh_port" "$name" && break
      err "Port reserved by another VM."
    done
  fi

  local display
  read -rp "GUI console (VNC-ish window)? [y/N]: " g
  [[ "$g" =~ ^[Yy]$ ]] && display="gui" || display="none"

  echo
  info "Fetching base image ..."
  fetch_image "$os_key" "$os_url" || return 1
  local base_img="$IMAGE_PATH"

  # Prepare VM directory
  local d; d=$(vm_dir "$name")
  mkdir -p "$d"
  chmod 700 "$d"

  # Disk: overlay from base to keep base pristine
  info "Creating disk ..."
  qemu-img create -f qcow2 -F qcow2 -b "$base_img" "$(vm_disk "$name")" "${disk}G" >/dev/null
  qemu-img resize "$(vm_disk "$name")" "${disk}G" >/dev/null

  # Cloud-init
  info "Building cloud-init seed ..."
  local ui="$d/user-data" mi="$d/meta-data"
  cat > "$ui" <<EOF
#cloud-config
hostname: ${hostname}
fqdn: ${hostname}
manage_etc_hosts: true
users:
  - name: ${user}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
ssh_pwauth: true
chpasswd:
  list: |
    ${user}:${pass}
  expire: false
package_update: true
runcmd:
  - systemctl enable --now ssh || systemctl enable --now sshd || true
EOF
  cat > "$mi" <<EOF
instance-id: ${name}-$(date +%s)
local-hostname: ${hostname}
EOF
  cloud-localds "$(vm_seed "$name")" "$ui" "$mi"
  chmod 600 "$ui" "$mi" "$(vm_seed "$name")"

  # MAC (stable)
  local mac; mac=$(printf '52:54:00:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))

  # Config file
  cat > "$(vm_conf "$name")" <<EOF
# RFVM configuration - do not edit unless you know what you're doing
VM_NAME="${name}"
VM_ID="$(gen_vm_id)"
VM_OS="${os_key}"
VM_OS_LABEL="${os_label}"
VM_USER="${user}"
VM_HOSTNAME="${hostname}"
VM_RAM=${ram}
VM_CPUS=${cpus}
VM_DISK=${disk}
VM_SSH_PORT="${ssh_port}"
VM_NET_MODE="${net_mode}"
VM_BRIDGE="${RFVM_BRIDGE}"
VM_MAC="${mac}"
VM_DISPLAY="${display}"
VM_CREATED="$(date '+%F %T')"
EOF
  chmod 600 "$(vm_conf "$name")"

  # systemd unit
  write_systemd_unit "$name"

  ok "VM '$name' created."
  read -rp "Start VM now? [Y/n]: " s
  if [[ ! "$s" =~ ^[Nn]$ ]]; then
    start_vm_internal "$name" || true
    systemctl enable "rfvm-${name}.service" >/dev/null 2>&1 || true
    if [[ "$net_mode" == "nat" ]]; then
      info "SSH: ssh -p ${ssh_port} ${user}@127.0.0.1"
    else
      info "SSH: ssh ${user}@<vm-ip>   (attach console for IP)"
    fi
    info "Give the guest 30-60s to boot + cloud-init."
  fi
  log "created VM $name ($os_key)"
}

# --------------------------- VM list / menu ----------------------------------
show_vm_list() {
  echo -e "${C_WHT}── Virtual Machines ──${C_RST}"
  local list; list=$(list_vms)
  if [[ -z "$list" ]]; then
    echo -e "  ${C_DIM}(no VMs yet)${C_RST}"; return
  fi
  printf "  ${C_BOLD}%-20s %-22s %-12s %-8s %-6s %-8s${C_RST}\n" \
    "NAME" "OS" "STATUS" "RAM" "CPUS" "SSH"
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    ( source "$(vm_conf "$n")"
      printf "  %-20s %-22s " "$VM_NAME" "${VM_OS_LABEL:0:22}"
      if [[ -f "$(vm_pid "$n")" ]] && kill -0 "$(cat "$(vm_pid "$n")" 2>/dev/null)" 2>/dev/null; then
        printf "${C_GRN}%-12s${C_RST}" "RUNNING"
      else
        printf "${C_DIM}%-12s${C_RST}" "STOPPED"
      fi
      printf " %-8s %-6s %-8s\n" "${VM_RAM}MB" "$VM_CPUS" "${VM_SSH_PORT:-—}"
    )
  done <<< "$list"
  echo
}

pick_vm() {
  local list; list=$(list_vms)
  [[ -z "$list" ]] && { err "No VMs."; return 1; }
  show_vm_list
  local n; read -rp "VM name: " n
  vm_exists "$n" || { err "Not found."; return 1; }
  PICKED_VM="$n"
}

# ------------------------- Management actions --------------------------------
act_start()   { pick_vm || return; start_vm_internal "$PICKED_VM"; systemctl enable "rfvm-${PICKED_VM}.service" >/dev/null 2>&1 || true; }
act_stop()    { pick_vm || return; read -rp "Stop '$PICKED_VM'? [y/N]: " a; [[ "$a" =~ ^[Yy]$ ]] && stop_vm_internal "$PICKED_VM"; }
act_restart() { pick_vm || return; stop_vm_internal "$PICKED_VM"; start_vm_internal "$PICKED_VM"; }
act_suspend() {
  pick_vm || return
  vm_running "$PICKED_VM" || { err "Not running."; return; }
  local sock; sock="$(vm_dir "$PICKED_VM")/monitor.sock"
  # QEMU monitor "stop" = pause
  ( echo "stop"; sleep 0.3 ) | socat - UNIX-CONNECT:"$sock" >/dev/null 2>&1 \
    || err "socat missing; install 'socat' to pause."
  ok "Suspend requested."
}
act_resume() {
  pick_vm || return
  local sock; sock="$(vm_dir "$PICKED_VM")/monitor.sock"
  ( echo "cont"; sleep 0.3 ) | socat - UNIX-CONNECT:"$sock" >/dev/null 2>&1 \
    || err "socat missing."
  ok "Resume requested."
}

act_delete() {
  pick_vm || return
  local n="$PICKED_VM"
  read -rp "Type the VM name to CONFIRM DELETION ($n): " confirm
  [[ "$confirm" == "$n" ]] || { err "Aborted."; return; }
  if vm_running "$n"; then stop_vm_internal "$n"; fi
  systemctl disable "rfvm-${n}.service" >/dev/null 2>&1 || true
  rm -f "$(systemd_unit "$n")"; systemctl daemon-reload
  local p; p=$(port_from_vm "$n" || true); [[ -n "$p" ]] && release_port "$p"
  rm -rf "$(vm_dir "$n")"
  ok "VM '$n' deleted."
  log "deleted VM $n"
}

act_reinstall() {
  pick_vm || return
  local n="$PICKED_VM"
  read -rp "Reinstall '$n' (disk will be wiped)? Type 'yes': " a
  [[ "$a" == "yes" ]] || return
  load_vm "$n"
  if vm_running "$n"; then stop_vm_internal "$n"; fi
  local base; base="$(os_lookup "$VM_OS" | cut -d'|' -f2)"
  fetch_image "$VM_OS" "$base" >/dev/null || return 1
  rm -f "$(vm_disk "$n")" "$(vm_seed "$n")"
  qemu-img create -f qcow2 -F qcow2 -b "$IMAGE_PATH" "$(vm_disk "$n")" "${VM_DISK}G" >/dev/null
  # Rebuild seed
  local ui d; d=$(vm_dir "$n"); ui="$d/user-data"; local mi="$d/meta-data"
  read -rsp "New password for ${VM_USER}: " pass; echo
  cat > "$ui" <<EOF
#cloud-config
hostname: ${VM_HOSTNAME}
users:
  - name: ${VM_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
ssh_pwauth: true
chpasswd:
  list: |
    ${VM_USER}:${pass}
  expire: false
runcmd:
  - systemctl enable --now ssh || systemctl enable --now sshd || true
EOF
  echo "instance-id: ${n}-$(date +%s)" > "$mi"
  cloud-localds "$(vm_seed "$n")" "$ui" "$mi"
  ok "Reinstalled. Start with option 3."
  log "reinstall VM $n"
}

act_clone() {
  pick_vm || return
  local src="$PICKED_VM" dst
  read -rp "New VM name: " dst
  valid_name "$dst" || { err "Invalid."; return; }
  vm_exists "$dst" && { err "Exists."; return; }
  load_vm "$src"
  if vm_running "$src"; then stop_vm_internal "$src"; fi

  local d; d=$(vm_dir "$dst"); mkdir -p "$d"; chmod 700 "$d"
  qemu-img convert -O qcow2 "$(vm_disk "$src")" "$(vm_disk "$dst")"
  cp -a "$(vm_dir "$src")/user-data" "$d/" 2>/dev/null || true
  cp -a "$(vm_dir "$src")/meta-data" "$d/" 2>/dev/null || true

  # New seed with unique instance-id
  if [[ -f "$d/user-data" ]]; then
    echo "instance-id: ${dst}-$(date +%s)" > "$d/meta-data"
    cloud-localds "$(vm_seed "$dst")" "$d/user-data" "$d/meta-data"
  else
    err "Source seed files missing; cloned disk only."
    : > "$(vm_seed "$dst")"
  fi

  # new port
  local newport
  while :; do
    newport=$(( (RANDOM % 10000) + 20000 ))
    port_in_use_host "$newport" && continue
    reserve_port "$newport" "$dst" && break
  done

  sed -e "s/^VM_NAME=.*/VM_NAME=\"$dst\"/" \
      -e "s/^VM_ID=.*/VM_ID=\"$(gen_vm_id)\"/" \
      -e "s/^VM_SSH_PORT=.*/VM_SSH_PORT=\"$newport\"/" \
      -e "s/^VM_CREATED=.*/VM_CREATED=\"$(date '+%F %T')\"/" \
      "$(vm_conf "$src")" > "$(vm_conf "$dst")"
  chmod 600 "$(vm_conf "$dst")"
  write_systemd_unit "$dst"
  ok "Cloned '$src' → '$dst' (SSH port $newport)."
}

act_info() {
  pick_vm || return
  load_vm "$PICKED_VM"
  local d; d=$(vm_dir "$PICKED_VM")
  local disk_size; disk_size=$(qemu-img info "$(vm_disk "$PICKED_VM")" 2>/dev/null | awk '/virtual size/{print $3,$4}')
  echo
  echo -e "${C_WHT}── VM Information ──${C_RST}"
  printf "  %-18s %s\n" "Name:"        "$VM_NAME"
  printf "  %-18s %s\n" "ID:"          "$VM_ID"
  printf "  %-18s %s\n" "OS:"          "$VM_OS_LABEL"
  printf "  %-18s %s\n" "Status:"      "$(vm_status_str "$VM_NAME")"
  printf "  %-18s %s\n" "RAM:"         "${VM_RAM} MB"
  printf "  %-18s %s\n" "CPUs:"        "$VM_CPUS"
  printf "  %-18s %s\n" "Disk size:"   "${disk_size:-${VM_DISK}G}"
  printf "  %-18s %s\n" "IP:"          "$(vm_ip "$VM_NAME")"
  printf "  %-18s %s\n" "SSH port:"    "${VM_SSH_PORT:-—}"
  printf "  %-18s %s\n" "Network:"     "$VM_NET_MODE"
  printf "  %-18s %s\n" "Created:"     "$VM_CREATED"
  printf "  %-18s %s\n" "Disk image:"  "$(vm_disk "$VM_NAME")"
  printf "  %-18s %s\n" "Config:"      "$(vm_conf "$VM_NAME")"
  echo
}

act_edit() {
  pick_vm || return
  local c; c=$(vm_conf "$PICKED_VM")
  local editor="${EDITOR:-nano}"
  command -v "$editor" >/dev/null || editor=vi
  "$editor" "$c"
  ok "Saved."
}

act_resize() {
  pick_vm || return
  local n="$PICKED_VM"; load_vm "$n"
  vm_running "$n" && { err "Stop the VM first."; return; }
  local sz; read -rp "New disk size in GB (>${VM_DISK}): " sz
  [[ "$sz" =~ ^[0-9]+$ ]] && (( sz > VM_DISK )) || { err "Invalid."; return; }
  qemu-img resize "$(vm_disk "$n")" "${sz}G"
  sed -i "s/^VM_DISK=.*/VM_DISK=${sz}/" "$(vm_conf "$n")"
  ok "Resized to ${sz}G. Grow partition inside guest."
}

act_monitor() {
  pick_vm || return
  local n="$PICKED_VM"
  vm_running "$n" || { err "VM not running."; return; }
  local pid; pid=$(cat "$(vm_pid "$n")")
  banner
  echo -e "${C_WHT}── Monitoring VM: $n (pid $pid) ──${C_RST}"
  echo "Press Ctrl-C to exit."
  while kill -0 "$pid" 2>/dev/null; do
    clear; banner
    echo -e "${C_WHT}── $n (pid $pid) ──${C_RST}"
    ps -p "$pid" -o pid,pcpu,pmem,rss,vsz,etime,cmd --no-headers
    echo
    echo -e "${C_WHT}── Disk ──${C_RST}"
    qemu-img info "$(vm_disk "$n")" | sed -n '1,8p'
    echo
    echo -e "${C_WHT}── Network ──${C_RST}"
    ip -s link show | head -40
    sleep 2
  done
}

act_console() {
  pick_vm || return
  local n="$PICKED_VM"
  vm_running "$n" || { err "Not running."; return; }
  info "Attaching to serial console (Ctrl-A x to exit)."
  local sock; sock="$(vm_dir "$n")/monitor.sock"
  # For non-graphical VMs, serial is a file; we can tail it
  tail -F "$(vm_log "$n")"
}

show_dashboard() {
  local total=0 running=0
  if [[ -d "$RFVM_VMS" ]]; then
    total=$(find "$RFVM_VMS" -mindepth 1 -maxdepth 1 -type d | wc -l)
    while IFS= read -r n; do
      vm_running "$n" && ((running++)) || true
    done < <(list_vms)
  fi
  echo -e "${C_DIM}VMs: ${C_WHT}${total}${C_DIM}  Running: ${C_GRN}${running}${C_DIM}  KVM: $(
    kvm_available && echo "${C_GRN}yes${C_DIM}" || echo "${C_RED}no${C_DIM}")  Bridge: ${C_WHT}${RFVM_BRIDGE}${C_DIM}  Host: $(hostname)${C_RST}"
  echo
}

main_menu() {
  while :; do
    banner
    show_dashboard
    show_vm_list
    echo -e "${C_WHT}── Main Menu ──${C_RST}"
    echo "  1) Create VM          2) Start VM         3) Stop VM"
    echo "  4) Restart VM         5) Suspend VM       6) Resume VM"
    echo "  7) Delete VM          8) Reinstall VM     9) Clone VM"
    echo " 10) Show VM info      11) Edit config     12) Resize disk"
    echo " 13) Monitor perf      14) Attach console  15) Refresh"
    echo " 16) Install deps      17) Exit"
    echo
    local c; read -rp "Select: " c
    case "$c" in
      1) create_vm; pause ;;
      2) act_start; pause ;;
      3) act_stop; pause ;;
      4) act_restart; pause ;;
      5) act_suspend; pause ;;
      6) act_resume; pause ;;
      7) act_delete; pause ;;
      8) act_reinstall; pause ;;
      9) act_clone; pause ;;
      10) act_info; pause ;;
      11) act_edit ;;
      12) act_resize; pause ;;
      13) act_monitor ;;
      14) act_console ;;
      15) continue ;;
      16) install_deps; pause ;;
      17) exit 0 ;;
      *) err "Invalid choice"; sleep 1 ;;
    esac
  done
}

# -------------------------- Daemon entrypoints -------------------------------
case "${1:-}" in
  --daemon-start) start_vm_internal "$2"; exit $? ;;
  --daemon-stop)  stop_vm_internal "$2";  exit $? ;;
  --version)      echo "RFVM $RFVM_VERSION"; exit 0 ;;
  ""|--menu)
    ensure_root
    mkdir -p "$RFVM_BASE" "$RFVM_VMS" "$RFVM_IMAGES"
    chmod 700 "$RFVM_BASE"
    check_deps
    install_internal_helpers
    main_menu
    ;;
  *)
    echo "Usage: $0 [--menu|--daemon-start NAME|--daemon-stop NAME|--version]"
    exit 1
    ;;
esac
