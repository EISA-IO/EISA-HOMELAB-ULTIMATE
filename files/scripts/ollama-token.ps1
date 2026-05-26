# =============================================================================
# Ollama token manager - DARKO Homelab
#
# Issues, lists, revokes, and rotates bearer tokens used by external clients
# (e.g. the cloud-deployed Executive Brief) to call the homelab's remote
# Ollama endpoint at https://ollama.<DOMAIN>.
#
# Security model:
#   - Tokens are 256-bit cryptographically-random strings (base64url).
#   - PLAINTEXT IS ONLY SHOWN ONCE, at issue time. Hashes (SHA-256) are
#     persisted; the homelab itself cannot recover the plaintext.
#   - Constant-time comparison happens in the ollama-auth sidecar at request
#     time. This script only manages the persisted hash list.
#   - The token file (persistent-storage/do-not-delete/ollama-auth/tokens.json)
#     is mounted read-only into the ollama-auth container.
#
# Usage:
#   pwsh files/scripts/ollama-token.ps1 issue   <label> [-Expires <YYYY-MM-DD>]
#   pwsh files/scripts/ollama-token.ps1 list
#   pwsh files/scripts/ollama-token.ps1 revoke  <id-or-label>
#   pwsh files/scripts/ollama-token.ps1 rotate  <label>  [-Expires <YYYY-MM-DD>]
#
# Tokens take effect within ~5s of issuance (the sidecar reloads on mtime).
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet('issue', 'list', 'revoke', 'rotate')]
    [string]$Command,

    [Parameter(Position=1)]
    [string]$Target,

    [Parameter()]
    [string]$Expires
)

$ErrorActionPreference = 'Stop'

# Resolve the token file relative to this script: scripts/ -> persistent-storage/...
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot   = Split-Path -Parent $scriptRoot   # = .../files
$tokenDir   = Join-Path $repoRoot 'persistent-storage/do-not-delete/ollama-auth'
$tokenFile  = Join-Path $tokenDir 'tokens.json'

function Ensure-TokenStore {
    if (-not (Test-Path $tokenDir))  { New-Item -ItemType Directory -Force -Path $tokenDir  | Out-Null }
    if (-not (Test-Path $tokenFile)) {
        $seed = @{ tokens = @() } | ConvertTo-Json -Depth 6
        Set-Content -Path $tokenFile -Value $seed -Encoding UTF8
    }
}

function Read-Store {
    Ensure-TokenStore
    $raw = Get-Content -Raw -Path $tokenFile -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) { return [pscustomobject]@{ tokens = @() } }
    return $raw | ConvertFrom-Json
}

function Write-Store {
    param($Store)
    if (-not $Store.tokens) { $Store | Add-Member -NotePropertyName tokens -NotePropertyValue @() -Force }
    # Atomic write: stage to temp file, then move.
    $tmp = "$tokenFile.tmp"
    ($Store | ConvertTo-Json -Depth 6) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Force -Path $tmp -Destination $tokenFile
}

function New-StrongToken {
    # 32 bytes (256 bits) of entropy, encoded base64url, ~43 chars.
    $b = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    $b64 = [Convert]::ToBase64String($b)
    return ($b64.Replace('+', '-').Replace('/', '_').TrimEnd('='))
}

function Get-Sha256Hex {
    param([string]$Text)
    $bytes  = [Text.Encoding]::UTF8.GetBytes($Text)
    $sha    = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
        return (-join ($hash | ForEach-Object { $_.ToString('x2') }))
    } finally {
        $sha.Dispose()
    }
}

function New-TokenId {
    return ([guid]::NewGuid().ToString('n').Substring(0, 12))
}

function Validate-Expires {
    param([string]$Iso)
    if ([string]::IsNullOrWhiteSpace($Iso)) { return $null }
    try {
        $dt = [datetime]::Parse($Iso, [System.Globalization.CultureInfo]::InvariantCulture)
        return $dt.ToUniversalTime().ToString('o')
    } catch {
        throw "Invalid -Expires value '$Iso'. Use YYYY-MM-DD (UTC)."
    }
}

function Find-Entry {
    param($Store, [string]$IdOrLabel)
    if ([string]::IsNullOrWhiteSpace($IdOrLabel)) { return $null }
    $match = $Store.tokens | Where-Object { $_.id -eq $IdOrLabel }
    if (-not $match) {
        $match = $Store.tokens | Where-Object { $_.label -eq $IdOrLabel -and -not $_.disabled }
    }
    return $match
}

# --- commands ---

function Cmd-Issue {
    param([string]$Label, [string]$ExpiresIso)
    if ([string]::IsNullOrWhiteSpace($Label)) { throw 'Label is required: ollama-token issue <label>' }
    $exp = Validate-Expires $ExpiresIso
    $store = Read-Store
    $existing = $store.tokens | Where-Object { $_.label -eq $Label -and -not $_.disabled }
    if ($existing) {
        Write-Warning "An active token already exists for label '$Label' (id=$($existing.id)). Use rotate to replace it."
    }
    $plaintext = New-StrongToken
    $entry = [pscustomobject]@{
        id         = New-TokenId
        label      = $Label
        sha256     = Get-Sha256Hex $plaintext
        createdAt  = (Get-Date).ToUniversalTime().ToString('o')
        expiresAt  = $exp
        disabled   = $false
    }
    $store.tokens = @($store.tokens) + $entry
    Write-Store $store

    Write-Host ''
    Write-Host '  Token issued. SAVE THIS NOW - it will never be shown again.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  Label : $($entry.label)"
    Write-Host "  ID    : $($entry.id)"
    Write-Host "  Token : $plaintext" -ForegroundColor Green
    if ($exp) { Write-Host "  Expires: $exp" }
    Write-Host ''
    Write-Host '  Test: curl -H "Authorization: Bearer <token>" https://ollama.<your-domain>/api/tags'
    Write-Host ''
}

function Cmd-List {
    $store = Read-Store
    if (-not $store.tokens -or $store.tokens.Count -eq 0) {
        Write-Host '(no tokens issued)'
        return
    }
    $store.tokens |
        Select-Object id, label, createdAt, expiresAt, disabled |
        Sort-Object disabled, createdAt |
        Format-Table -AutoSize
}

function Cmd-Revoke {
    param([string]$IdOrLabel)
    if ([string]::IsNullOrWhiteSpace($IdOrLabel)) { throw 'Target is required: ollama-token revoke <id-or-label>' }
    $store = Read-Store
    $entry = Find-Entry $store $IdOrLabel
    if (-not $entry) { throw "No active token matches '$IdOrLabel'." }
    $entry.disabled = $true
    $entry | Add-Member -NotePropertyName revokedAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    Write-Store $store
    Write-Host "Revoked token id=$($entry.id) (label='$($entry.label)'). Effective within ~5s."
}

function Cmd-Rotate {
    param([string]$Label, [string]$ExpiresIso)
    if ([string]::IsNullOrWhiteSpace($Label)) { throw 'Label is required: ollama-token rotate <label>' }
    $store = Read-Store
    $active = $store.tokens | Where-Object { $_.label -eq $Label -and -not $_.disabled }
    foreach ($e in $active) {
        $e.disabled = $true
        $e | Add-Member -NotePropertyName revokedAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    }
    Write-Store $store
    Cmd-Issue -Label $Label -ExpiresIso $ExpiresIso
}

switch ($Command) {
    'issue'  { Cmd-Issue  -Label  $Target -ExpiresIso $Expires }
    'list'   { Cmd-List }
    'revoke' { Cmd-Revoke -IdOrLabel $Target }
    'rotate' { Cmd-Rotate -Label  $Target -ExpiresIso $Expires }
}
