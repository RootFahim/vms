#!/usr/bin/env bash
#
# ROOTFAHIM VM MANAGER (rfvm.sh)
# A menu-driven QEMU/KVM virtual machine manager.
#
# Layout:
#   /var/lib/rfvm/
#     base/                  downloaded cloud images (shared read-only backing files)
#     vms/<vm-name>/
#       disk.qcow2           per-VM QCOW2 disk (backing file -> base image)
#       seed.iso             cloud-init NoCloud seed
#       meta-data,user-data  cloud-init sources (kept for regeneration)
#       vm.conf              per-VM configuration (KEY=VALUE)
#       console.log          serial console log
#     services/              systemd unit files
#
# Requires: root, qemu-system-x86_64, qemu-img, cloud-localds (cloud-image-utils),
#           wget/curl, ssh-keygen, openssh-client, iproute2, bridge-utils (optional).
#
set -o errexit
set -o nounset
set -o pipefail

readonly RFVM_VERSION="1.0.0"
readonly RFVM_HOME="/var/lib/rfvm"
readonly RFVM_BASE="${RFVM_HOME}/base"
readonly RFVM_VMS="${RFVM_HOME}/vms"
readonly RFVM_SERVICES="${RFVM_HOME}/services"
readonly RFVM_LOG="${RFVM_HOME}/rfvm.log"
readonly QEMU_BIN="qemu-system-x86_64"
readonly SYSTEMD_DIR="/etc/systemd/system"

# ---------------------------------------------------------------------------
# Colors / logging
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'
  C_BLU=$'\e[34m'; C_MAG=$'\e[35m'; C_CYN=$'\e[36m'; C_WHT=$'\e[97m'; C_BLD=$'\e[1m'
else
  C_RESET=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_MAG=""; C_CYN=""; C_WHT=""; C_BLD=""
fi

log()  { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$RFVM_LOG" 2>/dev/null || true; }
info() { printf '%s%s%s\n' "$C_CYN" "$*" "$C_RESET"; log INFO  "$*"; }
ok()   { printf '%s%s%s\n' "$C_GRN" "$*" "$C_RESET"; log OK    "$*"; }
warn() { printf '%s%s%s\n' "$C_YEL" "$*" "$C_RESET"; log WARN  "$*"; }
err()  { printf '%s%s%s\n' "$C_RED" "$*" "$C_RESET" >&2; log ERROR "$*"; }
die()  { err "$*"; exit 1; }

confirm() {
  local prompt="$1" reply
  read -r -p "${C_YEL}${prompt} [y/N]: ${C_RESET}" reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

prompt() {
  local varname="$1" prompt="$2" default="${3:-}" value
  if [[ -n "$default" ]]; then
    read -r -p "${C_WHT}${prompt} [${default}]: ${C_RESET}" value
    value="${value:-$default}"
  else
    read -r -p "${C_WHT}${prompt}: ${C_RESET}" value
  fi
  printf -v "$varname" '%s' "$value"
}

prompt_secret() {
  local varname="$1" prompt="$2" value
  read -r -s -p "${C_WHT}${prompt}: ${C_RESET}" value; echo
  printf -v "$varname" '%s' "$value"
}

banner() {
  clear || true
  cat <<EOF
${C_MAG}${C_BLD}
  ____   ___   ___ _____ _____    _    _   _ ___ __  __
 |  _ \ / _ \ / _ \_   _|  ___|  / \  | | | |_ _|  \/  |
 | |_) | | | | | | || | | |_    / _ \ | |_| || || |\/| |
 |  _ <| |_| | |_| || | |  _|  / ___ \|  _  || || |  | |
 |_| \_\\___/ \___/ |_| |_|   /_/   \_\_| |_|___|_|  |_|

        R O O T F A H I M   V M   M A N A G E R   v${RFVM_VERSION}
${C_RESET}
EOF
}

# ---------------------------------------------------------------------------
# Dependency handling
# ---------------------------------------------------------------------------
need_root() { [[ "${EUID}" -eq 0 ]] || die "This tool must be run as root."; }

install_deps() {
  local missing=()
  local pkgs=(qemu-system-x86 qemu-utils cloud-image-utils wget curl \
              openssh-client iproute2 bridge-utils genisoimage)
  local cmd_map=(
    "qemu-system-x86_64:qemu-system-x86"
    "qemu-img:qemu-utils"
    "cloud-localds:cloud-image-utils"
    "wget:wget"
    "curl:curl"
    "ssh-keygen:openssh-client"
    "ip:iproute2"
    "genisoimage:genisoimage"
  )
  local entry cmd pkg
  for entry in "${cmd_map[@]}"; do
    cmd="${entry%%:*}"; pkg="${entry##*:}"
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$pkg")
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then ok "All dependencies present."; return 0; fi
  warn "Missing packages: ${missing[*]}"
  if ! confirm "Install them now via apt-get?"; then die "Cannot proceed without dependencies."; fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends "${missing[@]}" \
    || die "Package installation failed."
  ok "Dependencies installed."
}

init_dirs() {
  mkdir -p "$RFVM_BASE" "$RFVM_VMS" "$RFVM_SERVICES"
  chmod 700 "$RFVM_HOME"
  touch "$RFVM_LOG"; chmod 600 "$RFVM_LOG"
}

# ---------------------------------------------------------------------------
# KVM / CPU detection
# ---------------------------------------------------------------------------
have_kvm() { [[ -r /dev/kvm && -w /dev/kvm ]]; }

kvm_args() {
  if have_kvm; then printf '%s' "-enable-kvm -cpu host"; fi
}

host_arch() { uname -m; }

# ---------------------------------------------------------------------------
# OS catalog
# ---------------------------------------------------------------------------
# name|image-url
declare -A OS_IMAGES=(
  ["ubuntu-22.04"]="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  ["ubuntu-24.04"]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  ["debian-11"]="https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2"
  ["debian-12"]="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
  ["fedora"]="https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-40-1.14.x86_64.qcow2"
  ["centos-9"]="https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"
  ["alma-9"]="https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
  ["rocky-9"]="https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
)
OS_ORDER=(ubuntu-22.04 ubuntu-24.04 debian-11 debian-12 fedora centos-9 alma-9 rocky-9)

os_menu() {
  local i=1 key
  printf '%sAvailable operating systems:%s\n' "$C_BLD" "$C_RESET"
  for key in "${OS_ORDER[@]}"; do
    printf '  %2d) %s\n' "$i" "$key"
    ((i++))
  done
  printf '   0) Cancel\n'
}

select_os() {
  local choice
  os_menu
  read -r -p "${C_WHT}Select OS: ${C_RESET}" choice
  [[ "$choice" =~ ^[0-9]+$ ]] || return 1
  [[ "$choice" -eq 0 ]] && return 1
  (( choice >= 1 && choice <= ${#OS_ORDER[@]} )) || return 1
  printf '%s' "${OS_ORDER[$((choice-1))]}"
}

ensure_base_image() {
  local os="$1"
  local url="${OS_IMAGES[$os]:-}"
  [[ -n "$url" ]] || die "Unknown OS: $os"
  local target="${RFVM_BASE}/${os}.qcow2"
  if [[ -s "$target" ]]; then ok "Base image for $os already present."; printf '%s' "$target"; return 0; fi
  info "Downloading $os cloud image (this may take a while)..."
  local tmp="${target}.part"
  rm -f "$tmp"
  if command -v wget >/dev/null 2>&1; then
    wget -q --show-progress -O "$tmp" "$url" || { rm -f "$tmp"; die "Download failed: $url"; }
  else
    curl -fL --progress-bar -o "$tmp" "$url" || { rm -f "$tmp"; die "Download failed: $url"; }
  fi
  qemu-img info "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "Downloaded file is not a valid qcow2: $url"; }
  mv "$tmp" "$target"
  ok "Base image saved: $target"
  printf '%s' "$target"
}

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
valid_name()  { [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9-]{1,30}$ ]]; }
valid_host()  { [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9-]{1,62}$ ]]; }
valid_user()  { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_port()  { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1024 && $1 <= 65535 )); }
valid_uint()  { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 )); }

port_in_use() {
  local port="$1"
  ss -H -ltn "sport = :$port" 2>/dev/null | grep -q . && return 0
  # Also check any VM's ssh_port
  local conf
  for conf in "${RFVM_VMS}"/*/vm.conf; do
    [[ -r "$conf" ]] || continue
    # shellcheck disable=SC1090
    ( source "$conf"; [[ "${SSH_PORT:-0}" == "$port" ]] && exit 0; exit 1 ) && return 0
  done
  return 1
}

vm_exists() { [[ -d "${RFVM_VMS}/$1" ]]; }

# ---------------------------------------------------------------------------
# Config I/O (KEY=VALUE, safely sourced, but we never export unsafe content)
# ---------------------------------------------------------------------------
load_conf() {
  local name="$1"
  local conf="${RFVM_VMS}/${name}/vm.conf"
  [[ -r "$conf" ]] || { err "Missing config: $conf"; return 1; }
  # shellcheck disable=SC1090
  source "$conf"
}

save_conf() {
  local name="$1"; shift
  local conf="${RFVM_VMS}/${name}/vm.conf"
  {
    printf '# ROOTFAHIM VM config - generated %s\n' "$(date -Is)"
    while (($#)); do printf '%s\n' "$1"; shift; done
  } >"$conf.tmp"
  chmod 600 "$conf.tmp"
  mv "$conf.tmp" "$conf"
}

# ---------------------------------------------------------------------------
# systemd service management
# ---------------------------------------------------------------------------
service_name() { printf 'rfvm-%s.service' "$1"; }

qemu_cmdline() {
  local name="$1"
  load_conf "$name" || return 1

  local accel; accel="$(kvm_args)"
  local dir="${RFVM_VMS}/${name}"
  local ssh_fwd="hostfwd=tcp::${SSH_PORT}-:22"
  local fwd args=()
  if [[ -n "${FORWARDS:-}" ]]; then
    IFS=',' read -r -a fwd <<<"${FORWARDS}"
    local item
    for item in "${fwd[@]}"; do
      [[ -n "$item" ]] && ssh_fwd+=",${item}"
    done
  fi

  # Base args
  args=( "$QEMU_BIN" )
  [[ -n "$accel" ]] && read -r -a _a <<<"$accel" && args+=("${_a[@]}")
  args+=(
    -name "$name"
    -machine q35,accel=kvm:tcg
    -smp "${CPU_CORES}"
    -m "${RAM_MB}"
    -nodefaults
    -no-user-config
    -daemonize
    -pidfile "${dir}/qemu.pid"
    -D "${dir}/qemu.log"
    -drive "file=${dir}/disk.qcow2,if=virtio,format=qcow2,cache=writeback"
    -drive "file=${dir}/seed.iso,if=virtio,format=raw,readonly=on"
    -netdev "user,id=net0,${ssh_fwd}"
    -device "virtio-net-pci,netdev=net0"
    -device virtio-rng-pci
    -display none
    -serial "file:${dir}/console.log"
    -monitor "unix:${dir}/monitor.sock,server,nowait"
  )
  if [[ "${GUI_MODE:-0}" == "1" ]]; then
    # Replace -display none with SDL when GUI is requested (requires DISPLAY)
    args=("${args[@]/-display none/-display sdl}")
  fi

  # Print args safely (no eval)
  local a
  for a in "${args[@]}"; do printf '%q ' "$a"; done
  printf '\n'
}

write_service() {
  local name="$1"
  local unit
  unit="$(service_name "$name")"
  local cmdline
  cmdline="$(qemu_cmdline "$name")" || return 1
  local path="${SYSTEMD_DIR}/${unit}"

  cat >"$path" <<EOF
[Unit]
Description=ROOTFAHIM VM ${name}
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=${RFVM_VMS}/${name}/qemu.pid
ExecStart=/bin/bash -c 'exec ${cmdline}'
ExecStop=/bin/bash -c 'p=\$(cat ${RFVM_VMS}/${name}/qemu.pid 2>/dev/null); if [ -n "\$p" ] && kill -0 \$p 2>/dev/null; then kill -TERM \$p; for i in \$(seq 1 30); do kill -0 \$p 2>/dev/null || exit 0; sleep 1; done; kill -KILL \$p; fi'
Restart=no
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$path"
  systemctl daemon-reload
}

# ---------------------------------------------------------------------------
# Cloud-init seed
# ---------------------------------------------------------------------------
gen_seed() {
  local name="$1"
  load_conf "$name" || return 1
  local dir="${RFVM_VMS}/${name}"
  local keyfile="${dir}/id_rsa"
  if [[ ! -s "${keyfile}.pub" ]]; then
    ssh-keygen -q -t rsa -b 3072 -N "" -C "rfvm@${name}" -f "$keyfile"
    chmod 600 "$keyfile"
    chmod 644 "${keyfile}.pub"
  fi
  local pubkey; pubkey="$(cat "${keyfile}.pub")"

  cat >"${dir}/meta-data" <<EOF
instance-id: ${name}-${VM_ID}
local-hostname: ${HOSTNAME}
EOF

  cat >"${dir}/user-data" <<EOF
#cloud-config
hostname: ${HOSTNAME}
fqdn: ${HOSTNAME}
manage_etc_hosts: true
users:
  - name: ${USERNAME}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: '${PASSWORD}'
    ssh_authorized_keys:
      - ${pubkey}
ssh_pwauth: true
chpasswd:
  expire: false
  list: |
    ${USERNAME}:${PASSWORD}
package_update: false
runcmd:
  - [ sh, -c, "sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config" ]
  - [ sh, -c, "systemctl restart ssh || systemctl restart sshd || true" ]
EOF
  chmod 600 "${dir}/user-data"
  cloud-localds "${dir}/seed.iso" "${dir}/user-data" "${dir}/meta-data" \
    || die "cloud-localds failed"
}

# ---------------------------------------------------------------------------
# VM creation
# ---------------------------------------------------------------------------
create_vm() {
  banner
  info "Create a new virtual machine"

  local name os
  while :; do
    prompt name "VM name (letters, digits, dash; must start with letter)"
    valid_name "$name" || { err "Invalid name."; continue; }
    vm_exists "$name" && { err "A VM named '$name' already exists."; continue; }
    break
  done

  os="$(select_os)" || { info "Cancelled."; return; }

  local hostname username password password2
  prompt hostname "Hostname" "$name"
  while ! valid_host "$hostname"; do err "Invalid hostname."; prompt hostname "Hostname" "$name"; done

  prompt username "Cloud user" "ubuntu"
  while ! valid_user "$username"; do err "Invalid username."; prompt username "Cloud user" "ubuntu"; done

  while :; do
    prompt_secret password "Password for ${username}"
    prompt_secret password2 "Confirm password"
    [[ -n "$password" ]] || { err "Password cannot be empty."; continue; }
    [[ "$password" == "$password2" ]] || { err "Passwords do not match."; continue; }
    break
  done

  local ram cpu disk ssh_port net_mode
  prompt ram "RAM in MB" "2048"
  while ! valid_uint "$ram" || (( ram < 512 )); do err "RAM must be >= 512."; prompt ram "RAM in MB" "2048"; done

  prompt cpu "CPU cores" "2"
  while ! valid_uint "$cpu" || (( cpu > 64 )); do err "CPU cores 1..64."; prompt cpu "CPU cores" "2"; done

  prompt disk "Disk size in GB" "20"
  while ! valid_uint "$disk" || (( disk < 5 )); do err "Disk must be >= 5 GB."; prompt disk "Disk size in GB" "20"; done

  while :; do
    prompt ssh_port "SSH port on host" "$((2200 + RANDOM % 700))"
    valid_port "$ssh_port" || { err "Port must be 1024..65535."; continue; }
    if port_in_use "$ssh_port"; then err "Port $ssh_port is already in use."; continue; fi
    break
  done

  printf '%sNetwork mode:%s\n  1) NAT (user-mode + SSH hostfwd) [default]\n  2) Bridge (host bridge required)\n' "$C_BLD" "$C_RESET"
  read -r -p "${C_WHT}Select network mode [1]: ${C_RESET}" net_mode
  case "${net_mode:-1}" in
    1) net_mode="nat" ;;
    2) net_mode="bridge" ;;
    *) net_mode="nat" ;;
  esac

  local bridge=""
  if [[ "$net_mode" == "bridge" ]]; then
    prompt bridge "Host bridge name" "br0"
  fi

  local forwards=""
  if [[ "$net_mode" == "nat" ]]; then
    if confirm "Add extra port forwards (e.g. 8080:80,443:443)?"; then
      prompt forwards "Forwards (comma-separated host:guest, empty to skip)"
    fi
  fi

  local gui="0"
  confirm "Enable GUI (SDL) display? (host must have X11/Wayland)" && gui="1"

  # Confirm
  echo
  printf '%sSummary%s\n' "$C_BLD" "$C_RESET"
  printf '  Name         : %s\n' "$name"
  printf '  OS           : %s\n' "$os"
  printf '  Hostname     : %s\n' "$hostname"
  printf '  User         : %s\n' "$username"
  printf '  RAM / CPU    : %s MB / %s vCPU\n' "$ram" "$cpu"
  printf '  Disk         : %s GB\n' "$disk"
  printf '  SSH port     : %s\n' "$ssh_port"
  printf '  Network      : %s\n' "$net_mode"
  [[ -n "$bridge" ]]  && printf '  Bridge       : %s\n' "$bridge"
  [[ -n "$forwards" ]] && printf '  Forwards     : %s\n' "$forwards"
  printf '  GUI          : %s\n' "$gui"
  confirm "Create this VM now?" || { info "Cancelled."; return; }

  local base
  base="$(ensure_base_image "$os")"

  local dir="${RFVM_VMS}/${name}"
  mkdir -p "$dir"
  chmod 700 "$dir"

  info "Creating qcow2 disk..."
  qemu-img create -q -f qcow2 -F qcow2 -b "$base" "${dir}/disk.qcow2" "${disk}G" \
    || { err "qemu-img failed"; rm -rf "$dir"; return 1; }

  local vm_id; vm_id="$(date +%s)-$((RANDOM))"
  save_conf "$name" \
    "VM_ID=${vm_id}" \
    "NAME=${name}" \
    "OS=${os}" \
    "HOSTNAME=${hostname}" \
    "USERNAME=${username}" \
    "PASSWORD=${password}" \
    "RAM_MB=${ram}" \
    "CPU_CORES=${cpu}" \
    "DISK_GB=${disk}" \
    "SSH_PORT=${ssh_port}" \
    "NET_MODE=${net_mode}" \
    "BRIDGE=${bridge}" \
    "FORWARDS=${forwards}" \
    "GUI_MODE=${gui}" \
    "CREATED=$(date -Is)" \
    "DISK_PATH=${dir}/disk.qcow2"

  info "Generating cloud-init seed..."
  gen_seed "$name" || { err "Seed failed."; return 1; }

  info "Writing systemd unit..."
  write_service "$name" || { err "systemd unit failed."; return 1; }
  systemctl enable "$(service_name "$name")" >/dev/null 2>&1 || true

  ok "VM '$name' created."
  info "Start it from the menu; cloud-init will finish setup on first boot."
  info "SSH key: ${dir}/id_rsa (password SSH is also enabled)."
}

# ---------------------------------------------------------------------------
# Lifecycle operations
# ---------------------------------------------------------------------------
vm_pid() {
  local name="$1" pidfile="${RFVM_VMS}/${name}/qemu.pid"
  [[ -r "$pidfile" ]] || return 1
  local pid; pid="$(cat "$pidfile" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
}

start_vm() {
  local name="$1"
  vm_exists "$name" || { err "No such VM: $name"; return 1; }
  if vm_pid "$name" >/dev/null; then warn "VM '$name' already running."; return 0; fi
  local unit; unit="$(service_name "$name")"
  [[ -f "${SYSTEMD_DIR}/${unit}" ]] || write_service "$name"
  systemctl start "$unit" || { err "systemctl start failed"; return 1; }
  sleep 1
  vm_pid "$name" >/dev/null && ok "VM '$name' started." || err "VM failed to start; check ${RFVM_VMS}/${name}/qemu.log"
}

stop_vm() {
  local name="$1"
  vm_exists "$name" || { err "No such VM: $name"; return 1; }
  confirm "Stop VM '$name'?" || return 0
  local unit; unit="$(service_name "$name")"
  systemctl stop "$unit" 2>/dev/null || true
  # Fallback: terminate pid if still alive
  local pid; if pid="$(vm_pid "$name")"; then kill -TERM "$pid" 2>/dev/null || true; fi
  sleep 1
  if pid="$(vm_pid "$name")"; then kill -KILL "$pid" 2>/dev/null || true; fi
  ok "VM '$name' stopped."
}

restart_vm() {
  stop_vm_silent "$1"; start_vm "$1"
}

stop_vm_silent() {
  local name="$1" unit; unit="$(service_name "$name")"
  systemctl stop "$unit" 2>/dev/null || true
  local pid; if pid="$(vm_pid "$name")"; then kill -TERM "$pid" 2>/dev/null || true; sleep 1; fi
  if pid="$(vm_pid "$name")"; then kill -KILL "$pid" 2>/dev/null || true; fi
}

# Suspend / resume via QMP monitor socket
qmp() {
  local name="$1" cmd="$2"
  local sock="${RFVM_VMS}/${name}/monitor.sock"
  [[ -S "$sock" ]] || { err "Monitor socket missing for '$name'"; return 1; }
  # Use socat if available; otherwise use a tiny python helper
  if command -v socat >/dev/null 2>&1; then
    printf '%s\n' "$cmd" | socat - UNIX-CONNECT:"$sock" >/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$sock" "$cmd" <<'PY'
import socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect(sys.argv[1])
s.sendall((sys.argv[2]+"\n").encode()); s.settimeout(2)
try: s.recv(4096)
except Exception: pass
s.close()
PY
  else
    die "Need socat or python3 to send monitor commands."
  fi
}

suspend_vm() {
  local name="$1"; vm_pid "$name" >/dev/null || { err "VM not running."; return 1; }
  qmp "$name" "stop" && ok "VM '$name' suspended."
}
resume_vm() {
  local name="$1"; vm_pid "$name" >/dev/null || { err "VM not running."; return 1; }
  qmp "$name" "cont" && ok "VM '$name' resumed."
}

delete_vm() {
  local name="$1"
  vm_exists "$name" || { err "No such VM."; return 1; }
  printf '%sThis will permanently delete VM "%s" and its disk.%s\n' "$C_RED" "$name" "$C_RESET"
  confirm "Type y to confirm deletion" || return 0
  confirm "Really delete? This cannot be undone" || return 0
  stop_vm_silent "$name"
  local unit; unit="$(service_name "$name")"
  systemctl disable "$unit" >/dev/null 2>&1 || true
  rm -f "${SYSTEMD_DIR}/${unit}"
  systemctl daemon-reload
  rm -rf "${RFVM_VMS:?}/${name}"
  ok "VM '$name' deleted."
}

clone_vm() {
  local src="$1" dst
  vm_exists "$src" || { err "No such source VM."; return 1; }
  while :; do
    prompt dst "New VM name"
    valid_name "$dst" || { err "Invalid name."; continue; }
    vm_exists "$dst" && { err "Name exists."; continue; }
    break
  done
  load_conf "$src"
  local new_port
  while :; do
    prompt new_port "SSH port for clone" "$((SSH_PORT + 1))"
    valid_port "$new_port" || { err "Invalid port."; continue; }
    port_in_use "$new_port" && { err "Port in use."; continue; }
    break
  done
  local dir="${RFVM_VMS}/${dst}"
  mkdir -p "$dir"; chmod 700 "$dir"
  qemu-img convert -O qcow2 "${RFVM_VMS}/${src}/disk.qcow2" "${dir}/disk.qcow2" \
    || { err "Clone failed."; rm -rf "$dir"; return 1; }
  local vm_id; vm_id="$(date +%s)-$((RANDOM))"
  save_conf "$dst" \
    "VM_ID=${vm_id}" \
    "NAME=${dst}" \
    "OS=${OS}" \
    "HOSTNAME=${dst}" \
    "USERNAME=${USERNAME}" \
    "PASSWORD=${PASSWORD}" \
    "RAM_MB=${RAM_MB}" \
    "CPU_CORES=${CPU_CORES}" \
    "DISK_GB=${DISK_GB}" \
    "SSH_PORT=${new_port}" \
    "NET_MODE=${NET_MODE}" \
    "BRIDGE=${BRIDGE:-}" \
    "FORWARDS=" \
    "GUI_MODE=${GUI_MODE:-0}" \
    "CREATED=$(date -Is)" \
    "DISK_PATH=${dir}/disk.qcow2"
  # Regenerate seed for clone (new hostname / instance-id)
  gen_seed "$dst"
  write_service "$dst"
  systemctl enable "$(service_name "$dst")" >/dev/null 2>&1 || true
  ok "Clone '$dst' created. Note: you may need to reset cloud-init inside the guest."
}

reinstall_vm() {
  local name="$1"
  vm_exists "$name" || { err "No such VM."; return 1; }
  load_conf "$name"
  warn "Reinstall will DESTROY current disk contents of '$name'."
  confirm "Proceed with reinstall?" || return 0
  stop_vm_silent "$name"
  local base; base="$(ensure_base_image "$OS")"
  rm -f "${RFVM_VMS}/${name}/disk.qcow2"
  qemu-img create -q -f qcow2 -F qcow2 -b "$base" "${RFVM_VMS}/${name}/disk.qcow2" "${DISK_GB}G"
  gen_seed "$name"
  ok "VM '$name' reinstalled (fresh disk + fresh cloud-init seed)."
}

edit_vm() {
  local name="$1"
  vm_exists "$name" || { err "No such VM."; return 1; }
  load_conf "$name"
  echo "Leave blank to keep current value."
  local ram="$RAM_MB" cpu="$CPU_CORES" port="$SSH_PORT" fwd="${FORWARDS:-}"
  prompt ram "RAM (MB)" "$RAM_MB"
  valid_uint "$ram" || ram="$RAM_MB"
  prompt cpu "CPU cores" "$CPU_CORES"
  valid_uint "$cpu" || cpu="$CPU_CORES"
  prompt port "SSH port" "$SSH_PORT"
  if valid_port "$port" && ! port_in_use "$port"; then :; else port="$SSH_PORT"; fi
  prompt fwd "Extra forwards (blank to clear)" "${FORWARDS:-}"

  save_conf "$name" \
    "VM_ID=${VM_ID}" "NAME=${NAME}" "OS=${OS}" "HOSTNAME=${HOSTNAME}" \
    "USERNAME=${USERNAME}" "PASSWORD=${PASSWORD}" \
    "RAM_MB=${ram}" "CPU_CORES=${cpu}" "DISK_GB=${DISK_GB}" \
    "SSH_PORT=${port}" "NET_MODE=${NET_MODE}" "BRIDGE=${BRIDGE:-}" \
    "FORWARDS=${fwd}" "GUI_MODE=${GUI_MODE:-0}" "CREATED=${CREATED}" \
    "DISK_PATH=${DISK_PATH}"
  write_service "$name"
  info "Config updated. Restart the VM for changes to apply."
}

resize_disk() {
  local name="$1"
  vm_exists "$name" || { err "No such VM."; return 1; }
  load_conf "$name"
  vm_pid "$name" >/dev/null && { err "Stop the VM before resizing."; return 1; }
  local newgb
  prompt newgb "New disk size in GB (current ${DISK_GB})" "$DISK_GB"
  valid_uint "$newgb" && (( newgb > DISK_GB )) || { err "Must be larger than current."; return 1; }
  qemu-img resize "${RFVM_VMS}/${name}/disk.qcow2" "${newgb}G" \
    || { err "Resize failed."; return 1; }
  # update conf
  sed -i "s/^DISK_GB=.*/DISK_GB=${newgb}/" "${RFVM_VMS}/${name}/vm.conf"
  ok "Disk resized to ${newgb}G. Grow the filesystem inside the guest (growpart + resize2fs/xfs_growfs)."
}

# ---------------------------------------------------------------------------
# Info / monitoring
# ---------------------------------------------------------------------------
vm_status() {
  local name="$1"
  if vm_pid "$name" >/dev/null; then printf '%sRUNNING%s' "$C_GRN" "$C_RESET"
  else printf '%sSTOPPED%s' "$C_RED" "$C_RESET"; fi
}

vm_ip() {
  local name="$1"
  # Try the QEMU monitor "info usernet" via serial? Simpler: parse ARP/neigh by ssh port is not reliable.
  # Use the guest agent-less trick: check DHCP leases on the slirp? Not exposed.
  # Fallback: query through hostfwd by attempting to read the guest via ssh? Too heavy.
  # Practical approach: user-mode NAT gives 10.0.2.15 by convention; report that.
  # For bridge mode, use arp/neigh by looking up the tap MAC — we don't expose a tap device,
  # so we can only report the guest-assigned address via cloud-init metadata.
  local conf="${RFVM_VMS}/${name}/vm.conf"
  [[ -r "$conf" ]] || return 1
  ( source "$conf"
    if [[ "${NET_MODE:-nat}" == "nat" ]]; then
      printf '10.0.2.15 (NAT guest)'
    else
      printf 'see bridge DHCP for %s' "${HOSTNAME}"
    fi )
}

vm_info() {
  local name="$1"
  vm_exists "$name" || { err "No such VM."; return 1; }
  load_conf "$name"
  local pid; pid="$(vm_pid "$name" || true)"
  echo
  printf '%sVM: %s%s\n' "$C_BLD" "$name" "$C_RESET"
  printf '  VM ID         : %s\n' "$VM_ID"
  printf '  OS            : %s\n' "$OS"
  printf '  Hostname      : %s\n' "$HOSTNAME"
  printf '  Cloud user    : %s\n' "$USERNAME"
  printf '  Status        : %s\n' "$(vm_status "$name")"
  printf '  RAM           : %s MB\n' "$RAM_MB"
  printf '  vCPU          : %s\n' "$CPU_CORES"
  printf '  Disk (conf)   : %s GB\n' "$DISK_GB"
  local vinfo; vinfo="$(qemu-img info "${RFVM_VMS}/${name}/disk.qcow2" 2>/dev/null | awk -F': ' '/virtual size/{print $2}')"
  printf '  Disk image    : %s\n' "${RFVM_VMS}/${name}/disk.qcow2 ${vinfo:+($vinfo)}"
  printf '  Network mode  : %s\n' "$NET_MODE"
  printf '  SSH port      : %s\n' "$SSH_PORT"
  printf '  Guest IP hint : %s\n' "$(vm_ip "$name")"
  printf '  Forwards      : %s\n' "${FORWARDS:-none}"
  printf '  Created       : %s\n' "$CREATED"
  if [[ -n "$pid" ]]; then
    printf '  QEMU PID      : %s\n' "$pid"
    printf '  Uptime        : %s\n' "$(ps -o etime= -p "$pid" | tr -d ' ')"
    printf '  CPU%% / RSS    : %s\n' "$(ps -o %cpu=,%rss= -p "$pid")"
  fi
  echo
}

monitor_vm() {
  local name="$1"
  vm_exists "$name" || { err "No such VM."; return 1; }
  local pid; pid="$(vm_pid "$name" || true)"
  if [[ -z "$pid" ]]; then warn "VM not running."; return 0; fi
  info "Live view (Ctrl+C to return)..."
  trap 'echo; return 0' INT
  while kill -0 "$pid" 2>/dev/null; do
    clear || true
    printf '%sVM %s%s  PID %s\n' "$C_BLD" "$name" "$C_RESET" "$pid"
    printf 'CPU%%:   %s\n' "$(ps -o %cpu= -p "$pid" | tr -d ' ')"
    printf 'RSS:    %s KB\n' "$(ps -o rss= -p "$pid" | tr -d ' ')"
    printf 'Threads:%s\n' "$(ps -o nlwp= -p "$pid" | tr -d ' ')"
    printf 'Uptime: %s\n' "$(ps -o etime= -p "$pid" | tr -d ' ')"
    local mon="${RFVM_VMS}/${name}/monitor.sock"
    if [[ -S "$mon" ]]; then
      printf '\n(monitor: %s)\n' "$mon"
    fi
    sleep 2
  done
}

# ---------------------------------------------------------------------------
# List / dashboard
# ---------------------------------------------------------------------------
list_vms() {
  local conf name
  local any=0
  printf '%-20s %-10s %-8s %-6s %-6s %-8s %s\n' \
    "NAME" "STATUS" "OS" "RAM" "CPU" "SSH" "IP"
  printf '%s\n' "-------------------------------------------------------------------------"
  for conf in "${RFVM_VMS}"/*/vm.conf; do
    [[ -r "$conf" ]] || continue
    any=1
    name="$(basename "$(dirname "$conf")")"
    ( source "$conf"
      printf '%-20s %-10b %-8s %-6s %-6s %-8s %s\n' \
        "$NAME" "$(vm_status "$NAME")" "$OS" "${RAM_MB}M" "$CPU_CORES" "$SSH_PORT" "$(vm_ip "$NAME")"
    )
  done
  [[ "$any" -eq 0 ]] && warn "No VMs yet."
  echo
}

pick_vm() {
  local varname="$1"
  list_vms
  local name
  prompt name "VM name"
  vm_exists "$name" || { err "No such VM."; return 1; }
  printf -v "$varname" '%s' "$name"
}

# ---------------------------------------------------------------------------
# Menus
# ---------------------------------------------------------------------------
main_menu() {
  while :; do
    banner
    printf '%sMain menu%s\n' "$C_BLD" "$C_RESET"
    cat <<EOF
  1) List VMs / dashboard
  2) Create VM
  3) Start VM
  4) Stop VM
  5) Restart VM
  6) Suspend VM
  7) Resume VM
  8) Show VM info
  9) Monitor VM (live)
 10) Edit VM config
 11) Resize VM disk
 12) Clone VM
 13) Reinstall VM
 14) Delete VM
 15) Open VM SSH (using stored key)
 16) Reinstall dependencies
  0) Exit
EOF
    local choice; read -r -p "${C_WHT}Choice: ${C_RESET}" choice
    local vm
    case "$choice" in
      1) banner; list_vms; read -r -p "Press Enter..." _ ;;
      2) create_vm; read -r -p "Press Enter..." _ ;;
      3) pick_vm vm && start_vm   "$vm"; read -r -p "Press Enter..." _ ;;
      4) pick_vm vm && stop_vm    "$vm"; read -r -p "Press Enter..." _ ;;
      5) pick_vm vm && restart_vm "$vm"; read -r -p "Press Enter..." _ ;;
      6) pick_vm vm && suspend_vm "$vm"; read -r -p "Press Enter..." _ ;;
      7) pick_vm vm && resume_vm  "$vm"; read -r -p "Press Enter..." _ ;;
      8) pick_vm vm && vm_info    "$vm"; read -r -p "Press Enter..." _ ;;
      9) pick_vm vm && monitor_vm "$vm" ;;
     10) pick_vm vm && edit_vm    "$vm"; read -r -p "Press Enter..." _ ;;
     11) pick_vm vm && resize_disk "$vm"; read -r -p "Press Enter..." _ ;;
     12) pick_vm vm && clone_vm   "$vm"; read -r -p "Press Enter..." _ ;;
     13) pick_vm vm && reinstall_vm "$vm"; read -r -p "Press Enter..." _ ;;
     14) pick_vm vm && delete_vm  "$vm"; read -r -p "Press Enter..." _ ;;
     15)
        if pick_vm vm; then
          load_conf "$vm"
          info "Connecting to root@localhost -p ${SSH_PORT} (password: user-supplied)"
          ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -i "${RFVM_VMS}/${vm}/id_rsa" \
              -p "$SSH_PORT" "${USERNAME}@127.0.0.1" || true
          read -r -p "Press Enter..." _
        fi ;;
     16) install_deps; read -r -p "Press Enter..." _ ;;
       0) exit 0 ;;
       *) warn "Invalid choice."; sleep 1 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Boot
# ---------------------------------------------------------------------------
main() {
  need_root
  init_dirs
  install_deps
  if ! have_kvm; then
    warn "/dev/kvm not available. VMs will run in slow TCG emulation mode."
  else
    ok "KVM acceleration available."
  fi
  main_menu
}

main "$@"
