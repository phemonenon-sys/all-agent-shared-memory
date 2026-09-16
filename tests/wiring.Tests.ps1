BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    $script:TestHome = Join-Path ([System.IO.Path]::GetTempPath()) ("asm-wire-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path "$TestHome\.claude", "$TestHome\.config\opencode", "$TestHome\.codex", "$TestHome\.gemini" | Out-Null
    Set-Content "$TestHome\.claude\settings.json" '{}'
    Set-Content "$TestHome\.config\opencode\opencode.json" '{}'
    Set-Content "$TestHome\.codex\config.toml" ''
    Set-Content "$TestHome\.gemini\GEMINI.md" '# Gemini rules'
    $script:Store = "$TestHome\.agents\memory"
    $script:Install = "$repo\tools\install.ps1"
    $script:Uninstall = "$repo\tools\uninstall.ps1"
}

AfterAll {
    Remove-Item $TestHome -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'install/uninstall round-trip (-WithBridge, temp HOME)' {
    It 'install wires memory + bridge + gemini without touching the real user profile' {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Install -StorePath $Store -HomeDir $TestHome -WithBridge 2>&1 | Out-String
        $out | Should -Match 'Installing'

        (Get-Content "$TestHome\.config\opencode\opencode.json" -Raw) | Should -Match 'ai_memory'
        (Get-Content "$TestHome\.config\opencode\opencode.json" -Raw) | Should -Match 'agent_bridge'
        (Get-Content "$TestHome\.codex\config.toml" -Raw) | Should -Match 'ai_memory'
        (Get-Content "$TestHome\.codex\config.toml" -Raw) | Should -Match 'agent_bridge'
        (Test-Path "$TestHome\.agents\agent-bridge\bridge-mcp.py") | Should -BeTrue
        (Test-Path "$TestHome\.agents\agent-bridge\sched.py") | Should -BeTrue
        (Get-Content "$TestHome\.gemini\GEMINI.md" -Raw) | Should -Match 'agents[\\/]memory'
        (Get-Content "$TestHome\.codex\AGENTS.md" -Raw) | Should -Match 'AI-MEMORY:BEGIN'
        (Get-Content "$TestHome\.claude\settings.json" -Raw) | Should -Match 'sessionstart-hook'

        { Get-Content "$TestHome\.config\opencode\opencode.json" -Raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'uninstall reverses memory + bridge + gemini + store' {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Uninstall -StorePath $Store -HomeDir $TestHome -RemoveStore 2>&1 | Out-String

        $oc = Get-Content "$TestHome\.config\opencode\opencode.json" -Raw
        $oc | Should -Not -Match 'ai_memory'
        $oc | Should -Not -Match 'agent_bridge'
        { $oc | ConvertFrom-Json } | Should -Not -Throw

        $ct = Get-Content "$TestHome\.codex\config.toml" -Raw
        $ct | Should -Not -Match 'ai_memory'
        $ct | Should -Not -Match 'agent_bridge'

        (Test-Path "$TestHome\.agents\agent-bridge") | Should -BeFalse
        (Get-Content "$TestHome\.gemini\GEMINI.md" -Raw) | Should -Not -Match 'agents[\\/]memory'
        if (Test-Path "$TestHome\.codex\AGENTS.md") {
            (Get-Content "$TestHome\.codex\AGENTS.md" -Raw) | Should -Not -Match 'AI-MEMORY:BEGIN'
        }
        (Test-Path $Store) | Should -BeFalse
        (Get-Content "$TestHome\.claude\settings.json" -Raw) | Should -Not -Match 'sessionstart-hook'
    }
}
