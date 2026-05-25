#!/usr/bin/env bash
# =============================================================================
# EISA HOMELAB ULTIMATE - Unified manager (macOS)
# Mirror of WINDOWS-HOMELAB-MANAGER.BAT. Menu-driven, single entry point:
#   [1] First-Run Setup    (wizard - once on a fresh clone)
#   [2] Start Stack        (day-to-day; brings the chosen profiles up)
#   [3] Stop Stack         (compose down + by-name fallback)
#   [4] LLM Manager        (pull / launch / delete Ollama models)
# =============================================================================
set -u
cd "$(dirname "$0")"

BASE="$(pwd)"
COMPOSE_DIR="${BASE}/files"
SETUP_PS1="${COMPOSE_DIR}/scripts/setup.ps1"
ENV_FILE="${COMPOSE_DIR}/.env"
STATE_FILE="${COMPOSE_DIR}/.wizard-state.json"
CONTAINER="ollama"
API="http://127.0.0.1:11434"
CFG="${COMPOSE_DIR}/context_size.cfg"
RECFILE="${COMPOSE_DIR}/recommended_models.txt"

# Green/dim/red ANSI styling so the look matches the Windows bat.
GREEN=$'\033[1;32m'
DIM=$'\033[0;32m'
RED=$'\033[1;31m'
RESET=$'\033[0m'

CTX=""

say() { printf '%s%s%s\n' "${GREEN}" "$1" "${RESET}"; }
dim() { printf '%s%s%s\n' "${DIM}"   "$1" "${RESET}"; }
err() { printf '%s%s%s\n' "${RED}"   "$1" "${RESET}"; }

header() {
    echo
    say "  +===================================================+"
    say "   $1"
    say "  +===================================================+"
    echo
}

pause_close() {
    if [ -t 0 ] && [ -z "${SSH_CONNECTION:-}" ]; then
        read -r -p "  Press return to close this window..." _ || true
    fi
}

pause_return() {
    read -r -p "  Press return to return to the main menu..." _ || true
}

# ============================================================================
# Wizard-state inspection. The first-run wizard persists the user's choices
# (including GPU mode) in files/.wizard-state.json. Mac users who picked
# "NATIVE Ollama on macOS" during the wizard's Step 3b end up with
# gpuMode = "native" in here; everything else (cpu / nvidia / amd) means
# the containerised ollama path.
# ============================================================================
get_gpu_mode() {
    [ -f "${STATE_FILE}" ] || { printf ''; return 0; }
    # Minimal JSON parse: pick the value of the "gpuMode" key. No jq dep.
    grep -oE '"gpuMode"[[:space:]]*:[[:space:]]*"[^"]*"' "${STATE_FILE}" 2>/dev/null \
        | head -n1 \
        | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/'
}
is_native_mode() { [ "$(get_gpu_mode)" = "native" ]; }

api_ready() { curl -sf --max-time 2 "${API}/api/tags" >/dev/null 2>&1; }

# ============================================================================
# Native (host-installed) ollama lifecycle. Used when gpuMode == "native".
# Prefers Homebrew (clean CLI + launchd integration via `brew services`);
# falls back to downloading the official Ollama-darwin.zip from GitHub
# Releases for machines without brew. Either way, ends with the API
# responding on ${API} or returns non-zero.
# ============================================================================
ensure_native_ollama() {
    # Already installed - just make sure it's running.
    if command -v ollama >/dev/null 2>&1; then
        api_ready && return 0
        echo "  Native ollama is installed but the API at ${API} is silent."
        echo "  Starting it..."
        if command -v brew >/dev/null 2>&1; then
            brew services start ollama >/dev/null 2>&1 || true
        fi
        if ! api_ready; then
            # Fallback: launch `ollama serve` detached. nohup so it survives
            # this shell exiting.
            (nohup ollama serve >/tmp/eisa-ollama-serve.log 2>&1 &)
        fi
        local i
        for i in $(seq 1 30); do
            sleep 1
            api_ready && return 0
        done
        err "  Native ollama did not respond within 30s."
        echo "      Recent log:   tail -n 50 /tmp/eisa-ollama-serve.log"
        echo "      Manual start: ollama serve"
        pause_return
        return 1
    fi

    # Not installed - install it.
    clear
    header "INSTALLING NATIVE OLLAMA"
    echo "  You picked NATIVE Ollama (Metal-accelerated) during first-run,"
    echo "  but the 'ollama' CLI is not on this Mac yet. Installing now."
    echo

    if command -v brew >/dev/null 2>&1; then
        echo "  Homebrew detected - using 'brew install ollama' (recommended)."
        echo
        if ! brew install ollama; then
            err "  brew install ollama failed."
            echo "      See the output above for details."
            pause_return
            return 1
        fi
        echo
        echo "  Starting ollama as a background launchd service..."
        brew services start ollama >/dev/null 2>&1 || true
    else
        echo "  Homebrew not found. Downloading the official Ollama Mac app from:"
        echo "    https://github.com/ollama/ollama/releases/latest"
        echo
        local tmpdir zip_path
        tmpdir="$(mktemp -d)"
        zip_path="${tmpdir}/Ollama-darwin.zip"
        if ! curl -fL --progress-bar \
                -o "${zip_path}" \
                "https://github.com/ollama/ollama/releases/latest/download/Ollama-darwin.zip"; then
            err "  Download failed."
            rm -rf "${tmpdir}"
            pause_return
            return 1
        fi
        echo
        echo "  Extracting Ollama.app to /Applications ..."
        # ditto preserves macOS metadata (codesign, quarantine) better than unzip.
        if ! ditto -xk "${zip_path}" /Applications/; then
            err "  Extracting to /Applications failed."
            rm -rf "${tmpdir}"
            pause_return
            return 1
        fi
        rm -rf "${tmpdir}"
        echo "  Launching Ollama.app (first launch installs the 'ollama' CLI"
        echo "  into /usr/local/bin and starts the background server)..."
        open -a Ollama 2>/dev/null || open /Applications/Ollama.app 2>/dev/null || true
        echo "  If the app shows a 'Move to Applications' or 'Install Command'"
        echo "  prompt, click through it now."
    fi

    # Wait for the API to come up.
    echo
    echo "  Waiting for the native ollama API at ${API} ..."
    local i
    for i in $(seq 1 60); do
        sleep 1
        # Refresh PATH cache so a freshly-installed brew/CLI is visible.
        hash -r 2>/dev/null || true
        if api_ready; then
            say "  [OK] Native ollama is up."
            return 0
        fi
    done
    err "  Ollama is installed but the API didn't respond within 60s."
    echo "      If you used the .app installer, look for a one-time CLI-install"
    echo "      prompt in the Ollama app window and accept it, then re-run."
    pause_return
    return 1
}

# Resolve PERSISTENT_STORAGE from .env (or fall back to the wizard default)
# and return an absolute path. Used by the optional "reset databases" step
# in Stop Stack to know where the bind-mounted postgres data lives.
resolve_persistent_storage() {
    local ps=""
    if [ -f "${ENV_FILE}" ]; then
        ps="$(grep -E '^PERSISTENT_STORAGE=' "${ENV_FILE}" | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
    fi
    [ -z "${ps}" ] && ps="./persistent-storage"
    case "${ps}" in
        /*) printf '%s\n' "${ps}" ;;
        *)  printf '%s/%s\n' "${COMPOSE_DIR}" "${ps#./}" ;;
    esac
}

# Wipe ONLY the two postgres bind-mount data dirs so the next start does a
# clean initdb. This is the recovery path for the half-initialised-postgres
# trap (PG_VERSION present so postgres refuses to re-init, but global/
# pg_filenode.map missing so it can't start either).
#
# Caller must already have called the regular Stop Stack so no postgres
# container is holding the directory open.
#
# Strictly opt-in: requires a typed "yes" confirmation, and only touches
# the two named subdirectories - media folders, ollama models, open-webui
# chat history, qdrant vectors, .env, wizard state are ALL preserved.
deep_clean_postgres() {
    local base n8n_dir immich_dir
    base="$(resolve_persistent_storage)"
    n8n_dir="${base}/n8n/postgres_storage"
    immich_dir="${base}/immich/postgres"

    echo
    err  "  ============================================================"
    err  "   RESET DATABASES - DESTRUCTIVE"
    err  "  ============================================================"
    echo
    echo "  This will permanently delete:"
    echo "    ${n8n_dir}"
    echo "    ${immich_dir}"
    echo
    echo "  Effect:"
    echo "    - n8n: every workflow run, credential, and saved workflow is gone."
    echo "    - immich: account + photo INDEX gone. The actual image files in"
    echo "      your photos folder are NOT touched; immich will rebuild the"
    echo "      index from them on next start, which takes a while."
    echo
    echo "  NOT touched:"
    echo "    - your media folders (movies / music / photos)"
    echo "    - ollama models / open-webui chats / qdrant vectors"
    echo "    - your .env file or wizard state"
    echo
    echo "  Type 'yes' (lowercase, no quotes) to confirm. Anything else cancels."
    echo
    local confirm
    read -r -p "  Confirm: " confirm
    if [ "${confirm}" != "yes" ]; then
        dim "  Cancelled - nothing deleted."
        return 0
    fi
    echo
    if [ -d "${n8n_dir}" ]; then
        rm -rf "${n8n_dir}" && say "  Removed ${n8n_dir}"
    else
        dim "  Skipped ${n8n_dir} (did not exist)"
    fi
    if [ -d "${immich_dir}" ]; then
        rm -rf "${immich_dir}" && say "  Removed ${immich_dir}"
    else
        dim "  Skipped ${immich_dir} (did not exist)"
    fi
    echo
    say "  Databases reset. The next [2] Start Stack will initdb cleanly."
}

# Dispatcher: ensure the right ollama (native vs container) is up and ready.
ollama_ensure() {
    if is_native_mode; then
        ensure_native_ollama
    else
        ollama_ensure_container
    fi
}

# Run an ollama CLI command in the mode-appropriate way. Non-interactive
# variant for `ollama list / rm / --version`.
ollama_cli() {
    if is_native_mode; then
        ollama "$@"
    else
        ollama_cli "$@"
    fi
}
# Interactive variant for `ollama run / pull` so the user sees TTY output.
ollama_cli_it() {
    if is_native_mode; then
        ollama "$@"
    else
        ollama_cli_it "$@"
    fi
}

# ============================================================================
# Preflight: pwsh required (for setup.ps1). Try Homebrew, then fall back to
# the official PowerShell .pkg installer from GitHub Releases.
# ============================================================================
ensure_pwsh() {
    if command -v pwsh >/dev/null 2>&1; then return 0; fi
    err "  PowerShell 7 (pwsh) is required by setup.ps1."
    echo

    if command -v brew >/dev/null 2>&1; then
        echo "  Installing it via Homebrew (one-time)..."
        if brew install --cask powershell; then
            hash -r 2>/dev/null || true
            command -v pwsh >/dev/null 2>&1 && return 0
        fi
        err "  Homebrew install failed; trying the official .pkg installer..."
        echo
    else
        echo "  Homebrew is not installed - falling back to the official .pkg installer."
        echo
    fi

    local arch pkg_arch
    arch="$(uname -m)"
    case "${arch}" in
        arm64)  pkg_arch="osx-arm64" ;;
        x86_64) pkg_arch="osx-x64"   ;;
        *)
            err "  Unsupported architecture: ${arch}"
            echo "  Install PowerShell manually from:"
            echo "    https://github.com/PowerShell/PowerShell/releases"
            return 1
            ;;
    esac

    echo "  Detecting the latest stable PowerShell release..."
    local pkg_url
    pkg_url="$(curl -fsSL https://api.github.com/repos/PowerShell/PowerShell/releases/latest 2>/dev/null \
        | grep -oE "\"browser_download_url\": *\"[^\"]+${pkg_arch}\\.pkg\"" \
        | head -n1 \
        | sed -E 's/^"browser_download_url": *"//; s/"$//')"
    if [ -z "${pkg_url}" ]; then
        err "  Could not determine the latest PowerShell .pkg URL."
        echo "  Install PowerShell manually from:"
        echo "    https://github.com/PowerShell/PowerShell/releases"
        return 1
    fi

    local tmpdir pkg_path
    tmpdir="$(mktemp -d)"
    pkg_path="${tmpdir}/powershell.pkg"
    echo "  Downloading: ${pkg_url}"
    if ! curl -fL --progress-bar -o "${pkg_path}" "${pkg_url}"; then
        err "  Download failed."
        rm -rf "${tmpdir}"
        return 1
    fi

    echo
    echo "  Installing PowerShell - you will be prompted for your macOS password."
    if ! sudo installer -pkg "${pkg_path}" -target /; then
        err "  Installer failed."
        rm -rf "${tmpdir}"
        return 1
    fi
    rm -rf "${tmpdir}"

    hash -r 2>/dev/null || true
    if command -v pwsh >/dev/null 2>&1; then
        say "  [OK] PowerShell installed."
        return 0
    fi
    err "  PowerShell installer reported success but pwsh is still not on PATH."
    echo "  Open a new Terminal window and re-run the manager."
    return 1
}

# ============================================================================
# TOP-LEVEL MENU
# ============================================================================
main_menu() {
    while true; do
        clear
        echo
        say "  ============================================================"
        say "   EISA HOMELAB ULTIMATE - Manager"
        say "  ============================================================"
        echo
        echo "   The ULTIMATE private, no-tracking homelab stack."
        echo "   100% local-first  |  zero telemetry  |  your data, your machine"
        echo
        dim "  ------------------------------------------------------------"
        echo
        say "   [1] First-Run Setup       (wizard - run me once on a fresh clone)"
        say "   [2] Start Stack           (day-to-day, brings everything up)"
        say "   [3] Stop Stack            (compose down + cleanup)"
        say "   [4] List Stack            (show running containers + health)"
        say "   [5] LLM Manager           (pull, launch, delete Ollama models)"
        say "   [6] Edit Media Folders    (movies / tv / music / downloads / photos)"
        say "   [7] Backup / Restore      (save or load images + volumes + state)"
        echo
        say "   [0] Exit"
        echo
        local choice
        read -r -p "  Select option: " choice
        case "${choice}" in
            1) do_first_run ;;
            2) do_start ;;
            3) do_stop ;;
            4) do_list ;;
            5) ollama_boot ;;
            6) do_edit_media ;;
            7) do_backup_menu ;;
            0) return 0 ;;
        esac
    done
}

# ============================================================================
# [1] FIRST-RUN WIZARD
# ============================================================================
do_first_run() {
    clear
    header "First-run wizard"
    if ! ensure_pwsh; then pause_return; return; fi
    if [ ! -f "${SETUP_PS1}" ]; then
        err "  [X] Could not find setup.ps1 at:"
        echo "      ${SETUP_PS1}"
        echo "      Re-clone or restore files/scripts/."
        pause_return
        return
    fi
    echo "  Wizard: ${SETUP_PS1}"
    echo
    echo "  ----------------------------------------------------------------"
    pwsh -NoProfile -File "${SETUP_PS1}"
    local rc=$?
    echo "  ----------------------------------------------------------------"
    echo
    if [ "${rc}" = "0" ]; then
        say "  [OK] Wizard completed."
    else
        err "  [!]  Wizard exited with code ${rc}."
    fi
    echo
    pause_return
}

# ============================================================================
# [6] EDIT MEDIA FOLDERS
# ============================================================================
do_edit_media() {
    clear
    header "Edit Media Folders"
    if ! ensure_pwsh; then pause_return; return; fi
    if [ ! -f "${SETUP_PS1}" ]; then
        err "  [X] setup.ps1 not found at ${SETUP_PS1}"
        pause_return
        return
    fi
    echo "  Shows current paths + status, lets you change any of them, validates"
    echo "  each one on disk, offers to create missing folders, and (optionally)"
    echo "  recreates the affected containers so the new mounts take effect."
    echo "  ----------------------------------------------------------------"
    pwsh -NoProfile -File "${SETUP_PS1}" -EditMediaPaths
    echo "  ----------------------------------------------------------------"
    echo
    pause_return
}

# ============================================================================
# [7] BACKUP / RESTORE submenu
# ============================================================================
do_backup_menu() {
    while true; do
        clear
        header "Backup / Restore"
        say "   Backup:"
        say "   [1] Backup everything           (identical clone - restore skips the wizard)"
        say "   [2] Backup images + volumes     (no .env - wizard runs fresh on restore)"
        say "   [3] Backup images only          (offline image cache - wizard runs)"
        say "   [4] Backup volumes only         (user data only, no images - wizard runs)"
        echo
        say "   Restore:"
        say "   [5] Restore from a backup folder"
        echo
        say "   [0] Back"
        echo
        local choice
        read -r -p "  Select option: " choice
        case "${choice}" in
            1) do_backup full           ;;
            2) do_backup images-volumes ;;
            3) do_backup images         ;;
            4) do_backup volumes        ;;
            5) do_restore               ;;
            0) return                   ;;
        esac
    done
}

do_backup() {
    local mode="${1:-full}"
    clear
    header "Backup  (mode: ${mode})"
    if ! ensure_pwsh; then pause_return; return; fi
    if [ ! -f "${SETUP_PS1}" ]; then
        err "  [X] setup.ps1 not found at ${SETUP_PS1}"
        pause_return
        return
    fi
    case "${mode}" in
        full)
            echo "  Dumps every Docker image + named volume + persistent-storage"
            echo "  + .env + state into a portable folder. Restoring on a"
            echo "  different PC/Mac brings the stack up identically with the"
            echo "  same configs and secrets - first-run wizard is skipped."
            echo "  Will offer to stop the stack first for a clean snapshot."
            ;;
        images-volumes)
            echo "  Saves images + named volumes + persistent-storage, but NOT"
            echo "  .env / state. Recipient runs the first-run wizard fresh;"
            echo "  secrets are regenerated, paths are re-asked. Pull phase"
            echo "  is instant because every image is already cached."
            echo "  Will offer to stop the stack first for a clean snapshot."
            ;;
        images)
            echo "  Saves docker images only (no user data, no .env). Useful"
            echo "  as an offline image cache; stack can stay running."
            echo "  Restore runs the wizard normally; pull phase is instant."
            ;;
        volumes)
            echo "  Saves named volumes + persistent-storage, no images, no"
            echo "  .env. Restore runs the wizard normally and compose"
            echo "  re-pulls every image from its registry (the slow part)."
            echo "  Will offer to stop the stack first for a clean snapshot."
            ;;
    esac
    echo "  ----------------------------------------------------------------"
    pwsh -NoProfile -File "${SETUP_PS1}" -Backup -BackupMode "${mode}"
    echo "  ----------------------------------------------------------------"
    echo
    pause_return
}

do_restore() {
    clear
    header "Restore"
    if ! ensure_pwsh; then pause_return; return; fi
    if [ ! -f "${SETUP_PS1}" ]; then
        err "  [X] setup.ps1 not found at ${SETUP_PS1}"
        pause_return
        return
    fi
    local rpath
    read -r -p "  Path to backup folder (or leave blank to be prompted): " rpath
    echo
    echo "  Loads images, named volumes, persistent-storage, and .env from"
    echo "  the backup folder, then brings the stack up. Will stop anything"
    echo "  currently running first."
    echo "  ----------------------------------------------------------------"
    if [ -n "${rpath}" ]; then
        pwsh -NoProfile -File "${SETUP_PS1}" -Restore -RestorePath "${rpath}"
    else
        pwsh -NoProfile -File "${SETUP_PS1}" -Restore
    fi
    echo "  ----------------------------------------------------------------"
    echo
    pause_return
}

# ============================================================================
# [2] START STACK
# ============================================================================
do_start() {
    clear
    header "Starting"
    if ! ensure_pwsh; then pause_return; return; fi
    if [ ! -f "${SETUP_PS1}" ]; then
        err "  [X] setup.ps1 not found at ${SETUP_PS1}"
        pause_return
        return
    fi
    echo "  Wizard in -StartOnly mode (self-healing): renders configs, fixes"
    echo "  bind-mount dirs, sets up the Authelia admin user, runs compose up."
    echo "  ----------------------------------------------------------------"
    pwsh -NoProfile -File "${SETUP_PS1}" -StartOnly
    local rc=$?
    echo "  ----------------------------------------------------------------"
    echo
    if [ "${rc}" = "0" ]; then
        say "  [OK] Stack started."
    else
        err "  [!]  Wizard exited with code ${rc}."
        echo  "       Common cause: containers from an older install are blocking"
        echo  "       these container_names. Pick [3] Stop Stack first, then retry."
    fi
    echo
    pause_return
}

# ============================================================================
# [3] STOP STACK
# ============================================================================
do_stop() {
    clear
    header "Stopping"

    if [ ! -d "${COMPOSE_DIR}" ]; then
        err "  [X] Could not find ${COMPOSE_DIR}"
        pause_return
        return
    fi

    echo "  [1/3] docker compose down --remove-orphans -t 10  (project: eisa-homelab)"
    echo "        Containers get 10s to stop gracefully, then SIGKILL. If a half-"
    echo "        broken container from a failed startup is stuck shutting down,"
    echo "        this prevents the whole stop from hanging indefinitely."
    echo "        ----------------------------------------------------------------"
    (
        cd "${COMPOSE_DIR}"
        COMPOSE_PROFILES=ai,media,media-stream,media-request,productivity,tunnel docker compose down --remove-orphans -t 10
    )
    echo "        ----------------------------------------------------------------"
    echo

    local -a EISA=(
        cloudflared heimdall-media Caddy Authelia navidrome jellyfin
        filebrowser omni-tools n8n qdrant ollama open-webui searxng
        local-deep-research vane hermes-agent
        Portainer tor-browser
        immich-server immich-machine-learning immich-redis immich-postgres
        seerr sonarr radarr prowlarr qbittorrent
    )

    echo "  [2/3] Stopping any leftover containers by name..."
    for name in "${EISA[@]}"; do
        if docker inspect -f '{{.State.Running}}' "${name}" >/dev/null 2>&1; then
            docker stop "${name}" >/dev/null 2>&1 && echo "         stopped  ${name}"
            docker rm   "${name}" >/dev/null 2>&1 && echo "         removed  ${name}"
        elif docker inspect -f '{{.Id}}' "${name}" >/dev/null 2>&1; then
            docker rm "${name}" >/dev/null 2>&1 && echo "         removed  ${name}  (was stopped)"
        fi
    done
    while IFS= read -r cid; do
        [ -z "${cid}" ] && continue
        docker rm -f "${cid}" >/dev/null 2>&1 && echo "         removed  ${cid}  (n8n-postgres match)"
    done < <(docker ps -aq --filter "name=n8n-postgres" 2>/dev/null)
    echo

    echo "  [3/3] Removing the 'caddy' docker network if it's empty..."
    docker network rm caddy >/dev/null 2>&1 && echo "         removed network 'caddy'"
    echo

    say "  [OK] Stop complete."
    echo
    echo "  Note: bind-mounted media + files/persistent-storage are NOT touched."
    echo "        Named docker volumes are NOT touched."
    if is_native_mode; then
        echo "        Native ollama on the host is NOT touched - it keeps running"
        echo "        as a launchd service. Manage it via the LLM Manager menu."
    fi
    echo

    # Offer the postgres reset only when it's likely to help: i.e. an
    # interrupted previous start left the bind-mount in a half-initdb
    # state (PG_VERSION present but global/pg_filenode.map missing).
    # Skip the prompt entirely otherwise so day-to-day stops are quiet.
    local base n8n_dir immich_dir need_reset=0
    base="$(resolve_persistent_storage)"
    n8n_dir="${base}/n8n/postgres_storage"
    immich_dir="${base}/immich/postgres"
    for d in "${n8n_dir}" "${immich_dir}"; do
        if [ -f "${d}/PG_VERSION" ] && [ ! -f "${d}/global/pg_filenode.map" ]; then
            need_reset=1
            break
        fi
    done

    if [ "${need_reset}" -eq 1 ]; then
        echo "  ----------------------------------------------------------------"
        err  "  Detected a half-initialised postgres data directory."
        echo "  This is what blocks the stack from starting with 'pg_filenode.map'"
        echo "  fatal errors. The fix is to wipe and let postgres initdb fresh."
        echo
        local reset
        read -r -p "  Reset the postgres databases now? [y/N]: " reset
        case "${reset}" in
            y|Y|yes|YES) deep_clean_postgres ;;
            *) dim "  Skipped. You can re-run Stop Stack any time to be offered again." ;;
        esac
        echo
    fi
    pause_return
}

# ============================================================================
# [4] LIST STACK
# ============================================================================
do_list() {
    clear
    header "Stack status"

    if ! command -v docker >/dev/null 2>&1; then
        err "  [X] docker CLI not found in PATH."
        echo "      Install Docker Desktop and re-run."
        pause_return
        return
    fi
    if ! docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
        err "  [X] Docker engine is not running."
        echo "      Start Docker Desktop and re-run."
        pause_return
        return
    fi

    local -a EISA=(
        cloudflared heimdall-media Caddy Authelia navidrome jellyfin
        filebrowser omni-tools n8n qdrant ollama open-webui searxng
        local-deep-research vane hermes-agent
        Portainer tor-browser
        immich-server immich-machine-learning immich-redis immich-postgres
        seerr sonarr radarr prowlarr qbittorrent
    )

    printf '  %-28s  %-10s  %-11s  %s\n' "CONTAINER" "STATE" "HEALTH" "STATUS"
    dim    "  ----------------------------  ----------  -----------  -----------------------------------"

    local found=0 running=0 healthy=0 unhealthy=0
    local name state health status row
    for name in "${EISA[@]}"; do
        state="$(docker inspect -f '{{.State.Status}}' "${name}" 2>/dev/null || true)"
        [ -z "${state}" ] && continue
        found=$((found + 1))
        health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "${name}" 2>/dev/null || true)"
        [ -z "${health}" ] && health="n/a"
        status="$(docker ps -a --filter "name=^${name}$" --format '{{.Status}}' 2>/dev/null || true)"
        [ -z "${status}" ] && status="-"

        [ "${state}" = "running" ]    && running=$((running + 1))
        [ "${health}" = "healthy" ]   && healthy=$((healthy + 1))
        [ "${health}" = "unhealthy" ] && unhealthy=$((unhealthy + 1))

        row="$(printf '  %-28s  %-10s  %-11s  %s' "${name}" "${state}" "${health}" "${status}")"
        if [ "${state}" != "running" ] || [ "${health}" = "unhealthy" ]; then
            err "${row}"
        elif [ "${health}" = "healthy" ] || [ "${health}" = "n/a" ]; then
            say "${row}"
        else
            # starting, restarting, etc.
            dim "${row}"
        fi
    done

    echo
    if [ "${found}" -eq 0 ]; then
        dim "  No EISA containers found - the stack does not appear to be deployed."
        echo
        echo "  Use option [2] Start Stack to bring it up."
    else
        say "  Summary: ${found} tracked, ${running} running, ${healthy} healthy, ${unhealthy} unhealthy"
    fi

    # In native mode ollama doesn't run as a docker container, so it never
    # shows up in the table above. Surface its status separately so the
    # user can tell at a glance whether the LLM backend is alive.
    if is_native_mode; then
        echo
        dim "  Native ollama (host-installed, not a docker container):"
        local nver
        if command -v ollama >/dev/null 2>&1; then
            nver="$(ollama --version 2>/dev/null | head -n1)"
            [ -z "${nver}" ] && nver="installed"
            if api_ready; then
                say  "    ollama (native)              ${nver}    API responding at ${API}"
            else
                err  "    ollama (native)              ${nver}    API NOT responding at ${API}"
                echo "    -> open [5] LLM Manager to start it, or run: ollama serve"
            fi
        else
            err  "    ollama (native)              NOT INSTALLED"
            echo "    -> open [5] LLM Manager - it will install via Homebrew or download"
            echo "       the official Ollama Mac app from GitHub Releases."
        fi
    fi

    echo
    pause_return
}

# ============================================================================
# [5] OLLAMA / LLM MANAGER
# ============================================================================
ollama_boot() {
    # Docker is only required for the containerised path. Native ollama
    # lives on the host, so we skip these checks when gpuMode == "native".
    if ! is_native_mode; then
        if ! command -v docker >/dev/null 2>&1; then
            clear
            header "ERROR"
            err "  docker CLI not found in PATH."
            echo "  Install Docker Desktop and re-run."
            pause_return
            return
        fi
        if ! docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
            clear
            header "ERROR"
            err "  Docker engine is not running."
            echo "  Start Docker Desktop and re-run."
            pause_return
            return
        fi
    fi

    [ -f "${CFG}" ] || echo 8192 > "${CFG}"
    CTX="$(cat "${CFG}" 2>/dev/null || true)"
    [[ "${CTX}" =~ ^[1-9][0-9]*$ ]] || CTX=8192

    if [ ! -f "${RECFILE}" ]; then
        cat > "${RECFILE}" <<'EOF'
LOW|huihui_ai/gemma-4-abliterated:e4b-q4_K
LOW|huihui_ai/gemma-4-abliterated:e4b-q8_0
HIGH|carstenuhlig/omnicoder-2-9b:q4_k_m
EOF
    fi

    if ! ollama_ensure; then return; fi
    ollama_menu
}

ollama_ensure_container() {
    local running i
    running="$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null || true)"
    if [ "${running}" = "true" ]; then
        for i in $(seq 1 15); do
            api_ready && return 0
            sleep 1
        done
    fi
    clear
    header "STARTING OLLAMA CONTAINER"
    echo "  Container  : ${CONTAINER}"
    echo "  Compose dir: ${COMPOSE_DIR}"
    echo
    ( cd "${COMPOSE_DIR}" && COMPOSE_PROFILES=ai docker compose up -d "${CONTAINER}" )
    for i in $(seq 1 60); do
        sleep 1
        if api_ready; then
            say "  Ollama API is responding."
            ollama_unload_vram
            echo
            return 0
        fi
    done
    err "  [!] Ollama container did not become ready within 60s."
    echo "      Check: docker logs ${CONTAINER}"
    pause_return
    return 1
}

ollama_unload_vram() {
    local body names name
    body="$(curl -sf --max-time 3 "${API}/api/ps" 2>/dev/null || true)"
    names="$(printf '%s' "${body}" | tr ',' '\n' | grep -oE '"name":"[^"]+"' | sed 's/^"name":"//; s/"$//')"
    if [ -n "${names}" ]; then
        while IFS= read -r name; do
            [ -z "${name}" ] && continue
            echo "  Unloading: ${name}"
            curl -sf -X POST -H 'Content-Type: application/json' \
                -d "{\"model\":\"${name}\",\"keep_alive\":0}" \
                "${API}/api/generate" >/dev/null 2>&1 || true
        done <<< "${names}"
        say "  VRAM freed."
        sleep 2
    else
        echo "  No models loaded in VRAM."
    fi
}

ollama_list_installed() {
    ollama_cli list 2>/dev/null | tail -n +2 | awk '
        NF >= 3 {
            name=$1
            if ($3 ~ /^[0-9.]+$/ && $4 ~ /^[KMGT]?B$/) { size=$3" "$4 } else { size=$3 }
            print name"|"size
        }
    '
}

ollama_is_installed() {
    ollama_cli list 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -qx "$1"
}

ollama_total_size_gb() {
    local body bytes
    body="$(curl -sf --max-time 3 "${API}/api/tags" 2>/dev/null || true)"
    bytes="$(printf '%s' "${body}" | grep -oE '"size":[0-9]+' | awk -F: '{ s += $2 } END { print s+0 }')"
    awk -v b="${bytes:-0}" 'BEGIN { printf "%.2f", b/1073741824 }'
}

ollama_menu() {
    while true; do
        clear
        if is_native_mode; then
            header "OLLAMA MANAGER (native - Apple Metal)"
        else
            header "OLLAMA MANAGER (docker)"
        fi
        local ver size
        ver="$(ollama_cli --version 2>/dev/null | head -n1 || true)"
        [ -z "${ver}" ] && ver="unknown"
        size="$(ollama_total_size_gb)"
        if is_native_mode; then
            echo "  Mode     : NATIVE (host-installed, Metal accelerated)"
        else
            echo "  Container: ${CONTAINER}"
        fi
        echo "  Version  : ${ver}"
        echo "  API      : ${API}"
        echo "  Context  : ${CTX}"
        echo
        echo "  Total downloaded Models Size: ${size} GB"
        echo
        say  "  [1] Launch a Model"
        say  "  [2] Pull a Recommended/Custom Model"
        say  "  [3] Delete a Model"
        say  "  [4] Modify Context Length"
        say  "  [0] Back to main menu"
        echo
        local choice
        read -r -p "  Select option: " choice
        case "${choice}" in
            1) ollama_launch ;;
            2) ollama_pull_menu ;;
            3) ollama_delete ;;
            4) ollama_context ;;
            0) return ;;
        esac
    done
}

ollama_launch() {
    ollama_ensure || return
    clear
    header "LAUNCH A MODEL"
    local -a names sizes
    while IFS='|' read -r name size; do
        [ -z "${name}" ] && continue
        names+=("${name}")
        sizes+=("${size}")
    done < <(ollama_list_installed)
    if [ "${#names[@]}" -eq 0 ]; then
        if is_native_mode; then
            echo "  No models installed yet in the native ollama on this Mac."
        else
            echo "  No installed models in the ${CONTAINER} container."
        fi
        echo "  Pull one first via menu option [2]."
        echo
        pause_return
        return
    fi
    local i
    for i in "${!names[@]}"; do
        printf '  [%d] %-50s <%s>\n' "$((i+1))" "${names[$i]}" "${sizes[$i]}"
    done
    echo
    say  "  [0] Back"
    echo
    local pick
    read -r -p "  Select model: " pick
    [ -z "${pick}" ] && return
    [ "${pick}" = "0" ] && return
    if ! [[ "${pick}" =~ ^[1-9][0-9]*$ ]] || [ "${pick}" -gt "${#names[@]}" ]; then
        err "  [!] Invalid selection."
        sleep 1
        return
    fi
    local model="${names[$((pick-1))]}"
    clear
    header "LAUNCHING MODEL"
    echo "  Tag       : ${model}"
    if is_native_mode; then
        echo "  Backend   : native ollama (Apple Metal)"
    else
        echo "  Container : ${CONTAINER}"
    fi
    echo "  Context   : ${CTX}"
    echo
    dim "  Inside the REPL: /set parameter num_ctx ${CTX}  (per-session override)"
    dim "  Type /bye to exit and return to the menu."
    echo
    local -a flags=()
    [[ "${model}" == *qwen3.5* ]] && flags+=(--think=false)
    ollama_cli_it run "${flags[@]}" "${model}" || true
}

ollama_pull_menu() {
    ollama_ensure || return
    while true; do
        clear
        header "PULL A RECOMMENDED/CUSTOM MODEL"
        say  "  [1] Recommended Models"
        say  "  [2] Custom Model Tag"
        say  "  [0] Back"
        echo
        local choice
        read -r -p "  Select option: " choice
        case "${choice}" in
            1) ollama_pull_recommended; return ;;
            2) ollama_pull_custom; return ;;
            0) return ;;
        esac
    done
}

ollama_pull_recommended() {
    clear
    header "PULL RECOMMENDED MODEL"
    local -a tags
    local last_group="" count=0
    while IFS='|' read -r grp tag; do
        [ -z "${tag}" ] && continue
        ollama_is_installed "${tag}" && continue
        if [ "${grp}" != "${last_group}" ]; then
            echo
            [ "${grp}" = "LOW" ]  && dim "  LOW VRAM"
            [ "${grp}" = "HIGH" ] && dim "  HIGH VRAM"
            dim "  --------------------------------------------------------------------------------"
            last_group="${grp}"
        fi
        count=$((count + 1))
        tags+=("${tag}")
        printf '  [%d] %s\n' "${count}" "${tag}"
    done < <(grep -v '^[[:space:]]*$' "${RECFILE}" | grep -v '^#')
    if [ "${count}" -eq 0 ]; then
        if is_native_mode; then
            echo "  All recommended models are already installed in the native ollama."
        else
            echo "  All recommended models are already installed in the container."
        fi
        echo
        pause_return
        return
    fi
    echo
    say  "  [0] Back"
    echo
    local pick
    read -r -p "  Select option: " pick
    [ -z "${pick}" ] && return
    [ "${pick}" = "0" ] && return
    if ! [[ "${pick}" =~ ^[1-9][0-9]*$ ]] || [ "${pick}" -gt "${count}" ]; then
        err "  [!] Invalid selection."
        sleep 1
        return
    fi
    local model="${tags[$((pick-1))]}"
    clear
    header "DOWNLOADING MODEL"
    if is_native_mode; then
        echo "  Pulling ${model} via native ollama..."
    else
        echo "  Pulling ${model} into ${CONTAINER}..."
    fi
    echo
    ollama_cli_it pull "${model}" || true
    echo
    pause_return
}

ollama_pull_custom() {
    clear
    header "PULL CUSTOM MODEL"
    local model
    read -r -p "  Enter model tag: " model
    [ -z "${model}" ] && return
    echo
    if is_native_mode; then
        echo "  Pulling ${model} via native ollama..."
    else
        echo "  Pulling ${model} into ${CONTAINER}..."
    fi
    echo
    ollama_cli_it pull "${model}" || true
    echo
    pause_return
}

ollama_delete() {
    clear
    header "DELETE A MODEL"
    local -a names sizes
    while IFS='|' read -r name size; do
        [ -z "${name}" ] && continue
        names+=("${name}")
        sizes+=("${size}")
    done < <(ollama_list_installed)
    if [ "${#names[@]}" -eq 0 ]; then
        if is_native_mode; then
            echo "  No models installed in the native ollama."
        else
            echo "  No installed models in the ${CONTAINER} container."
        fi
        echo
        pause_return
        return
    fi
    local i
    for i in "${!names[@]}"; do
        printf '  [%d] %-50s <%s>\n' "$((i+1))" "${names[$i]}" "${sizes[$i]}"
    done
    echo
    say  "  [0] Back"
    echo
    local pick
    read -r -p "  Select model to delete: " pick
    [ -z "${pick}" ] && return
    [ "${pick}" = "0" ] && return
    if ! [[ "${pick}" =~ ^[1-9][0-9]*$ ]] || [ "${pick}" -gt "${#names[@]}" ]; then
        err "  [!] Invalid selection."
        sleep 1
        return
    fi
    local model="${names[$((pick-1))]}"
    echo
    echo "  You are about to delete: ${model}"
    echo
    local confirm
    read -r -p "  Are you sure? [y/N]: " confirm
    case "${confirm}" in y|Y|yes|YES) ;; *) return ;; esac
    echo
    if is_native_mode; then
        echo "  Removing ${model} from the native ollama..."
    else
        echo "  Removing ${model} from ${CONTAINER}..."
    fi
    if ollama_cli rm "${model}"; then
        say "  [OK] ${model} deleted successfully."
        sleep 2
    else
        err "  [!] Failed to delete model."
        pause_return
    fi
}

ollama_context() {
    while true; do
        clear
        header "MODIFY CONTEXT LENGTH"
        echo "  Current: ${CTX}"
        echo
        say  "  [1] 4096"
        say  "  [2] 8192"
        say  "  [3] 16384"
        say  "  [4] 32768"
        say  "  [5] 65536"
        say  "  [6] 131072   (128K)"
        say  "  [7] 262144   (256K)"
        say  "  [8] Custom"
        say  "  [0] Back"
        echo
        local pick newctx
        read -r -p "  Select option: " pick
        case "${pick}" in
            1) newctx=4096 ;;
            2) newctx=8192 ;;
            3) newctx=16384 ;;
            4) newctx=32768 ;;
            5) newctx=65536 ;;
            6) newctx=131072 ;;
            7) newctx=262144 ;;
            8)
                echo
                read -r -p "  Enter custom context length: " newctx
                [ -z "${newctx}" ] && continue
                [[ "${newctx}" =~ ^[1-9][0-9]*$ ]] || continue
                ;;
            0) return ;;
            *) continue ;;
        esac
        clear
        header "APPLY CONTEXT LENGTH"
        echo "  Current : ${CTX}"
        echo "  New     : ${newctx}"
        echo
        echo "  Saved locally in context_size.cfg."
        echo
        CTX="${newctx}"
        echo "${CTX}" > "${CFG}"
        if is_native_mode; then
            # Native mode: ollama reads OLLAMA_NUM_CTX from its own env at
            # `ollama serve` start time. We can't simply edit .env and
            # `docker compose up` like in container mode - the brew launchd
            # plist / Ollama.app owns the process.
            echo "  Native ollama is in use, so there is no docker container to recreate."
            echo
            echo "  This new value is the per-session default the REPL hint will show."
            echo "  To make it the SERVER-SIDE default, set it in the ollama service env:"
            if command -v brew >/dev/null 2>&1; then
                echo "    launchctl setenv OLLAMA_NUM_CTX ${CTX}"
                echo "    brew services restart ollama"
            else
                echo "    Quit the Ollama.app, set OLLAMA_NUM_CTX=${CTX} in your shell"
                echo "    profile, and relaunch it."
            fi
            echo
            echo "  Either way, you can always override per session inside the REPL:"
            echo "    /set parameter num_ctx ${CTX}"
            echo
            pause_return
        else
            echo "  Choose Y to also write OLLAMA_NUM_CTX in .env and recreate the"
            echo "  ollama container (server-side default; ~10s downtime)."
            echo
            local recreate
            read -r -p "  Recreate container with new server-side default? [y/N]: " recreate
            case "${recreate}" in y|Y|yes|YES) ollama_apply_ctx_to_env ;; esac
        fi
        return
    done
}

ollama_apply_ctx_to_env() {
    if [ ! -f "${ENV_FILE}" ]; then
        err "  [!] Cannot find ${ENV_FILE} - saving CTX in cfg only."
        pause_return
        return
    fi
    if grep -q '^OLLAMA_NUM_CTX=' "${ENV_FILE}"; then
        sed -i.bak "s|^OLLAMA_NUM_CTX=.*|OLLAMA_NUM_CTX=${CTX}|" "${ENV_FILE}"
        rm -f "${ENV_FILE}.bak"
    else
        printf '\nOLLAMA_NUM_CTX=%s\n' "${CTX}" >> "${ENV_FILE}"
    fi
    clear
    header "RECREATING OLLAMA CONTAINER"
    ( cd "${COMPOSE_DIR}" && COMPOSE_PROFILES=ai docker compose up -d --force-recreate "${CONTAINER}" )
    ollama_ensure_container
}

# ============================================================================
# Entry point
# ============================================================================
# Wipe the visible screen AND the scrollback buffer so Terminal.app's
# launcher prelude ("Last login...", "/path/to/MAC-HOMELAB-MANAGER.COMMAND
# ; exit;") cannot be scrolled back to. Plain `clear` only handles the
# visible screen on macOS, leaving the prelude in scrollback.
printf '\033[H\033[2J\033[3J'
main_menu
echo
pause_close
exit 0
