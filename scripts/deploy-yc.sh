#!/usr/bin/env bash
# Usage on a fresh Ubuntu VM:
#   sudo bash deploy-yc.sh
# The public HTTP listener is inherited from proxy.yaml (TCP 8090).
set -Eeuo pipefail
umask 022

readonly REPO_URL='https://github.com/brg171171/hw_docker_2.git'
readonly APP_DIR='/opt/hw_docker_2'
readonly PROJECT_NAME='hw-docker-2'
readonly STATE_DIR='/var/lib/hw-docker-2'

log() { printf '\n[deploy] %s\n' "$*"; }
die() { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }
compose() { docker compose --project-name "$PROJECT_NAME" --project-directory "$APP_DIR" "$@"; }

on_error() {
  local code=$?
  trap - ERR
  printf '\n[deploy] Failed with exit code %s. Existing data is preserved.\n' "$code" >&2
  if command -v docker >/dev/null && [[ -f "$APP_DIR/compose.yaml" ]]; then
    compose ps -a >&2 || true
    compose logs --no-color --tail=50 web db reverse-proxy ingress-proxy >&2 || true
  fi
  exit "$code"
}
trap on_error ERR

if [[ "${1:-}" == '--help' ]]; then
  printf '%s\n' \
    'Usage: sudo bash deploy-yc.sh' \
    'Deploys https://github.com/brg171171/hw_docker_2 to /opt/hw_docker_2.' \
    'On the first run, replaces the public example passwords with random local ones.' \
    'On subsequent runs, preserves .env and the MySQL volume.' \
    'Optional PIP_CA_FILE=/path/to/ca-bundle supplies a BuildKit CA secret.' \
    'Does not create a cloud VM or open cloud security-group rules.'
  exit 0
fi
[[ $# -eq 0 ]] || die 'Unknown arguments; use --help.'
[[ $EUID -eq 0 ]] || die 'Run this script with sudo.'

# The script targets Ubuntu; do not silently alter another distribution.
# shellcheck disable=SC1091
source /etc/os-release
[[ "$ID" == 'ubuntu' ]] || die 'Ubuntu is required.'

export DEBIAN_FRONTEND=noninteractive
log 'Installing deployment prerequisites.'
apt-get -o DPkg::Lock::Timeout=180 update
apt-get -o DPkg::Lock::Timeout=180 install -y --no-install-recommends \
  ca-certificates curl git openssl python3 util-linux

exec 9>/run/lock/hw-docker-2-deploy.lock
flock -n 9 || die 'Another deployment is already running.'

if ! command -v docker >/dev/null; then
  # Refuse to remove or replace an existing container runtime automatically.
  for package in docker.io podman-docker containerd runc; do
    if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
      die "Existing package $package needs review before installing Docker CE."
    fi
  done
  log 'Installing Docker Engine from the official Ubuntu repository.'
  install -m 0755 -d /etc/apt/keyrings
  curl --fail --silent --show-error --retry 3 \
    https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get -o DPkg::Lock::Timeout=180 update
  apt-get -o DPkg::Lock::Timeout=180 install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

systemctl enable --now docker
docker info >/dev/null
compose_version=$(docker compose version --short) \
  || die 'Docker Compose plugin is missing. Install it before continuing.'
compose_version=${compose_version#v}
dpkg --compare-versions "$compose_version" ge '2.20.0' \
  || die 'Docker Compose 2.20.0 or newer is required for include.'
docker buildx version >/dev/null \
  || die 'Docker Buildx plugin is required.'

# backend is an explicitly named network. Never remove another project's network.
if docker network inspect backend >/dev/null 2>&1; then
  owner=$(docker network inspect backend \
    --format '{{index .Labels "com.docker.compose.project"}}')
  [[ "$owner" == "$PROJECT_NAME" ]] \
    || die "Network backend already exists and is not owned by $PROJECT_NAME."
fi

log "Cloning or updating the fork in $APP_DIR."
if [[ ! -e "$APP_DIR" ]]; then
  install -d -m 0755 /opt
  git clone --branch main --single-branch "$REPO_URL" "$APP_DIR"
else
  [[ -d "$APP_DIR/.git" ]] || die "$APP_DIR exists but is not a Git checkout."
  # .env is intentionally changed locally; do not reset or overwrite it.
  git -C "$APP_DIR" diff --quiet -- . ':!.env' \
    || die 'The checkout contains local changes outside .env.'
  git -C "$APP_DIR" diff --cached --quiet \
    || die 'The checkout contains staged local changes.'
  git -C "$APP_DIR" fetch "$REPO_URL" main
  git -C "$APP_DIR" merge --ff-only FETCH_HEAD
fi

[[ -f "$APP_DIR/.env" ]] || die 'The repository must contain its existing .env file.'
install -d -m 0700 "$STATE_DIR"

if [[ ! -f "$STATE_DIR/env-initialized" ]]; then
  if docker volume inspect "${PROJECT_NAME}_mysql_data" >/dev/null 2>&1; then
    die 'An existing database volume has no initialization marker; refusing to rotate its passwords.'
  fi
  # Parse only the two non-secret identifier values, including quoted .env values.
  read_identifier() {
    python3 - "$APP_DIR/.env" "$1" <<'PY'
import ast
import pathlib
import re
import sys

for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    key, sep, value = line.partition("=")
    if sep and key.strip() == sys.argv[2]:
        value = value.strip()
        if value.startswith(("'", '"')):
            value = ast.literal_eval(value)
        if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_]+", value):
            raise SystemExit("Invalid database or user identifier in .env")
        print(value)
        break
else:
    raise SystemExit("Required database identifier is missing from .env")
PY
  }
  database=$(read_identifier MYSQL_DATABASE)
  app_user=$(read_identifier MYSQL_USER)
  [[ "$app_user" != 'root' ]] || die 'The application user must not be root.'
  root_password=$(openssl rand -hex 24)
  app_password=$(openssl rand -hex 24)
  env_tmp=$(mktemp "$APP_DIR/.env.XXXXXX")
  printf 'MYSQL_ROOT_PASSWORD=%s\nMYSQL_DATABASE=%s\nMYSQL_USER=%s\nMYSQL_PASSWORD=%s\n' \
    "$root_password" "$database" "$app_user" "$app_password" > "$env_tmp"
  chmod 0600 "$env_tmp"
  mv "$env_tmp" "$APP_DIR/.env"
  unset root_password app_password
  touch "$STATE_DIR/env-initialized"
  log 'Fresh local passwords generated in .env; values are not printed.'
else
  log 'Keeping the existing .env and database credentials.'
fi
chmod 0600 "$APP_DIR/.env"

compose config --quiet

# Optional corporate/sandbox CA. It is neither baked into the image nor needed
# on a normal Ubuntu VM with direct TLS access.
if [[ -n "${PIP_CA_FILE:-}" ]]; then
  [[ -r "$PIP_CA_FILE" ]] || die 'PIP_CA_FILE is not readable.'
  docker build \
    --secret "id=pip_ca,src=$PIP_CA_FILE" \
    --file "$APP_DIR/Dockerfile.python" \
    --tag "${PROJECT_NAME}-web" "$APP_DIR"
fi

log 'Building and starting all included Compose services.'
compose up -d --build --wait --wait-timeout 300

log 'Checking the complete local proxy chain on TCP 8090.'
response=$(curl --fail --silent --show-error --retry 5 \
  --retry-connrefused --retry-delay 2 --max-time 15 \
  -L http://127.0.0.1:8090)
printf '%s\n' "$response"
printf '%s' "$response" | python3 -c \
  'import json,sys; r=json.load(sys.stdin); assert isinstance(r,str) and "TIME:" in r and "IP:" in r, "Unexpected application response"'

log 'Checking that the request was recorded in MySQL.'
count=$(compose exec -T db sh -c \
  'MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -u"$MYSQL_USER" -D"$MYSQL_DATABASE" \
  --batch --skip-column-names -e "SELECT COUNT(*) FROM requests;"')
[[ "$count" =~ ^[0-9]+$ && "$count" -ge 1 ]] \
  || die 'The requests table does not contain the test request.'
printf '[deploy] requests rows: %s\n' "$count"
compose ps

log 'Deployment complete. Test the public IP on TCP 8090 from outside the VM.'
log 'Allow inbound TCP 8090 in the cloud security group; do not publish 3306 or 5000.'
log "For later commands: cd $APP_DIR; sudo docker compose -p $PROJECT_NAME ps"
