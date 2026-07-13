#!/usr/bin/env bash

#  IamGunpoint
#  ======================================================
#  PUFFERPANEL UNIVERSAL INSTALLER v1.1
#  Author: IamGunpoint
#  DO NOT COPY MY CODE - IamGunpoint 2026
#  ======================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

BANNER='\n  ╭──────────────────────────────────────────────╮\n  │              IamGunpoint Installer           │\n  │       PufferPanel + Docker + PM2 Repair      │\n  ╰──────────────────────────────────────────────╯\n'

printf "${CYAN}%b${NC}\n" "$BANNER"
printf "${BLUE}Author pinned: IamGunpoint${NC}\n"
printf "${YELLOW}Cool curved cards edition${NC}\n\n"

SUDO=""
if [[ ${EUID} -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo -e "${RED}[ERROR] Run as root or install sudo.${NC}"
    exit 1
  fi
fi

log() { echo -e "${CYAN}[*]${NC} $1"; }
ok() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; }

print_card() {
  local title="$1"
  echo -e "${BLUE}╭──────────────────────────────────────────────╮${NC}"
  printf "${BLUE}│${NC} %-44s ${BLUE}│${NC}\n" "$title"
  echo -e "${BLUE}╰──────────────────────────────────────────────╯${NC}"
}

random_string() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"
}

get_ip() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
  if [[ -z "${ip:-}" ]]; then
    ip=$(curl -4 -fsSL ifconfig.me 2>/dev/null || true)
  fi
  echo "${ip:-YOUR_SERVER_IP}"
}

run_safe() {
  local msg="$1"
  shift
  log "$msg"
  if "$@"; then
    ok "$msg"
    return 0
  fi
  warn "$msg failed, continuing"
  return 1
}

pkg_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

apt_fix() {
  warn "Trying to repair broken packages"
  ${SUDO} dpkg --configure -a || true
  ${SUDO} apt --fix-broken install -y || true
  ${SUDO} apt clean || true
  ${SUDO} apt update -y || true
}

ensure_pkg() {
  local pkg="$1"
  if pkg_installed "$pkg"; then
    ok "$pkg already installed"
    return 0
  fi

  if ${SUDO} apt install -y "$pkg"; then
    ok "$pkg installed"
    return 0
  fi

  warn "Install failed for $pkg, running apt repair"
  apt_fix

  if ${SUDO} apt install -y "$pkg"; then
    ok "$pkg installed after repair"
    return 0
  fi

  warn "Still could not install $pkg"
  return 1
}

ensure_base_packages() {
  local packages=(curl gnupg ca-certificates lsb-release software-properties-common apt-transport-https)
  for pkg in "${packages[@]}"; do
    ensure_pkg "$pkg" || true
  done
}

ensure_docker() {
  print_card "Docker packages"
  if cmd_exists docker; then
    ok "Docker already installed"
  else
    ensure_pkg docker.io || true
  fi
  run_safe "Enabling Docker service" ${SUDO} systemctl enable docker
  run_safe "Starting Docker service" ${SUDO} systemctl start docker
}

start_docker_custom() {
  print_card "Docker custom start"
  log "Applying your custom Docker starter flow"
  set +u
  : "${HOME:=/root}"; : "${USER:=root}"; export HOME USER

  if docker info >/dev/null 2>&1; then
    ok "Docker already running"
    docker version || true
    set -u
    return 0
  fi

  ${SUDO} pkill -9 dockerd 2>/dev/null || true
  ${SUDO} rm -f /var/run/docker.sock /var/run/docker.pid 2>/dev/null || true
  ${SUDO} modprobe overlay 2>/dev/null || true
  ${SUDO} sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

  echo "[18] dockerd_vfs_storage_driver (prob 99%)"
  echo "[*] CMD: dockerd --storage-driver=vfs --iptables=false"
  ${SUDO} nohup dockerd --storage-driver=vfs --iptables=false >/tmp/dockerd.iamgunpoint.vfs.log 2>&1 &

  for i in {1..12}; do
    sleep 1
    printf "."
    docker info >/dev/null 2>&1 && break
  done
  echo

  if docker info >/dev/null 2>&1; then
    ok "Docker started successfully"
  else
    warn "Custom VFS Docker start did not fully report ready"
    warn "Trying systemctl restart docker"
    ${SUDO} systemctl restart docker >/dev/null 2>&1 || true
    sleep 3
    if docker info >/dev/null 2>&1; then
      ok "Docker recovered after restart"
    else
      warn "Check log: /tmp/dockerd.iamgunpoint.vfs.log"
    fi
  fi
  set -u
}

ensure_node_pm2() {
  print_card "Node.js + PM2"

  if cmd_exists pm2; then
    ok "PM2 already installed"
    return 0
  fi

  if cmd_exists npm && cmd_exists node; then
    ok "Node and npm already present"
  else
    warn "Default apt nodejs/npm may conflict on some systems"
    warn "Using NodeSource setup to avoid nodejs vs npm conflict"
    curl -fsSL https://deb.nodesource.com/setup_20.x | ${SUDO} bash - || true
    apt_fix
    ensure_pkg nodejs || true
  fi

  if ! cmd_exists npm; then
    warn "npm missing, trying repair and reinstall nodejs"
    apt_fix
    ensure_pkg nodejs || true
  fi

  if cmd_exists npm; then
    run_safe "Installing PM2 globally" ${SUDO} npm install -g pm2
  else
    warn "npm still unavailable, PM2 install skipped"
  fi
}

setup_pufferpanel_repo() {
  print_card "PufferPanel repository"
  log "Adding PufferPanel apt repo"
  mkdir -p /tmp/pufferpanel-setup
  curl -fsSL https://packagecloud.io/pufferpanel/pufferpanel/gpgkey | ${SUDO} gpg --dearmor -o /usr/share/keyrings/pufferpanel-archive-keyring.gpg || true
  DIST_CODENAME=$(lsb_release -cs 2>/dev/null || echo focal)
  echo "deb [signed-by=/usr/share/keyrings/pufferpanel-archive-keyring.gpg] https://packagecloud.io/pufferpanel/pufferpanel/ubuntu/ ${DIST_CODENAME} main" | ${SUDO} tee /etc/apt/sources.list.d/pufferpanel.list >/dev/null || true
  ${SUDO} apt update -y || apt_fix
}

ensure_pufferpanel() {
  print_card "PufferPanel install"
  if cmd_exists pufferpanel; then
    ok "PufferPanel already installed"
  else
    ensure_pkg pufferpanel || true
    if ! cmd_exists pufferpanel; then
      warn "Trying repo refresh and reinstall"
      setup_pufferpanel_repo
      ensure_pkg pufferpanel || true
    fi
  fi

  run_safe "Enabling pufferpanel service" ${SUDO} systemctl enable pufferpanel
  run_safe "Starting pufferpanel service" ${SUDO} systemctl start pufferpanel
}

create_admin_user() {
  print_card "Admin user creation"
  echo -n "Enter admin username: "
  read -r ADMIN_USER
  echo -n "Enter admin email: "
  read -r ADMIN_EMAIL

  if [[ -z "${ADMIN_USER:-}" || -z "${ADMIN_EMAIL:-}" ]]; then
    err "Username and email are required"
    return 1
  fi

  ADMIN_PASS="mhm44323@"
  log "Creating PufferPanel admin user"

  if ${SUDO} pufferpanel user add --name "$ADMIN_USER" --email "$ADMIN_EMAIL" --password "$ADMIN_PASS" --admin >/tmp/pufferpanel-user-add.log 2>&1; then
    ok "Admin user created"
    return 0
  fi

  warn "Primary command failed, trying fallback"
  if ${SUDO} pufferpanel user create --name "$ADMIN_USER" --email "$ADMIN_EMAIL" --password "$ADMIN_PASS" --admin >>/tmp/pufferpanel-user-add.log 2>&1; then
    ok "Admin user created with fallback"
    return 0
  fi

  if grep -qiE 'already exists|duplicate' /tmp/pufferpanel-user-add.log 2>/dev/null; then
    warn "User may already exist, continuing"
    ADMIN_PASS="EXISTING_USER_PASSWORD_NOT_CHANGED"
    return 0
  fi

  warn "Could not create admin automatically"
  warn "See log: /tmp/pufferpanel-user-add.log"
  ADMIN_PASS="USER_CREATE_FAILED_CHECK_LOG"
  return 0
}

setup_pm2() {
  print_card "PM2 startup"

  if ! cmd_exists pm2; then
    warn "PM2 not found, skipping PM2 setup"
    return 0
  fi

  if pgrep -f 'pufferpanel.*runService' >/dev/null 2>&1 || pgrep -x pufferpanel >/dev/null 2>&1; then
    ok "PufferPanel already appears running"
  else
    log "Starting pufferpanel with PM2"
    if pm2 describe pufferpanel >/dev/null 2>&1; then
      ok "PM2 process pufferpanel already exists"
      pm2 restart pufferpanel || true
    else
      if pm2 start "$(command -v pufferpanel)" --name pufferpanel -- runService; then
        ok "PM2 started pufferpanel with runService"
      else
        warn "runService start failed, trying without runService"
        pm2 start "$(command -v pufferpanel)" --name pufferpanel || true
      fi
    fi
  fi

  pm2 save || true
  PM2_USER="${SUDO_USER:-root}"
  PM2_HOME_DIR=$(eval echo "~${PM2_USER}")
  PM2_STARTUP_OUTPUT=$(pm2 startup systemd -u "$PM2_USER" --hp "$PM2_HOME_DIR" 2>/dev/null || true)
  PM2_STARTUP_CMD=$(echo "$PM2_STARTUP_OUTPUT" | grep -E 'sudo|env PATH=' | tail -n 1)
  if [[ -n "${PM2_STARTUP_CMD:-}" ]]; then
    bash -c "$PM2_STARTUP_CMD" || true
  fi
}

cloudflare_prompt() {
  print_card "Cloudflare prompt"
  CLOUDFLARE_ENABLED="No"
  CLOUDFLARE_TOKEN="Not provided"
  read -r -p "Do you want Cloudflare? (y/n): " CF_ANSWER
  if [[ "$CF_ANSWER" =~ ^[Yy]$ ]]; then
    CLOUDFLARE_ENABLED="Yes"
    read -r -p "Enter Cloudflare token: " CLOUDFLARE_TOKEN
  fi
}

main() {
  print_card "System update"
  run_safe "Running apt update" ${SUDO} apt update -y
  apt_fix

  print_card "Base packages"
  ensure_base_packages

  ensure_docker
  start_docker_custom
  ensure_node_pm2
  setup_pufferpanel_repo
  ensure_pufferpanel
  create_admin_user || true
  setup_pm2
  cloudflare_prompt

  SERVER_IP=$(get_ip)
  PANEL_URL="http://${SERVER_IP}:8080"

  print_card "Install complete"
  echo -e "${GREEN}PufferPanel install finished.${NC}"
  echo
  echo "Username : ${ADMIN_USER:-not-set}"
  echo "Password : ${ADMIN_PASS:-not-set}"
  echo "Email    : ${ADMIN_EMAIL:-not-set}"
  echo "URL      : ${PANEL_URL}"
  echo "Docker   : $(docker --version 2>/dev/null || echo unavailable)"
  echo "PM2      : $(pm2 --version 2>/dev/null || echo unavailable)"
  echo "Cloudflare enabled : ${CLOUDFLARE_ENABLED:-No}"
  echo "Cloudflare token   : ${CLOUDFLARE_TOKEN:-Not provided}"
  echo
  echo "Done. - IamGunpoint"
}

main "$@"
