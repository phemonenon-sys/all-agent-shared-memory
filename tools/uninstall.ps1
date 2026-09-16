[CmdletBinding()]
param(
    [string]$StorePath = (Join-Path $env:USERPROFILE '.agents\memory'),
    [switch]$DryRun,
    [switch]$RemoveStore,
    [switch]$SkipClaude,
    [switch]$SkipOpencode,
    [switch]$SkipCodex,
    [switch]$SkipBlocks
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Say([string]$msg) { Write-Output $msg }
function Step([string]$msg) { Write-Output ""; Write-Output "== $msg" }
function Read-Text([string]$Path) { if (Test-Path $Path) { return [System.IO.File]::ReadAllText($Path) } return '' }
function Write-Text([string]$Path, [string]$Content) { [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom) }
function Backup([string]$Path) {
    if (Test-Path $Path) {
        Copy-Item $Path "$Path.bak-uninstall-$stamp" -Force
        Say "  backup -> $Path.bak-uninstall-$stamp"
    }
}

Step "Uninstalling All-Agent Shared Memory wiring"
Say "  store: $StorePath"
if ($DryRun) { Say "  MODE : DryRun (no changes will be written)" }

# 1. Claude Code: remove our SessionStart hook handler
Step "1/4 Claude Code hook"
$claudeSettings = Join-Path $env:USERPROFILE '.claude\settings.json'
if ($SkipClaude) { Say "  skipped (-SkipClaude)" }
elseif (-not (Test-Path $claudeSettings)) { Say "  no settings.json - skipped" }
else {
    $raw = Read-Text $claudeSettings
    if ($raw -notmatch 'sessionstart-hook') { Say "  no shared-memory hook found - skipped" }
    elseif ($DryRun) { Say "  would remove SessionStart handler referencing sessionstart-hook" }
    else {
        Backup $claudeSettings
        try {
            $j = $raw | ConvertFrom-Json
            $groups = @($j.hooks.SessionStart)
            $keptGroups = @()
            foreach ($group in $groups) {
                $handlers = @($group.hooks | Where-Object { $_.command -notmatch 'sessionstart-hook' })
                if ($handlers.Count -gt 0) { $group.hooks = $handlers; $keptGroups += $group }
            }
            if ($keptGroups.Count -gt 0) { $j.hooks.SessionStart = $keptGroups }
            else { $j.hooks.PSObject.Properties.Remove('SessionStart') }
            if (-not $j.hooks.PSObject.Properties.Name) { $j.PSObject.Properties.Remove('hooks') }
            $new = $j | ConvertTo-Json -Depth 20
            $null = $new | ConvertFrom-Json
            Write-Text $claudeSettings $new
            Say "  removed shared-memory SessionStart hook"
        } catch { Say "  WARN: could not clean settings.json ($($_.Exception.Message)); restore from backup if needed" }
    }
}

# 2. opencode: remove ai_memory MCP + instructions entry
Step "2/4 opencode"
$oc = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
if ($SkipOpencode) { Say "  skipped (-SkipOpencode)" }
elseif (-not (Test-Path $oc)) { Say "  no opencode.json - skipped" }
else {
    $raw = Read-Text $oc
    if ($raw -notmatch 'ai_memory') { Say "  ai_memory not registered - skipped" }
    elseif ($DryRun) { Say "  would remove mcp.ai_memory + MEMORY.md instruction" }
    else {
        Backup $oc
        try {
            $j = $raw | ConvertFrom-Json
            if ($j.mcp -and $j.mcp.PSObject.Properties.Name -contains 'ai_memory') { $j.mcp.PSObject.Properties.Remove('ai_memory') }
            if ($j.instructions) {
                $kept = @($j.instructions) | Where-Object { $_ -and $_ -notmatch 'agents[\\/]memory' }
                $j.instructions = $kept
            }
            $new = $j | ConvertTo-Json -Depth 32
            $null = $new | ConvertFrom-Json
            Write-Text $oc $new
            Say "  removed mcp.ai_memory + instructions entry"
        } catch { Say "  WARN: could not clean opencode.json ($($_.Exception.Message))" }
    }
}

# 3. Codex: remove [mcp_servers.ai_memory] section
Step "3/4 Codex"
$ct = Join-Path $env:USERPROFILE '.codex\config.toml'
if ($SkipCodex) { Say "  skipped (-SkipCodex)" }
elseif (-not (Test-Path $ct)) { Say "  no config.toml - skipped" }
else {
    $raw = Read-Text $ct
    if ($raw -notmatch '\[mcp_servers\.ai_memory\]') { Say "  ai_memory not registered - skipped" }
    elseif ($DryRun) { Say "  would remove [mcp_servers.ai_memory] section" }
    else {
        Backup $ct
        $lines = [System.IO.File]::ReadAllLines($ct)
        $out = New-Object System.Collections.Generic.List[string]
        $skipping = $false
        foreach ($line in $lines) {
            if ($line.Trim() -eq '[mcp_servers.ai_memory]') { $skipping = $true; continue }
            if ($skipping -and $line -match '^\[') { $skipping = $false }
            if (-not $skipping) { $out.Add($line) }
        }
        Write-Text $ct (($out -join "`r`n").TrimEnd() + "`r`n")
        Say "  removed [mcp_servers.ai_memory] section"
    }
}

# 4. AGENTS.md managed blocks
Step "4/4 AGENTS.md blocks"
if ($SkipBlocks) { Say "  skipped (-SkipBlocks)" }
else {
    $hostsFile = Join-Path $StorePath 'hosts.json'
    $targets = @(
        (Join-Path $env:USERPROFILE '.codex\AGENTS.md'),
        (Join-Path $env:USERPROFILE '.zcode\workspace\default\AGENTS.md')
    )
    if (Test-Path $hostsFile) {
        try {
            $cfg = Get-Content $hostsFile -Raw | ConvertFrom-Json
            if ($cfg.block_targets) { $targets = @($cfg.block_targets) }
        } catch { }
    }
    foreach ($target in $targets) {
        if (-not (Test-Path $target)) { Say "  $target - not present"; continue }
        $content = Read-Text $target
        if ($content -notmatch 'AI-MEMORY:BEGIN') { Say "  $target - no block found"; continue }
        if ($DryRun) { Say "  would remove AI-MEMORY block from $target"; continue }
        Backup $target
        $pattern = "(?s)\r?\n*<!-- AI-MEMORY:BEGIN -->.*?<!-- AI-MEMORY:END -->\r?\n?"
        $new = [regex]::Replace($content, $pattern, "`r`n")
        Write-Text $target $new
        Say "  removed block from $target"
    }
}

# 5. optional store removal
Step "5/5 Store"
if ($RemoveStore) {
    if (-not (Test-Path (Join-Path $StorePath 'MEMORY.md'))) { Say "  store not found at $StorePath - skipped" }
    elseif ($DryRun) { Say "  would delete $StorePath" }
    else {
        $parent = Split-Path $StorePath -Parent
        if ($StorePath -like '*\*' -and $StorePath -notmatch '^\w:\\$' -and (Test-Path $StorePath)) {
            Remove-Item $StorePath -Recurse -Force
            Say "  deleted $StorePath"
        } else { Say "  refused: unsafe store path ($StorePath)" }
    }
} else {
    Say "  kept $StorePath (pass -RemoveStore to delete it)"
}

Step "Done"
Say "  hooks/MCP registrations removed; *.bak-uninstall-* backups kept for rollback."
