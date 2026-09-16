$ErrorActionPreference = 'SilentlyContinue'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$mem  = Join-Path $root 'MEMORY.md'
$cli  = Join-Path $root 'tools\mem.ps1'

$content = ''
if (Test-Path $mem) { $content = [System.IO.File]::ReadAllText($mem) }

$context = @"
[Shared agent memory auto-loaded from $mem]

How to maintain it:
- Save durable facts: powershell -NoProfile -File "$cli" add -Text "..." -Agent claude [-Hot] [-Project name]
- Search deeper history: powershell -NoProfile -File "$cli" search -Query "..."
- Raw session history lives in claude-mem (http://localhost:37777); this file is the curated cross-agent layer.
- Never store secrets in memory files.

--- BEGIN SHARED MEMORY ---

$content

--- END SHARED MEMORY ---
"@

$result = @{
    hookSpecificOutput = @{
        hookEventName     = 'SessionStart'
        additionalContext = $context
    }
}

Write-Output ($result | ConvertTo-Json -Depth 6 -Compress)
exit 0
