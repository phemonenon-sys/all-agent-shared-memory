BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    $script:Store = Join-Path ([System.IO.Path]::GetTempPath()) ("asm-pester-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path "$Store\tools", "$Store\log", "$Store\projects" | Out-Null
    Copy-Item "$repo\tools\mem.ps1" "$Store\tools\mem.ps1" -Force
    Copy-Item "$repo\tools\mem-mcp.py" "$Store\tools\mem-mcp.py" -Force
    Copy-Item "$repo\examples\MEMORY.template.md" "$Store\MEMORY.md" -Force

    $script:Mem = "$Store\tools\mem.ps1"
    $script:MemFile = "$Store\MEMORY.md"
    $script:BlockTarget = "$Store\target-AGENTS.md"
    $targets = @($BlockTarget)
    [pscustomobject]@{ block_targets = $targets } | ConvertTo-Json -Depth 4 | Set-Content "$Store\hosts.json" -Encoding utf8

    function Invoke-Mem {
        param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
        & powershell -NoProfile -ExecutionPolicy Bypass -File $Mem @Arguments 2>&1 | Out-String
    }
}

AfterAll {
    Remove-Item $Store -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Append-HotLog (add -Hot)' {
    It 'creates the Hot log section and appends the entry' {
        $out = Invoke-Mem add -Text 'pester hot fact' -Hot
        $out | Should -Match 'Hot log'
        (Get-Content $MemFile -Raw) | Should -Match 'pester hot fact'
        (Get-Content $MemFile -Raw) | Should -Match '## Hot log \(auto\)'
    }

    It 'keeps exactly one Hot log heading after repeated adds' {
        Invoke-Mem add -Text 'second hot fact' -Hot | Out-Null
        $headings = (Get-Content $MemFile | Where-Object { $_ -match '^## Hot log \(auto\)' }).Count
        $headings | Should -Be 1
    }
}

Describe 'Update-ManagedBlock (sync)' {
    It 'writes a managed block containing the memory content' {
        $out = Invoke-Mem sync
        $out | Should -Match 'synced'
        (Test-Path $BlockTarget) | Should -BeTrue
        $content = Get-Content $BlockTarget -Raw
        $content | Should -Match 'AI-MEMORY:BEGIN'
        $content | Should -Match 'AI-MEMORY:END'
        $content | Should -Match 'pester hot fact'
    }

    It 'is idempotent - one block after re-sync, content refreshed' {
        Invoke-Mem add -Text 'fresh after first sync' -Hot | Out-Null
        Invoke-Mem sync | Out-Null
        $content = Get-Content $BlockTarget -Raw
        ([regex]::Matches($content, 'AI-MEMORY:BEGIN')).Count | Should -Be 1
        $content | Should -Match 'fresh after first sync'
    }
}

Describe 'Secret refusal' {
    It 'refuses credential-shaped text' {
        $out = Invoke-Mem add -Text 'key sk-abcdefghijklmnopqrstuvwx1234'
        $out | Should -Match 'refused'
    }
}

Describe 'Prune' {
    It 'trims the hot log to the requested size and backs up' {
        $head = "# T`r`n`r`n## Hot log (auto)`r`n"
        $entries = (1..120 | ForEach-Object { "- entry $_" }) -join "`r`n"
        [System.IO.File]::WriteAllText($MemFile, $head + $entries + "`r`n")
        $out = Invoke-Mem prune -Keep 50
        $out | Should -Match 'kept last 50 of 120'
        $kept = (Get-Content $MemFile | Where-Object { $_ -match '^- entry ' }).Count
        $kept | Should -Be 50
        (Get-ChildItem "$Store\MEMORY.md.bak-prune-*").Count | Should -BeGreaterThan 0
    }
}

Describe 'Doctor' {
    It 'warns when MEMORY.md exceeds 150 lines' {
        $head = "# T`r`n`r`n## Hot log (auto)`r`n"
        $entries = (1..200 | ForEach-Object { "- line $_" }) -join "`r`n"
        [System.IO.File]::WriteAllText($MemFile, $head + $entries + "`r`n")
        Invoke-Mem sync | Out-Null
        $out = Invoke-Mem doctor
        $out | Should -Match '\[WARN\] MEMORY\.md size'
    }
}
