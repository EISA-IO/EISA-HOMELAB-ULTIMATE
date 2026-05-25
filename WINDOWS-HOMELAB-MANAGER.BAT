@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul
title EISA Homelab Ultimate - Manager
color 0A
mode con: cols=140 lines=42 >nul 2>&1

:: =============================================================================
:: EISA HOMELAB ULTIMATE - Unified manager (Windows)
:: One launcher for everything. Menu-driven:
::   [1] First-Run Setup    (wizard - once on a fresh clone)
::   [2] Start Stack        (day-to-day; brings the chosen profiles up)
::   [3] Stop Stack         (compose down + by-name fallback)
::   [4] List Stack         (show running containers + health)
::   [5] LLM Manager        (pull / launch / delete Ollama models)
:: =============================================================================

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

set "COMPOSE_DIR=%SCRIPT_DIR%\files"
set "SETUP_PS1=%COMPOSE_DIR%\scripts\setup.ps1"
set "ENV_FILE=%COMPOSE_DIR%\.env"
set "CONTAINER=ollama"
set "API=http://127.0.0.1:11434"
set "CFG=%COMPOSE_DIR%\context_size.cfg"
set "RECFILE=%COMPOSE_DIR%\recommended_models.txt"
set "LISTTMP=%TEMP%\ollama_menu_%RANDOM%_%RANDOM%.tmp"
set "IDXTMP=%TEMP%\ollama_idx_%RANDOM%_%RANDOM%.tmp"

:: Hoisted to top so both Stop Stack and List Stack can iterate the same list.
set "EISA=cloudflared heimdall-media Caddy Authelia navidrome jellyfin filebrowser omni-tools n8n qdrant ollama open-webui searxng local-deep-research vane hermes-agent Portainer tor-browser immich-server immich-machine-learning immich-redis immich-postgres seerr sonarr radarr prowlarr qbittorrent"

:: Postgres bind-mount paths the wizard uses by default. The "reset databases"
:: recovery in Stop Stack only ever touches these two and only with explicit
:: typed-"yes" confirmation - everything else (media, ollama models, named
:: docker volumes) stays intact.
set "N8N_PG=%COMPOSE_DIR%\persistent-storage\n8n\postgres_storage"
set "IMMICH_PG=%COMPOSE_DIR%\persistent-storage\immich\postgres"

where pwsh >nul 2>&1
if %ERRORLEVEL%==0 (set "PS=pwsh") else (set "PS=powershell")


:: =============================================================================
:: TOP-LEVEL MENU
:: =============================================================================
:MAIN_MENU
cls
echo.
echo  ============================================================
echo   EISA HOMELAB ULTIMATE - Manager
echo  ============================================================
echo.
echo   The ULTIMATE private, no-tracking homelab stack.
echo   100%% local-first  ^|  zero telemetry  ^|  your data, your machine
echo.
echo  ------------------------------------------------------------
echo.
echo   [1] First-Run Setup       (wizard - run me once on a fresh clone)
echo   [2] Start Stack           (day-to-day, brings everything up)
echo   [3] Stop Stack            (compose down + cleanup)
echo   [4] List Stack            (show running containers + health)
echo   [5] LLM Manager           (pull, launch, delete Ollama models)
echo   [6] Edit Media Folders    (movies / tv / music / downloads / photos)
echo   [7] Backup / Restore      (save or load images + volumes + state)
echo.
echo   [0] Exit
echo.
set "choice="
set /p "choice=  Select option: "

if "!choice!"=="1" goto :DO_FIRST_RUN
if "!choice!"=="2" goto :DO_START
if "!choice!"=="3" goto :DO_STOP
if "!choice!"=="4" goto :DO_LIST
if "!choice!"=="5" goto :OLLAMA_BOOT
if "!choice!"=="6" goto :DO_EDIT_MEDIA
if "!choice!"=="7" goto :DO_BACKUP_MENU
if "!choice!"=="0" goto :END
goto :MAIN_MENU


:: =============================================================================
:: [1] FIRST-RUN WIZARD
:: =============================================================================
:DO_FIRST_RUN
cls
echo.
echo  ============================================================
echo   EISA HOMELAB ULTIMATE - First-run wizard
echo  ============================================================
echo.
if not exist "%SETUP_PS1%" (
    echo   [X] Could not find setup.ps1 at:
    echo       %SETUP_PS1%
    echo       The repo layout looks wrong - re-clone or restore files\scripts\.
    echo.
    pause
    goto :MAIN_MENU
)
echo   Wizard: %SETUP_PS1%
echo   Using : %PS%
echo.
echo   ----------------------------------------------------------------
%PS% -NoProfile -ExecutionPolicy Bypass -File "%SETUP_PS1%"
set "EXITCODE=!ERRORLEVEL!"
echo   ----------------------------------------------------------------
echo.
if "!EXITCODE!"=="0" (
    echo   [OK] Wizard completed.
) else (
    echo   [!]  Wizard exited with code !EXITCODE!.
)
echo.
echo   Press any key to return to the main menu...
pause >nul
goto :MAIN_MENU


:: =============================================================================
:: [2] START STACK
:: =============================================================================
:DO_START
cls
echo.
echo  ============================================================
echo   EISA HOMELAB ULTIMATE - Starting
echo  ============================================================
echo.
if not exist "%SETUP_PS1%" (
    echo   [X] Could not find setup.ps1 at %SETUP_PS1%
    echo.
    pause
    goto :MAIN_MENU
)
echo   Wizard in -StartOnly mode (self-healing): renders configs, fixes
echo   bind-mount dirs, sets up the Authelia admin user, runs compose up.
echo   ----------------------------------------------------------------
%PS% -NoProfile -ExecutionPolicy Bypass -File "%SETUP_PS1%" -StartOnly
set "EXITCODE=!ERRORLEVEL!"
echo   ----------------------------------------------------------------
echo.
if "!EXITCODE!"=="0" (
    echo   [OK] Stack started.
) else (
    echo   [!]  Wizard exited with code !EXITCODE!.
    echo        Common cause: containers from an older install are blocking
    echo        these container_names. Pick [3] Stop Stack first, then retry.
)
echo.
echo   Press any key to return to the main menu...
pause >nul
goto :MAIN_MENU


:: =============================================================================
:: [6] EDIT MEDIA FOLDERS  (validate + edit the 5 host paths the stack mounts)
:: =============================================================================
:DO_EDIT_MEDIA
cls
echo.
echo  ============================================================
echo   EISA HOMELAB ULTIMATE - Edit Media Folders
echo  ============================================================
echo.
if not exist "%SETUP_PS1%" (
    echo   [X] Could not find setup.ps1 at %SETUP_PS1%
    echo.
    pause
    goto :MAIN_MENU
)
echo   Shows current paths + status, lets you change any of them, validates
echo   each one on disk, offers to create missing folders, and (optionally)
echo   recreates the affected containers so the new mounts take effect.
echo   ----------------------------------------------------------------
%PS% -NoProfile -ExecutionPolicy Bypass -File "%SETUP_PS1%" -EditMediaPaths
echo   ----------------------------------------------------------------
echo.
echo   Press any key to return to the main menu...
pause >nul
goto :MAIN_MENU


:: =============================================================================
:: [7] BACKUP / RESTORE submenu
:: =============================================================================
:DO_BACKUP_MENU
cls
echo.
echo  ============================================================
echo   EISA HOMELAB ULTIMATE - Backup / Restore
echo  ============================================================
echo.
echo   Backup:
echo   [1] Backup everything           (identical clone - restore skips the wizard)
echo   [2] Backup images + volumes     (no .env - wizard runs fresh on restore)
echo   [3] Backup images only          (offline image cache - wizard runs)
echo   [4] Backup volumes only         (user data only, no images - wizard runs)
echo.
echo   Restore:
echo   [5] Restore from a backup folder
echo.
echo   [0] Back
echo.
set "bchoice="
set /p "bchoice=  Select option: "
if "!bchoice!"=="1" set "BMODE=full"           & goto :DO_BACKUP
if "!bchoice!"=="2" set "BMODE=images-volumes" & goto :DO_BACKUP
if "!bchoice!"=="3" set "BMODE=images"         & goto :DO_BACKUP
if "!bchoice!"=="4" set "BMODE=volumes"        & goto :DO_BACKUP
if "!bchoice!"=="5" goto :DO_RESTORE
if "!bchoice!"=="0" goto :MAIN_MENU
goto :DO_BACKUP_MENU

:DO_BACKUP
cls
echo.
echo  ============================================================
echo   EISA HOMELAB ULTIMATE - Backup  (mode: !BMODE!)
echo  ============================================================
echo.
if not exist "%SETUP_PS1%" (
    echo   [X] Could not find setup.ps1 at %SETUP_PS1%
    echo.
    pause
    goto :DO_BACKUP_MENU
)
if "!BMODE!"=="full"           echo   Dumps every Docker image + named volume + persistent-
if "!BMODE!"=="full"           echo   storage + .env + state into a portable folder. Restoring
if "!BMODE!"=="full"           echo   on a different PC/Mac brings the stack up identically with
if "!BMODE!"=="full"           echo   the same configs and secrets - first-run wizard is skipped.
if "!BMODE!"=="full"           echo   Will offer to stop the stack first for a clean snapshot.
if "!BMODE!"=="images-volumes" echo   Saves images + named volumes + persistent-storage, but
if "!BMODE!"=="images-volumes" echo   NOT .env / state. Recipient runs the first-run wizard
if "!BMODE!"=="images-volumes" echo   fresh; secrets are regenerated, paths are re-asked. Pull
if "!BMODE!"=="images-volumes" echo   phase is instant because every image is already cached.
if "!BMODE!"=="images-volumes" echo   Will offer to stop the stack first for a clean snapshot.
if "!BMODE!"=="images"         echo   Saves docker images only (no user data, no .env). Useful
if "!BMODE!"=="images"         echo   as an offline image cache; stack can stay running.
if "!BMODE!"=="images"         echo   Restore runs the wizard normally; pull phase is instant.
if "!BMODE!"=="volumes"        echo   Saves named volumes + persistent-storage, no images, no
if "!BMODE!"=="volumes"        echo   .env. Restore runs the wizard normally and compose
if "!BMODE!"=="volumes"        echo   re-pulls every image from its registry (the slow part).
if "!BMODE!"=="volumes"        echo   Will offer to stop the stack first for a clean snapshot.
echo   ----------------------------------------------------------------
%PS% -NoProfile -ExecutionPolicy Bypass -File "%SETUP_PS1%" -Backup -BackupMode !BMODE!
echo   ----------------------------------------------------------------
echo.
echo   Press any key to return to the backup menu...
pause >nul
goto :DO_BACKUP_MENU

:DO_RESTORE
cls
echo.
echo  ============================================================
echo   EISA HOMELAB ULTIMATE - Restore
echo  ============================================================
echo.
if not exist "%SETUP_PS1%" (
    echo   [X] Could not find setup.ps1 at %SETUP_PS1%
    echo.
    pause
    goto :DO_BACKUP_MENU
)
set "rpath="
set /p "rpath=  Path to backup folder (or leave blank to be prompted): "
echo.
echo   Loads images, named volumes, persistent-storage, and .env from
echo   the backup folder, then brings the stack up. Will stop anything
echo   currently running first.
echo   ----------------------------------------------------------------
if defined rpath (
    %PS% -NoProfile -ExecutionPolicy Bypass -File "%SETUP_PS1%" -Restore -RestorePath "!rpath!"
) else (
    %PS% -NoProfile -ExecutionPolicy Bypass -File "%SETUP_PS1%" -Restore
)
echo   ----------------------------------------------------------------
echo.
echo   Press any key to return to the backup menu...
pause >nul
goto :DO_BACKUP_MENU


:: =============================================================================
:: [3] STOP STACK  (in-line; same logic as the old WINDOWS-STOP.BAT)
:: =============================================================================
:DO_STOP
cls
echo.
echo  ============================================================
echo   EISA HOMELAB ULTIMATE - Stopping
echo  ============================================================
echo.
pushd "%COMPOSE_DIR%" >nul 2>nul
if errorlevel 1 (
    echo   [X] Could not cd into %COMPOSE_DIR%
    echo.
    pause
    goto :MAIN_MENU
)

:: Enumerate every profile so `docker compose down` sees every service
:: even if a future service is scoped to media-stream/media-request/
:: productivity ONLY (without `media` as a fallback profile).
set "COMPOSE_PROFILES=ai,media,media-stream,media-request,productivity,tunnel"

echo   [1/3] docker compose down --remove-orphans -t 10  (project: eisa-homelab)
echo         Containers get 10s to stop gracefully, then SIGKILL. Prevents a
echo         half-broken container from a failed startup hanging the whole stop.
echo         --progress plain avoids cmd.exe redraw artefacts.
echo         ----------------------------------------------------------------
docker compose --progress plain down --remove-orphans -t 10
echo         ----------------------------------------------------------------
echo.

echo   [2/3] Stopping any leftover containers by name...
for %%N in (%EISA%) do (
    docker inspect -f "{{.State.Running}}" "%%N" >nul 2>&1
    if not errorlevel 1 (
        docker stop "%%N" >nul 2>&1 && echo          stopped  %%N
        docker rm   "%%N" >nul 2>&1 && echo          removed  %%N
    ) else (
        docker inspect -f "{{.Id}}" "%%N" >nul 2>&1
        if not errorlevel 1 (
            docker rm "%%N" >nul 2>&1 && echo          removed  %%N (was stopped)
        )
    )
)
for /f "tokens=*" %%C in ('docker ps -aq --filter "name=n8n-postgres" 2^>nul') do (
    docker rm -f "%%C" >nul 2>&1 && echo          removed  %%C  (n8n-postgres match)
)
echo.

echo   [3/3] Removing the 'caddy' docker network if it's empty...
docker network rm caddy >nul 2>&1 && echo          removed network 'caddy'
echo.

popd >nul 2>nul
echo   [OK] Stop complete.
echo.
echo   Note: bind-mounted media + files\persistent-storage are NOT touched.
echo         Named docker volumes are NOT touched.
echo.

:: --- Half-init postgres detection -------------------------------------------
:: Surfaces the "PG_VERSION present but global\pg_filenode.map missing" trap
:: that bricks Start Stack on subsequent runs. Only prompts when the broken
:: signature is actually present, so day-to-day stops stay quiet.
set "POSTGRES_HALFINIT="
if exist "%N8N_PG%\PG_VERSION" if not exist "%N8N_PG%\global\pg_filenode.map" set "POSTGRES_HALFINIT=1"
if exist "%IMMICH_PG%\PG_VERSION" if not exist "%IMMICH_PG%\global\pg_filenode.map" set "POSTGRES_HALFINIT=1"

if defined POSTGRES_HALFINIT (
    echo   ----------------------------------------------------------------
    echo   Detected a half-initialised postgres data directory.
    echo   This is what blocks Start Stack with 'pg_filenode.map' fatal errors.
    echo   The fix is to wipe and let postgres initdb fresh.
    echo.
    choice /C YN /N /M "  Reset the postgres databases now? [Y/N]: "
    if not errorlevel 2 (
        call :DEEP_CLEAN_POSTGRES
    ) else (
        echo   Skipped. You can re-run Stop Stack any time to be offered again.
    )
    echo.
)

echo   Press any key to return to the main menu...
pause >nul
goto :MAIN_MENU


:: ---------------------------------------------------------------------------
:: Wipe ONLY the two postgres bind-mount data dirs so the next start does a
:: clean initdb. Strictly opt-in: requires a typed "yes" (case-sensitive).
:: Only touches the two named paths - media, ollama models, named volumes,
:: .env and wizard-state are ALL preserved.
:: ---------------------------------------------------------------------------
:DEEP_CLEAN_POSTGRES
echo.
echo   ============================================================
echo    RESET DATABASES - DESTRUCTIVE
echo   ============================================================
echo.
echo   This will permanently delete:
echo     %N8N_PG%
echo     %IMMICH_PG%
echo.
echo   Effect:
echo     - n8n: every workflow run, credential, and saved workflow is gone.
echo     - immich: account + photo INDEX gone. The actual image files in
echo       your photos folder are NOT touched; immich will rebuild the
echo       index from them on next start, which takes a while.
echo.
echo   NOT touched:
echo     - your media folders (movies / music / photos)
echo     - ollama models / open-webui chats / qdrant vectors
echo     - your .env file or wizard state
echo.
echo   Type 'yes' (lowercase, no quotes) to confirm. Anything else cancels.
echo.
set "CONFIRM="
set /p "CONFIRM=  Confirm: "
if not "%CONFIRM%"=="yes" (
    echo   Cancelled - nothing deleted.
    exit /b 0
)
echo.
if exist "%N8N_PG%" (
    rmdir /s /q "%N8N_PG%" && echo   Removed %N8N_PG%
) else (
    echo   Skipped %N8N_PG% ^(did not exist^)
)
if exist "%IMMICH_PG%" (
    rmdir /s /q "%IMMICH_PG%" && echo   Removed %IMMICH_PG%
) else (
    echo   Skipped %IMMICH_PG% ^(did not exist^)
)
echo.
echo   Databases reset. The next [2] Start Stack will initdb cleanly.
exit /b 0


:: =============================================================================
:: [4] LIST STACK  (show running containers + health, color-grouped)
:: =============================================================================
:DO_LIST
cls
echo.
echo  +===================================================+
echo   Stack status
echo  +===================================================+
echo.

where docker >nul 2>nul
if errorlevel 1 (
    echo   [X] docker CLI not found in PATH.
    echo       Install Docker Desktop and re-run.
    echo.
    pause
    goto :MAIN_MENU
)
docker info --format "{{.ServerVersion}}" >nul 2>nul
if errorlevel 1 (
    echo   [X] Docker engine is not running.
    echo       Start Docker Desktop and re-run.
    echo.
    pause
    goto :MAIN_MENU
)

echo   CONTAINER                       STATE       HEALTH       STATUS
echo   ------------------------------  ----------  -----------  -----------------------------------
set /a _FOUND=0
set /a _RUNNING=0
set /a _HEALTHY=0
set /a _UNHEALTHY=0
for %%N in (%EISA%) do (
    set "ST="
    for /f "tokens=*" %%S in ('docker inspect -f "{{.State.Status}}" "%%N" 2^>nul') do set "ST=%%S"
    if defined ST (
        set /a _FOUND+=1
        set "HE=n/a"
        for /f "tokens=*" %%H in ('docker inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}" "%%N" 2^>nul') do set "HE=%%H"
        set "STS=-"
        for /f "tokens=*" %%P in ('docker ps -a --filter "name=^%%N$" --format "{{.Status}}" 2^>nul') do set "STS=%%P"
        if "!ST!"=="running" set /a _RUNNING+=1
        if "!HE!"=="healthy" set /a _HEALTHY+=1
        if "!HE!"=="unhealthy" set /a _UNHEALTHY+=1
        call :LIST_ROW "%%N" "!ST!" "!HE!" "!STS!"
    )
)
echo.
if !_FOUND! equ 0 (
    echo   No EISA containers found - the stack does not appear to be deployed.
    echo.
    echo   Use option [2] Start Stack to bring it up.
) else (
    echo   Summary: !_FOUND! tracked, !_RUNNING! running, !_HEALTHY! healthy, !_UNHEALTHY! unhealthy
)
echo.
echo   Press any key to return to the main menu...
pause >nul
goto :MAIN_MENU

:LIST_ROW
:: %1=name %2=state %3=health %4=status. Pads each fixed-width column the
:: same way the macOS sister script does so the table lines up.
set "_N=%~1                              "
set "_N=!_N:~0,30!"
set "_S=%~2          "
set "_S=!_S:~0,10!"
set "_H=%~3           "
set "_H=!_H:~0,11!"
echo   !_N!  !_S!  !_H!  %~4
exit /b


:: =============================================================================
:: [5] OLLAMA / LLM MANAGER  (full port of WINDOWS-LLM-MANAGER.BAT)
:: =============================================================================
:OLLAMA_BOOT
where docker >nul 2>nul
if errorlevel 1 (
    cls & call :OLLAMA_HEADER "ERROR"
    echo   docker CLI not found in PATH.
    echo   Install Docker Desktop and re-run.
    echo.
    pause
    goto :MAIN_MENU
)
docker info --format "{{.ServerVersion}}" >nul 2>nul
if errorlevel 1 (
    cls & call :OLLAMA_HEADER "ERROR"
    echo   Docker engine is not running.
    echo   Start Docker Desktop and re-run.
    echo.
    pause
    goto :MAIN_MENU
)

if not exist "%CFG%" echo 8192>"%CFG%"
set /p CTX=<"%CFG%"
if not defined CTX set "CTX=8192"
echo !CTX!| findstr /R "^[1-9][0-9]*$" >nul
if errorlevel 1 set "CTX=8192"

if not exist "%RECFILE%" (
    > "%RECFILE%" (
        echo LOW^|huihui_ai/gemma-4-abliterated:e4b-q4_K
        echo LOW^|huihui_ai/gemma-4-abliterated:e4b-q8_0
        echo HIGH^|carstenuhlig/omnicoder-2-9b:q4_k_m
    )
)

call :OLLAMA_ENSURE_CONTAINER
if errorlevel 1 goto :MAIN_MENU


:OLLAMA_MENU
cls
call :OLLAMA_HEADER "OLLAMA MANAGER (docker)"
set "OLLAMA_VER="
for /f "tokens=*" %%V in ('docker exec %CONTAINER% ollama --version 2^>nul') do set "OLLAMA_VER=%%V"
if not defined OLLAMA_VER set "OLLAMA_VER=unknown"
echo   Container: %CONTAINER%
echo   Version  : !OLLAMA_VER!
echo   API      : %API%
echo   Context  : !CTX!
echo.

set "_TOTAL_SIZE=?"
for /f "usebackq delims=" %%G in (`%PS% -NoProfile -Command "& {try {$j=(Invoke-WebRequest -Uri '%API%/api/tags' -UseBasicParsing -TimeoutSec 3).Content | ConvertFrom-Json; $s=($j.models | Measure-Object -Property size -Sum).Sum; if($s){[math]::Round($s/1GB,2)}else{'0.00'}} catch {'?'}}"`) do set "_TOTAL_SIZE=%%G GB"
echo   Total downloaded Models Size: !_TOTAL_SIZE!
echo.
echo   [1] Launch a Model
echo   [2] Pull a Recommended/Custom Model
echo   [3] Delete a Model
echo   [4] Modify Context Length
echo   [0] Back to main menu
echo.
set "choice="
set /p "choice=  Select option: "

if "!choice!"=="1" goto :OLLAMA_LAUNCH
if "!choice!"=="2" goto :OLLAMA_PULL
if "!choice!"=="3" goto :OLLAMA_DELETE
if "!choice!"=="4" goto :OLLAMA_CONTEXT
if "!choice!"=="0" goto :MAIN_MENU
goto :OLLAMA_MENU


:OLLAMA_HEADER
echo.
echo   +===================================================+
echo    %~1
echo   +===================================================+
echo.
exit /b


:OLLAMA_ENSURE_CONTAINER
docker inspect -f "{{.State.Running}}" %CONTAINER% 2>nul | findstr /B /C:"true" >nul
if not errorlevel 1 (
    for /l %%N in (1,1,15) do (
        %PS% -NoProfile -Command "try { (Invoke-WebRequest -Uri '%API%/api/tags' -UseBasicParsing -TimeoutSec 2) | Out-Null; exit 0 } catch { exit 1 }" >nul 2>nul
        if not errorlevel 1 exit /b 0
        timeout /t 1 /nobreak >nul
    )
)
cls
call :OLLAMA_HEADER "STARTING OLLAMA CONTAINER"
echo   Container  : %CONTAINER%
echo   Compose dir: %COMPOSE_DIR%
echo.
pushd "%COMPOSE_DIR%" >nul
set "COMPOSE_PROFILES=ai" & docker compose up -d %CONTAINER%
popd >nul

for /l %%N in (1,1,60) do (
    timeout /t 1 /nobreak >nul
    %PS% -NoProfile -Command "try { (Invoke-WebRequest -Uri '%API%/api/tags' -UseBasicParsing -TimeoutSec 2) | Out-Null; exit 0 } catch { exit 1 }" >nul 2>nul
    if not errorlevel 1 goto :OLLAMA_READY
)
echo.
echo   [!] Ollama container did not become ready within 60s.
echo       Check: docker logs %CONTAINER%
echo.
pause
exit /b 1

:OLLAMA_READY
echo   Ollama API is responding.
%PS% -NoProfile -ExecutionPolicy Bypass -Command ^
    "try {" ^
    "  $ps = (Invoke-WebRequest -Uri '%API%/api/ps' -UseBasicParsing -TimeoutSec 3).Content | ConvertFrom-Json;" ^
    "  foreach ($m in $ps.models) {" ^
    "    Write-Host ('  Unloading: ' + $m.name);" ^
    "    $body = @{model=$m.name; keep_alive=0} | ConvertTo-Json;" ^
    "    Invoke-WebRequest -Uri '%API%/api/generate' -Method Post -Body $body -ContentType 'application/json' -UseBasicParsing -TimeoutSec 10 | Out-Null;" ^
    "  }" ^
    "  if ($ps.models.Count -gt 0) { Write-Host '  VRAM freed.'; Start-Sleep -Seconds 2 }" ^
    "  else { Write-Host '  No models loaded in VRAM.' }" ^
    "} catch { Write-Host '  Could not query VRAM state, continuing.' }" 2>nul
echo.
exit /b 0


:OLLAMA_BUILD_INDEX
if exist "%LISTTMP%" del /q "%LISTTMP%" >nul 2>nul
if exist "%IDXTMP%"  del /q "%IDXTMP%"  >nul 2>nul
docker exec %CONTAINER% ollama list > "%LISTTMP%" 2>nul
set /a COUNT=0
for /f "usebackq skip=1 tokens=1,3,4" %%A in ("%LISTTMP%") do (
    set /a COUNT+=1
    >> "%IDXTMP%" echo !COUNT!^|%%A^|%%B %%C
)
exit /b

:OLLAMA_IS_INSTALLED
findstr /I /B /C:"%~1 " "%LISTTMP%" >nul 2>nul
exit /b !errorlevel!


:OLLAMA_LAUNCH
call :OLLAMA_ENSURE_CONTAINER
cls
call :OLLAMA_HEADER "LAUNCH A MODEL"
call :OLLAMA_BUILD_INDEX
if !COUNT! equ 0 (
    echo   No installed models in the %CONTAINER% container.
    echo   Pull one first via menu option [2].
    echo.
    pause
    goto :OLLAMA_MENU
)
for /f "usebackq tokens=1-3 delims=|" %%A in ("%IDXTMP%") do (
    echo   [%%A] %%B  ^<%%C^>
)
echo.
echo   [0] Back
echo.
set "pick="
set /p "pick=  Select model: "
if not defined pick goto :OLLAMA_LAUNCH
if "!pick!"=="0" goto :OLLAMA_MENU
set "MODEL="
for /f "tokens=2 delims=|" %%A in ('findstr /B /C:"!pick!|" "%IDXTMP%"') do set "MODEL=%%A"
if not defined MODEL (
    echo   [!] Invalid selection.
    timeout /t 1 /nobreak >nul
    goto :OLLAMA_LAUNCH
)
cls
call :OLLAMA_HEADER "LAUNCHING MODEL"
echo   Tag       : !MODEL!
echo   Container : %CONTAINER%
echo   Context   : !CTX!
echo.
echo   Inside the REPL: /set parameter num_ctx !CTX!  (per-session override)
echo   Type /bye to exit and return to the menu.
echo.
set "RUN_FLAGS="
echo !MODEL! | findstr /I "qwen3.5" >nul
if not errorlevel 1 set "RUN_FLAGS=--think=false"
docker exec -it %CONTAINER% ollama run !RUN_FLAGS! "!MODEL!"
goto :OLLAMA_MENU


:OLLAMA_PULL
call :OLLAMA_ENSURE_CONTAINER
cls
call :OLLAMA_HEADER "PULL A RECOMMENDED/CUSTOM MODEL"
echo   [1] Recommended Models
echo   [2] Custom Model Tag
echo   [0] Back
echo.
set "pullchoice="
set /p "pullchoice=  Select option: "
if "!pullchoice!"=="1" goto :OLLAMA_PULL_REC
if "!pullchoice!"=="2" goto :OLLAMA_PULL_CUSTOM
if "!pullchoice!"=="0" goto :OLLAMA_MENU
goto :OLLAMA_PULL


:OLLAMA_PULL_REC
cls
call :OLLAMA_HEADER "PULL RECOMMENDED MODEL"
call :OLLAMA_BUILD_INDEX
if exist "%IDXTMP%" del /q "%IDXTMP%" >nul 2>nul
set /a COUNT=0
set "LASTGROUP="
for /f "usebackq tokens=1,* delims=|" %%A in ("%RECFILE%") do (
    set "GROUP=%%A"
    set "TAG=%%B"
    if defined TAG (
        call :OLLAMA_IS_INSTALLED "%%B"
        if errorlevel 1 (
            if /I not "!LASTGROUP!"=="!GROUP!" (
                echo.
                if /I "!GROUP!"=="LOW"  echo   LOW VRAM
                if /I "!GROUP!"=="HIGH" echo   HIGH VRAM
                echo   --------------------------------------------------------------------------------
                set "LASTGROUP=!GROUP!"
            )
            set /a COUNT+=1
            >> "%IDXTMP%" echo !COUNT!^|%%A^|%%B
            echo   [!COUNT!] %%B
        )
    )
)
if !COUNT! equ 0 (
    echo   All recommended models are already installed in the container.
    echo.
    pause
    goto :OLLAMA_PULL
)
echo.
echo   [0] Back
echo.
set "pick="
set /p "pick=  Select option: "
if not defined pick goto :OLLAMA_PULL_REC
if "!pick!"=="0" goto :OLLAMA_PULL
set "MODEL="
for /f "tokens=3 delims=|" %%A in ('findstr /B /C:"!pick!|" "%IDXTMP%"') do set "MODEL=%%A"
if not defined MODEL (
    echo   [!] Invalid selection.
    timeout /t 1 /nobreak >nul
    goto :OLLAMA_PULL_REC
)
cls
call :OLLAMA_HEADER "DOWNLOADING MODEL"
echo   Pulling !MODEL! into %CONTAINER%...
echo.
docker exec -it %CONTAINER% ollama pull "!MODEL!"
echo.
pause
goto :OLLAMA_MENU


:OLLAMA_PULL_CUSTOM
cls
call :OLLAMA_HEADER "PULL CUSTOM MODEL"
set "MODEL="
set /p "MODEL=  Enter model tag: "
if not defined MODEL goto :OLLAMA_PULL
echo.
echo   Pulling !MODEL! into %CONTAINER%...
echo.
docker exec -it %CONTAINER% ollama pull "!MODEL!"
echo.
pause
goto :OLLAMA_MENU


:OLLAMA_DELETE
cls
call :OLLAMA_HEADER "DELETE A MODEL"
call :OLLAMA_BUILD_INDEX
if !COUNT! equ 0 (
    echo   No installed models in the %CONTAINER% container.
    echo.
    pause
    goto :OLLAMA_MENU
)
for /f "usebackq tokens=1-3 delims=|" %%A in ("%IDXTMP%") do (
    echo   [%%A] %%B  ^<%%C^>
)
echo.
echo   [0] Back
echo.
set "pick="
set /p "pick=  Select model to delete: "
if not defined pick goto :OLLAMA_DELETE
if "!pick!"=="0" goto :OLLAMA_MENU
set "MODEL="
for /f "tokens=2 delims=|" %%A in ('findstr /B /C:"!pick!|" "%IDXTMP%"') do set "MODEL=%%A"
if not defined MODEL (
    echo   [!] Invalid selection.
    timeout /t 1 /nobreak >nul
    goto :OLLAMA_DELETE
)
echo.
echo   You are about to delete: !MODEL!
echo.
choice /C YN /N /M "  Are you sure? [Y/N]: "
if errorlevel 2 goto :OLLAMA_DELETE
echo.
echo   Removing !MODEL! from %CONTAINER%...
docker exec %CONTAINER% ollama rm "!MODEL!"
if errorlevel 1 (
    echo.
    echo   [!] Failed to delete model.
    pause
    goto :OLLAMA_DELETE
)
echo.
echo   [OK] !MODEL! deleted successfully.
timeout /t 2 /nobreak >nul
goto :OLLAMA_DELETE


:OLLAMA_CONTEXT
cls
call :OLLAMA_HEADER "MODIFY CONTEXT LENGTH"
echo   Current: !CTX!
echo.
echo   [1] 4096
echo   [2] 8192
echo   [3] 16384
echo   [4] 32768
echo   [5] 65536
echo   [6] 131072   (128K)
echo   [7] 262144   (256K)
echo   [8] Custom
echo   [0] Back
echo.
set "ctxpick="
set /p "ctxpick=  Select option: "
if "!ctxpick!"=="0" goto :OLLAMA_MENU
if "!ctxpick!"=="1" set "NEWCTX=4096"   & goto :OLLAMA_CTX_CONFIRM
if "!ctxpick!"=="2" set "NEWCTX=8192"   & goto :OLLAMA_CTX_CONFIRM
if "!ctxpick!"=="3" set "NEWCTX=16384"  & goto :OLLAMA_CTX_CONFIRM
if "!ctxpick!"=="4" set "NEWCTX=32768"  & goto :OLLAMA_CTX_CONFIRM
if "!ctxpick!"=="5" set "NEWCTX=65536"  & goto :OLLAMA_CTX_CONFIRM
if "!ctxpick!"=="6" set "NEWCTX=131072" & goto :OLLAMA_CTX_CONFIRM
if "!ctxpick!"=="7" set "NEWCTX=262144" & goto :OLLAMA_CTX_CONFIRM
if "!ctxpick!"=="8" goto :OLLAMA_CTX_CUSTOM
goto :OLLAMA_CONTEXT

:OLLAMA_CTX_CUSTOM
echo.
set "NEWCTX="
set /p "NEWCTX=  Enter custom context length: "
if not defined NEWCTX goto :OLLAMA_CONTEXT
echo !NEWCTX!| findstr /R "^[1-9][0-9]*$" >nul
if errorlevel 1 goto :OLLAMA_CONTEXT
goto :OLLAMA_CTX_CONFIRM

:OLLAMA_CTX_CONFIRM
cls
call :OLLAMA_HEADER "APPLY CONTEXT LENGTH"
echo   Current : !CTX!
echo   New     : !NEWCTX!
echo.
echo   Saved locally in context_size.cfg.
echo.
echo   Choose Y to also write OLLAMA_NUM_CTX in .env and recreate the
echo   ollama container (server-side default; ~10s downtime).
echo.
choice /C YN /N /M "  Recreate container with new server-side default? [Y/N]: "
set "RECREATE=N"
if not errorlevel 2 set "RECREATE=Y"
set "CTX=!NEWCTX!"
> "%CFG%" echo !CTX!
if /I "!RECREATE!"=="Y" goto :OLLAMA_APPLY_TO_ENV
goto :OLLAMA_MENU

:OLLAMA_APPLY_TO_ENV
if not exist "%ENV_FILE%" (
    echo.
    echo   [!] Cannot find %ENV_FILE% - saving CTX in cfg only.
    pause
    goto :OLLAMA_MENU
)
%PS% -NoProfile -ExecutionPolicy Bypass -Command ^
    "$p='%ENV_FILE%';" ^
    "$ctx='!CTX!';" ^
    "$lines = Get-Content -LiteralPath $p;" ^
    "$found=$false;" ^
    "$out=$lines | ForEach-Object { if ($_ -match '^OLLAMA_NUM_CTX=') { $found=$true; \"OLLAMA_NUM_CTX=$ctx\" } else { $_ } };" ^
    "if (-not $found) { $out += \"OLLAMA_NUM_CTX=$ctx\" };" ^
    "Set-Content -LiteralPath $p -Value $out -Encoding ASCII"
cls
call :OLLAMA_HEADER "RECREATING OLLAMA CONTAINER"
pushd "%COMPOSE_DIR%" >nul
set "COMPOSE_PROFILES=ai" & docker compose up -d --force-recreate %CONTAINER%
popd >nul
call :OLLAMA_ENSURE_CONTAINER
goto :OLLAMA_MENU


:: =============================================================================
:: EXIT
:: =============================================================================
:END
if exist "%LISTTMP%" del /q "%LISTTMP%" >nul 2>nul
if exist "%IDXTMP%"  del /q "%IDXTMP%"  >nul 2>nul

:: Pause if launched by double-click (cmd /c) so the user can read any output.
echo %CMDCMDLINE% | findstr /I /C:"/c" >nul && (
    echo.
    echo Press any key to close this window . . .
    pause >nul
)

endlocal
exit /b 0
