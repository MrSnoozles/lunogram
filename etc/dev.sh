#!/usr/bin/env bash
#
# Runs the Lunogram development stack with live reloading.
#
#   ./etc/dev.sh            # backing services + API + console
#   ./etc/dev.sh api        # only the Go API   (air, rebuilds on .go changes)
#   ./etc/dev.sh console    # only the console  (vite, hot module replacement)
#
# Backing services (Postgres, Redis, NATS, renderer) run in Docker via
# docker-compose.dev.yml and are left running when this script exits so the
# next start is fast — stop them with `make dev-down`.
#
# Environment for the API is read from the repository's .env file, which the
# Go binary does not load by itself. Copy .env.example to .env to get started.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

AIR="${AIR:-$ROOT/bin/air}"
PNPM="${PNPM:-pnpm}"
COMPOSE_FILE="$ROOT/docker-compose.dev.yml"

RESET=$'\033[0m'
BLUE=$'\033[34;1m'
CYAN=$'\033[36m'
MAGENTA=$'\033[35m'
YELLOW=$'\033[33m'

log() { printf '%s▶%s %s\n' "$BLUE" "$RESET" "$*"; }
die() { printf '%serror:%s %s\n' $'\033[31;1m' "$RESET" "$*" >&2; exit 1; }

# Prefix a child process's output so interleaved logs stay readable.
prefix() {
    local label="$1" color="$2"
    awk -v p="${color}[${label}]${RESET} " '{ print p $0; fflush() }'
}

load_env() {
    if [[ -f "$ROOT/.env" ]]; then
        log "loading environment from .env"
        set -a
        # shellcheck disable=SC1091
        source "$ROOT/.env"
        set +a
    else
        printf '%swarning:%s no .env found — the API will fall back to its Docker defaults.\n' \
            "$YELLOW" "$RESET" >&2
        printf '         run: cp .env.example .env\n' >&2
    fi
}

start_services() {
    command -v docker >/dev/null 2>&1 || die "docker is required but not installed"
    log "starting backing services (postgres, redis, nats, renderer)…"
    docker compose -f "$COMPOSE_FILE" up -d --wait
}

run_api() {
    [[ -x "$AIR" ]] || die "air not found at $AIR — run 'make dev-api' once to install it"
    "$AIR" -c "$ROOT/.air.toml"
}

run_console() {
    command -v "$PNPM" >/dev/null 2>&1 || die "pnpm is required but not installed"
    [[ -d "$ROOT/console/node_modules" ]] || {
        log "installing console dependencies…"
        (cd "$ROOT/console" && "$PNPM" install)
    }
    [[ -f "$ROOT/console/.env" ]] || {
        log "creating console/.env from console/.env.example"
        cp "$ROOT/console/.env.example" "$ROOT/console/.env"
    }
    (cd "$ROOT/console" && "$PNPM" dev)
}

pids=()

cleanup() {
    trap - INT TERM EXIT
    printf '\n'
    log "stopping api and console (docker services keep running — 'make dev-down' to stop them)"
    for pid in "${pids[@]:-}"; do
        [[ -n "$pid" ]] && kill -TERM "-$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
}

main() {
    local target="${1:-all}"

    case "$target" in
        api)
            load_env
            run_api
            ;;
        console)
            run_console
            ;;
        all)
            load_env
            start_services

            # Job control gives each background job its own process group so
            # cleanup can signal the whole tree (air spawns the built binary).
            set -m
            trap cleanup INT TERM EXIT

            log "starting api on http://localhost:8080 (live reload)"
            { run_api 2>&1 | prefix api "$CYAN"; } &
            pids+=("$!")

            log "starting console on http://localhost:5173 (hot reload)"
            { run_console 2>&1 | prefix console "$MAGENTA"; } &
            pids+=("$!")

            log "open http://localhost:5173 — press Ctrl-C to stop"
            wait
            ;;
        *)
            die "unknown target '$target' (expected: api, console, or nothing)"
            ;;
    esac
}

main "$@"
