#!/usr/bin/env bash
# =============================================================================
#  RF VM MANAGER - Professional QEMU/KVM Virtual Machine Manager
#  Version: 1.0.0
#  Target : Ubuntu / Debian hosts with KVM support
#  Author : RF VM Manager Project
# =============================================================================
set -o pipefail
shopt -s nullglob

# ---------------------------------------------------------------------------
# Global configuration
# ---------------------------------------------------------------------------
readonly RFVM_VERSION="1.0.0"
readonly BASE_DIR="/var/lib/rfvm"
readonly VM_DIR="${BASE_DIR}/vms"
readonly IMG_CACHE="${BASE_DIR}/images"
readonly ISO_CACHE="${BASE_DIR}/isos"
readonly LOG_DIR="${BASE_DIR}/logs"
readonly LOCK_DIR="${BASE_DIR}/locks"
readonly SSH_KEY_DIR="${BASE_DIR}/ssh"

# Detect KVM
if [[ -w /dev/kvm ]]; then
    KVM_ENABLED=1
    KVM_ARG="-enable-kvm -cpu host"
else
    KVM_ENABLED=0
    KVM_ARG="-cpu max"
fi

# Colors
readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_BLUE='\033[0;34m'
readonly C_CYAN='\033[0;36m'
readonly C_MAGENTA='\033[0;35m'
readonly C_BOLD='\033[1m'
readonly C_DIM='\033[2m'

# ---------------------------------------------------------------------------
# Utility helpers
# ---------------------------------------------------------------------------
log()      { echo -e "${C_CYAN}[*]${C_RESET} $*"; }
success()  { echo -e "${C_GREEN}[+]${C_RESET} $*"; }
warn()     { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
error()    { echo -e "${C_RED}[-]${C_RESET} $*" >&2; }
die()      { error "$*"; exit 1; }

pause() {
    echo ""
    read -r -p "Press [Enter] to continue..." _
}

confirm() {
    local prompt="${1:-Are you sure?}"
    local reply
    read -r -p "${prompt} [y/N]: " reply
    [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

# ---------------------------------------------------------------------------
# Initialization: dependencies, directories, permissions
# ---------------------------------------------------------------------------
install_dependencies() {
    local pkgs=(
        qemu-system-x86 qemu-utils cloud-image-utils
        wget curl openssh-client iproute2 bridge-utils
        genisoimage socat
    )
    local missing=()
    for p in "${pkgs[@]}"; do
        dpkg -s "$p" &>/dev/null || missing+=("$p")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi
    log "Installing missing packages: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y --no-install-recommends "${missing[@]}" >/dev/null 2>&1 \
        || { warn "Some packages failed to install. Continuing anyway."; }
}

init_dirs() {
    mkdir -p "$VM_DIR" "$IMG_CACHE" "$ISO_CACHE" "$LOG_DIR" "$LOCK_DIR" "$SSH_KEY_DIR"
    chmod 700 "$BASE_DIR" "$VM_DIR" "$SSH_KEY_DIR"
}

require_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."
}

require_qemu() {
    command -v qemu-system-x86_64 >/dev/null 2>&1 \
        || die "qemu-system-x86_64 not found. Run with sudo to auto-install."
}

# ---------------------------------------------------------------------------
# Download helpers
# ---------------------------------------------------------------------------
download_file() {
    local url="$1" dest="$2"
    if [[ -s "$dest" ]]; then
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    log "Downloading $(basename "$dest")..."
    if ! wget -q --show-progress --timeout=60 -O "${dest}.part" "$url"; then
        rm -f "${dest}.part"
        error "Failed to download $url"
        return 1
    fi
    mv "${dest}.part" "$dest"
    return 0
}

# ---------------------------------------------------------------------------
# OS image catalog
# ---------------------------------------------------------------------------
# Format: key | display name | url
os_catalog() {
    cat <<'EOF'
ubuntu2204|Ubuntu 22.04 LTS|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
ubuntu2404|Ubuntu 24.04 LTS|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
debian11|Debian 11 (Bullseye)|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2
debian12|Debian 12 (Bookworm)|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2
fedora|Fedora 40 Cloud|https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-40-1.14.x86_64.qcow2
centos9|CentOS Stream 9|https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2
alma9|AlmaLinux 9|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2
rocky9|Rocky Linux 9|https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2
EOF
}

get_os_url() {
    os_catalog | awk -F'|' -v k="$1" '$1==k{print $3}'
}
get_os_name() {
    os_catalog | awk -F'|' -v k="$1" '$1==k{print $2}'
}

# ---------------------------------------------------------------------------
# VM metadata helpers
# ---------------------------------------------------------------------------
vm_dir()      { echo "${VM_DIR}/$1"; }
vm_conf()     { echo "${VM_DIR}/$1/vm.conf"; }
vm_disk()     { echo "${VM_DIR}/$1/disk.qcow2"; }
vm_seed()     { echo "${VM_DIR}/$1/seed.iso"; }
vm_log()      { echo "${LOG_DIR}/$1.log"; }
vm_pidfile()  { echo "${VM_DIR}/$1/qemu.pid"; }

vm_exists() { [[ -f "$(vm_conf "$1")" ]]; }

load_vm_conf() {
    local name="$1"
    [[ -f "$(vm_conf "$name")" ]] || return 1
    # shellcheck disable=SC1090
    source "$(vm_conf "$name")"
}

vm_is_running() {
    local name="$1" pidfile
    pidfile="$(vm_pidfile "$name")"
    [[ -f "$pidfile" ]] || return 1
    local pid
    pid=$$(cat "$pidfile" 2>/dev/null || true)
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

list_vm_names() {
    local d
    for d in "$VM_DIR"/*/; do
        [[ -f "${d}vm.conf" ]] && basename "$d"
    done
}

# ---------------------------------------------------------------------------
# Port & resource validation
# ---------------------------------------------------------------------------
port_in_use_host() {
    local port="$1"
    ss -ltn "sport = :${port}" 2>/dev/null | grep -q LISTEN
}

port_used_by_vm() {
    local port="$1" name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        local f
        f="$(vm_conf "$name")"
        [[ -f "$f" ]] || continue
        # shellcheck disable=SC1090
        ( source "$f"; [[ "${SSH_PORT:-}" == "$port" ]] && exit 0 || exit 1 )
        if [[ $? -eq 0 ]]; then
            echo "$name"; return 0
        fi
    done < <(list_vm_names)
    return 1
}

unique_port() {
    local start="${1:-2222}" p
    for p in $(seq "$start" $((start+200))); do
        if ! port_in_use_host "$p" && ! port_used_by_vm "$p" >/dev/null; then
            echo "$p"; return 0
        fi
    done
    return 1
}

unique_name() {
    local base="$1" n="$1" i=1
    while [[ -e "$(vm_dir "$n")" ]]; do
        n="${base}-$i"; ((i++))
    done
    echo "$n"
}

# ---------------------------------------------------------------------------
# VM creation
# ---------------------------------------------------------------------------
create_vm() {
    clear
    echo -e "${C_MAGENTA}${C_BOLD}=== Create New Virtual Machine ===${C_RESET}\n"

    local vm_name hostname os_key username password ram cpu disk_size ssh_port net_mode port_fwd gui

    read -r -p "VM name (letters, digits, dash) : " vm_name
    [[ "$vm_name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{1,30}$ ]] \
        || { error "Invalid VM name. Use 2-31 alnum/dash/underscore."; pause; return; }
    if vm_exists "$vm_name"; then
        error "A VM named '$vm_name' already exists."; pause; return
    fi

    echo ""
    echo "Select operating system:"
    local i=0 keys=()
    while IFS='|' read -r k n _; do
        ((i++)); keys+=("$k")
        printf "  %2d) %s\n" "$i" "$n"
    done < <(os_catalog)

    local choice
    read -r -p "Choice [1-${#keys[@]}]: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#keys[@]} )) \
        || { error "Invalid choice."; pause; return; }
    os_key="${keys[$((choice-1))]}"

    read -r -p "Hostname [${vm_name}]: " hostname
    hostname="${hostname:-$vm_name}"

    read -r -p "Username [rfuser]: " username
    username="${username:-rfuser}"
    [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
        || { error "Invalid username."; pause; return; }

    local pass1 pass2
    while true; do
        read -r -s -p "Password for '${username}': " pass1; echo
        read -r -s -p "Confirm password: " pass2; echo
        [[ -n "$pass1" && "$pass1" == "$pass2" ]] && break
        warn "Passwords empty or mismatched. Try again."
    done

    read -r -p "RAM in MB [2048]: " ram
    ram="${ram:-2048}"
    [[ "$ram" =~ ^[0-9]+$ ]] && (( ram>=512 && ram<=65536 )) \
        || { error "RAM must be 512-65536 MB."; pause; return; }

    read -r -p "CPU cores [2]: " cpu
    cpu="${cpu:-2}"
    [[ "$cpu" =~ ^[0-9]+$ ]] && (( cpu>=1 && cpu<=64 )) \
        || { error "CPU must be 1-64."; pause; return; }

    read -r -p "Disk size (GB) [20]: " disk_size
    disk_size="${disk_size:-20}"
    [[ "$disk_size" =~ ^[0-9]+$ ]] && (( disk_size>=5 && disk_size<=500 )) \
        || { error "Disk must be 5-500 GB."; pause; return; }

    local def_port
    def_port="$(unique_port 2222)" || die "No free SSH port in range."
    read -r -p "SSH port on host [${def_port}]: " ssh_port
    ssh_port="${ssh_port:-$def_port}"
    [[ "$ssh_port" =~ ^[0-9]+$ ]] && (( ssh_port>=1024 && ssh_port<=65535 )) \
        || { error "Port must be 1024-65535."; pause; return; }
    if port_in_use_host "$ssh_port" || port_used_by_vm "$ssh_port" >/dev/null; then
        error "Port ${ssh_port} already in use."; pause; return
    fi

    echo ""
    echo "Network mode:"
    echo "  1) NAT  (user-mode, default, no host setup)"
    echo "  2) Bridge (requires pre-existing br0 on host)"
    read -r -p "Choice [1]: " net_mode
    net_mode="${net_mode:-1}"
    if [[ "$net_mode" == "2" ]] && ! ip link show br0 &>/dev/null; then
        error "Bridge br0 does not exist on host."; pause; return
    fi

    read -r -p "Extra host port forwarding (e.g. 8080:80, blank=none): " port_fwd

    read -r -p "GUI mode? (VNC display) [y/N]: " gui
    [[ "${gui,,}" == "y" ]] && gui=1 || gui=0

    # ---- Begin build ----
    local dir; dir="$(vm_dir "$vm_name")"
    mkdir -p "$dir"
    chmod 700 "$dir"

    # Download base image
    local img_url img_cache
    img_url="$(get_os_url "$os_key")"
    img_cache="${IMG_CACHE}/$(basename "$img_url")"
    if ! download_file "$img_url" "$img_cache"; then
        error "OS image download failed."; rm -rf "$dir"; pause; return
    fi

    log "Creating QCOW2 disk (${disk_size}GB, backing from base image)..."
    qemu-img create -f qcow2 -F qcow2 -b "$img_cache" "$(vm_disk "$vm_name")" "${disk_size}G" >/dev/null \
        || { error "Disk creation failed."; rm -rf "$dir"; pause; return; }

    # Generate SSH key (for convenience)
    local ssh_key="${SSH_KEY_DIR}/${vm_name}_id_rsa"
    [[ -f "${ssh_key}.pub" ]] || ssh-keygen -t ed25519 -N '' -f "$ssh_key" -q
    local pubkey; pubkey="$(cat "${ssh_key}.pub")"

    # Cloud-init
    log "Generating cloud-init seed ISO..."
    cat > "${dir}/user-data" <<EOF
#cloud-config
hostname: ${hostname}
fqdn: ${hostname}
manage_etc_hosts: true
users:
  - name: ${username}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - ${pubkey}
ssh_pwauth: true
chpasswd:
  list: |
    ${username}:${pass1}
  expire: false
package_update: true
runcmd:
  - [ sh, -c, "systemctl enable --now ssh || systemctl enable --now sshd || true" ]
EOF
    cat > "${dir}/meta-data" <<EOF
instance-id: ${vm_name}-$(date +%s)
local-hostname: ${hostname}
EOF

    if command -v cloud-localds >/dev/null 2>&1; then
        cloud-localds "$(vm_seed "$vm_name")" "${dir}/user-data" "${dir}/meta-data" \
            || { error "cloud-localds failed."; rm -rf "$dir"; pause; return; }
    else
        error "cloud-localds missing (cloud-image-utils)."; rm -rf "$dir"; pause; return
    fi
    chmod 600 "${dir}/user-data" "${dir}/meta-data"

    # Persist config
    {
        echo "VM_NAME='${vm_name}'"
        echo "VM_ID='$(date +%Y%m%d%H%M%S)-${vm_name}'"
        echo "OS_KEY='${os_key}'"
        echo "OS_NAME='$(get_os_name "$os_key")'"
        echo "HOSTNAME='${hostname}'"
        echo "USERNAME='${username}'"
        echo "RAM='${ram}'"
        echo "CPU='${cpu}'"
        echo "DISK_SIZE='${disk_size}'"
        echo "SSH_PORT='${ssh_port}'"
        echo "NET_MODE='${net_mode}'"
        echo "PORT_FWD='${port_fwd}'"
        echo "GUI='${gui}'"
        echo "CREATED='$(date -Iseconds)'"
        echo "SSH_KEY='${ssh_key}'"
    } > "$(vm_conf "$vm_name")"
    chmod 600 "$(vm_conf "$vm_name")"

    success "VM '${vm_name}' created."
    success "  SSH  : ssh -p ${ssh_port} ${username}@127.0.0.1"
    success "  Key  : ${ssh_key}"
    success "  Disk : $(vm_disk "$vm_name")"
    pause
}

# ---------------------------------------------------------------------------
# VM lifecycle
# ---------------------------------------------------------------------------
build_qemu_args() {
    local name="$1"
    load_vm_conf "$name" || return 1

    local args=()
    args+=($KVM_ARG)
    args+=(-m "$RAM" -smp "$CPU" -name "$VM_NAME")
    args+=(-drive "file=$(vm_disk "$name"),if=virtio,format=qcow2,cache=writeback")
    args+=(-drive "file=$(vm_seed "$name"),if=virtio,format=raw,readonly=on")
    args+=(-pidfile "$(vm_pidfile "$name")")
    args+=(-daemonize)

    if [[ "$GUI" == "1" ]]; then
        args+=(-vnc ":0" -vga std)
    else
        args+=(-nographic -serial "file:$(vm_log "$name")" -monitor none)
    fi

    if [[ "$NET_MODE" == "2" ]]; then
        args+=(-netdev "bridge,id=net0,br=br0")
        args+=(-device "virtio-net-pci,netdev=net0")
    else
        local hostfwd="hostfwd=tcp::${SSH_PORT}-:22"
        if [[ -n "$PORT_FWD" ]]; then
            IFS=',' read -ra fwds <<< "$PORT_FWD"
            for f in "${fwds[@]}"; do
                [[ "$f" =~ ^[0-9]+:[0-9]+$ ]] && hostfwd+=",hostfwd=tcp::${f%:*}-:${f#*:}"
            done
        fi
        args+=(-netdev "user,id=net0,${hostfwd}")
        args+=(-device "virtio-net-pci,netdev=net0")
    fi

    printf '%s\n' "${args[@]}"
}

start_vm() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        select_vm_or_return; name="$SELECTED_VM"
        [[ -z "$name" ]] && return
    fi
    vm_exists "$name" || { error "VM '$name' does not exist."; pause; return; }
    if vm_is_running "$name"; then
        warn "VM '$name' is already running."; pause; return
    fi

    local -a qemu_args
    mapfile -t qemu_args < <(build_qemu_args "$name")

    log "Starting VM '$name'..."
    if qemu-system-x86_64 "${qemu_args[@]}"; then
        success "VM '$name' started (PID $(cat "$(vm_pidfile "$name")" 2>/dev/null))."
        load_vm_conf "$name"
        [[ "$NET_MODE" == "1" ]] && success "SSH: ssh -p ${SSH_PORT} ${USERNAME}@127.0.0.1"
        [[ "$GUI" == "1" ]] && success "VNC: :0 (e.g. vncviewer 127.0.0.1:5900)"
    else
        error "Failed to start VM '$name'. Check $(vm_log "$name")."
    fi
    pause
}

stop_vm() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        select_vm_or_return; name="$SELECTED_VM"
        [[ -z "$name" ]] && return
    fi
    vm_is_running "$name" || { warn "VM '$name' is not running."; pause; return; }

    confirm "Stop (poweroff via ACPI) VM '$name'?" || return
    local pid; pid=$(cat "$(vm_pidfile "$name")" 2>/dev/null || true)
    [[ -n "$pid" ]] || { rm -f "$(vm_pidfile "$name")"; return; }

    log "Sending ACPI shutdown..."
    kill -TERM "$pid" 2>/dev/null || true
    local i
    for i in {1..30}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
        warn "Still running after 30s; forcing stop."
        kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$(vm_pidfile "$name")"
    success "VM '$name' stopped."
    pause
}

restart_vm() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        select_vm_or_return; name="$SELECTED_VM"
        [[ -z "$name" ]] && return
    fi
    if vm_is_running "$name"; then
        local pid; pid=$(cat "$(vm_pidfile "$name")" 2>/dev/null || true)
        [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null
        sleep 3
        [[ -n "$pid" ]] && kill -KILL "$pid" 2>/dev/null || true
        rm -f "$(vm_pidfile "$name")"
    fi
    start_vm "$name"
}

suspend_vm() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        select_vm_or_return; name="$SELECTED_VM"
        [[ -z "$name" ]] && return
    fi
    vm_is_running "$name" || { warn "VM not running."; pause; return; }
    local pid; pid=$(cat "$(vm_pidfile "$name")" 2>/dev/null)
    kill -STOP "$pid" 2>/dev/null && success "VM '$name' suspended (SIGSTOP)." \
        || error "Suspend failed."
    pause
}

resume_vm() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        select_vm_or_return; name="$SELECTED_VM"
        [[ -z "$name" ]] && return
    fi
    vm_is_running "$name" || { warn "VM not running."; pause; return; }
    local pid; pid=$(cat "$(vm_pidfile "$name")" 2>/dev/null)
    kill -CONT "$pid" 2>/dev/null && success "VM '$name' resumed." \
        || error "Resume failed."
    pause
}

delete_vm() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        select_vm_or_return; name="$SELECTED_VM"
        [[ -z "$name" ]] && return
    fi
    vm_exists "$name" || { error "VM '$name' does not exist."; pause; return; }

    warn "This will permanently delete VM '$name' and ALL its data."
    confirm "Are you absolutely sure?" || return
    read -r -p "Type VM name to confirm deletion: " confirm_name
    [[ "$confirm_name" == "$name" ]] || { error "Confirmation failed."; pause; return; }

    if vm_is_running "$name"; then
        local pid; pid=$(cat "$(vm_pidfile "$name")" 2>/dev/null || true)
        [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null && sleep 2 && kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "${SSH_KEY_DIR}/${name}_id_rsa" "${SSH_KEY_DIR}/${name}_id_rsa.pub"
    rm -rf "$(vm_dir "$name")"
    success "VM '$name' deleted."
    pause
}

reinstall_vm() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        select_vm_or_return; name="$SELECTED_VM"
        [[ -z "$name" ]] && return
    fi
    vm_exists "$name" || { error "VM not found."; pause; return; }

    load_vm_conf "$name"
    confirm "Reinstall VM '$name'? Existing disk data will be DESTROYED." || return
    read -r -p "Type VM name to confirm: " c
    [[ "$c" == "$name" ]] || { error "Confirmation failed."; pause; return; }

    # Stop
    if vm_is_running "$name"; then
        local pid; pid=$(cat "$(vm_pidfile "$name")" 2>/dev/null || true)
        [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null && sleep 2 && kill -KILL "$pid" 2>/dev/null || true
    fi

    local img_url img_cache
    img_url="$(get_os_url "$OS_KEY")"
    img_cache="${IMG_CACHE}/$(basename "$img_url")"
    download_file "$img_url" "$img_cache" || { error "Image download failed."; pause; return; }

    rm -f "$(vm_disk "$name")" "$(vm_seed "$name")"
    qemu-img create -f qcow2 -F qcow2 -b "$img_cache" "$(vm_disk "$name")" "${DISK_SIZE}G" >/dev/null \
        || { error "Re-create disk failed."; pause; return; }

    # Regenerate seed
    local dir; dir="$(vm_dir "$name")"
    local pubkey; pubkey="$(cat "${SSH_KEY_DIR}/${name}_id_rsa.pub" 2>/dev/null || echo '')"
    cat > "${dir}/user-data" <<EOF
#cloud-config
hostname: ${HOSTNAME}
users:
  - name: ${USERNAME}
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    ssh_authorized_keys:
      - ${pubkey}
ssh_pwauth: true
runcmd:
  - [ sh, -c, "systemctl enable --now ssh || true" ]
EOF
    cat > "${dir}/meta-data" <<EOF
instance-id: ${name}-reinstall-$(date +%s)
local-hostname: ${HOSTNAME}
EOF
    cloud-localds "$(vm_seed "$name")" "${dir}/user-data" "${dir}/meta-data" \
        || { error "cloud-init seed failed."; pause; return; }
    success "VM '$name' reinstalled. Start it to boot."
    pause
}

clone_vm() {
    local src="${1:-}"
    if [[ -z "$src" ]]; then
        select_vm_or_return; src="$SELECTED_VM"
        [[ -z "$src" ]] && return
    fi
    vm_exists "$src" || { error "Source VM not found."; pause; return; }
    if vm_is_running "$src"; then
        error "Cannot clone a running VM. Stop it first."; pause; return
    fi
    read -r -p "New VM name: " dst
    [[ "$dst" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{1,30}$ ]] \
        || { error "Invalid name."; pause; return; }
    vm_exists "$dst" && { error "Name already exists."; pause; return; }

    local new_port; new_port="$(unique_port 2222)" || { error "No free port."; pause; return; }
    local dstdir; dstdir="$(vm_dir "$dst")"
    mkdir -p "$dstdir"; chmod 700 "$dstdir"

    log "Copying disk (this may take a while)..."
    qemu-img convert -O qcow2 "$(vm_disk "$src")" "$(vm_disk "$dst")" \
        || { error "Disk copy failed."; rm -rf "$dstdir"; pause; return; }

    cp "$(vm_seed "$src")" "$(vm_seed "$dst")"
    load_vm_conf "$src"
    {
        echo "VM_NAME='${dst}'"
        echo "VM_ID='$(date +%Y%m%d%H%M%S)-${dst}'"
        echo "OS_KEY='${OS_KEY}'"
        echo "OS_NAME='${OS_NAME}'"
        echo "HOSTNAME='${dst}'"
        echo "USERNAME='${USERNAME}'"
        echo "RAM='${RAM}'"
        echo "CPU='${CPU}'"
        echo "DISK_SIZE='${DISK_SIZE}'"
        echo "SSH_PORT='${new_port}'"
        echo "NET_MODE='${NET_MODE}'"
        echo "PORT_FWD=''"
        echo "GUI='${GUI}'"
        echo "CREATED='$(date -Iseconds)'"
        echo "SSH_KEY='${SSH_KEY_DIR}/${dst}_id_rsa'"
    } > "$(vm_conf "$dst")"
    chmod 600 "$(vm_conf "$dst")"
    success "VM cloned: '${src}' -> '${dst}' (SSH port ${new_port})."
    warn "Note: cloned VM still uses source cloud-init config. Reinstall for clean provisioning."
    pause
}

resize_disk() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        select_vm_or_return; name="$SELECTED_VM"
        [[ -z "$name" ]] && return
    fi
    vm_exists "$name" || { error "VM not found."; pause; return; }
    if vm_is_running "$name"; then
        warn "VM is running. Live resize may require guest action."
    fi
    load_vm_conf "$name"
    read -r -p "New disk size in GB (current ${DISK_SIZE}): " new_size
    [[ "$new_size" =~ ^[0-9]+$ ]] && (( new_size > DISK_SIZE && new_size <= 2000 )) \
        || { error "Invalid new size."; pause; return; }
    confirm "Resize disk of '$name' to ${new_size}GB?" || return
    qemu-img resize "$(vm_disk "$name")" "${new_size}G" \
        || { error "Resize failed."; pause; return; }
    sed -i "s/^DISK_SIZE=.*/DISK_SIZE='${new_size}'/" "$(vm_conf "$name")"
    success "Disk resized to ${new_size}GB."
    warn "Run inside guest: 'growpart /dev/vda 1 && resize2fs /dev/vda1'."
    pause
}

edit_vm_conf() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        select_vm_or_return; name="$SELECTED_VM"
        [[ -z "$name" ]] && return
    fi
    vm_exists "$name" || { error "VM not found."; pause; return; }
    if vm_is_running "$name"; then
        warn "VM is running. Changes apply on next boot."
    fi
    local tmp; tmp="$(mktemp)"
    cp "$(vm_conf "$name")" "$tmp"
    "${EDITOR:-nano}" "$tmp"
    # Re-source and validate
    local err=0
    # shellcheck disable=SC1090
    ( source "$tmp"; \
        [[ "$RAM" =~ ^[0-9]+$ && "$CPU" =~ ^[0-9]+$ && "$SSH_PORT" =~ ^[0-9]+$ ]] || exit 1
    ) || err=1
    if (( err )); then
        error "Edited config contains invalid values. Aborting."
        rm -f "$tmp"; pause; return
    fi
    mv "$tmp" "$(vm_conf "$name")"
    chmod 600 "$(vm_conf "$name")"
    success "Config saved."
    pause
}

# ---------------------------------------------------------------------------
# Status / info / monitoring
# ---------------------------------------------------------------------------
select_vm_or_return() {
    SELECTED_VM=""
    local names=()
    while IFS= read -r n; do [[ -n "$n" ]] && names+=("$n"); done < <(list_vm_names)
    if [[ ${#names[@]} -eq 0 ]]; then
        warn "No VMs exist yet. Create one first."
        pause
        return 1
    fi
    echo ""
    local i
    for i in "${!names[@]}"; do
        local state="stopped"
        vm_is_running "${names[$i]}" && state="running"
        printf "  %2d) %-24s [%s]\n" "$((i+1))" "${names[$i]}" "$state"
    done
    local choice
    read -r -p "Select VM by number (0=cancel): " choice
    [[ "$choice" == "0" ]] && return 1
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#names[@]} )) || return 1
    SELECTED_VM="${names[$((choice-1))]}"
    return 0
}

show_vm_info() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        select_vm_or_return; name="$SELECTED_VM"
        [[ -z "$name" ]] && return
    fi
    vm_exists "$name" || { error "VM not found."; pause; return; }
    load_vm_conf "$name"

    local state="${C_RED}STOPPED${C_RESET}"
    vm_is_running "$name" && state="${C_GREEN}RUNNING${C_RESET}"

    clear
    echo -e "${C_BOLD}${C_MAGENTA}=== VM: ${name} ===${C_RESET}\n"
    printf "  %-18s : %s\n" "VM ID"       "$VM_ID"
    printf "  %-18s : %s\n" "OS"          "$OS_NAME"
    printf "  %-18s : %s\n" "Status"      "$state"
    printf "  %-18s : %s\n" "Hostname"    "$HOSTNAME"
    printf "  %-18s : %s\n" "Username"    "$USERNAME"
    printf "  %-18s : %s MB\n" "RAM"      "$RAM"
    printf "  %-18s : %s cores\n" "CPU"   "$CPU"
    printf "  %-18s : %s GB\n" "Disk"     "$DISK_SIZE"
    printf "  %-18s : %s\n" "SSH port"    "$SSH_PORT"
    printf "  %-18s : %s\n" "Net mode"    "$([[ "$NET_MODE" == "2" ]] && echo Bridge || echo NAT)"
    printf "  %-18s : %s\n" "Port fwd"    "${PORT_FWD:-none}"
    printf "  %-18s : %s\n" "GUI"         "$([[ "$GUI" == "1" ]] && echo VNC || echo Headless)"
    printf "  %-18s : %s\n" "Created"     "$CREATED"
    printf "  %-18s : %s\n" "Disk path"   "$(vm_disk "$name")"
    printf "  %-18s : %s\n" "Config file" "$(vm_conf "$name")"
    pause
}

vm_ip_address() {
    local name="$1"
    load_vm_conf "$name" || return
    if [[ "$NET_MODE" == "2" ]]; then
        # bridge: try ARP / DHCP lease from dnsmasq-less setup; attempt neighbour table
        local mac
        mac=$(virsh domiflist 2>/dev/null | awk -v n="$name" '$1==n{print $5}' || true)
        [[ -n "$mac" ]] && ip neigh | awk -v m="$mac" '$3==m{print $1; exit}'
    else
        # NAT user-mode: guest gets 10.0.2.15; not directly reachable except via port forward
        echo "10.0.2.15 (NAT guest)"
    fi
}

show_vm_monitor() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        select_vm_or_return; name="$SELECTED_VM"
        [[ -z "$name" ]] && return
    fi
    vm_is_running "$name" || { warn "VM not running. No live metrics."; pause; return; }
    local pid; pid=$(cat "$(vm_pidfile "$name")" 2>/dev/null)
    [[ -n "$pid" ]] || { error "PID file missing."; pause; return; }

    clear
    echo -e "${C_BOLD}${C_MAGENTA}=== Live Monitoring: ${name} (PID ${pid}) ===${C_RESET}\n"
    if command -v ps >/dev/null; then
        printf "  %-18s : " "QEMU process"
        ps -p "$pid" -o %cpu=,rss=,etime= --no-headers | awk '{printf "CPU %s%%  RSS %dMB  Uptime %s\n", $1, $2/1024, $3}'
    fi
    if [[ -d "/proc/${pid}" ]]; then
        local fd_count
        fd_count=$(ls "/proc/${pid}/fd" 2>/dev/null | wc -l)
        printf "  %-18s : %s\n" "Open FDs"    "$fd_count"
    fi
    local ip
    ip="$(vm_ip_address "$name")"
    printf "  %-18s : %s\n" "IP"           "${ip:-unknown}"
    load_vm_conf "$name"
    printf "  %-18s : %s\n" "SSH endpoint" "127.0.0.1:${SSH_PORT}"
    printf "  %-18s : %s\n" "Log file"     "$(vm_log "$name")"
    pause
}

# ---------------------------------------------------------------------------
# Dashboard / listing
# ---------------------------------------------------------------------------
show_dashboard() {
    clear
    echo -e "${C_BOLD}${C_MAGENTA}================================================================${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}             RF VM MANAGER  v${RFVM_VERSION}  -  Dashboard${C_RESET}"
    echo -e "${C_BOLD}${C_MAGENTA}================================================================${C_RESET}"
    echo -e "  KVM acceleration : $([[ $KVM_ENABLED -eq 1 ]] && echo -e "${C_GREEN}enabled${C_RESET}" || echo -e "${C_YELLOW}disabled${C_RESET}")"
    echo -e "  Base directory   : ${BASE_DIR}"
    local total running stopped
    total=$(list_vm_names | wc -l)
    running=0; stopped=0
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        if vm_is_running "$n"; then ((running++)); else ((stopped++)); fi
    done < <(list_vm_names)
    echo -e "  Virtual machines : ${total} total  ${C_GREEN}${running} running${C_RESET}  ${C_RED}${stopped} stopped${C_RESET}"
    echo ""
    if [[ "$total" -gt 0 ]]; then
        printf "  %-4s %-24s %-20s %-10s %-8s %-10s\n" "#" "NAME" "OS" "STATUS" "SSH" "DISK"
        printf "  %s\n" "---------------------------------------------------------------------------"
        local i=1
        while IFS= read -r n; do
            [[ -z "$n" ]] && continue
            load_vm_conf "$n" 2>/dev/null || continue
            local st
            if vm_is_running "$n"; then st="${C_GREEN}RUNNING${C_RESET}"; else st="${C_RED}STOPPED${C_RESET}"; fi
            printf "  %-4d %-24s %-20s %b  %-8s %-8sGB\n" "$i" "$n" "$OS_NAME" "$st" "$SSH_PORT" "$DISK_SIZE"
            ((i++))
        done < <(list_vm_names)
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        show_dashboard
        echo -e "${C_CYAN}--- Operations ---${C_RESET}"
        cat <<EOF
  1)  Create VM
  2)  Start VM
  3)  Stop VM
  4)  Restart VM
  5)  Suspend VM
  6)  Resume VM
  7)  Show VM information
  8)  Edit VM configuration
  9)  Resize VM disk
 10)  Clone VM
 11)  Reinstall VM
 12)  Performance monitoring
 13)  Delete VM
 14)  Install / update dependencies
 15)  Exit
EOF
        local ch
        read -r -p "> " ch
        case "$ch" in
            1)  create_vm ;;
            2)  select_vm_or_return && start_vm   "$SELECTED_VM" ;;
            3)  select_vm_or_return && stop_vm    "$SELECTED_VM" ;;
            4)  select_vm_or_return && restart_vm "$SELECTED_VM" ;;
            5)  select_vm_or_return && suspend_vm "$SELECTED_VM" ;;
            6)  select_vm_or_return && resume_vm  "$SELECTED_VM" ;;
            7)  select_vm_or_return && show_vm_info "$SELECTED_VM" ;;
            8)  select_vm_or_return && edit_vm_conf "$SELECTED_VM" ;;
            9)  select_vm_or_return && resize_disk "$SELECTED_VM" ;;
            10) select_vm_or_return && clone_vm   "$SELECTED_VM" ;;
            11) select_vm_or_return && reinstall_vm "$SELECTED_VM" ;;
            12) select_vm_or_return && show_vm_monitor "$SELECTED_VM" ;;
            13) select_vm_or_return && delete_vm  "$SELECTED_VM" ;;
            14) install_dependencies; pause ;;
            15) echo "Goodbye."; exit 0 ;;
            *)  warn "Invalid choice."; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
    require_root
    init_dirs
    require_qemu
    install_dependencies
    main_menu
}

main "$@"
