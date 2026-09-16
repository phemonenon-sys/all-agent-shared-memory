[CmdletBinding()]
param(
    [string]$StorePath = '',
    [string]$HomeDir = '',
    [switch]$DryRun,
    [switch]$RemoveStore,
    [switch]$SkipBridge,
    [switch]$SkipClaude,
    [switch]$SkipOpencode,
    [switch]$SkipCodex,
    [switch]$SkipBlocks,
    [switch]$SkipGemini
)

$ErrorActionPreference = 'Stop'
if (-not $HomeDir) { $HomeDir = $env:USERPROFILE }
if (-not $StorePath) { $StorePath = Join-Path $HomeDir '.agents\memory' }
$RegisterClaudeCli = ($HomeDir -eq $env:USERPROFILE)
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

# 1. Claude Code: remove our SessionStart hook handler + agent_bridge MCP (user scope)
Step "1/7 Claude Code"
$claudeSettings = Join-Path $HomeDir '.claude\settings.json'
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
            elseif ($j.hooks.PSObject.Properties.Name -contains 'SessionStart') { $j.hooks.PSObject.Properties.Remove('SessionStart') }
            if (-not $j.hooks.PSObject.Properties.Name) { $j.PSObject.Properties.Remove('hooks') }
            $new = $j | ConvertTo-Json -Depth 20
            $null = $new | ConvertFrom-Json
            Write-Text $claudeSettings $new
            Say "  removed shared-memory SessionStart hook"
        } catch { Say "  WARN: could not clean settings.json ($($_.Exception.Message)); restore from backup if needed" }
    }
}
if (-not $SkipClaude -and -not $SkipBridge) {
    $claudeCli = (Get-Command claude -ErrorAction SilentlyContinue).Source
    if ($claudeCli -and $RegisterClaudeCli) {
        if ($DryRun) { Say "  would run: claude mcp remove agent_bridge -s user" }
        else { & $claudeCli mcp remove agent_bridge -s user 2>&1 | Out-Null; Say "  claude: agent_bridge MCP removed (if present)" }
    } elseif ($claudeCli -and -not $RegisterClaudeCli) {
        Say "  claude: skipped MCP removal (custom -HomeDir)"
    }
}

# 2. opencode: remove ai_memory + agent_bridge + instructions entry
Step "2/7 opencode"
$oc = Join-Path $HomeDir '.config\opencode\opencode.json'
if ($SkipOpencode) { Say "  skipped (-SkipOpencode)" }
elseif (-not (Test-Path $oc)) { Say "  no opencode.json - skipped" }
else {
    $raw = Read-Text $oc
    $hasMemory = $raw -match 'ai_memory'
    $hasBridge = $raw -match 'agent_bridge'
    if (-not $hasMemory -and -not $hasBridge) { Say "  nothing registered - skipped" }
    elseif ($DryRun) { Say "  would remove mcp.ai_memory / mcp.agent_bridge + MEMORY.md instruction" }
    else {
        Backup $oc
        try {
            $j = $raw | ConvertFrom-Json
            foreach ($name in @('ai_memory', 'agent_bridge')) {
                if ($j.mcp -and ($j.mcp.PSObject.Properties.Name -contains $name)) { $j.mcp.PSObject.Properties.Remove($name) }
            }
            if ($j.instructions) {
                $kept = @($j.instructions) | Where-Object { $_ -and $_ -notmatch 'agents[\\/]memory' }
                $j.instructions = $kept
            }
            $new = $j | ConvertTo-Json -Depth 32
            $null = $new | ConvertFrom-Json
            Write-Text $oc $new
            Say "  removed memory/bridge MCP entries + instructions entry"
        } catch { Say "  WARN: could not clean opencode.json ($($_.Exception.Message))" }
    }
}

# 3. Codex: remove [mcp_servers.ai_memory] and [mcp_servers.agent_bridge] sections
Step "3/7 Codex"
$ct = Join-Path $HomeDir '.codex\config.toml'
if ($SkipCodex) { Say "  skipped (-SkipCodex)" }
elseif (-not (Test-Path $ct)) { Say "  no config.toml - skipped" }
else {
    $raw = Read-Text $ct
    if ($raw -notmatch '\[mcp_servers\.(ai_memory|agent_bridge)\]') { Say "  nothing registered - skipped" }
    elseif ($DryRun) { Say "  would remove [mcp_servers.ai_memory] / [mcp_servers.agent_bridge] sections" }
    else {
        Backup $ct
        $lines = [System.IO.File]::ReadAllLines($ct)
        $out = New-Object System.Collections.Generic.List[string]
        $skipping = $false
        foreach ($line in $lines) {
            if ($line.Trim() -in @('[mcp_servers.ai_memory]', '[mcp_servers.agent_bridge]')) { $skipping = $true; continue }
            if ($skipping -and $line -match '^\[') { $skipping = $false }
            if (-not $skipping) { $out.Add($line) }
        }
        Write-Text $ct (($out -join "`r`n").TrimEnd() + "`r`n")
        Say "  removed ai_memory/agent_bridge sections"
    }
}

# 4. AGENTS.md managed blocks
Step "4/7 AGENTS.md blocks"
if ($SkipBlocks) { Say "  skipped (-SkipBlocks)" }
else {
    $hostsFile = Join-Path $StorePath 'hosts.json'
    $targets = @(
        (Join-Path $HomeDir '.codex\AGENTS.md'),
        (Join-Path $HomeDir '.zcode\workspace\default\AGENTS.md')
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

# 5. agent-bridge: MCP registration already handled above; remove deployment + scheduler + Gemini
Step "5/7 agent-bridge"
if ($SkipBridge) { Say "  skipped (-SkipBridge)" }
else {
    $bridgePath = Join-Path (Split-Path $StorePath -Parent) 'agent-bridge'
    $schedulerPath = Join-Path (Split-Path $StorePath -Parent) 'scheduler'
    $bridgePresent = (Test-Path (Join-Path $bridgePath 'bridge-mcp.py'))
    $schedulerTasks = @()
    $tasksDir = Join-Path $schedulerPath 'tasks'
    if (Test-Path $tasksDir) { $schedulerTasks = @(Get-ChildItem $tasksDir -Filter *.cmd -ErrorAction SilentlyContinue) }

    if (-not $bridgePresent -and $schedulerTasks.Count -eq 0) { Say "  bridge not deployed - skipped" }
    elseif ($DryRun) {
        if ($bridgePresent) { Say "  would delete $bridgePath" }
        if ($schedulerTasks.Count -gt 0) { Say "  would delete $($schedulerTasks.Count) scheduled task(s) + $schedulerPath" }
    } else {
        foreach ($wrapper in $schedulerTasks) {
            $taskName = "AgentScheduler\$($wrapper.BaseName)"
            & schtasks /Delete /F /TN $taskName 2>&1 | Out-Null
            Say "  scheduler: removed task $taskName"
        }
        if ($schedulerTasks.Count -gt 0 -and (Test-Path $schedulerPath)) { Remove-Item $schedulerPath -Recurse -Force; Say "  scheduler: removed $schedulerPath" }
        if ($bridgePresent) { Remove-Item $bridgePath -Recurse -Force; Say "  deleted $bridgePath" }
    }
}

# 6. Gemini import line
Step "6/7 Gemini"
if ($SkipGemini) { Say "  skipped (-SkipGemini)" }
else {
    $geminiFile = Join-Path $HomeDir '.gemini\GEMINI.md'
    if (-not (Test-Path $geminiFile)) { Say "  no GEMINI.md - skipped" }
    else {
        $content = Read-Text $geminiFile
        if ($content -notmatch 'agents[\\/]memory') { Say "  no import line found - skipped" }
        elseif ($DryRun) { Say "  would remove MEMORY.md import line from $geminiFile" }
        else {
            Backup $geminiFile
            $new = [regex]::Replace($content, "(?m)^@.*agents[\\/]memory[^\r\n]*\r?\n?", "")
            Write-Text $geminiFile $new.TrimEnd() + "`r`n"
            Say "  removed import line from $geminiFile"
        }
    }
}

# 7. optional store removal
Step "7/7 Store"
if ($RemoveStore) {
    if (-not (Test-Path (Join-Path $StorePath 'MEMORY.md'))) { Say "  store not found at $StorePath - skipped" }
    elseif ($DryRun) { Say "  would delete $StorePath" }
    else {
        if ($StorePath -match '^\w:\\$' -or -not ($StorePath -match '\\')) { Say "  refused: unsafe store path ($StorePath)" }
        else { Remove-Item $StorePath -Recurse -Force; Say "  deleted $StorePath" }
    }
} else {
    Say "  kept $StorePath (pass -RemoveStore to delete it)"
}

Step "Done"
Say "  hooks/MCP registrations removed; *.bak-uninstall-* backups kept for rollback."
