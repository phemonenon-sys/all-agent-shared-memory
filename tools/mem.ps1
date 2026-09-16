[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('read', 'add', 'search', 'sync', 'status', 'doctor')]
    [string]$Command = 'read',
    [string]$Text = '',
    [string]$Query = '',
    [string]$Project = '',
    [string]$Agent = '',
    [switch]$Hot,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Root     = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$MemFile  = Join-Path $Root 'MEMORY.md'
$LogDir   = Join-Path $Root 'log'
$ProjDir  = Join-Path $Root 'projects'
$HostsFile = Join-Path $Root 'hosts.json'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (-not $Agent) { $Agent = if ($env:AI_AGENT) { $env:AI_AGENT } else { 'agent' } }
if (-not (Test-Path $LogDir))  { New-Item -ItemType Directory -Force -Path $LogDir  | Out-Null }
if (-not (Test-Path $ProjDir)) { New-Item -ItemType Directory -Force -Path $ProjDir | Out-Null }

function Read-Text([string]$Path) {
    if (Test-Path $Path) { return [System.IO.File]::ReadAllText($Path) }
    return ''
}

function Append-Text([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, (Read-Text $Path) + $Content, $Utf8NoBom)
}

function Append-HotLog([string]$Line) {
    $content = Read-Text $MemFile
    if ($content -notmatch '(?m)^## Hot log \(auto\)') {
        $content = $content.TrimEnd() + "`r`n`r`n## Hot log (auto)`r`n"
        [System.IO.File]::WriteAllText($MemFile, $content, $Utf8NoBom)
    }
    Append-Text $MemFile ($Line + "`r`n")
}

function Get-BlockTargets {
    if (Test-Path $HostsFile) {
        try {
            $cfg = Get-Content $HostsFile -Raw | ConvertFrom-Json
            if ($cfg.block_targets) { return @($cfg.block_targets) }
        } catch { }
    }
    return @(
        (Join-Path $env:USERPROFILE '.codex\AGENTS.md'),
        (Join-Path $env:USERPROFILE '.zcode\workspace\default\AGENTS.md')
    )
}

function Test-TextSecret([string]$Value) {
    $patterns = @(
        'AKIA[0-9A-Z]{16}',
        'sk-ant-[A-Za-z0-9_-]{20,}',
        'sk-[A-Za-z0-9]{20,}',
        'ghp_[A-Za-z0-9]{36}',
        'github_pat_[A-Za-z0-9_]{22,}',
        'xox[baprs]-[A-Za-z0-9-]{10,}',
        'AIza[0-9A-Za-z_-]{35}',
        '-----BEGIN [A-Z ]*PRIVATE KEY-----',
        'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}',
        '(?i)(api[_-]?key|token|secret|password)\s*[:=]\s*\S{16,}',
        '(?i)bearer\s+[A-Za-z0-9\-_\.]{20,}'
    )
    foreach ($pattern in $patterns) {
        if ($Value -match $pattern) { return $pattern }
    }
    return $null
}

$Begin = '<!-- AI-MEMORY:BEGIN -->'
$End   = '<!-- AI-MEMORY:END -->'

function Update-ManagedBlock([string]$Path, [string]$Body) {
    $block = "$Begin`r`n" + $Body.TrimEnd() + "`r`n$End"
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $content = Read-Text $Path
    if ($content -match [regex]::Escape($Begin)) {
        $pattern = "(?s)" + [regex]::Escape($Begin) + ".*?" + [regex]::Escape($End)
        $content = [regex]::Replace($content, $pattern, [System.Text.RegularExpressions.MatchEvaluator] { param($m) $block })
    } else {
        if ($content.Trim().Length -gt 0) { $content = $content.TrimEnd() + "`r`n`r`n" }
        $content = $content + $block + "`r`n"
    }
    [System.IO.File]::WriteAllText($Path, $content, $Utf8NoBom)
}

switch ($Command) {

    'read' {
        Write-Output (Read-Text $MemFile)
    }

    'add' {
        if (-not $Text) { throw 'add requires -Text "..."' }
        if (-not $Force) {
            $hit = Test-TextSecret $Text
            if ($hit) {
                throw "refused: text matches secret pattern '$hit'. Use -Force only for false positives; never store real credentials in memory files."
            }
        }
        $now = Get-Date
        $stamp = $now.ToString('yyyy-MM-dd HH:mm')
        $line = "- $stamp [$Agent] $Text"
        if ($Project) {
            $p = Join-Path $ProjDir ($Project + '.md')
            if (-not (Test-Path $p)) { [System.IO.File]::WriteAllText($p, "# Project memory: $Project`r`n", $Utf8NoBom) }
            Append-Text $p ($line + "`r`n")
            Write-Output "saved -> projects\$Project.md"
        } else {
            $p = Join-Path $LogDir ($now.ToString('yyyy-MM') + '.md')
            if (-not (Test-Path $p)) { [System.IO.File]::WriteAllText($p, "# Memory log $($now.ToString('yyyy-MM'))`r`n", $Utf8NoBom) }
            Append-Text $p ($line + "`r`n")
            Write-Output "saved -> log\$($now.ToString('yyyy-MM')).md"
        }
        if ($Hot) {
            Append-HotLog $line
            Write-Output 'also appended to MEMORY.md -> Hot log (auto)'
        }
    }

    'search' {
        if (-not $Query) { throw 'search requires -Query "..."' }
        $files = @()
        if (Test-Path $MemFile) { $files += $MemFile }
        $files += Get-ChildItem $LogDir -Filter *.md -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
        $files += Get-ChildItem $ProjDir -Filter *.md -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
        if (-not $files) { Write-Output 'memory is empty'; break }
        $hits = Select-String -Path $files -Pattern $Query -SimpleMatch -ErrorAction SilentlyContinue
        if (-not $hits) { Write-Output "no matches for: $Query"; break }
        foreach ($h in $hits) {
            $rel = $h.Path.Replace($Root + '\', '')
            Write-Output ("{0}:{1}: {2}" -f $rel, $h.LineNumber, $h.Line.Trim())
        }
    }

    'sync' {
        $memory = Read-Text $MemFile
        $body = @"
## Shared agent memory (auto-synced)

This block is generated by mem.ps1 sync. Edit MEMORY.md, then re-run sync.
Full store: $Root (log\ + projects\; search via tools\mem.ps1 search -Query "...").
Save durable facts: powershell -NoProfile -File "$Root\tools\mem.ps1" add -Text "..." -Agent codex [-Hot] [-Project name].
Never store secrets here.

--- BEGIN SHARED MEMORY CONTENT ---

$memory

--- END SHARED MEMORY CONTENT ---
"@
        foreach ($target in (Get-BlockTargets)) {
            Update-ManagedBlock $target $body
            Write-Output "synced -> $target"
        }
    }

    'doctor' {
        $script:doctorFails = 0
        function Check([string]$Name, [bool]$Ok, [string]$Detail) {
            if ($Ok) { Write-Output ("[PASS] {0} {1}" -f $Name, $Detail) }
            else { $script:doctorFails++; Write-Output ("[FAIL] {0} {1}" -f $Name, $Detail) }
        }
        function Skip([string]$Name, [string]$Detail) { Write-Output ("[SKIP] {0} {1}" -f $Name, $Detail) }

        Check 'store MEMORY.md' (Test-Path $MemFile) $MemFile
        Check 'store tools' ((Test-Path (Join-Path $Root 'tools\mem.ps1')) -and (Test-Path (Join-Path $Root 'tools\mem-mcp.py'))) 'mem.ps1 + mem-mcp.py'

        $memTime = Get-Item $MemFile -ErrorAction SilentlyContinue
        foreach ($target in (Get-BlockTargets)) {
            if (-not (Test-Path $target)) { Check "block $target" $false 'file missing - run sync'; continue }
            $content = Read-Text $target
            $has = $content -match [regex]::Escape($Begin)
            if (-not $has) { Check "block $target" $false 'missing block - run sync' }
            elseif ($memTime -and (Get-Item $target).LastWriteTime -lt $memTime.LastWriteTime) { Check "block $target" $false 'present but stale - run sync' }
            else { Check "block $target" $true 'fresh' }
        }

        $claudeSettings = Join-Path $env:USERPROFILE '.claude\settings.json'
        if (Test-Path $claudeSettings) { Check 'claude hook' ((Read-Text $claudeSettings) -match 'sessionstart-hook\.ps1') $claudeSettings }
        else { Skip 'claude hook' 'no settings.json' }

        $oc = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
        if (Test-Path $oc) { Check 'opencode wiring' ((Read-Text $oc) -match 'ai_memory') $oc }
        else { Skip 'opencode wiring' 'no opencode.json' }

        $codexToml = Join-Path $env:USERPROFILE '.codex\config.toml'
        if (Test-Path $codexToml) { Check 'codex mcp' ((Read-Text $codexToml) -match 'ai_memory') $codexToml }
        else { Skip 'codex mcp' 'no config.toml' }

        $python = (Get-Command python -ErrorAction SilentlyContinue).Source
        if ($python) { Check 'python for MCP' $true $python } else { Check 'python for MCP' $false 'not found - MCP unavailable (CLI still works)' }

        if ($python) {
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $python
                $psi.Arguments = '"' + (Join-Path $Root 'tools\mem-mcp.py') + '"'
                $psi.RedirectStandardInput = $true
                $psi.RedirectStandardOutput = $true
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $proc = [System.Diagnostics.Process]::Start($psi)
                $proc.StandardInput.WriteLine('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"doctor","version":"0"}}}')
                $proc.StandardInput.Close()
                $null = $proc.WaitForExit(8000)
                $out = $proc.StandardOutput.ReadToEnd()
                Check 'mcp handshake' ($out -match 'serverInfo') 'initialize answered'
            } catch { Check 'mcp handshake' $false $_.Exception.Message }
        }

        if ($script:doctorFails -gt 0) { Write-Output ""; Write-Output "doctor: $($script:doctorFails) problem(s) found"; exit 1 }
        Write-Output ""; Write-Output 'doctor: all checks passed'
    }

    'status' {
        $mem = Get-Item $MemFile -ErrorAction SilentlyContinue
        Write-Output "root        : $Root"
        if ($mem) { Write-Output ("MEMORY.md   : {0} bytes, {1} lines" -f $mem.Length, (Get-Content $MemFile -ErrorAction SilentlyContinue).Count) }
        else { Write-Output "MEMORY.md   : missing" }
        $logCount = (Get-ChildItem $LogDir -Filter *.md -ErrorAction SilentlyContinue | Measure-Object).Count
        $projCount = (Get-ChildItem $ProjDir -Filter *.md -ErrorAction SilentlyContinue | Measure-Object).Count
        Write-Output "log files   : $logCount   project files: $projCount"
        foreach ($p in (Get-BlockTargets)) {
            if (Test-Path $p) { Write-Output ("block       : {0}  (updated {1})" -f $p, (Get-Item $p).LastWriteTime) }
            else { Write-Output "block       : $p  (missing - run sync)" }
        }
    }
}
