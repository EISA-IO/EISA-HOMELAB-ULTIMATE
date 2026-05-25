#Requires -Version 5.1
<#
.SYNOPSIS
  EISA Homelab Ultimate - beginner-friendly first-run wizard.

.DESCRIPTION
  On a fresh checkout, walks the user through:
    1. Picking a stack (AI / Media+Productivity / Ultimate)
    2. Choosing local-only vs Cloudflare tunnel access
    3. Pointing at their media folders by friendly name
    4. Generating strong secrets silently
    5. Starting the right docker compose profiles
    6. Pulling a first LLM if the AI stack is selected and no models exist
  On subsequent runs, lets the user just start their existing stack.

.PARAMETER Reconfigure
  Force the first-run wizard even if .env / .wizard-state.json are populated.

.PARAMETER NoStart
  Run the wizard but skip `docker compose up`.
#>

[CmdletBinding()]
param(
    # First-run mode (no flag): run the full wizard.
    [switch]$Reconfigure,    # force re-asking every value even if .env has it
    [switch]$NoStart,        # render configs but don't `docker compose up`
    [switch]$StartOnly,      # skip wizard entirely; just bring the existing stack up
    [switch]$EditMediaPaths, # standalone editor for MOVIES_PATH / TV_SHOWS_PATH / MUSIC_PATH / DOWNLOADS_PATH / PHOTOS_PATH
    [switch]$Backup,         # save images + named volumes + persistent-storage + .env to a portable folder
    [string]$BackupPath,     # destination folder for -Backup (default: <repoRoot>\backups\eisa-homelab-backup-<timestamp>)
    [ValidateSet('','full','images-volumes','images','volumes')]
    [string]$BackupMode = '', # what to include in -Backup: full | images-volumes | images | volumes (prompts if blank)
    [switch]$Restore,        # load images + volumes + persistent-storage from a backup folder, then start
    [string]$RestorePath     # source folder for -Restore (prompted if not supplied)
)

# ---------------------------------------------------------------------------
# Locate project root (one level up from this script).
# ---------------------------------------------------------------------------
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
Set-Location $ProjectRoot

$EnvFile         = Join-Path $ProjectRoot '.env'
$EnvExample      = Join-Path $ProjectRoot '.env.example'
$StateFile       = Join-Path $ProjectRoot '.wizard-state.json'
$RecommendedFile = Join-Path $ProjectRoot 'recommended_models.txt'

# Make the console UTF-8 so the ASCII-art logo renders.
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch {}

# ---------------------------------------------------------------------------
# Output helpers - green/minimal house style.
# ---------------------------------------------------------------------------
function G   { param([string]$T = '') Write-Host $T -ForegroundColor Green }
function Dim { param([string]$T = '') Write-Host $T -ForegroundColor DarkGreen }
function Err { param([string]$T) Write-Host "  ! $T" -ForegroundColor Red }
function Ok  { param([string]$T) Write-Host "  $([char]0x2713) $T" -ForegroundColor Green }

function Show-Logo {
    # NOTE: deliberately no Clear-Host here - when invoked from a .bat
    # launcher we want the bat's pre-amble (steps 1..4) to stay visible
    # above the logo so the user has a full audit trail of what ran.
    G ''
    G '   ███████╗██╗███████╗ █████╗'
    G '   ██╔════╝██║██╔════╝██╔══██╗'
    G '   █████╗  ██║███████╗███████║'
    G '   ██╔══╝  ██║╚════██║██╔══██║'
    G '   ███████╗██║███████║██║  ██║'
    G '   ╚══════╝╚═╝╚══════╝╚═╝  ╚═╝'
    G '   H O M E L A B    U L T I M A T E'
    G ''
    G '   The ULTIMATE private, no-tracking homelab stack.'
    Dim '   100% local-first  |  zero telemetry  |  your data, your machine'
    G ''
}

function Step {
    param([string]$Title, [string]$Hint = '')
    G ''
    G "  $Title"
    if ($Hint) { Dim "  $Hint" }
    G ''
}

# ---------------------------------------------------------------------------
# Prompts.
# ---------------------------------------------------------------------------
function Ask {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default = '',
        [switch]$Secret,
        [switch]$AllowEmpty
    )
    while ($true) {
        $hint = if ($Default) { " [$Default]" } else { '' }
        Write-Host "  $Prompt$hint " -NoNewline -ForegroundColor Green
        if ($Secret) {
            $sec  = Read-Host -AsSecureString
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            $val  = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        } else {
            $val = Read-Host
        }
        if ([string]::IsNullOrWhiteSpace($val)) { $val = $Default }
        if ([string]::IsNullOrWhiteSpace($val) -and -not $AllowEmpty) {
            Err "this can't be blank"
            continue
        }
        return $val
    }
}

# Open a URL in the user's default browser (best effort, no-op on failure).
function Open-Browser {
    param([Parameter(Mandatory)][string]$Url)
    try {
        switch ($script:OS) {
            'Windows' { Start-Process $Url | Out-Null }
            'Mac'     { & open $Url 2>$null | Out-Null }
            'Linux'   { & xdg-open $Url 2>$null | Out-Null }
        }
    } catch {}
}

# ---------------------------------------------------------------------------
# Add-DesktopShortcut: drops a one-click "Start EISA Homelab" launcher on the
# user's Desktop. Windows shortcut points at the repo's
# WINDOWS_HOMELAB_START.bat (.lnk via WScript.Shell COM); macOS copies
# MAC_HOMELAB_START.command to ~/Desktop and marks it executable. Idempotent.
# ---------------------------------------------------------------------------
function Add-DesktopShortcut {
    # ProjectRoot = .../files, the start launchers live one level up at the repo root.
    $repoRoot = Split-Path $ProjectRoot -Parent
    if ($script:OS -eq 'Windows') {
        $target = Join-Path $repoRoot 'WINDOWS_HOMELAB_START.bat'
        if (-not (Test-Path $target)) {
            Dim "  WINDOWS_HOMELAB_START.bat not found at $target - skipping desktop shortcut."
            return
        }
        $desktop = [Environment]::GetFolderPath('Desktop')
        if (-not $desktop -or -not (Test-Path $desktop)) {
            Dim '  Could not resolve Desktop folder - skipping shortcut.'
            return
        }
        $lnk = Join-Path $desktop 'EISA Homelab.lnk'
        try {
            $sh = New-Object -ComObject WScript.Shell
            $s  = $sh.CreateShortcut($lnk)
            $s.TargetPath       = $target
            $s.WorkingDirectory = $repoRoot
            # Use cmd.exe's icon - the .bat itself has none, the shell would
            # otherwise show a blank icon. Keeps it recognisable on Desktop.
            $s.IconLocation     = "$env:SystemRoot\System32\cmd.exe,0"
            $s.Description      = 'Start EISA Homelab (Docker + stack + Heimdall)'
            $s.Save()
            Ok "Desktop shortcut created: $lnk"
        } catch {
            Dim "  Could not create desktop shortcut: $($_.Exception.Message)"
        }
    } elseif ($script:OS -eq 'Mac') {
        $target = Join-Path $repoRoot 'MAC_HOMELAB_START.command'
        if (-not (Test-Path $target)) {
            Dim "  MAC_HOMELAB_START.command not found at $target - skipping desktop launcher."
            return
        }
        $desktop = Join-Path $HOME 'Desktop'
        if (-not (Test-Path $desktop)) {
            Dim '  ~/Desktop missing - skipping launcher.'
            return
        }
        $alias = Join-Path $desktop 'EISA Homelab.command'
        try {
            Copy-Item $target $alias -Force
            # Mac Finder won't double-click-launch a .command file without +x.
            & chmod +x $alias 2>$null | Out-Null
            Ok "Desktop launcher created: $alias"
        } catch {
            Dim "  Could not create desktop launcher: $($_.Exception.Message)"
        }
    } else {
        Dim '  Desktop shortcut creation is only implemented for Windows + macOS.'
    }
}

function Ask-YesNo {
    param([string]$Prompt, [bool]$DefaultYes = $true)
    $def = if ($DefaultYes) { 'Y/n' } else { 'y/N' }
    while ($true) {
        Write-Host "  $Prompt [$def] " -NoNewline -ForegroundColor Green
        $a = (Read-Host).Trim().ToLower()
        if ([string]::IsNullOrEmpty($a)) { return $DefaultYes }
        if ($a -in @('y','yes')) { return $true }
        if ($a -in @('n','no'))  { return $false }
        Err 'answer y or n'
    }
}

function Ask-Choice {
    param([Parameter(Mandatory)][object[]]$Options)
    while ($true) {
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $opt = $Options[$i]
            G ("    [{0}] {1}" -f ($i + 1), $opt.Label)
            if ($opt.PSObject.Properties['Hint'] -and $opt.Hint) {
                $lines = if ($opt.Hint -is [array]) { $opt.Hint } else { @($opt.Hint) }
                foreach ($ln in $lines) { Dim ("        $ln") }
            }
            if ($opt.PSObject.Properties['Warning'] -and $opt.Warning) {
                $wlines = if ($opt.Warning -is [array]) { $opt.Warning } else { @($opt.Warning) }
                foreach ($wln in $wlines) { Write-Host ("        [!] $wln") -ForegroundColor Yellow }
            }
        }
        G ''
        Write-Host '  > ' -NoNewline -ForegroundColor Green
        $pick = Read-Host
        $n = 0
        if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) {
            return $n
        }
        Err 'pick a number from the list'
    }
}

# Master list of pickable apps. One row per user-facing app - multi-container
# apps (immich, n8n, the arr stack) expose their internal services in
# the Services array so the wizard can hand them to `docker compose up`
# positionally. Bundle is the wizard's logical group: 'ai', 'media-stream'
# (streaming + request/download), or 'productivity'. The trimmer + custom
# picker both source from this so we never drift.
function Get-StackEntries {
    @(
        # AI
        [pscustomobject]@{ Bundle='ai'; Label='ollama               (local LLMs - the brain)';                  Services=@('ollama') }
        [pscustomobject]@{ Bundle='ai'; Label='open-webui           (ChatGPT-style chat interface for the AI)'; Services=@('open-webui') }
        [pscustomobject]@{ Bundle='ai'; Label='searxng              (private metasearch engine)';               Services=@('searxng') }
        [pscustomobject]@{ Bundle='ai'; Label='local-deep-research  (AI research assistant)';                   Services=@('local-deep-research') }
        [pscustomobject]@{ Bundle='ai'; Label='vane                 (Perplexity-style answer engine)';          Services=@('vane') }
        [pscustomobject]@{ Bundle='ai'; Label='n8n                  (workflow automation; bundles postgres + qdrant)'; Services=@('n8n','n8n-postgres','qdrant') }
        [pscustomobject]@{ Bundle='ai'; Label='hermes               (self-improving agent + dashboard UI)'; Services=@('hermes-agent') }
        # MEDIA STREAMING - what your friends/family will actually watch
        [pscustomobject]@{ Bundle='media-streaming'; Label='jellyfin             (movie + TV streaming)';                    Services=@('jellyfin') }
        [pscustomobject]@{ Bundle='media-streaming'; Label='navidrome            (music streaming)';                         Services=@('navidrome') }
        [pscustomobject]@{ Bundle='media-streaming'; Label='immich               (photo + video library; bundles DB/Redis/ML)'; Services=@('immich-server','immich-machine-learning','immich-redis','immich-postgres') }
        # MEDIA REQUEST - request UI + sonarr/radarr + indexer + torrent client
        [pscustomobject]@{ Bundle='media-request';   Label='seerr                (request UI for movies/TV)';                 Services=@('seerr') }
        [pscustomobject]@{ Bundle='media-request';   Label='sonarr               (TV automation)';                            Services=@('sonarr') }
        [pscustomobject]@{ Bundle='media-request';   Label='radarr               (movie automation)';                         Services=@('radarr') }
        [pscustomobject]@{ Bundle='media-request';   Label='prowlarr             (indexer manager)';                          Services=@('prowlarr') }
        [pscustomobject]@{ Bundle='media-request';   Label='qbittorrent          (torrent download client)';                  Services=@('qbittorrent') }
        # PRODUCTIVITY
        [pscustomobject]@{ Bundle='productivity'; Label='filebrowser          (web file manager)';                        Services=@('filebrowser') }
        [pscustomobject]@{ Bundle='productivity'; Label='omni-tools           (grab-bag of web utilities)';                Services=@('omni-tools') }
        [pscustomobject]@{ Bundle='productivity'; Label='tor-browser          (Tor Browser in a browser tab)';             Services=@('tor-browser') }
    )
}

# Show the user the services that the picked bundle will start and let them
# drop any they don't want. Returns the flat (and possibly trimmed) list of
# docker-compose service names to pass to `up`, OR $null if they accepted
# the bundle as-is - in which case the caller stays in --profile mode.
function Invoke-StackTrimmer {
    param([string]$Stack)  # 'ai' | 'media' | 'productivity' | 'ultimate'

    $all = Get-StackEntries
    $entries = switch ($Stack) {
        'ai'              { $all | Where-Object { $_.Bundle -eq 'ai' } }
        'media-streaming' { $all | Where-Object { $_.Bundle -eq 'media-streaming' } }
        'media-request'   { $all | Where-Object { $_.Bundle -eq 'media-request' } }
        'productivity'    { $all | Where-Object { $_.Bundle -eq 'productivity' } }
        'ultimate'        { $all }
    }
    $entries = @($entries)
    if ($entries.Count -eq 0) { return $null }

    G ''
    G  '  Want to drop any of these containers before starting?'
    Dim '  Press Enter to keep everything (the default), or type comma/space-'
    Dim '  separated numbers (e.g. "5 8" or "5,8") to skip those containers.'
    G  ''
    for ($i = 0; $i -lt $entries.Count; $i++) {
        G ("    [{0}] {1}" -f ($i + 1), $entries[$i].Label)
    }
    G  ''
    Write-Host '  > Drop which? (Enter = keep all) ' -NoNewline -ForegroundColor Green
    $raw = Read-Host
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    $dropIdx = @()
    foreach ($t in ($raw -split '[,\s]+' | Where-Object { $_ -match '^[0-9]+$' })) {
        $n = [int]$t
        if ($n -ge 1 -and $n -le $entries.Count -and ($dropIdx -notcontains $n)) {
            $dropIdx += $n
        }
    }
    if ($dropIdx.Count -eq 0) { return $null }

    $kept = @()
    $droppedLabels = @()
    for ($i = 0; $i -lt $entries.Count; $i++) {
        if ($dropIdx -contains ($i + 1)) {
            $droppedLabels += ($entries[$i].Label -split '\s')[0]
        } else {
            $kept += $entries[$i].Services
        }
    }
    Ok ('Dropped: ' + ($droppedLabels -join ', '))
    return ($kept | Select-Object -Unique)
}

# Multi-pick service picker for the CUSTOM stack option. Pulls the same
# master list as the trimmer so we never have to maintain two copies.
function Invoke-CustomServicePicker {
    $entries = @(Get-StackEntries)
    # Pre-compute the index ranges for the "ai" / "media" / "prod" shortcuts
    # so they keep working as the bundle membership of new apps changes.
    $aiIdx = @(); $streamIdx = @(); $requestIdx = @(); $prodIdx = @()
    for ($i = 0; $i -lt $entries.Count; $i++) {
        switch ($entries[$i].Bundle) {
            'ai'              { $aiIdx      += ($i + 1) }
            'media-streaming' { $streamIdx  += ($i + 1) }
            'media-request'   { $requestIdx += ($i + 1) }
            'productivity'    { $prodIdx    += ($i + 1) }
        }
    }

    G ''
    G  '  CUSTOM stack - pick the apps you want.'
    Dim '  Type comma- or space-separated numbers (e.g. "1,3,7" or "1 3 7"), "all" to'
    Dim '  pick everything, or one of: ai / streaming / request / media / prod.'
    G ''
    for ($i = 0; $i -lt $entries.Count; $i++) {
        G ("    [{0}] {1}" -f ($i + 1), $entries[$i].Label)
    }
    G ''
    Write-Host '  > ' -NoNewline -ForegroundColor Green
    $raw = Read-Host
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

    $picked = @()
    $lower  = $raw.Trim().ToLower()
    if ($lower -eq 'all') {
        $picked = 1..$entries.Count
    } elseif ($lower -eq 'ai') {
        $picked = $aiIdx
    } elseif ($lower -in @('streaming','media-streaming','stream')) {
        $picked = $streamIdx
    } elseif ($lower -in @('request','media-request','arr')) {
        $picked = $requestIdx
    } elseif ($lower -eq 'media') {
        $picked = @($streamIdx) + @($requestIdx)
    } elseif ($lower -in @('prod','productivity')) {
        $picked = $prodIdx
    } else {
        # Split on commas, spaces, or both; keep numeric tokens only.
        $tokens = $raw -split '[,\s]+' | Where-Object { $_ -match '^[0-9]+$' }
        foreach ($t in $tokens) {
            $n = [int]$t
            if ($n -ge 1 -and $n -le $entries.Count -and ($picked -notcontains $n)) {
                $picked += $n
            }
        }
    }

    $services = @()
    foreach ($p in $picked) {
        $services += $entries[$p - 1].Services
    }
    return ($services | Select-Object -Unique)
}

# ---------------------------------------------------------------------------
# Docker preflight - detect OS, status, and auto-install if missing.
# ---------------------------------------------------------------------------
function Get-OS {
    # $IsWindows / $IsMacOS / $IsLinux only exist on PowerShell 6+.
    if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) {
        if ($IsWindows) { return 'Windows' }
        if ($IsMacOS)   { return 'Mac' }
        if ($IsLinux)   { return 'Linux' }
    }
    # PowerShell 5.1 only runs on Windows.
    return 'Windows'
}

function Get-DockerStatus {
    # 0 = CLI present and engine reachable
    # 1 = CLI present but engine not running
    # 2 = CLI not installed
    try {
        $null = & docker --version 2>&1
        if ($LASTEXITCODE -ne 0) { return 2 }
    } catch { return 2 }
    try {
        $null = & docker info --format '{{.ServerVersion}}' 2>&1
        if ($LASTEXITCODE -ne 0) { return 1 }
    } catch { return 1 }
    return 0
}

function Wait-DockerEngine {
    param([int]$TimeoutSeconds = 300)
    Dim "  Waiting for the Docker engine to come up (up to $TimeoutSeconds s)..."
    $start = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt $TimeoutSeconds) {
        try {
            $null = & docker info --format '{{.ServerVersion}}' 2>&1
            if ($LASTEXITCODE -eq 0) {
                Ok 'Docker engine is up.'
                return $true
            }
        } catch {}
        Start-Sleep -Seconds 2
    }
    return $false
}

function Start-DockerDesktop {
    param([string]$OS)
    if ($OS -eq 'Windows') {
        $candidates = @(
            (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Docker\Docker\Docker Desktop.exe')
        )
        foreach ($c in $candidates) {
            if ($c -and (Test-Path $c)) {
                Start-Process -FilePath $c | Out-Null
                return
            }
        }
    } elseif ($OS -eq 'Mac') {
        & open -a 'Docker' 2>$null
    }
}

function Install-DockerWindows {
    # Try winget first.
    $wingetOk = $false
    try {
        $null = & winget --version 2>&1
        if ($LASTEXITCODE -eq 0) { $wingetOk = $true }
    } catch {}

    if ($wingetOk) {
        Dim '  Installing Docker Desktop via winget (a UAC prompt will appear)...'
        Start-Process -Verb RunAs -Wait -FilePath 'winget' -ArgumentList @(
            'install','-e','--id','Docker.DockerDesktop',
            '--silent','--accept-source-agreements','--accept-package-agreements'
        ) -ErrorAction SilentlyContinue
        # winget via Start-Process doesn't propagate $LASTEXITCODE; verify by re-checking docker.
        try { $null = & docker --version 2>&1 } catch {}
        if ($LASTEXITCODE -eq 0) {
            Ok 'Docker Desktop installed via winget.'
            return $true
        }
        Dim '  winget path did not complete cleanly. Falling back to MSI download...'
    }

    # MSI / EXE fallback.
    $url       = 'https://desktop.docker.com/win/main/amd64/Docker Desktop Installer.exe'
    $installer = Join-Path $env:TEMP 'DockerDesktopInstaller.exe'
    Dim '  Downloading Docker Desktop installer (~600 MB)...'
    try {
        Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
    } catch {
        Err "Download failed: $($_.Exception.Message)"
        return $false
    }
    Dim '  Running Docker Desktop installer (a UAC prompt will appear)...'
    Start-Process -Verb RunAs -Wait -FilePath $installer -ArgumentList @(
        'install','--quiet','--accept-license'
    ) -ErrorAction SilentlyContinue
    Remove-Item $installer -ErrorAction SilentlyContinue
    return $true
}

function Install-DockerMac {
    # Try Homebrew first.
    $brewOk = $false
    try {
        $null = & brew --version 2>&1
        if ($LASTEXITCODE -eq 0) { $brewOk = $true }
    } catch {}

    if ($brewOk) {
        Dim '  Installing Docker Desktop via Homebrew...'
        & brew install --cask docker
        if ($LASTEXITCODE -eq 0) {
            Ok 'Docker Desktop installed via Homebrew.'
            return $true
        }
        Dim '  brew install failed. Falling back to DMG download...'
    }

    # DMG fallback.
    $arch   = ((& uname -m) | Out-String).Trim()
    $dmgUrl = if ($arch -eq 'arm64') {
        'https://desktop.docker.com/mac/main/arm64/Docker.dmg'
    } else {
        'https://desktop.docker.com/mac/main/amd64/Docker.dmg'
    }
    $dmg = '/tmp/Docker.dmg'
    Dim "  Downloading Docker.dmg for $arch..."
    try {
        Invoke-WebRequest -Uri $dmgUrl -OutFile $dmg -UseBasicParsing
    } catch {
        Err "Download failed: $($_.Exception.Message)"
        return $false
    }
    Dim '  Mounting DMG...'
    & hdiutil attach $dmg -nobrowse -quiet
    Dim '  Copying Docker.app into /Applications (you may be prompted for your password)...'
    & sudo cp -R '/Volumes/Docker/Docker.app' '/Applications/'
    & hdiutil detach '/Volumes/Docker' -quiet
    Remove-Item $dmg -ErrorAction SilentlyContinue
    return $true
}

function Ensure-Docker {
    param([string]$OS)

    $status = Get-DockerStatus

    if ($status -eq 0) {
        # All good.
        return
    }

    if ($status -eq 1) {
        # CLI is there, engine isn't. Try to start Docker Desktop and wait.
        Dim '  Docker is installed but the engine is not running. Starting Docker Desktop...'
        Start-DockerDesktop -OS $OS
        if (Wait-DockerEngine -TimeoutSeconds 180) { return }
        Err 'Docker engine did not come up. Launch Docker Desktop manually and re-run.'
        exit 1
    }

    # status -eq 2 - CLI missing. Offer to install.
    Step 'Docker Desktop is not installed' "We can download and install it for you now. Expect a UAC / password prompt once."
    if (-not (Ask-YesNo 'Install Docker Desktop now?' $true)) {
        Err 'Docker Desktop is required. Install it manually and re-run.'
        Dim '  https://www.docker.com/products/docker-desktop/'
        exit 1
    }

    $installed = switch ($OS) {
        'Windows' { Install-DockerWindows }
        'Mac'     { Install-DockerMac }
        default {
            Err "Sorry, auto-install isn't wired up for $OS. Install Docker manually and re-run."
            Dim '  https://www.docker.com/products/docker-desktop/'
            exit 1
        }
    }

    if (-not $installed) {
        Err 'Auto-install did not complete. Install Docker Desktop manually and re-run.'
        Dim '  https://www.docker.com/products/docker-desktop/'
        exit 1
    }

    Ok 'Docker Desktop installed. Launching it...'
    Start-DockerDesktop -OS $OS

    if (-not (Wait-DockerEngine -TimeoutSeconds 300)) {
        Err 'Docker engine did not come up within 5 minutes.'
        Dim "  On Windows this usually means WSL2 was set up and Windows needs a sign-out or reboot."
        Dim '  Sign out / reboot, launch Docker Desktop manually, then re-run.'
        exit 1
    }
}

# ---------------------------------------------------------------------------
# .env IO + secret generation (unchanged shapes from prior wizard).
# ---------------------------------------------------------------------------
function Read-EnvFile {
    param([string]$Path)
    $map = [ordered]@{}
    if (-not (Test-Path $Path)) { return $map }
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
            $map[$Matches[1]] = $Matches[2]
        }
    }
    return $map
}

function Write-EnvFile {
    param([string]$Path, $Map)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Generated by setup.ps1 - open the HOMELAB-MANAGER launcher and pick [1] First-Run Setup to change values.')
    [void]$sb.AppendLine('# Sensitive: never commit this file (it is gitignored).')
    foreach ($k in $Map.Keys) {
        [void]$sb.AppendLine("$k=$($Map[$k])")
    }
    Set-Content -Path $Path -Value $sb.ToString() -Encoding ASCII
}

function New-HexSecret {
    param([int]$Bytes = 32)
    $b = New-Object byte[] $Bytes
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    -join ($b | ForEach-Object { $_.ToString('x2') })
}

function New-Base64Secret {
    param([int]$Bytes = 32)
    $b = New-Object byte[] $Bytes
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    [Convert]::ToBase64String($b)
}

function Test-Placeholder {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    return $Value -match '^__.*__$' -or $Value -match 'CHANGE_ME' -or $Value -match 'GENERATE_'
}

# True when .env already holds a real, filled-in configuration rather than
# the .env.example placeholders. Lets the first-run wizard offer "use your
# existing config" instead of re-walking every question. Fires for ANY
# configured domain (not a specific one) or for a completed local-only setup.
function Test-ConfiguredEnv {
    param($EnvMap)
    if (-not $EnvMap -or $EnvMap.Count -eq 0) { return $false }
    # Signal 1: a real domain or Cloudflare tunnel token is set - an online
    # hosting config for ANY domain already exists. Test-Placeholder treats a
    # blank/local-only value as "not set", so pure local installs fall through.
    if (-not (Test-Placeholder $EnvMap['DOMAIN']))                  { return $true }
    if (-not (Test-Placeholder $EnvMap['CLOUDFLARE_TUNNEL_TOKEN'])) { return $true }
    # Signal 2: every auto-generated secret is filled in - a completed setup,
    # even in local-only mode where there is no domain.
    $required = @(
        'POSTGRES_PASSWORD','N8N_ENCRYPTION_KEY','N8N_USER_MANAGEMENT_JWT_SECRET',
        'DB_PASSWORD','SONARR_API_KEY','RADARR_API_KEY','PROWLARR_API_KEY',
        'SEERR_API_KEY','HERMES_API_KEY'
    )
    foreach ($k in $required) {
        if (-not $EnvMap.Contains($k)) { return $false }
        if (Test-Placeholder $EnvMap[$k]) { return $false }
    }
    return $true
}

# Normalise Windows paths to docker-compose-friendly form.
function Format-Path {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $p = $Path.Trim().Trim('"').Trim("'")
    return $p -replace '\\', '/'
}

# Migrate the 5 media-path keys to the current per-OS defaults:
#   Windows/Linux: C:/MEDIA/{Movies,TV-Shows,Music,Downloads,Photos}
#   macOS:         $HOME/Documents/MEDIA/{Movies,TV-Shows,Music,Downloads,Photos}
# Only rewrites values that match a KNOWN LEGACY SHAPE so a custom path
# the user typed (e.g. /Volumes/Big/Music, E:\My-Stuff) is never touched.
# Legacy shapes are matched by regex so they work regardless of which
# username, drive letter, or platform produced them - that way a .env
# copied between Mac and Windows still migrates cleanly.
# Relies on $script:OS being set by the main flow before any branch
# invokes it. Returns the list of keys that were migrated.
function Migrate-LegacyMediaDefaults {
    param($EnvMap)
    $h = $HOME -replace '\\','/'
    $folders = @('Movies','TV-Shows','Music','Downloads','Photos')
    $keys    = @('MOVIES_PATH','TV_SHOWS_PATH','MUSIC_PATH','DOWNLOADS_PATH','PHOTOS_PATH')

    if ($script:OS -eq 'Mac') {
        $newPrefix = "$h/Documents/MEDIA"
    } else {
        $newPrefix = 'C:/MEDIA'
    }

    $migrated = @()
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $k = $keys[$i]
        $f = $folders[$i]
        if (-not $EnvMap.Contains($k)) { continue }
        $current = ($EnvMap[$k] -replace '\\','/').TrimEnd('/')
        $new     = "$newPrefix/$f"
        if ($current -eq $new) { continue }   # already on the new default

        $fEsc = [regex]::Escape($f)
        $patterns = @(
            "^F:/$fEsc$",                              # F:/Movies (oldest Windows default)
            "^C:/MEDIA/$fEsc$",                        # C:/MEDIA/Movies (current Windows default)
            "^/Users/[^/]+/$fEsc$",                    # /Users/john/Movies (oldest Mac default)
            "^/Users/[^/]+/Documents/$fEsc$",          # /Users/john/Documents/Movies (previous Mac default)
            "^/Users/[^/]+/Documents/MEDIA/$fEsc$",    # /Users/john/Documents/MEDIA/Movies (current Mac default)
            "^/home/[^/]+/$fEsc$",                     # /home/john/Movies (Linux equivalent)
            "^/home/[^/]+/Documents/MEDIA/$fEsc$"      # /home/john/Documents/MEDIA/Movies
        )
        foreach ($pat in $patterns) {
            if ($current -match $pat) {
                $EnvMap[$k] = $new
                $migrated += $k
                break
            }
        }
    }
    return $migrated
}

# ---------------------------------------------------------------------------
# State file (so subsequent runs can "just start").
# ---------------------------------------------------------------------------
function Read-State {
    if (-not (Test-Path $StateFile)) { return $null }
    try { return Get-Content $StateFile -Raw | ConvertFrom-Json } catch { return $null }
}

function Write-State {
    param($State)
    $State | ConvertTo-Json -Depth 5 | Set-Content $StateFile -Encoding ASCII
}

# ---------------------------------------------------------------------------
# Edit + validate media folder locations standalone (menu option [6] in the
# HOMELAB-MANAGER launchers). Reads/writes .env in place and offers to
# recreate the containers whose bind mounts changed.
# ---------------------------------------------------------------------------
function Test-MediaPath {
    # Returns [pscustomobject]@{ Status; Detail }. Status in 'ok','missing','file','error'.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ Status = 'error'; Detail = 'empty' }
    }
    try {
        if (-not (Test-Path $Path)) {
            return [pscustomobject]@{ Status = 'missing'; Detail = "doesn't exist yet" }
        }
        $item = Get-Item $Path -ErrorAction Stop
        if (-not $item.PSIsContainer) {
            return [pscustomobject]@{ Status = 'file'; Detail = 'is a file, expected a folder' }
        }
        return [pscustomobject]@{ Status = 'ok'; Detail = 'exists' }
    } catch {
        return [pscustomobject]@{ Status = 'error'; Detail = $_.Exception.Message }
    }
}

function Invoke-EditMediaPaths {
    if (-not (Test-Path $EnvFile)) {
        Err ".env not found at $EnvFile."
        Dim '  Run [1] First-Run Setup once to create it, then come back here to tweak paths.'
        return
    }
    $envMap = Read-EnvFile $EnvFile

    # Auto-migrate any leftover legacy F:\ defaults to C:/MEDIA/ - but only
    # when the value EXACTLY matches the old default (never a custom path).
    $migrated = Migrate-LegacyMediaDefaults $envMap
    if ($migrated.Count -gt 0) {
        Write-EnvFile $EnvFile $envMap
        Ok "Migrated legacy F:\ defaults to C:/MEDIA/ for: $($migrated -join ', ')"
    }

    # MOVIES_PATH and DOWNLOADS_PATH share TV_SHOWS_PATH defaults derivation logic
    # in the wizard - keep this list in the same order so users see them together.
    $keys = @(
        @{ Key = 'MOVIES_PATH';    Label = 'Movies folder'    }
        @{ Key = 'TV_SHOWS_PATH';  Label = 'TV Shows folder'  }
        @{ Key = 'MUSIC_PATH';     Label = 'Music folder'     }
        @{ Key = 'DOWNLOADS_PATH'; Label = 'Downloads folder' }
        @{ Key = 'PHOTOS_PATH';    Label = 'Photos folder (Immich library)' }
    )

    Step 'Edit + validate your media folders' 'Shows each path with current status. Press Enter to keep a value; type a new path to change it. Missing folders can be created on the spot.'

    G  '  Current values:'
    foreach ($spec in $keys) {
        $val = if ($envMap.Contains($spec.Key)) { $envMap[$spec.Key] } else { '' }
        $r   = Test-MediaPath $val
        $tag = switch ($r.Status) {
            'ok'      { '[OK]     ' }
            'missing' { '[MISSING]' }
            'file'    { '[BAD]    ' }
            'error'   { '[BAD]    ' }
        }
        $line = "    $tag  $($spec.Label.PadRight(40))  $val"
        switch ($r.Status) {
            'ok'      { G   $line }
            'missing' { Dim $line }
            default   { Err "$line  ($($r.Detail))" }
        }
    }
    G ''

    $changed = $false
    foreach ($spec in $keys) {
        $current = if ($envMap.Contains($spec.Key)) { $envMap[$spec.Key] } else { '' }
        $raw     = Ask "$($spec.Label) (Enter = keep)" $current -AllowEmpty
        if (-not $raw) { $raw = $current }
        $new     = Format-Path $raw
        if ($new -ne $current) {
            $envMap[$spec.Key] = $new
            $changed = $true
            Ok "$($spec.Key) -> $new"
        }

        $r = Test-MediaPath $new
        switch ($r.Status) {
            'ok'      { Dim "    [OK] $new" }
            'missing' {
                if (Ask-YesNo "    Folder doesn't exist. Create it now?" $true) {
                    try {
                        New-Item -ItemType Directory -Force -Path $new | Out-Null
                        Ok "    Created $new"
                    } catch {
                        Err "    Could not create: $($_.Exception.Message)"
                    }
                } else {
                    Dim "    Left it missing - the container will create it on first start, but you should verify the disk it lives on has enough space."
                }
            }
            'file'  { Err "    $new is a file, not a folder. Pick a different path." }
            'error' { Err "    $new is unreadable: $($r.Detail)" }
        }
        G ''
    }

    if ($changed) {
        Write-EnvFile $EnvFile $envMap
        Ok '.env updated.'
    } else {
        Dim '  No path values changed.'
    }

    # Recreate affected containers so the new bind mounts take effect. These
    # are every service in docker-compose.yml that mounts any of the 5 paths.
    $mediaContainers = @(
        'jellyfin','navidrome','immich-server','immich-machine-learning',
        'filebrowser','tor-browser','sonarr','radarr','qbittorrent'
    )
    $running = @()
    foreach ($c in $mediaContainers) {
        $state = & docker inspect -f '{{.State.Running}}' $c 2>$null
        if ($state -eq 'true') { $running += $c }
    }
    if ($running.Count -gt 0) {
        G ''
        Dim "  Containers currently using these paths: $($running -join ', ')"
        Dim '  Bind mounts only refresh when a container is recreated.'
        if (Ask-YesNo '  Recreate them now so the new paths take effect?' $changed) {
            Push-Location $ProjectRoot
            try {
                # --force-recreate drops + recreates with the new mounts.
                & docker compose --progress plain up -d --force-recreate @running
                Ok 'Containers recreated.'
            } catch {
                Err "docker compose up failed: $($_.Exception.Message)"
            } finally {
                Pop-Location
            }
        } else {
            Dim '  Skipped. Run [3] Stop Stack then [2] Start Stack later to apply.'
        }
    } else {
        Dim '  No media containers are currently running - new paths will apply next time you Start Stack.'
    }
}

# ---------------------------------------------------------------------------
# Backup + restore. The unit of backup is a SELF-CONTAINED FOLDER on disk,
# not a single archive - easier to inspect, easier to drop on a USB drive,
# and the user can delete pieces (e.g. drop images.tar to save space and
# re-pull from registries on restore).
#
# Layout of a backup folder:
#   <root>/
#     images.tar               (docker save of every stack image)
#     volumes/<name>.tar.gz    (one per docker named volume)
#     persistent-storage.tar.gz (files/persistent-storage/, the bind mounts)
#     .env                     (secrets, paths, API keys)
#     .wizard-state.json       (profile choices, GPU mode)
#     MANIFEST.txt             (timestamp, host, list of contents)
#
# All archive ops run inside a throw-away `alpine` container so the format
# is identical on Windows/macOS/Linux without depending on host tar.exe.
# ---------------------------------------------------------------------------

# Resolve docker-compose with EVERY known profile active so the output
# includes services + named volumes from all of them. `docker compose
# config` filters by active profile otherwise - and "no profile" matches
# only the always-on core, missing 90% of the stack.
function Get-FullComposeConfig {
    Push-Location $ProjectRoot
    try {
        $args = @('compose')
        foreach ($p in @('ai','media','media-stream','media-request','productivity','tunnel')) {
            $args += @('--profile', $p)
        }
        $args += @('config','--format','json')
        $cfgJson = & docker @args 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $cfgJson) { return $null }
        return $cfgJson | ConvertFrom-Json
    } finally {
        Pop-Location
    }
}

# List every image referenced by docker-compose.yml that is actually
# pulled locally. Returns @() if compose config fails (e.g. no .env).
# IMPORTANT: each GPU overlay (nvidia/amd/native) can swap a service's
# image tag - e.g. immich-machine-learning swaps to ":v2.7.5-cuda" on
# nvidia hosts. If we only read the base file we MISS those variants,
# the backup omits them, and restore quietly re-pulls them from the
# registry. Union the image list across base + every overlay so the
# backup captures whichever variant is actually running.
function Get-StackImages {
    $declared = @{}
    $overlays = @('','docker-compose.nvidia.yml','docker-compose.amd.yml','docker-compose.ollama-native.yml')

    Push-Location $ProjectRoot
    try {
        foreach ($overlay in $overlays) {
            $args = @('compose','-f','docker-compose.yml')
            if ($overlay -and (Test-Path (Join-Path $ProjectRoot $overlay))) {
                $args += @('-f', $overlay)
            }
            foreach ($p in @('ai','media','media-stream','media-request','productivity','tunnel')) {
                $args += @('--profile', $p)
            }
            $args += @('config','--format','json')
            $cfgJson = & docker @args 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $cfgJson) { continue }
            $cfg = $cfgJson | ConvertFrom-Json
            foreach ($s in $cfg.services.PSObject.Properties) {
                if ($s.Value.image) { $declared[$s.Value.image] = $true }
            }
        }
    } finally {
        Pop-Location
    }

    $local = @{}
    & docker image ls --format '{{.Repository}}:{{.Tag}}' 2>$null | ForEach-Object {
        if ($_) { $local[$_] = $true }
    }
    return @($declared.Keys | Sort-Object | Where-Object { $local.ContainsKey($_) })
}

# Get a (declared, local) tuple for the images Compose would pull right
# now, scoped to the active profiles + custom services. Used to detect
# the "all already cached" case so we can skip the pull phase entirely.
# Returns @{ Declared = @(...); Local = @(...); Missing = @(...) }.
function Get-StackImageStatus {
    param(
        [string[]]$Profiles       = @(),
        [string[]]$CustomServices = @(),
        [string]$GpuMode          = 'cpu'
    )
    Push-Location $ProjectRoot
    try {
        $args = @('compose','-f','docker-compose.yml')
        switch ($GpuMode) {
            'nvidia' { $args += @('-f','docker-compose.nvidia.yml') }
            'amd'    { $args += @('-f','docker-compose.amd.yml') }
            'native' { $args += @('-f','docker-compose.ollama-native.yml') }
        }
        if ($CustomServices.Count -gt 0) {
            # CUSTOM mode bypasses --profile; pass the services positionally
            # to `config` so only their stanzas are resolved.
            $args += @('config','--format','json')
            $args += $CustomServices
        } else {
            foreach ($p in $Profiles) { $args += @('--profile', $p) }
            $args += @('config','--format','json')
        }
        $cfgJson = & docker @args 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $cfgJson) {
            return @{ Declared = @(); Local = @(); Missing = @() }
        }
        $cfg = $cfgJson | ConvertFrom-Json
        $declared = @()
        foreach ($s in $cfg.services.PSObject.Properties) {
            if ($s.Value.image) { $declared += $s.Value.image }
        }
        $declared = $declared | Sort-Object -Unique

        $local = @{}
        & docker image ls --format '{{.Repository}}:{{.Tag}}' 2>$null | ForEach-Object {
            if ($_) { $local[$_] = $true }
        }
        $present = @($declared | Where-Object { $local.ContainsKey($_) })
        $missing = @($declared | Where-Object { -not $local.ContainsKey($_) })
        return @{ Declared = $declared; Local = $present; Missing = $missing }
    } finally {
        Pop-Location
    }
}

# Compose-prefixed name of every named volume declared in docker-compose.yml
# that actually exists on the daemon.
function Get-StackVolumes {
    $cfg = Get-FullComposeConfig
    if (-not $cfg) { return @() }
    $names = @()
    if ($cfg.volumes) {
        foreach ($v in $cfg.volumes.PSObject.Properties) { $names += $v.Name }
    }
    $project = $cfg.name
    if (-not $project) { $project = (Split-Path $ProjectRoot -Leaf).ToLower() -replace '[^a-z0-9_-]','' }

    $existing = @{}
    & docker volume ls --format '{{.Name}}' 2>$null | ForEach-Object {
        if ($_) { $existing[$_] = $true }
    }
    return @($names | ForEach-Object {
        $full = "${project}_$_"
        if ($existing.ContainsKey($full)) { $full }
    })
}

# Scan the default backup root (<repoRoot>/backups/) for subfolders that
# look like real EISA Homelab backups - i.e. they contain a MANIFEST.txt.
# Returns @() when the root doesn't exist or no valid backup is inside.
function Get-LocalBackupFolders {
    $repoRoot = Split-Path $ProjectRoot -Parent
    $root = Join-Path $repoRoot 'backups'
    if (-not (Test-Path $root)) { return @() }
    $candidates = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue
    return @($candidates | Where-Object { Test-Path (Join-Path $_.FullName 'MANIFEST.txt') } | Sort-Object Name -Descending)
}

function Invoke-BackupStack {
    param(
        [ValidateSet('','full','images-volumes','images','volumes')]
        [string]$Mode = ''
    )
    $repoRoot = Split-Path $ProjectRoot -Parent
    if (-not $BackupPath) {
        $stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
        $BackupPath = Join-Path $repoRoot "backups/eisa-homelab-backup-$stamp"
    }

    Step 'Backup EISA Homelab' "Destination: $BackupPath"

    # Mode picker. Only 'full' bundles .env + state, so only 'full'
    # short-circuits the first-run wizard on restore. The other three
    # modes always let the wizard run through normally; the cached
    # artifacts (images / volumes / both) just make it faster.
    if (-not $Mode) {
        Dim '  What to include in this backup?'
        G  ''
        $modePick = Ask-Choice @(
            [pscustomobject]@{
                Label = 'Backup everything       (identical clone to another PC/Mac)'
                Hint  = @(
                    'images + named volumes + persistent-storage + .env + state.'
                    'On restore: wizard is SKIPPED, stack starts with the saved'
                    'config - identical to the source machine.'
                )
            }
            [pscustomobject]@{
                Label = 'Backup images + volumes (no .env - wizard runs fresh)'
                Hint  = @(
                    'images + named volumes + persistent-storage. NO .env / state.'
                    'On restore: first-run wizard runs normally; secrets are'
                    'regenerated, paths are re-asked. Compose pull is instant'
                    'because every image is already in the cache.'
                    'Caveat: regenerated secrets break n8n encrypted workflows'
                    'in postgres if you keep the n8n volume.'
                )
            }
            [pscustomobject]@{
                Label = 'Backup images only'
                Hint  = @(
                    'Just images.tar (no user data, no secrets).'
                    'On restore: wizard runs normally; compose pull is instant.'
                )
            }
            [pscustomobject]@{
                Label = 'Backup volumes only'
                Hint  = @(
                    'Named volumes + persistent-storage. NO images, NO .env.'
                    'On restore: wizard runs normally; compose re-pulls every'
                    'image from its registry (the slow part).'
                )
            }
        )
        $Mode = switch ($modePick) {
            1 { 'full' }
            2 { 'images-volumes' }
            3 { 'images' }
            4 { 'volumes' }
        }
        G ''
    }

    $doImages  = $Mode -in @('full','images-volumes','images')
    $doVolumes = $Mode -in @('full','images-volumes','volumes')   # named volumes + persistent-storage
    $doEnv     = $Mode -eq 'full'                                 # .env + state - only the full clone keeps these

    $modeDesc = @{
        'full'           = 'images + volumes + persistent-storage + .env + state'
        'images-volumes' = 'images + volumes + persistent-storage (no .env / state)'
        'images'         = 'just docker images.tar'
        'volumes'        = 'volumes + persistent-storage (no images, no .env)'
    }[$Mode]
    Dim "  Mode: $Mode - $modeDesc"
    if ($doVolumes) {
        Dim '  Recommend stopping the stack first so volume snapshots are consistent.'
    }
    G  ''

    # Warn-and-confirm if the stack is running. Only relevant when we're
    # snapshotting volumes - images.tar is a pure docker-save of cached
    # layers and is unaffected by whether containers are running.
    if ($doVolumes) {
        $running = @()
        & docker ps --format '{{.Names}}' 2>$null | ForEach-Object { if ($_) { $running += $_ } }
        if ($running.Count -gt 0) {
            Dim "  Stack appears to be running ($($running.Count) container(s)). Volumes backed up while postgres / sqlite are writing can be inconsistent."
            if (Ask-YesNo '  Stop the stack now for a clean backup? (recommended)' $true) {
                Push-Location $ProjectRoot
                try {
                    & docker compose --progress plain down -t 10
                } finally { Pop-Location }
            }
        }
    }

    New-Item -ItemType Directory -Force -Path $BackupPath | Out-Null
    if ($doVolumes) {
        New-Item -ItemType Directory -Force -Path (Join-Path $BackupPath 'volumes') | Out-Null
    }

    # 1) Save images.
    $imgs = @()
    if ($doImages) {
        $imgs = Get-StackImages
        if ($imgs.Count -eq 0) {
            Dim '  No locally-pulled stack images found - skipping image save.'
        } else {
            Ok "Saving $($imgs.Count) image(s) to images.tar - this is the big one, can take a few minutes."
            $imagesTar = Join-Path $BackupPath 'images.tar'
            & docker save -o $imagesTar @imgs
            if ($LASTEXITCODE -ne 0) {
                Err "docker save failed (exit $LASTEXITCODE)."
            } else {
                $size = [math]::Round((Get-Item $imagesTar).Length / 1GB, 2)
                Ok "images.tar written ($size GB)."
            }
        }
    }

    # 2) Save named volumes via an alpine helper container.
    $vols = @()
    if ($doVolumes) {
        $vols = Get-StackVolumes
        if ($vols.Count -eq 0) {
            Dim '  No named volumes found - nothing to back up.'
        } else {
            Ok "Archiving $($vols.Count) named volume(s) via alpine tar..."
            $volBackupDir = (Resolve-Path (Join-Path $BackupPath 'volumes')).Path
            foreach ($v in $vols) {
                $short = ($v -replace '^[^_]+_','')
                Dim "    -> $v"
                & docker run --rm `
                    -v "${v}:/source:ro" `
                    -v "${volBackupDir}:/backup" `
                    alpine sh -c "tar czf /backup/${short}.tar.gz -C /source ." 2>$null
                if ($LASTEXITCODE -ne 0) {
                    Err "    tar failed for volume $v"
                }
            }
            Ok 'Volumes archived.'
        }
    }

    # 3) Tar persistent-storage via alpine (the project lives at $ProjectRoot
    #    which is files/, persistent-storage is at $ProjectRoot/persistent-storage).
    if ($doVolumes) {
        $psSrc = Join-Path $ProjectRoot 'persistent-storage'
        if (Test-Path $psSrc) {
            Ok 'Archiving persistent-storage (configs, postgres data, *arr state)...'
            $psBackup = (Resolve-Path $BackupPath).Path
            $psSrcAbs = (Resolve-Path $psSrc).Path
            & docker run --rm `
                -v "${psSrcAbs}:/source:ro" `
                -v "${psBackup}:/backup" `
                alpine sh -c 'tar czf /backup/persistent-storage.tar.gz -C /source .' 2>$null
            if ($LASTEXITCODE -ne 0) {
                Err '  persistent-storage tar failed.'
            } else {
                Ok 'persistent-storage.tar.gz written.'
            }
        } else {
            Dim '  No persistent-storage folder yet - skipping.'
        }
    }

    # 4) Copy .env + .wizard-state.json. Skipped for images-only and
    # no-env modes - the .env carries the user's secrets and the state
    # file makes the first-run wizard auto-skip, which is undesirable
    # for the "ship this backup to someone else" use case.
    if ($doEnv) {
        if (Test-Path $EnvFile)   { Copy-Item $EnvFile   (Join-Path $BackupPath '.env')              -Force }
        if (Test-Path $StateFile) { Copy-Item $StateFile (Join-Path $BackupPath '.wizard-state.json') -Force }
    }

    # 5) Manifest.
    $bundled = @()
    if ($doImages -and $imgs.Count -gt 0) { $bundled += 'images.tar' }
    if ($doVolumes) {
        $bundled += @('volumes/*.tar.gz', 'persistent-storage.tar.gz')
    }
    if ($doEnv) {
        $bundled += @('.env', '.wizard-state.json')
    }
    $manifest = @(
        "EISA Homelab backup"
        "Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
        "Host:    $env:COMPUTERNAME$([Environment]::MachineName)"
        "Project: $ProjectRoot"
        "Mode:    $Mode"
        ""
        "Images saved: $($imgs.Count)"
        ($imgs | ForEach-Object { "  $_" })
        ""
        "Volumes saved: $($vols.Count)"
        ($vols | ForEach-Object { "  $_" })
        ""
        "Bundled: $($bundled -join ', ')"
    ) -join "`n"
    Set-Content -Path (Join-Path $BackupPath 'MANIFEST.txt') -Value $manifest -Encoding UTF8

    G ''
    Ok "Backup complete: $BackupPath"
    Dim '  Copy this folder to any drive/USB/cloud sync. To restore on another machine:'
    Dim '    1. clone this repo there'
    Dim '    2. run the manager -> [7] Backup / Restore -> [2] Restore from a backup folder'
}

function Invoke-RestoreStack {
    param([string]$Path)
    if (-not $Path) { $Path = $RestorePath }
    if (-not $Path) {
        Step 'Restore EISA Homelab from a backup folder' ''
        # Offer the most recent local backup as the default so the user
        # can just hit Enter when they know they want it.
        $local = @(Get-LocalBackupFolders)
        $default = if ($local.Count -gt 0) { $local[0].FullName } else { '' }
        $Path = Ask 'Path to the backup folder' $default -AllowEmpty
    }
    $path = $Path
    if (-not $path) {
        Err 'No path provided - aborting.'
        return $false
    }
    if (-not (Test-Path $path)) {
        Err "Folder not found: $path"
        return $false
    }
    $path = (Resolve-Path $path).Path

    $manifest = Join-Path $path 'MANIFEST.txt'
    if (-not (Test-Path $manifest)) {
        Err "Not an EISA Homelab backup folder (missing MANIFEST.txt): $path"
        return $false
    }

    Step 'Restoring from backup' $path
    Dim '  This will replace your current docker images, named volumes, persistent-storage folder, and .env. Stopping the stack first.'
    if (-not (Ask-YesNo '  Proceed?' $true)) { return $false }

    Push-Location $ProjectRoot
    try {
        & docker compose --progress plain down -t 10 2>$null
    } finally { Pop-Location }

    # 1) Load images.
    $imagesTar = Join-Path $path 'images.tar'
    if (Test-Path $imagesTar) {
        Ok 'Loading images via docker load - this is the long step.'
        & docker load -i $imagesTar
        if ($LASTEXITCODE -ne 0) { Err 'docker load failed.' } else { Ok 'Images loaded.' }
    } else {
        Dim '  images.tar not in backup - images will be pulled from registries when the stack starts.'
    }

    # 2) Restore named volumes.
    $volDir = Join-Path $path 'volumes'
    if (Test-Path $volDir) {
        # Figure out the project name so we re-create volumes with the
        # right prefix.
        Push-Location $ProjectRoot
        try {
            $cfgJson = & docker compose config --format json 2>$null
            $cfg = if ($cfgJson) { $cfgJson | ConvertFrom-Json } else { $null }
        } finally { Pop-Location }
        $project = if ($cfg -and $cfg.name) { $cfg.name } else { (Split-Path $ProjectRoot -Leaf).ToLower() -replace '[^a-z0-9_-]','' }

        $tarsAbs = (Resolve-Path $volDir).Path
        Get-ChildItem $volDir -Filter '*.tar.gz' -ErrorAction SilentlyContinue | ForEach-Object {
            $short = $_.BaseName -replace '\.tar$',''
            $full  = "${project}_$short"
            Dim "    <- $full"
            & docker volume create $full 2>$null | Out-Null
            & docker run --rm `
                -v "${full}:/target" `
                -v "${tarsAbs}:/backup:ro" `
                alpine sh -c "cd /target && tar xzf /backup/$($_.Name)" 2>$null
            if ($LASTEXITCODE -ne 0) { Err "    restore failed for $full" }
        }
        Ok 'Volumes restored.'
    } else {
        Dim '  No volumes/ in backup - skipping named-volume restore.'
    }

    # 3) Restore persistent-storage.
    $psTar = Join-Path $path 'persistent-storage.tar.gz'
    if (Test-Path $psTar) {
        $psDest = Join-Path $ProjectRoot 'persistent-storage'
        New-Item -ItemType Directory -Force -Path $psDest | Out-Null
        $psDestAbs = (Resolve-Path $psDest).Path
        $psTarAbs  = (Resolve-Path $psTar).Path
        # Copy the tar.gz into a temp container-visible dir, then unpack
        # into the bind-mounted target. We bind the .tar.gz's parent dir
        # read-only.
        $tarDirAbs = Split-Path $psTarAbs -Parent
        & docker run --rm `
            -v "${psDestAbs}:/target" `
            -v "${tarDirAbs}:/backup:ro" `
            alpine sh -c 'cd /target && tar xzf /backup/persistent-storage.tar.gz' 2>$null
        if ($LASTEXITCODE -ne 0) {
            Err '  persistent-storage extract failed.'
        } else {
            Ok 'persistent-storage restored.'
        }
    } else {
        Dim '  No persistent-storage.tar.gz in backup - keeping current contents (if any).'
    }

    # 4) Restore .env + .wizard-state.json.
    $bkEnv     = Join-Path $path '.env'
    $bkState   = Join-Path $path '.wizard-state.json'
    $envRestored = $false
    if (Test-Path $bkEnv)   { Copy-Item $bkEnv   $EnvFile   -Force; Ok '.env restored.'; $envRestored = $true }
    if (Test-Path $bkState) { Copy-Item $bkState $StateFile -Force; Ok '.wizard-state.json restored.' }

    G ''
    if ($envRestored) {
        Ok 'Restore complete. The stack will come up with the images, volumes, and settings from the backup.'
    } else {
        Ok 'Image cache loaded from backup. (.env was not in this backup - wizard will continue so you can configure the stack.)'
    }
    return [pscustomobject]@{ Success = $true; EnvRestored = $envRestored }
}

# ---------------------------------------------------------------------------
# The first-run wizard.
# ---------------------------------------------------------------------------
function Invoke-Wizard {
    # ---- Step 0: restore from a backup? -----------------------------------
    # Only shown when at least one valid EISA Homelab backup is detected
    # in <repoRoot>/backups/. On fresh clones with nothing to restore from
    # we skip the question entirely - no point asking.
    $foundBackups = @(Get-LocalBackupFolders)
    if ($foundBackups.Count -gt 0) {
        Step 'Step 0 - Restore from a previous backup?' "Detected $($foundBackups.Count) backup folder(s) in backups/. You can either load one of them now (skipping the rest of the wizard) or start fresh."
        Dim '  Found:'
        foreach ($b in $foundBackups | Select-Object -First 5) {
            Dim "    $($b.Name)"
        }
        if ($foundBackups.Count -gt 5) { Dim "    … and $($foundBackups.Count - 5) more" }
        G ''

        $restoreChoice = Ask-Choice @(
            [pscustomobject]@{
                Label = 'Start fresh - pull images from the internet (recommended)'
                Hint  = @(
                    'Normal first-run flow. The wizard will ask questions and bring',
                    'up a clean stack, pulling every container image from its registry.'
                )
            }
            [pscustomobject]@{
                Label = "Restore from $($foundBackups[0].Name)"
                Hint  = @(
                    'Skip the rest of the wizard, load saved images + volumes +',
                    'persistent-storage from the most recent backup folder, and',
                    'bring the stack up exactly like it was on the source machine.',
                    'For other backup paths, use the manager menu [7] Restore.'
                )
            }
        )
        if ($restoreChoice -eq 2) {
            # Pre-fill the restore path so the user isn't asked again.
            $restoreResult = Invoke-RestoreStack -Path $foundBackups[0].FullName
            if ($restoreResult -and $restoreResult.Success) {
                if ($restoreResult.EnvRestored) {
                    # Full restore: .env + state came back, the wizard has
                    # nothing left to ask. Short-circuit straight to start.
                    return [pscustomobject]@{ Restored = $true }
                } else {
                    # Images-only restore: the cache is now warm but .env
                    # is still empty. Fall through to the regular wizard
                    # so the user can pick stack/paths/GPU/etc., and the
                    # subsequent compose pull will be a no-op (images
                    # already loaded).
                    G ''
                    Dim '  Continuing with the wizard - your image cache is pre-populated, so the pull phase will be instant.'
                    G ''
                }
            } else {
                Dim '  Restore failed or was aborted - falling through to a clean install.'
            }
        }
    }

    # Bootstrap .env from .env.example if missing.
    if (-not (Test-Path $EnvFile)) {
        Copy-Item $EnvExample $EnvFile
    }
    $envMap     = Read-EnvFile $EnvFile
    $exampleMap = Read-EnvFile $EnvExample
    foreach ($k in $exampleMap.Keys) {
        if (-not $envMap.Contains($k)) { $envMap[$k] = $exampleMap[$k] }
    }

    # ---- Step 0b: existing configuration detected? ------------------------
    # A populated .env (real secrets or a configured domain, not the
    # .env.example placeholders) means this clone already has a working
    # config. Offer to keep it and just pick what to start, instead of
    # re-asking everything (which could clobber the saved DOMAIN / tunnel
    # token). -Reconfigure forces the full wizard.
    $useExisting = $false
    if ((Test-ConfiguredEnv $envMap) -and -not $Reconfigure) {
        Step 'Existing configuration detected' 'This clone already has a filled-in .env (domain, secrets, media paths). You can keep it and just pick what to start, or reconfigure everything from scratch.'
        $hostLine = if (-not (Test-Placeholder $envMap['CLOUDFLARE_TUNNEL_TOKEN'])) {
            "ONLINE via $($envMap['DOMAIN'])"
        } else { 'LOCAL only (no domain / tunnel)' }
        Dim "    Hosting       : $hostLine"
        Dim "    Heimdall tiles: $(if ($envMap['HEIMDALL_TILE_DOMAIN']) { 'https://*.' + $envMap['HEIMDALL_TILE_DOMAIN'] } else { 'http://*.localhost' })"
        Dim "    Media folders : $($envMap['MOVIES_PATH']), $($envMap['TV_SHOWS_PATH']), $($envMap['MUSIC_PATH']), ..."
        Dim "    Secrets       : present (databases, n8n, *arr API keys, Hermes)"
        G ''
        $cfgChoice = Ask-Choice @(
            [pscustomobject]@{
                Label = 'Use my existing configuration (recommended)'
                Hint  = @(
                    'Keep the current domain, secrets, and media paths as-is.'
                    'You will only pick which apps to start next - no other questions.'
                )
            }
            [pscustomobject]@{
                Label = 'Reconfigure from scratch'
                Hint  = @(
                    'Walk through every question again (hosting, paths, GPU).'
                    'Existing non-placeholder secrets are still preserved.'
                )
            }
        )
        $useExisting = ($cfgChoice -eq 1)
    }

    # ---- Step 1: stack ----------------------------------------------------
    Step 'Step 1 - Pick what to install' 'Each option starts a different set of containers. You can re-run the first-run launcher to change later.'
    Dim '  Always installed (the core):'
    Dim '    Heimdall   start page'
    Dim '    Caddy      reverse proxy'
    Dim '    Authelia   SSO gateway'
    Dim '    Portainer  Docker UI'
    G ''
    $stackPick = Ask-Choice @(
        [pscustomobject]@{
            Label = 'AI'
            Hint  = @(
                'ollama              local LLMs'
                'open-webui          chat interface'
                'searxng             private search'
                'local-deep-research AI research'
                'vane                answer engine'
                'n8n + postgres      workflow automation'
                'qdrant              vector database'
            )
        }
        [pscustomobject]@{
            Label = 'MEDIA STREAMING STACK'
            Hint  = @(
                'jellyfin            movie + TV streaming'
                'navidrome           music streaming'
                'immich              photo + video library'
            )
        }
        [pscustomobject]@{
            Label = 'MEDIA REQUEST STACK'
            Hint  = @(
                'seerr               request UI for movies/TV'
                'sonarr              TV automation'
                'radarr              movie automation'
                'prowlarr            indexer manager'
                'qbittorrent         torrent download client'
            )
        }
        [pscustomobject]@{
            Label = 'PRODUCTIVITY (utilities only)'
            Hint  = @(
                'filebrowser         file manager'
                'omni-tools          web utilities'
                'tor-browser         anonymous browser'
            )
        }
        [pscustomobject]@{
            Label = 'ULTIMATE (everything - recommended)'
            Hint  = @(
                'Everything from AI + MEDIA STREAMING + MEDIA REQUEST + PRODUCTIVITY.'
            )
            Warning = 'Online pull takes ~45 min on average to fetch every image (one-time, depends on your connection).'
        }
        [pscustomobject]@{
            Label = 'CUSTOM (pick individual apps)'
            Hint  = @(
                'Show a checklist of every app and let me choose exactly'
                'which ones to start.'
            )
        }
    )

    $customServices = @()
    $profiles       = @()
    $stack          = switch ($stackPick) {
        1 { 'ai' }
        2 { 'media-streaming' }
        3 { 'media-request' }
        4 { 'productivity' }
        5 { 'ultimate' }
        6 { 'custom' }
    }
    switch ($stack) {
        'ai'              { $profiles = @('ai') }
        'media-streaming' { $profiles = @('media-stream') }
        'media-request'   { $profiles = @('media-request') }
        'productivity'    { $profiles = @('productivity') }
        'ultimate'        { $profiles = @('ai','media') }
        'custom'          {
            $customServices = Invoke-CustomServicePicker
            if (-not $customServices -or $customServices.Count -eq 0) {
                Dim '  No apps picked - defaulting to ULTIMATE.'
                $stack    = 'ultimate'
                $profiles = @('ai','media')
                $customServices = @()
            }
        }
    }

    # Optional trim step for bundle picks. If the user wants every app in
    # the bundle they pressed (the common case), this is one Enter - no
    # disruption. If they want to drop a few (e.g. skip Vane + Tor in
    # ULTIMATE), the trimmer returns the kept-services list and we switch
    # to customServices mode so Start-Stack lists them positionally instead
    # of activating a profile (profiles are all-or-nothing).
    if ($stack -in @('ai','media-streaming','media-request','productivity','ultimate')) {
        $kept = Invoke-StackTrimmer -Stack $stack
        if ($kept) {
            $customServices = $kept
            $profiles       = @()
        }
    }

    # Compatibility flags surfaced in the summary / state blob.
    $aiServices    = @('ollama','open-webui','searxng','local-deep-research','vane','n8n','n8n-postgres','qdrant','hermes-agent')
    $mediaServices = @('jellyfin','navidrome','immich-server','immich-machine-learning','immich-redis','immich-postgres','filebrowser','omni-tools','tor-browser','seerr','sonarr','radarr','prowlarr','qbittorrent')
    $hasAi    = ($profiles -contains 'ai') -or `
                ($customServices | Where-Object { $_ -in $aiServices }).Count -gt 0
    $hasMedia = ($profiles -contains 'media') -or ($profiles -contains 'media-stream') -or ($profiles -contains 'media-request') -or ($profiles -contains 'productivity') -or `
                ($customServices | Where-Object { $_ -in $mediaServices }).Count -gt 0
    Ok "Stack: $($stack.ToUpper())$(if ($customServices.Count -gt 0) { " (trimmed to $($customServices.Count) services)" })"

    # ---- Use existing config: stack picked, skip the rest of the wizard --
    # Everything below (hosting, Heimdall tiles, media paths, secrets) is
    # taken from the current .env untouched. GPU mode isn't stored in .env,
    # so auto-detect it like Start Stack does rather than prompt.
    if ($useExisting) {
        $useTunnel = -not (Test-Placeholder $envMap['CLOUDFLARE_TUNNEL_TOKEN'])
        $gpuMode   = if ($hasAi) { Get-OllamaGpuMode -OS $script:OS } else { 'cpu' }
        Ok ("Access (kept from .env): " + ($(if ($useTunnel) { "ONLINE ($($envMap['DOMAIN']))" } else { 'LOCAL only' })))
        if ($hasAi) { Ok "GPU mode: $($gpuMode.ToUpper()) (auto-detected)" }
        # Top up only placeholder secrets; real values are left as they are.
        if (Ensure-EnvSecrets -EnvMap $envMap) { Write-EnvFile $EnvFile $envMap }
        return [pscustomobject]@{
            Env            = $envMap
            Stack          = $stack
            Profiles       = $profiles
            CustomServices = $customServices
            UseTunnel      = $useTunnel
            HasAi          = $hasAi
            HasMedia       = $hasMedia
            GpuMode        = $gpuMode
        }
    }

    # ---- Step 2: access mode ---------------------------------------------
    Step 'Step 2 - Hosting: local or online?' 'This decides whether your stack lives only on your LAN, or is reachable from anywhere on the internet through your own domain.'
    $accessPick = Ask-Choice @(
        [pscustomobject]@{
            Label = 'LOCAL HOSTING (recommended - safe default)'
            Hint  = @(
                'Apps reachable at http://localhost:PORT on this machine'
                'and on your LAN. Nothing exposed to the public internet.'
                'No domain, no Cloudflare account, no SSO required.'
            )
        }
        [pscustomobject]@{
            Label = 'ONLINE HOSTING via Cloudflare tunnel'
            Hint  = @(
                'Apps reachable from anywhere at chat.yourdomain.com,'
                'movie.yourdomain.com, etc. Gated by Authelia SSO.'
                'Requires: a domain on Cloudflare + a free tunnel'
                'token from https://dash.cloudflare.com/.'
            )
        }
    )
    $useTunnel = ($accessPick -eq 2)

    if ($useTunnel) {
        Step 'Step 2a - Cloudflare tunnel setup (walkthrough)' 'This wizard installs cloudflared automatically. You only need to grab a token from Cloudflare and tell us your domain.'
        G  '  PART A - Get your tunnel token (you do this now in your browser):'
        G  ''
        Dim '    1) Open  https://dash.cloudflare.com/'
        Dim '    2) Left sidebar:  Networks  ->  Tunnels'
        Dim '    3) Click  "Create a tunnel"'
        Dim '    4) Connector type:  Cloudflared'
        Dim '    5) Name your tunnel  (anything, e.g. "homelab")'
        Dim '    6) Click  "Save tunnel"'
        Dim '    7) The next page shows install commands - IGNORE THEM.'
        Dim '       We run cloudflared in Docker; we only need the token.'
        Dim '    8) Find the long string after `--token` in the install command'
        Dim '       (~150 chars, starts with "ey..."). That is your token.'
        Dim '    9) Copy ONLY the token (not the whole `cloudflared service`'
        Dim '       command), then paste it below.'
        G  ''
        Dim '  PART B comes after the stack is up - you will get instructions'
        Dim '  for adding Public Hostnames in Cloudflare so your subdomains'
        Dim '  actually route to the stack.'
        G  ''
        if (Ask-YesNo '  Open https://dash.cloudflare.com/ in your browser now?' $true) {
            Open-Browser 'https://dash.cloudflare.com/'
        }
        G  ''
        $envMap['DOMAIN']                  = Ask 'Your domain (e.g. example.com)' $envMap['DOMAIN']
        $envMap['CLOUDFLARE_TUNNEL_TOKEN'] = Ask 'Cloudflare tunnel token' $envMap['CLOUDFLARE_TUNNEL_TOKEN'] -Secret
    } else {
        $envMap['DOMAIN']                  = ''
        $envMap['CLOUDFLARE_TUNNEL_TOKEN'] = ''
    }
    Ok ("Access: " + ($(if ($useTunnel) { "ONLINE ($($envMap['DOMAIN']))" } else { 'LOCAL only' })))

    # ---- Step 2b: Heimdall start-page tile URLs --------------------------
    # Heimdall ships a curated set of dashboard tiles whose URLs all point at
    # the maintainer's domain. We give the user one chance, here, to put
    # their own domain in - or leave blank for localhost-only mode.
    # The actual SQL rewrite runs later in Ensure-HeimdallTiles and is
    # idempotent: it only fires while the placeholder URLs are still in the
    # DB, so re-runs and user customizations are safe.
    Step 'Step 2b - Heimdall start-page tiles' 'Tell us where the dashboard tiles should point. We rewrite them only once, the first time we see the placeholder URLs.'
    G  '  Type the domain you want your dashboard tiles to use, or leave blank'
    G  '  for local-only mode. In local mode tiles use http://<sub>.localhost'
    G  '  URLs which auto-resolve to 127.0.0.1 in every modern browser - Caddy'
    G  '  proxies them to the right container on port 80.'
    G  ''
    Dim '    With "example.com":  https://chat.example.com, https://movie.example.com, ...'
    Dim '    Blank (local-only):  http://chat.localhost, http://photos.localhost, http://movie.localhost ...'
    G  ''
    $tileDefault = if (-not (Test-Placeholder $envMap['HEIMDALL_TILE_DOMAIN'])) {
        $envMap['HEIMDALL_TILE_DOMAIN']
    } elseif ($envMap['DOMAIN']) {
        $envMap['DOMAIN']
    } else { '' }
    $envMap['HEIMDALL_TILE_DOMAIN'] = Ask 'Domain for Heimdall tiles (blank = *.localhost)' $tileDefault -AllowEmpty
    if ($envMap['HEIMDALL_TILE_DOMAIN']) {
        Ok ("Heimdall tiles  ->  https://*." + $envMap['HEIMDALL_TILE_DOMAIN'])
    } else {
        Ok 'Heimdall tiles  ->  http://*.localhost (local-only, via Caddy)'
    }

    # ---- Step 3: persistent storage --------------------------------------
    if (Test-Placeholder $envMap['PERSISTENT_STORAGE']) {
        $envMap['PERSISTENT_STORAGE'] = './persistent-storage'
    }

    # ---- Step 4: media folders (only if media stack) ---------------------
    if ($hasMedia) {
        if ($script:OS -eq 'Mac') {
            $pathHint = 'Type the full path to each folder. Examples: ~/Documents/MEDIA/Movies, /Volumes/Media/Movies'
            # If the defaults still look Windows-y, swap to sensible Mac defaults.
            $homePath = $HOME
            foreach ($k in @('MOVIES_PATH','TV_SHOWS_PATH','MUSIC_PATH','DOWNLOADS_PATH','PHOTOS_PATH')) {
                if (-not $envMap.Contains($k) -or $envMap[$k] -match '^[A-Za-z]:') {
                    $envMap[$k] = switch ($k) {
                        'MOVIES_PATH'    { "$homePath/Documents/MEDIA/Movies" }
                        'TV_SHOWS_PATH'  { "$homePath/Documents/MEDIA/TV-Shows" }
                        'MUSIC_PATH'     { "$homePath/Documents/MEDIA/Music" }
                        'DOWNLOADS_PATH' { "$homePath/Documents/MEDIA/Downloads" }
                        'PHOTOS_PATH'    { "$homePath/Documents/MEDIA/Photos" }
                    }
                }
            }
        } else {
            $pathHint = 'Type the full path to each folder. Examples: C:\MEDIA\Movies, D:\TV-Shows, C:/MEDIA/Music'
        }
        # Migrate any leftover legacy defaults from older installs to the
        # current per-OS defaults (Windows: C:/MEDIA/, Mac: ~/Documents/).
        # Only touches values that EXACTLY match an old default - never a
        # custom path the user typed in themselves.
        [void](Migrate-LegacyMediaDefaults $envMap)
        if (-not $envMap.Contains('PHOTOS_PATH') -or [string]::IsNullOrWhiteSpace($envMap['PHOTOS_PATH'])) {
            $envMap['PHOTOS_PATH'] = 'C:/MEDIA/Photos'
        }
        Step 'Step 3 - Your media folders' $pathHint
        $envMap['MOVIES_PATH']    = Format-Path (Ask 'MOVIES FOLDER LOCATION'    $envMap['MOVIES_PATH'])
        $envMap['TV_SHOWS_PATH']  = Format-Path (Ask 'TV SHOWS FOLDER LOCATION'  $envMap['TV_SHOWS_PATH'])
        $envMap['MUSIC_PATH']     = Format-Path (Ask 'MUSIC FOLDER LOCATION'     $envMap['MUSIC_PATH'])
        $envMap['DOWNLOADS_PATH'] = Format-Path (Ask 'DOWNLOADS FOLDER LOCATION' $envMap['DOWNLOADS_PATH'])
        $envMap['PHOTOS_PATH']    = Format-Path (Ask 'PHOTOS FOLDER LOCATION (Immich library)' $envMap['PHOTOS_PATH'])
        Ok 'Media folders saved.'
    }

    # ---- Step 3b: GPU acceleration for Ollama (only if AI in stack) ------
    $gpuMode = 'cpu'
    if ($hasAi) {
        $detected = Get-OllamaGpuMode -OS $script:OS
        Step 'Step 3b - GPU acceleration for Ollama' "We auto-detected your GPU as: $($detected.ToUpper()). You can override below if needed."

        # On macOS we offer a fifth option: run Ollama NATIVELY on the host
        # (Homebrew or ollama.app) so it uses Metal. Docker on Mac can't
        # pass Metal through to containers, so this is the only way to get
        # real GPU acceleration on Apple Silicon.
        if ($script:OS -eq 'Mac') {
            $gpuPick = Ask-Choice @(
                [pscustomobject]@{
                    Label = 'NATIVE Ollama on macOS (Metal-accelerated)  -- recommended for Apple Silicon'
                    Hint  = @(
                        'Skips the in-container ollama. Open WebUI, Local Deep Research,'
                        'and Vane will point at http://host.docker.internal:11434 so'
                        'Mac-native Ollama (using Metal) serves them. Massive speedup'
                        'on M1/M2/M3 vs containerised CPU.'
                        '  Setup: brew install ollama && brew services start ollama'
                        '  Verify: curl http://localhost:11434/api/tags'
                    )
                }
                [pscustomobject]@{
                    Label = 'CPU only (containerised ollama)'
                    Hint  = @(
                        'Runs ollama inside Docker on Mac. Works without any host'
                        'install but is much slower since the container cannot reach Metal.'
                    )
                }
            )
            $gpuMode = switch ($gpuPick) {
                1 { 'native' }
                2 { 'cpu' }
            }
        } else {
            $gpuPick = Ask-Choice @(
                [pscustomobject]@{
                    Label = "Use auto-detected: $($detected.ToUpper())"
                    Hint  = @(
                        'Recommended. Trust the detection unless you know better.'
                    )
                }
                [pscustomobject]@{
                    Label = 'NVIDIA (CUDA)'
                    Hint  = @(
                        'Requires NVIDIA driver + Docker Desktop "Enable GPU support",'
                        'or on Linux: nvidia-container-toolkit installed.'
                    )
                }
                [pscustomobject]@{
                    Label = 'AMD (ROCm) - Linux only'
                    Hint  = @(
                        'Requires ROCm-compatible AMD GPU + ROCm drivers on a Linux host.'
                        'Docker Desktop on Windows does NOT support AMD passthrough.'
                    )
                }
                [pscustomobject]@{
                    Label = 'CPU only'
                    Hint  = @(
                        'Works on every machine but slower. Use this if your GPU'
                        'is unsupported or you want predictable resource use.'
                    )
                }
            )
            $gpuMode = switch ($gpuPick) {
                1 { $detected }
                2 { 'nvidia' }
                3 { 'amd' }
                4 { 'cpu' }
            }
        }
        Ok "GPU mode: $($gpuMode.ToUpper())"
    }

    # ---- Step 5: passwords + secrets -------------------------------------
    Step 'Step 4 - Secrets' 'Generating strong random keys for databases, n8n, and SSO. Nothing for you to type.'
    $genSpecs = @(
        @{ Key='POSTGRES_PASSWORD';              Bytes=24; Mode='hex' }
        @{ Key='N8N_ENCRYPTION_KEY';             Bytes=32; Mode='hex' }
        @{ Key='N8N_USER_MANAGEMENT_JWT_SECRET'; Bytes=32; Mode='hex' }
        @{ Key='NEXTAUTH_SECRET';                Bytes=32; Mode='b64' }
        @{ Key='LINKWARDEN_DB_PASSWORD';         Bytes=20; Mode='hex' }
        @{ Key='DB_PASSWORD';                    Bytes=20; Mode='hex' }
        @{ Key='TOR_VNC_PW';                     Bytes=12; Mode='hex' }
        @{ Key='SONARR_API_KEY';                 Bytes=16; Mode='hex' }
        @{ Key='RADARR_API_KEY';                 Bytes=16; Mode='hex' }
        @{ Key='PROWLARR_API_KEY';               Bytes=16; Mode='hex' }
        @{ Key='SEERR_API_KEY';                  Bytes=16; Mode='hex' }
        @{ Key='HERMES_API_KEY';                 Bytes=16; Mode='hex' }
        # JELLYFIN_ADMIN_PASSWORD intentionally omitted - see Default Credentials policy.
    )
    foreach ($s in $genSpecs) {
        if ($Reconfigure -or (Test-Placeholder $envMap[$s.Key])) {
            $envMap[$s.Key] = if ($s.Mode -eq 'hex') {
                New-HexSecret -Bytes $s.Bytes
            } else {
                New-Base64Secret -Bytes $s.Bytes
            }
        }
    }
    Ok 'Secrets generated.'

    # ---- write .env back -------------------------------------------------
    Write-EnvFile $EnvFile $envMap

    return [pscustomobject]@{
        Env             = $envMap
        Stack           = $stack
        Profiles        = $profiles
        CustomServices  = $customServices
        UseTunnel       = $useTunnel
        HasAi           = $hasAi
        HasMedia        = $hasMedia
        GpuMode         = $gpuMode
    }
}

# ---------------------------------------------------------------------------
# Template rendering (Caddy / Authelia / SearXNG).
# Kept logically identical to the previous wizard.
# ---------------------------------------------------------------------------
function Resolve-Template {
    param([string]$TemplatePath, [string]$OutputPath, $Env)
    if (-not (Test-Path $TemplatePath)) { return }
    $text = Get-Content $TemplatePath -Raw
    $text = $text.Replace('__SEARXNG_SECRET_KEY__',              [string]$Env['SEARXNG_SECRET_KEY'])
    $text = $text.Replace('__AUTHELIA_JWT_SECRET__',             [string]$Env['AUTHELIA_JWT_SECRET'])
    $text = $text.Replace('__AUTHELIA_STORAGE_ENCRYPTION_KEY__', [string]$Env['AUTHELIA_STORAGE_ENCRYPTION_KEY'])
    foreach ($k in $Env.Keys) {
        $needle = '${' + $k + '}'
        $text = $text.Replace($needle, [string]$Env[$k])
    }
    Set-Content -Path $OutputPath -Value $text -Encoding UTF8
}

function Write-LocalOnlyCaddyfile {
    param([string]$OutputPath, $Env)
    $torPw   = [string]$Env['TOR_VNC_PW']
    $torAuth = [string]$Env['TOR_BASIC_AUTH']
    $content = @"
# Caddy reverse proxy - LOCAL-ONLY MODE
# DOMAIN is empty in .env, so instead of *.<your-domain> we serve every
# service at http://<sub>.localhost. *.localhost auto-resolves to 127.0.0.1
# in all modern browsers + OSes (RFC 6761), so no hosts file, no DNS, no
# Cloudflare needed - just open http://photos.localhost, http://chat.localhost,
# etc., and Caddy on :80 proxies to the right container.
#
# LAN-only trust assumed - no Authelia gate on these routes. Switch to
# tunnel mode in the wizard (Step 2) if you want SSO + public access.

{
    auto_https off
    http_port 80
}

# ===== INFRASTRUCTURE =====
http://hub.localhost {
    reverse_proxy heimdall-media:80
}

http://portainer.localhost {
    reverse_proxy Portainer:9000
}

http://qdrant.localhost {
    reverse_proxy qdrant:6333
}

http://auth.localhost {
    reverse_proxy Authelia:9091
}

# ===== TOOLS =====
http://tool.localhost {
    reverse_proxy host.docker.internal:8890
}

http://search.localhost {
    reverse_proxy searxng:8080
}

# Tor zero-click auto-login (basic-auth injected, kasm form skipped).
http://tor.localhost {
    @root path /
    redir @root /vnc.html?username=kasm_user&password=$torPw&autoconnect=true&resize=remote 302
    reverse_proxy https://host.docker.internal:6901 {
        transport http {
            tls_insecure_skip_verify
        }
        header_up Authorization "Basic $torAuth"
    }
}

# ===== AI =====
http://chat.localhost {
    reverse_proxy host.docker.internal:9002
}

http://n8n.localhost {
    reverse_proxy host.docker.internal:5678
}

http://smartsearch.localhost {
    reverse_proxy vane:3000
}

http://research.localhost {
    reverse_proxy local-deep-research:5000
}

http://hermes.localhost {
    reverse_proxy hermes-agent:9119
}

# AI host services (no docker container in the standard compose - these
# routes 502 until you run image/video/voice natively on the host).
http://image.localhost {
    reverse_proxy host.docker.internal:9020
}

http://video.localhost {
    reverse_proxy host.docker.internal:3333
}

http://voice.localhost {
    reverse_proxy host.docker.internal:7861
}

# ===== MEDIA =====
http://movie.localhost {
    reverse_proxy host.docker.internal:9014
}

http://music.localhost {
    reverse_proxy host.docker.internal:4533
}

http://file.localhost {
    reverse_proxy host.docker.internal:8095
}

http://photos.localhost {
    reverse_proxy immich-server:2283
}

# ===== REQUEST / DOWNLOAD STACK =====
http://request.localhost {
    reverse_proxy seerr:5055
}

http://sonarr.localhost {
    reverse_proxy sonarr:8989
}

http://radarr.localhost {
    reverse_proxy radarr:7878
}

http://prowlarr.localhost {
    reverse_proxy prowlarr:9696
}

# qBittorrent v5 hard-validates the Host-header port against its listening
# port, so we proxy on container port 9081 (matches host:9081 + WebUI\Port)
# and rewrite the Host header to qbittorrent:9081 so it always matches.
http://torrent.localhost {
    reverse_proxy qbittorrent:9081 {
        header_up Host {upstream_hostport}
    }
}

# Catch-all: any *.localhost we didn't map gets a friendly hint.
:80 {
    respond "Homelab - local-only mode. Open http://hub.localhost/ for the dashboard." 200
}
"@
    Set-Content -Path $OutputPath -Value $content -Encoding UTF8
}

function Render-Templates {
    param($Env, $StateBlob)

    if (-not $StateBlob.SEARXNG_SECRET_KEY)            { $StateBlob.SEARXNG_SECRET_KEY            = New-HexSecret 32 }
    if (-not $StateBlob.AUTHELIA_JWT_SECRET)           { $StateBlob.AUTHELIA_JWT_SECRET           = New-HexSecret 32 }
    if (-not $StateBlob.AUTHELIA_STORAGE_ENCRYPTION_KEY) {
        # We're generating a brand-new storage encryption key. If a stale
        # Authelia SQLite db exists, it was encrypted with the (now-lost)
        # previous key. Wipe it so Authelia re-initialises cleanly. Authelia
        # data is just session/2FA state - nothing irreplaceable on a fresh
        # install. users_database.yml is separate and survives.
        $autheliaDb = Join-Path $ProjectRoot 'persistent-storage/do-not-delete/authelia/db.sqlite3'
        if (Test-Path $autheliaDb) {
            Remove-Item $autheliaDb -Force -ErrorAction SilentlyContinue
            Dim '  Wiped stale Authelia db.sqlite3 (encryption key was regenerated).'
        }
        $StateBlob.AUTHELIA_STORAGE_ENCRYPTION_KEY = New-HexSecret 32
    }

    $renderEnv = [ordered]@{}
    foreach ($k in $Env.Keys) { $renderEnv[$k] = $Env[$k] }
    $renderEnv['SEARXNG_SECRET_KEY']              = $StateBlob.SEARXNG_SECRET_KEY
    $renderEnv['AUTHELIA_JWT_SECRET']             = $StateBlob.AUTHELIA_JWT_SECRET
    $renderEnv['AUTHELIA_STORAGE_ENCRYPTION_KEY'] = $StateBlob.AUTHELIA_STORAGE_ENCRYPTION_KEY
    $torCred = "kasm_user:" + [string]$Env['TOR_VNC_PW']
    $renderEnv['TOR_BASIC_AUTH'] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($torCred))

    if ([string]::IsNullOrWhiteSpace($Env['DOMAIN'])) {
        Write-LocalOnlyCaddyfile -OutputPath (Join-Path $ProjectRoot 'persistent-storage/do-not-delete/caddy/Caddyfile') -Env $renderEnv
    } else {
        Resolve-Template `
            (Join-Path $ProjectRoot 'persistent-storage/do-not-delete/caddy/Caddyfile.tmpl') `
            (Join-Path $ProjectRoot 'persistent-storage/do-not-delete/caddy/Caddyfile') `
            $renderEnv
    }
    # Authelia rejects an empty session.cookies.domain - and 'localhost'
    # alone, because it needs at least one period. In local-only mode
    # DOMAIN is intentionally blank, so substitute 'homelab.local' just
    # for the Authelia render. Authelia then boots cleanly with the
    # .homelab.local hostnames; they go unused because the local-only
    # Caddyfile doesn't proxy through Authelia.
    $autheliaEnv = [ordered]@{}
    foreach ($k in $renderEnv.Keys) { $autheliaEnv[$k] = $renderEnv[$k] }
    if ([string]::IsNullOrWhiteSpace($autheliaEnv['DOMAIN'])) {
        $autheliaEnv['DOMAIN'] = 'homelab.local'
    }
    Resolve-Template `
        (Join-Path $ProjectRoot 'persistent-storage/do-not-delete/authelia/configuration.yml.tmpl') `
        (Join-Path $ProjectRoot 'persistent-storage/do-not-delete/authelia/configuration.yml') `
        $autheliaEnv
    Resolve-Template `
        (Join-Path $ProjectRoot 'persistent-storage/do-not-delete/searxng/settings.yml.tmpl') `
        (Join-Path $ProjectRoot 'persistent-storage/do-not-delete/searxng/settings.yml') `
        $renderEnv

    $usersExample = Join-Path $ProjectRoot 'persistent-storage/do-not-delete/authelia/users_database.yml.example'
    $usersFile    = Join-Path $ProjectRoot 'persistent-storage/do-not-delete/authelia/users_database.yml'
    if (-not (Test-Path $usersFile) -and (Test-Path $usersExample)) {
        Copy-Item $usersExample $usersFile
    }
}

# ---------------------------------------------------------------------------
# Repair-BindPaths: docker bind-mounts that target FILES on the host will
# silently auto-create an empty DIRECTORY at that path on Windows when the
# file doesn't exist, which then breaks the container. Wipe any such
# stray directories so the next render/copy produces a real file.
# ---------------------------------------------------------------------------
function Repair-BindPaths {
    $bindFiles = @(
        (Join-Path $ProjectRoot 'persistent-storage/do-not-delete/caddy/Caddyfile')
        (Join-Path $ProjectRoot 'persistent-storage/do-not-delete/authelia/configuration.yml')
        (Join-Path $ProjectRoot 'persistent-storage/do-not-delete/authelia/users_database.yml')
        (Join-Path $ProjectRoot 'persistent-storage/do-not-delete/searxng/settings.yml')
        (Join-Path $ProjectRoot 'persistent-storage/do-not-delete/filebrowser/settings.json')
    )
    foreach ($p in $bindFiles) {
        if (Test-Path $p -PathType Container) {
            Remove-Item $p -Recurse -Force
            Dim "  Repaired bind path: removed stray directory at $p"
        }
    }

    # n8n persists its encryption key to .n8n/config on first boot. If an
    # earlier run let n8n boot with literal '__GENERATE_32_BYTE_HEX__' from a
    # placeholder .env, its saved key won't match the (now-regenerated) one
    # in .env. Wipe so n8n re-initializes with the current N8N_ENCRYPTION_KEY.
    $n8nConfig = Join-Path $ProjectRoot 'persistent-storage/n8n/n8n_storage/config'
    if (Test-Path $n8nConfig -PathType Leaf) {
        $cfg = Get-Content $n8nConfig -Raw -ErrorAction SilentlyContinue
        if ($cfg -match '__GENERATE_' -or $cfg -match 'CHANGE_ME') {
            Remove-Item $n8nConfig -Force
            Dim '  Wiped stale n8n config (had placeholder encryption key baked in).'
        }
    }
}

# ---------------------------------------------------------------------------
# Ensure-AutheliaUser: pulls the authelia image (if needed), generates a
# strong random password + argon2 hash, and writes users_database.yml so
# Authelia actually boots. No-op if a real hash is already in place.
# Password is stored in .env as AUTHELIA_ADMIN_PASSWORD for later recovery.
# ---------------------------------------------------------------------------
function Ensure-AutheliaUser {
    param($EnvMap)

    $usersFile    = Join-Path $ProjectRoot 'persistent-storage/do-not-delete/authelia/users_database.yml'
    $usersExample = Join-Path $ProjectRoot 'persistent-storage/do-not-delete/authelia/users_database.yml.example'

    if (-not (Test-Path $usersFile -PathType Leaf) -and (Test-Path $usersExample)) {
        Copy-Item $usersExample $usersFile
    }
    if (-not (Test-Path $usersFile -PathType Leaf)) {
        Err '  Cannot find users_database.yml.example to bootstrap Authelia user.'
        return
    }

    $contents = Get-Content $usersFile -Raw
    if ($contents -notmatch '__ARGON2_HASH_REPLACE_ME__') {
        # Hash already real, nothing to do.
        return
    }

    # Default Credentials policy: admin / admin everywhere we control auth.
    # Tunnel-mode users should change this from the Authelia UI after first
    # login - Authelia is the public-internet gate when DOMAIN is set.
    $password = 'admin'
    # On a fresh install this `docker run` first PULLS the authelia image
    # (~80 MB, can take 30-60s) and then computes the argon2id hash
    # (deliberately slow by design, ~1-2s). Both are silent - so the user
    # would see no output for up to a minute. Pre-flight by pulling the
    # image with our normal pull-progress filter, then run the hash.
    $haveAuthelia = & docker image inspect authelia/authelia:latest 2>$null
    if ($LASTEXITCODE -ne 0) {
        Dim '  Pulling authelia image (one-off, ~80 MB) for argon2 hash generation...'
        & docker pull --quiet authelia/authelia:latest 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Err '  authelia image pull failed - argon2 hash cannot be generated.'
            return
        }
    }
    Dim '  Generating Authelia admin argon2 hash (deliberately slow by design, ~2s)...'
    $hashOutput = (& docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password $password) 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Err '  Authelia hash generation failed. Authelia may not start.'
        Dim "  $hashOutput"
        return
    }

    $hashMatch = [regex]::Match($hashOutput, '\$argon2[a-z]+\$[^\s]+')
    if (-not $hashMatch.Success) {
        Err '  Could not parse argon2 hash from authelia output. Authelia may not start.'
        Dim "  $hashOutput"
        return
    }
    $hash = $hashMatch.Value

    # Use .Replace() (literal) - NOT -replace - because the hash contains
    # `$` characters that would be interpreted as backreferences.
    $newContents = $contents.Replace('__ARGON2_HASH_REPLACE_ME__', $hash)
    Set-Content $usersFile $newContents -Encoding UTF8

    $EnvMap['AUTHELIA_ADMIN_PASSWORD'] = $password
    Write-EnvFile $EnvFile $EnvMap

    Ok "Authelia admin user 'admin' configured."
    Dim "  Password: $password   (also saved in .env as AUTHELIA_ADMIN_PASSWORD)"
}

# ---------------------------------------------------------------------------
# Wait-Url: poll a URL until it returns 2xx/3xx (or 401, which means the
# app is up and refusing us - also a success for "boot detection"). Used
# by Configure-MediaStack to know when each *arr is ready to be wired.
# ---------------------------------------------------------------------------
function Wait-Url {
    param([string]$Url, [int]$TimeoutSeconds = 120, [hashtable]$Headers = $null)
    # Extract host + port for the TCP fallback. Invoke-WebRequest is unreliable
    # across PS versions for distinguishing "service up but 401" from "service
    # down" (PS7's HttpRequestException doesn't always carry a Response), so we
    # treat a successful TCP socket connect as proof the listener is alive -
    # which is what callers actually mean by "wait for the app to come up".
    $uri = [Uri]$Url
    $remoteHost = $uri.Host
    $remotePort = if ($uri.Port -gt 0) { $uri.Port } else { if ($uri.Scheme -eq 'https') { 443 } else { 80 } }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 -Headers $Headers -ErrorAction Stop
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) { return $true }
        } catch {
            # Any HTTP response (incl. 401/403/4xx) means the service is up.
            # Probe TCP directly to confirm before sleeping again.
            $tcp = New-Object System.Net.Sockets.TcpClient
            try {
                $iar = $tcp.BeginConnect($remoteHost, $remotePort, $null, $null)
                $ok = $iar.AsyncWaitHandle.WaitOne(3000, $false)
                if ($ok -and $tcp.Connected) { $tcp.EndConnect($iar); return $true }
            } catch {
            } finally {
                $tcp.Close()
            }
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

# ---------------------------------------------------------------------------
# Configure-MediaStack: idempotent API-driven wiring of the request /
# download stack. Runs once after the containers are up. Safe on re-runs:
# every step checks "already done?" before POSTing.
#
# What it sets up:
#   - Sonarr: qBittorrent download client + /tv root folder + tv-sonarr cat
#   - Radarr: qBittorrent download client + /movies root folder + radarr cat
#   - Prowlarr: Sonarr + Radarr registered as applications (auto-sync indexers)
#   - Prowlarr: 5 public no-signup indexers (1337x, YTS, EZTV, TheRARBG, TPB)
#   - 1080p preference: Sonarr/Radarr's built-in "HD-1080p" profile id is
#     resolved + handed to Seerr settings.json so requests are 1080p by default
#
# Seerr's media-server step still needs user interaction (Jellyfin API key
# generation), so we stop just short of that. The summary prints exactly
# what the user clicks through in Seerr's first-run wizard.
# ---------------------------------------------------------------------------
function Configure-MediaStack {
    param($EnvMap)

    $sonarrUrl   = 'http://localhost:8989'
    $radarrUrl   = 'http://localhost:7878'
    $prowlarrUrl = 'http://localhost:9696'
    $sonarrKey   = [string]$EnvMap['SONARR_API_KEY']
    $radarrKey   = [string]$EnvMap['RADARR_API_KEY']
    $prowlarrKey = [string]$EnvMap['PROWLARR_API_KEY']

    if ((Test-Placeholder $sonarrKey) -or (Test-Placeholder $radarrKey) -or (Test-Placeholder $prowlarrKey)) {
        Dim '  Media-stack API keys still placeholders - skipping auto-config.'
        return
    }

    Step 'Step 6 - Wiring Seerr / Sonarr / Radarr / Prowlarr / qBittorrent' 'One-time auto-config. Waiting for each app to boot, then POSTing settings via their REST APIs. Safe to re-run.'

    # ---- Wait for each app to be reachable -----------------------------
    foreach ($svc in @(
        @{ Url="$sonarrUrl/ping";       Name='Sonarr' }
        @{ Url="$radarrUrl/ping";       Name='Radarr' }
        @{ Url="$prowlarrUrl/ping";     Name='Prowlarr' }
        @{ Url='http://localhost:9081'; Name='qBittorrent' }
    )) {
        Dim "  Waiting for $($svc.Name) to come up..."
        if (-not (Wait-Url -Url $svc.Url -TimeoutSeconds 120)) {
            Err "  $($svc.Name) never responded on $($svc.Url). Skipping auto-config."
            return
        }
    }
    Ok 'All apps are up.'

    # ---- qBittorrent: set admin/adminadmin via API (subnet whitelist
    #      makes the request unauthenticated since 127.0.0.1 is whitelisted).
    # qBittorrent v5 enforces:
    #   - WebUI password MUST be >= 6 chars (so 'admin' is rejected - we use
    #     'adminadmin', the legacy v4 default + well-known *arr companion creds).
    #   - The AuthSubnetWhitelist bypass only applies to a handful of routes
    #     (NOT setPreferences), so we have to do a proper session-login first
    #     using the temporary password qBittorrent prints to docker stdout on
    #     every boot when no Password_PBKDF2 is stored.
    try {
        $qbBase = 'http://localhost:9081'
        $qbDesired = 'adminadmin'
        $sess = $null
        $loggedIn = $false

        # Try the desired credentials first. If they're already in place
        # (re-run), we skip the temp-password dance.
        try {
            $r = Invoke-WebRequest -Uri "$qbBase/api/v2/auth/login" -Method POST `
                -Body "username=admin&password=$qbDesired" -ContentType 'application/x-www-form-urlencoded' `
                -SessionVariable sess -UseBasicParsing -ErrorAction Stop
            if ($r.StatusCode -in 200,204) { $loggedIn = $true }
        } catch { }

        if (-not $loggedIn) {
            # Read the temp password printed by qBittorrent's first boot
            # (a fresh one on every container start - take the LAST match).
            $logs = (& docker logs qbittorrent 2>&1) -join "`n"
            $matches2 = [regex]::Matches($logs, 'temporary password is provided for this session:\s*(\S+)')
            $match = if ($matches2.Count -gt 0) { $matches2[$matches2.Count - 1] } else { $null }
            if ($match -and $match.Success) {
                $tempPw = $match.Groups[1].Value
                try {
                    $r = Invoke-WebRequest -Uri "$qbBase/api/v2/auth/login" -Method POST `
                        -Body "username=admin&password=$tempPw" -ContentType 'application/x-www-form-urlencoded' `
                        -SessionVariable sess -UseBasicParsing -ErrorAction Stop
                    if ($r.StatusCode -in 200,204) { $loggedIn = $true }
                } catch { }
            }
        }

        if (-not $loggedIn -or -not $sess) {
            Dim '  qBittorrent: could not authenticate. Default login is in `docker logs qbittorrent`.'
        } else {
            # One POST sets credentials + the seeding policy.
            #
            # Seeding policy: stop the torrent the moment its download finishes.
            # In qBittorrent the share-ratio limit is only checked AFTER
            # download completes, so max_ratio=0 + max_ratio_act=0 (Pause/Stop
            # in v5) means "as soon as the file is fully downloaded, stop
            # uploading." Seed-time limits are disabled - the ratio check
            # fires first anyway.
            $prefsObj = [ordered]@{
                web_ui_username                   = 'admin'
                web_ui_password                   = $qbDesired
                max_ratio_enabled                 = $true
                max_ratio                         = 0
                max_ratio_act                     = 0
                max_seeding_time_enabled          = $false
                max_seeding_time                  = -1
                max_inactive_seeding_time_enabled = $false
                max_inactive_seeding_time         = -1
            }
            $prefs = $prefsObj | ConvertTo-Json -Compress
            try {
                $r2 = Invoke-WebRequest -Uri "$qbBase/api/v2/app/setPreferences" -Method POST `
                    -WebSession $sess -Body "json=$([uri]::EscapeDataString($prefs))" `
                    -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -ErrorAction Stop
                if ($r2.StatusCode -eq 200) {
                    Ok 'qBittorrent: admin/adminadmin + seeding stops on download completion.'
                } else {
                    Dim "  qBittorrent: setPreferences returned $($r2.StatusCode)."
                }
            } catch {
                Dim "  qBittorrent: setPreferences failed: $($_.Exception.Message)"
            }
        }
    } catch {
        Dim "  qBittorrent: could not set credentials ($($_.Exception.Message)). Default login is in 'docker logs qbittorrent'."
    }

    # ---- Helpers for Sonarr / Radarr (both use v3 API) -----------------
    function Invoke-ArrApi {
        param([string]$BaseUrl, [string]$ApiKey, [string]$Path, [string]$Method = 'GET', $Body = $null, [string]$ApiVersion = 'v3')
        $url = "$BaseUrl/api/$ApiVersion/$($Path.TrimStart('/'))"
        $headers = @{ 'X-Api-Key' = $ApiKey; 'Accept' = 'application/json' }
        try {
            if ($Body) {
                $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 -Compress }
                return Invoke-RestMethod -Uri $url -Method $Method -Headers $headers -Body $json -ContentType 'application/json' -ErrorAction Stop
            } else {
                return Invoke-RestMethod -Uri $url -Method $Method -Headers $headers -ErrorAction Stop
            }
        } catch {
            $msg = $_.Exception.Message
            $body = ''
            if ($_.ErrorDetails) { $body = $_.ErrorDetails.Message }
            throw "API $Method $url failed: $msg`n$body"
        }
    }

    # Add qBittorrent as a download client to Sonarr / Radarr. If a stale
    # entry exists (e.g. pointed at :8080 from a previous wizard run before
    # we moved qBittorrent to :9081), reconcile fields in place instead of
    # skipping - otherwise the *arr keeps showing "Connection refused
    # (qbittorrent:8080)" health errors forever.
    function Add-QbDownloadClient {
        param([string]$BaseUrl, [string]$ApiKey, [string]$AppName, [string]$Category)
        $desiredFields = [ordered]@{
            host                = 'qbittorrent'
            port                = 9081
            useSsl              = $false
            urlBase             = ''
            username            = 'admin'
            password            = 'adminadmin'
            tvCategory          = $Category
            movieCategory       = $Category
            recentTvPriority    = 0
            olderTvPriority     = 0
            recentMoviePriority = 0
            olderMoviePriority  = 0
            initialState        = 0
            sequentialOrder     = $false
            firstAndLast        = $false
        }
        $existing = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $ApiKey -Path 'downloadclient'
        $hasQb = $existing | Where-Object { $_.implementation -eq 'QBittorrent' } | Select-Object -First 1
        if ($hasQb) {
            $drift = $false
            foreach ($f in $hasQb.fields) {
                if ($desiredFields.Contains($f.name) -and ([string]$f.value -ne [string]$desiredFields[$f.name])) {
                    $f.value = $desiredFields[$f.name]
                    $drift = $true
                }
            }
            if ($drift) {
                $null = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $ApiKey -Path "downloadclient/$($hasQb.id)" -Method PUT -Body $hasQb
                Ok "${AppName}: qBittorrent download client reconciled (host/port/creds)."
            } else {
                Dim "  ${AppName}: qBittorrent already registered as download client."
            }
            return
        }
        $fieldList = foreach ($k in $desiredFields.Keys) { @{ name = $k; value = $desiredFields[$k] } }
        $payload = @{
            enable          = $true
            protocol        = 'torrent'
            priority        = 1
            removeCompletedDownloads = $true
            removeFailedDownloads    = $true
            name            = 'qBittorrent'
            fields          = @($fieldList)
            implementationName = 'qBittorrent'
            implementation     = 'QBittorrent'
            configContract     = 'QBittorrentSettings'
            tags               = @()
        }
        $null = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $ApiKey -Path 'downloadclient' -Method POST -Body $payload
        Ok "${AppName}: qBittorrent added as download client (category=$Category)."
    }

    # Add a root folder (/tv for sonarr, /movies for radarr). The most common
    # failure is the host path not existing before docker compose up - Docker
    # then auto-creates a root-owned empty mount that the LSIO 'abc' user
    # cannot write to. We catch the 400 and tell the user how to fix it
    # instead of aborting the rest of the configurator.
    function Add-RootFolder {
        param([string]$BaseUrl, [string]$ApiKey, [string]$AppName, [string]$Path)
        $existing = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $ApiKey -Path 'rootfolder'
        if ($existing | Where-Object { $_.path -eq $Path }) {
            Dim "  ${AppName}: root folder $Path already configured."
            return
        }
        try {
            $null = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $ApiKey -Path 'rootfolder' -Method POST -Body @{ path = $Path }
            Ok "${AppName}: root folder $Path added."
        } catch {
            $err = $_.Exception.Message
            if ($err -match 'not writable|FolderWritableValidator') {
                Err "  ${AppName}: root folder $Path is not writable inside the container."
                Dim '    Likely cause: host bind-mount path does not exist before docker compose up,'
                Dim '    so Docker auto-created a root-owned empty mount. Fix:'
                Dim "      1. Create the host path: mkdir <your TV_SHOWS_PATH or MOVIES_PATH>"
                Dim '      2. Re-run the launcher and pick [1] First-Run Setup again.'
                Dim '    Other config (download client, indexers) is still being applied.'
            } else {
                Err "  ${AppName}: root folder add failed: $err"
            }
        }
    }

    # Find the built-in "HD-1080p" quality profile id (used by Seerr).
    function Get-1080pProfileId {
        param([string]$BaseUrl, [string]$ApiKey)
        $profiles = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $ApiKey -Path 'qualityprofile'
        $hd1080 = $profiles | Where-Object { $_.name -eq 'HD-1080p' } | Select-Object -First 1
        if (-not $hd1080) {
            # Fallback: profile that contains the "Bluray-1080p" quality
            $hd1080 = $profiles | Where-Object { $_.items.quality.name -contains 'Bluray-1080p' } | Select-Object -First 1
        }
        return $hd1080.id
    }

    # Find or create a custom format by name from a schema template. Returns
    # the format id. $Mutator is a scriptblock that receives the template
    # spec object and tweaks its fields before we POST it.
    function Get-Or-Create-Format {
        param([string]$BaseUrl, [string]$ApiKey, [string]$AppName, [string]$Name, [string]$Implementation, [scriptblock]$Mutator)
        $formats = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $ApiKey -Path 'customformat'
        $existing = $formats | Where-Object { $_.name -eq $Name } | Select-Object -First 1
        if ($existing) {
            Dim "  ${AppName}: custom format '${Name}' already present (id=$($existing.id))."
            return $existing.id
        }
        $schema = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $ApiKey -Path 'customformat/schema'
        $spec   = $schema | Where-Object { $_.implementation -eq $Implementation } | Select-Object -First 1
        if (-not $spec) {
            Dim "  ${AppName}: no ${Implementation} in schema - skipping ${Name}."
            return $null
        }
        $spec | Add-Member -NotePropertyName name -NotePropertyValue ($Implementation -replace 'Specification$','') -Force
        $spec.negate   = $false
        $spec.required = $true
        & $Mutator $spec
        $cfBody = @{
            name                            = $Name
            includeCustomFormatWhenRenaming = $false
            specifications                  = @($spec)
        }
        $created = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $ApiKey -Path 'customformat' -Method POST -Body $cfBody
        Ok "${AppName}: created '${Name}' custom format (id=$($created.id))."
        return $created.id
    }

    # Apply size-cap + English-only constraints to the HD-1080p profile.
    # Sonarr v4 has no profile.language field (language was migrated to
    # Custom Formats), so we enforce English via a "Not English" custom
    # format with -10000 score plus minFormatScore=0. Radarr keeps the
    # built-in profile.language for parity with how its UI exposes it.
    # The 4 GB cap is a SizeSpecification "min=4, max=999999" (units = GB)
    # with -10000 score on both apps. Idempotent.
    function Set-ArrSizeAndLanguage {
        param([string]$BaseUrl, [string]$ApiKey, [string]$AppName)

        $sizeFormatId = Get-Or-Create-Format -BaseUrl $BaseUrl -ApiKey $ApiKey -AppName $AppName `
            -Name 'Size > 4 GB' -Implementation 'SizeSpecification' -Mutator {
                param($s)
                foreach ($f in $s.fields) {
                    if ($f.name -eq 'min') { $f.value = 4 }
                    elseif ($f.name -eq 'max') { $f.value = 999999 }
                }
            }

        # Sonarr-only: "Not English" via LanguageSpecification + exceptLanguage=true.
        $notEnglishId = $null
        if ($AppName -eq 'Sonarr') {
            $notEnglishId = Get-Or-Create-Format -BaseUrl $BaseUrl -ApiKey $ApiKey -AppName $AppName `
                -Name 'Not English' -Implementation 'LanguageSpecification' -Mutator {
                    param($s)
                    foreach ($f in $s.fields) {
                        if ($f.name -eq 'value')          { $f.value = 1 }       # English
                        elseif ($f.name -eq 'exceptLanguage') { $f.value = $true }  # match anything OTHER than English
                    }
                }
        }

        # Apply to HD-1080p profile.
        $profiles = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $ApiKey -Path 'qualityprofile'
        $hd = $profiles | Where-Object { $_.name -eq 'HD-1080p' } | Select-Object -First 1
        if (-not $hd) {
            Dim "  ${AppName}: HD-1080p profile missing - skipping language/size lock."
            return
        }
        # Radarr exposes profile.language; Sonarr v4 doesn't. Use Add-Member -Force
        # to set it only if it already exists on the object (so PowerShell doesn't
        # throw on the missing-property case).
        if ($hd.PSObject.Properties.Match('language').Count -gt 0) {
            $hd.language = @{ id = 1; name = 'English' }
        }
        $hd.minFormatScore = 0

        # Build the formatItems array - preserve any existing entries, flip our
        # caps to -10000, append new ones if missing.
        $targetScores = @{}
        if ($sizeFormatId) { $targetScores[$sizeFormatId] = @{ Name = 'Size > 4 GB'; Score = -10000 } }
        if ($notEnglishId) { $targetScores[$notEnglishId] = @{ Name = 'Not English'; Score = -10000 } }
        $items = @()
        $seen = @{}
        foreach ($fi in $hd.formatItems) {
            if ($targetScores.ContainsKey($fi.format)) {
                $fi.score = $targetScores[$fi.format].Score
                $seen[$fi.format] = $true
            }
            $items += $fi
        }
        foreach ($id in $targetScores.Keys) {
            if (-not $seen.ContainsKey($id)) {
                $items += @{ format = $id; name = $targetScores[$id].Name; score = $targetScores[$id].Score }
            }
        }
        $hd.formatItems = $items

        $null = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $ApiKey -Path "qualityprofile/$($hd.id)" -Method PUT -Body $hd
        Ok "${AppName}: HD-1080p locked to English + reject any release > 4 GB."
    }

    try {
        Add-QbDownloadClient -BaseUrl $sonarrUrl -ApiKey $sonarrKey -AppName 'Sonarr' -Category 'tv-sonarr'
        Add-RootFolder       -BaseUrl $sonarrUrl -ApiKey $sonarrKey -AppName 'Sonarr' -Path '/tv'
        $sonarrProfileId = Get-1080pProfileId -BaseUrl $sonarrUrl -ApiKey $sonarrKey
        Set-ArrSizeAndLanguage -BaseUrl $sonarrUrl -ApiKey $sonarrKey -AppName 'Sonarr'
        Ok ("Sonarr: HD-1080p profile id = $sonarrProfileId.")
    } catch { Err "  Sonarr config failed: $_" }

    try {
        Add-QbDownloadClient -BaseUrl $radarrUrl -ApiKey $radarrKey -AppName 'Radarr' -Category 'movies-radarr'
        Add-RootFolder       -BaseUrl $radarrUrl -ApiKey $radarrKey -AppName 'Radarr' -Path '/movies'
        $radarrProfileId = Get-1080pProfileId -BaseUrl $radarrUrl -ApiKey $radarrKey
        Set-ArrSizeAndLanguage -BaseUrl $radarrUrl -ApiKey $radarrKey -AppName 'Radarr'
        Ok ("Radarr: HD-1080p profile id = $radarrProfileId.")
    } catch { Err "  Radarr config failed: $_" }

    # ---- Prowlarr: register Sonarr + Radarr as apps, then add indexers
    try {
        # Apps
        $apps = Invoke-ArrApi -BaseUrl $prowlarrUrl -ApiKey $prowlarrKey -Path 'applications' -ApiVersion 'v1'
        foreach ($app in @(
            @{ Name='Sonarr'; Impl='Sonarr'; Contract='SonarrSettings'; SyncType='Standard'; Url='http://sonarr:8989'; Key=$sonarrKey }
            @{ Name='Radarr'; Impl='Radarr'; Contract='RadarrSettings'; SyncType='Standard'; Url='http://radarr:7878'; Key=$radarrKey }
        )) {
            if ($apps | Where-Object { $_.name -eq $app.Name }) {
                Dim "  Prowlarr: $($app.Name) already registered."
                continue
            }
            $payload = @{
                name              = $app.Name
                syncLevel         = 'fullSync'
                fields            = @(
                    @{ name = 'prowlarrUrl';   value = 'http://prowlarr:9696' }
                    @{ name = 'baseUrl';       value = $app.Url }
                    @{ name = 'apiKey';        value = $app.Key }
                    @{ name = 'syncCategories'; value = @(2000,2010,2020,2030,2040,2045,2050,2060,5000,5010,5020,5030,5040,5045,5050) }
                )
                implementationName = $app.Impl
                implementation     = $app.Impl
                configContract     = $app.Contract
                tags               = @()
            }
            $null = Invoke-ArrApi -BaseUrl $prowlarrUrl -ApiKey $prowlarrKey -Path 'applications' -ApiVersion 'v1' -Method POST -Body $payload
            Ok "Prowlarr: registered $($app.Name) as application."
        }

        # Public indexers (no signup, no creds). Use Prowlarr's indexer
        # schema endpoint to fetch each definition then POST it back so we
        # don't have to hard-code the schema (which changes between versions).
        # Indexers REQUIRE appProfileId since Prowlarr 1.x - fetch the default
        # app profile id once so the POST validates.
        $appProfiles = @()
        try {
            $appProfiles = Invoke-ArrApi -BaseUrl $prowlarrUrl -ApiKey $prowlarrKey -Path 'appprofile' -ApiVersion 'v1'
        } catch {
            Dim "  Prowlarr: could not list app profiles ($($_.Exception.Message)). Using id=1."
        }
        $defaultAppProfileId = if ($appProfiles -and $appProfiles.Count -gt 0) { $appProfiles[0].id } else { 1 }
        Dim "  Prowlarr: using app profile id=$defaultAppProfileId for new indexers."

        # Public, no-signup indexers that exist in Prowlarr's current schema.
        # Some (1337x) are Cloudflare-fronted and won't return results until
        # the user adds a FlareSolverr companion container - adding them here
        # is still useful because they'll work the moment FlareSolverr is up.
        # TheRARBG / ThePirateBay are intentionally NOT in this list: their
        # entries were removed/renamed in Prowlarr and the POST 400s.
        $indexerNames = @('1337x','YTS','EZTV','Knaben','LimeTorrents','TorrentGalaxyClone','Internet Archive')
        $existingIdx = Invoke-ArrApi -BaseUrl $prowlarrUrl -ApiKey $prowlarrKey -Path 'indexer' -ApiVersion 'v1'
        $schema = Invoke-ArrApi -BaseUrl $prowlarrUrl -ApiKey $prowlarrKey -Path 'indexer/schema' -ApiVersion 'v1'
        foreach ($name in $indexerNames) {
            if ($existingIdx | Where-Object { $_.name -eq $name }) {
                Dim "  Prowlarr: indexer $name already present."
                continue
            }
            $tpl = $schema | Where-Object { $_.name -eq $name } | Select-Object -First 1
            if (-not $tpl) {
                Dim "  Prowlarr: no schema for $name (skipped - upstream may have renamed it)."
                continue
            }
            $tpl.enable = $true
            # appProfileId lives at the top level of the indexer object; the
            # schema endpoint returns id=0 (template) so we have to overwrite.
            $tpl | Add-Member -NotePropertyName appProfileId -NotePropertyValue $defaultAppProfileId -Force
            try {
                $null = Invoke-ArrApi -BaseUrl $prowlarrUrl -ApiKey $prowlarrKey -Path 'indexer' -ApiVersion 'v1' -Method POST -Body $tpl
                Ok "Prowlarr: added indexer $name."
            } catch {
                Dim "  Prowlarr: $name could not be added ($($_.Exception.Message)) - skipped."
            }
        }
    } catch {
        Err "  Prowlarr config failed: $_"
    }

    # ---- Persist resolved profile ids for the user's reference.
    if ($sonarrProfileId) { $EnvMap['SONARR_PROFILE_ID_1080P'] = [string]$sonarrProfileId }
    if ($radarrProfileId) { $EnvMap['RADARR_PROFILE_ID_1080P'] = [string]$radarrProfileId }
    Write-EnvFile $EnvFile $EnvMap

    # ---- Bootstrap Jellyfin first-run + Seerr admin --------------------
    # Seerr's first admin user can only be created by signing in via a media
    # server admin (Plex/Jellyfin/Emby), so we run Jellyfin's startup
    # wizard programmatically first, then re-use the same admin creds to
    # bootstrap Seerr. Both are idempotent - skip if already configured.
    $jfAdminUser = [string]$EnvMap['JELLYFIN_ADMIN_USERNAME']
    $jfAdminPass = [string]$EnvMap['JELLYFIN_ADMIN_PASSWORD']
    if ([string]::IsNullOrWhiteSpace($jfAdminUser)) { $jfAdminUser = 'admin' }
    if ([string]::IsNullOrWhiteSpace($jfAdminPass) -or (Test-Placeholder $jfAdminPass)) {
        Dim '  Skipping Jellyfin / Seerr auto-config: JELLYFIN_ADMIN_PASSWORD is unset.'
    } else {
        $bootstrapped = Bootstrap-Jellyfin -EnvMap $EnvMap
        if ($bootstrapped) {
            $cookieJar = Bootstrap-Seerr -EnvMap $EnvMap
            if ($cookieJar) {
                Configure-SeerrServers -EnvMap $EnvMap -Session $cookieJar
            }
        }
    }

    G ''
    Ok 'Media stack wired. Open http://request.localhost to start requesting:'
    Dim "  Login: $jfAdminUser / admin   (default - change in Jellyfin/Seerr UI for tunnel mode)"
    Dim '  Sonarr + Radarr defaults: HD-1080p, English-only, reject any release > 4 GB.'
}

# ---------------------------------------------------------------------------
# Bootstrap-Jellyfin: completes Jellyfin's first-run wizard via its REST API
# (POST /Startup/Configuration -> /Startup/User -> /Startup/Complete), then
# generates a long-lived API key and stores it in .env as JELLYFIN_API_KEY.
#
# Returns $true if Jellyfin is now bootstrapped (newly or pre-existing AND
# we have admin creds that work), $false if we should skip Seerr auto-setup
# (e.g. Jellyfin was set up out-of-band and we don't know the password).
# ---------------------------------------------------------------------------
function Bootstrap-Jellyfin {
    param($EnvMap)
    $jfBase = 'http://localhost:9014'
    $user   = [string]$EnvMap['JELLYFIN_ADMIN_USERNAME']
    $pass   = [string]$EnvMap['JELLYFIN_ADMIN_PASSWORD']

    if (-not (Wait-Url -Url "$jfBase/System/Info/Public" -TimeoutSeconds 120)) {
        Err '  Jellyfin never responded. Skipping Seerr auto-config.'
        return $false
    }

    $public = $null
    try {
        $public = Invoke-RestMethod -Uri "$jfBase/System/Info/Public" -UseBasicParsing -ErrorAction Stop
    } catch {
        Err "  Could not read Jellyfin status: $($_.Exception.Message)"
        return $false
    }

    # Header that Jellyfin uses to authorise pre-login API calls.
    $emby = 'MediaBrowser Client="eisa-bootstrap", Device="setup", DeviceId="ehu-setup-1", Version="1.0"'

    if (-not $public.StartupWizardCompleted) {
        Dim '  Jellyfin first-run wizard not finished - running it now...'
        # /Startup/User crashes with "Sequence contains no elements" if it's
        # called before Jellyfin has finished creating its internal "root"
        # placeholder user. TCP-reachable != ready, so poll GET /Startup/User
        # until it returns a Name (typically 1-2 seconds after Wait-Url
        # succeeded, but can drift up to 30s on cold start).
        $rootReady = $false
        for ($i = 0; $i -lt 30; $i++) {
            try {
                $probe = Invoke-RestMethod -Uri "$jfBase/Startup/User" `
                    -Headers @{ 'Authorization' = $emby } -ErrorAction Stop
                if ($probe.Name) { $rootReady = $true; break }
            } catch { }
            Start-Sleep -Seconds 1
        }
        if (-not $rootReady) {
            Err '  Jellyfin internal root user never materialised. Skipping first-run.'
            return $false
        }
        try {
            # NOTE: order matters. POST /Startup/User MUST come before
            # POST /Startup/Configuration on a clean install. With the
            # opposite order Jellyfin's UpdateStartupUser throws
            # "Sequence contains no elements" because Configuration's
            # side-effects move the pre-seeded "root" user out of the
            # _userManager.Users collection that the User endpoint
            # iterates. Calling /Startup/User first finds and renames
            # the seeded user cleanly. (Reproduces on every released
            # 10.10.x and 10.11.x; upstream fix is in main only -
            # jellyfin#14576 was closed as not-planned.)
            $userBody = @{ Name=$user; Password=$pass } | ConvertTo-Json
            Invoke-WebRequest -Uri "$jfBase/Startup/User" -Method POST `
                -Headers @{ 'Authorization' = $emby } `
                -ContentType 'application/json' -Body $userBody -UseBasicParsing -ErrorAction Stop | Out-Null
            $cfgBody = @{ UICulture='en-US'; MetadataCountryCode='US'; PreferredMetadataLanguage='en' } | ConvertTo-Json
            Invoke-WebRequest -Uri "$jfBase/Startup/Configuration" -Method POST `
                -Headers @{ 'Authorization' = $emby } `
                -ContentType 'application/json' -Body $cfgBody -UseBasicParsing -ErrorAction Stop | Out-Null
            Invoke-WebRequest -Uri "$jfBase/Startup/Complete" -Method POST `
                -Headers @{ 'Authorization' = $emby } `
                -UseBasicParsing -ErrorAction Stop | Out-Null
            Ok "Jellyfin admin user '$user' created."
        } catch {
            Err "  Jellyfin first-run failed: $($_.Exception.Message)"
            return $false
        }
    } else {
        Dim '  Jellyfin already initialised - verifying admin login works.'
    }

    # Verify admin creds work (this also gives us a token for /Auth/Keys).
    try {
        $loginBody = @{ Username = $user; Pw = $pass } | ConvertTo-Json
        $loginResp = Invoke-RestMethod -Uri "$jfBase/Users/AuthenticateByName" -Method POST `
            -Headers @{ 'Authorization' = $emby } `
            -ContentType 'application/json' -Body $loginBody -ErrorAction Stop
        $token = $loginResp.AccessToken
    } catch {
        Err "  Jellyfin admin login failed ($user) - Seerr auto-config skipped."
        Dim '    Likely cause: Jellyfin was set up out-of-band with a different password.'
        Dim "    Fix: log into http://movie.localhost as your real admin, then finish Seerr at"
        Dim '    http://request.localhost using those credentials.'
        return $false
    }

    # Generate a long-lived API key if we don't have one yet.
    if (Test-Placeholder $EnvMap['JELLYFIN_API_KEY']) {
        try {
            $authedHeader = 'MediaBrowser Token="' + $token + '", Client="eisa", Device="setup", DeviceId="ehu-setup-1", Version="1.0"'
            Invoke-WebRequest -Uri "$jfBase/Auth/Keys?App=eisa-homelab" -Method POST `
                -Headers @{ 'Authorization' = $authedHeader } `
                -UseBasicParsing -ErrorAction Stop | Out-Null
            $keysResp = Invoke-RestMethod -Uri "$jfBase/Auth/Keys" `
                -Headers @{ 'Authorization' = $authedHeader } -ErrorAction Stop
            $newKey = ($keysResp.Items | Where-Object { $_.AppName -eq 'eisa-homelab' } | Select-Object -First 1).AccessToken
            if ($newKey) {
                $EnvMap['JELLYFIN_API_KEY'] = $newKey
                Write-EnvFile $EnvFile $EnvMap
                Ok 'Jellyfin API key generated and saved to .env.'
            }
        } catch {
            Dim "  Could not generate Jellyfin API key: $($_.Exception.Message)"
        }
    }

    return $true
}

# ---------------------------------------------------------------------------
# Bootstrap-Seerr: POSTs to /api/v1/auth/jellyfin with Jellyfin admin creds.
# Seerr's auth route detects "no admin user yet" + "user is Jellyfin admin"
# and auto-creates the Seerr admin user with id=1. Returns the captured
# WebSession (cookies) for chained API calls; $null on failure.
# ---------------------------------------------------------------------------
function Bootstrap-Seerr {
    param($EnvMap)
    $seerrBase = 'http://localhost:5055'

    if (-not (Wait-Url -Url "$seerrBase/api/v1/status" -TimeoutSeconds 120)) {
        Err '  Seerr never responded on port 5055. Skipping auto-setup.'
        return $null
    }

    # Idempotent: if Seerr already has a media server configured + a user,
    # we have nothing to do here.
    try {
        $status = Invoke-RestMethod -Uri "$seerrBase/api/v1/status" -ErrorAction Stop
        if ($status.commitTag -or $status.version) {
            $publicSettings = Invoke-RestMethod -Uri "$seerrBase/api/v1/settings/public" -ErrorAction Stop
            if ($publicSettings.initialized) {
                Dim '  Seerr already initialised - skipping bootstrap.'
                # Login so the caller can still chain server config if needed.
                $session = $null
                try {
                    $loginBody = @{
                        username = $EnvMap['JELLYFIN_ADMIN_USERNAME']
                        password = $EnvMap['JELLYFIN_ADMIN_PASSWORD']
                    } | ConvertTo-Json
                    Invoke-WebRequest -Uri "$seerrBase/api/v1/auth/jellyfin" -Method POST `
                        -ContentType 'application/json' -Body $loginBody `
                        -SessionVariable session -UseBasicParsing -ErrorAction Stop | Out-Null
                    return $session
                } catch {
                    return $null
                }
            }
        }
    } catch { }

    try {
        $body = @{
            username   = $EnvMap['JELLYFIN_ADMIN_USERNAME']
            password   = $EnvMap['JELLYFIN_ADMIN_PASSWORD']
            hostname   = 'jellyfin'
            port       = 8096
            useSsl     = $false
            urlBase    = ''
            # MediaServerType.JELLYFIN = 2 in Seerr's enum. Without this,
            # auth.ts throws ApiErrorCode.NoAdminUser even when the Jellyfin
            # account IS an admin - Seerr only auto-creates the first Seerr
            # admin when serverType is explicitly Jellyfin or Emby.
            serverType = 2
        } | ConvertTo-Json
        $session = $null
        $resp = Invoke-WebRequest -Uri "$seerrBase/api/v1/auth/jellyfin" -Method POST `
            -ContentType 'application/json' -Body $body `
            -SessionVariable session -UseBasicParsing -ErrorAction Stop
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
            Ok "Seerr admin user '$($EnvMap['JELLYFIN_ADMIN_USERNAME'])' created (via Jellyfin auth)."
            # Flip the "initialized" flag in settings.json so the next visit
            # lands on /login instead of /setup. Seerr writes mediaServerType
            # but leaves main.initialized = false on bootstrap; we have to set
            # it (and public.initialized for the front-end mirror) ourselves.
            $seerrSettings = Join-Path $ProjectRoot 'persistent-storage/do-not-delete/seerr/settings.json'
            if (Test-Path $seerrSettings) {
                try {
                    $json = Get-Content $seerrSettings -Raw | ConvertFrom-Json
                    $changed = $false
                    # Use Add-Member -Force so the assignment works whether or
                    # not the property already exists on the PSObject (older
                    # Seerr versions had main.initialized; newer drop it and
                    # only ship public.initialized).
                    foreach ($k in @('main','public')) {
                        if ($json.$k -and (-not $json.$k.initialized)) {
                            $json.$k | Add-Member -NotePropertyName initialized -NotePropertyValue $true -Force
                            $changed = $true
                        }
                    }
                    if ($changed) {
                        $json | ConvertTo-Json -Depth 20 | Set-Content $seerrSettings -Encoding UTF8
                        & docker restart seerr | Out-Null
                        Ok 'Seerr setup wizard marked complete (visiting / now lands on /login).'
                    }
                } catch {
                    Dim "  Could not flip Seerr initialized flag: $($_.Exception.Message)"
                }
            }
            return $session
        }
    } catch {
        $msg = $_.Exception.Message
        $body = ''
        if ($_.ErrorDetails) { $body = $_.ErrorDetails.Message }
        Err "  Seerr bootstrap failed: $msg"
        if ($body) { Dim "    $body" }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Configure-SeerrServers: registers Sonarr + Radarr inside Seerr so that
# requests forwarded from the UI go to the right *arr app with the HD-1080p
# quality profile and the right root folder. Requires a session cookie
# from Bootstrap-Seerr.
# ---------------------------------------------------------------------------
function Configure-SeerrServers {
    param($EnvMap, $Session)
    $seerrBase = 'http://localhost:5055'
    $sonarrUrl   = 'http://localhost:8989'
    $radarrUrl   = 'http://localhost:7878'
    $sonarrKey   = [string]$EnvMap['SONARR_API_KEY']
    $radarrKey   = [string]$EnvMap['RADARR_API_KEY']

    function Get-1080pProfileIdLocal {
        param([string]$BaseUrl, [string]$ApiKey)
        $profiles = Invoke-RestMethod -Uri "$BaseUrl/api/v3/qualityprofile" -Headers @{ 'X-Api-Key' = $ApiKey } -ErrorAction Stop
        ($profiles | Where-Object { $_.name -eq 'HD-1080p' } | Select-Object -First 1).id
    }

    $sonarrProfile = Get-1080pProfileIdLocal -BaseUrl $sonarrUrl -ApiKey $sonarrKey
    $radarrProfile = Get-1080pProfileIdLocal -BaseUrl $radarrUrl -ApiKey $radarrKey

    foreach ($svc in @(
        @{ Endpoint='sonarr'; Name='Sonarr'; Host='sonarr'; Port=8989; Key=$sonarrKey; Profile=$sonarrProfile; Dir='/tv/' }
        @{ Endpoint='radarr'; Name='Radarr'; Host='radarr'; Port=7878; Key=$radarrKey; Profile=$radarrProfile; Dir='/movies/' }
    )) {
        try {
            $existing = Invoke-RestMethod -Uri "$seerrBase/api/v1/settings/$($svc.Endpoint)" `
                -WebSession $Session -ErrorAction Stop
            if ($existing -and $existing.Count -gt 0) {
                Dim "  Seerr: $($svc.Name) server already configured."
                continue
            }
        } catch { }

        $body = @{
            name              = $svc.Name
            hostname          = $svc.Host
            port              = $svc.Port
            apiKey            = $svc.Key
            useSsl            = $false
            baseUrl           = ''
            activeProfileId   = [int]$svc.Profile
            activeProfileName = 'HD-1080p'
            activeDirectory   = $svc.Dir
            is4k              = $false
            isDefault         = $true
            tags              = @()
            externalUrl       = ''
            syncEnabled       = $false
            preventSearch     = $false
        }
        if ($svc.Endpoint -eq 'sonarr') {
            $body.activeAnimeProfileId         = [int]$svc.Profile
            $body.activeAnimeDirectory         = $svc.Dir
            $body.activeLanguageProfileId      = 1
            $body.activeAnimeLanguageProfileId = 1
            $body.enableSeasonFolders          = $true
        } elseif ($svc.Endpoint -eq 'radarr') {
            $body.minimumAvailability = 'released'
        }

        try {
            Invoke-WebRequest -Uri "$seerrBase/api/v1/settings/$($svc.Endpoint)" -Method POST `
                -WebSession $Session -ContentType 'application/json' `
                -Body ($body | ConvertTo-Json -Compress) -UseBasicParsing -ErrorAction Stop | Out-Null
            Ok "Seerr: $($svc.Name) registered (HD-1080p, root=$($svc.Dir))."
        } catch {
            $bodyErr = ''
            if ($_.ErrorDetails) { $bodyErr = $_.ErrorDetails.Message }
            Err "  Seerr: $($svc.Name) registration failed: $($_.Exception.Message)"
            if ($bodyErr) { Dim "    $bodyErr" }
        }
    }
}

# ---------------------------------------------------------------------------
# Pre-Seed-MediaStack: writes config.xml for sonarr/radarr/prowlarr and
# qBittorrent.conf for qbittorrent BEFORE their containers start, so each
# app boots with our pre-generated API key + no first-run wizard.
#
# - *arr config.xml uses AuthenticationMethod=External so the WebUI loads
#   without a password prompt (the API also accepts X-Api-Key regardless).
# - qBittorrent gets admin/adminadmin as a known PBKDF2 hash + a subnet
#   whitelist that lets containers on the caddy network (172.16/12) and
#   localhost bypass auth entirely, so the API configurator works.
# - Skips writing a file if the user has already started the app (config
#   exists with a different API key) - preserves their customisations.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Configure-HermesAgent: render the Hermes Agent config.yaml that locks
# every LLM role to the in-stack Ollama. The agent's docs accept three
# providers: openai, custom, and ollama-cloud - we use "custom" pointed
# at http://ollama:11434/v1 (the OpenAI-compatible endpoint). Per the
# Ollama-setup guide, the auxiliary tasks (vision, web_extract,
# session_search, compression) can each have their own model; we route
# vision through omnicoder (tool-call capable) and the lighter tasks
# through the smaller abliterated gemma - both already auto-installed
# by the AI bundle's first-run, so the agent works out of the box.
# Idempotent: only writes the file if it's missing or differs.
# ---------------------------------------------------------------------------
function Configure-HermesAgent {
    param($EnvMap)

    $dir = Join-Path $ProjectRoot 'persistent-storage/do-not-delete/hermes-agent'
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $path = Join-Path $dir 'config.yaml'

    $mainModel = 'carstenuhlig/omnicoder-2-9b:q4_k_m'
    $auxModel  = 'huihui_ai/gemma-4-abliterated:e4b-q4_K'

    # YAML produced with explicit values so we don't depend on PowerShell
    # ConvertTo-Yaml (not in stock PS). LF endings keep it portable across
    # the alpine-tar archive path used by Backup / Restore.
    $yaml = @"
# Auto-generated by setup.ps1 (Configure-HermesAgent).
# Locks Hermes Agent to the in-stack Ollama for ALL LLM roles.
# Re-run [1] First-Run Setup to regenerate.

model:
  default: "$mainModel"
  provider: "custom"
  base_url: "http://ollama:11434/v1"

auxiliary:
  vision:
    provider: "custom"
    base_url: "http://ollama:11434/v1"
    model: "$mainModel"
  web_extract:
    provider: "custom"
    base_url: "http://ollama:11434/v1"
    model: "$auxModel"
  session_search:
    provider: "custom"
    base_url: "http://ollama:11434/v1"
    model: "$auxModel"
  compression:
    provider: "custom"
    base_url: "http://ollama:11434/v1"
    model: "$auxModel"
"@
    # LF line endings to keep the file portable.
    [System.IO.File]::WriteAllText($path, ($yaml -replace "`r`n","`n"))
    Ok "Hermes Agent config rendered ($path)."
}

function Pre-Seed-MediaStack {
    param($EnvMap)

    # Ensure the media bind-mount targets exist on the host BEFORE docker
    # compose up. If they don't, Docker auto-creates them as root-owned
    # mounts inside the container, and Sonarr/Radarr (running as UID 1000
    # 'abc' in the LSIO image) can't write into them - root folder add
    # fails with FolderWritableValidator.
    # Also pre-create the seerr config bind-mount target. Seerr runs as
    # PUID 1000 and crashes on first start with EACCES when /app/config is
    # owned by root (which it is when Docker auto-creates the host path).
    $seerrDir = Join-Path $ProjectRoot 'persistent-storage/do-not-delete/seerr'
    if (-not (Test-Path $seerrDir)) {
        New-Item -ItemType Directory -Path $seerrDir -Force | Out-Null
        Dim "  Created Seerr config host directory: $seerrDir"
    }
    foreach ($k in @('MOVIES_PATH','TV_SHOWS_PATH','DOWNLOADS_PATH')) {
        $p = [string]$EnvMap[$k]
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        # Skip obviously-foreign paths (Mac path on Windows, Win path on Mac)
        # - these are a stale-.env signal and creating them would just leave
        # surprise empty folders on the wrong filesystem.
        if ($script:OS -eq 'Windows' -and $p -match '^/Users/') { continue }
        if ($script:OS -ne 'Windows' -and $p -match '^[A-Za-z]:[\\/]')   { continue }
        try {
            if (-not (Test-Path $p)) {
                New-Item -ItemType Directory -Path $p -Force | Out-Null
                Dim "  Created $k host directory: $p"
            }
        } catch {
            Dim "  Could not create $k at $p ($($_.Exception.Message)) - Sonarr/Radarr may need manual root-folder setup."
        }
    }

    # Immich system-integrity markers. Immich's StorageService refuses
    # to start microservices if any of its managed subdirs under
    # UPLOAD_LOCATION (=/data) is missing a `.immich` marker file -
    # this is its mount-disappeared safety check. On a fresh install
    # the host folder is empty, so we seed every required subdir with
    # the marker. See https://docs.immich.app/administration/system-integrity
    $photos = [string]$EnvMap['PHOTOS_PATH']
    if (-not [string]::IsNullOrWhiteSpace($photos) -and
        -not ($script:OS -eq 'Windows' -and $photos -match '^/Users/') -and
        -not ($script:OS -ne 'Windows' -and $photos -match '^[A-Za-z]:[\\/]')) {
        try {
            if (-not (Test-Path $photos)) {
                New-Item -ItemType Directory -Path $photos -Force | Out-Null
                Dim "  Created PHOTOS_PATH host directory: $photos"
            }
            foreach ($sub in @('encoded-video','thumbs','upload','backups','library','profile')) {
                $subDir    = Join-Path $photos $sub
                $markerFile = Join-Path $subDir '.immich'
                if (-not (Test-Path $subDir)) {
                    New-Item -ItemType Directory -Path $subDir -Force | Out-Null
                }
                if (-not (Test-Path $markerFile)) {
                    New-Item -ItemType File -Path $markerFile -Force | Out-Null
                }
            }
        } catch {
            Dim "  Could not seed Immich folder structure at $photos ($($_.Exception.Message)) - immich-server may crash-loop on first start."
        }
    }

    $apps = @(
        @{ Name='Sonarr';   Dir='sonarr';   Port=8989; ApiKey=$EnvMap['SONARR_API_KEY'] }
        @{ Name='Radarr';   Dir='radarr';   Port=7878; ApiKey=$EnvMap['RADARR_API_KEY'] }
        @{ Name='Prowlarr'; Dir='prowlarr'; Port=9696; ApiKey=$EnvMap['PROWLARR_API_KEY'] }
    )
    foreach ($a in $apps) {
        $cfgDir  = Join-Path $ProjectRoot ("persistent-storage/do-not-delete/" + $a.Dir)
        $cfgFile = Join-Path $cfgDir 'config.xml'
        if (-not (Test-Path $cfgDir)) {
            New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
        }
        # Skip if user has already booted the app and customised the API key.
        if (Test-Path $cfgFile -PathType Leaf) {
            $existing = Get-Content $cfgFile -Raw -ErrorAction SilentlyContinue
            if ($existing -and $existing -match '<ApiKey>([0-9a-fA-F]{16,})</ApiKey>') {
                $existingKey = $Matches[1]
                if ($existingKey -ne $a.ApiKey -and $existingKey -ne '__GENERATE_32_BYTE_HEX__') {
                    # Preserve user's existing key - copy it back into .env so
                    # the configurator can talk to the app.
                    $EnvMap[("$($a.Name.ToUpper())_API_KEY")] = $existingKey
                    Dim "  $($a.Name): keeping existing API key from config.xml."
                    continue
                }
            }
        }
        $xml = @"
<Config>
  <BindAddress>*</BindAddress>
  <Port>$($a.Port)</Port>
  <SslPort>0</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>False</LaunchBrowser>
  <ApiKey>$($a.ApiKey)</ApiKey>
  <AuthenticationMethod>External</AuthenticationMethod>
  <AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>
  <Branch>main</Branch>
  <LogLevel>info</LogLevel>
  <UrlBase></UrlBase>
  <InstanceName>$($a.Name)</InstanceName>
  <UpdateMechanism>Docker</UpdateMechanism>
</Config>
"@
        Set-Content -Path $cfgFile -Value $xml -Encoding UTF8
        Ok "$($a.Name) pre-seeded (config.xml with known API key)."
    }

    # qBittorrent: minimal pre-seed.
    #   - AuthSubnetWhitelist for the docker bridge + RFC1918 ranges so the
    #     API configurator (and Caddy) reach /api/v2 without creds.
    #   - HostHeaderValidation + CSRF off so torrent.localhost / torrent.${DOMAIN}
    #     proxied requests aren't rejected as cross-origin.
    #   - /downloads as default save path.
    # DO NOT pre-seed Password_PBKDF2: qBittorrent v5.x rejects the legacy
    # hash format and enters a crash loop. Instead the configurator
    # (Set-QbittorrentPassword) POSTs the desired password via the WebUI
    # API on first boot, which lets qBittorrent compute the v5 hash itself.
    # qBittorrent v5's LSIO image launches with --profile=/config/qBittorrent,
    # which reads its INI from /config/qBittorrent/config/qBittorrent.conf
    # (nested config/ subdir). The v4 image used /config/qBittorrent/qBittorrent.conf.
    # Write to BOTH for forward + backward compat: whichever the running image
    # honours wins, and re-runs are idempotent.
    $qbConfDir  = Join-Path $ProjectRoot 'persistent-storage/do-not-delete/qbittorrent/qBittorrent/config'
    $qbConfFile = Join-Path $qbConfDir 'qBittorrent.conf'
    if (-not (Test-Path $qbConfDir)) {
        New-Item -ItemType Directory -Path $qbConfDir -Force | Out-Null
    }
    # NOTE: line endings MUST be Unix LF. The linuxserver image's qbittorrent
    # run script greps WebUI\Address with `grep -Po "...\K(.*)"`; on a CRLF
    # file the trailing \r ends up in the captured value, the
    # `[[ ${addr} == "*" ]]` check fails, and nc -z "*\r" 8080 throws
    # `getaddrinfo: Name does not resolve`. qBittorrent then crash-loops.
    # We write LF via [IO.File]::WriteAllText (PowerShell's Set-Content
    # defaults to CRLF on Windows); qBittorrent itself writes LF when it
    # rewrites the file later (Qt on Linux). Also self-heal an existing
    # CRLF conf on every wizard run so an upgrade from a buggy pre-seed
    # doesn't leave the user stuck.
    function Convert-FileToLF {
        param([string]$Path)
        if (-not (Test-Path $Path -PathType Leaf)) { return }
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes -notcontains [byte]13) { return }
        $fixed = [byte[]]($bytes | Where-Object { $_ -ne 13 })
        [System.IO.File]::WriteAllBytes($Path, $fixed)
        Dim "  Stripped CRLF from $Path"
    }

    if (-not (Test-Path $qbConfFile -PathType Leaf)) {
        $qbConf = @"
[BitTorrent]
Session\DefaultSavePath=/downloads/
# Stop seeding the instant a download completes. GlobalMaxRatio=0 means the
# ratio target is reached at finish (ratio is 0 right after the last piece),
# and ShareLimitAction=Stop triggers the action immediately. No seed-time
# limit (-1 = disabled) since the ratio check fires first.
Session\GlobalMaxRatio=0
Session\GlobalMaxSeedingMinutes=-1
Session\GlobalMaxInactiveSeedingMinutes=-1
Session\ShareLimitAction=Stop

[LegalNotice]
Accepted=true

[Preferences]
WebUI\Port=9081
# Wide-open auth bypass for the LAN. qBittorrent v5 sees Docker-NAT'd source
# IPs as ::ffff:172.x (IPv4-mapped IPv6), which DOES NOT match plain IPv4
# CIDRs like 172.16.0.0/12. We include the IPv6-mapped variants explicitly,
# and add 0.0.0.0/0 + ::/0 because this is local-only mode anyway - Caddy
# + Authelia gate tunnel-mode access. Without this the configurator's
# setPreferences call returns 403.
WebUI\AuthSubnetWhitelistEnabled=true
WebUI\AuthSubnetWhitelist=0.0.0.0/0, ::/0
WebUI\HostHeaderValidation=false
WebUI\CSRFProtection=false
WebUI\LocalHostAuth=false
WebUI\ServerDomains=*
Downloads\SavePath=/downloads/
"@
        $qbConf = $qbConf -replace "`r`n", "`n"
        [System.IO.File]::WriteAllText($qbConfFile, $qbConf, [System.Text.UTF8Encoding]::new($false))
        Ok 'qBittorrent pre-seeded (LF endings, LAN auth bypass, /downloads).'
    } else {
        Convert-FileToLF -Path $qbConfFile
        Dim '  qBittorrent: config exists, keeping user customisations.'
    }
}

# ---------------------------------------------------------------------------
# Ensure-HeimdallTiles: rewrites Heimdall's start-page tile URLs in
# app.sqlite based on the tile domain captured in Step 2b of the wizard.
#
#   $TileDomain non-empty  ->  https://chat.<dom>, https://movie.<dom>, ...
#   $TileDomain empty      ->  http://chat.localhost, http://photos.localhost, ...
#                              (resolved by Caddy's local-mode vhosts on :80)
#
# The rewrite is idempotent and gated: it only fires while at least one
# tile URL still contains the shipped "homelab.local" placeholder, so user
# customizations are never clobbered, and re-runs are no-ops.
#
# Uses docker (alpine:3.20 + apk add sqlite) so we don't need sqlite3
# on the host - same pattern Ensure-AutheliaUser uses for argon2.
# ---------------------------------------------------------------------------
function Ensure-HeimdallTiles {
    param([string]$TileDomain = '')

    $dbPath = Join-Path $ProjectRoot 'persistent-storage/do-not-delete/heimdall/config/www/app.sqlite'
    if (-not (Test-Path $dbPath -PathType Leaf)) {
        Dim '  Heimdall DB not present yet - tile rewrite will run after first heimdall boot.'
        return
    }

    $dbDir  = Split-Path $dbPath
    $dbName = Split-Path $dbPath -Leaf
    $tmpSql = Join-Path $dbDir '.heimdall-rewrite.sql'

    # Probe: how many tiles still hold the maintainer's placeholder?
    $probeRaw = (& docker run --rm -v "${dbDir}:/data" alpine:3.20 sh -c "apk add --no-cache sqlite >/dev/null 2>&1 && sqlite3 /data/$dbName ""SELECT COUNT(*) FROM items WHERE url LIKE '%homelab.local%';""") 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Err '  Could not probe Heimdall DB (docker sqlite3 failed). Skipping tile rewrite.'
        Dim "  $probeRaw"
        return
    }
    $count = 0
    [int]::TryParse(($probeRaw.Trim() -split "`n" | Select-Object -Last 1).Trim(), [ref]$count) | Out-Null
    if ($count -eq 0) {
        Dim '  Heimdall tiles already customized - leaving them alone.'
        return
    }

    # Build the per-tile URL map. id values come from the shipped app.sqlite
    # seed; if a user wipes and re-adds tiles, ids will be different and the
    # homelab.local probe above will return 0, so we never reach this branch.
    $lines = @()
    if ([string]::IsNullOrWhiteSpace($TileDomain)) {
        # LOCAL MODE: route everything through Caddy's *.localhost vhosts
        # (see Write-LocalOnlyCaddyfile). *.localhost auto-resolves to
        # 127.0.0.1 in every modern OS/browser, so no DNS or hosts file
        # required.
        $sub = [ordered]@{
            1 = 'chat'; 2 = 'movie'; 3 = 'music'; 4 = 'file'; 5 = 'tool'
            6 = 'image'; 7 = 'voice'; 8 = 'video'; 9 = 'hermes'
            10 = 'n8n'; 11 = 'hermes'; 12 = 'n8n'
        }
        foreach ($id in $sub.Keys) {
            $lines += "UPDATE items SET url='http://$($sub[$id]).localhost' WHERE id=$id;"
        }
    } else {
        # ONLINE MODE: <subdomain>.<TileDomain> matching the Caddyfile vhosts.
        $sub = [ordered]@{
            1 = 'chat'; 2 = 'movie'; 3 = 'music'; 4 = 'file'; 5 = 'tool'
            6 = 'image'; 7 = 'voice'; 8 = 'video'; 9 = 'hermes'
            10 = 'n8n'; 11 = 'hermes'; 12 = 'n8n'
        }
        foreach ($id in $sub.Keys) {
            $lines += "UPDATE items SET url='https://$($sub[$id]).$TileDomain' WHERE id=$id;"
        }
    }

    Set-Content -Path $tmpSql -Value ($lines -join "`n") -Encoding ASCII
    try {
        $applyRaw = (& docker run --rm -v "${dbDir}:/data" alpine:3.20 sh -c "apk add --no-cache sqlite >/dev/null 2>&1 && sqlite3 /data/$dbName "".read /data/.heimdall-rewrite.sql""") 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            $target = if ($TileDomain) { "https://*.$TileDomain" } else { 'http://*.localhost' }
            Ok "Heimdall tiles rewritten -> $target ($count tile(s) updated)."
        } else {
            Err 'Heimdall tile rewrite failed (docker sqlite3 returned non-zero).'
            Dim "  $applyRaw"
        }
    } finally {
        Remove-Item $tmpSql -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Ensure-EnvSecrets: silently generate strong random values for any env keys
# still holding their placeholder (`__GENERATE_*__` / `__CHANGE_ME__`).
# Returns $true if any secret was written.
# ---------------------------------------------------------------------------
function Ensure-EnvSecrets {
    param($EnvMap)
    $genSpecs = @(
        @{ Key='POSTGRES_PASSWORD';              Bytes=24; Mode='hex' }
        @{ Key='N8N_ENCRYPTION_KEY';             Bytes=32; Mode='hex' }
        @{ Key='N8N_USER_MANAGEMENT_JWT_SECRET'; Bytes=32; Mode='hex' }
        @{ Key='NEXTAUTH_SECRET';                Bytes=32; Mode='b64' }
        @{ Key='LINKWARDEN_DB_PASSWORD';         Bytes=20; Mode='hex' }
        @{ Key='DB_PASSWORD';                    Bytes=20; Mode='hex' }
        @{ Key='TOR_VNC_PW';                     Bytes=12; Mode='hex' }
        @{ Key='SONARR_API_KEY';                 Bytes=16; Mode='hex' }
        @{ Key='RADARR_API_KEY';                 Bytes=16; Mode='hex' }
        @{ Key='PROWLARR_API_KEY';               Bytes=16; Mode='hex' }
        @{ Key='SEERR_API_KEY';                  Bytes=16; Mode='hex' }
        @{ Key='HERMES_API_KEY';                 Bytes=16; Mode='hex' }
        # JELLYFIN_ADMIN_PASSWORD intentionally omitted - see Default Credentials policy.
    )
    $changed = $false
    foreach ($s in $genSpecs) {
        if (Test-Placeholder $EnvMap[$s.Key]) {
            $EnvMap[$s.Key] = if ($s.Mode -eq 'hex') {
                New-HexSecret -Bytes $s.Bytes
            } else {
                New-Base64Secret -Bytes $s.Bytes
            }
            $changed = $true
        }
    }
    return $changed
}

# ---------------------------------------------------------------------------
# New-StateBlob: shape of .wizard-state.json. Used both by fresh installs
# and as the seed for Render-Templates.
# ---------------------------------------------------------------------------
function New-StateBlob {
    return [pscustomobject]@{
        SEARXNG_SECRET_KEY              = ''
        AUTHELIA_JWT_SECRET             = ''
        AUTHELIA_STORAGE_ENCRYPTION_KEY = ''
        profiles                        = @('ai','media')
        customServices                  = @()
        useTunnel                       = $false
        gpuMode                         = 'cpu'
        configured                      = $true
    }
}

# ---------------------------------------------------------------------------
# Compose start / stop.
# ---------------------------------------------------------------------------
function Start-Stack {
    param(
        [string[]]$Profiles,
        [bool]$UseTunnel,
        [string]$GpuMode = 'cpu',  # 'cpu' | 'nvidia' | 'amd' | 'native' (Mac, Metal)
        [string[]]$CustomServices = @()
    )

    # The media-stream and media-request profiles are conceptually distinct
    # in the Step 1 picker but operationally inseparable: Seerr requests
    # land in Jellyfin's library, Sonarr/Radarr import into Jellyfin's
    # paths, and the wizard's Step 6 configurator waits on Sonarr/Radarr/
    # Prowlarr/qBittorrent regardless of which media profile was picked.
    # So if the user has either one, expand to include both - otherwise
    # picking just "MEDIA STREAMING STACK" starts jellyfin/navidrome/immich
    # but then hangs forever on "Waiting for Sonarr to come up..."
    if ($Profiles -contains 'media-stream' -and $Profiles -notcontains 'media-request') {
        $Profiles = @($Profiles) + 'media-request'
    }
    if ($Profiles -contains 'media-request' -and $Profiles -notcontains 'media-stream') {
        $Profiles = @($Profiles) + 'media-stream'
    }

    # `--progress plain` forces line-by-line output instead of compose v2's
    # default TTY redraw renderer. When the wizard is launched from the
    # macOS .command launcher (or the Windows .bat one) compose's in-place
    # progress updates don't redraw cleanly and you end up with hundreds
    # of near-identical "[+] Running 20/24 ... Waiting 5.5s" lines for
    # every healthcheck wait. Plain output is one line per event.
    $arglist = @('compose', '--progress', 'plain', '-f', 'docker-compose.yml')
    switch ($GpuMode) {
        'nvidia' { $arglist += @('-f', 'docker-compose.nvidia.yml') }
        'amd'    { $arglist += @('-f', 'docker-compose.amd.yml') }
        'native' { $arglist += @('-f', 'docker-compose.ollama-native.yml') }
    }

    if ($CustomServices -and $CustomServices.Count -gt 0) {
        # CUSTOM mode: pass explicit service names positionally to `up`.
        # We bypass --profile and instead list the chosen services plus
        # the always-on core (which has no profile but doesn't auto-start
        # when other services are listed positionally).
        $coreServices = @('caddy','authelia','heimdall','portainer')
        $services = @($CustomServices) + $coreServices
        if ($UseTunnel) { $services += 'cloudflared' }
        # De-dup while preserving order.
        $services = $services | Select-Object -Unique
        $arglist += @('up','-d') + $services
    } else {
        $effective = @($Profiles)
        if ($UseTunnel) { $effective += 'tunnel' }
        foreach ($p in $effective) { $arglist += @('--profile', $p) }
        $arglist += @('up','-d')
    }

    # ----------------------------------------------------------------
    # PHASE 1 - `docker compose pull`. Plain, traditional output;
    # let compose handle parallelism, retries, and progress display.
    # The previous custom pull pool was occasionally getting stuck on
    # transient cloudflare blips with no clean recovery path.
    # ----------------------------------------------------------------
    $pullArgs    = [System.Collections.Generic.List[string]]::new()
    $skipDashD   = $false
    foreach ($a in $arglist) {
        if ($a -eq 'up')                   { $pullArgs.Add('pull'); $skipDashD = $true; continue }
        if ($skipDashD -and $a -eq '-d')   { $skipDashD = $false; continue }
        $pullArgs.Add($a)
    }

    G ''
    G  '  [1/2] Pulling images (3 at a time)...'
    G  ''
    # COMPOSE_PARALLEL_LIMIT throttles compose's engine-call concurrency.
    # On home internet, 3 parallel pulls each get a decent slice of
    # bandwidth; with the default (unlimited / one per image) every pull
    # gets bandwidth/N and none of them progress meaningfully. We restore
    # the prior value (if any) after the pull so the up phase isn't
    # constrained unexpectedly.
    $prevParallelLimit = $env:COMPOSE_PARALLEL_LIMIT
    $env:COMPOSE_PARALLEL_LIMIT = '3'
    try {
        & docker @pullArgs
        $pullExit = $LASTEXITCODE
    } finally {
        if ($null -eq $prevParallelLimit) {
            Remove-Item Env:COMPOSE_PARALLEL_LIMIT -ErrorAction SilentlyContinue
        } else {
            $env:COMPOSE_PARALLEL_LIMIT = $prevParallelLimit
        }
    }
    if ($pullExit -ne 0) {
        G ''
        Err 'docker compose pull failed.'
        Err '    Check internet / registry creds, then re-run Start Stack.'
        exit $pullExit
    }
    G ''
    Ok 'Images ready.'

    # ----------------------------------------------------------------
    # PHASE 2 - bring containers up with the now-cached images.
    # ----------------------------------------------------------------
    G ''
    G  '  [2/2] Starting containers...'
    G  ''

    # Per-event filter. Compose emits each container's lifecycle as
    # 4-6 lines (Creating, Created, Starting, Started, [Healthy]); we
    # collapse that to ONE line per container - first terminal state
    # only. Healthy follow-ups are dropped because the container is
    # already counted as up, and counting both inflates the progress
    # number x2.
    $dropPattern = '^\s*(Container|Network|Volume)\s+.+?\s+(Creating|Created|Starting|Waiting|Recreating|Recreated|Stopping|Stopped|Removing|Removed|Healthy)\s*$'
    $okPattern   = '^\s*(Container|Network|Volume)\s+(.+?)\s+(Started|Running)\s*$'
    $errPattern  = '^\s*(Container|Network|Volume)\s+(.+?)\s+(Error|Failed.*)\s*$'

    $upCount = 0
    $seen    = @{}
    & docker @arglist 2>&1 | ForEach-Object {
        $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { [string]$_ }
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        if ($line -match $dropPattern) { return }
        if ($line -match $okPattern) {
            $name = $matches[2]
            if ($seen.ContainsKey($name)) { return }
            $seen[$name] = $true
            $upCount++
            Write-Host ('  [{0,2}] {1}' -f $upCount, $name) -ForegroundColor Green
            return
        }
        if ($line -match $errPattern) {
            Write-Host ('  [!]  ' + $matches[2] + ' - ' + $matches[3]) -ForegroundColor Red
            return
        }
        # Pass anything else (real errors, multi-line stack traces) through.
        Write-Host $line
    }

    if ($LASTEXITCODE -ne 0) {
        Err 'docker compose up failed.'
        exit $LASTEXITCODE
    }
    G ''
    Ok "Stack is up ($upCount container(s) running)."
}

# ---------------------------------------------------------------------------
# Get-OllamaGpuMode: best-effort GPU detection. Returns 'nvidia', 'amd',
# or 'cpu'. Used as the default for the first-run wizard and on every
# -StartOnly when no explicit choice has been persisted yet.
# ---------------------------------------------------------------------------
function Get-OllamaGpuMode {
    param([string]$OS = $script:OS)

    # macOS: Docker Desktop's Linux VM can't reach Metal, so containerised
    # Ollama is always CPU. But if the user has Ollama running NATIVELY on
    # the host (brew install / ollama.app), we can detect that and default
    # to 'native' mode - Open WebUI / LDR / Vane will be repointed at
    # host.docker.internal:11434 so they get Metal-accelerated inference.
    if ($OS -eq 'Mac') {
        try {
            $resp = Invoke-WebRequest -Uri 'http://127.0.0.1:11434/api/tags' -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($resp.StatusCode -eq 200) { return 'native' }
        } catch {}
        return 'cpu'
    }

    # NVIDIA: check whether docker has the nvidia runtime registered.
    try {
        $info = (& docker info --format '{{json .Runtimes}}' 2>$null) | Out-String
        if ($info -match '"nvidia"') { return 'nvidia' }
    } catch {}

    # Windows fallback: try nvidia-smi on the host.
    if ($OS -eq 'Windows') {
        try {
            $null = & nvidia-smi --query-gpu=name --format=csv,noheader 2>$null
            if ($LASTEXITCODE -eq 0) { return 'nvidia' }
        } catch {}
    }

    # AMD ROCm (Linux only - Docker Desktop on Windows doesn't expose AMD).
    if ($OS -eq 'Linux' -and (Test-Path '/dev/kfd')) { return 'amd' }

    return 'cpu'
}

# ---------------------------------------------------------------------------
# LLM picker (only runs if AI in stack and no models installed yet).
# ---------------------------------------------------------------------------
function Wait-Ollama {
    param([int]$TimeoutSeconds = 60)
    for ($i = 0; $i -lt $TimeoutSeconds; $i++) {
        try {
            $null = Invoke-WebRequest -Uri 'http://127.0.0.1:11434/api/tags' -UseBasicParsing -TimeoutSec 2
            return $true
        } catch {}
        Start-Sleep -Seconds 1
    }
    return $false
}

# ---------------------------------------------------------------------------
# Ensure-NativeOllamaInstalled: when the wizard's gpuMode is "native" (Mac
# Apple Silicon path), make sure the host-installed `ollama` CLI exists and
# the server is responding on http://127.0.0.1:11434 BEFORE we compose-up.
# Without this, Start-Stack succeeds (the overlay disables the in-container
# ollama) but Open WebUI / Local Deep Research / Vane all try to
# reach host.docker.internal:11434 and find nothing, and the auto-pull step
# in Install-FirstLlm later fails too.
#
# Prefers Homebrew (clean CLI install + launchd integration). Falls back to
# downloading the official universal Ollama.app from GitHub Releases for
# Macs without brew. No-op on every non-Mac OS - the wizard only ever sets
# gpuMode to "native" on macOS.
# ---------------------------------------------------------------------------
function Ensure-NativeOllamaInstalled {
    param([string]$GpuMode)
    if ($GpuMode -ne 'native') { return }
    if ($script:OS -ne 'Mac') { return }

    $hasCli = $null -ne (Get-Command ollama -ErrorAction SilentlyContinue)

    if ($hasCli) {
        if (Wait-Ollama -TimeoutSeconds 3) {
            Ok 'Native ollama already installed and responding on :11434.'
            return
        }
        Dim '  Native ollama is installed but the API is silent. Starting it...'
        if (Get-Command brew -ErrorAction SilentlyContinue) {
            & brew services start ollama 2>$null | Out-Null
        }
        if (-not (Wait-Ollama -TimeoutSeconds 30)) {
            # Last resort: detached `ollama serve` so it survives this script.
            Start-Process -FilePath 'ollama' -ArgumentList 'serve' -WindowStyle Hidden | Out-Null
        }
        if (Wait-Ollama -TimeoutSeconds 30) {
            Ok 'Native ollama started.'
        } else {
            Err 'Ollama is installed but the API did not come up within 60s.'
            Dim '  Try manually: brew services restart ollama   (or: ollama serve)'
        }
        return
    }

    # Not installed - install it.
    G ''
    Step 'Installing native ollama (Apple Metal-accelerated)' `
         'You picked NATIVE Ollama in Step 3b. The "ollama" CLI is not on this Mac yet, so we will install it now.'

    if (Get-Command brew -ErrorAction SilentlyContinue) {
        Dim '  Homebrew detected - using `brew install ollama` (recommended).'
        & brew install ollama
        if ($LASTEXITCODE -ne 0) {
            Err 'brew install ollama failed - see output above.'
            Dim '  Skipping native install. The stack will still come up, but Open'
            Dim '  WebUI / Vane / LDR will have no LLM backend until you'
            Dim '  install ollama manually.'
            return
        }
        Dim '  Starting ollama as a background launchd service...'
        & brew services start ollama 2>$null | Out-Null
    } else {
        Dim '  Homebrew not found. Downloading the official Ollama Mac app from:'
        Dim '    https://github.com/ollama/ollama/releases/latest'
        $tmpDir  = Join-Path ([System.IO.Path]::GetTempPath()) ("eisa-ollama-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
        $zipPath = Join-Path $tmpDir 'Ollama-darwin.zip'
        try {
            Invoke-WebRequest -Uri 'https://github.com/ollama/ollama/releases/latest/download/Ollama-darwin.zip' `
                              -OutFile $zipPath -UseBasicParsing
        } catch {
            Err ("Download failed: " + $_.Exception.Message)
            Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
            return
        }
        Dim '  Extracting Ollama.app to /Applications ...'
        # ditto preserves macOS codesign + quarantine metadata better than unzip.
        & ditto -xk $zipPath '/Applications/'
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -ne 0) {
            Err 'Extracting to /Applications failed.'
            return
        }
        Dim '  Launching Ollama.app (first launch installs the CLI to /usr/local/bin'
        Dim '  and starts the background daemon)...'
        & open -a Ollama 2>$null
    }

    Dim '  Waiting for the native ollama API to come up at http://127.0.0.1:11434 ...'
    if (Wait-Ollama -TimeoutSeconds 90) {
        Ok 'Native ollama is up.'
    } else {
        Err 'Ollama is installed but the API did not respond within 90s.'
        Dim '  If you used the .app installer, look for a one-time "Install CLI"'
        Dim '  prompt in the Ollama app window and accept it, then re-run.'
    }
}

function Get-OllamaModelCount {
    try {
        $resp = Invoke-WebRequest -Uri 'http://127.0.0.1:11434/api/tags' -UseBasicParsing -TimeoutSec 5
        $j = $resp.Content | ConvertFrom-Json
        if ($null -eq $j.models) { return 0 }
        return @($j.models).Count
    } catch { return 0 }
}

function Read-RecommendedModels {
    if (-not (Test-Path $RecommendedFile)) { return @() }
    $items = @()
    foreach ($line in Get-Content $RecommendedFile) {
        if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
        $parts = $line -split '\|', 2
        if ($parts.Count -ne 2) { continue }
        $items += [pscustomobject]@{
            Tier = $parts[0].Trim().ToUpper()
            Tag  = $parts[1].Trim()
        }
    }
    return $items
}

function Test-OllamaModelInstalled {
    param([string]$Tag)
    try {
        $resp = Invoke-WebRequest -Uri 'http://127.0.0.1:11434/api/tags' -UseBasicParsing -TimeoutSec 5
        $j = $resp.Content | ConvertFrom-Json
        foreach ($m in @($j.models)) {
            if ($m.name -eq $Tag -or $m.model -eq $Tag) { return $true }
        }
    } catch {}
    return $false
}

# Pull a model into whichever Ollama is reachable on :11434. Tries, in order:
#   1. `docker exec -it ollama ollama pull <tag>` (in-container ollama)
#   2. `& ollama pull <tag>`                       (host ollama CLI - Mac native)
#   3. POST /api/pull                              (last-resort streaming API)
function Invoke-OllamaPull {
    param([Parameter(Mandatory)][string]$Tag)

    # Containerised ollama present?
    try {
        $null = & docker inspect -f '{{.Id}}' ollama 2>$null
        if ($LASTEXITCODE -eq 0) {
            & docker exec -it ollama ollama pull $Tag
            return ($LASTEXITCODE -eq 0)
        }
    } catch {}

    # Host ollama CLI?
    try {
        $null = & ollama --version 2>$null
        if ($LASTEXITCODE -eq 0) {
            & ollama pull $Tag
            return ($LASTEXITCODE -eq 0)
        }
    } catch {}

    # API fallback (no nice progress, but works headless).
    Dim '  Streaming pull via /api/pull (no progress bar)...'
    try {
        $body = @{ name = $Tag } | ConvertTo-Json -Compress
        Invoke-WebRequest -Uri 'http://127.0.0.1:11434/api/pull' `
            -Method Post -Body $body -ContentType 'application/json' `
            -UseBasicParsing -TimeoutSec 3600 | Out-Null
        return $true
    } catch {
        Err "  /api/pull failed: $($_.Exception.Message)"
        return $false
    }
}

function Install-FirstLlm {
    $managerName = if ($script:OS -eq 'Mac') {
        'MAC-HOMELAB-MANAGER.COMMAND -> [4] LLM Manager'
    } else {
        'WINDOWS-HOMELAB-MANAGER.BAT -> [4] LLM Manager'
    }

    $starters = @(
        [pscustomobject]@{
            Tag     = 'huihui_ai/gemma-4-abliterated:e4b-q4_K'
            Title   = 'Gemma 4 (e4b, Q4_K) - abliterated'
            Purpose = 'General-purpose, uncensored AI. Use this for everyday chat,'
            Purpose2= 'writing, brainstorming, summarising, Q&A. Smaller + faster.'
        }
        [pscustomobject]@{
            Tag     = 'carstenuhlig/omnicoder-2-9b:q4_k_m'
            Title   = 'OmniCoder 2 (9B, Q4_K_M)'
            Purpose = 'Agentic + coding model. Use this when you want the LLM to'
            Purpose2= 'write/edit code, drive tools, or plan multi-step tasks.'
        }
    )

    # Image-awareness: only print the header + wait for Ollama if there's
    # actually something to install. When both starters are already pulled
    # (re-run scenario) we'd otherwise spend 30-90s waiting for the Ollama
    # API just to print "already installed - skipping" twice.
    $needed = @()
    if (Wait-Ollama -TimeoutSeconds 5) {
        foreach ($m in $starters) {
            if (-not (Test-OllamaModelInstalled -Tag $m.Tag)) { $needed += $m.Tag }
        }
    } else {
        # Ollama not up yet - assume nothing is installed and let the
        # full path below wait for it. This is the fresh-install case.
        $needed = $starters | ForEach-Object { $_.Tag }
    }
    if ($needed.Count -eq 0) {
        Dim "  Starter LLMs already installed (both models present) - skipping."
        return
    }

    Step 'Step 5 - Starter LLMs' 'Auto-installing two recommended models so you have something to chat with out of the box. This may take a few minutes per model (~5 GB each).'

    if (-not (Wait-Ollama -TimeoutSeconds 90)) {
        Err 'Ollama is not responding on http://127.0.0.1:11434. Skipping model install.'
        Dim "  You can run $managerName after Ollama is up."
        return
    }

    foreach ($m in $starters) {
        G ''
        Dim '  ----------------------------------------------------------------'
        G  "  $($m.Title)"
        Dim "    $($m.Purpose)"
        Dim "    $($m.Purpose2)"
        Dim "    Tag: $($m.Tag)"
        Dim '  ----------------------------------------------------------------'

        if (Test-OllamaModelInstalled -Tag $m.Tag) {
            Ok "$($m.Tag) already installed - skipping."
            continue
        }

        if (Invoke-OllamaPull -Tag $m.Tag) {
            Ok "Installed $($m.Tag)"
        } else {
            Err "Failed to pull $($m.Tag). You can retry from $managerName."
        }
    }

    G ''
    Dim '  ----------------------------------------------------------------'
    G  '  Want a MONSTER uncensored model?'
    Dim '  ----------------------------------------------------------------'
    Dim '  These take much more VRAM (~16-24 GB) but are noticeably smarter'
    Dim '  than the starters. Pull from the LLM Manager when you have the'
    Dim '  hardware:'
    Dim ''
    Dim '    iaprofesseur/SuperGemma4-26b-uncensored-Q4'
    Dim '      26B-param Gemma 4 variant. Uncensored, strong reasoning,'
    Dim '      great for long-form writing and tougher Q&A.'
    Dim ''
    Dim '    fredrezones55/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:Q4'
    Dim '      35B-param Qwen 3.6 MoE (A3B active). Uncensored aggressive'
    Dim '      finetune; the heaviest-hitter on the recommended list.'
    Dim ''
    Dim "  Pull them from $managerName -> [4] LLM Manager -> [2] Pull a"
    Dim '  Recommended/Custom Model. Both are already in recommended_models.txt.'
}

# ---------------------------------------------------------------------------
# Final summary.
# ---------------------------------------------------------------------------
function Show-Summary {
    param($Result)
    G ''
    G '  ============================================================'
    G '   All done.'
    G '  ============================================================'
    G ''
    if ($Result.UseTunnel -and $Result.Env['DOMAIN']) {
        Dim "  Hosting mode: ONLINE  (Cloudflare tunnel on $($Result.Env['DOMAIN']))"
        Dim '                Apps reachable from anywhere via your subdomains.'
    } else {
        Dim '  Hosting mode: LOCAL ONLY  (LAN access only; nothing exposed publicly)'
    }
    if ($Result.HasAi) {
        $gpuLabel = switch ($Result.GpuMode) {
            'nvidia' { 'NVIDIA GPU (CUDA, in-container Ollama)' }
            'amd'    { 'AMD GPU (ROCm, in-container Ollama)' }
            'native' { 'NATIVE Ollama on macOS (Metal) - in-container ollama disabled' }
            default  { 'CPU only (in-container Ollama)' }
        }
        Dim "  GPU mode    : $gpuLabel"
    }
    G ''
    G '  Open these in your browser:'
    Dim '  (*.localhost auto-resolves to 127.0.0.1 in every modern browser -'
    Dim '   Caddy on :80 proxies each subdomain to the right container.)'
    G ''
    G '    Heimdall (start page)   http://hub.localhost'
    G '    Portainer               http://portainer.localhost'
    if ($Result.HasMedia) {
        G ''
        Dim '  MEDIA & PRODUCTIVITY'
        G '    Jellyfin (movies/TV)    http://movie.localhost'
        G '    Navidrome (music)       http://music.localhost'
        G '    Immich (photos/videos)  http://photos.localhost'
        G '    Filebrowser             http://file.localhost'
        G '    Omni Tools              http://tool.localhost'
        G '    Tor Browser (auto-login) http://tor.localhost/'
        G ''
        Dim '  REQUEST / DOWNLOAD STACK'
        G '    Seerr (request UI)      http://request.localhost'
        G '    Sonarr (TV)             http://sonarr.localhost'
        G '    Radarr (movies)         http://radarr.localhost'
        G '    Prowlarr (indexers)     http://prowlarr.localhost'
        G '    qBittorrent             http://torrent.localhost   (admin / adminadmin)'
    }
    if ($Result.HasAi) {
        G ''
        Dim '  AI'
        G '    Open WebUI (chat)       http://chat.localhost'
        G '    Hermes Agent            http://hermes.localhost   (dashboard; auto-wired to Ollama)'
        G '    SearXNG (search)        http://search.localhost'
        G '    Local Deep Research     http://research.localhost'
        G '    Vane (AI search)        http://smartsearch.localhost'
        G '    n8n (workflows)         http://n8n.localhost'
        G '    Qdrant (vector DB)      http://qdrant.localhost'
        Dim '    Ollama API (direct)     http://localhost:11434  (API-only, no UI)'
        Dim '    Hermes Agent API        http://localhost:8642   (API-only)'
    }
    if ($Result.UseTunnel -and $Result.Env['DOMAIN']) {
        $d = $Result.Env['DOMAIN']
        G ''
        Dim "  ONLINE - via Cloudflare tunnel at *.$d"
        G "    Heimdall   https://hub.$d"
        if ($Result.HasMedia) {
            G "    Jellyfin   https://movie.$d"
            G "    Navidrome  https://music.$d"
            G "    Immich     https://photos.$d"
            G "    Files      https://file.$d"
        }
        if ($Result.HasAi) {
            G "    Open WebUI https://chat.$d"
            G "    Hermes     https://hermes.$d"
            G "    SearXNG    https://search.$d"
            G "    n8n        https://n8n.$d"
        }
        G ''
        Dim '  ============================================================'
        G  "  PART B - Cloudflare Public Hostnames (do this now in your browser)"
        Dim '  ============================================================'
        G  ''
        G  "  Cloudflared is already running and connected to your tunnel."
        G  "  You now need to tell Cloudflare which subdomains route to it."
        G  ''
        G  "  Go back to your tunnel in https://dash.cloudflare.com/  ->  Networks"
        G  "  ->  Tunnels  ->  (your tunnel)  ->  'Public Hostname' tab."
        G  ''
        G  "  EASIEST PATH (one wildcard covers every service):"
        Dim '    Subdomain : *'
        Dim "    Domain    : $d"
        Dim '    Path      : (leave blank)'
        Dim '    Service   : Type=HTTP  ,  URL=caddy:80'
        Dim '    Click "Save hostname".'
        G  ''
        G  "  OR explicit (one Public Hostname per service - more granular):"
        Dim "    hub.$d         ->  HTTP  caddy:80   Heimdall (start page)"
        if ($Result.HasMedia) {
            Dim "    movie.$d       ->  HTTP  caddy:80   Jellyfin"
            Dim "    music.$d       ->  HTTP  caddy:80   Navidrome"
            Dim "    photos.$d      ->  HTTP  caddy:80   Immich"
            Dim "    file.$d        ->  HTTP  caddy:80   Filebrowser"
            Dim "    tor.$d         ->  HTTP  caddy:80   Tor Browser (SSO)"
            Dim "    tool.$d        ->  HTTP  caddy:80   Omni Tools"
            Dim "    request.$d     ->  HTTP  caddy:80   Seerr (requests)"
            Dim "    sonarr.$d      ->  HTTP  caddy:80   Sonarr (TV)"
            Dim "    radarr.$d      ->  HTTP  caddy:80   Radarr (movies)"
            Dim "    prowlarr.$d    ->  HTTP  caddy:80   Prowlarr (indexers)"
            Dim "    torrent.$d     ->  HTTP  caddy:80   qBittorrent"
        }
        if ($Result.HasAi) {
            Dim "    chat.$d        ->  HTTP  caddy:80   Open WebUI"
            Dim "    hermes.$d      ->  HTTP  caddy:80   Hermes Agent (dashboard)"
            Dim "    search.$d      ->  HTTP  caddy:80   SearXNG"
            Dim "    n8n.$d         ->  HTTP  caddy:80   n8n workflows"
            Dim "    smartsearch.$d ->  HTTP  caddy:80   Vane AI engine"
            Dim "    research.$d    ->  HTTP  caddy:80   Local Deep Research"
            Dim "    qdrant.$d      ->  HTTP  caddy:80   Qdrant vector DB"
        }
        Dim "    portainer.$d   ->  HTTP  caddy:80   Portainer (SSO)"
        Dim "    auth.$d        ->  HTTP  caddy:80   Authelia login (REQUIRED)"
        G  ''
        G  "  NOTE: 'caddy:80' is the internal docker hostname of the reverse proxy."
        G  "        Cloudflared reaches it on the docker 'caddy' network. Do NOT"
        G  "        use http://localhost - that's a different machine from cloudflared's view."
        G  ''
        Dim '  Once those Public Hostnames are saved, your subdomains are live.'
        Dim "  Test:  https://hub.$d  (should show Heimdall)."
        if (Ask-YesNo '  Open the Cloudflare tunnels page now?' $false) {
            Open-Browser 'https://dash.cloudflare.com/'
        }
    }
    G ''
    Dim '  ------------------------------------------------------------'
    G '  Default credentials  (admin / admin everywhere)'
    Dim '  ------------------------------------------------------------'
    Dim '    Auto-configured by the wizard:'
    G  '      Jellyfin           admin / admin'
    G  '      Seerr              admin / admin   (signs in via Jellyfin)'
    G  '      qBittorrent        admin / adminadmin   (v5 requires >=6 chars)'
    G  '      Authelia           admin / admin   (tunnel-mode SSO gate)'
    Dim '    First-visit signup - type admin / admin when prompted:'
    G  '      Portainer          admin / admin   (asks on first visit)'
    G  '      Filebrowser        admin / admin   (default)'
    if ($Result.HasMedia) {
        G  '      Immich             admin@local.host / admin   (admin signup form)'
        G  '      Navidrome          admin / admin   (first-visit prompt)'
    }
    if ($Result.HasAi) {
        G  '      Open WebUI         admin / admin   (first-visit signup)'
        G  '      n8n                admin@local.host / admin   (owner signup)'
    }
    Dim '    Sonarr / Radarr / Prowlarr / Heimdall: no login required'
    Dim '    (External auth + LAN trust on .localhost; Authelia gates them in tunnel mode).'
    if ($Result.UseTunnel) {
        G  ''
        Dim '    [!] Tunnel mode is ON. Change Authelia + Jellyfin + Seerr + qBittorrent'
        Dim '        passwords NOW - these are reachable from the public internet via Cloudflare.'
    }
    Dim '  ------------------------------------------------------------'
    G ''
    Dim '  ------------------------------------------------------------'
    G '  Privacy at a glance:'
    Dim '    [+] Everything runs on YOUR machine. No cloud account required.'
    Dim '    [+] No telemetry, no analytics, no phone-home.'
    if ($Result.HasAi) {
        Dim '    [+] LLMs run locally via Ollama. Prompts never leave your network.'
        Dim '    [+] Searches go through SearXNG (no tracking, no profile building).'
    }
    if ($Result.UseTunnel) {
        Dim '    [!] Tunnel mode is ON: Cloudflare is in the request path for'
        Dim '        traffic from outside your LAN. LAN access stays direct.'
    } else {
        Dim '    [+] Local-only mode: nothing is exposed to the public internet.'
    }
    Dim '  ------------------------------------------------------------'
    G ''
    if ($script:OS -eq 'Mac') {
        Dim '  Tip: re-open MAC-HOMELAB-MANAGER.COMMAND -> pick [2] to start / [3] to stop.'
    } else {
        Dim '  Tip: re-open WINDOWS-HOMELAB-MANAGER.BAT -> pick [2] to start / [3] to stop.'
    }
    G ''
}

# ===========================================================================
# Main flow.
# ===========================================================================
Show-Logo

$script:OS = Get-OS

# Make sure Docker is installed and the engine is reachable. If not, this
# will offer to download + install Docker Desktop, then wait for the engine.
Ensure-Docker -OS $script:OS

$state  = Read-State
$envMap = Read-EnvFile $EnvFile

# -----------------------------------------------------------------------------
# Branch 0: -EditMediaPaths - invoked by the HOMELAB-MANAGER launchers when
# the user picks [6] Edit Media Folders. Standalone editor + validator for
# the 5 host paths the media stack bind-mounts. Doesn't touch anything else.
# -----------------------------------------------------------------------------
if ($EditMediaPaths) {
    Invoke-EditMediaPaths
    exit 0
}

# -----------------------------------------------------------------------------
# Branch -1: -Backup - manager menu's "Backup the stack now". Dumps images +
# volumes + persistent-storage into a portable folder and exits.
# -----------------------------------------------------------------------------
if ($Backup) {
    Invoke-BackupStack -Mode $BackupMode
    exit 0
}

# -----------------------------------------------------------------------------
# Branch -2: -Restore - manager menu's "Restore from a backup folder".
# Loads images + volumes + persistent-storage from a folder and starts.
# -----------------------------------------------------------------------------
if ($Restore) {
    if (Invoke-RestoreStack) {
        # After a successful restore, bring the stack up using whatever state
        # the backup carried.
        $envMap = Read-EnvFile $EnvFile
        $state  = Read-State
        Render-Templates -Env $envMap -StateBlob $state
        $profiles  = if ($state -and $state.profiles)      { @($state.profiles) }      else { @('ai','media') }
        $useTunnel = if ($state -and $state.useTunnel)     { [bool]$state.useTunnel }  else { $false }
        $gpuMode   = if ($state -and $state.gpuMode)       { [string]$state.gpuMode }  else { 'cpu' }
        $custom    = if ($state -and $state.customServices){ @($state.customServices) }else { @() }
        Ensure-NativeOllamaInstalled -GpuMode $gpuMode
        Start-Stack -Profiles $profiles -UseTunnel $useTunnel -GpuMode $gpuMode -CustomServices $custom
    }
    exit 0
}

# -----------------------------------------------------------------------------
# Branch A: -StartOnly - invoked by the HOMELAB-MANAGER launchers when the
# user picks [2] Start Stack.
# SELF-HEALING. Every step that the first-run wizard does (without the
# interactive prompts) runs here too, so the stack comes up cleanly even
# if you skipped first-run, or if Docker silently created stray dirs at
# bind-file paths, or if the Authelia hash placeholder is still in place.
# -----------------------------------------------------------------------------
if ($StartOnly) {
    Step 'Self-heal: preparing the stack to come up cleanly' ''

    # 1. Bootstrap .env from .env.example if needed.
    if (-not (Test-Path $EnvFile)) {
        Copy-Item $EnvExample $EnvFile
        Dim '  Created .env from .env.example.'
        $envMap = Read-EnvFile $EnvFile
    }
    $exampleMap = Read-EnvFile $EnvExample
    foreach ($k in $exampleMap.Keys) {
        if (-not $envMap.Contains($k)) { $envMap[$k] = $exampleMap[$k] }
    }

    # 2. Fill any placeholder secrets in .env silently.
    if (Ensure-EnvSecrets -EnvMap $envMap) {
        Write-EnvFile $EnvFile $envMap
        Ok 'Filled in missing .env secrets.'
    }

    # 2b. Migrate legacy F:\ media defaults to C:/MEDIA/ silently.
    $migratedPaths = Migrate-LegacyMediaDefaults $envMap
    if ($migratedPaths.Count -gt 0) {
        Write-EnvFile $EnvFile $envMap
        Ok "Migrated legacy F:\ media defaults to C:/MEDIA/: $($migratedPaths -join ', ')"
    }

    # 3. Wipe any directories Docker auto-created at bind-file paths.
    Repair-BindPaths

    # 4. Load / synth state blob.
    $stateBlob = if ($state) { $state } else { New-StateBlob }
    foreach ($k in @('SEARXNG_SECRET_KEY','AUTHELIA_JWT_SECRET','AUTHELIA_STORAGE_ENCRYPTION_KEY','profiles','customServices','useTunnel','gpuMode','configured')) {
        if (-not $stateBlob.PSObject.Properties[$k]) {
            $stateBlob | Add-Member -NotePropertyName $k -NotePropertyValue $null
        }
    }
    if (-not $stateBlob.profiles -or $stateBlob.profiles.Count -eq 0) {
        if (-not $stateBlob.customServices -or $stateBlob.customServices.Count -eq 0) {
            $stateBlob.profiles = @('ai','media')
        }
    }
    # Auto-detect tunnel: only enable if the user supplied a real token.
    $stateBlob.useTunnel = -not (Test-Placeholder $envMap['CLOUDFLARE_TUNNEL_TOKEN'])
    # Auto-detect GPU mode if not already persisted by first-run.
    # 'native' is the macOS Apple-Silicon path (host-installed ollama via
    # Homebrew + the docker-compose.ollama-native.yml overlay) - must be
    # in this allowlist or -StartOnly will silently overwrite the saved
    # choice with re-detection (which returns 'cpu' on Mac) and the
    # containerised ollama will be pulled / started instead.
    if (-not $stateBlob.gpuMode -or $stateBlob.gpuMode -notin @('cpu','nvidia','amd','native')) {
        $stateBlob.gpuMode = Get-OllamaGpuMode
        Dim "  Detected GPU mode: $($stateBlob.gpuMode.ToUpper())"
    }
    $stateBlob.configured = $true

    # 5. Render Caddyfile, Authelia configuration.yml, SearXNG settings.yml
    #    (also copies users_database.yml from .example if missing).
    Render-Templates -Env $envMap -StateBlob $stateBlob
    Ok 'Rendered Caddy / Authelia / SearXNG config from templates.'

    # 5b. Rewrite Heimdall start-page tile URLs from the maintainer's
    #     placeholders to whatever the user picked in Step 2b. Idempotent -
    #     no-ops once the placeholders are gone, so this is safe in -StartOnly.
    Ensure-HeimdallTiles -TileDomain $envMap['HEIMDALL_TILE_DOMAIN']

    # 5c. Pre-seed media-stack config files (sonarr/radarr/prowlarr config.xml
    #     + qBittorrent.conf) so each app boots with our known API key and
    #     skips its first-run wizard. Idempotent.
    Pre-Seed-MediaStack -EnvMap $envMap

    # 5d. Render Hermes Agent config.yaml (Ollama-only routing).
    Configure-HermesAgent -EnvMap $envMap

    # 6. Generate Authelia admin argon2 hash if users_database.yml still has
    #    the placeholder. Auto-pulls the authelia image on first run.
    Ensure-AutheliaUser -EnvMap $envMap

    # 7. Persist the (possibly updated) state.
    Write-State -State $stateBlob

    # 8. Start.
    $profiles  = @($stateBlob.profiles)
    $customSvc = @($stateBlob.customServices)
    $useTunnel = [bool]$stateBlob.useTunnel
    $gpuMode   = [string]$stateBlob.gpuMode
    if ($customSvc -and $customSvc.Count -gt 0) {
        $hasAi    = ($customSvc | Where-Object { $_ -in 'ollama','open-webui','searxng','local-deep-research','vane','n8n','n8n-postgres','qdrant','hermes-agent' }).Count -gt 0
        $hasMedia = ($customSvc | Where-Object { $_ -in 'jellyfin','navidrome','immich-server','immich-machine-learning','immich-redis','immich-postgres','filebrowser','omni-tools','tor-browser','seerr','sonarr','radarr','prowlarr','qbittorrent' }).Count -gt 0
    } else {
        $hasAi    = $profiles -contains 'ai'
        $hasMedia = ($profiles -contains 'media') -or ($profiles -contains 'media-stream') -or ($profiles -contains 'productivity')
    }

    # In native mode the host needs ollama on :11434 BEFORE compose comes
    # up - otherwise Open WebUI / LDR / Vane all start with their
    # OLLAMA_BASE_URL pointing at host.docker.internal:11434 and find nothing.
    Ensure-NativeOllamaInstalled -GpuMode $gpuMode

    Start-Stack -Profiles $profiles -UseTunnel $useTunnel -GpuMode $gpuMode -CustomServices $customSvc

    if ($hasAi -and (Get-OllamaModelCount) -eq 0) {
        Install-FirstLlm
    }

    # 9. Once containers are up, wire the *arr stack via REST APIs.
    if ($hasMedia) { Configure-MediaStack -EnvMap $envMap }

    Show-Summary -Result ([pscustomobject]@{
        Env       = $envMap
        HasAi     = $hasAi
        HasMedia  = $hasMedia
        UseTunnel = $useTunnel
        GpuMode   = $gpuMode
    })
    exit 0
}

# -----------------------------------------------------------------------------
# Branch B: full first-run wizard - invoked by the HOMELAB-MANAGER launchers
# when the user picks [1] First-Run Setup.
# -----------------------------------------------------------------------------
$result = Invoke-Wizard

# Step 0 may have short-circuited the wizard with a successful restore.
# Re-read .env + state from the restored files, render templates, and
# go straight to compose-up - no question loop, no secret regeneration.
if ($result -and $result.PSObject.Properties['Restored'] -and $result.Restored) {
    $envMap   = Read-EnvFile $EnvFile
    $state    = Read-State
    Render-Templates -Env $envMap -StateBlob $state
    if (-not $NoStart) {
        $profiles  = if ($state -and $state.profiles)      { @($state.profiles) }      else { @('ai','media') }
        $useTunnel = if ($state -and $state.useTunnel)     { [bool]$state.useTunnel }  else { $false }
        $gpuMode   = if ($state -and $state.gpuMode)       { [string]$state.gpuMode }  else { 'cpu' }
        $custom    = if ($state -and $state.customServices){ @($state.customServices) }else { @() }
        Ensure-NativeOllamaInstalled -GpuMode $gpuMode
        Start-Stack -Profiles $profiles -UseTunnel $useTunnel -GpuMode $gpuMode -CustomServices $custom
    }
    exit 0
}

# Load/extend the state blob and persist secrets + choices.
$stateBlob = if ($state) { $state } else {
    [pscustomobject]@{
        SEARXNG_SECRET_KEY             = ''
        AUTHELIA_JWT_SECRET            = ''
        AUTHELIA_STORAGE_ENCRYPTION_KEY = ''
        profiles                       = @()
        customServices                 = @()
        useTunnel                      = $false
        gpuMode                        = 'cpu'
        configured                     = $false
    }
}
foreach ($k in @('SEARXNG_SECRET_KEY','AUTHELIA_JWT_SECRET','AUTHELIA_STORAGE_ENCRYPTION_KEY','profiles','customServices','useTunnel','gpuMode','configured')) {
    if (-not $stateBlob.PSObject.Properties[$k]) {
        $stateBlob | Add-Member -NotePropertyName $k -NotePropertyValue $null
    }
}
$stateBlob.profiles       = $result.Profiles
$stateBlob.customServices = $result.CustomServices
$stateBlob.useTunnel      = $result.UseTunnel
$stateBlob.gpuMode        = $result.GpuMode
$stateBlob.configured     = $true

# Post-wizard setup. Each step prints a marker so the user can see where
# things are between "Secrets generated" and the compose pull/up phase -
# Ensure-AutheliaUser in particular can take 30-60s on a fresh install
# because it pulls the authelia image to compute the argon2 hash.
Step 'Step 5 - Preparing the stack' 'Rendering configs, fixing bind paths, generating Authelia hash, pre-seeding *arr and Hermes Agent. No questions - just stuff happening.'
Repair-BindPaths
Ok 'Bind paths verified.'
Render-Templates -Env $result.Env -StateBlob $stateBlob
Ok 'Rendered Caddy / Authelia / SearXNG config from templates.'
Ensure-HeimdallTiles -TileDomain $result.Env['HEIMDALL_TILE_DOMAIN']
Pre-Seed-MediaStack -EnvMap $result.Env
Configure-HermesAgent -EnvMap $result.Env
Ensure-AutheliaUser -EnvMap $result.Env
Write-State -State $stateBlob
Ok 'Stack ready to start.'

if (-not $NoStart) {
    # If the user picked NATIVE in Step 3b on Mac, install + start the host
    # ollama before compose-up so the AI services (open-webui,
    # local-deep-research, vane) can reach host.docker.internal:11434 from
    # inside their containers as soon as they boot.
    Ensure-NativeOllamaInstalled -GpuMode $result.GpuMode

    Start-Stack -Profiles $result.Profiles -UseTunnel $result.UseTunnel -GpuMode $result.GpuMode -CustomServices $result.CustomServices
}

if (-not $NoStart -and $result.HasAi) {
    if ((Get-OllamaModelCount) -eq 0) {
        Install-FirstLlm
    }
}

if (-not $NoStart -and $result.HasMedia) {
    Configure-MediaStack -EnvMap $result.Env
}

Show-Summary -Result $result

# Post-wizard niceties. Only runs after the FULL first-run wizard
# (not on -StartOnly), and only when the stack was actually brought up.
if (-not $NoStart) {
    G ''
    Step 'Final touches' 'One-click access for next time.'
    # 1. Auto-open Heimdall - works for both local-only (hub.localhost) and
    #    tunnel mode (hub.<DOMAIN>); falls back to the direct port if Caddy
    #    isn't part of the picked stack for some reason.
    $heimdallUrl = if ($result.UseTunnel -and $result.Env['DOMAIN']) {
        "https://hub.$($result.Env['DOMAIN'])"
    } else {
        'http://hub.localhost'
    }
    # Heimdall is up the moment its container reports running, but the
    # internal nginx + PHP-FPM stack can still 502 for a second or two
    # while warming. Give it a visible 5s countdown so the user knows
    # why we're stalling.
    for ($i = 5; $i -ge 1; $i--) {
        Write-Host "`r  Opening Heimdall at $heimdallUrl in ${i}s... " -NoNewline -ForegroundColor DarkGreen
        Start-Sleep -Seconds 1
    }
    Write-Host "`r  Opening Heimdall at $heimdallUrl ...           " -ForegroundColor DarkGreen
    Open-Browser $heimdallUrl
    # 2. Offer a Desktop shortcut for next time. Default = yes, since users
    #    who don't want desktop clutter can just say n.
    if ($script:OS -in @('Windows','Mac')) {
        if (Ask-YesNo '  Create a Desktop shortcut that one-clicks the whole stack up?' $true) {
            Add-DesktopShortcut
        }
    }
}
