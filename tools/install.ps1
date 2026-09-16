[CmdletBinding()]
param(
    [string]$StorePath = (Join-Path $env:USERPROFILE '.agents\memory'),
    [string]$RepoRoot = '',
    [switch]$DryRun,
    [switch]$SkipClaude,
    [switch]$SkipOpencode,
    [switch]$SkipCodex,
    [switch]$SkipZcode
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Say([string]$msg) { Write-Output $msg }
function Step([string]$msg) { Write-Output ""; Write-Output "== $msg" }

function Read-Text([string]$Path) {
    if (Test-Path $Path) { return [System.IO.File]::ReadAllText($Path) }
    return ''
}
function Write-Text([string]$Path, [string]$Content) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}
function Backup([string]$Path) {
    if (Test-Path $Path) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item $Path "$Path.bak-asm-$stamp" -Force
        Say "  backup -> $Path.bak-asm-$stamp"
    }
}

Step "Installing All-Agent Shared Memory"
Say "  store : $StorePath"
Say "  source: $RepoRoot"
if ($DryRun) { Say "  MODE  : DryRun (no changes will be written)" }

# 1. locate python
$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { $python = (Get-Command py -ErrorAction SilentlyContinue).Source }
if (-not $python) { Say "  WARN: python not found - MCP registration will be skipped. Install Python 3.10+." }

# 2. create store + copy tools
Step "1/5 Store + tools"
$dirs = @($StorePath, (Join-Path $StorePath 'log'), (Join-Path $StorePath 'projects'), (Join-Path $StorePath 'tools'))
foreach ($d in $dirs) {
    if ($DryRun) { Say "  would create $d" } else { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}
foreach ($tool in @('mem.ps1', 'sessionstart-hook.ps1', 'mem-mcp.py')) {
    $src = Join-Path $RepoRoot "tools\$tool"
    $dst = Join-Path $StorePath "tools\$tool"
    if ($DryRun) { Say "  would copy $src -> $dst" } else { Copy-Item $src $dst -Force; Say "  copied $tool" }
}
if (-not (Test-Path (Join-Path $StorePath 'MEMORY.md'))) {
    $tpl = Join-Path $RepoRoot 'examples\MEMORY.template.md'
    if ($DryRun) { Say "  would seed MEMORY.md from template" } else { Copy-Item $tpl (Join-Path $StorePath 'MEMORY.md') -Force; Say "  seeded MEMORY.md from template" }
} else {
    Say "  MEMORY.md exists - left untouched"
}
$hostsFile = Join-Path $StorePath 'hosts.json'
if (-not (Test-Path $hostsFile)) {
    $targets = @()
    $targets += (Join-Path $env:USERPROFILE '.codex\AGENTS.md')
    $targets += (Join-Path $env:USERPROFILE '.zcode\workspace\default\AGENTS.md')
    $cfg = [pscustomobject]@{ block_targets = $targets }
    if ($DryRun) { Say "  would write hosts.json with codex+zcode targets" } else { Write-Text $hostsFile ($cfg | ConvertTo-Json -Depth 4); Say "  wrote hosts.json" }
}

$memPs1 = Join-Path $StorePath 'tools\mem.ps1'
$hookPs1 = Join-Path $StorePath 'tools\sessionstart-hook.ps1'
$mcpPy = Join-Path $StorePath 'tools\mem-mcp.py'
$memMd = Join-Path $StorePath 'MEMORY.md'

# 3. Claude Code: SessionStart hook
Step "2/5 Claude Code (SessionStart hook)"
$claudeSettings = Join-Path $env:USERPROFILE '.claude\settings.json'
if ($SkipClaude) { Say "  skipped (-SkipClaude)" }
elseif (-not (Test-Path $claudeSettings)) { Say "  no ~/.claude/settings.json - skipped" }
else {
    $raw = Read-Text $claudeSettings
    if ($raw -match 'sessionstart-hook\.ps1' -or $raw -match 'ai_memory') {
        Say "  hook already present - skipped"
    } elseif ($DryRun) {
        Say "  would add hooks.SessionStart -> $hookPs1"
    } else {
        Backup $claudeSettings
        $hook = @"
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $($hookPs1 -replace '\\','\\')",
            "timeout": 15
          }
        ]
      }
    ]
  },
"@
        $i = $raw.IndexOf('{')
        if ($i -lt 0) { Say "  WARN: settings.json is not an object - skipped" }
        else {
            $new = $raw.Substring(0, $i + 1) + "`r`n" + $hook + $raw.Substring($i + 1)
            try { $null = $new | ConvertFrom-Json } catch { $new = $null }
            if ($null -eq $new) { Say "  WARN: patched settings.json would be invalid - skipped (backup kept)" }
            else { Write-Text $claudeSettings $new; Say "  added SessionStart hook" }
        }
    }
}

# 4. opencode: instructions + MCP
Step "3/5 opencode (instructions + MCP)"
$oc = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
if ($SkipOpencode) { Say "  skipped (-SkipOpencode)" }
elseif (-not (Test-Path $oc)) { Say "  no ~/.config/opencode/opencode.json - skipped" }
else {
    $raw = Read-Text $oc
    if ($raw -match 'ai_memory') {
        Say "  config already references ai_memory - skipped"
    } elseif ($DryRun) {
        Say "  would add instructions[] + mcp.ai_memory to opencode.json"
    } else {
        Backup $oc
        try {
            $j = $raw | ConvertFrom-Json
            $memForward = $memMd.Replace('\', '/')
            $instr = @($j.instructions) + $memForward
            $j.instructions = $instr
            if (-not $j.mcp) { $j | Add-Member -NotePropertyName mcp -NotePropertyValue ([pscustomobject]@{}) -Force }
            $server = [pscustomobject]@{
                type    = 'local'
                command = @($python, $mcpPy.Replace('\', '/'))
                enabled = $true
            }
            $j.mcp | Add-Member -NotePropertyName ai_memory -NotePropertyValue $server -Force
            $new = $j | ConvertTo-Json -Depth 32
            $null = $new | ConvertFrom-Json
            Write-Text $oc $new
            Say "  added instructions[] + mcp.ai_memory"
        } catch { Say "  WARN: could not patch opencode.json ($($_.Exception.Message))" }
    }
}

# 5. Codex: MCP registration
Step "4/5 Codex (MCP + AGENTS.md sync)"
$codexToml = Join-Path $env:USERPROFILE '.codex\config.toml'
if ($SkipCodex) { Say "  skipped (-SkipCodex)" }
elseif (-not (Test-Path $codexToml)) { Say "  no ~/.codex/config.toml - skipped" }
else {
    $raw = Read-Text $codexToml
    if ($raw -match 'ai_memory') {
        Say "  config.toml already references ai_memory - skipped"
    } elseif ($DryRun) {
        Say "  would append [mcp_servers.ai_memory] to config.toml"
    } else {
        Backup $codexToml
        $toml = "`r`n[mcp_servers.ai_memory]`r`ncommand = '$python'`r`nargs = ['$mcpPy']`r`nstartup_timeout_sec = 30`r`n"
        Append-Text $codexToml $toml
        Say "  appended [mcp_servers.ai_memory]"
    }
}

# 6. sync AGENTS.md blocks (codex + zcode targets)
Step "5/5 Sync AGENTS.md blocks"
if ($SkipZcode -and $SkipCodex) { Say "  skipped" }
elseif ($DryRun) {
    Say "  would run: mem.ps1 sync (updates managed blocks in hosts.json targets)"
} else {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $memPs1 sync
}

Step "Done"
Say "  store  : $StorePath"
Say "  CLI    : powershell -NoProfile -File `"$memPs1`" read|add|search|sync|status"
Say "  MCP    : ai_memory (memory_read / memory_search / memory_add / memory_projects)"
Say "  Uninstall: remove the SessionStart hook from ~/.claude/settings.json, the ai_memory entries from opencode.json/config.toml, and delete the store."
