#!/usr/bin/env bash
# Sets up and manages this Modmail fork on a fresh Debian/Ubuntu server.
#
#   sudo ./setup.sh install [repo-url]   install Docker, fetch the code, configure, start
#   sudo ./setup.sh update               pull the latest code and rebuild
#   sudo ./setup.sh logs                 follow the bot's logs
#   sudo ./setup.sh backup               dump the database to ./backups
#   sudo ./setup.sh restart | stop
#
# install prompts for anything not already set in the environment:
#   TOKEN, GUILD_ID, OWNERS, MODMAIL_GUILD_ID, LOG_URL, ENABLE_LOGVIEWER=yes|no
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/modmail}"
COMPOSE_FILE="docker-compose.selfhost.yml"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "run this with sudo"
}

compose() {
    local profiles=()
    if [ -f "$INSTALL_DIR/.env" ] && grep -q '^ENABLE_LOGVIEWER=yes' "$INSTALL_DIR/.env"; then
        profiles=(--profile logviewer)
    fi
    docker compose --project-directory "$INSTALL_DIR" -f "$INSTALL_DIR/$COMPOSE_FILE" "${profiles[@]}" "$@"
}

install_docker() {
    if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
        info "Docker already installed"
        return
    fi
    info "Installing Docker"
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl git
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
}

fetch_code() {
    local repo_url="${1:-}"
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [ -f "$INSTALL_DIR/$COMPOSE_FILE" ]; then
        info "Code already present in $INSTALL_DIR"
    elif [ -n "$repo_url" ]; then
        command -v git >/dev/null || apt-get install -y -qq git
        info "Cloning $repo_url into $INSTALL_DIR"
        git clone "$repo_url" "$INSTALL_DIR"
    elif [ -f "$here/$COMPOSE_FILE" ]; then
        # Running from a copy of the repo (e.g. uploaded with rsync/scp).
        if [ "$here" != "$INSTALL_DIR" ]; then
            info "Copying $here to $INSTALL_DIR"
            mkdir -p "$INSTALL_DIR"
            cp -a "$here/." "$INSTALL_DIR/"
        fi
    else
        die "pass the git URL of your fork: sudo ./setup.sh install https://github.com/you/modmail.git"
    fi
}

ask() {
    # ask VAR "prompt" [default] -- keeps an existing environment value
    local var="$1" prompt="$2" default="${3:-}" value="${!1:-}"
    while [ -z "$value" ]; do
        if [ -n "$default" ]; then
            read -rp "$prompt [$default]: " value
            value="${value:-$default}"
        else
            read -rp "$prompt: " value
        fi
    done
    printf -v "$var" '%s' "$value"
}

write_env() {
    local env_file="$INSTALL_DIR/.env"
    if [ -f "$env_file" ]; then
        info "Keeping existing $env_file (delete it to reconfigure)"
        return
    fi

    info "Configuring the bot (values come from the Discord developer portal and server)"
    ask TOKEN "Bot token"
    ask GUILD_ID "Main server ID (where users are members)"
    ask MODMAIL_GUILD_ID "Server ID where thread channels are created" "$GUILD_ID"
    ask OWNERS "Owner user IDs, comma separated"
    ask ENABLE_LOGVIEWER "Run the web log viewer? (yes/no)" "no"
    if [ "$ENABLE_LOGVIEWER" = "yes" ]; then
        ask LOG_URL "Public URL the log viewer will be served at" "http://localhost:8000"
    else
        LOG_URL="${LOG_URL:-https://example.com/}"
    fi

    umask 077
    cat >"$env_file" <<EOF
TOKEN=$TOKEN
GUILD_ID=$GUILD_ID
MODMAIL_GUILD_ID=$MODMAIL_GUILD_ID
OWNERS=$OWNERS
LOG_URL=$LOG_URL
ENABLE_LOGVIEWER=$ENABLE_LOGVIEWER
DISABLE_AUTOUPDATES=true

# Fork features
USE_PERSISTENT_CHANNEL_NAME=yes
PERSISTENT_CHANNEL_NAME_PREFIX=ticket
PERSISTENT_CHANNEL_NAME_LENGTH=6
THREAD_HISTORY_RECAP=10
EOF
    info "Wrote $env_file"
}

cmd_install() {
    require_root
    install_docker
    fetch_code "${1:-}"
    write_env
    info "Building and starting"
    compose up -d --build
    compose ps
    cat <<EOF

Modmail is starting. Next steps:
  1. Watch it come up:   sudo $INSTALL_DIR/setup.sh logs
  2. In your server run: ?setup   (creates the Modmail category and log channel)
  3. DM the bot to open a test thread.
EOF
}

cmd_update() {
    require_root
    if [ -d "$INSTALL_DIR/.git" ]; then
        info "Pulling latest code"
        git -C "$INSTALL_DIR" pull --ff-only
    fi
    compose up -d --build
    docker image prune -f >/dev/null
}

cmd_backup() {
    require_root
    mkdir -p "$INSTALL_DIR/backups"
    local out="$INSTALL_DIR/backups/modmail-$(date +%Y%m%d-%H%M%S).archive.gz"
    compose exec -T mongo mongodump --archive --gzip --db modmail_bot >"$out"
    info "Saved $out"
}

case "${1:-}" in
    install) shift; cmd_install "$@" ;;
    update) cmd_update ;;
    logs) compose logs -f --tail=100 bot ;;
    backup) cmd_backup ;;
    restart) require_root; compose restart ;;
    stop) require_root; compose down ;;
    *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
