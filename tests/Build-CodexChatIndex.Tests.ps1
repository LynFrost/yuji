$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $here
$buildScript = Join-Path $projectRoot 'Build-CodexChatIndex.ps1'
$serverScript = Join-Path $projectRoot 'CodexChatIndexServer.py'
$fixtureHome = Join-Path $here 'fixtures\codex-home'
$fixtureSessionId = '00000000-0000-0000-0000-000000000001'
$forkHeadSessionId = '22222222-2222-2222-2222-222222222222'
$forkHeadPath = Join-Path $fixtureHome 'sessions\2026\04\25\rollout-2026-04-25T09-00-00-22222222-2222-2222-2222-222222222222.jsonl'
$tempRoot = Join-Path $env:TEMP ('CodexChatIndex-Test-' + [guid]::NewGuid().ToString('N'))
$outputPath = Join-Path $tempRoot 'CodexChatIndex.html'
$previousPythonDontWriteBytecode = $env:PYTHONDONTWRITEBYTECODE
$env:PYTHONDONTWRITEBYTECODE = '1'

function Get-TestSourceRoot {
    param(
        [string]$DataRoot,
        [string]$SourceId = 'local-codex'
    )
    Join-Path (Join-Path $DataRoot 'CodexChatIndex.sources') $SourceId
}

Describe 'Build-CodexChatIndex session reader outputs' {
    BeforeAll {
        New-Item -ItemType Directory -Force $tempRoot | Out-Null
        & $buildScript -CodexHome $fixtureHome -OutputPath $outputPath -DataRoot $tempRoot | Out-Null
        $script:html = Get-Content -LiteralPath $outputPath -Raw
        $defaultSourceRoot = Get-TestSourceRoot $tempRoot
        $indexPath = Join-Path $defaultSourceRoot 'CodexChatIndex.data.json'
        $script:index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json -Depth 100
        $searchIndexPath = Join-Path $defaultSourceRoot 'CodexChatIndex.search.json'
        $script:searchIndexPath = $searchIndexPath
        $script:searchIndex = if (Test-Path -LiteralPath $searchIndexPath -PathType Leaf) {
            Get-Content -LiteralPath $searchIndexPath -Raw | ConvertFrom-Json -Depth 100
        } else {
            $null
        }
        $script:sessionIndex = @(
            $script:index.workspaces |
                ForEach-Object { @($_.sessions) } |
                Where-Object { $_.id -eq $fixtureSessionId } |
                Select-Object -First 1
        )
        if (-not $script:sessionIndex) {
            throw "Fixture session '$fixtureSessionId' was not found in the built index."
        }
        $detailHref = [string]$script:sessionIndex.detailHref
        $script:outputDirectory = [System.IO.Path]::GetFullPath((Split-Path -Parent $outputPath))
        $script:detailPath = if ([string]::IsNullOrWhiteSpace($detailHref)) {
            Join-Path $script:outputDirectory '__missing-detail-href__.json'
        } else {
            [System.IO.Path]::GetFullPath((Join-Path $script:outputDirectory $detailHref))
        }
        if (Test-Path -LiteralPath $script:detailPath -PathType Leaf) {
            $script:detail = Get-Content -LiteralPath $script:detailPath -Raw | ConvertFrom-Json -Depth 100
        }
    }

    It 'keeps heavy event data out of the index payload' {
        ($sessionIndex.PSObject.Properties.Name -contains 'events') | Should Be $false
        ($sessionIndex.PSObject.Properties.Name -contains 'transcript') | Should Be $false
        (($sessionIndex | ConvertTo-Json -Depth 20 -Compress) -match '"searchText"') | Should Be $false
        $sessionIndex.detailHref | Should Not BeNullOrEmpty
    }

    It 'keeps the index session record small enough for lazy detail loading' {
        $json = ($sessionIndex | ConvertTo-Json -Depth 20 -Compress)
        $json.Length -lt 4000 | Should Be $true
    }

    It 'writes a separate full-library search index with hidden detail text' {
        (Test-Path -LiteralPath $searchIndexPath -PathType Leaf) | Should Be $true
        $searchIndex.version | Should Be 1
        $searchIndex.sessions.Count | Should BeGreaterThan 1

        $fixtureSearch = @($searchIndex.sessions | Where-Object { $_.id -eq $fixtureSessionId } | Select-Object -First 1)
        $fixtureSearch | Should Not BeNullOrEmpty
        $fixtureSearch.searchText | Should Match 'Build-CodexChatIndex\.ps1'
        $fixtureSearch.searchText | Should Match 'line 2'
        $fixtureSearch.searchText | Should Match '我已经定位到阅读器逻辑'

        (($sessionIndex | ConvertTo-Json -Depth 20 -Compress) -match '"searchText"') | Should Be $false
    }

    It 'boots from the lightweight index instead of embedding full app data' {
        $html | Should Match "const INDEX_URL = './CodexChatIndex\.sources/local-codex/CodexChatIndex\.data\.json';"
        $html | Should Match 'async function loadIndex\(\)'
        $html | Should Match 'async function loadSessionDetail\(session\)'
        $html | Should Not Match '<script id="app-data" type="application/json">'
    }

    It 'renders the V0.26 visible Yuji brand without renaming internal files' {
        $html | Should Match '<title>语迹 - AI 对话记录浏览器</title>'
        $html | Should Match '<h1>语迹 <span class="version-badge">V0\.26</span></h1>'
        $html | Should Match '<span class="app-subtitle">AI 对话记录浏览器</span>'
        $html | Should Match "const INDEX_URL = './CodexChatIndex\.sources/local-codex/CodexChatIndex\.data\.json';"
        (Test-Path -LiteralPath (Join-Path $projectRoot 'CodexChatIndex.html') -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath $buildScript -PathType Leaf) | Should Be $true
    }

    It 'uses V0.26 builder and visible version markers' {
        $buildSource = Get-Content -LiteralPath $buildScript -Raw

        $html | Should Match '<span class="version-badge">V0\.26</span>'
        $buildSource | Should Match '\$builderVersion = "V0\.26"'
        $html | Should Not Match '<span class="version-badge">V0\.25</span>'
        $buildSource | Should Not Match '\$builderVersion = "V0\.25"'
        $html | Should Not Match '<span class="version-badge">V0\.24</span>'
        $buildSource | Should Not Match '\$builderVersion = "V0\.24"'
        $html | Should Not Match '<span class="version-badge">V0\.22</span>'
        $buildSource | Should Not Match '\$builderVersion = "V0\.22"'
        $html | Should Not Match '<span class="version-badge">V0\.19</span>'
        $buildSource | Should Not Match '\$builderVersion = "V0\.19"'
        $html | Should Not Match '<span class="version-badge">V0\.18</span>'
        $buildSource | Should Not Match '\$builderVersion = "V0\.18"'
    }

    It 'uses a single V0.26 HTML template source without PowerShell interpolation leftovers' {
        $templatePath = Join-Path $projectRoot 'templates\CodexChatIndex.template.html'
        $templatePath | Should Exist
        $template = Get-Content -LiteralPath $templatePath -Raw
        $buildSource = Get-Content -LiteralPath $buildScript -Raw

        $template | Should Match '{{BUILDER_VERSION}}'
        $template | Should Match '{{INDEX_URL}}'
        $template | Should Match '{{TOTAL_SESSIONS}}'
        $template | Should Match '{{TOTAL_WORKSPACES}}'
        $template | Should Match '{{ARCHIVED_COUNT}}'
        $template | Should Match '{{IMAGE_REF_COUNT}}'
        $template | Should Match '{{GENERATED_AT}}'
        $template | Should Not Match '\$builderVersion|\$indexUrlForScript|\$totalSessions|\$totalWorkspaces|\$archivedCount|\$imageRefCount|\$generatedAt'

        $buildSource | Should Match 'CodexChatIndex\.template\.html'
        $buildSource | Should Not Match '\$html\s*=\s*@"[\s\S]*<!doctype html>'
        $html | Should Not Match '{{[A-Z0-9_]+}}'
    }

    It 'escapes template INDEX_URL values for JavaScript single-quoted strings' {
        $escapeRoot = Join-Path $tempRoot 'template-escape'
        $escapeOutputRoot = Join-Path $escapeRoot 'out'
        $escapeDataRoot = Join-Path $escapeRoot "runtime O'Brien"
        $escapeOutputPath = Join-Path $escapeOutputRoot 'CodexChatIndex.html'
        New-Item -ItemType Directory -Force $escapeOutputRoot | Out-Null

        & $buildScript -CodexHome $fixtureHome -OutputPath $escapeOutputPath -DataRoot $escapeDataRoot | Out-Null
        $escapeHtml = Get-Content -LiteralPath $escapeOutputPath -Raw

        $escapeHtml | Should Match "const INDEX_URL = '../runtime O\\'Brien/CodexChatIndex\.sources/local-codex/CodexChatIndex\.data\.json';"
        $escapeHtml | Should Not Match '{{INDEX_URL}}'
    }

    It 'guards CURRENT_DETAIL assignment outside the async fetch helper' {
        $html | Should Match 'function applyLoadedDetail\(session, detail\)'
        $html | Should Match 'await loadSessionDetail\(session\)'
        $html | Should Not Match 'if \(sessionCache\.has\(key\)\) \{\s*CURRENT_DETAIL ='
        $html | Should Match 'function cacheCurrentDetail\(key, detail\)'
    }

    It 'writes a session detail shard beside the built html' {
        $sessionIndex.detailHref | Should Match '^CodexChatIndex\.sources/local-codex/CodexChatIndex\.sessions[\\/]'
        (Split-Path -Parent $detailPath) | Should Be ([System.IO.Path]::GetFullPath((Join-Path (Get-TestSourceRoot $tempRoot) 'CodexChatIndex.sessions')))
        (Test-Path -LiteralPath $detailPath -PathType Leaf) | Should Be $true
    }

    It 'writes default runtime data to the local-codex source directory outside the version directory' {
        $layoutRoot = Join-Path $tempRoot 'layout-default'
        $versionRoot = Join-Path $layoutRoot 'CodexChatIndex'
        New-Item -ItemType Directory -Force $versionRoot | Out-Null
        Copy-Item -LiteralPath $buildScript -Destination (Join-Path $versionRoot 'Build-CodexChatIndex.ps1') -Force
        Copy-Item -LiteralPath (Join-Path $projectRoot 'templates') -Destination (Join-Path $versionRoot 'templates') -Recurse -Force

        & (Join-Path $versionRoot 'Build-CodexChatIndex.ps1') -CodexHome $fixtureHome | Out-Null

        $versionHtmlPath = Join-Path (Join-Path $versionRoot 'temp') 'CodexChatIndex.html'
        $sourceRoot = Join-Path $layoutRoot '运行数据\CodexChatIndex.sources\local-codex'
        $sourceManifestPath = Join-Path $layoutRoot '运行数据\CodexChatIndex.sources.json'
        $sharedDataPath = Join-Path $sourceRoot 'CodexChatIndex.data.json'
        $sharedSearchPath = Join-Path $sourceRoot 'CodexChatIndex.search.json'
        $sharedCachePath = Join-Path $sourceRoot 'CodexChatIndex.cache.json'
        $sharedDetailRoot = Join-Path $sourceRoot 'CodexChatIndex.sessions'
        (Test-Path -LiteralPath $versionHtmlPath -PathType Leaf) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $versionRoot 'CodexChatIndex.html') -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath $sourceManifestPath -PathType Leaf) | Should Be $true
        (Test-Path -LiteralPath $sharedDataPath -PathType Leaf) | Should Be $true
        (Test-Path -LiteralPath $sharedSearchPath -PathType Leaf) | Should Be $true
        (Test-Path -LiteralPath $sharedCachePath -PathType Leaf) | Should Be $true
        (Test-Path -LiteralPath $sharedDetailRoot -PathType Container) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $versionRoot 'CodexChatIndex.data.json') -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $versionRoot 'CodexChatIndex.search.json') -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $versionRoot 'CodexChatIndex.cache.json') -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $versionRoot 'CodexChatIndex.sessions') -PathType Container) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $layoutRoot '运行数据\CodexChatIndex.data.json') -PathType Leaf) | Should Be $false

        $versionHtml = Get-Content -LiteralPath $versionHtmlPath -Raw
        $versionHtml | Should Match "const INDEX_URL = '../../运行数据/CodexChatIndex\.sources/local-codex/CodexChatIndex\.data\.json';"

        $sharedIndex = Get-Content -LiteralPath $sharedDataPath -Raw | ConvertFrom-Json -Depth 100
        $sharedIndex.source.id | Should Be 'local-codex'
        $sharedIndex.source.label | Should Be '本机 Codex'
        $sharedIndex.source.type | Should Be 'local-codex'
        $sharedSession = @(
            $sharedIndex.workspaces |
                ForEach-Object { @($_.sessions) } |
                Where-Object { $_.id -eq $fixtureSessionId } |
                Select-Object -First 1
        )[0]
        $sharedSession.sourceId | Should Be 'local-codex'
        $sharedSession.detailHref | Should Match '^\.\./\.\./运行数据/CodexChatIndex\.sources/local-codex/CodexChatIndex\.sessions/'
        $sharedDetailPath = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $versionHtmlPath) ([string]$sharedSession.detailHref)))
        (Test-Path -LiteralPath $sharedDetailPath -PathType Leaf) | Should Be $true
    }

    It 'keeps the V0.26 source directory free of generated runtime artifacts' {
        foreach ($artifact in @(
            'CodexChatIndex.html',
            'CodexChatIndex.data.json',
            'CodexChatIndex.search.json',
            'CodexChatIndex.cache.json',
            'CodexChatIndex.sessions',
            '.playwright-mcp',
            '__pycache__'
        )) {
            Test-Path -LiteralPath (Join-Path $projectRoot $artifact) | Should Be $false
        }
    }

    It 'stores the V0.26 version marker in a dedicated source file' {
        $versionFile = Join-Path $projectRoot 'VERSION_V0.26.txt'
        (Test-Path -LiteralPath $versionFile -PathType Leaf) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $projectRoot 'VERSION_V0.25.txt') -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $projectRoot 'VERSION_V0.24.txt') -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $projectRoot 'VERSION_V0.23.txt') -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $projectRoot) 'CodexChatIndex_V0.23') -PathType Container) | Should Be $true
        (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $projectRoot) 'CodexChatIndex_V0.25') -PathType Container) | Should Be $true
        (Get-Content -LiteralPath $versionFile -Raw).Trim() | Should Be 'V0.26'
    }

    It 'keeps the V0.25 archive beside the active repo with only whitelisted source files' {
        $archiveRoot = Join-Path (Split-Path -Parent $projectRoot) 'CodexChatIndex_V0.25'
        (Test-Path -LiteralPath $archiveRoot -PathType Container) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $archiveRoot '.git') -PathType Container) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $archiveRoot 'temp') -PathType Container) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $archiveRoot 'demo-55-6-push.txt') -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $archiveRoot 'demo-55-7-merge.txt') -PathType Leaf) | Should Be $false

        $expected = @(
            '.gitignore',
            'Build-CodexChatIndex.cmd',
            'Build-CodexChatIndex.ps1',
            'CodexChatIndexServer.py',
            'Open-CodexChatIndex.cmd',
            'VERSION_V0.25.txt',
            'templates\CodexChatIndex.template.html',
            'tests\Build-CodexChatIndex.Tests.ps1',
            'tests\fixtures\codex-home\sessions\2026\04\24\rollout-2026-04-24T12-00-00-00000000-0000-0000-0000-000000000001.jsonl',
            'tests\fixtures\codex-home\sessions\2026\04\25\rollout-2026-04-25T09-00-00-22222222-2222-2222-2222-222222222222.jsonl'
        )
        foreach ($relative in $expected) {
            (Test-Path -LiteralPath (Join-Path $archiveRoot $relative) -PathType Leaf) | Should Be $true
        }

        $actual = @(
            Get-ChildItem -LiteralPath $archiveRoot -Recurse -Force |
                Where-Object { -not $_.PSIsContainer } |
                ForEach-Object { $_.FullName.Substring($archiveRoot.Length + 1) } |
                Sort-Object
        )
        ($actual -join "`n") | Should Be (($expected | Sort-Object) -join "`n")
    }

    It 'keeps the V0.23 archive beside the active repo without git metadata or temp output' {
        $archiveRoot = Join-Path (Split-Path -Parent $projectRoot) 'CodexChatIndex_V0.23'
        (Test-Path -LiteralPath $archiveRoot -PathType Container) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $archiveRoot '.git') -PathType Container) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $archiveRoot 'temp') -PathType Container) | Should Be $false
        foreach ($relative in @(
            '.gitignore',
            'Build-CodexChatIndex.cmd',
            'Build-CodexChatIndex.ps1',
            'CodexChatIndexServer.py',
            'Open-CodexChatIndex.cmd',
            'VERSION_V0.23.txt',
            'templates\CodexChatIndex.template.html',
            'tests\Build-CodexChatIndex.Tests.ps1',
            'tests\fixtures\codex-home\sessions\2026\04\24\rollout-2026-04-24T12-00-00-00000000-0000-0000-0000-000000000001.jsonl',
            'tests\fixtures\codex-home\sessions\2026\04\25\rollout-2026-04-25T09-00-00-22222222-2222-2222-2222-222222222222.jsonl'
        )) {
            (Test-Path -LiteralPath (Join-Path $archiveRoot $relative) -PathType Leaf) | Should Be $true
        }
    }

    It 'scans only the selected external source folder recursively and marks archived paths' {
        $externalRoot = Join-Path $tempRoot 'external-source-scan'
        $alphaRoot = Join-Path $externalRoot 'AlphaSource'
        $betaRoot = Join-Path $externalRoot 'BetaSource'
        $alphaNormalDir = Join-Path $alphaRoot 'sessions\2026\06'
        $alphaArchiveDir = Join-Path $alphaRoot 'archived_sessions\2026\06'
        $alphaNoiseDir = Join-Path $alphaRoot 'sessions\2026\07'
        $betaDir = Join-Path $betaRoot 'sessions\2026\06'
        New-Item -ItemType Directory -Force $alphaNormalDir, $alphaArchiveDir, $alphaNoiseDir, $betaDir | Out-Null
        $alphaNormalPath = Join-Path $alphaNormalDir 'rollout-2026-06-04T10-00-00-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl'
        $alphaArchivePath = Join-Path $alphaArchiveDir 'rollout-2026-06-04T11-00-00-bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.jsonl'
        $alphaNoisePath = Join-Path $alphaNoiseDir 'rollout-2026-06-04T12-00-00-cccccccc-cccc-cccc-cccc-cccccccccccc.jsonl'
        $betaPath = Join-Path $betaDir 'rollout-2026-06-04T12-30-00-dddddddd-dddd-dddd-dddd-dddddddddddd.jsonl'
        @(
            '{"timestamp":"2026-06-04T10:00:00Z","type":"session_meta","payload":{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","timestamp":"2026-06-04T10:00:00Z","cwd":"M:\\Alpha","source":"vscode","model_provider":"crs"}}',
            '{"timestamp":"2026-06-04T10:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"Alpha normal question"}}'
        ) | Set-Content -LiteralPath $alphaNormalPath -Encoding UTF8
        @(
            '{"timestamp":"2026-06-04T11:00:00Z","type":"session_meta","payload":{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","timestamp":"2026-06-04T11:00:00Z","cwd":"M:\\Alpha","source":"vscode","model_provider":"crs"}}',
            '{"timestamp":"2026-06-04T11:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"Alpha archived question"}}'
        ) | Set-Content -LiteralPath $alphaArchivePath -Encoding UTF8
        @(
            '{"timestamp":"2026-06-04T12:00:00Z","type":"metadata","payload":{"source":"notes","cwd":"M:\\Alpha"}}',
            '{"timestamp":"2026-06-04T12:00:01Z","kind":"note","text":"Alpha noise should not become a session"}'
        ) | Set-Content -LiteralPath $alphaNoisePath -Encoding UTF8
        @(
            '{"timestamp":"2026-06-04T12:30:00Z","type":"session_meta","payload":{"id":"dddddddd-dddd-dddd-dddd-dddddddddddd","timestamp":"2026-06-04T12:30:00Z","cwd":"M:\\Beta","source":"vscode","model_provider":"crs"}}',
            '{"timestamp":"2026-06-04T12:30:01Z","type":"event_msg","payload":{"type":"user_message","message":"Beta should not be scanned"}}'
        ) | Set-Content -LiteralPath $betaPath -Encoding UTF8

        $dataRoot = Join-Path $tempRoot 'external-runtime'
        $externalHtmlPath = Join-Path $tempRoot 'external-index.html'
        $summary = (& $buildScript `
            -OutputPath $externalHtmlPath `
            -DataRoot $dataRoot `
            -SourceId 'external-alpha-test' `
            -SourceLabel 'AlphaSource' `
            -SourceType 'external-codex-jsonl' `
            -ExternalSourcePath $alphaRoot `
            -RefreshMode Full `
            -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json

        $sourceRoot = Join-Path $dataRoot 'CodexChatIndex.sources\external-alpha-test'
        $externalIndex = Get-Content -LiteralPath (Join-Path $sourceRoot 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $externalSessions = @($externalIndex.workspaces | ForEach-Object { @($_.sessions) })

        $summary.scannedCount | Should Be 3
        $summary.parsedCount | Should Be 2
        $summary.failedCount | Should Be 1
        $summary.sessions | Should Be 2
        $summary.archived | Should Be 1
        $externalIndex.source.id | Should Be 'external-alpha-test'
        $externalIndex.source.label | Should Be 'AlphaSource'
        $externalIndex.source.type | Should Be 'external-codex-jsonl'
        @($externalSessions | Where-Object { $_.title -match 'Alpha' }).Count | Should Be 2
        @($externalSessions | Where-Object { $_.path -eq (Get-Item -LiteralPath $alphaNoisePath).FullName }).Count | Should Be 0
        @($externalSessions | Where-Object { $_.path -eq (Get-Item -LiteralPath $betaPath).FullName }).Count | Should Be 0
        @($externalSessions | Where-Object { $_.archived }).Count | Should Be 1
        @($externalSessions | Where-Object { $_.sourceId -eq 'external-alpha-test' }).Count | Should Be 2
    }

    It 'builds V0.17 local Claude data from projects jsonl and sessions metadata into an isolated source' {
        $claudeHome = Join-Path $tempRoot 'claude-home'
        $projectDir = Join-Path $claudeHome 'projects\m-work-demo'
        $sessionMetaDir = Join-Path $claudeHome 'sessions'
        New-Item -ItemType Directory -Force $projectDir, $sessionMetaDir | Out-Null
        $claudeSessionId = '019e003a-0448-7963-b92a-7c3aba7499c9'
        $claudeJsonlPath = Join-Path $projectDir ($claudeSessionId + '.jsonl')
        @(
            '{"type":"user","sessionId":"019e003a-0448-7963-b92a-7c3aba7499c9","timestamp":"2026-06-15T08:00:00Z","cwd":"M:\\Claude Demo","entrypoint":"cli","message":{"role":"user","content":[{"type":"text","text":"Claude first question"}]}}',
            '{"type":"assistant","sessionId":"019e003a-0448-7963-b92a-7c3aba7499c9","timestamp":"2026-06-15T08:00:01Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Claude hidden thinking"},{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"README.md"}},{"type":"text","text":"Claude final answer"}]}}',
            '{"type":"user","sessionId":"019e003a-0448-7963-b92a-7c3aba7499c9","timestamp":"2026-06-15T08:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"README result text"}]}}',
            '{"type":"custom-title","sessionId":"019e003a-0448-7963-b92a-7c3aba7499c9","timestamp":"2026-06-15T08:00:03Z","title":"Claude Custom Title"}'
        ) | Set-Content -LiteralPath $claudeJsonlPath -Encoding UTF8
        '{"sessionId":"019e003a-0448-7963-b92a-7c3aba7499c9","entrypoint":"claude-desktop-3p","cwd":"M:\\Metadata Fallback"}' |
            Set-Content -LiteralPath (Join-Path $sessionMetaDir ($claudeSessionId + '.json')) -Encoding UTF8

        $dataRoot = Join-Path $tempRoot 'claude-runtime'
        $claudeHtmlPath = Join-Path $tempRoot 'claude-index.html'
        $summary = (& $buildScript `
            -OutputPath $claudeHtmlPath `
            -DataRoot $dataRoot `
            -SourceId 'local-claude' `
            -SourceLabel '本机 Claude' `
            -SourceType 'local-claude' `
            -ClaudeHome $claudeHome `
            -ClaudeScanRoots @((Join-Path $claudeHome 'projects')) `
            -RefreshMode Full `
            -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json

        $sourceRoot = Join-Path $dataRoot 'CodexChatIndex.sources\local-claude'
        $claudeIndex = Get-Content -LiteralPath (Join-Path $sourceRoot 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $claudeSearch = Get-Content -LiteralPath (Join-Path $sourceRoot 'CodexChatIndex.search.json') -Raw | ConvertFrom-Json -Depth 100
        $claudeSession = @($claudeIndex.workspaces | ForEach-Object { @($_.sessions) } | Select-Object -First 1)[0]
        $claudeDetailPath = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $claudeHtmlPath) ([string]$claudeSession.detailHref)))
        $claudeDetail = Get-Content -LiteralPath $claudeDetailPath -Raw | ConvertFrom-Json -Depth 100

        $summary.scannedCount | Should Be 1
        $summary.parsedCount | Should Be 1
        $claudeIndex.source.id | Should Be 'local-claude'
        $claudeIndex.source.label | Should Be '本机 Claude'
        $claudeIndex.source.type | Should Be 'local-claude'
        $claudeIndex.source.root | Should Match '\\.claude\\projects$|claude-home\\projects$'
        $claudeIndex.workspaces[0].cwd | Should Be 'M:\Claude Demo'
        $claudeSession.id | Should Be $claudeSessionId
        $claudeSession.title | Should Be 'Claude Custom Title'
        $claudeSession.source | Should Be 'cli'
        $claudeSession.modelProvider | Should Be 'Claude'
        $claudeSession.sourceId | Should Be 'local-claude'
        ($claudeDetail.events | ForEach-Object { $_.kind }) -join ',' | Should Be 'user,assistant_commentary,tool,assistant_final,tool'
        $claudeDetail.events[1].rawText | Should Be 'Claude hidden thinking'
        $claudeDetail.events[2].toolName | Should Be 'Read'
        $claudeDetail.events[4].summary | Should Match 'tool_result'
        $claudeSearch.sessions[0].searchText | Should Match 'Claude final answer'
        $claudeSearch.sessions[0].sourceId | Should Be 'local-claude'
    }

    It 'expands V0.17 local Claude to desktop agent jsonl and VS Code Claude chat conversations' {
        $profileRoot = Join-Path $tempRoot 'claude-profile-extra'
        $claudeHome = Join-Path $profileRoot '.claude'
        $desktopProjectDir = Join-Path $profileRoot 'AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p\local-agent-mode-sessions\bcc5fa91\00000000\local_agent\.claude\projects\C--Users-DemoUser-AppData-Local-Claude-3p-local-agent-mode-sessions-bcc5fa91-00000000-local-agent-outputs'
        $vscodeConversationDir = Join-Path $profileRoot 'AppData\Roaming\Code\User\workspaceStorage\abc123\AndrePimenta.claude-code-chat\conversations'
        $mcpLogDir = Join-Path $profileRoot 'AppData\Local\claude-cli-nodejs\Cache\m-work-demo\mcp-logs-claude-vscode'
        New-Item -ItemType Directory -Force (Join-Path $claudeHome 'projects'), (Join-Path $claudeHome 'sessions'), $desktopProjectDir, $vscodeConversationDir, $mcpLogDir | Out-Null

        $desktopSessionId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        @(
            '{"type":"queue-operation","operation":"enqueue","timestamp":"2026-06-15T08:15:26Z","sessionId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","content":"桌面 Claude 提问"}',
            '{"type":"user","sessionId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","timestamp":"2026-06-15T08:15:27Z","cwd":"C:\\Users\\DemoUser\\AppData\\Local\\Claude-3p\\local-agent-mode-sessions\\demo\\outputs","entrypoint":"local-agent","message":{"role":"user","content":"桌面 Claude 提问"}}',
            '{"type":"assistant","sessionId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","timestamp":"2026-06-15T08:15:28Z","entrypoint":"local-agent","message":{"role":"assistant","content":[{"type":"thinking","thinking":"桌面 Claude 思考"},{"type":"text","text":"桌面 Claude 回答"}]}}'
        ) | Set-Content -LiteralPath (Join-Path $desktopProjectDir ($desktopSessionId + '.jsonl')) -Encoding UTF8

        @{
            sessionId = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
            startTime = '2026-01-17T15:00:14.863Z'
            endTime = '2026-01-17T15:01:16.882Z'
            messageCount = 4
            messages = @(
                @{ timestamp = '2026-01-17T15:00:14.863Z'; messageType = 'userInput'; data = 'VS Code Claude 提问' },
                @{ timestamp = '2026-01-17T15:00:15.774Z'; messageType = 'sessionInfo'; data = @{ sessionId = 'cccccccc-cccc-cccc-cccc-cccccccccccc'; cwd = 'M:\VSCode Claude Project' } },
                @{ timestamp = '2026-01-17T15:00:16.000Z'; messageType = 'updateTokens'; data = @{ totalTokensInput = 12; totalTokensOutput = 3 } },
                @{ timestamp = '2026-01-17T15:01:16.882Z'; messageType = 'output'; data = 'VS Code Claude 回答' }
            )
            filename = '2026-01-17_15-00_.json'
        } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $vscodeConversationDir '2026-01-17_15-00_.json') -Encoding UTF8

        '{"debug":"MCP log only","timestamp":"2026-01-17T15:00:00Z","sessionId":"dddddddd-dddd-dddd-dddd-dddddddddddd","cwd":"M:\\Noise"}' |
            Set-Content -LiteralPath (Join-Path $mcpLogDir '2026-01-17T15-00-00Z.jsonl') -Encoding UTF8

        $dataRoot = Join-Path $tempRoot 'claude-extra-runtime'
        $claudeHtmlPath = Join-Path $tempRoot 'claude-extra-index.html'
        $summary = (& $buildScript `
            -OutputPath $claudeHtmlPath `
            -DataRoot $dataRoot `
            -SourceId 'local-claude' `
            -SourceLabel '本机 Claude' `
            -SourceType 'local-claude' `
            -ClaudeHome $claudeHome `
            -ClaudeScanRoots @((Join-Path $claudeHome 'projects'), (Join-Path $profileRoot 'AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p\local-agent-mode-sessions'), (Join-Path $profileRoot 'AppData\Roaming\Code\User\workspaceStorage')) `
            -RefreshMode Full `
            -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json

        $sourceRoot = Join-Path $dataRoot 'CodexChatIndex.sources\local-claude'
        $claudeIndex = Get-Content -LiteralPath (Join-Path $sourceRoot 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $claudeSearch = Get-Content -LiteralPath (Join-Path $sourceRoot 'CodexChatIndex.search.json') -Raw | ConvertFrom-Json -Depth 100
        $sessions = @($claudeIndex.workspaces | ForEach-Object { @($_.sessions) })
        $desktopSession = @($sessions | Where-Object { $_.id -eq $desktopSessionId } | Select-Object -First 1)[0]
        $vscodeSession = @($sessions | Where-Object { $_.id -eq 'cccccccc-cccc-cccc-cccc-cccccccccccc' } | Select-Object -First 1)[0]
        $desktopDetail = Get-Content -LiteralPath ([System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $claudeHtmlPath) ([string]$desktopSession.detailHref)))) -Raw | ConvertFrom-Json -Depth 100
        $vscodeDetail = Get-Content -LiteralPath ([System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $claudeHtmlPath) ([string]$vscodeSession.detailHref)))) -Raw | ConvertFrom-Json -Depth 100

        $summary.scannedCount | Should Be 2
        $summary.parsedCount | Should Be 2
        $sessions.Count | Should Be 2
        $desktopSession.source | Should Be 'local-agent'
        $desktopSession.title | Should Be '桌面 Claude 提问'
        ($desktopDetail.events | ForEach-Object { $_.kind }) -join ',' | Should Be 'user,assistant_commentary,assistant_final'
        $vscodeSession.source | Should Be 'vscode-claude-code-chat'
        $vscodeSession.cwd | Should Be 'M:\VSCode Claude Project'
        ($vscodeDetail.events | ForEach-Object { $_.kind }) -join ',' | Should Be 'user,assistant_final'
        $claudeSearch.sessions.searchText -join "`n" | Should Match '桌面 Claude 回答'
        $claudeSearch.sessions.searchText -join "`n" | Should Match 'VS Code Claude 回答'
        $claudeSearch.sessions.searchText -join "`n" | Should Not Match 'MCP log only'
    }

    It 'writes an incremental cache and reuses unchanged detail shards' {
        $incrementalRoot = Join-Path $tempRoot 'incremental-cache'
        $incrementalOutputPath = Join-Path $incrementalRoot 'CodexChatIndex.html'
        New-Item -ItemType Directory -Force $incrementalRoot | Out-Null

        $fullSummary = (& $buildScript -CodexHome $fixtureHome -OutputPath $incrementalOutputPath -DataRoot $incrementalRoot -RefreshMode Full -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json
        $incrementalSourceRoot = Get-TestSourceRoot $incrementalRoot
        $cachePath = Join-Path $incrementalSourceRoot 'CodexChatIndex.cache.json'
        $indexPath = Join-Path $incrementalSourceRoot 'CodexChatIndex.data.json'
        $builtIndex = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json -Depth 100
        $builtSession = @(
            $builtIndex.workspaces |
                ForEach-Object { @($_.sessions) } |
                Where-Object { $_.id -eq $fixtureSessionId } |
                Select-Object -First 1
        )[0]
        $detailPath = [System.IO.Path]::GetFullPath((Join-Path $incrementalRoot ([string]$builtSession.detailHref)))
        $detailWriteTime = (Get-Item -LiteralPath $detailPath).LastWriteTimeUtc

        Start-Sleep -Milliseconds 1200

        $incrementalSummary = (& $buildScript -CodexHome $fixtureHome -OutputPath $incrementalOutputPath -DataRoot $incrementalRoot -RefreshMode Incremental -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json
        $detailWriteTimeAfter = (Get-Item -LiteralPath $detailPath).LastWriteTimeUtc

        $fullSummary.mode | Should Be 'Full'
        $fullSummary.parsedCount | Should Be 2
        (Test-Path -LiteralPath $cachePath -PathType Leaf) | Should Be $true
        $incrementalSummary.mode | Should Be 'Incremental'
        $incrementalSummary.scannedCount | Should Be 2
        $incrementalSummary.parsedCount | Should Be 0
        $incrementalSummary.reusedCount | Should Be 2
        $detailWriteTimeAfter | Should Be $detailWriteTime
    }

    It 'returns quickly without rewriting outputs when an incremental source signature is unchanged' {
        $noChangeRoot = Join-Path $tempRoot 'incremental-no-change'
        $noChangeOutputPath = Join-Path $noChangeRoot 'CodexChatIndex.html'
        New-Item -ItemType Directory -Force $noChangeRoot | Out-Null

        & $buildScript -CodexHome $fixtureHome -OutputPath $noChangeOutputPath -DataRoot $noChangeRoot -RefreshMode Full -JsonSummary | Out-Null
        $noChangeSourceRoot = Get-TestSourceRoot $noChangeRoot
        $dataPath = Join-Path $noChangeSourceRoot 'CodexChatIndex.data.json'
        $searchPath = Join-Path $noChangeSourceRoot 'CodexChatIndex.search.json'
        $cachePath = Join-Path $noChangeSourceRoot 'CodexChatIndex.cache.json'
        $index = Get-Content -LiteralPath $dataPath -Raw | ConvertFrom-Json -Depth 100
        $detailPath = [System.IO.Path]::GetFullPath((Join-Path $noChangeRoot ([string]$index.workspaces[0].sessions[0].detailHref)))
        $beforeTimes = @{
            Html = (Get-Item -LiteralPath $noChangeOutputPath).LastWriteTimeUtc
            Data = (Get-Item -LiteralPath $dataPath).LastWriteTimeUtc
            Search = (Get-Item -LiteralPath $searchPath).LastWriteTimeUtc
            Cache = (Get-Item -LiteralPath $cachePath).LastWriteTimeUtc
            Detail = (Get-Item -LiteralPath $detailPath).LastWriteTimeUtc
        }

        Start-Sleep -Milliseconds 1200

        $summary = (& $buildScript -CodexHome $fixtureHome -OutputPath $noChangeOutputPath -DataRoot $noChangeRoot -RefreshMode Incremental -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json

        $summary.mode | Should Be 'Incremental'
        $summary.noChange | Should Be $true
        $summary.skippedWrite | Should Be $true
        $summary.scannedCount | Should Be 2
        $summary.parsedCount | Should Be 0
        $summary.reusedCount | Should Be 2
        $summary.notice | Should Match '未发现新增或修改记录'
        (Get-Item -LiteralPath $noChangeOutputPath).LastWriteTimeUtc | Should Be $beforeTimes.Html
        (Get-Item -LiteralPath $dataPath).LastWriteTimeUtc | Should Be $beforeTimes.Data
        (Get-Item -LiteralPath $searchPath).LastWriteTimeUtc | Should Be $beforeTimes.Search
        (Get-Item -LiteralPath $cachePath).LastWriteTimeUtc | Should Be $beforeTimes.Cache
        (Get-Item -LiteralPath $detailPath).LastWriteTimeUtc | Should Be $beforeTimes.Detail
    }

    It 'does not fast-return when an expected output or detail file is missing' {
        $missingRoot = Join-Path $tempRoot 'incremental-missing-output'
        $missingOutputPath = Join-Path $missingRoot 'CodexChatIndex.html'
        New-Item -ItemType Directory -Force $missingRoot | Out-Null

        & $buildScript -CodexHome $fixtureHome -OutputPath $missingOutputPath -DataRoot $missingRoot -RefreshMode Full -JsonSummary | Out-Null
        $missingSourceRoot = Get-TestSourceRoot $missingRoot
        $dataPath = Join-Path $missingSourceRoot 'CodexChatIndex.data.json'
        $index = Get-Content -LiteralPath $dataPath -Raw | ConvertFrom-Json -Depth 100
        $detailPath = [System.IO.Path]::GetFullPath((Join-Path $missingRoot ([string]$index.workspaces[0].sessions[0].detailHref)))
        Remove-Item -LiteralPath $dataPath -Force

        $summaryMissingData = (& $buildScript -CodexHome $fixtureHome -OutputPath $missingOutputPath -DataRoot $missingRoot -RefreshMode Incremental -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json
        $summaryMissingData.noChange | Should Not Be $true
        $summaryMissingData.skippedWrite | Should Not Be $true
        $summaryMissingData.parsedCount | Should Be 0
        (Test-Path -LiteralPath $dataPath -PathType Leaf) | Should Be $true

        Remove-Item -LiteralPath $detailPath -Force
        $summaryMissingDetail = (& $buildScript -CodexHome $fixtureHome -OutputPath $missingOutputPath -DataRoot $missingRoot -RefreshMode Incremental -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json
        $summaryMissingDetail.noChange | Should Not Be $true
        $summaryMissingDetail.skippedWrite | Should Not Be $true
        (Test-Path -LiteralPath $detailPath -PathType Leaf) | Should Be $true
    }

    It 'does not fast-return for full rebuilds or when a source file changes' {
        $changeHome = Join-Path $tempRoot 'incremental-change-home'
        Copy-Item -LiteralPath $fixtureHome -Destination $changeHome -Recurse -Force
        $changeRoot = Join-Path $tempRoot 'incremental-change-output'
        $changeOutputPath = Join-Path $changeRoot 'CodexChatIndex.html'
        New-Item -ItemType Directory -Force $changeRoot | Out-Null

        $fullSummary = (& $buildScript -CodexHome $changeHome -OutputPath $changeOutputPath -DataRoot $changeRoot -RefreshMode Full -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json
        $fullAgainSummary = (& $buildScript -CodexHome $changeHome -OutputPath $changeOutputPath -DataRoot $changeRoot -RefreshMode Full -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json
        $sourcePath = Join-Path $changeHome 'sessions\2026\04\24\rollout-2026-04-24T12-00-00-00000000-0000-0000-0000-000000000001.jsonl'
        Add-Content -LiteralPath $sourcePath -Value ''

        $changedSummary = (& $buildScript -CodexHome $changeHome -OutputPath $changeOutputPath -DataRoot $changeRoot -RefreshMode Incremental -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json

        $fullSummary.mode | Should Be 'Full'
        $fullSummary.noChange | Should Not Be $true
        $fullAgainSummary.mode | Should Be 'Full'
        $fullAgainSummary.noChange | Should Not Be $true
        $changedSummary.mode | Should Be 'Incremental'
        $changedSummary.noChange | Should Not Be $true
        $changedSummary.skippedWrite | Should Not Be $true
        $changedSummary.parsedCount | Should BeGreaterThan 0
    }

    It 'keeps V0.22 Codex input images in detail only and renders image affordances' {
        $imageHome = Join-Path $tempRoot 'image-home'
        $imageSessionDir = Join-Path $imageHome 'sessions\2026\06\17'
        New-Item -ItemType Directory -Force $imageSessionDir | Out-Null
        $imageSessionId = '33333333-3333-3333-3333-333333333333'
        $imageSessionPath = Join-Path $imageSessionDir ('rollout-2026-06-17T08-00-00-' + $imageSessionId + '.jsonl')
        $imageDataUrl = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lrWg9QAAAABJRU5ErkJggg=='
        @(
            '{"timestamp":"2026-06-17T08:00:00Z","type":"session_meta","payload":{"id":"33333333-3333-3333-3333-333333333333","timestamp":"2026-06-17T08:00:00Z","cwd":"M:\\Image Demo","source":"cli","model_provider":"openai","cli_version":"0.18-test"}}',
            ('{"timestamp":"2026-06-17T08:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"请看这张图，不要把 base64 放进搜索。"},{"type":"input_image","image_url":"' + $imageDataUrl + '"}]}}'),
            '{"timestamp":"2026-06-17T08:00:02Z","type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"我看到了图片。"}}'
        ) | Set-Content -LiteralPath $imageSessionPath -Encoding UTF8

        $imageRoot = Join-Path $tempRoot 'image-runtime'
        $imageOutputPath = Join-Path $imageRoot 'CodexChatIndex.html'
        & $buildScript -CodexHome $imageHome -OutputPath $imageOutputPath -DataRoot $imageRoot -RefreshMode Full -JsonSummary | Out-Null

        $imageIndex = Get-Content -LiteralPath (Join-Path (Get-TestSourceRoot $imageRoot) 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $imageSearch = Get-Content -LiteralPath (Join-Path (Get-TestSourceRoot $imageRoot) 'CodexChatIndex.search.json') -Raw | ConvertFrom-Json -Depth 100
        $imageSession = @($imageIndex.workspaces | ForEach-Object { @($_.sessions) } | Select-Object -First 1)[0]
        $imageDetailPath = [System.IO.Path]::GetFullPath((Join-Path $imageRoot ([string]$imageSession.detailHref)))
        $imageDetail = Get-Content -LiteralPath $imageDetailPath -Raw | ConvertFrom-Json -Depth 100
        $imageHtml = Get-Content -LiteralPath $imageOutputPath -Raw

        $imageIndex.imageReferences | Should Be 1
        $imageSession.hasImageReference | Should Be $true
        $imageDetail.events[0].images[0].src | Should Be $imageDataUrl
        $imageDetail.events[0].rawText | Should Be '请看这张图，不要把 base64 放进搜索。'
        ($imageIndex | ConvertTo-Json -Depth 100 -Compress) | Should Not Match 'iVBORw0KGgo'
        ($imageSearch | ConvertTo-Json -Depth 100 -Compress) | Should Not Match 'iVBORw0KGgo'
        $imageHtml | Should Match 'class="message-images"'
        $imageHtml | Should Match 'loading="lazy"'
        $imageHtml | Should Match 'function openImagePreview'
        $imageHtml | Should Match 'function openImagePreviewFromButton'
        $imageHtml | Should Match 'onclick="openImagePreviewFromButton\(this\)"'
        $imageHtml | Should Not Match 'onclick="openImagePreview\('
        $imageHtml | Should Match 'id="imagePreviewModal"'
        $imageHtml | Should Match 'id="imagePreviewImage"'
        $imageHtml | Should Match 'id="imagePreviewClose"'
        $imageHtml | Should Not Match 'window\.open\(src'
    }

    It 'previews images in a modal and clears image src when closed' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/let imagePreviewTrigger = null;[\s\S]*?\n    function renderEventImages\(event\) \{/);
if (!match) throw new Error("image preview helpers not found");
const imagePreviewImage = { src: "", alt: "" };
let closeFocused = 0;
let triggerFocused = 0;
const imagePreviewClose = { focus() { closeFocused++; } };
const imagePreviewModal = {
  hidden: true,
  contains(element) { return element === imagePreviewImage || element === imagePreviewClose; }
};
const trigger = { focus() { triggerFocused++; } };
const document = {
  activeElement: trigger,
  getElementById(id) {
    return {
      imagePreviewModal,
      imagePreviewImage,
      imagePreviewClose
    }[id] || null;
  }
};
eval(match[0].replace(/\n    function renderEventImages\(event\) \{$/, ""));
openImagePreview("data:image/png;base64,AAA", "查看图片 1");
const opened = {
  hidden: imagePreviewModal.hidden,
  src: imagePreviewImage.src,
  alt: imagePreviewImage.alt,
  closeFocused
};
closeImagePreview();
const closed = {
  hidden: imagePreviewModal.hidden,
  src: imagePreviewImage.src,
  alt: imagePreviewImage.alt,
  triggerFocused
};
console.log(JSON.stringify({ opened, closed }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.opened.hidden | Should Be $false
        $result.opened.src | Should Be 'data:image/png;base64,AAA'
        $result.opened.alt | Should Be '查看图片 1'
        $result.opened.closeFocused | Should Be 1
        $result.closed.hidden | Should Be $true
        $result.closed.src | Should Be ''
        $result.closed.alt | Should Be ''
        $result.closed.triggerFocused | Should Be 1
    }

    It 'deduplicates V0.22 Codex user messages recorded as both response_item and event_msg while retaining images' {
        $dedupeHome = Join-Path $tempRoot 'dedupe-home'
        $dedupeSessionDir = Join-Path $dedupeHome 'sessions\2026\06\17'
        New-Item -ItemType Directory -Force $dedupeSessionDir | Out-Null
        $dedupeSessionPath = Join-Path $dedupeSessionDir 'rollout-2026-06-17T08-05-00-55555555-5555-5555-5555-555555555555.jsonl'
        $imageDataUrl = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lrWg9QAAAABJRU5ErkJggg=='
        @(
            '{"timestamp":"2026-06-17T08:05:00Z","type":"session_meta","payload":{"id":"55555555-5555-5555-5555-555555555555","timestamp":"2026-06-17T08:05:00Z","cwd":"M:\\Dedupe Demo","source":"cli","model_provider":"openai","cli_version":"0.18-test"}}',
            ('{"timestamp":"2026-06-17T08:05:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"同一条提问不要重复显示。"},{"type":"input_image","image_url":"' + $imageDataUrl + '"}]}}'),
            '{"timestamp":"2026-06-17T08:05:01Z","type":"event_msg","payload":{"type":"user_message","message":"同一条提问不要重复显示。"}}',
            '{"timestamp":"2026-06-17T08:05:02Z","type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"只回复一次。"}}'
        ) | Set-Content -LiteralPath $dedupeSessionPath -Encoding UTF8

        $dedupeRoot = Join-Path $tempRoot 'dedupe-runtime'
        $dedupeOutputPath = Join-Path $dedupeRoot 'CodexChatIndex.html'
        & $buildScript -CodexHome $dedupeHome -OutputPath $dedupeOutputPath -DataRoot $dedupeRoot -RefreshMode Full -JsonSummary | Out-Null

        $dedupeIndex = Get-Content -LiteralPath (Join-Path (Get-TestSourceRoot $dedupeRoot) 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $dedupeSession = @($dedupeIndex.workspaces | ForEach-Object { @($_.sessions) } | Select-Object -First 1)[0]
        $dedupeDetailPath = [System.IO.Path]::GetFullPath((Join-Path $dedupeRoot ([string]$dedupeSession.detailHref)))
        $dedupeDetail = Get-Content -LiteralPath $dedupeDetailPath -Raw | ConvertFrom-Json -Depth 100
        $userEvents = @($dedupeDetail.events | Where-Object { $_.kind -eq 'user' })

        $userEvents.Count | Should Be 1
        $userEvents[0].rawText | Should Be '同一条提问不要重复显示。'
        $userEvents[0].images[0].src | Should Be $imageDataUrl
        $dedupeSession.userCount | Should Be 1
        $dedupeIndex.imageReferences | Should Be 1
    }

    It 'deduplicates adjacent V0.22 Codex response_item user messages with the same timestamp and text' {
        $responseItemDedupeHome = Join-Path $tempRoot 'response-item-dedupe-home'
        $responseItemDedupeSessionDir = Join-Path $responseItemDedupeHome 'sessions\2026\06\17'
        New-Item -ItemType Directory -Force $responseItemDedupeSessionDir | Out-Null
        $responseItemDedupeSessionPath = Join-Path $responseItemDedupeSessionDir 'rollout-2026-06-17T08-06-00-66666666-6666-6666-6666-666666666666.jsonl'
        @(
            '{"timestamp":"2026-06-17T08:06:00Z","type":"session_meta","payload":{"id":"66666666-6666-6666-6666-666666666666","timestamp":"2026-06-17T08:06:00Z","cwd":"M:\\Response Item Dedupe Demo","source":"cli","model_provider":"openai","cli_version":"0.18-test"}}',
            '{"timestamp":"2026-06-17T08:06:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"连续 response_item 用户消息也不要重复显示。"}]}}',
            '{"timestamp":"2026-06-17T08:06:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"连续 response_item 用户消息也不要重复显示。"}]}}',
            '{"timestamp":"2026-06-17T08:06:02Z","type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"只保留一条。"}}'
        ) | Set-Content -LiteralPath $responseItemDedupeSessionPath -Encoding UTF8

        $responseItemDedupeRoot = Join-Path $tempRoot 'response-item-dedupe-runtime'
        $responseItemDedupeOutputPath = Join-Path $responseItemDedupeRoot 'CodexChatIndex.html'
        & $buildScript -CodexHome $responseItemDedupeHome -OutputPath $responseItemDedupeOutputPath -DataRoot $responseItemDedupeRoot -RefreshMode Full -JsonSummary | Out-Null

        $responseItemDedupeIndex = Get-Content -LiteralPath (Join-Path (Get-TestSourceRoot $responseItemDedupeRoot) 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $responseItemDedupeSession = @($responseItemDedupeIndex.workspaces | ForEach-Object { @($_.sessions) } | Select-Object -First 1)[0]
        $responseItemDedupeDetailPath = [System.IO.Path]::GetFullPath((Join-Path $responseItemDedupeRoot ([string]$responseItemDedupeSession.detailHref)))
        $responseItemDedupeDetail = Get-Content -LiteralPath $responseItemDedupeDetailPath -Raw | ConvertFrom-Json -Depth 100
        $userEvents = @($responseItemDedupeDetail.events | Where-Object { $_.kind -eq 'user' })

        $userEvents.Count | Should Be 1
        $userEvents[0].rawText | Should Be '连续 response_item 用户消息也不要重复显示。'
        $responseItemDedupeSession.userCount | Should Be 1
    }

    It 'deduplicates V0.22 Codex user duplicates even when system records are between them' {
        $nearDedupeHome = Join-Path $tempRoot 'near-dedupe-home'
        $nearDedupeSessionDir = Join-Path $nearDedupeHome 'sessions\2026\06\17'
        New-Item -ItemType Directory -Force $nearDedupeSessionDir | Out-Null
        $nearDedupeSessionPath = Join-Path $nearDedupeSessionDir 'rollout-2026-06-17T08-07-00-77777777-7777-7777-7777-777777777777.jsonl'
        @(
            '{"timestamp":"2026-06-17T08:07:00Z","type":"session_meta","payload":{"id":"77777777-7777-7777-7777-777777777777","timestamp":"2026-06-17T08:07:00Z","cwd":"M:\\Near Dedupe Demo","source":"cli","model_provider":"openai","cli_version":"0.18-test"}}',
            '{"timestamp":"2026-06-17T08:07:01.100Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"同一时间附近的重复提问不要显示两次。"}]}}',
            '{"timestamp":"2026-06-17T08:07:01.101Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1}}}}',
            '{"timestamp":"2026-06-17T08:07:01.101Z","type":"event_msg","payload":{"type":"user_message","message":"同一时间附近的重复提问不要显示两次。"}}',
            '{"timestamp":"2026-06-17T08:07:02Z","type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"只保留一条。"}}'
        ) | Set-Content -LiteralPath $nearDedupeSessionPath -Encoding UTF8

        $nearDedupeRoot = Join-Path $tempRoot 'near-dedupe-runtime'
        $nearDedupeOutputPath = Join-Path $nearDedupeRoot 'CodexChatIndex.html'
        & $buildScript -CodexHome $nearDedupeHome -OutputPath $nearDedupeOutputPath -DataRoot $nearDedupeRoot -RefreshMode Full -JsonSummary | Out-Null

        $nearDedupeIndex = Get-Content -LiteralPath (Join-Path (Get-TestSourceRoot $nearDedupeRoot) 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $nearDedupeSession = @($nearDedupeIndex.workspaces | ForEach-Object { @($_.sessions) } | Select-Object -First 1)[0]
        $nearDedupeDetailPath = [System.IO.Path]::GetFullPath((Join-Path $nearDedupeRoot ([string]$nearDedupeSession.detailHref)))
        $nearDedupeDetail = Get-Content -LiteralPath $nearDedupeDetailPath -Raw | ConvertFrom-Json -Depth 100
        $userEvents = @($nearDedupeDetail.events | Where-Object { $_.kind -eq 'user' })

        $userEvents.Count | Should Be 1
        $userEvents[0].rawText | Should Be '同一时间附近的重复提问不要显示两次。'
        $nearDedupeSession.userCount | Should Be 1
    }

    It 'deduplicates V0.22 Codex user duplicates when only surrounding whitespace differs' {
        $whitespaceDedupeHome = Join-Path $tempRoot 'whitespace-dedupe-home'
        $whitespaceDedupeSessionDir = Join-Path $whitespaceDedupeHome 'sessions\2026\06\17'
        New-Item -ItemType Directory -Force $whitespaceDedupeSessionDir | Out-Null
        $whitespaceDedupeSessionPath = Join-Path $whitespaceDedupeSessionDir 'rollout-2026-06-17T08-07-30-77777777-7777-7777-7777-777777777778.jsonl'
        @(
            '{"timestamp":"2026-06-17T08:07:30Z","type":"session_meta","payload":{"id":"77777777-7777-7777-7777-777777777778","timestamp":"2026-06-17T08:07:30Z","cwd":"M:\\Whitespace Dedupe Demo","source":"cli","model_provider":"openai","cli_version":"0.18-test"}}',
            '{"timestamp":"2026-06-17T08:07:31Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"前后空白不同也不要重复显示。"}]}}',
            '{"timestamp":"2026-06-17T08:07:31Z","type":"event_msg","payload":{"type":"user_message","message":"\n 前后空白不同也不要重复显示。\n"}}',
            '{"timestamp":"2026-06-17T08:07:32Z","type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"只保留一条。"}}'
        ) | Set-Content -LiteralPath $whitespaceDedupeSessionPath -Encoding UTF8

        $whitespaceDedupeRoot = Join-Path $tempRoot 'whitespace-dedupe-runtime'
        $whitespaceDedupeOutputPath = Join-Path $whitespaceDedupeRoot 'CodexChatIndex.html'
        & $buildScript -CodexHome $whitespaceDedupeHome -OutputPath $whitespaceDedupeOutputPath -DataRoot $whitespaceDedupeRoot -RefreshMode Full -JsonSummary | Out-Null

        $whitespaceDedupeIndex = Get-Content -LiteralPath (Join-Path (Get-TestSourceRoot $whitespaceDedupeRoot) 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $whitespaceDedupeSession = @($whitespaceDedupeIndex.workspaces | ForEach-Object { @($_.sessions) } | Select-Object -First 1)[0]
        $whitespaceDedupeDetailPath = [System.IO.Path]::GetFullPath((Join-Path $whitespaceDedupeRoot ([string]$whitespaceDedupeSession.detailHref)))
        $whitespaceDedupeDetail = Get-Content -LiteralPath $whitespaceDedupeDetailPath -Raw | ConvertFrom-Json -Depth 100
        $userEvents = @($whitespaceDedupeDetail.events | Where-Object { $_.kind -eq 'user' })

        $userEvents.Count | Should Be 1
        $userEvents[0].rawText | Should Be '前后空白不同也不要重复显示。'
        $whitespaceDedupeSession.userCount | Should Be 1
    }

    It 'filters injected Codex context response_item user messages from visible questions and titles' {
        $contextHome = Join-Path $tempRoot 'context-filter-home'
        $contextSessionDir = Join-Path $contextHome 'sessions\2026\06\17'
        New-Item -ItemType Directory -Force $contextSessionDir | Out-Null
        $contextSessionPath = Join-Path $contextSessionDir 'rollout-2026-06-17T08-08-00-88888888-8888-8888-8888-888888888888.jsonl'
        $agentsText = "# AGENTS.md instructions for M:\Demo`n`n<INSTRUCTIONS>`nOnly internal instructions.`n</INSTRUCTIONS>"
        $environmentText = "<environment_context>`n  <cwd>M:\Demo</cwd>`n  <shell>powershell</shell>`n</environment_context>"
        @(
            '{"timestamp":"2026-06-17T08:08:00Z","type":"session_meta","payload":{"id":"88888888-8888-8888-8888-888888888888","timestamp":"2026-06-17T08:08:00Z","cwd":"M:\\Context Filter Demo","source":"cli","model_provider":"openai","cli_version":"0.18-test"}}',
            (@{ timestamp = '2026-06-17T08:08:01Z'; type = 'response_item'; payload = @{ type = 'message'; role = 'user'; content = @(@{ type = 'input_text'; text = $agentsText }) } } | ConvertTo-Json -Depth 10 -Compress),
            (@{ timestamp = '2026-06-17T08:08:02Z'; type = 'response_item'; payload = @{ type = 'message'; role = 'user'; content = @(@{ type = 'input_text'; text = $environmentText }) } } | ConvertTo-Json -Depth 10 -Compress),
            '{"timestamp":"2026-06-17T08:08:03Z","type":"event_msg","payload":{"type":"user_message","message":"这才是真实提问。"}}',
            '{"timestamp":"2026-06-17T08:08:04Z","type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"真实回复。"}}'
        ) | Set-Content -LiteralPath $contextSessionPath -Encoding UTF8

        $contextRoot = Join-Path $tempRoot 'context-filter-runtime'
        $contextOutputPath = Join-Path $contextRoot 'CodexChatIndex.html'
        & $buildScript -CodexHome $contextHome -OutputPath $contextOutputPath -DataRoot $contextRoot -RefreshMode Full -JsonSummary | Out-Null

        $contextIndex = Get-Content -LiteralPath (Join-Path (Get-TestSourceRoot $contextRoot) 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $contextSession = @($contextIndex.workspaces | ForEach-Object { @($_.sessions) } | Select-Object -First 1)[0]
        $contextDetailPath = [System.IO.Path]::GetFullPath((Join-Path $contextRoot ([string]$contextSession.detailHref)))
        $contextDetail = Get-Content -LiteralPath $contextDetailPath -Raw | ConvertFrom-Json -Depth 100
        $userEvents = @($contextDetail.events | Where-Object { $_.kind -eq 'user' })

        $contextSession.title | Should Be '这才是真实提问。'
        $contextSession.summary | Should Be '这才是真实提问。'
        $userEvents.Count | Should Be 1
        $userEvents[0].rawText | Should Be '这才是真实提问。'
        ($contextDetail.events | ConvertTo-Json -Depth 20 -Compress) | Should Not Match 'environment_context'
        ($contextDetail.events | ConvertTo-Json -Depth 20 -Compress) | Should Not Match 'AGENTS\.md instructions'
    }

    It 'filters injected AGENTS messages that are followed by other harness context blocks' {
        $wideContextHome = Join-Path $tempRoot 'wide-context-filter-home'
        $wideContextSessionDir = Join-Path $wideContextHome 'sessions\2026\06\17'
        New-Item -ItemType Directory -Force $wideContextSessionDir | Out-Null
        $wideContextSessionPath = Join-Path $wideContextSessionDir 'rollout-2026-06-17T08-08-30-88888888-8888-8888-8888-888888888889.jsonl'
        $wideAgentsText = "# AGENTS.md instructions for M:\Demo`n`n<INSTRUCTIONS>`nOnly internal instructions.`n</INSTRUCTIONS>`n<environment_context>`n  <cwd>M:\Demo</cwd>`n</environment_context>"
        @(
            '{"timestamp":"2026-06-17T08:08:30Z","type":"session_meta","payload":{"id":"88888888-8888-8888-8888-888888888889","timestamp":"2026-06-17T08:08:30Z","cwd":"M:\\Wide Context Filter Demo","source":"cli","model_provider":"openai","cli_version":"0.18-test"}}',
            (@{ timestamp = '2026-06-17T08:08:31Z'; type = 'response_item'; payload = @{ type = 'message'; role = 'user'; content = @(@{ type = 'input_text'; text = $wideAgentsText }) } } | ConvertTo-Json -Depth 10 -Compress),
            '{"timestamp":"2026-06-17T08:08:32Z","type":"event_msg","payload":{"type":"user_message","message":"宽上下文后面的真实提问。"}}',
            '{"timestamp":"2026-06-17T08:08:33Z","type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"真实回复。"}}'
        ) | Set-Content -LiteralPath $wideContextSessionPath -Encoding UTF8

        $wideContextRoot = Join-Path $tempRoot 'wide-context-filter-runtime'
        $wideContextOutputPath = Join-Path $wideContextRoot 'CodexChatIndex.html'
        & $buildScript -CodexHome $wideContextHome -OutputPath $wideContextOutputPath -DataRoot $wideContextRoot -RefreshMode Full -JsonSummary | Out-Null

        $wideContextIndex = Get-Content -LiteralPath (Join-Path (Get-TestSourceRoot $wideContextRoot) 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $wideContextSession = @($wideContextIndex.workspaces | ForEach-Object { @($_.sessions) } | Select-Object -First 1)[0]
        $wideContextDetailPath = [System.IO.Path]::GetFullPath((Join-Path $wideContextRoot ([string]$wideContextSession.detailHref)))
        $wideContextDetail = Get-Content -LiteralPath $wideContextDetailPath -Raw | ConvertFrom-Json -Depth 100
        $userEvents = @($wideContextDetail.events | Where-Object { $_.kind -eq 'user' })

        $wideContextSession.title | Should Be '宽上下文后面的真实提问。'
        $userEvents.Count | Should Be 1
        $userEvents[0].rawText | Should Be '宽上下文后面的真实提问。'
        ($wideContextDetail.events | ConvertTo-Json -Depth 20 -Compress) | Should Not Match 'AGENTS\.md instructions'
        ($wideContextDetail.events | ConvertTo-Json -Depth 20 -Compress) | Should Not Match 'environment_context'
    }

    It 'drops Codex sessions that only contain injected context messages' {
        $emptyContextHome = Join-Path $tempRoot 'empty-context-home'
        $emptyContextSessionDir = Join-Path $emptyContextHome 'sessions\2026\06\17'
        New-Item -ItemType Directory -Force $emptyContextSessionDir | Out-Null
        $emptyContextSessionPath = Join-Path $emptyContextSessionDir 'rollout-2026-06-17T08-09-00-99999999-9999-9999-9999-999999999999.jsonl'
        $environmentText = "<environment_context>`n  <cwd>M:\Demo</cwd>`n  <shell>powershell</shell>`n</environment_context>"
        @(
            '{"timestamp":"2026-06-17T08:09:00Z","type":"session_meta","payload":{"id":"99999999-9999-9999-9999-999999999999","timestamp":"2026-06-17T08:09:00Z","cwd":"M:\\Empty Context Demo","source":"cli","model_provider":"openai","cli_version":"0.18-test"}}',
            (@{ timestamp = '2026-06-17T08:09:01Z'; type = 'response_item'; payload = @{ type = 'message'; role = 'user'; content = @(@{ type = 'input_text'; text = $environmentText }) } } | ConvertTo-Json -Depth 10 -Compress)
        ) | Set-Content -LiteralPath $emptyContextSessionPath -Encoding UTF8

        $emptyContextRoot = Join-Path $tempRoot 'empty-context-runtime'
        $emptyContextOutputPath = Join-Path $emptyContextRoot 'CodexChatIndex.html'
        $summary = (& $buildScript -CodexHome $emptyContextHome -OutputPath $emptyContextOutputPath -DataRoot $emptyContextRoot -RefreshMode Full -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json

        $emptyContextIndex = Get-Content -LiteralPath (Join-Path (Get-TestSourceRoot $emptyContextRoot) 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100

        $summary.scannedCount | Should Be 1
        $summary.parsedCount | Should Be 0
        $summary.failedCount | Should Be 0
        $emptyContextIndex.totalSessions | Should Be 0
        @($emptyContextIndex.workspaces).Count | Should Be 0
    }

    It 'keeps V0.22 Codex sessions without input images out of image reference counts' {
        $plainHome = Join-Path $tempRoot 'plain-image-home'
        $plainSessionDir = Join-Path $plainHome 'sessions\2026\06\17'
        New-Item -ItemType Directory -Force $plainSessionDir | Out-Null
        $plainSessionPath = Join-Path $plainSessionDir 'rollout-2026-06-17T08-10-00-44444444-4444-4444-4444-444444444444.jsonl'
        @(
            '{"timestamp":"2026-06-17T08:10:00Z","type":"session_meta","payload":{"id":"44444444-4444-4444-4444-444444444444","timestamp":"2026-06-17T08:10:00Z","cwd":"M:\\Plain Demo","source":"cli","model_provider":"openai","cli_version":"0.18-test"}}',
            '{"timestamp":"2026-06-17T08:10:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"这是一条没有图片的普通消息。"}]}}',
            '{"timestamp":"2026-06-17T08:10:02Z","type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"普通回复。"}}'
        ) | Set-Content -LiteralPath $plainSessionPath -Encoding UTF8

        $plainRoot = Join-Path $tempRoot 'plain-image-runtime'
        $plainOutputPath = Join-Path $plainRoot 'CodexChatIndex.html'
        & $buildScript -CodexHome $plainHome -OutputPath $plainOutputPath -DataRoot $plainRoot -RefreshMode Full -JsonSummary | Out-Null

        $plainIndex = Get-Content -LiteralPath (Join-Path (Get-TestSourceRoot $plainRoot) 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $plainSession = @($plainIndex.workspaces | ForEach-Object { @($_.sessions) } | Select-Object -First 1)[0]
        $plainDetailPath = [System.IO.Path]::GetFullPath((Join-Path $plainRoot ([string]$plainSession.detailHref)))
        $plainDetail = Get-Content -LiteralPath $plainDetailPath -Raw | ConvertFrom-Json -Depth 100

        $plainIndex.imageReferences | Should Be 0
        $plainSession.hasImageReference | Should Be $false
        ($plainDetail.events[0].PSObject.Properties.Name -contains 'images') | Should Be $false
    }

    It 'falls back to full rebuild with an explicit notice when the cache is invalid' {
        $invalidRoot = Join-Path $tempRoot 'invalid-cache'
        $invalidOutputPath = Join-Path $invalidRoot 'CodexChatIndex.html'
        New-Item -ItemType Directory -Force $invalidRoot | Out-Null

        & $buildScript -CodexHome $fixtureHome -OutputPath $invalidOutputPath -DataRoot $invalidRoot -RefreshMode Full -JsonSummary | Out-Null
        $invalidSourceRoot = Get-TestSourceRoot $invalidRoot
        $cachePath = Join-Path $invalidSourceRoot 'CodexChatIndex.cache.json'
        Set-Content -LiteralPath $cachePath -Value '{invalid-json' -Encoding UTF8

        $summary = (& $buildScript -CodexHome $fixtureHome -OutputPath $invalidOutputPath -DataRoot $invalidRoot -RefreshMode Incremental -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json

        $summary.mode | Should Be 'Full'
        $summary.parsedCount | Should Be 2
        $summary.notice | Should Match '缓存损坏'
    }

    It 'falls back to full rebuild with an explicit notice when the cache version is incompatible' {
        $versionRoot = Join-Path $tempRoot 'version-mismatch-cache'
        $versionOutputPath = Join-Path $versionRoot 'CodexChatIndex.html'
        New-Item -ItemType Directory -Force $versionRoot | Out-Null

        & $buildScript -CodexHome $fixtureHome -OutputPath $versionOutputPath -DataRoot $versionRoot -RefreshMode Full -JsonSummary | Out-Null
        $versionSourceRoot = Get-TestSourceRoot $versionRoot
        $cachePath = Join-Path $versionSourceRoot 'CodexChatIndex.cache.json'
        $cacheData = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -Depth 100
        $cacheData.cacheVersion = 999
        Set-Content -LiteralPath $cachePath -Value ($cacheData | ConvertTo-Json -Depth 100) -Encoding UTF8

        $summary = (& $buildScript -CodexHome $fixtureHome -OutputPath $versionOutputPath -DataRoot $versionRoot -RefreshMode Incremental -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json

        $summary.mode | Should Be 'Full'
        $summary.parsedCount | Should Be 2
        $summary.notice | Should Match '缓存版本不兼容'
    }

    It 'refreshes only the requested current session when cache is available' {
        $currentHome = Join-Path $tempRoot 'current-refresh-home'
        $currentRoot = Join-Path $tempRoot 'current-refresh-output'
        $currentOutputPath = Join-Path $currentRoot 'CodexChatIndex.html'
        Copy-Item -LiteralPath $fixtureHome -Destination $currentHome -Recurse
        New-Item -ItemType Directory -Force $currentRoot | Out-Null

        & $buildScript -CodexHome $currentHome -OutputPath $currentOutputPath -DataRoot $currentRoot -RefreshMode Full -JsonSummary | Out-Null

        $currentSessionPath = Join-Path $currentHome 'sessions\2026\04\24\rollout-2026-04-24T12-00-00-00000000-0000-0000-0000-000000000001.jsonl'
        $otherSessionPath = Join-Path $currentHome 'sessions\2026\04\25\rollout-2026-04-25T09-00-00-22222222-2222-2222-2222-222222222222.jsonl'
        $currentSessionPath = (Get-Item -LiteralPath $currentSessionPath).FullName
        $otherSessionPath = (Get-Item -LiteralPath $otherSessionPath).FullName
        $beforeIndex = Get-Content -LiteralPath (Join-Path (Get-TestSourceRoot $currentRoot) 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $otherSessionBefore = @(
            $beforeIndex.workspaces |
                ForEach-Object { @($_.sessions) } |
                Where-Object { $_.path -eq $otherSessionPath } |
                Select-Object -First 1
        )[0]
        $otherDetailPath = [System.IO.Path]::GetFullPath((Join-Path $currentRoot ([string]$otherSessionBefore.detailHref)))
        $otherDetailWriteTime = (Get-Item -LiteralPath $otherDetailPath).LastWriteTimeUtc

        Start-Sleep -Milliseconds 1200

        @(
            '{"timestamp":"2026-04-24T12:09:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-v008"}}',
            '{"timestamp":"2026-04-24T12:09:01Z","type":"event_msg","payload":{"type":"user_message","message":"V0.08 快刷追加问题"}}',
            '{"timestamp":"2026-04-24T12:09:02Z","type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"V0.08 快刷追加回答"}}',
            '{"timestamp":"2026-04-24T12:09:03Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-v008","last_agent_message":"V0.08 快刷追加回答"}}'
        ) | Add-Content -LiteralPath $currentSessionPath -Encoding UTF8

        $currentSummary = (& $buildScript -CodexHome $currentHome -OutputPath $currentOutputPath -DataRoot $currentRoot -RefreshMode Current -CurrentSessionPath $currentSessionPath -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json
        $afterIndex = Get-Content -LiteralPath (Join-Path (Get-TestSourceRoot $currentRoot) 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $currentSessionAfter = @(
            $afterIndex.workspaces |
                ForEach-Object { @($_.sessions) } |
                Where-Object { $_.path -eq $currentSessionPath } |
                Select-Object -First 1
        )[0]
        $currentDetailPath = [System.IO.Path]::GetFullPath((Join-Path $currentRoot ([string]$currentSessionAfter.detailHref)))
        $currentDetailText = Get-Content -LiteralPath $currentDetailPath -Raw
        $otherDetailWriteTimeAfter = (Get-Item -LiteralPath $otherDetailPath).LastWriteTimeUtc

        $currentSummary.mode | Should Be 'Current'
        $currentSummary.scannedCount | Should Be 1
        $currentSummary.parsedCount | Should Be 1
        $currentSummary.reusedCount | Should Be 1
        $currentSessionAfter.userCount | Should BeGreaterThan 1
        $currentDetailText | Should Match 'V0\.08 快刷追加问题'
        $currentDetailText | Should Match 'V0\.08 快刷追加回答'
        $otherDetailWriteTimeAfter | Should Be $otherDetailWriteTime
    }

    It 'discovers archived sessions recursively' {
        $nestedHome = Join-Path $tempRoot 'nested-archive-home'
        $nestedArchiveDir = Join-Path $nestedHome 'archived_sessions\2026\04\24'
        $nestedArchiveFile = Join-Path $nestedArchiveDir 'rollout-2026-04-24T13-00-00-11111111-1111-1111-1111-111111111111.jsonl'
        $nestedOutputPath = Join-Path $tempRoot 'NestedArchiveIndex.html'
        $nestedDataPath = Join-Path (Get-TestSourceRoot $tempRoot) 'CodexChatIndex.data.json'
        New-Item -ItemType Directory -Force $nestedArchiveDir | Out-Null
        @(
            '{"timestamp":"2026-04-24T13:00:00Z","type":"session_meta","payload":{"id":"11111111-1111-1111-1111-111111111111","timestamp":"2026-04-24T13:00:00Z","cwd":"M:\\Nested\\Archive","source":"vscode","model_provider":"crs","cli_version":"0.124.0-alpha.2"}}',
            '{"timestamp":"2026-04-24T13:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"nested archived session"}}'
        ) | Set-Content -LiteralPath $nestedArchiveFile -Encoding UTF8

        & $buildScript -CodexHome $nestedHome -OutputPath $nestedOutputPath -DataRoot $tempRoot | Out-Null

        $nestedIndex = Get-Content -LiteralPath $nestedDataPath -Raw | ConvertFrom-Json -Depth 100
        $archivedSession = @(
            $nestedIndex.workspaces |
                ForEach-Object { @($_.sessions) } |
                Where-Object { $_.id -eq '11111111-1111-1111-1111-111111111111' } |
                Select-Object -First 1
        )[0]

        $archivedSession | Should Not BeNullOrEmpty
        $archivedSession.archived | Should Be $true
        $archivedSession.path | Should Match 'archived_sessions[\\/]2026[\\/]04[\\/]24'
    }

    It 'renders V0.07 local timestamps and excludes rolled-back turns from effective detail data' {
        $rollbackHome = Join-Path $tempRoot 'rollback-home'
        $rollbackSessionDir = Join-Path $rollbackHome 'sessions\2026\05\04'
        $rollbackSessionId = '33333333-3333-3333-3333-333333333333'
        $rollbackSessionPath = Join-Path $rollbackSessionDir ('rollout-2026-05-04T16-02-37-' + $rollbackSessionId + '.jsonl')
        $rollbackOutputPath = Join-Path $tempRoot 'RollbackIndex.html'
        New-Item -ItemType Directory -Force $rollbackSessionDir | Out-Null
        @(
            '{"timestamp":"2026-05-04T08:02:37.856Z","type":"session_meta","payload":{"id":"33333333-3333-3333-3333-333333333333","timestamp":"2026-05-04T08:02:37.856Z","cwd":"M:\\Rollback","source":"vscode","model_provider":"crs","cli_version":"0.128.0-alpha.1"}}',
            '{"timestamp":"2026-05-04T08:02:40.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-keep-1"}}',
            '{"timestamp":"2026-05-04T08:02:40.100Z","type":"event_msg","payload":{"type":"user_message","message":"保留的问题"}}',
            '{"timestamp":"2026-05-04T08:02:40.200Z","type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"V0.05 已实现并验收完成"}}',
            '{"timestamp":"2026-05-04T08:02:40.300Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-keep-1","last_agent_message":"V0.05 已实现并验收完成"}}',
            '{"timestamp":"2026-05-04T08:02:42.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-rollback"}}',
            '{"timestamp":"2026-05-04T08:02:42.100Z","type":"event_msg","payload":{"type":"user_message","message":"以上这些修改项是否会影响UI界面？"}}',
            '{"timestamp":"2026-05-04T08:02:42.200Z","type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"会影响，但主要是交互行为影响"}}',
            '{"timestamp":"2026-05-04T08:02:42.250Z","type":"event_msg","payload":{"type":"token_count"}}',
            '{"timestamp":"2026-05-04T08:02:42.300Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-rollback","last_agent_message":"会影响，但主要是交互行为影响"}}',
            '{"timestamp":"2026-05-04T08:02:43.711Z","type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}',
            '{"timestamp":"2026-05-04T08:02:57.500Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-keep-2"}}',
            '{"timestamp":"2026-05-04T08:02:57.576Z","type":"event_msg","payload":{"type":"user_message","message":"现在给我0.06版本的修改文档。先讨论清楚再落笔。"}}',
            '{"timestamp":"2026-05-04T08:03:10.000Z","type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"V0.06 修改文档讨论"}}',
            '{"timestamp":"2026-05-04T08:03:10.100Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-keep-2","last_agent_message":"V0.06 修改文档讨论"}}'
        ) | Set-Content -LiteralPath $rollbackSessionPath -Encoding UTF8

        & $buildScript -CodexHome $rollbackHome -OutputPath $rollbackOutputPath -DataRoot $tempRoot | Out-Null

        $rollbackIndexPath = Join-Path (Get-TestSourceRoot $tempRoot) 'CodexChatIndex.data.json'
        $rollbackIndex = Get-Content -LiteralPath $rollbackIndexPath -Raw | ConvertFrom-Json -Depth 100
        $rollbackSession = @(
            $rollbackIndex.workspaces |
                ForEach-Object { @($_.sessions) } |
                Where-Object { $_.id -eq $rollbackSessionId } |
                Select-Object -First 1
        )[0]
        $rollbackDetailPath = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $rollbackOutputPath) ([string]$rollbackSession.detailHref)))
        $rollbackDetail = Get-Content -LiteralPath $rollbackDetailPath -Raw | ConvertFrom-Json -Depth 100
        $detailText = $rollbackDetail | ConvertTo-Json -Depth 100 -Compress

        $rollbackSession.createdLocal | Should Be '2026-05-04 16:02:37'
        $rollbackSession.updatedLocal | Should Be '2026-05-04 16:03:10'
        $rollbackSession.userCount | Should Be 2
        $rollbackSession.assistantCount | Should Be 2
        @($rollbackDetail.events | Where-Object { $_.kind -eq 'user' })[1].timestampLocal | Should Be '2026-05-04 16:02:57'
        $detailText | Should Match 'V0\.05 已实现并验收完成'
        $detailText | Should Match '现在给我0\.06版本的修改文档'
        $detailText | Should Not Match '会影响，但主要是交互行为影响'
        $detailText | Should Not Match '以上这些修改项是否会影响UI界面'
    }

    It 'prunes obsolete detail shards on rebuild' {
        $staleShardPath = Join-Path (Join-Path (Get-TestSourceRoot $tempRoot) 'CodexChatIndex.sessions') 'orphaned-stale-shard.json'
        Set-Content -LiteralPath $staleShardPath -Value '{"stale":true}' -Encoding UTF8
        (Test-Path -LiteralPath $staleShardPath -PathType Leaf) | Should Be $true

        & $buildScript -CodexHome $fixtureHome -OutputPath $outputPath -DataRoot $tempRoot | Out-Null

        (Test-Path -LiteralPath $staleShardPath -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath $detailPath -PathType Leaf) | Should Be $true
    }

    It 'uses a collision-safe shard filename instead of only the session id' {
        [System.IO.Path]::GetFileName([string]$sessionIndex.detailHref) | Should Not Be ($fixtureSessionId + '.json')
        [System.IO.Path]::GetFileName([string]$sessionIndex.detailHref) | Should Match ('^' + [regex]::Escape($fixtureSessionId) + '-[A-Fa-f0-9]{8,}\.json$')
    }

    It 'keeps the fork head session id and metadata when ancestor session_meta records follow it' {
        $forkSession = @(
            $script:index.workspaces |
                ForEach-Object { @($_.sessions) } |
                Where-Object { $_.path -eq $forkHeadPath } |
                Select-Object -First 1
        )[0]

        $forkSession | Should Not BeNullOrEmpty
        $forkSession.id | Should Be $forkHeadSessionId
        $forkSession.createdLocal | Should Be '2026-04-25 17:00:00'

        $forkWorkspace = @(
            $script:index.workspaces |
                Where-Object { @($_.sessions | Where-Object { $_.path -eq $forkHeadPath }).Count -gt 0 } |
                Select-Object -First 1
        )[0]
        $forkWorkspace.cwd | Should Be 'M:\Fork\Head'

        $forkDetailPath = [System.IO.Path]::GetFullPath((Join-Path $script:outputDirectory ([string]$forkSession.detailHref)))
        $forkDetail = Get-Content -LiteralPath $forkDetailPath -Raw | ConvertFrom-Json -Depth 100
        $forkDetail.id | Should Be $forkHeadSessionId
        [System.IO.Path]::GetFileName([string]$forkSession.detailHref) | Should Match ('^' + [regex]::Escape($forkHeadSessionId) + '-[A-Fa-f0-9]{8,}\.json$')
    }

    It 'normalizes user, commentary, tool, final answer, and system events' {
        $detail | Should Not BeNullOrEmpty
        $kinds = @($detail.events | ForEach-Object { $_.kind })
        ($kinds -contains 'user') | Should Be $true
        ($kinds -contains 'assistant_commentary') | Should Be $true
        ($kinds -contains 'tool') | Should Be $true
        ($kinds -contains 'assistant_final') | Should Be $true
        ($kinds -contains 'system') | Should Be $true
    }

    It 'stores render mode hints for assistant final events' {
        $detail | Should Not BeNullOrEmpty
        @($detail.events |
            Where-Object { $_.kind -eq 'assistant_final' } |
            ForEach-Object {
                $_.renderMode | Should Be 'deterministic_markdown'
                $_.rawText | Should Not BeNullOrEmpty
            }) | Should Not BeNullOrEmpty
    }

    It 'keeps rawText on exported reader events' {
        $detail.events |
            Where-Object { $_.kind -in @('user','assistant_final','assistant_commentary','tool') } |
            ForEach-Object {
                $_.rawText | Should Not BeNullOrEmpty
            }
    }

    It 'keeps mixed chunks as paragraphs in the deterministic parser' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function isExplicitQuoteBlock\(text\) \{[\s\S]*?\n    \}(?=\n\n    function renderInlineText)/);
if (!match) {
  throw new Error("deterministic parser helpers not found");
}
eval(match[0]);
const result = {
  mixedQuote: parseDeterministicBlocks("intro\n> quoted"),
  pureQuote: parseDeterministicBlocks("> quoted\n> still quoted"),
  mixedList: parseDeterministicBlocks("intro\n- item"),
  pureList: parseDeterministicBlocks("- item one\n- item two"),
  mixedListKinds: parseDeterministicBlocks("- item one\n1. item two")
};
console.log(JSON.stringify(result));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        @($result.mixedQuote).Count | Should Be 1
        $result.mixedQuote[0].type | Should Be 'paragraph'
        @($result.pureQuote).Count | Should Be 1
        $result.pureQuote[0].type | Should Be 'quote'

        @($result.mixedList).Count | Should Be 1
        $result.mixedList[0].type | Should Be 'paragraph'
        @($result.pureList).Count | Should Be 1
        $result.pureList[0].type | Should Be 'list'

        @($result.mixedListKinds).Count | Should Be 1
        $result.mixedListKinds[0].type | Should Be 'paragraph'
    }

    It 'renders explicit final-answer lists and keeps process groups collapsed by default' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function escapeHtml\(value\) \{[\s\S]*?\n    \}(?=\n\n    function renderViewer)/);
if (!match) {
  throw new Error("reader render helpers not found");
}
eval(match[0]);
const result = {
  bulletList: renderEvent({
    kind: "assistant_final",
    timestampLocal: "2026-04-25 12:00:00",
    rawText: "- alpha\n- beta"
  }),
  numberedList: renderEvent({
    kind: "assistant_final",
    timestampLocal: "2026-04-25 12:00:00",
    rawText: "1. first\n2. second"
  }),
  processGroup: buildReaderMarkup([
    { kind: "assistant_commentary", timestampLocal: "2026-04-25 12:00:00", rawText: "thinking" },
    { kind: "assistant_final", timestampLocal: "2026-04-25 12:00:01", rawText: "done" }
  ]),
  processGroupExpanded: buildReaderMarkup([
    { kind: "assistant_commentary", timestampLocal: "2026-04-25 12:00:00", rawText: "thinking" },
    { kind: "assistant_final", timestampLocal: "2026-04-25 12:00:01", rawText: "done" }
  ], { autoExpandGroups: true })
};
console.log(JSON.stringify(result));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.bulletList | Should Match '<ul\b[^>]*>'
        $result.bulletList | Should Match '<li>alpha</li>'
        $result.bulletList | Should Match '<li>beta</li>'
        $result.numberedList | Should Match '<ol\b[^>]*>'
        $result.numberedList | Should Match '<li>first</li>'
        $result.numberedList | Should Match '<li>second</li>'
        $result.processGroup | Should Match '<details class="collapsed-group">'
        $result.processGroup | Should Not Match '<details class="collapsed-group" open>'
        $result.processGroupExpanded | Should Match '<details class="collapsed-group" open>'
    }

    It 'renders deterministic markdown tables, bold text, lists, and copy controls' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function escapeHtml\(value\) \{[\s\S]*?\n    \}(?=\n\n    function renderViewer)/);
if (!match) {
  throw new Error("reader render helpers not found");
}
eval(match[0]);
const tableText = [
  "| 总弹力 F | 总行程 S |",
  "|---|---:|",
  "| 33 N | 约 0.18 mm |",
  "| 60 N | 约 0.36 mm |"
].join("\n");
const listText = "- extobjects 目录\n- pathproc.js\n- functions.js\n- globals.js";
const result = {
  tableBlocks: parseDeterministicBlocks(tableText),
  invalidTable: renderEvent({
    kind: "assistant_final",
    timestampLocal: "2026-04-25 12:00:00",
    rawText: "| a | b |\n|---|\n| c | d |"
  }),
  finalMessage: renderEvent({
    kind: "assistant_final",
    timestampLocal: "2026-04-25 12:00:00",
    rawText: "**拿 0.4 mm 粗略举例**\n\n" + tableText + "\n\n" + listText
  }),
  userMessage: renderEvent({
    kind: "user",
    timestampLocal: "2026-04-25 12:00:00",
    rawText: listText
  })
};
console.log(JSON.stringify(result));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20

        @($result.tableBlocks).Count | Should Be 1
        $result.tableBlocks[0].type | Should Be 'table'
        @($result.tableBlocks[0].rows).Count | Should Be 2
        $result.finalMessage | Should Match '<strong>拿 0\.4 mm 粗略举例</strong>'
        $result.finalMessage | Should Match '<table class="message-table">'
        $result.finalMessage | Should Match '<th>总弹力 F</th>'
        $result.finalMessage | Should Match '<td class="align-right">约 0\.18 mm</td>'
        $result.finalMessage | Should Match '<ul\b[^>]*>'
        $result.finalMessage | Should Match '<li>extobjects 目录</li>'
        $result.finalMessage | Should Match '<button type="button" class="message-copy"'
        $result.finalMessage | Should Match '复制全文'
        $result.userMessage | Should Match '<ul\b[^>]*>'
        $result.userMessage | Should Match '<button type="button" class="message-copy"'
        $result.invalidTable | Should Not Match '<table class="message-table">'
    }

    It 'preserves ordered list numbering when items are separated by blank lines' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function escapeHtml\(value\) \{[\s\S]*?\n    \}(?=\n\n    function renderViewer)/);
if (!match) {
  throw new Error("reader render helpers not found");
}
eval(match[0]);
const result = {
  separated: renderDeterministicMarkdown("1. first\n\n2. second\n\n3. third"),
  continuous: renderDeterministicMarkdown("1. first\n2. second"),
  bullet: renderDeterministicMarkdown("- alpha\n\n- beta"),
  paragraph: renderDeterministicMarkdown("Release 2026. ordinary paragraph"),
  codeBlock: renderDeterministicMarkdown("```text\n1. first\n\n2. second\n```")
};
console.log(JSON.stringify(result));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.separated | Should Match '<ol class="message-list">'
        $result.separated | Should Match '<ol start="2" class="message-list">'
        $result.separated | Should Match '<ol start="3" class="message-list">'
        $result.separated | Should Match '<li>first</li>'
        $result.separated | Should Match '<li>second</li>'
        $result.separated | Should Match '<li>third</li>'
        ([regex]::Matches($result.continuous, '<ol\b')).Count | Should Be 1
        $result.continuous | Should Not Match '<ol start='
        $result.bullet | Should Match '<ul class="message-list">'
        $result.bullet | Should Not Match '<ul start='
        $result.paragraph | Should Not Match '<ol\b'
        $result.codeBlock | Should Match '<pre class="code-block"><code>1\. first'
        $result.codeBlock | Should Not Match '<ol\b'
    }

    It 'places execution process between the user question and final answer' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function escapeHtml\(value\) \{[\s\S]*?\n    \}(?=\n\n    function renderViewer)/);
if (!match) {
  throw new Error("reader render helpers not found");
}
eval(match[0]);
const markup = buildReaderMarkup([
  { kind: "user", timestampLocal: "2026-04-25 12:00:00", rawText: "question" },
  { kind: "assistant_commentary", timestampLocal: "2026-04-25 12:00:01", rawText: "thinking" },
  { kind: "tool", timestampLocal: "2026-04-25 12:00:02", toolName: "exec_command", status: "exit=0", summary: "ran" },
  { kind: "assistant_final", timestampLocal: "2026-04-25 12:00:03", rawText: "answer" }
]);
console.log(JSON.stringify({
  userIndex: markup.indexOf("message user"),
  processIndex: markup.indexOf("collapsed-group"),
  finalIndex: markup.indexOf("message--final")
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.userIndex -ge 0 | Should Be $true
        $result.processIndex -gt $result.userIndex | Should Be $true
        $result.finalIndex -gt $result.processIndex | Should Be $true
    }

    It 'renders V0.17 strong markdown for numbered Chinese headings without touching code spans or code blocks' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function escapeHtml\(value\) \{[\s\S]*?\n    \}(?=\n\n    function renderViewer)/);
if (!match) {
  throw new Error("reader render helpers not found");
}
eval(match[0]);
const sample = "**3. 你没在 class CTaskCounter 下面看到那些函数，是因为它们藏在宏里**";
const result = {
  heading: renderDeterministicMarkdown(sample),
  inlineCode: renderDeterministicMarkdown("`**literal**`"),
  codeBlock: renderDeterministicMarkdown("```js\nconst value = \"**literal**\";\n```"),
  unclosed: renderDeterministicMarkdown("**未闭合"),
  table: renderDeterministicMarkdown("| A | B |\n|---|---|\n| **左** | `**右**` |"),
  list: renderDeterministicMarkdown("- **列表项**")
};
console.log(JSON.stringify(result));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.heading | Should Match '<strong>3\. 你没在 class CTaskCounter 下面看到那些函数，是因为它们藏在宏里</strong>'
        $result.heading | Should Not Match '\*\*3\.'
        $result.inlineCode | Should Match '<code>\*\*literal\*\*</code>'
        $result.inlineCode | Should Not Match '<strong>literal</strong>'
        $result.codeBlock | Should Match '<pre class="code-block"><code>const value = &quot;\*\*literal\*\*&quot;;</code></pre>'
        $result.unclosed | Should Match '\*\*未闭合'
        $result.table | Should Match '<strong>左</strong>'
        $result.table | Should Match '<code>\*\*右\*\*</code>'
        $result.list | Should Match '<strong>列表项</strong>'
    }

    It 'styles user and assistant bubbles with opposite alignment' {
        $html | Should Match '\.message\.user \{[\s\S]*?align-self: flex-end'
        $html | Should Match '\.message\.assistant \{[\s\S]*?align-self: flex-start'
        $html | Should Match '\.message-copy \{[\s\S]*?align-self: center'
    }

    It 'uses wider reader layout with a borderless full-width assistant answer' {
        $html | Should Match '\.message\.user \{[\s\S]*?max-width: 80%'
        $html | Should Match '\.message\.user \{[\s\S]*?background: var\(--assistant\)'
        $html | Should Match '\.message\.assistant \{[\s\S]*?width: 100%'
        $html | Should Match '\.message\.assistant \{[\s\S]*?max-width: 100%'
        $html | Should Match '\.message\.assistant \{[\s\S]*?border-color: transparent'
        $html | Should Match '\.message\.assistant \{[\s\S]*?box-shadow: none'
    }

    It 'keeps workspace filter checkboxes top-aligned with their labels' {
        $html | Should Not Match '\.pane input \{'
        $html | Should Match '\.pane input\[type="search"\] \{[\s\S]*?width: 100%'
        $html | Should Not Match '\.sort-panel label \{'
        $html | Should Match '\.pane \{[\s\S]*?position: relative'
        $html | Should Match '#workspacePane \{[\s\S]*?z-index: 30'
        $html | Should Match '#sessionPane \{[\s\S]*?z-index: 20'
        $html | Should Match '\.shell > \.viewer \{[\s\S]*?z-index: 10'
        $html | Should Match '\.pane-header \{[\s\S]*?z-index: 20'
        $html | Should Match '\.sort-menu \{[\s\S]*?position: static'
        $html | Should Match '\.sort-panel \{[\s\S]*?width: 300px'
        $html | Should Match '\.sort-panel \{[\s\S]*?width: min\(300px, calc\(100% - 24px\)\)'
        $html | Should Match '\.sort-panel \{[\s\S]*?right: 12px'
        $html | Should Match '\.sort-panel \{[\s\S]*?z-index: 1000'
        $html | Should Match '\.sort-panel \{[\s\S]*?background: var\(--paper\)'
        $html | Should Match '\.sort-panel > label \{'
        $html | Should Match '\.sort-panel \.check-item \{[\s\S]*?display: flex'
        $html | Should Match '\.sort-panel \.check-item \{[\s\S]*?align-items: flex-start'
        $html | Should Match '\.sort-panel \.check-item input \{[\s\S]*?margin-top: 2px'
        $html | Should Match '\.sort-panel \.check-item input \{[\s\S]*?width: auto'
        $html | Should Match '\.sort-panel \.check-item span \{[\s\S]*?display: block'
    }

    It 'renders V0.22 collapsible directory and title panes with title-adjacent collapse buttons' {
        $html | Should Match '<span class="version-badge">V0\.26</span>'
        $html | Should Match '<main class="shell" id="appShell">'
        $html | Should Match '<section class="pane" id="workspacePane">'
        $html | Should Match '<section class="pane" id="sessionPane">'
        $html | Should Match '<div class="pane-title-group">\s*<p class="pane-title">目录</p>\s*<button type="button" id="collapseWorkspacesButton"'
        $html | Should Match '<div class="pane-title-group">\s*<p class="pane-title">标题</p>\s*<button type="button" id="collapseTitlesButton"'
        $html | Should Match 'collapseWorkspacesButton" class="pane-collapse-btn" data-collapse-pane="workspaces"'
        $html | Should Match 'collapseTitlesButton" class="pane-collapse-btn" data-collapse-pane="titles"'
        $html | Should Match '<button type="button" id="collapseWorkspacesButton"[\s\S]*?</button>\s*</div>\s*<div class="header-actions">[\s\S]*?<summary>筛选</summary>[\s\S]*?<summary>排序</summary>'
        $html | Should Match '<button type="button" id="collapseTitlesButton"[\s\S]*?</button>\s*</div>\s*<div class="header-actions">[\s\S]*?<summary>排序</summary>'
        $html | Should Not Match '第一层：目录'
        $html | Should Not Match '第二层：标题'
        $html | Should Match 'id="collapsedControls"'
        $html | Should Match 'data-collapse-pane="workspaces"'
        $html | Should Match 'data-collapse-pane="titles"'
        $html | Should Match 'data-expand-pane="workspaces"'
        $html | Should Match 'data-expand-pane="titles"'
        $html | Should Match 'Yuji\.sidebarCollapsed\.workspaces'
        $html | Should Match 'Yuji\.sidebarCollapsed\.titles'
        $html | Should Match 'function syncPaneCollapseState\(\)'
        $html | Should Match '\.shell\.is-workspace-collapsed'
        $html | Should Match '\.shell\.is-session-collapsed'
        $html | Should Match '\.shell\.is-workspace-collapsed\.is-session-collapsed'
        $html | Should Match '\.pane\.is-collapsed \{[\s\S]*?display: none'
        $html | Should Match '\.pane-title-group \{[\s\S]*?display: inline-flex'
        $html | Should Match '\.pane-title-group \{[\s\S]*?gap: 6px'
        $html | Should Not Match '第一层：工作目录'
        $html | Should Not Match '第二层：会话'
        $html | Should Not Match '第三层：会话'
        $html | Should Match 'grid-template-columns: 240px 320px minmax\(0, 1fr\)'
        $html | Should Match '@media \(min-width: 1280px\) \{[\s\S]*?grid-template-columns: 300px 400px minmax\(0, 1fr\)'
        $html | Should Match '\.pane-title \{[\s\S]*?white-space: nowrap'
        $html | Should Match '\.workspace-btn,[\s\S]*?\.session-btn \{[\s\S]*?font-size: 13px'
        $html | Should Match '\.workspace-meta,[\s\S]*?\.session-meta \{[\s\S]*?font-size: 12px'
        $html | Should Match '\.title-group-head \{[\s\S]*?font-size: 13px'
        $html | Should Match '\.title-group-meta \{[\s\S]*?font-size: 12px'
        $html | Should Match '\.workspace-name \{[^}]*white-space: normal'
        $html | Should Match '\.workspace-name \{[^}]*overflow-wrap: anywhere'
        $html | Should Not Match '\.workspace-name \{[^}]*text-overflow: ellipsis'
        $html | Should Match '\.title-group-title \{[^}]*white-space: normal'
        $html | Should Match '\.title-group-title \{[^}]*overflow-wrap: anywhere'
        $html | Should Not Match '\.title-group-title \{[^}]*text-overflow: ellipsis'
        $html | Should Match 'function groupSessionsByTitle\(sessions\)'
        $html | Should Match 'function hasMultipleSessionBranches\(group\)'
        $html | Should Match 'function formatSessionMeta\(session\)'
        $html | Should Match "groupNode\.className = 'title-group'"
        $html | Should Match 'applyNoteMetadata\(groupHead, createGroupNoteTarget\(current\.workspace, group\), group\.title\)'
        $html | Should Match 'btn\.title = item\.workspace\.cwd'
        $html | Should Match 'applyNoteMetadata\(btn, createSessionNoteTarget\(current\.workspace, group, session\), session\.path \|\| session\.title \|\| ''''\)'
        $html | Should Not Match 'session-summary'
        $html | Should Match '<span class="title-group-title">'
        $html | Should Match '<span class="session-meta">'
    }

    It 'persists V0.22 pane collapse state and supports the global sidebar toggle' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/const PANE_COLLAPSE_STORAGE_KEYS = [\s\S]*?\n    function syncPaneCollapseState\(\) \{[\s\S]*?\n    \}(?=\n\n    function positionFloatingPanel)/);
if (!match) {
  throw new Error("pane collapse helpers not found");
}
const classTokens = new Set();
const makeButton = () => ({
  hidden: null,
  textContent: "",
  title: "",
  setAttribute(name, value) { this[name] = value; }
});
const workspacePane = { classList: { toggle(name, value) { this[name] = value; } } };
const sessionPane = { classList: { toggle(name, value) { this[name] = value; } } };
const collapsedControls = { hidden: true };
const collapseButtons = { workspaces: makeButton(), titles: makeButton() };
const expandButtons = { workspaces: makeButton(), titles: makeButton() };
const globalSidebarToggleButton = makeButton();
const appShell = {
  classList: {
    toggle(name, value) {
      if (value) classTokens.add(name);
      else classTokens.delete(name);
    }
  }
};
const document = {
  getElementById(id) {
    return {
      appShell,
      workspacePane,
      sessionPane,
      collapsedControls,
      collapseWorkspacesButton: collapseButtons.workspaces,
      collapseTitlesButton: collapseButtons.titles,
      expandWorkspacesButton: expandButtons.workspaces,
      expandTitlesButton: expandButtons.titles,
      globalSidebarToggleButton
    }[id] || null;
  }
};
let rafCount = 0;
const requestAnimationFrame = callback => {
  rafCount++;
  callback();
};
const saved = {};
const localStorage = {
  getItem(key) { return Object.prototype.hasOwnProperty.call(saved, key) ? saved[key] : null; },
  setItem(key, value) { saved[key] = value; }
};
eval(match[0]);
const initial = {
  workspaceHidden: workspacePane.classList["is-collapsed"] === true,
  sessionHidden: sessionPane.classList["is-collapsed"] === true,
  controlsHidden: collapsedControls.hidden,
  globalText: globalSidebarToggleButton.textContent,
  globalTitle: globalSidebarToggleButton.title
};
setPaneCollapsed("workspaces", true);
const afterWorkspace = {
  shellWorkspace: classTokens.has("is-workspace-collapsed"),
  paneHidden: workspacePane.classList["is-collapsed"] === true,
  expandVisible: expandButtons.workspaces.hidden === false,
  controlsVisible: collapsedControls.hidden === false,
  saved: saved["Yuji.sidebarCollapsed.workspaces"],
  globalText: globalSidebarToggleButton.textContent
};
setPaneCollapsed("titles", true);
const afterBoth = {
  shellBoth: classTokens.has("is-workspace-collapsed") && classTokens.has("is-session-collapsed"),
  sessionHidden: sessionPane.classList["is-collapsed"] === true,
  titleSaved: saved["Yuji.sidebarCollapsed.titles"],
  globalText: globalSidebarToggleButton.textContent
};
setPaneCollapsed("workspaces", false);
const transcript = { scrollTop: 321 };
toggleAllSidebars();
const afterGlobalCollapse = {
  shellBoth: classTokens.has("is-workspace-collapsed") && classTokens.has("is-session-collapsed"),
  storageWorkspaces: saved["Yuji.sidebarCollapsed.workspaces"],
  storageTitles: saved["Yuji.sidebarCollapsed.titles"],
  globalText: globalSidebarToggleButton.textContent,
  scrollTop: transcript.scrollTop
};
transcript.scrollTop = 654;
toggleAllSidebars();
const afterGlobalExpand = {
  workspaceHidden: workspacePane.classList["is-collapsed"] === true,
  sessionHidden: sessionPane.classList["is-collapsed"] === true,
  storageWorkspaces: saved["Yuji.sidebarCollapsed.workspaces"],
  storageTitles: saved["Yuji.sidebarCollapsed.titles"],
  globalText: globalSidebarToggleButton.textContent,
  scrollTop: transcript.scrollTop,
  rafCount
};
console.log(JSON.stringify({
  initial,
  afterWorkspace,
  afterBoth,
  restoredWorkspace: workspacePane.classList["is-collapsed"] === false,
  restoredSaved: saved["Yuji.sidebarCollapsed.workspaces"],
  afterGlobalCollapse,
  afterGlobalExpand
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.initial.workspaceHidden | Should Be $false
        $result.initial.sessionHidden | Should Be $false
        $result.initial.controlsHidden | Should Be $true
        $result.initial.globalText | Should Be '收起'
        $result.initial.globalTitle | Should Be '一键收起目录和标题'
        $result.afterWorkspace.shellWorkspace | Should Be $true
        $result.afterWorkspace.paneHidden | Should Be $true
        $result.afterWorkspace.expandVisible | Should Be $true
        $result.afterWorkspace.controlsVisible | Should Be $true
        $result.afterWorkspace.saved | Should Be 'true'
        $result.afterWorkspace.globalText | Should Be '收起'
        $result.afterBoth.shellBoth | Should Be $true
        $result.afterBoth.sessionHidden | Should Be $true
        $result.afterBoth.titleSaved | Should Be 'true'
        $result.afterBoth.globalText | Should Be '展开'
        $result.restoredWorkspace | Should Be $true
        $result.restoredSaved | Should Be 'false'
        $result.afterGlobalCollapse.shellBoth | Should Be $true
        $result.afterGlobalCollapse.storageWorkspaces | Should Be 'true'
        $result.afterGlobalCollapse.storageTitles | Should Be 'true'
        $result.afterGlobalCollapse.globalText | Should Be '展开'
        $result.afterGlobalCollapse.scrollTop | Should Be 321
        $result.afterGlobalExpand.workspaceHidden | Should Be $false
        $result.afterGlobalExpand.sessionHidden | Should Be $false
        $result.afterGlobalExpand.storageWorkspaces | Should Be 'false'
        $result.afterGlobalExpand.storageTitles | Should Be 'false'
        $result.afterGlobalExpand.globalText | Should Be '收起'
        $result.afterGlobalExpand.scrollTop | Should Be 654
        $result.afterGlobalExpand.rafCount | Should BeGreaterThan 0
    }

    It 'marks the selected title group and branch in the title pane' {
        $html | Should Match '\.title-group-head\.active \{[\s\S]*?border-color: var\(--accent\)'
        $html | Should Match "const groupActive = group\.sessions\.some\(session => getSessionKey\(session\) === selectedSessionKey\)"
        $html | Should Match "groupHead\.className = 'title-group-head' \+ \(groupActive \? ' active' : ''\)"
        $html | Should Match "btn\.className = 'session-btn' \+ \(getSessionKey\(session\) === selectedSessionKey \? ' active' : ''\)"
    }

    It 'renders V0.16 note menu, modal, and custom note tooltip shell' {
        $html | Should Match 'const NOTES_API_URL = ''/api/notes'''
        $html | Should Match '<div id="noteContextMenu" class="note-menu"'
        $html | Should Match '<div id="noteModal" class="note-modal"'
        $html | Should Match '<div id="noteTooltip" class="note-tooltip"'
        $html | Should Match '\.note-menu\[hidden\],[\s\S]*?\.note-modal\[hidden\],[\s\S]*?\.note-tooltip\[hidden\] \{[\s\S]*?display: none !important'
        $html | Should Match '\.note-menu \{[\s\S]*?position: fixed'
        $html | Should Match '\.note-modal \{[\s\S]*?position: fixed'
        $html | Should Match '\.note-tooltip \{[\s\S]*?position: fixed'
        $html | Should Match '\.note-tooltip \{[\s\S]*?white-space: pre-wrap'
        $html | Should Match '\.note-tooltip \{[\s\S]*?max-width: min\(70vw, 760px\)'
        $html | Should Match '\.title-group-head\.has-note::after,[\s\S]*?\.session-btn\.has-note::after'
        $html | Should Match 'loadNotes\(\)'
        $html | Should Match 'openNoteMenu\(event, target\)'
        $html | Should Match 'openNoteModal\(target\)'
        $html | Should Match 'deleteNoteForTarget\(target\)'
        $html | Should Match 'showNoteTooltip\(event, target\)'
        $html | Should Match 'hideNoteTooltip\(\)'
    }

    It 'renders V0.16 note markers without overriding selected title card styles' {
        $html | Should Match '\.workspace-btn,[\s\S]*?\.session-btn \{[\s\S]*?position: relative'
        $html | Should Match '\.title-group-head \{[\s\S]*?position: relative'
        $html | Should Match '\.title-group-head\.has-note::after,[\s\S]*?\.session-btn\.has-note::after \{[\s\S]*?content: ""'
        $html | Should Match '\.title-group-head\.has-note::after,[\s\S]*?\.session-btn\.has-note::after \{[\s\S]*?position: absolute'
        $html | Should Match '\.title-group-head\.has-note::after,[\s\S]*?\.session-btn\.has-note::after \{[\s\S]*?border-radius: 999px'
        $html | Should Match '\.title-group-head\.active\.has-note::after,[\s\S]*?\.session-btn\.active\.has-note::after \{[\s\S]*?box-shadow: 0 0 0 2px rgba\(255,255,255,\.9\)'
        $html | Should Not Match '\.title-group-head\.has-note\s*,[\s\S]*?\.session-btn\.has-note\s*\{'
        $html | Should Not Match '\.title-group-head\.has-note\s*\{'
        $html | Should Not Match '\.session-btn\.has-note\s*\{'
        $html | Should Not Match '\.title-group-head\.active\.has-note\s*\{'
        $html | Should Not Match '\.session-btn\.active\.has-note\s*\{'
    }

    It 'creates stable V0.16 note keys for title groups and session branches' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function stableHash\(value\) \{[\s\S]*?\n    \}(?=\n\n    function getNote)/);
if (!match) {
  throw new Error("note key helpers not found");
}
function getSessionKey(session) {
  return session && (session.key || session.path || session.id || "");
}
eval(match[0]);
const workspace = { cwd: "M:/WORK/demo" };
const group = { title: "同一个问题", sessions: [{ id: "s1", path: "M:/WORK/demo/a.jsonl", key: "k-a" }] };
const session = { id: "session-id", key: "session-key", path: "M:/WORK/demo/a.jsonl", title: "同一个问题" };
const fallbackSession = { id: "fallback-id", title: "无路径" };
const groupTarget = createGroupNoteTarget(workspace, group);
const sessionTarget = createSessionNoteTarget(workspace, group, session);
const fallbackTarget = createSessionNoteTarget(workspace, group, fallbackSession);
console.log(JSON.stringify({ groupTarget, sessionTarget, fallbackTarget }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20

        $result.groupTarget.type | Should Be 'group'
        $result.groupTarget.key | Should Match '^group:'
        $result.groupTarget.workspace | Should Be 'M:/WORK/demo'
        $result.groupTarget.title | Should Be '同一个问题'
        $result.sessionTarget.type | Should Be 'session'
        $result.sessionTarget.key | Should Match '^session:'
        $result.sessionTarget.path | Should Be 'M:/WORK/demo/a.jsonl'
        $result.sessionTarget.sessionId | Should Be 'session-id'
        $result.fallbackTarget.key | Should Match '^session:'
        $result.fallbackTarget.sessionId | Should Be 'fallback-id'
    }

    It 'applies custom note tooltip metadata without native title when a note exists' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function getNote\(key\) \{[\s\S]*?\n    \}(?=\n\n    function renderWorkspaceList)/);
if (!match) {
  throw new Error("note metadata helpers not found");
}
const attrs = {};
const classes = new Set();
const element = {
  dataset: {},
  classList: {
    toggle(name, enabled) {
      if (enabled) classes.add(name);
      else classes.delete(name);
    }
  },
  setAttribute(name, value) { attrs[name] = value; },
  removeAttribute(name) { delete attrs[name]; }
};
const notesState = { notes: new Map([["group:abc", { note: "备注第一行\n备注第二行" }]]) };
eval(match[0]);
classes.add("active");
applyNoteMetadata(element, { key: "group:abc", type: "group", title: "原始标题" }, "原始标题");
const withNote = { attrs: { ...attrs }, dataset: { ...element.dataset }, classes: Array.from(classes) };
applyNoteMetadata(element, { key: "group:missing", type: "group", title: "原始标题" }, "原始标题");
const withoutNote = { attrs: { ...attrs }, dataset: { ...element.dataset }, classes: Array.from(classes) };
console.log(JSON.stringify({ withNote, withoutNote }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20

        $result.withNote.attrs.PSObject.Properties.Name -contains 'title' | Should Be $false
        $result.withNote.dataset.noteKey | Should Be 'group:abc'
        $result.withNote.dataset.noteText | Should Match '备注第一行'
        @($result.withNote.classes) -contains 'has-note' | Should Be $true
        @($result.withNote.classes) -contains 'active' | Should Be $true
        $result.withoutNote.attrs.title | Should Be '原始标题'
        $result.withoutNote.dataset.noteKey | Should Be 'group:missing'
        @($result.withoutNote.classes) -contains 'has-note' | Should Be $false
        @($result.withoutNote.classes) -contains 'active' | Should Be $true
    }

    It 'only renders third-level session rows for title groups with multiple branches' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function truncateDisplayText\(value, maxLength\) \{[\s\S]*?\n    \}(?=\n\n    function getVisibleWorkspaces)/);
if (!match) {
  throw new Error("title grouping helpers not found");
}
function compareDate(a, b) {
  return Date.parse(a || "") - Date.parse(b || "");
}
function compareText(a, b) {
  return String(a || "").localeCompare(String(b || ""), "zh-CN", { numeric: true, sensitivity: "base" });
}
eval(match[0]);
const singleGroup = groupSessionsByTitle([
  { title: "源头", updatedAt: "2026-05-04T10:00:00Z", updatedLocal: "2026-05-04 18:00:00", userCount: 2, assistantCount: 3 }
])[0];
const multiGroup = groupSessionsByTitle([
  { title: "源头", updatedAt: "2026-05-04T10:00:00Z", updatedLocal: "2026-05-04 18:00:00", userCount: 2, assistantCount: 3 },
  { title: "源头", updatedAt: "2026-05-04T11:00:00Z", updatedLocal: "2026-05-04 19:00:00", userCount: 4, assistantCount: 5 }
])[0];
const singleMeta = formatTitleGroupMeta(singleGroup);
const branchMeta = formatSessionMeta(multiGroup.sessions[0]);
console.log(JSON.stringify({
  singleHasBranches: hasMultipleSessionBranches(singleGroup),
  multiHasBranches: hasMultipleSessionBranches(multiGroup),
  singleMeta,
  branchMeta
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.singleHasBranches | Should Be $false
        $result.multiHasBranches | Should Be $true
        $result.singleMeta | Should Match '2026-05-04 18:00:00'
        $result.singleMeta | Should Match '用户 2'
        $result.singleMeta | Should Match '回答 3'
        $result.branchMeta | Should Match '2026-05-04 18:00:00'
        $result.branchMeta | Should Match '用户 2'
        $result.branchMeta | Should Match '回答 3'
        $result.branchMeta | Should Not Match '更新：'
        $result.branchMeta | Should Not Match 'Assistant'
    }

    It 'truncates long title display text without changing the original title' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function truncateDisplayText\(value, maxLength\) \{[\s\S]*?\n    \}(?=\n\n    function groupSessionsByTitle)/);
if (!match) {
  throw new Error("truncateDisplayText helper not found");
}
eval(match[0]);
const longTitle = "测".repeat(301);
const exactTitle = "测".repeat(300);
console.log(JSON.stringify({
  long: truncateDisplayText(longTitle, 300),
  exact: truncateDisplayText(exactTitle, 300),
  originalLength: longTitle.length
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.long.Length | Should Be 303
        $result.long | Should Match '\.\.\.$'
        $result.exact.Length | Should Be 300
        $result.exact | Should Not Match '\.\.\.$'
        $result.originalLength | Should Be 301
    }

    It 'shows an auto-dismissing toast after copying message text' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/async function copyText\(value\) \{[\s\S]*?\n    \}(?=\n\n    function isExplicitQuoteBlock)/);
if (!match) {
  throw new Error("copy helpers not found");
}

const toastState = { textContent: "", className: "toast", hidden: true };
global.document = {
  getElementById: id => id === "toast" ? toastState : null,
  createElement: () => ({ value: "", select() {}, remove() {} }),
  body: { appendChild() {} },
  execCommand: () => true
};
global.setTimeout = (fn, ms) => {
  global.__toastDelay = ms;
  global.__toastCallback = fn;
  return 7;
};
global.clearTimeout = value => {
  global.__clearedTimer = value;
};

eval(match[0]);
(async () => {
  copyText = async value => {
    global.__copied = value;
  };
  const id = registerMessageCopyText("复制内容");
  await copyMessageText(id);
  const success = {
    copied: global.__copied,
    text: toastState.textContent,
    className: toastState.className,
    hidden: toastState.hidden,
    delay: global.__toastDelay
  };
  global.__toastCallback();
  const afterTimeout = {
    className: toastState.className,
    hidden: toastState.hidden
  };

  copyText = async () => {
    throw new Error("blocked");
  };
  await copyMessageText(id);
  const failure = {
    text: toastState.textContent,
    className: toastState.className,
    hidden: toastState.hidden
  };
  console.log(JSON.stringify({ success, afterTimeout, failure }));
})().catch(error => {
  console.error(error);
  process.exit(1);
});
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.success.copied | Should Be '复制内容'
        $result.success.text | Should Be '已复制全文'
        $result.success.className | Should Match 'toast--visible'
        $result.success.hidden | Should Be $false
        $result.success.delay | Should Be 1600
        $result.afterTimeout.className | Should Not Match 'toast--visible'
        $result.afterTimeout.hidden | Should Be $true
        $result.failure.text | Should Be '复制失败，请手动复制'
        $result.failure.className | Should Match 'toast--visible'
        $result.failure.className | Should Match 'toast--error'
        $result.failure.hidden | Should Be $false
    }

    It 'isolates message copy button clicks from question selection' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const helperMatch = html.match(/async function copyText\(value\) \{[\s\S]*?\n    \}(?=\n\n    function isExplicitQuoteBlock)/);
const listenerMatch = html.match(/transcript\.addEventListener\('click', event => \{[\s\S]*?\n    \}\);(?=\n    transcript\.addEventListener\('toggle')/);
if (!helperMatch || !listenerMatch) {
  throw new Error("copy helpers or transcript click listener not found");
}

const toastState = { textContent: "", className: "toast", hidden: true };
global.document = {
  getElementById: id => id === "toast" ? toastState : null,
  createElement: () => ({ value: "", select() {}, remove() {} }),
  body: { appendChild() {} },
  execCommand: () => true
};
global.setTimeout = () => 1;
global.clearTimeout = () => {};

eval(helperMatch[0]);
copyText = async value => {
  global.__copied = value;
};

const id = registerMessageCopyText("copy payload");
const markup = renderCopyButton({ rawText: "copy payload" });
const copyEvent = {
  defaultPrevented: false,
  preventDefault() {
    this.defaultPrevented = true;
    this.prevented = true;
  },
  stopPropagation() {
    this.stopped = true;
  }
};

const transcriptEvents = {};
let selectedQuestionKey = "q1";
let setSelectedCalls = 0;
const copyButton = {
  closest(selector) {
    if (selector === "button, a, input, textarea, select") return copyButton;
    if (selector === "[data-question-key]") return questionNode;
    return null;
  }
};
const questionNode = {
  dataset: { questionKey: "q2" }
};
const transcript = {
  focus() {
    global.__focused = true;
  },
  addEventListener(name, handler) {
    transcriptEvents[name] = handler;
  }
};
function setSelectedQuestionKey(key) {
  selectedQuestionKey = key;
  setSelectedCalls += 1;
}
eval(listenerMatch[0]);

(async () => {
  await handleMessageCopyClick(copyEvent, id);
  transcriptEvents.click({
    defaultPrevented: copyEvent.defaultPrevented,
    target: copyButton
  });
  console.log(JSON.stringify({
    markup,
    copied: global.__copied,
    prevented: copyEvent.prevented === true,
    stopped: copyEvent.stopped === true,
    selectedQuestionKey,
    setSelectedCalls,
    focused: global.__focused === true
  }));
})().catch(error => {
  console.error(error);
  process.exit(1);
});
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.markup | Should Match "handleMessageCopyClick\(event, 'message-copy-"
        $result.copied | Should Be 'copy payload'
        $result.prevented | Should Be $true
        $result.stopped | Should Be $true
        $result.selectedQuestionKey | Should Be 'q1'
        $result.setSelectedCalls | Should Be 0
        $result.focused | Should Be $false
    }

    It 'moves message copy actions into the message header to save vertical space' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function escapeHtml\(value\) \{[\s\S]*?\n    \}(?=\n\n    function renderViewer)/);
if (!match) {
  throw new Error("reader render helpers not found");
}
eval(match[0]);
const userMarkup = renderEvent({
  kind: "user",
  timestampLocal: "2026-04-25 12:00:00",
  rawText: "question",
  questionKey: "q1"
});
const answerMarkup = renderEvent({
  kind: "assistant_final",
  timestampLocal: "2026-04-25 12:00:01",
  rawText: "answer"
});
console.log(JSON.stringify({ userMarkup, answerMarkup }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.userMarkup | Should Match '<div class="message-head">[\s\S]*?<button type="button" class="message-copy"'
        $result.userMarkup | Should Not Match '</div><div class="message-blocks">[\s\S]*?</div><button type="button" class="message-copy"'
        $result.answerMarkup | Should Match '<div class="message-head">[\s\S]*?<button type="button" class="message-copy"'
        $html | Should Match '\.message-copy \{[\s\S]*?flex: none'
        $html | Should Not Match '\.message-copy \{[\s\S]*?margin-top: 12px'
    }

    It 'renders current-session search controls and bottom-only question navigation helpers' {
        $html | Should Match 'id="viewerSearch"'
        $html | Should Match 'data-view-mode="questions"'
        $html | Should Match '>提问</button>'
        $html | Should Not Match '>只看提问</button>'
        $html | Should Not Match 'data-view-mode="answers"'
        $html | Should Not Match 'data-view-mode="process"'
        $html | Should Not Match 'data-view-mode="tools"'
        $html | Should Not Match '打开 JSONL'
        $html | Should Not Match 'id="questionPrev"'
        $html | Should Match 'id="questionNext"'
        $html | Should Match 'data-question-nav="bottom"'
        $html | Should Not Match 'data-question-nav="top"'
        $html | Should Match 'function getQuestionKey\(session, eventIndex\)'
        $html | Should Match 'function jumpQuestion\(direction\)'
        $html | Should Match 'data-question-key'
        $html | Should Match "event\.key === 'ArrowUp'"
        $html | Should Match "event\.key === 'ArrowDown'"
        $html | Should Not Match '搜索范围仅限当前模式下的当前会话内容'
        $html | Should Not Match 'reader-toolbar-note'
        $html | Should Match 'function eventMatchesView\(event\)'
        $html | Should Match 'function eventMatchesSearch\(event, query\)'
        $html | Should Match 'function cacheCurrentDetail\(key, detail\)'
        $html | Should Match 'function clearCurrentDetail\(\)'
        $html | Should Match 'function syncSelectedQuestionKey\(preferredPosition, options\)'
        $html | Should Match 'pendingQuestionFocus = ''last'''
        $html | Should Match 'focusFirstQuestion'
        $html | Should Match "if \(id === 'transcript'\)"
    }

    It 'wires viewer search to full-library filtering through the local search API' {
        $html | Should Match 'const SEARCH_API_URL = ''/api/search'';'
        $html | Should Match 'let globalSearchState ='
        $html | Should Match 'function scheduleGlobalSearch\(\)'
        $html | Should Match 'async function runGlobalSearch\(query'
        $html | Should Match 'function sessionMatchesGlobalSearch\(session\)'
        $html | Should Match 'const globalSearchMatch = sessionMatchesGlobalSearch\(session\)'
        $html | Should Match 'if \(getGlobalSearchQuery\(\)\) \{[\s\S]*?return;[\s\S]*?\}'
        $html | Should Match 'if \(getGlobalSearchQuery\(\) && !sessionMatchesGlobalSearch\(session\)\)'
        $html | Should Match 'function scheduleViewerSearch\(\)[\s\S]*?scheduleGlobalSearch\(\)'
        $html | Should Match 'viewerSearchInput\.addEventListener\(''input'', \(\) => \{[\s\S]*?scheduleViewerSearch\(\)'
        $html | Should Not Match 'viewerSearchInput\.addEventListener\(''input'', \(\) => \{[\s\S]*?renderViewer\(\);\s*\}\);'
    }

    It 'matches V0.22 current-session search terms with whitespace-split AND semantics' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function getSearchTerms\(query\) \{[\s\S]*?\n    \}(?=\n\n    function eventMatchesSearch)/);
const eventMatch = html.match(/function eventMatchesSearch\(event, query\) \{[\s\S]*?\n    \}(?=\n\n    function getVisibleDetailEvents)/);
if (!match || !eventMatch) {
  throw new Error("V0.22 search helpers not found");
}
eval(match[0] + "\n" + eventMatch[0]);
const event = { summary: "exit was captured", rawText: "the code path is visible", toolName: "", status: "" };
console.log(JSON.stringify({
  terms: getSearchTerms("  exit   code  "),
  both: eventMatchesSearch(event, "exit code"),
  reversed: eventMatchesSearch(event, "code exit"),
  missing: eventMatchesSearch(event, "exit missing"),
  blank: eventMatchesSearch(event, "   ")
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        ($result.terms -join ',') | Should Be 'exit,code'
        $result.both | Should Be $true
        $result.reversed | Should Be $true
        $result.missing | Should Be $false
        $result.blank | Should Be $true
    }

    It 'highlights V0.22 visible transcript text without changing registered copy text' {
        $html | Should Match 'function highlightMatchesInElement\(root, terms\)'
        $html | Should Match 'document\.createTreeWalker\([^)]*NodeFilter\.SHOW_TEXT'
        $html | Should Match 'mark\.className = ''search-hit'''
        $html | Should Match 'node\.parentElement\.closest\(''mark,script,style''\)'
        $html | Should Match 'highlightMatchesInElement\(transcript, getSearchTerms\(viewerSearchQuery\)\)'
        $html | Should Match 'highlightMatchesInElement\(body, getSearchTerms\(viewerSearchQuery\)\)'
        $html | Should Not Match 'messageCopyTexts\.set\(id, [^;]*mark'
    }

    It 'orders V0.22 search input, search scope, display mode, and tool controls without text labels' {
        $html | Should Match 'class="toolbar-segment toolbar-segment--view"'
        $html | Should Match 'class="toolbar-segment toolbar-segment--search"'
        $html | Should Match 'class="toolbar-segment toolbar-segment--tools"'
        $html | Should Not Match 'toolbar-group-label'
        $html | Should Not Match '>显示：</span>'
        $html | Should Not Match '>搜索：</span>'
        $html | Should Match 'data-view-mode="all"'
        $html | Should Match 'data-view-mode="questions"'
        $html | Should Match 'data-search-scope="all"'
        $html | Should Match 'data-search-scope="current"'
        $html | Should Match 'let viewerSearchScope = ''all'''
        $html | Should Match 'function scheduleViewerSearch\(\)'
        $html | Should Match 'viewerSearchScope === ''current'''
        $html | Should Match 'viewerSearchInput\.addEventListener\(''input'', \(\) => \{[\s\S]*?scheduleViewerSearch\(\)'
        $html | Should Match 'button\[data-search-scope\]'
        $searchInputIndex = $html.IndexOf('id="viewerSearch"')
        $searchScopeIndex = $html.IndexOf('toolbar-segment toolbar-segment--search')
        $viewModeIndex = $html.IndexOf('toolbar-segment toolbar-segment--view')
        $toolsIndex = $html.IndexOf('toolbar-segment toolbar-segment--tools')
        $searchInputIndex | Should BeGreaterThan -1
        $searchScopeIndex | Should BeGreaterThan $searchInputIndex
        $viewModeIndex | Should BeGreaterThan $searchScopeIndex
        $toolsIndex | Should BeGreaterThan $viewModeIndex
    }

    It 'debounces V0.22 current-session search and keeps full-library search debounce unchanged' {
        $html | Should Match 'let currentScopeSearchTimer = 0'
        $html | Should Match 'const CURRENT_SCOPE_SEARCH_DELAY_MS = 160'
        $html | Should Match 'let viewerSearchInputIsComposing = false'
        $html | Should Match 'viewerSearchInput\.addEventListener\(''compositionstart'', \(\) => \{[\s\S]*?viewerSearchInputIsComposing = true'
        $html | Should Match 'viewerSearchInput\.addEventListener\(''compositionend'', \(\) => \{[\s\S]*?viewerSearchInputIsComposing = false;[\s\S]*?scheduleViewerSearch\(\)'
        $html | Should Match 'if \(viewerSearchInputIsComposing\) return'
        $html | Should Match 'setTimeout\(\(\) => \{[\s\S]*?renderViewer\(\);[\s\S]*?\}, CURRENT_SCOPE_SEARCH_DELAY_MS\)'
        $html | Should Match 'setTimeout\(\(\) => \{[\s\S]*?runGlobalSearch\(query\);[\s\S]*?\}, 240\)'
    }

    It 'navigates V0.22 search results using visible question keys' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function updateQuestionNavState\(\) \{[\s\S]*?\n    \}(?=\n\n    function findQuestionElement)/);
const jumpMatch = html.match(/function jumpQuestion\(direction\) \{[\s\S]*?\n    \}(?=\n\n    function handleQuestionSelectionFromRender)/);
if (!match || !jumpMatch) {
  throw new Error("question navigation helpers not found");
}
let viewerSearchQuery = "needle";
let viewerSearchScope = "current";
let selectedQuestionKey = "q1";
const questionNextButton = { disabled: null };
const transcript = {
  querySelectorAll(selector) {
    if (selector !== "[data-question-key]") return [];
    return [
      { dataset: { questionKey: "q1" } },
      { dataset: { questionKey: "q3" } }
    ];
  }
};
function getSearchTerms(query) { return String(query || "").trim().toLowerCase().split(/\s+/).filter(Boolean); }
function getQuestionEvents() {
  return [{ questionKey: "q1" }, { questionKey: "q2" }, { questionKey: "q3" }];
}
const selected = [];
function setSelectedQuestionKey(key, options) {
  selected.push({ key, options });
  selectedQuestionKey = key;
}
eval(match[0] + "\n" + jumpMatch[0]);
updateQuestionNavState();
const initialNextDisabled = questionNextButton.disabled;
jumpQuestion(1);
updateQuestionNavState();
console.log(JSON.stringify({
  initialNextDisabled,
  selected,
  nextDisabled: questionNextButton.disabled
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.initialNextDisabled | Should Be $false
        $result.selected[0].key | Should Be 'q3'
        $result.selected[0].options.behavior | Should Be 'keyboard'
        $result.nextDisabled | Should Be $false
    }

    It 'uses compact grouped toolbar controls with bottom-only transcript navigation' {
        $html | Should Match 'class="toolbar-segment toolbar-segment--view"'
        $html | Should Match 'class="toolbar-segment toolbar-segment--search"'
        $html | Should Match 'class="toolbar-segment toolbar-segment--tools"'
        $html | Should Match '<button type="button" data-view-mode="all">全部</button>'
        $html | Should Match '<button type="button" data-view-mode="questions"[^>]*>提问</button>'
        $html | Should Match '<button type="button" data-search-scope="all"[^>]*>全部</button>'
        $html | Should Match '<button type="button" data-search-scope="current"[^>]*>当前</button>'
        $html | Should Match '<button type="button" id="questionNext" data-question-nav="bottom"[^>]*>底部</button>'
        $html | Should Match 'function scrollTranscriptTop\(\)'
        $html | Should Match 'function scrollTranscriptBottom\(\)'
        $html | Should Match 'focusFirstQuestion\(\{ scroll: false \}\)'
        $html | Should Match 'focusLastQuestion\(\{ scroll: false \}\)'
        $html | Should Match 'scrollTranscriptBottom\(\)'
        $html | Should Not Match 'toolbar-group-label'
        $html | Should Not Match '>显示：</span>'
        $html | Should Not Match '>搜索：</span>'
        $html | Should Not Match 'id="questionPrev"'
        $html | Should Not Match 'data-question-nav="top"'
        $html | Should Not Match '>顶部</button>'
        $html | Should Not Match 'data-question-nav="prev">向上'
        $html | Should Not Match 'data-question-nav="next">向下'
    }

    It 'keeps bottom navigation pinned until the transcript reaches its final bottom' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const bottomMatch = html.match(/function scrollTranscriptBottom\(\) \{[\s\S]*?\n    \}(?=\n\n    function ensureSelection)/);
if (!bottomMatch) {
  throw new Error("bottom navigation helper not found");
}
let selectedQuestionKey = null;
let activeQuestionScrollToken = 0;
let transcriptLayoutLockTimer = 0;
let rafCallbacks = [];
let collapsedAfterUnlock = false;
function requestAnimationFrame(callback) { rafCallbacks.push(callback); return rafCallbacks.length; }
function cancelAnimationFrame() {}
function cancelQuestionScrollAnimation() {}
function setTimeout(callback) { return 1; }
function clearTimeout() {}
function lockTranscriptLayoutForProgrammaticScroll() {}
function unlockTranscriptLayoutForProgrammaticScroll() {
  if (!collapsedAfterUnlock) {
    collapsedAfterUnlock = true;
    transcript.scrollHeight = 1200;
    transcript.scrollTop = 100;
  }
}
function focusLastQuestion() { selectedQuestionKey = "last"; return true; }
function focusTranscriptForQuestionNavigation() { return true; }
const calls = [];
const transcript = {
  scrollTop: 0,
  scrollHeight: 1000,
  clientHeight: 250,
  scrollTo(options) {
    calls.push(options);
    this.scrollTop = Math.max(0, options.top - this.clientHeight);
  }
};
eval(bottomMatch[0]);
scrollTranscriptBottom();
let frame = 0;
while (rafCallbacks.length && frame < 40) {
  const callback = rafCallbacks.shift();
  if (frame === 2) transcript.scrollHeight = 1800;
  callback();
  frame++;
}
console.log(JSON.stringify({
  selectedQuestionKey,
  frames: frame,
  lastTop: calls.length ? calls[calls.length - 1].top : null,
  lastBehavior: calls.length ? calls[calls.length - 1].behavior : null,
  callCount: calls.length,
  bottomGap: transcript.scrollHeight - transcript.clientHeight - transcript.scrollTop
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.selectedQuestionKey | Should Be 'last'
        $result.lastTop | Should Be 1200
        $result.lastBehavior | Should Be 'auto'
        [int]$result.callCount | Should BeGreaterThan 6
        [int]$result.bottomGap | Should Be 0
    }

    It 'keeps top navigation pinned until the transcript reaches its final top' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const topMatch = html.match(/function scrollTranscriptTop\(\) \{[\s\S]*?\n    \}(?=\n\n    function scrollTranscriptBottom)/);
if (!topMatch) {
  throw new Error("top navigation helper not found");
}
let selectedQuestionKey = null;
let activeQuestionScrollToken = 0;
let transcriptLayoutLockTimer = 0;
let rafCallbacks = [];
let collapsedAfterUnlock = false;
function requestAnimationFrame(callback) { rafCallbacks.push(callback); return rafCallbacks.length; }
function cancelAnimationFrame() {}
function cancelQuestionScrollAnimation() {}
function setTimeout(callback) { return 1; }
function clearTimeout() {}
function lockTranscriptLayoutForProgrammaticScroll() {}
function unlockTranscriptLayoutForProgrammaticScroll() {
  if (!collapsedAfterUnlock) {
    collapsedAfterUnlock = true;
    transcript.scrollTop = 380;
  }
}
function focusFirstQuestion() { selectedQuestionKey = "first"; return true; }
function focusTranscriptForQuestionNavigation() { return true; }
const calls = [];
const transcript = {
  scrollTop: 900,
  scrollTo(options) {
    calls.push(options);
    this.scrollTop = options.top;
  }
};
eval(topMatch[0]);
scrollTranscriptTop();
let frame = 0;
while (rafCallbacks.length && frame < 40) {
  const callback = rafCallbacks.shift();
  callback();
  frame++;
}
console.log(JSON.stringify({
  selectedQuestionKey,
  frames: frame,
  lastTop: calls.length ? calls[calls.length - 1].top : null,
  lastBehavior: calls.length ? calls[calls.length - 1].behavior : null,
  callCount: calls.length,
  scrollTop: transcript.scrollTop
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.selectedQuestionKey | Should Be 'first'
        $result.lastTop | Should Be 0
        $result.lastBehavior | Should Be 'auto'
        [int]$result.callCount | Should BeGreaterThan 6
        [int]$result.scrollTop | Should Be 0
    }

    It 'keeps keyboard question navigation anchored near the top of the transcript' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const scrollMatch = html.match(/function scrollTranscriptTo\(top, behavior, fallbackElement, options\) \{[\s\S]*?\n    \}(?=\n\n    function convergeScrollToQuestion)/);
const convergeMatch = html.match(/function convergeScrollToQuestion\(questionKey, behavior\) \{[\s\S]*?\n    \}(?=\n\n    function scrollToQuestion)/);
const questionMatch = html.match(/function scrollToQuestion\(questionKey, behavior\) \{[\s\S]*?\n    \}(?=\n\n    function highlightCurrentQuestion)/);
const selectMatch = html.match(/function setSelectedQuestionKey\(questionKey, options\) \{[\s\S]*?\n    \}(?=\n\n    function focusFirstQuestion)/);
const jumpMatch = html.match(/function jumpQuestion\(direction\) \{[\s\S]*?\n    \}(?=\n\n    function handleQuestionSelectionFromRender)/);
if (!scrollMatch || !convergeMatch || !questionMatch || !selectMatch || !jumpMatch) {
  throw new Error("question scroll helpers not found");
}
let activeQuestionScrollAnimation = 0;
let activeQuestionScrollToken = 0;
let selectedQuestionKey = "q1";
let rafCallbacks = [];
let lockCount = 0;
function requestAnimationFrame(callback) { rafCallbacks.push(callback); return rafCallbacks.length; }
function cancelAnimationFrame() {}
function cancelQuestionScrollAnimation() { activeQuestionScrollAnimation = 0; }
function lockTranscriptLayoutForProgrammaticScroll() { lockCount++; }
function unlockTranscriptLayoutForProgrammaticScroll() {}
const performance = { now: () => 0 };
const positions = [];
const transcript = {
  scrollTop: 0,
  scrollHeight: 4000,
  clientHeight: 500,
  style: { setProperty() {} },
  querySelectorAll(selector) {
    if (selector !== "[data-question-key]") return [];
    return [
      { dataset: { questionKey: "q1" }, offsetTop: 900, offsetHeight: 120 },
      { dataset: { questionKey: "q2" }, offsetTop: 1600, offsetHeight: 120 }
    ];
  },
  scrollTo(args) {
    positions.push(args.top);
    this.scrollTop = args.top;
  }
};
function getSearchTerms() { return []; }
function getQuestionEvents() { return [{ questionKey: "q1" }, { questionKey: "q2" }]; }
function getNavigableQuestionKeys() { return getQuestionEvents().map(event => event.questionKey); }
function findQuestionElement(questionKey) {
  return Array.from(transcript.querySelectorAll("[data-question-key]")).find(node => node.dataset.questionKey === questionKey) || null;
}
function calculateQuestionScrollSpacer() { return 0; }
function highlightCurrentQuestion() {}
eval(scrollMatch[0] + "\n" + convergeMatch[0] + "\n" + questionMatch[0] + "\n" + selectMatch[0] + "\n" + jumpMatch[0]);
jumpQuestion(1);
while (rafCallbacks.length) {
  const callback = rafCallbacks.shift();
  callback(1000);
}
console.log(JSON.stringify({ selectedQuestionKey, positions, scrollTop: transcript.scrollTop, lockCount, rafQueued: rafCallbacks.length }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.selectedQuestionKey | Should Be 'q2'
        [int]$result.lockCount | Should Be 1
        [int]$result.rafQueued | Should Be 0
        [int]$result.positions.Count | Should BeGreaterThan 0
        [int]$result.scrollTop | Should Be 1584
    }

    It 'uses a short locked stable scroll path for keyboard question navigation' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const cancelMatch = html.match(/function cancelQuestionScrollAnimation\(\) \{[\s\S]*?\n    \}(?=\n\n    function lockTranscriptLayoutForProgrammaticScroll)/);
const lockMatch = html.match(/function lockTranscriptLayoutForProgrammaticScroll\([^)]*\) \{[\s\S]*?\n    \}(?=\n\n    function unlockTranscriptLayoutForProgrammaticScroll)/);
const unlockMatch = html.match(/function unlockTranscriptLayoutForProgrammaticScroll\(\) \{[\s\S]*?\n    \}(?=\n\n    function calculateQuestionScrollSpacer)/);
const stableMatch = html.match(/function stableScrollToQuestionForKeyboard\(questionKey\) \{[\s\S]*?\n    \}(?=\n\n    function scrollToQuestion)/);
const questionMatch = html.match(/function scrollToQuestion\(questionKey, behavior\) \{[\s\S]*?\n    \}(?=\n\n    function highlightCurrentQuestion)/);
const selectMatch = html.match(/function setSelectedQuestionKey\(questionKey, options\) \{[\s\S]*?\n    \}(?=\n\n    function focusFirstQuestion)/);
if (!cancelMatch || !lockMatch || !unlockMatch || !stableMatch || !questionMatch || !selectMatch) {
  throw new Error("stable keyboard question scroll helpers not found");
}
let activeQuestionScrollAnimation = 99;
let activeQuestionScrollToken = 0;
let transcriptLayoutLockTimer = 0;
let selectedQuestionKey = "q1";
let selectedQuestionKeyIsTemporary = false;
let rafCallbacks = [];
let timeoutCalls = [];
let timeoutCallbacks = [];
let clearTimeoutCalls = [];
let lockAdds = 0;
let lockRemoves = 0;
let cancelCalls = 0;
let savedAnchors = 0;
let q2RectTop = 600;
const styleCalls = [];
const scrollCalls = [];
function requestAnimationFrame(callback) { rafCallbacks.push(callback); return rafCallbacks.length; }
function cancelAnimationFrame(id) { cancelCalls += 1; }
function setTimeout(callback, ms) { timeoutCalls.push(ms); timeoutCallbacks.push(callback); return timeoutCalls.length; }
function clearTimeout(value) { clearTimeoutCalls.push(value); }
function saveProgressAnchorForCurrentSession() { savedAnchors += 1; }
function highlightCurrentQuestion() { global.__highlighted = true; }
const q2 = {
  dataset: { questionKey: "q2" },
  offsetTop: 1600,
  offsetHeight: 120,
  getBoundingClientRect() { return { top: q2RectTop }; }
};
const transcript = {
  scrollTop: 1000,
  scrollHeight: 3000,
  clientHeight: 500,
  classList: {
    add(name) { if (name === "is-programmatic-scroll") lockAdds += 1; },
    remove(name) { if (name === "is-programmatic-scroll") lockRemoves += 1; }
  },
  style: {
    setProperty(name, value) { styleCalls.push({ name, value }); }
  },
  querySelectorAll(selector) {
    if (selector !== "[data-question-key]") return [];
    return [q2];
  },
  getBoundingClientRect() { return { top: 100 }; },
  scrollTo(args) {
    scrollCalls.push({ top: args.top, behavior: args.behavior });
    this.scrollTop = args.top;
    q2RectTop = scrollCalls.length === 1 ? 222 : 116;
  }
};
function findQuestionElement(questionKey) {
  return questionKey === "q2" ? q2 : null;
}
function calculateQuestionScrollSpacer() { return 32; }
eval(cancelMatch[0] + "\n" + lockMatch[0] + "\n" + unlockMatch[0] + "\n" + stableMatch[0] + "\n" + questionMatch[0] + "\n" + selectMatch[0]);
setSelectedQuestionKey("q2", { scroll: true, behavior: "keyboard" });
const afterSelectBeforeFrames = { scrollCount: scrollCalls.length, rafCount: rafCallbacks.length };
let frames = 0;
while (rafCallbacks.length && frames < 5) {
  const callback = rafCallbacks.shift();
  callback();
  frames += 1;
}
const beforeTimeout = { lockRemoves, scrollCount: scrollCalls.length, remainingRaf: rafCallbacks.length };
while (timeoutCallbacks.length) {
  timeoutCallbacks.shift()();
}
console.log(JSON.stringify({
  selectedQuestionKey,
  savedAnchors,
  activeQuestionScrollAnimation,
  cancelCalls,
  timeoutCalls,
  clearTimeoutCalls,
  lockAdds,
  lockRemoves,
  styleCalls,
  scrollCalls,
  afterSelectBeforeFrames,
  beforeTimeout,
  frames,
  remainingRaf: rafCallbacks.length
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20
        $scrollCalls = @($result.scrollCalls)

        $result.selectedQuestionKey | Should Be 'q2'
        $result.savedAnchors | Should Be 1
        $result.cancelCalls | Should Be 1
        $result.activeQuestionScrollAnimation | Should Be 0
        $result.timeoutCalls[0] | Should Be 250
        $result.lockAdds | Should Be 1
        $result.beforeTimeout.lockRemoves | Should Be 0
        $result.lockRemoves | Should Be 1
        $result.afterSelectBeforeFrames.scrollCount | Should Be 0
        $result.afterSelectBeforeFrames.rafCount | Should Be 1
        $scrollCalls.Count | Should Be 2
        $scrollCalls[0].top | Should Be 1484
        $scrollCalls[0].behavior | Should Be 'auto'
        $scrollCalls[1].top | Should Be 1590
        $scrollCalls[1].behavior | Should Be 'auto'
        $result.remainingRaf | Should Be 0
    }

    It 'corrects keyboard question scroll once after layout unlock clamps scroll position' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const cancelMatch = html.match(/function cancelQuestionScrollAnimation\(\) \{[\s\S]*?\n    \}(?=\n\n    function lockTranscriptLayoutForProgrammaticScroll)/);
const lockMatch = html.match(/function lockTranscriptLayoutForProgrammaticScroll\([^)]*\) \{[\s\S]*?\n    \}(?=\n\n    function unlockTranscriptLayoutForProgrammaticScroll)/);
const unlockMatch = html.match(/function unlockTranscriptLayoutForProgrammaticScroll\(\) \{[\s\S]*?\n    \}(?=\n\n    function calculateQuestionScrollSpacer)/);
const stableMatch = html.match(/function stableScrollToQuestionForKeyboard\(questionKey\) \{[\s\S]*?\n    \}(?=\n\n    function scrollToQuestion)/);
if (!cancelMatch || !lockMatch || !unlockMatch || !stableMatch) {
  throw new Error("stable keyboard question scroll helpers not found");
}
let activeQuestionScrollAnimation = 0;
let activeQuestionScrollToken = 0;
let transcriptLayoutLockTimer = 0;
let rafCallbacks = [];
let timeoutCallbacks = [];
let q2RectTop = 600;
let unlockCount = 0;
const styleCalls = [];
const scrollCalls = [];
function requestAnimationFrame(callback) { rafCallbacks.push(callback); return rafCallbacks.length; }
function cancelAnimationFrame() {}
function setTimeout(callback, ms) { timeoutCallbacks.push(callback); return 1; }
function clearTimeout() {}
const q2 = {
  dataset: { questionKey: "q2" },
  offsetTop: 1600,
  offsetHeight: 120,
  getBoundingClientRect() { return { top: q2RectTop }; }
};
const transcript = {
  scrollTop: 1000,
  scrollHeight: 26000,
  clientHeight: 500,
  classList: {
    add() {},
    remove() {
      unlockCount += 1;
      this._removed = true;
      transcript.scrollHeight = 1100;
      transcript.scrollTop = 600;
      q2RectTop = 0;
    }
  },
  style: {
    setProperty(name, value) {
      styleCalls.push({ name, value });
    }
  },
  getBoundingClientRect() { return { top: 100 }; },
  scrollTo(args) {
    scrollCalls.push({ top: args.top, behavior: args.behavior });
    this.scrollTop = args.top;
    q2RectTop = 116;
  }
};
function findQuestionElement(questionKey) { return questionKey === "q2" ? q2 : null; }
function calculateQuestionScrollSpacer() { return unlockCount ? 800 : 0; }
eval(cancelMatch[0] + "\n" + lockMatch[0] + "\n" + unlockMatch[0] + "\n" + stableMatch[0]);
stableScrollToQuestionForKeyboard("q2");
let frames = 0;
while (rafCallbacks.length && frames < 5) {
  const callback = rafCallbacks.shift();
  callback();
  frames += 1;
}
const beforeTimeout = { scrollCount: scrollCalls.length, unlockCount, finalScrollTop: transcript.scrollTop };
while (timeoutCallbacks.length) {
  timeoutCallbacks.shift()();
}
console.log(JSON.stringify({ scrollCalls, styleCalls, unlockCount, frames, beforeTimeout, remainingRaf: rafCallbacks.length, finalScrollTop: transcript.scrollTop }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20
        $scrollCalls = @($result.scrollCalls)
        $styleCalls = @($result.styleCalls)

        $result.unlockCount | Should Be 1
        $result.beforeTimeout.unlockCount | Should Be 0
        $result.beforeTimeout.scrollCount | Should Be 1
        $scrollCalls.Count | Should Be 2
        $styleCalls.Count | Should Be 2
        $styleCalls[0].value | Should Be '0px'
        $styleCalls[1].value | Should Be '800px'
        $scrollCalls[0].top | Should Be 1484
        $scrollCalls[1].top | Should Be 484
        $scrollCalls[1].behavior | Should Be 'auto'
        $result.finalScrollTop | Should Be 484
        $result.remainingRaf | Should Be 0
    }

    It 'does not correct keyboard question scroll when the target is within tolerance' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const cancelMatch = html.match(/function cancelQuestionScrollAnimation\(\) \{[\s\S]*?\n    \}(?=\n\n    function lockTranscriptLayoutForProgrammaticScroll)/);
const lockMatch = html.match(/function lockTranscriptLayoutForProgrammaticScroll\([^)]*\) \{[\s\S]*?\n    \}(?=\n\n    function unlockTranscriptLayoutForProgrammaticScroll)/);
const unlockMatch = html.match(/function unlockTranscriptLayoutForProgrammaticScroll\(\) \{[\s\S]*?\n    \}(?=\n\n    function calculateQuestionScrollSpacer)/);
const stableMatch = html.match(/function stableScrollToQuestionForKeyboard\(questionKey\) \{[\s\S]*?\n    \}(?=\n\n    function scrollToQuestion)/);
if (!cancelMatch || !lockMatch || !unlockMatch || !stableMatch) {
  throw new Error("stable keyboard question scroll helpers not found");
}
let activeQuestionScrollAnimation = 0;
let activeQuestionScrollToken = 0;
let transcriptLayoutLockTimer = 0;
let rafCallbacks = [];
let timeoutCallbacks = [];
let unlockCount = 0;
let q2RectTop = 600;
const scrollCalls = [];
function requestAnimationFrame(callback) { rafCallbacks.push(callback); return rafCallbacks.length; }
function cancelAnimationFrame() {}
function setTimeout(callback, ms) { timeoutCallbacks.push(callback); return 1; }
function clearTimeout() {}
const q2 = {
  dataset: { questionKey: "q2" },
  offsetTop: 1600,
  offsetHeight: 120,
  getBoundingClientRect() { return { top: q2RectTop }; }
};
const transcript = {
  scrollTop: 1000,
  scrollHeight: 3000,
  clientHeight: 500,
  classList: { add() {}, remove() { unlockCount += 1; } },
  style: { setProperty() {} },
  getBoundingClientRect() { return { top: 100 }; },
  scrollTo(args) {
    scrollCalls.push(args);
    this.scrollTop = args.top;
    q2RectTop = 117;
  }
};
function findQuestionElement(questionKey) { return questionKey === "q2" ? q2 : null; }
function calculateQuestionScrollSpacer() { return 0; }
eval(cancelMatch[0] + "\n" + lockMatch[0] + "\n" + unlockMatch[0] + "\n" + stableMatch[0]);
stableScrollToQuestionForKeyboard("q2");
let frames = 0;
while (rafCallbacks.length && frames < 5) {
  const callback = rafCallbacks.shift();
  callback();
  frames += 1;
}
while (timeoutCallbacks.length) {
  timeoutCallbacks.shift()();
}
console.log(JSON.stringify({ scrollCalls, unlockCount, remainingRaf: rafCallbacks.length }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20

        @($result.scrollCalls).Count | Should Be 1
        $result.unlockCount | Should Be 1
        $result.remainingRaf | Should Be 0
    }

    It 'keeps non-keyboard question selection on the existing deferred scroll path' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const selectMatch = html.match(/function setSelectedQuestionKey\(questionKey, options\) \{[\s\S]*?\n    \}(?=\n\n    function focusFirstQuestion)/);
if (!selectMatch) {
  throw new Error("question selection helper not found");
}
let selectedQuestionKey = null;
let selectedQuestionKeyIsTemporary = false;
let rafCallbacks = [];
let stableCalls = 0;
let scrollCalls = 0;
function requestAnimationFrame(callback) { rafCallbacks.push(callback); return rafCallbacks.length; }
function highlightCurrentQuestion() {}
function saveProgressAnchorForCurrentSession() {}
function stableScrollToQuestionForKeyboard() { stableCalls += 1; }
function scrollToQuestion(questionKey, behavior) {
  scrollCalls += 1;
  global.__scroll = { questionKey, behavior };
}
eval(selectMatch[0]);
setSelectedQuestionKey("q2", { scroll: true, behavior: "auto" });
const beforeFrame = { stableCalls, scrollCalls, rafCount: rafCallbacks.length };
while (rafCallbacks.length) {
  rafCallbacks.shift()();
}
console.log(JSON.stringify({ beforeFrame, stableCalls, scrollCalls, scroll: global.__scroll }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.beforeFrame.stableCalls | Should Be 0
        $result.beforeFrame.scrollCalls | Should Be 0
        $result.beforeFrame.rafCount | Should Be 1
        $result.stableCalls | Should Be 0
        $result.scrollCalls | Should Be 1
        $result.scroll.behavior | Should Be 'auto'
    }

    It 're-converges explicit smooth question navigation when lazy layout shifts the target element' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const scrollMatch = html.match(/function scrollTranscriptTo\(top, behavior, fallbackElement, options\) \{[\s\S]*?\n    \}(?=\n\n    function convergeScrollToQuestion)/);
const convergeMatch = html.match(/function convergeScrollToQuestion\(questionKey, behavior\) \{[\s\S]*?\n    \}(?=\n\n    function scrollToQuestion)/);
const questionMatch = html.match(/function scrollToQuestion\(questionKey, behavior\) \{[\s\S]*?\n    \}(?=\n\n    function highlightCurrentQuestion)/);
if (!scrollMatch || !convergeMatch || !questionMatch) {
  throw new Error("question scroll helpers not found");
}
let activeQuestionScrollAnimation = 0;
let activeQuestionScrollToken = 0;
let selectedQuestionKey = "q1";
let rafCallbacks = [];
let collapsedAfterUnlock = false;
function requestAnimationFrame(callback) { rafCallbacks.push(callback); return rafCallbacks.length; }
function cancelAnimationFrame() {}
function lockTranscriptLayoutForProgrammaticScroll() {}
function unlockTranscriptLayoutForProgrammaticScroll() {
  if (!collapsedAfterUnlock) {
    collapsedAfterUnlock = true;
    q2Top = 1600;
    transcript.scrollTop = 7580;
  }
}
const performance = { now: () => 0 };
let q2Top = 1600;
const transcript = {
  scrollTop: 0,
  scrollHeight: 5000,
  clientHeight: 500,
  style: { setProperty() {}, removeProperty() {} },
  getBoundingClientRect() { return { top: 0 }; },
  querySelectorAll(selector) {
    if (selector !== "[data-question-key]") return [];
    return [
      { dataset: { questionKey: "q1" }, offsetTop: 900, offsetHeight: 120, getBoundingClientRect() { return { top: 900 - transcript.scrollTop }; } },
      { dataset: { questionKey: "q2" }, offsetTop: q2Top, offsetHeight: 120, getBoundingClientRect() { return { top: q2Top - transcript.scrollTop }; } }
    ];
  },
  scrollTo(args) {
    this.scrollTop = args.top;
  }
};
function getSearchTerms() { return []; }
function getQuestionEvents() { return [{ questionKey: "q1" }, { questionKey: "q2" }]; }
function getNavigableQuestionKeys() { return getQuestionEvents().map(event => event.questionKey); }
function findQuestionElement(questionKey) {
  return Array.from(transcript.querySelectorAll("[data-question-key]")).find(node => node.dataset.questionKey === questionKey) || null;
}
function calculateQuestionScrollSpacer() { return 0; }
function highlightCurrentQuestion() {}
eval(scrollMatch[0] + "\n" + convergeMatch[0] + "\n" + questionMatch[0]);
convergeScrollToQuestion("q2", "smooth");
let frame = 0;
while (rafCallbacks.length && frame < 40) {
  const callback = rafCallbacks.shift();
  if (frame === 2) q2Top = 2300;
  callback(1000 + frame * 16);
  frame++;
}
console.log(JSON.stringify({ selectedQuestionKey, scrollTop: transcript.scrollTop, frame }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        [Math]::Abs([int]$result.scrollTop - 1584) | Should BeLessThan 3
    }

    It 'adds the previous user question as V0.17 search context for answer and tool matches' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function escapeHtml\(value\) \{[\s\S]*?\n    \}(?=\n\n    function renderViewer)/);
if (!match) {
  throw new Error("reader render helpers not found");
}
var APP = { workspaces: [{ id: "ws-1", sessions: [{ key: "session-key", id: "session-id", path: "demo.jsonl" }] }] };
var selectedWorkspaceId = "ws-1";
var selectedSessionKey = "session-key";
var CURRENT_DETAIL = {
  events: [
    { kind: "user", timestampLocal: "2026-06-15 10:00:00", rawText: "How do I compile it?" },
    { kind: "assistant_final", timestampLocal: "2026-06-15 10:00:01", rawText: "Use cmake with answer-only-needle." },
    { kind: "user", timestampLocal: "2026-06-15 10:01:00", rawText: "Show diagnostics needle" },
    { kind: "tool", timestampLocal: "2026-06-15 10:01:01", toolName: "exec_command", summary: "tool-only-needle", rawText: "raw output" }
  ]
};
var viewerSearchQuery = "answer-only-needle";
var viewerViewMode = "all";
var selectedQuestionKey = null;
var messageCopyTexts = new Map();
var messageCopySerial = 0;
var lazyDetailRenderers = new Map();
var lazyDetailSerial = 0;
eval(match[0]);
const answerEvents = getVisibleDetailEvents();
const answerMarkup = buildReaderMarkup(answerEvents, {});
viewerSearchQuery = "needle";
const mixedEvents = getVisibleDetailEvents();
const mixedMarkup = buildReaderMarkup(mixedEvents, {});
console.log(JSON.stringify({
  answerKinds: answerEvents.map(event => event.kind),
  answerContext: !!answerEvents[0].isSearchContext,
  answerMarkup,
  mixedKinds: mixedEvents.map(event => event.kind),
  mixedContextCount: mixedEvents.filter(event => event.isSearchContext).length,
  mixedMarkup
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20

        ($result.answerKinds -join ',') | Should Be 'user,assistant_final'
        $result.answerContext | Should Be $true
        $result.answerMarkup | Should Match '上下文提问'
        $result.answerMarkup | Should Match 'How do I compile it\?'
        ($result.mixedKinds -join ',') | Should Be 'user,assistant_final,user,tool'
        $result.mixedContextCount | Should Be 1
        $result.mixedMarkup | Should Match 'Show diagnostics needle'
        $result.mixedMarkup | Should Match '执行过程'
    }

    It 'selects title pane entries without rebuilding the title list' {
        $html | Should Match 'function syncSessionListSelection\(\)'
        $html | Should Match 'function preventTitleButtonMouseFocus\(event\)'
        $html | Should Match 'async function selectSessionFromTitlePane\(session\)'
        $html | Should Match 'async function selectSession\(session, options\)'
        $html | Should Match 'groupHead\.dataset\.sessionKeys = group\.sessions\.map\(item => getSessionKey\(item\)\)\.join\(''\|''\)'
        $html | Should Match 'btn\.dataset\.sessionKey = getSessionKey\(session\)'
        $html | Should Match 'groupHead\.onmousedown = preventTitleButtonMouseFocus'
        $html | Should Match 'btn\.onmousedown = preventTitleButtonMouseFocus'
        $html | Should Match 'await selectSessionFromTitlePane\(group\.sessions\[0\]\)'
        $html | Should Match 'await selectSessionFromTitlePane\(session\)'
        $html | Should Not Match 'preserveSessionListScroll\(\(\) => selectSession\(group\.sessions\[0\]\)\)'
        $html | Should Not Match 'preserveSessionListScroll\(\(\) => selectSession\(session\)\)'

        $titleSelection = [regex]::Match($html, 'async function selectSessionFromTitlePane\(session\) \{[\s\S]*?\n    \}')
        $titleSelection.Success | Should Be $true
        $titleSelection.Value | Should Match 'syncSessionListSelection\(\)'
        $titleSelection.Value | Should Match 'selectSession\(session, \{ syncLists: false \}\)'
        $titleSelection.Value | Should Not Match 'renderWorkspaceList'
        $titleSelection.Value | Should Not Match 'renderSessionList'
        $titleSelection.Value | Should Not Match 'sessionList\.innerHTML = '''''
    }

    It 'keeps hidden process and tool raw text searchable without depending on rendered DOM' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const termsMatch = html.match(/function getSearchTerms\(query\) \{[\s\S]*?\n    \}(?=\n\n    function eventMatchesSearch)/);
const match = html.match(/function eventMatchesSearch\(event, query\) \{[\s\S]*?\n    \}(?=\n\n    function getVisibleDetailEvents)/);
if (!termsMatch || !match) {
  throw new Error("eventMatchesSearch helper not found");
}
eval(termsMatch[0] + "\n" + match[0]);
console.log(JSON.stringify({
  toolRaw: eventMatchesSearch({ kind: "tool", toolName: "exec_command", status: "exit=0", summary: "输出 128 行", rawText: "HIDDEN TOOL OUTPUT needle" }, "needle"),
  systemRaw: eventMatchesSearch({ kind: "system", rawText: "系统统计 needle" }, "needle"),
  toolName: eventMatchesSearch({ kind: "tool", toolName: "exec_command", status: "exit=0", summary: "", rawText: "" }, "exec_command")
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.toolRaw | Should Be $true
        $result.systemRaw | Should Be $true
        $result.toolName | Should Be $true
    }

    It 'renders only lazy process summaries in the default viewer markup and omits raw tool output' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function summarizeProcessItems\(items, options\) \{[\s\S]*?\n    \}(?=\n\n    function renderReaderToolbarActions)/);
if (!match) {
  throw new Error("lazy process helpers not found");
}
function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}
function renderLazyDetails(className, summaryHtml, bodyRenderer, options) {
  return '<details class="' + className + '" data-lazy-detail-id="stub"><summary>' + summaryHtml + '</summary><div class="message-blocks" data-lazy-detail-body></div></details>';
}
eval(match[0]);
const items = [
  { kind: "assistant_commentary", timestampLocal: "2026-05-04 10:00:01", rawText: "working note" },
  { kind: "tool", timestampLocal: "2026-05-04 10:00:02", toolName: "exec_command", status: "exit=0", summary: "输出 128 行", rawText: "HIDDEN TOOL OUTPUT needle" },
  { kind: "system", timestampLocal: "2026-05-04 10:00:03", rawText: "系统统计 needle" }
];
const markup = renderCollapsedProcessItems(items, { searchQuery: "" });
console.log(JSON.stringify({ markup }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.markup | Should Match '<details class="collapsed-group"'
        $result.markup | Should Match '执行过程'
        $result.markup | Should Match '工具 1'
        $result.markup | Should Match '系统 1'
        $result.markup | Should Not Match 'HIDDEN TOOL OUTPUT needle'
        $result.markup | Should Not Match '系统统计 needle'
    }

    It 'exports markdown with complete system events and tool raw output even when the viewer shows only summaries' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function buildMarkdown\(detail\) \{[\s\S]*?\n    \}(?=\n\n    function exportSelectedMarkdown)/);
if (!match) {
  throw new Error("buildMarkdown helper not found");
}
eval(match[0]);
const markdown = buildMarkdown({
  title: "示例会话",
  path: "workspace/session.jsonl",
  createdLocal: "2026-05-04 10:00:00",
  updatedLocal: "2026-05-04 10:01:00",
  events: [
    { kind: "user", timestampLocal: "2026-05-04 10:00:00", rawText: "你好" },
    { kind: "assistant_commentary", timestampLocal: "2026-05-04 10:00:01", rawText: "过程说明" },
    { kind: "tool", timestampLocal: "2026-05-04 10:00:02", toolName: "exec_command", status: "exit=0", summary: "输出 128 行", rawText: "HIDDEN TOOL OUTPUT" },
    { kind: "system", timestampLocal: "2026-05-04 10:00:03", rawText: "系统统计信息" },
    { kind: "assistant_final", timestampLocal: "2026-05-04 10:00:04", rawText: "最终答案" }
  ]
});
console.log(JSON.stringify({ markdown }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.markdown | Should Match '^# 示例会话'
        $result.markdown | Should Match '## 用户 \(2026-05-04 10:00:00\)'
        $result.markdown | Should Match '## 过程 \(2026-05-04 10:00:01\)'
        $result.markdown | Should Match '## 工具 \(2026-05-04 10:00:02\)'
        $result.markdown | Should Match 'HIDDEN TOOL OUTPUT'
        $result.markdown | Should Match '## 系统 \(2026-05-04 10:00:03\)'
        $result.markdown | Should Match '系统统计信息'
        $result.markdown | Should Match '## Assistant \(2026-05-04 10:00:04\)'
        $result.markdown | Should Match '最终答案'
    }

    It 'moves keyboard focus into the transcript after title selection and transcript top navigation' {
        $html | Should Match 'function focusTranscriptForQuestionNavigation\(\)'
        $html | Should Match 'pendingQuestionFocus = targetAnchor \? null : ''last'''
        $html | Should Match 'restoreProgressAnchor\(targetAnchor, \{ token: selectRestoreToken, behavior: ''auto'' \}\)'
        $html | Should Match 'requestAnimationFrame\(\(\) => focusTranscriptForQuestionNavigation\(\)\);'

        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function focusTranscriptForQuestionNavigation\(\) \{[\s\S]*?\n    \}(?=\n\n    function ensureSelection)/);
if (!match) {
  throw new Error("transcript focus helper not found");
}
let selectedQuestionKey = null;
let activeQuestionScrollToken = 0;
let transcriptLayoutLockTimer = 0;
let rafCallbacks = [];
function requestAnimationFrame(callback) { rafCallbacks.push(callback); return rafCallbacks.length; }
function cancelAnimationFrame() {}
function cancelQuestionScrollAnimation() {}
function setTimeout() { return 1; }
function clearTimeout() {}
function lockTranscriptLayoutForProgrammaticScroll() {}
function unlockTranscriptLayoutForProgrammaticScroll() {}
const focusCalls = [];
const scrollCalls = [];
const transcript = {
  scrollTop: 200,
  scrollTo(options) {
    scrollCalls.push(options);
    this.scrollTop = options.top;
    global.__scrollToOptions = options;
  },
  focus(options) {
    focusCalls.push(options);
  }
};
global.document = {
  getElementById: id => id === "transcript" ? transcript : null
};
function focusFirstQuestion() {
  selectedQuestionKey = "question-1";
  return true;
}
eval(match[0]);
scrollPaneTop("transcript");
let frame = 0;
while (rafCallbacks.length && frame < 20) {
  const callback = rafCallbacks.shift();
  callback();
  frame++;
}
console.log(JSON.stringify({ focusCalls, scrollToOptions: global.__scrollToOptions, scrollCalls, scrollTop: transcript.scrollTop }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        @($result.focusCalls).Count | Should Be 1
        $result.focusCalls[0].preventScroll | Should Be $true
        $result.scrollToOptions.top | Should Be 0
        $result.scrollToOptions.behavior | Should Be 'auto'
        [int]$result.scrollCalls.Count | Should BeGreaterThan 1
        [int]$result.scrollTop | Should Be 0
    }

    It 'keeps all scroll-to-top controls as fixed-size circular arrow buttons' {
        $scrollTopButtons = [regex]::Matches($html, '<button class="scroll-top"[^>]*>↑</button>')
        $scrollTopButtons.Count | Should Be 3
        $html | Should Match '\.scroll-top \{[\s\S]*?width: 42px'
        $html | Should Match '\.scroll-top \{[\s\S]*?height: 42px'
        $html | Should Match '\.scroll-top \{[\s\S]*?min-height: 42px'
        $html | Should Match '\.scroll-top \{[\s\S]*?flex: none'
        $html | Should Match '\.scroll-top \{[\s\S]*?display: inline-flex'
        $html | Should Match '\.scroll-top \{[\s\S]*?align-items: center'
        $html | Should Match '\.scroll-top \{[\s\S]*?justify-content: center'
        $html | Should Match '\.scroll-top \{[\s\S]*?padding: 0'
        $html | Should Match '\.scroll-top \{[\s\S]*?border-radius: 999px'
    }

    It 'selects the last question on session entry and the first question after returning to top' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function getQuestionKey\(session, eventIndex\) \{[\s\S]*?\n    \}(?=\n\n    function eventMatchesView)/);
if (!match) {
  throw new Error("question focus helpers not found");
}
let selectedQuestionKey = null;
let CURRENT_DETAIL = {
  events: [
    { kind: "user", rawText: "first" },
    { kind: "assistant_final", rawText: "answer" },
    { kind: "user", rawText: "last" }
  ]
};
function getSelectedSession() {
  return { key: "session-1" };
}
function getSessionKey(session) {
  return session && session.key;
}
function getCurrentDetailEvents() {
  return CURRENT_DETAIL.events;
}
eval(match[0]);
syncSelectedQuestionKey("last");
const last = selectedQuestionKey;
selectedQuestionKey = null;
syncSelectedQuestionKey("first");
const first = selectedQuestionKey;
console.log(JSON.stringify({ first, last }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.first | Should Be 'session-1::question::0'
        $result.last | Should Be 'session-1::question::2'
    }

    It 'defines V0.22 per-session progress anchors without persistent storage' {
        $html | Should Match 'const sessionProgressAnchors = new Map\(\)'
        $html | Should Match 'const MAX_PROGRESS_ANCHORS = 200'
        $html | Should Match 'let progressRestoreToken = 0'
        $html | Should Match 'let selectedQuestionKeyIsTemporary = false'
        $html | Should Match 'function captureProgressAnchor\(session\)'
        $html | Should Match 'function resolveQuestionKeyFromAnchor\(anchor, session\)'
        $html | Should Match 'function restoreProgressAnchor\(anchor, options\)'
        $html | Should Match 'workspacePath: workspace \? \(workspace\.cwd \|\| ''''\) : '''''
        $html | Should Match 'persistAnchor: false'
        $html | Should Not Match 'localStorage\.setItem\([^\n]*ProgressAnchor'
        $html | Should Not Match 'localStorage\.getItem\([^\n]*ProgressAnchor'
    }

    It 'resolves V0.22 progress anchors by question key, text hash, and question index without falling back to the first question' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function getQuestionKey\(session, eventIndex\) \{[\s\S]*?\n    \}(?=\n\n    function eventMatchesView)/);
if (!match) {
  throw new Error("progress anchor helpers not found");
}
let selectedQuestionKey = null;
let selectedQuestionKeyIsTemporary = false;
let viewerViewMode = "all";
let viewerSearchScope = "all";
let viewerSearchQuery = "";
let currentSourceId = "local-codex";
let selectedWorkspaceId = "workspace-current";
let selectedSessionKey = "session-1";
let APP = {
  workspaces: [
    { id: "workspace-current", cwd: "/actual/workspace", sessions: [{ key: "session-1", path: "/actual/workspace/session-1.jsonl" }] }
  ]
};
let CURRENT_DETAIL = {
  events: [
    { kind: "user", rawText: "First question" },
    { kind: "assistant_final", rawText: "answer" },
    { kind: "user", rawText: "Middle question" },
    { kind: "user", rawText: "Unique target question" }
  ]
};
const sessionProgressAnchors = new Map();
const MAX_PROGRESS_ANCHORS = 200;
let progressRestoreToken = 0;
function getCurrentSourceId() { return currentSourceId; }
function getSessionKey(session) { return session && (session.key || session.path || session.id || ""); }
function getSelectedSession() {
  const workspace = APP.workspaces.find(item => item.id === selectedWorkspaceId);
  return workspace ? workspace.sessions.find(item => getSessionKey(item) === selectedSessionKey) || null : null;
}
function getCurrentDetailEvents() { return CURRENT_DETAIL.events; }
function findQuestionElement() { return null; }
const transcript = null;
eval(match[0]);
const originalQuestions = getQuestionEvents();
const targetHash = originalQuestions[2].questionTextHash;
CURRENT_DETAIL = {
  events: [
    { kind: "system", rawText: "inserted before questions" },
    { kind: "user", rawText: "First question" },
    { kind: "assistant_final", rawText: "answer" },
    { kind: "user", rawText: "Middle question changed" },
    { kind: "user", rawText: "Unique target question" }
  ]
};
const firstAfterShift = getQuestionEvents()[0].questionKey;
const hashResolved = resolveQuestionKeyFromAnchor({
  sourceId: "local-codex",
  workspacePath: "/actual/workspace",
  sessionKey: "session-1",
  questionKey: "session-1::question::99",
  questionIndex: 0,
  questionTextHash: targetHash
});
const indexResolved = resolveQuestionKeyFromAnchor({
  sourceId: "local-codex",
  workspacePath: "/actual/workspace",
  sessionKey: "session-1",
  questionKey: "missing-key",
  questionIndex: 2,
  questionTextHash: "missing-hash"
});
const overflowResolved = resolveQuestionKeyFromAnchor({
  sourceId: "local-codex",
  workspacePath: "/actual/workspace",
  sessionKey: "session-1",
  questionKey: "missing-key",
  questionIndex: 99,
  questionTextHash: "missing-hash"
});
const wrongSourceResolved = resolveQuestionKeyFromAnchor({
  sourceId: "other-source",
  workspacePath: "/actual/workspace",
  sessionKey: "session-1",
  questionKey: hashResolved,
  questionIndex: 2,
  questionTextHash: targetHash
});
console.log(JSON.stringify({
  targetHash,
  firstAfterShift,
  hashResolved,
  indexResolved,
  overflowResolved,
  wrongSourceResolved
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20

        $result.targetHash | Should Not BeNullOrEmpty
        $result.firstAfterShift | Should Be 'session-1::question::1'
        $result.hashResolved | Should Be 'session-1::question::4'
        $result.indexResolved | Should Be 'session-1::question::4'
        $result.overflowResolved | Should Be 'session-1::question::4'
        $result.hashResolved | Should Not Be $result.firstAfterShift
        $result.wrongSourceResolved | Should BeNullOrEmpty
    }

    It 'persists V0.22 progress anchors only for deliberate question selections' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const progressMatch = html.match(/function getQuestionKey\(session, eventIndex\) \{[\s\S]*?\n    \}(?=\n\n    function eventMatchesView)/);
const selectMatch = html.match(/function setSelectedQuestionKey\(questionKey, options\) \{[\s\S]*?\n    \}(?=\n\n    function focusFirstQuestion)/);
if (!progressMatch || !selectMatch) {
  throw new Error("progress selection helpers not found");
}
let selectedQuestionKey = null;
let selectedQuestionKeyIsTemporary = false;
let viewerViewMode = "all";
let viewerSearchScope = "current";
let viewerSearchQuery = "needle";
let currentSourceId = "local-codex";
let selectedWorkspaceId = "workspace-current";
let selectedSessionKey = "session-1";
let CURRENT_DETAIL = {
  events: [
    { kind: "user", rawText: "First question" },
    { kind: "assistant_final", rawText: "answer" },
    { kind: "user", rawText: "Second question" }
  ]
};
let APP = {
  workspaces: [
    { id: "workspace-current", cwd: "/workspace-cwd", sessions: [{ key: "session-1", path: "/workspace-cwd/session-1.jsonl" }] }
  ]
};
const sessionProgressAnchors = new Map();
const MAX_PROGRESS_ANCHORS = 200;
let progressRestoreToken = 0;
const transcript = {
  getBoundingClientRect() { return { top: 10 }; }
};
function getCurrentSourceId() { return currentSourceId; }
function getSessionKey(session) { return session && (session.key || session.path || session.id || ""); }
function getSelectedSession() {
  const workspace = APP.workspaces.find(item => item.id === selectedWorkspaceId);
  return workspace ? workspace.sessions.find(item => getSessionKey(item) === selectedSessionKey) || null : null;
}
function getCurrentDetailEvents() { return CURRENT_DETAIL.events; }
function findQuestionElement(questionKey) {
  if (questionKey !== "session-1::question::2") return null;
  return { getBoundingClientRect() { return { top: 42 }; } };
}
let highlightCalls = 0;
function highlightCurrentQuestion() { highlightCalls += 1; }
eval(progressMatch[0] + "\n" + selectMatch[0]);
setSelectedQuestionKey("session-1::question::2", { scroll: false, persistAnchor: false, temporary: true });
const temporaryAnchor = getProgressAnchorForSession(getSelectedSession());
const temporaryFlag = selectedQuestionKeyIsTemporary;
setSelectedQuestionKey("session-1::question::2", { scroll: false });
const savedAnchor = getProgressAnchorForSession(getSelectedSession());
console.log(JSON.stringify({
  temporaryAnchor,
  temporaryFlag,
  savedAnchor,
  progressRestoreToken,
  selectedQuestionKeyIsTemporary,
  highlightCalls
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20

        $result.temporaryAnchor | Should BeNullOrEmpty
        $result.temporaryFlag | Should Be $true
        $result.savedAnchor.sourceId | Should Be 'local-codex'
        $result.savedAnchor.workspacePath | Should Be '/workspace-cwd'
        $result.savedAnchor.sessionKey | Should Be 'session-1'
        $result.savedAnchor.questionKey | Should Be 'session-1::question::2'
        $result.savedAnchor.questionIndex | Should Be 1
        $result.savedAnchor.questionTextHash | Should Not BeNullOrEmpty
        $result.savedAnchor.offsetFromQuestionTop | Should Be 32
        $result.progressRestoreToken | Should Be 1
        $result.selectedQuestionKeyIsTemporary | Should Be $false
        $result.highlightCalls | Should Be 2
    }

    It 'restores a captured V0.22 progress anchor after refresh through the explicit detail reload path' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function setRefreshButtonLoading\(button, isLoading, loadingText, idleText\) \{[\s\S]*?\n    \}(?=\n\n    function focusTranscriptForQuestionNavigation)/);
if (!match) {
  throw new Error("refresh helper not found");
}
eval(match[0]);

function getSessionKey(session) {
  return session.key || session.path || session.id || "";
}
function sessionSignature(session) {
  return [session.userCount || 0, session.assistantCount || 0].join(":");
}
function collectSessionMap(data) {
  const rows = new Map();
  (data.workspaces || []).forEach(workspace => {
    (workspace.sessions || []).forEach(session => rows.set(getSessionKey(session), { session, signature: sessionSignature(session) }));
  });
  return rows;
}
function collectWorkspaceSet(data) {
  return new Set((data.workspaces || []).map(workspace => workspace.cwd || "(未知工作目录)"));
}
function flattenSessions(data) {
  const rows = [];
  (data.workspaces || []).forEach(workspace => {
    (workspace.sessions || []).forEach(session => rows.push({ workspace: workspace.cwd, session }));
  });
  return rows;
}
function countUniqueWorkspaces(items) {
  return new Set(items.map(item => item.workspace || "(未知工作目录)")).size;
}
function formatGroupedChangeMessage(title, items, mapper) {
  return title + ":" + items.map(mapper).join("|");
}
function prepareData() {}
function updateStats() {}
function refreshFilterMenus() {}
function getCurrentSourceId() { return currentSourceId; }
function getSelectedSession() {
  const workspace = APP.workspaces.find(item => item.id === selectedWorkspaceId);
  return workspace ? workspace.sessions.find(item => getSessionKey(item) === selectedSessionKey) || null : null;
}
function detailMatchesSession(session, detail) {
  return !!session && !!detail && detail.path === session.path;
}
function focusTranscriptForQuestionNavigation() {
  focusCalls += 1;
  return true;
}
global.requestAnimationFrame = callback => {
  callback();
  return 1;
};

let progressRestoreToken = 0;
let currentSourceId = "local-codex";
let selectedWorkspaceId = "workspace-before";
let selectedSessionKey = "session-1";
let selectedQuestionKey = "session-1::question::2";
let CURRENT_DETAIL = { stale: true };
let APP = {
  workspaces: [
    { id: "workspace-before", cwd: "/workspace", sessions: [{ key: "session-1", path: "/workspace/session-1.jsonl", userCount: 1, assistantCount: 1 }] }
  ]
};
let sourceState = { selectedSourceId: "local-codex" };
function renderSourceSelect() {}
const sessionCache = {
  cleared: 0,
  clear() { this.cleared += 1; }
};
const captured = [];
const saved = [];
const restored = [];
function captureProgressAnchor(session) {
  captured.push(getSessionKey(session));
  return {
    sourceId: "local-codex",
    workspacePath: "/workspace",
    sessionKey: "session-1",
    questionKey: "session-1::question::2",
    questionIndex: 1,
    questionTextHash: "abc12345"
  };
}
function saveProgressAnchor(anchor) { saved.push(anchor); return true; }
function restoreProgressAnchor(anchor, options) { restored.push({ anchor, options }); return true; }
const refreshedData = {
  source: { id: "local-codex" },
  workspaces: [
    { id: "workspace-after", cwd: "/workspace", sessions: [{ key: "session-1", path: "/workspace/session-1.jsonl", userCount: 2, assistantCount: 2 }] }
  ]
};
const currentDetail = { path: "/workspace/session-1.jsonl", events: [{ kind: "user", rawText: "hello" }] };
const toasts = [];
global.fetch = async () => ({
  ok: true,
  json: async () => ({ ok: true, data: refreshedData, currentDetail, scannedCount: 1, parsedCount: 1, reusedCount: 0, elapsedMs: 800 })
});
function showToast(message, options) { toasts.push({ message, options }); }
function renderWorkspaceList(skipViewerSync) { renderWorkspaceListCalls.push(skipViewerSync); }
let loadSessionDetailCalls = 0;
async function loadSessionDetail(session) { loadSessionDetailCalls += 1; return { path: session.path }; }
function applyLoadedDetail(session, detail) { appliedDetails.push({ session, detail }); return true; }
function renderViewer() { renderViewerCalls += 1; }
const renderWorkspaceListCalls = [];
const appliedDetails = [];
let renderViewerCalls = 0;
let focusCalls = 0;
(async () => {
  await refreshIndex();
  console.log(JSON.stringify({
    captured,
    saved,
    restored,
    renderViewerCalls,
    loadSessionDetailCalls,
    appliedDetails,
    selectedWorkspaceId,
    selectedSessionKey,
    progressRestoreToken,
    focusCalls,
    toasts
  }));
})().catch(error => {
  console.error(error);
  process.exit(1);
});
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 30

        $result.captured[0] | Should Be 'session-1'
        $result.saved[0].questionKey | Should Be 'session-1::question::2'
        $result.restored[0].anchor.questionKey | Should Be 'session-1::question::2'
        $result.restored[0].options.behavior | Should Be 'auto'
        [int]$result.restored[0].options.token | Should BeGreaterThan 0
        $result.renderViewerCalls | Should Be 1
        $result.loadSessionDetailCalls | Should Be 0
        $result.appliedDetails[0].detail.path | Should Be '/workspace/session-1.jsonl'
        $result.selectedWorkspaceId | Should Be 'workspace-after'
        $result.selectedSessionKey | Should Be 'session-1'
        $result.focusCalls | Should Be 0
    }

    It 'retries V0.22 progress anchor scrolling for a few frames when refresh layout is still settling' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const progressMatch = html.match(/function getQuestionKey\(session, eventIndex\) \{[\s\S]*?\n    \}(?=\n\n    function eventMatchesView)/);
if (!progressMatch) {
  throw new Error("progress helpers not found");
}
let selectedQuestionKey = null;
let selectedQuestionKeyIsTemporary = false;
let viewerViewMode = "all";
let viewerSearchScope = "current";
let viewerSearchQuery = "";
let currentSourceId = "local-codex";
let selectedWorkspaceId = "workspace-current";
let selectedSessionKey = "session-1";
let CURRENT_DETAIL = {
  events: [
    { kind: "user", rawText: "First question" },
    { kind: "assistant_final", rawText: "answer" },
    { kind: "user", rawText: "Second question" }
  ]
};
let APP = {
  workspaces: [
    { id: "workspace-current", cwd: "/workspace", sessions: [{ key: "session-1", path: "/workspace/session-1.jsonl" }] }
  ]
};
const sessionProgressAnchors = new Map();
const MAX_PROGRESS_ANCHORS = 200;
let progressRestoreToken = 1;
const transcript = { getBoundingClientRect() { return { top: 0 }; } };
const rafCallbacks = [];
function requestAnimationFrame(callback) { rafCallbacks.push(callback); return rafCallbacks.length; }
function getCurrentSourceId() { return currentSourceId; }
function getSessionKey(session) { return session && (session.key || session.path || session.id || ""); }
function getSelectedSession() {
  const workspace = APP.workspaces.find(item => item.id === selectedWorkspaceId);
  return workspace ? workspace.sessions.find(item => getSessionKey(item) === selectedSessionKey) || null : null;
}
function getCurrentDetailEvents() { return CURRENT_DETAIL.events; }
function findQuestionElement() {
  return {
    getBoundingClientRect() {
      return { top: scrollCalls >= 3 ? 16 : 120 };
    }
  };
}
let highlightCalls = 0;
function highlightCurrentQuestion() { highlightCalls += 1; }
let focusCalls = 0;
function focusTranscriptForQuestionNavigation() { focusCalls += 1; }
let scrollCalls = 0;
function scrollToQuestion(questionKey, behavior) {
  scrollCalls += 1;
  return scrollCalls >= 3;
}
function setSelectedQuestionKey(questionKey, options) {
  selectedQuestionKey = questionKey || null;
  selectedQuestionKeyIsTemporary = !!(options && options.temporary);
  highlightCurrentQuestion();
}
eval(progressMatch[0]);
const anchor = {
  sourceId: "local-codex",
  workspacePath: "/workspace",
  sessionKey: "session-1",
  questionKey: "session-1::question::2",
  questionIndex: 1,
  questionTextHash: hashQuestionText("Second question")
};
const restored = restoreProgressAnchor(anchor, { token: 1, behavior: "auto" });
let frames = 0;
while (rafCallbacks.length && frames < 8) {
  const callback = rafCallbacks.shift();
  callback();
  frames += 1;
}
console.log(JSON.stringify({ restored, frames, scrollCalls, focusCalls, selectedQuestionKey, selectedQuestionKeyIsTemporary }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20

        $result.restored | Should Be $true
        [int]$result.scrollCalls | Should BeGreaterThan 2
        $result.focusCalls | Should Be 1
        $result.selectedQuestionKey | Should Be 'session-1::question::2'
        $result.selectedQuestionKeyIsTemporary | Should Be $false
    }

    It 'stabilizes bottom scroll room before a single monotonic question scroll' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function findQuestionElement\(questionKey\) \{[\s\S]*?\n    \}(?=\n\n    function highlightCurrentQuestion)/);
if (!match) {
  throw new Error("question scroll helpers not found");
}
const styleCalls = [];
const element = {
  dataset: { questionKey: "q2" },
  offsetTop: 500,
  offsetHeight: 120,
  scrollIntoView(options) {
    global.__scrollOptions = options;
  }
};
let transcript = {
  clientHeight: 600,
  scrollHeight: 700,
  style: {
    setProperty(name, value) {
      styleCalls.push({ name, value });
    }
  },
  scrollTo(options) {
    global.__scrollToOptions = options;
  },
  querySelectorAll() {
    return [element];
  }
};
eval(match[0]);
const ok = scrollToQuestion("q2", "auto");
console.log(JSON.stringify({ ok, styleCalls, scrollOptions: global.__scrollOptions, scrollToOptions: global.__scrollToOptions }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10
        $calls = @($result.styleCalls)
        $lastCall = $calls[$calls.Count - 1]

        $result.ok | Should Be $true
        $calls.Count | Should Be 1
        $calls[0].name | Should Be '--transcript-scroll-spacer'
        $calls[0].value | Should Be '400px'
        $lastCall.name | Should Be '--transcript-scroll-spacer'
        $lastCall.value | Should Be '400px'
        $result.scrollToOptions.top | Should Be 484
        $result.scrollToOptions.behavior | Should Be 'auto'
        $result.scrollOptions | Should BeNullOrEmpty
        $html | Should Match 'padding: 20px 22px calc\(38px \+ var\(--transcript-scroll-spacer, 0px\)\)'
        $html | Should Match 'activeQuestionScrollAnimation'
        $html | Should Match 'cancelAnimationFrame'
    }

    It 'compresses viewer header metadata and right-aligns status tags' {
        $html | Should Match '<div class="viewer-head-row">'
        $html | Should Match '创建：'' \+ escapeHtml\(session\.createdLocal\)'
        $html | Should Match '用户 '' \+ session\.userCount \+ '' · 回答 '' \+ session\.assistantCount'
        $html | Should Not Match 'viewer-meta">更新：'
        $html | Should Not Match '· Assistant '' \+ session\.assistantCount'
        $html | Should Match '<div class="viewer-tags">'
        $html | Should Not Match '<div class="viewer-status-row">'
        $html | Should Match '\.viewer-head-row \{[\s\S]*?display: flex'
        $html | Should Match '\.viewer-head-row \{[\s\S]*?justify-content: space-between'
    }

    It 'uses complete non-blocking toast feedback for copied path and session commands' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/async function copyText\(value\) \{[\s\S]*?\n    \}(?=\n\n    function isExplicitQuoteBlock)/);
if (!match) {
  throw new Error("copy helpers not found");
}

const toastState = { textContent: "", className: "toast", hidden: true };
global.document = {
  getElementById: id => id === "toast" ? toastState : null,
  createElement: () => ({ value: "", select() {}, remove() {} }),
  body: { appendChild() {} },
  execCommand: () => true
};
global.navigator = {};
global.setTimeout = (fn, ms) => {
  global.__toastDelay = ms;
  global.__toastCallback = fn;
  return 9;
};
global.clearTimeout = () => {};

const copied = [];
let APP = { workspaces: [{ id: "workspace-1", cwd: "M:\\完整目录\\很长很长很长很长很长很长", sessions: [] }] };
let selectedWorkspaceId = "workspace-1";
let selectedSessionKey = "session-1";
function getSelectedSession() {
  return {
    id: "session-id-0001",
    path: "C:\\Users\\DemoUser\\.codex\\sessions\\2026\\05\\04\\rollout-complete-path.jsonl"
  };
}

eval(match[0]);
copyText = async value => {
  copied.push(value);
};

(async () => {
  await copyCurrentPath();
  const pathToast = toastState.textContent;
  await copyResumeCommand();
  const sessionToast = toastState.textContent;
  console.log(JSON.stringify({
    copied,
    pathToast,
    sessionToast,
    delay: global.__toastDelay,
    className: toastState.className,
    hidden: toastState.hidden
  }));
})().catch(error => {
  console.error(error);
  process.exit(1);
});
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        @($result.copied).Count | Should Be 2
        $result.copied[0] | Should Be 'C:\Users\DemoUser\.codex\sessions\2026\05\04\rollout-complete-path.jsonl'
        $result.copied[1] | Should Match '^codex resume session-id-0001 -C '
        $result.pathToast | Should Match '已复制路径：'
        $result.pathToast | Should Match ([regex]::Escape($result.copied[0]))
        $result.pathToast | Should Not Match '\.\.\.'
        $result.sessionToast | Should Match '已复制 SESSION：'
        $result.sessionToast | Should Match ([regex]::Escape($result.copied[1]))
        $result.sessionToast | Should Not Match '\.\.\.'
        $result.className | Should Match 'toast--visible'
        $result.hidden | Should Be $false
        $result.delay | Should Be 2600
        $html | Should Match 'onclick="copyCurrentPath\(\)"'
        $html | Should Match 'title="复制当前会话路径">路径</button>'
        $html | Should Match '复制 codex resume 命令'
        $html | Should Match 'onclick="copyResumeCommand\(\)"'
        $html | Should Not Match '>复制路径</button>'
        $html | Should Not Match '>复制 SESSION</button>'
        $html | Should Match '\.toast \{[^}]*white-space: pre-wrap'
        $html | Should Match '\.toast \{[^}]*overflow: auto'
        $html | Should Not Match '\.toast \{[^}]*text-overflow: ellipsis'
    }

    It 'includes system events in all view but not question-only view' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function eventMatchesView\(event\) \{[\s\S]*?\n    \}(?=\n\n    function eventMatchesSearch)/);
if (!match) {
  throw new Error("eventMatchesView helper not found");
}
let viewerViewMode = "all";
eval(match[0]);
const systemEvent = { kind: "system" };
const userEvent = { kind: "user" };
const assistantEvent = { kind: "assistant_final" };
const toolEvent = { kind: "tool" };
const result = {};
viewerViewMode = "all";
result.all = eventMatchesView(systemEvent);
viewerViewMode = "questions";
result.questionSystem = eventMatchesView(systemEvent);
result.questionUser = eventMatchesView(userEvent);
result.questionAssistant = eventMatchesView(assistantEvent);
result.questionTool = eventMatchesView(toolEvent);
console.log(JSON.stringify(result));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.all | Should Be $true
        $result.questionSystem | Should Be $false
        $result.questionUser | Should Be $true
        $result.questionAssistant | Should Be $false
        $result.questionTool | Should Be $false
    }

    It 'exports markdown from normalized detail events including tool summaries' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function buildMarkdown\(detail\) \{[\s\S]*?\n    \}(?=\n\n    function exportSelectedMarkdown)/);
if (!match) {
  throw new Error("buildMarkdown helper not found");
}
eval(match[0]);
const markdown = buildMarkdown({
  title: "示例会话",
  path: "workspace/session.jsonl",
  createdLocal: "2026-04-25 12:00:00",
  updatedLocal: "2026-04-25 12:01:00",
  events: [
    { kind: "user", timestampLocal: "2026-04-25 12:00:00", rawText: "你好" },
    { kind: "assistant_commentary", timestampLocal: "2026-04-25 12:00:01", rawText: "推理中" },
    { kind: "assistant_final", timestampLocal: "2026-04-25 12:00:02", rawText: "最终答案" },
    { kind: "tool", timestampLocal: "2026-04-25 12:00:03", summary: "exec_command: exit=0", rawText: "tool raw output" },
    { kind: "system", timestampLocal: "2026-04-25 12:00:04", rawText: "不要导出" }
  ]
});
console.log(JSON.stringify({ markdown }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.markdown | Should Match '^# 示例会话'
        $result.markdown | Should Match '## 用户 \(2026-04-25 12:00:00\)'
        $result.markdown | Should Match '你好'
        $result.markdown | Should Match '## 过程 \(2026-04-25 12:00:01\)'
        $result.markdown | Should Match '推理中'
        $result.markdown | Should Match '## Assistant \(2026-04-25 12:00:02\)'
        $result.markdown | Should Match '最终答案'
        $result.markdown | Should Match '## 工具 \(2026-04-25 12:00:03\)'
        $result.markdown | Should Match 'exec_command: exit=0'
        $result.markdown | Should Match 'tool raw output'
        $result.markdown | Should Match '## 系统 \(2026-04-25 12:00:04\)'
        $result.markdown | Should Match '不要导出'
    }

    It 'renders V0.22 refresh controls with compact full rebuild and global sidebar toggle buttons' {
        $html | Should Match 'id="refreshCurrentButton"'
        $html | Should Match 'onclick="refreshCurrentSession\(\)"'
        $html | Should Match 'id="refreshButton"'
        $html | Should Match 'onclick="refreshIndex\(\)"'
        $html | Should Match 'id="rebuildButton"'
        $html | Should Match 'onclick="rebuildIndex\(\)"'
        $html | Should Match '快刷'
        $html | Should Match '<button type="button" id="rebuildButton" class="refresh-btn" onclick="rebuildIndex\(\)" title="重新扫描和解析全部聊天记录，耗时可能较长" aria-label="全量重建">全量</button>'
        $html | Should Match '<button type="button" id="globalSidebarToggleButton" class="refresh-btn sidebar-toggle-btn" title="一键收起目录和标题" aria-label="一键收起目录和标题">收起</button>'
        $html | Should Not Match '>全量重建</button>'
        $rebuildIndex = $html.IndexOf('id="rebuildButton"')
        $globalToggleIndex = $html.IndexOf('id="globalSidebarToggleButton"')
        $rebuildIndex | Should BeGreaterThan -1
        $globalToggleIndex | Should BeGreaterThan $rebuildIndex
        $html | Should Match 'async function runRefreshRequest\(mode, options\)'
        $html | Should Match 'async function refreshCurrentSession\(\)'
        $html | Should Match 'async function rebuildIndex\(\)'
        $html | Should Match 'function toggleAllSidebars\(\)'
        $html | Should Match "/api/refresh-current"
        $html | Should Match "/api/rebuild"
        $html | Should Not Match 'alert\(message\);'
    }

    It 'keeps the V0.22 mobile header brand row from shrinking beside top action buttons' {
        $html | Should Match '@media \(max-width: 980px\) \{[\s\S]*?\.header-main \{[\s\S]*?flex-basis: 100%'
        $html | Should Match '@media \(max-width: 980px\) \{[\s\S]*?\.header-main \{[\s\S]*?min-width: 100%'
    }

    It 'renders V0.09 chat reply controls with compact quick refresh label and inline composer actions' {
        $html | Should Match 'id="replyComposer"'
        $html | Should Match 'id="replyInput"'
        $html | Should Match 'id="clearReplyButton"'
        $html | Should Match 'id="copyReplyCommandButton"'
        $html | Should Match 'quick-refresh-btn'
        $html | Should Match '>快刷<'
        $html | Should Match 'SESSION'
        $html | Should Match 'id="refreshCurrentButton" class="quick-refresh-btn"'
        $html | Should Match 'reply-composer-actions'
        $html | Should Match 'clearReplyDraft\(\)'
        $html | Should Match 'copyReplyCommand\(\)'
        $html | Should Match 'MAX_REPLY_LINES = 20'
    }

    It 'keeps reply composer actions from taking a full right-side text column' {
        $buildSource = Get-Content -LiteralPath $buildScript -Raw

        $html | Should Match '<span class="version-badge">V0\.26</span>'
        $html | Should Not Match '<span class="version-badge">V0\.12\.1</span>'
        $buildSource | Should Match '\$builderVersion = "V0\.26"'
        $buildSource | Should Not Match '\$builderVersion = "V0\.12\.1"'

        $html | Should Not Match 'padding:\s*12px\s+150px\s+52px\s+14px'
        $html | Should Match '\.reply-composer textarea \{[\s\S]*?padding: 12px 16px 58px 14px'
        $html | Should Match '\.reply-composer-actions \{[\s\S]*?max-width: calc\(100% - 68px\)'
        $html | Should Match '\.reply-composer-actions \{[\s\S]*?flex-wrap: wrap'
        $html | Should Match '\.reply-composer-actions \{[\s\S]*?justify-content: flex-end'
        $html | Should Match '\.reply-composer-actions \{[\s\S]*?gap: 6px'
    }

    It 'uses compact top stats labels and removes visible generated-time prefix in V0.22' {
        $html | Should Match 'id="statSessions">会话：'
        $html | Should Match 'id="statWorkspaces">目录：'
        $html | Should Match 'id="statArchived">归档：'
        $html | Should Match 'id="statImages">含图：'
        $html | Should Match 'id="statGenerated"[^>]*title="生成时间：'
        $html | Should Match 'id="statGenerated"[^>]*aria-label="生成时间：'
        $html | Should Not Match 'id="statGenerated"[^>]*>时间：'
        $html | Should Match 'generated\.textContent = APP\.generatedAt \|\| '''''
        $html | Should Match 'generated\.title = ''生成时间：'' \+ \(APP\.generatedAt \|\| ''''\)'
        $html | Should Not Match '工作目录：'
        $html | Should Not Match '含图片引用：'
    }

    It 'renders V0.16 reply input attributes and scheduled composer updates' {
        $html | Should Match '<textarea id="replyInput"[^>]*spellcheck="false"'
        $html | Should Match '<textarea id="replyInput"[^>]*autocomplete="off"'
        $html | Should Match '<textarea id="replyInput"[^>]*autocorrect="off"'
        $html | Should Match '<textarea id="replyInput"[^>]*autocapitalize="off"'
        $html | Should Match 'function saveReplyDraftValueOnly\(\)'
        $html | Should Match 'function scheduleReplyComposerUpdate\(\)'
        $html | Should Match 'requestAnimationFrame\(callback\)'
        $html | Should Match 'function canBuildReplyResumeCommand\(session, replyText\)'
        $html | Should Match 'const canSend = canBuildReplyResumeCommand\(session, text\)'
        $html | Should Match 'async function copyReplyCommand\(\)[\s\S]*?const command = buildReplyResumeCommand\(session, reply\)'
        $html | Should Match 'replyInput\.addEventListener\(''input'', \(\) => \{[\s\S]*?persistReplyDraft\(\);[\s\S]*?\}\);'
        $html | Should Not Match 'replyInput\.addEventListener\(''input'', \(\) => \{[\s\S]*?updateReplyComposerState\(\)'
        $html | Should Match 'replyInput\.addEventListener\(''compositionend'', \(\) => \{[\s\S]*?replyInputIsComposing = false;[\s\S]*?scheduleReplyComposerUpdate\(\)'
    }

    It 'limits reply composer height to 20 lines and enables internal scrolling for overflow' {
        $html | Should Match '\.reply-composer textarea \{[\s\S]*?overflow-y: auto'
        $html | Should Match '\.reply-composer textarea \{[\s\S]*?overflow-x: hidden'
        $html | Should Match 'replyInput\.style\.overflowY = scrollHeight > metrics\.maxHeight \? ''auto'' : ''hidden'''
        $html | Should Match 'lineHeight \* MAX_REPLY_LINES'
        $html | Should Match 'function getReplyInputMetrics\(\)'
        $html | Should Match 'let replyInputMetrics = null'
        $html | Should Match 'function resetReplyInputMetrics\(\)'
    }

    It 'supports k and K as transcript-level quick refresh shortcuts' {
        $html | Should Match 'event\.key && event\.key\.toLowerCase\(\) === ''k'''
        $html | Should Match 'void refreshCurrentSession\(\)'
        $html | Should Match 'event\.target\.closest\('
        $html | Should Match 'button, a, input, textarea, select'
    }

    It 'renders V0.16 source selector before refresh and carries sourceId through loading, search, and refresh requests' {
        $html | Should Match '<label class="source-selector"'
        $html | Should Match '<select id="sourceSelect"'
        $html | Should Match '<button type="button" id="refreshButton"'
        $html.IndexOf('<select id="sourceSelect"') -lt $html.IndexOf('<button type="button" id="refreshButton"') | Should Be $true
        $html | Should Match 'const SOURCES_API_URL = ''/api/sources'''
        $html | Should Match 'let currentSourceId = ''local-codex'''
        $html | Should Match 'async function loadSources\(\)'
        $html | Should Match 'async function switchSource\(sourceId\)'
        $html | Should Match 'function getCurrentSourceId\(\)'
        $html | Should Match 'function buildSourceUrl\(url\)'
        $html | Should Match 'fetch\(buildSourceUrl\(INDEX_URL\), \{ cache: ''no-store'' \}\)'
        $html | Should Match 'SEARCH_API_URL \+ ''\?sourceId='' \+ encodeURIComponent\(getCurrentSourceId\(\)\) \+ ''&q='''
        $html | Should Match 'bodyWithSourceId\(settings\.body\)'
        $html | Should Match 'sourceSelect\.addEventListener\(''change'''
    }

    It 'disables misleading SESSION and reply send controls for external sources while preserving path and quick refresh' {
        $html | Should Match 'function isExternalSource\(\)'
        $html | Should Match '外部来源不支持复制 SESSION'
        $html | Should Match '外部来源不支持生成发送命令'
        $html | Should Match 'copyResumeCommand\(\)[\s\S]*?typeof isExternalSource === ''function'' && isExternalSource\(\)'
        $html | Should Match 'copyReplyCommand\(\)[\s\S]*?typeof isExternalSource === ''function'' && isExternalSource\(\)'
        $html | Should Match 'renderReaderToolbarActions\(session\)[\s\S]*?SESSION'
        $html | Should Match 'renderReaderToolbarActions\(session\)[\s\S]*?快刷'
        $html | Should Match 'renderReaderToolbarActions\(session\)[\s\S]*?路径'
        $html | Should Match 'canBuildReplyResumeCommand\(session, replyText\)[\s\S]*?typeof isExternalSource === ''function'' && isExternalSource\(\)'
    }

    It 'adds sourceId to note targets so remarks do not leak across sources' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function getSessionKey\(session\) \{[\s\S]*?\n    \}(?=\n\n    function getNote)/);
if (!match) {
  throw new Error("note key helpers not found");
}
let currentSourceId = "external-alpha-test";
function getCurrentSourceId() { return currentSourceId; }
eval(match[0]);
const workspace = { cwd: "M:/WORK/demo" };
const group = { title: "同一个问题", sessions: [{ id: "s1", path: "M:/WORK/demo/a.jsonl", key: "k-a" }] };
const session = { id: "session-id", key: "session-key", path: "M:/WORK/demo/a.jsonl", title: "同一个问题" };
const groupTarget = createGroupNoteTarget(workspace, group);
const sessionTarget = createSessionNoteTarget(workspace, group, session);
console.log(JSON.stringify({ groupTarget, sessionTarget }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20

        $result.groupTarget.sourceId | Should Be 'external-alpha-test'
        $result.sessionTarget.sourceId | Should Be 'external-alpha-test'
        $result.groupTarget.key | Should Match '^group:external-alpha-test:'
        $result.sessionTarget.key | Should Match '^session:external-alpha-test:'
    }

    It 'builds a reply resume command from the current session path, session id, and reply text' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function buildResumeCommand\(session\) \{[\s\S]*?function buildMarkdown/);
if (!match) {
  throw new Error("reply command helpers not found");
}
const source = match[0].replace(/function buildMarkdown[\s\S]*/, "");
eval(source);

global.APP = {
  workspaces: [
    {
      id: "ws-1",
      cwd: "M:\\Demo Workspace\\Codex\\示例项目_无附件"
    }
  ]
};
global.selectedWorkspaceId = "ws-1";

const session = {
  id: "019e003a-0448-7963-b92a-7c3aba7499c9",
  cwd: "M:\\Demo Workspace\\Codex\\示例项目_无附件",
  path: "C:\\Users\\DemoUser\\.codex\\sessions\\2026\\05\\07\\rollout.jsonl"
};
const command = buildReplyResumeCommand(session, "回复");
console.log(JSON.stringify({ command }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json

        $result.command | Should Be 'codex -C "M:\Demo Workspace\Codex\示例项目_无附件" resume 019e003a-0448-7963-b92a-7c3aba7499c9 "回复"'
    }

    It 'escapes reply command text safely for quotes and multiline input' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function buildResumeCommand\(session\) \{[\s\S]*?function buildMarkdown/);
if (!match) {
  throw new Error("reply command helpers not found");
}
const source = match[0].replace(/function buildMarkdown[\s\S]*/, "");
eval(source);

global.APP = {
  workspaces: [
    {
      id: "ws-1",
      cwd: "C:\\Demo"
    }
  ]
};
global.selectedWorkspaceId = "ws-1";

const session = {
  cwd: "M:\\Demo Workspace\\Codex\\示例项目_无附件",
  path: "C:\\Users\\DemoUser\\.codex\\sessions\\2026\\05\\07\\rollout.jsonl",
  id: "019e003a-0448-7963-b92a-7c3aba7499c9"
};
const command = buildReplyResumeCommand(session, "第一行\"quoted\"\n第二行");
console.log(JSON.stringify({ command }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json

        $result.command | Should Match 'codex -C "C:\\Demo" resume 019e003a-0448-7963-b92a-7c3aba7499c9 '
        $result.command | Should Match 'quoted'
        $result.command | Should Match '第二行'
    }

    It 'builds V0.17 local Claude PowerShell resume and print commands with single-quote escaping' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function buildResumeCommand\(session\) \{[\s\S]*?function buildMarkdown/);
if (!match) {
  throw new Error("reply command helpers not found");
}
const source = match[0].replace(/function buildMarkdown[\s\S]*/, "");
function getCurrentSource() {
  return { id: "local-claude", label: "本机 Claude", type: "local-claude" };
}
function isExternalSource() {
  return false;
}
eval(source);

global.APP = {
  workspaces: [
    {
      id: "ws-1",
      cwd: "M:\\Project O'Brien"
    }
  ]
};
global.selectedWorkspaceId = "ws-1";

const session = {
  id: "019e003a-0448-7963-b92a-7c3aba7499c9",
  cwd: "M:\\Project O'Brien",
  path: "C:\\Users\\DemoUser\\.claude\\projects\\demo\\019e003a-0448-7963-b92a-7c3aba7499c9.jsonl"
};
const resume = buildResumeCommand(session);
const reply = buildReplyResumeCommand(session, "it'll work\n第二行");
console.log(JSON.stringify({ resume, reply, canSend: canBuildReplyResumeCommand(session, "hello") }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json

        $result.resume | Should Be "Set-Location -LiteralPath 'M:\Project O''Brien'; claude --resume '019e003a-0448-7963-b92a-7c3aba7499c9'"
        $result.reply | Should Be "Set-Location -LiteralPath 'M:\Project O''Brien'; claude -p --resume '019e003a-0448-7963-b92a-7c3aba7499c9' 'it''ll work`n第二行'"
        $result.canSend | Should Be $true
    }

    It 'handles Enter, Shift+Enter, clear, and draft persistence in the reply composer' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const scriptTag = '<script>';
const firstScript = html.indexOf(scriptTag);
const secondScript = html.indexOf(scriptTag, firstScript + scriptTag.length);
const start = secondScript + scriptTag.length;
const closeTag = '</script>';
const end = html.indexOf(closeTag, start);
if (start < 0 || end < 0 || secondScript < 0) {
  throw new Error("app script block not found");
}
const script = html.slice(start, end);
const MAX_REPLY_LINES = 20;

global.navigator = {
  clipboard: {
    writeText: async text => {
      global.__copiedText = text;
    }
  }
};
global.requestAnimationFrame = callback => {
  callback();
  return 1;
};
global.cancelAnimationFrame = () => {};
global.setTimeout = callback => {
  callback();
  return 1;
};
global.clearTimeout = () => {};

function createNode(id) {
  return {
    id,
    value: "",
    innerHTML: "",
    textContent: "",
    hidden: false,
    disabled: false,
    open: false,
    dataset: {},
    style: {
      setProperty(name, value) { this[name] = value; },
      removeProperty(name) { delete this[name]; }
    },
    classList: {
      add() {},
      remove() {},
      toggle() {},
      contains() { return false; }
    },
    focus() {
      global.document.activeElement = this;
    },
    blur() {},
    addEventListener(type, handler) {
      this._handlers = this._handlers || {};
      this._handlers[type] = handler;
    },
    dispatch(type, event) {
      if (this._handlers && this._handlers[type]) this._handlers[type](event);
    },
    setAttribute(name, value) {
      this[name] = value;
    },
    removeAttribute(name) {
      delete this[name];
    },
    querySelector() { return null; },
    querySelectorAll() { return []; },
    closest() { return null; },
    appendChild() {},
    scrollTo() {},
    contains(node) { return node === this; }
  };
}

const ids = [
  "workspaceFilter","sessionFilter","viewerSearch","workspaceList","sessionList","viewerHead","transcript","workspaceFilterInput","sessionFilterInput","viewerSearchInput",
  "viewerToolbar","viewerToolbarActions","questionPrev","questionNext","workspaceProviderFilter","workspaceSourceFilter",
  "workspaceSortField","workspaceSortDirection","sessionSortField","sessionSortDirection","toast","replyComposer",
  "replyInput","clearReplyButton","copyReplyCommandButton"
];
const nodes = Object.fromEntries(ids.map(id => [id, createNode(id)]));
nodes.workspaceSortField.value = "path";
nodes.workspaceSortDirection.value = "asc";
nodes.sessionSortField.value = "updated";
nodes.sessionSortDirection.value = "desc";
nodes.replyInput.value = "";
nodes.replyInput.scrollHeight = 48;

global.document = {
  activeElement: null,
  body: createNode("body"),
  getElementById(id) {
    return nodes[id] || null;
  },
  addEventListener() {},
  querySelectorAll() { return []; },
  createElement() { return createNode("created"); }
};
global.localStorage = {
  getItem() { return null; },
  setItem() {},
  removeItem() {}
};

eval(script);

APP = {
  workspaces: [
    {
      id: "ws-1",
      cwd: "M:\\Demo Workspace\\Codex\\示例项目_无附件",
      sessions: [
        {
          key: "session-1",
          id: "019e003a-0448-7963-b92a-7c3aba7499c9",
          cwd: "M:\\Demo Workspace\\Codex\\示例项目_无附件",
          path: "C:\\Users\\DemoUser\\.codex\\sessions\\2026\\05\\07\\rollout.jsonl",
          title: "Session 1",
          userCount: 1,
          assistantCount: 1
        }
      ]
    }
  ]
};
selectedWorkspaceId = "ws-1";
selectedSessionKey = "session-1";

const toasts = [];
showToast = (message, options) => {
  toasts.push({ message, options });
};
copyText = async text => {
  global.__copiedText = text;
};
const originalCopyReplyCommand = copyReplyCommand;
copyReplyCommand = (...args) => {
  global.__copyPromise = originalCopyReplyCommand(...args);
  return global.__copyPromise;
};

syncReplyComposer();
nodes.replyInput.value = "第一行";
persistReplyDraft();

const shiftEnter = {
  key: "Enter",
  shiftKey: true,
  isComposing: false,
  preventDefaultCalled: false,
  preventDefault() { this.preventDefaultCalled = true; }
};
nodes.replyInput.dispatch("keydown", shiftEnter);

const copiedBefore = global.__copiedText || "";
const sendEnter = {
  key: "Enter",
  shiftKey: false,
  isComposing: false,
  preventDefaultCalled: false,
  preventDefault() { this.preventDefaultCalled = true; }
};
Promise.resolve()
  .then(() => nodes.replyInput.dispatch("keydown", sendEnter))
  .then(() => global.__copyPromise || Promise.resolve())
  .then(() => {
    if (!global.__copiedText) {
      return copyReplyCommand();
    }
    return Promise.resolve();
  })
  .then(() => {
    const copiedAfter = global.__copiedText || "";
    clearReplyDraft();
    const clearedValue = nodes.replyInput.value;
    nodes.replyInput.value = "草稿A";
    persistReplyDraft();
    selectedSessionKey = "session-2";
    APP.workspaces[0].sessions.push({
      key: "session-2",
      id: "019e003a-0448-7963-b92a-7c3aba7499d0",
      cwd: "M:\\Demo Workspace\\Codex\\示例项目_无附件",
      path: "C:\\Users\\DemoUser\\.codex\\sessions\\2026\\05\\07\\rollout-2.jsonl",
      title: "Session 2",
      userCount: 1,
      assistantCount: 1
    });
    syncReplyComposer();
    nodes.replyInput.value = "草稿B";
    persistReplyDraft();
    selectedSessionKey = "session-1";
    syncReplyComposer();
    const restored = nodes.replyInput.value;
    console.log(JSON.stringify({
      copiedBefore,
      copiedAfter,
      shiftPrevented: shiftEnter.preventDefaultCalled,
      sendPrevented: sendEnter.preventDefaultCalled,
      clearedValue,
      restored,
      composerMaxLines: MAX_REPLY_LINES
    }));
  })
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
'@
        $result = node -e $node $outputPath | ConvertFrom-Json

        $result.shiftPrevented | Should Be $false
        $result.sendPrevented | Should Be $true
        $result.clearedValue | Should Be ''
        $result.restored | Should Be '草稿A'
        $result.composerMaxLines | Should Be 20
    }

    It 'coalesces reply input updates and defers command building until copy' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function escapePowerShellDoubleQuoted\(value\) \{[\s\S]*?\n    \}(?=\n\n    async function copyResumeCommand)/);
if (!match) {
  throw new Error("reply composer helpers not found");
}

let builtReplyCommandCalls = 0;
let copiedText = "";
let rafQueue = [];

global.requestAnimationFrame = callback => {
  rafQueue.push(callback);
  return rafQueue.length;
};
global.cancelAnimationFrame = () => {};
global.window = {
  getComputedStyle() {
    return {
      lineHeight: "26px",
      borderTopWidth: "1px",
      borderBottomWidth: "1px",
      paddingTop: "12px",
      paddingBottom: "12px"
    };
  }
};

const MAX_REPLY_LINES = 20;
const APP = { workspaces: [{ id: "ws-1", cwd: "C:\\Demo" }] };
let selectedWorkspaceId = "ws-1";
let selectedSessionKey = "session-1";
let replyInputIsComposing = false;
let replyComposerUpdateFrame = 0;
let replyInputMetrics = null;
const replyDrafts = new Map();

const replyInput = {
  value: "",
  scrollHeight: 72,
  style: {},
  focus() {}
};
const replyComposer = {
  classList: {
    add(name) { this[name] = true; },
    remove(name) { this[name] = false; }
  }
};
const clearReplyButton = {};
const copyReplyCommandButton = {};

function getSessionKey(session) {
  return session && (session.key || session.path || session.id || "");
}
function getSelectedSession() {
  return {
    key: selectedSessionKey,
    id: "019e003a-0448-7963-b92a-7c3aba7499c9",
    cwd: "C:\\Demo",
    path: "C:\\Users\\DemoUser\\.codex\\sessions\\2026\\05\\07\\rollout.jsonl"
  };
}
function showToast() {}
async function copyText(text) {
  copiedText = text;
}

eval(match[0].replace(
  "function buildReplyResumeCommand(session, replyText) {",
  "function buildReplyResumeCommand(session, replyText) { builtReplyCommandCalls += 1;"
));

replyInput.value = "第一";
persistReplyDraft();
replyInput.value = "第一行";
persistReplyDraft();
replyInput.value = "第一行继续";
persistReplyDraft();
const queuedAfterInputs = rafQueue.length;
const builtBeforeFlush = builtReplyCommandCalls;
while (rafQueue.length) {
  const callbacks = rafQueue;
  rafQueue = [];
  callbacks.forEach(callback => callback());
}
const builtAfterFlush = builtReplyCommandCalls;
const sendEnabledAfterFlush = copyReplyCommandButton.disabled === false;

replyInputIsComposing = true;
replyInput.value = "中文组合中";
persistReplyDraft();
persistReplyDraft();
const queuedDuringComposition = rafQueue.length;
replyInputIsComposing = false;
scheduleReplyComposerUpdate();
const queuedAfterComposition = rafQueue.length;
while (rafQueue.length) {
  const callbacks = rafQueue;
  rafQueue = [];
  callbacks.forEach(callback => callback());
}

copyReplyCommand()
  .then(() => {
    console.log(JSON.stringify({
      queuedAfterInputs,
      builtBeforeFlush,
      builtAfterFlush,
      sendEnabledAfterFlush,
      queuedDuringComposition,
      queuedAfterComposition,
      builtAfterCopy: builtReplyCommandCalls,
      copiedText,
      draft: replyDrafts.get("session-1")
    }));
  })
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
'@
        $result = node -e $node $outputPath | ConvertFrom-Json

        $result.queuedAfterInputs | Should Be 1
        $result.builtBeforeFlush | Should Be 0
        $result.builtAfterFlush | Should Be 0
        $result.sendEnabledAfterFlush | Should Be $true
        $result.queuedDuringComposition | Should Be 0
        $result.queuedAfterComposition | Should Be 1
        $result.builtAfterCopy | Should Be 1
        $result.copiedText | Should Match '^codex -C "C:\\Demo" resume '
        $result.draft | Should Be '中文组合中'
    }

    It 'refreshes through a single explicit detail reload path' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function setRefreshButtonLoading\(button, isLoading, loadingText, idleText\) \{[\s\S]*?\n    \}(?=\n\n    function focusTranscriptForQuestionNavigation)/);
if (!match) {
  throw new Error("refreshIndex helper not found");
}
eval(match[0]);

function getSessionKey(session) {
  return session.key || session.path || session.id || "";
}

function sessionSignature(session) {
  return [session.userCount || 0, session.assistantCount || 0].join(":");
}

function collectSessionMap(data) {
  const rows = new Map();
  (data.workspaces || []).forEach(workspace => {
    (workspace.sessions || []).forEach(session => {
      rows.set(getSessionKey(session), { session, signature: sessionSignature(session) });
    });
  });
  return rows;
}

function collectWorkspaceSet(data) {
  return new Set((data.workspaces || []).map(workspace => workspace.cwd || "(未知工作目录)"));
}

function flattenSessions(data) {
  const rows = [];
  (data.workspaces || []).forEach(workspace => {
    (workspace.sessions || []).forEach(session => rows.push({ workspace: workspace.cwd, session }));
  });
  return rows;
}

function countUniqueWorkspaces(items) {
  return new Set(items.map(item => item.workspace || "(未知工作目录)")).size;
}

function formatGroupedChangeMessage(title, items, mapper) {
  return title + ":" + items.map(mapper).join("|");
}

function prepareData() {}
function updateStats() {}
function refreshFilterMenus() {}
function getSelectedSession() {
  const workspace = APP.workspaces.find(item => item.id === selectedWorkspaceId);
  return workspace ? workspace.sessions.find(item => getSessionKey(item) === selectedSessionKey) || null : null;
}
function detailMatchesSession(session, detail) {
  if (!session || !detail) return false;
  if (detail.path && session.path) return detail.path === session.path;
  if (detail.id && session.id) return detail.id === session.id;
  return false;
}
function focusTranscriptForQuestionNavigation() {
  return true;
}
global.requestAnimationFrame = callback => {
  callback();
  return 1;
};

const sessionCache = {
  cleared: 0,
  clear() {
    this.cleared += 1;
  }
};

let CURRENT_DETAIL = { stale: true };
let selectedWorkspaceId = "workspace-before";
let selectedSessionKey = "session-1";
let selectedQuestionKey = null;
let APP = {
  workspaces: [
    {
      id: "workspace-before",
      cwd: "/workspace",
      sessions: [
        { key: "session-1", title: "Session 1", userCount: 1, assistantCount: 1 }
      ]
    }
  ]
};

const refreshedData = {
  workspaces: [
    {
      id: "workspace-after",
      cwd: "/workspace",
      sessions: [
        { key: "session-1", title: "Session 1", userCount: 2, assistantCount: 2 }
      ]
    }
  ]
};

const toasts = [];
global.fetch = async () => ({
  ok: true,
  json: async () => ({ ok: true, data: refreshedData, scannedCount: 2, parsedCount: 1, reusedCount: 1, elapsedMs: 1200 })
});
function showToast(message, options) {
  toasts.push({ message, options });
}

const renderWorkspaceListCalls = [];
function renderWorkspaceList(skipViewerSync) {
  renderWorkspaceListCalls.push(skipViewerSync);
}

let loadSessionDetailCalls = 0;
async function loadSessionDetail(session) {
  loadSessionDetailCalls += 1;
  return { id: "detail-1", path: session.path || "", key: getSessionKey(session) };
}

let applyLoadedDetailCalls = 0;
function applyLoadedDetail() {
  applyLoadedDetailCalls += 1;
  return true;
}

let renderViewerCalls = 0;
function renderViewer() {
  renderViewerCalls += 1;
}

(async () => {
  await refreshIndex();
  console.log(JSON.stringify({
    toasts,
    sessionCacheCleared: sessionCache.cleared,
    currentDetailAfterRefresh: CURRENT_DETAIL,
    renderWorkspaceListCalls,
    loadSessionDetailCalls,
    applyLoadedDetailCalls,
    renderViewerCalls,
    selectedWorkspaceId,
    selectedSessionKey
  }));
})().catch(error => {
  console.error(error);
  process.exit(1);
});
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20

        @($result.toasts).Count | Should Be 1
        $result.sessionCacheCleared | Should Be 1
        @($result.renderWorkspaceListCalls).Count | Should Be 1
        $result.renderWorkspaceListCalls[0] | Should Be $true
        $result.loadSessionDetailCalls | Should Be 1
        $result.applyLoadedDetailCalls | Should Be 1
        $result.renderViewerCalls | Should Be 1
        $result.selectedWorkspaceId | Should Be 'workspace-after'
        $result.selectedSessionKey | Should Be 'session-1'
    }

    It 'uses currentDetail returned by the refresh response before falling back to detail fetches' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function setRefreshButtonLoading\(button, isLoading, loadingText, idleText\) \{[\s\S]*?\n    \}(?=\n\n    function focusTranscriptForQuestionNavigation)/);
if (!match) {
  throw new Error("refreshIndex helper not found");
}
eval(match[0]);

function getSessionKey(session) {
  return session.key || session.path || session.id || "";
}

function sessionSignature(session) {
  return [session.userCount || 0, session.assistantCount || 0].join(":");
}

function collectSessionMap(data) {
  const rows = new Map();
  (data.workspaces || []).forEach(workspace => {
    (workspace.sessions || []).forEach(session => {
      rows.set(getSessionKey(session), { session, signature: sessionSignature(session) });
    });
  });
  return rows;
}

function collectWorkspaceSet(data) {
  return new Set((data.workspaces || []).map(workspace => workspace.cwd || "(未知工作目录)"));
}

function flattenSessions(data) {
  const rows = [];
  (data.workspaces || []).forEach(workspace => {
    (workspace.sessions || []).forEach(session => rows.push({ workspace: workspace.cwd, session }));
  });
  return rows;
}

function countUniqueWorkspaces(items) {
  return new Set(items.map(item => item.workspace || "(未知工作目录)")).size;
}

function formatGroupedChangeMessage(title, items, mapper) {
  return title + ":" + items.map(mapper).join("|");
}

function prepareData() {}
function updateStats() {}
function refreshFilterMenus() {}
function getSelectedSession() {
  const workspace = APP.workspaces.find(item => item.id === selectedWorkspaceId);
  return workspace ? workspace.sessions.find(item => getSessionKey(item) === selectedSessionKey) || null : null;
}
function detailMatchesSession(session, detail) {
  if (!session || !detail) return false;
  if (detail.path && session.path) return detail.path === session.path;
  if (detail.id && session.id) return detail.id === session.id;
  return false;
}
function focusTranscriptForQuestionNavigation() {
  return true;
}
global.requestAnimationFrame = callback => {
  callback();
  return 1;
};

const sessionCache = {
  cleared: 0,
  clear() {
    this.cleared += 1;
  }
};

let CURRENT_DETAIL = { stale: true };
let selectedWorkspaceId = "workspace-before";
let selectedSessionKey = "session-1";
let selectedQuestionKey = null;
let APP = {
  workspaces: [
    {
      id: "workspace-before",
      cwd: "/workspace",
      sessions: [
        { key: "session-1", path: "/workspace/session-1.jsonl", title: "Session 1", userCount: 1, assistantCount: 1 }
      ]
    }
  ]
};

const refreshedData = {
  workspaces: [
    {
      id: "workspace-after",
      cwd: "/workspace",
      sessions: [
        { key: "session-1", path: "/workspace/session-1.jsonl", title: "Session 1", userCount: 2, assistantCount: 2 }
      ]
    }
  ]
};

const currentDetail = { id: "detail-1", path: "/workspace/session-1.jsonl", events: [{ kind: "user", rawText: "hi" }] };
const toasts = [];
global.fetch = async () => ({
  ok: true,
  json: async () => ({ ok: true, data: refreshedData, currentDetail, scannedCount: 1, parsedCount: 1, reusedCount: 0, elapsedMs: 900 })
});
function showToast(message, options) {
  toasts.push({ message, options });
}

const renderWorkspaceListCalls = [];
function renderWorkspaceList(skipViewerSync) {
  renderWorkspaceListCalls.push(skipViewerSync);
}

let loadSessionDetailCalls = 0;
async function loadSessionDetail(session) {
  loadSessionDetailCalls += 1;
  return { id: "fallback-detail", path: session.path || "", key: getSessionKey(session) };
}

let applyLoadedDetailCalls = 0;
const appliedDetails = [];
function applyLoadedDetail(session, detail) {
  applyLoadedDetailCalls += 1;
  appliedDetails.push({ session, detail });
  return true;
}

let renderViewerCalls = 0;
function renderViewer() {
  renderViewerCalls += 1;
}

(async () => {
  await refreshIndex();
  console.log(JSON.stringify({
    toasts,
    sessionCacheCleared: sessionCache.cleared,
    loadSessionDetailCalls,
    applyLoadedDetailCalls,
    appliedDetails,
    renderViewerCalls
  }));
})().catch(error => {
  console.error(error);
  process.exit(1);
});
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20

        @($result.toasts).Count | Should Be 1
        $result.sessionCacheCleared | Should Be 1
        $result.loadSessionDetailCalls | Should Be 0
        $result.applyLoadedDetailCalls | Should Be 1
        $result.renderViewerCalls | Should Be 1
        $result.appliedDetails[0].detail.path | Should Be '/workspace/session-1.jsonl'
    }

    It 'shows lightweight refresh progress and blocks duplicate refresh clicks' {
        $html | Should Match 'id="refreshButton"'
        $html | Should Match '\.refresh-btn \{[\s\S]*?position: relative'
        $html | Should Match '\.refresh-btn\.is-loading::after'
        $html | Should Match '@keyframes refresh-progress'
        $html | Should Match 'runRefreshRequest\._running'
        $html | Should Match 'button\.textContent = isLoading \? loadingText : idleText'

        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function setRefreshButtonLoading\(button, isLoading, loadingText, idleText\) \{[\s\S]*?\n    \}(?=\n\n    function focusTranscriptForQuestionNavigation)/);
if (!match) {
  throw new Error("refreshIndex helper not found");
}
eval(match[0]);

function getSessionKey(session) {
  return session.key || session.path || session.id || "";
}

function sessionSignature(session) {
  return [session.userCount || 0, session.assistantCount || 0].join(":");
}

function collectSessionMap(data) {
  const rows = new Map();
  (data.workspaces || []).forEach(workspace => {
    (workspace.sessions || []).forEach(session => {
      rows.set(getSessionKey(session), { session, signature: sessionSignature(session) });
    });
  });
  return rows;
}

function collectWorkspaceSet(data) {
  return new Set((data.workspaces || []).map(workspace => workspace.cwd || "(未知工作目录)"));
}

function flattenSessions(data) {
  const rows = [];
  (data.workspaces || []).forEach(workspace => {
    (workspace.sessions || []).forEach(session => rows.push({ workspace: workspace.cwd, session }));
  });
  return rows;
}

function countUniqueWorkspaces(items) {
  return new Set(items.map(item => item.workspace || "(未知工作目录)")).size;
}

function formatGroupedChangeMessage(title, items, mapper) {
  return title + ":" + items.map(mapper).join("|");
}

function prepareData() {}
function updateStats() {}
function refreshFilterMenus() {}
function getSelectedSession() {
  const workspace = APP.workspaces.find(item => item.id === selectedWorkspaceId);
  return workspace ? workspace.sessions.find(item => getSessionKey(item) === selectedSessionKey) || null : null;
}
function focusTranscriptForQuestionNavigation() {
  return true;
}
global.requestAnimationFrame = callback => {
  callback();
  return 1;
};

const sessionCache = {
  cleared: 0,
  clear() {
    this.cleared += 1;
  }
};

let CURRENT_DETAIL = { stale: true };
let selectedWorkspaceId = "workspace-before";
let selectedSessionKey = "session-1";
let selectedQuestionKey = null;
let APP = {
  workspaces: [
    {
      id: "workspace-before",
      cwd: "/workspace",
      sessions: [
        { key: "session-1", title: "Session 1", userCount: 1, assistantCount: 1 }
      ]
    }
  ]
};

const refreshedData = {
  workspaces: [
    {
      id: "workspace-after",
      cwd: "/workspace",
      sessions: [
        { key: "session-1", title: "Session 1", userCount: 2, assistantCount: 2 }
      ]
    }
  ]
};

const buttonClasses = new Set();
const refreshButton = {
  disabled: false,
  textContent: "刷新",
  classList: {
    add(value) { buttonClasses.add(value); },
    remove(value) { buttonClasses.delete(value); },
    contains(value) { return buttonClasses.has(value); }
  },
  setAttribute(name, value) {
    this[name] = value;
  },
  removeAttribute(name) {
    delete this[name];
  }
};
global.document = {
  getElementById: id => id === "refreshButton" ? refreshButton : null
};

const toasts = [];
function showToast(message, options) {
  toasts.push({ message, options });
}

let fetchCount = 0;
let resolveFetch;
global.fetch = async () => {
  fetchCount += 1;
  return new Promise(resolve => {
    resolveFetch = () => resolve({
      ok: true,
      json: async () => ({ ok: true, data: refreshedData, scannedCount: 2, parsedCount: 1, reusedCount: 1, elapsedMs: 1200 })
    });
  });
};

const renderWorkspaceListCalls = [];
function renderWorkspaceList(skipViewerSync) {
  renderWorkspaceListCalls.push(skipViewerSync);
}

let loadSessionDetailCalls = 0;
async function loadSessionDetail(session) {
  loadSessionDetailCalls += 1;
  return { id: "detail-1", path: session.path || "", key: getSessionKey(session) };
}

let applyLoadedDetailCalls = 0;
function applyLoadedDetail() {
  applyLoadedDetailCalls += 1;
  return true;
}

let renderViewerCalls = 0;
function renderViewer() {
  renderViewerCalls += 1;
}

(async () => {
  const firstRefresh = refreshIndex();
  await Promise.resolve();
  const during = {
    disabled: refreshButton.disabled,
    text: refreshButton.textContent,
    loading: refreshButton.classList.contains("is-loading"),
    ariaBusy: refreshButton["aria-busy"],
    fetchCount
  };
  await refreshIndex();
  const duplicateFetchCount = fetchCount;
  resolveFetch();
  await firstRefresh;
  console.log(JSON.stringify({
    during,
    duplicateFetchCount,
    after: {
      disabled: refreshButton.disabled,
      text: refreshButton.textContent,
      loading: refreshButton.classList.contains("is-loading"),
      ariaBusy: refreshButton["aria-busy"]
    },
    toasts,
    renderWorkspaceListCalls,
    loadSessionDetailCalls,
    applyLoadedDetailCalls,
    renderViewerCalls
  }));
})().catch(error => {
  console.error(error);
  process.exit(1);
});
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20

        $result.during.disabled | Should Be $true
        $result.during.text | Should Be '刷新中...'
        $result.during.loading | Should Be $true
        $result.during.ariaBusy | Should Be 'true'
        $result.during.fetchCount | Should Be 1
        $result.duplicateFetchCount | Should Be 1
        $result.after.disabled | Should Be $false
        $result.after.text | Should Be '刷新'
        $result.after.loading | Should Be $false
        $result.after.ariaBusy | Should BeNullOrEmpty
        @($result.toasts).Count | Should Be 1
        @($result.renderWorkspaceListCalls).Count | Should Be 1
        $result.loadSessionDetailCalls | Should Be 1
        $result.applyLoadedDetailCalls | Should Be 1
        $result.renderViewerCalls | Should Be 1
    }

    It 'warns that full rebuild may take longer and keeps the selected session path in the request body' {
        $html | Should Match '重新扫描和解析全部聊天记录，耗时可能较长'
        $html | Should Match 'title="重新扫描和解析全部聊天记录，耗时可能较长"'

        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function setRefreshButtonLoading\(button, isLoading, loadingText, idleText\) \{[\s\S]*?\n    \}(?=\n\n    function focusTranscriptForQuestionNavigation)/);
if (!match) {
  throw new Error("refreshIndex helper not found");
}
eval(match[0]);

function getSessionKey(session) {
  return session.key || session.path || session.id || "";
}

function sessionSignature(session) {
  return [session.userCount || 0, session.assistantCount || 0].join(":");
}

function collectSessionMap(data) {
  const rows = new Map();
  (data.workspaces || []).forEach(workspace => {
    (workspace.sessions || []).forEach(session => {
      rows.set(getSessionKey(session), { session, signature: sessionSignature(session) });
    });
  });
  return rows;
}

function collectWorkspaceSet(data) {
  return new Set((data.workspaces || []).map(workspace => workspace.cwd || "(未知工作目录)"));
}

function flattenSessions(data) {
  const rows = [];
  (data.workspaces || []).forEach(workspace => {
    (workspace.sessions || []).forEach(session => rows.push({ workspace: workspace.cwd, session }));
  });
  return rows;
}

function countUniqueWorkspaces(items) {
  return new Set(items.map(item => item.workspace || "(未知工作目录)")).size;
}

function formatGroupedChangeMessage(title, items, mapper) {
  return title + ":" + items.map(mapper).join("|");
}

function prepareData() {}
function updateStats() {}
function refreshFilterMenus() {}
function focusTranscriptForQuestionNavigation() {
  return true;
}
global.requestAnimationFrame = callback => {
  callback();
  return 1;
};

const selectedSession = { key: "session-1", path: "/workspace/session-1.jsonl", title: "Session 1", userCount: 1, assistantCount: 1 };
function getSelectedSession() {
  return selectedSession;
}
function detailMatchesSession(session, detail) {
  if (!session || !detail) return false;
  if (detail.path && session.path) return detail.path === session.path;
  if (detail.id && session.id) return detail.id === session.id;
  return false;
}

const sessionCache = {
  clear() {}
};

let CURRENT_DETAIL = { stale: true };
let selectedWorkspaceId = "workspace-before";
let selectedSessionKey = "session-1";
let selectedQuestionKey = null;
let APP = {
  workspaces: [
    {
      id: "workspace-before",
      cwd: "/workspace",
      sessions: [selectedSession]
    }
  ]
};

const rebuildData = {
  workspaces: [
    {
      id: "workspace-after",
      cwd: "/workspace",
      sessions: [
        { key: "session-1", path: "/workspace/session-1.jsonl", title: "Session 1", userCount: 1, assistantCount: 1 }
      ]
    }
  ]
};

const toasts = [];
const requests = [];
global.fetch = async (url, request) => {
  requests.push({ url, request });
  return {
    ok: true,
    json: async () => ({ ok: true, data: rebuildData, currentDetail: { path: "/workspace/session-1.jsonl", events: [] }, scannedCount: 2, parsedCount: 2, reusedCount: 0, elapsedMs: 4200 })
  };
};
function showToast(message, options) {
  toasts.push({ message, options });
}

function renderWorkspaceList() {}
async function loadSessionDetail() {
  throw new Error("loadSessionDetail should not run when currentDetail is returned");
}
function applyLoadedDetail() {
  return true;
}
function renderViewer() {}

(async () => {
  await rebuildIndex();
  console.log(JSON.stringify({ toasts, requests }));
})().catch(error => {
  console.error(error);
  process.exit(1);
});
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20

        @($result.toasts).Count | Should Be 2
        $result.toasts[0].message | Should Match '全量重建会重新扫描和解析全部聊天记录'
        $result.requests[0].url | Should Be '/api/rebuild'
        $requestBody = $result.requests[0].request.body | ConvertFrom-Json
        $requestBody.path | Should Be '/workspace/session-1.jsonl'
    }

    It 'fails refresh safely when clicked before app data is ready' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function setRefreshButtonLoading\(button, isLoading, loadingText, idleText\) \{[\s\S]*?\n    \}(?=\n\n    function focusTranscriptForQuestionNavigation)/);
if (!match) {
  throw new Error("refreshIndex helper not found");
}
eval(match[0]);

function getSessionKey(session) {
  return session.key || session.path || session.id || "";
}

function sessionSignature(session) {
  return [session.userCount || 0, session.assistantCount || 0].join(":");
}

function collectSessionMap(data) {
  const rows = new Map();
  ((data && data.workspaces) || []).forEach(workspace => {
    (workspace.sessions || []).forEach(session => {
      rows.set(getSessionKey(session), { session, signature: sessionSignature(session) });
    });
  });
  return rows;
}

function collectWorkspaceSet(data) {
  return new Set((((data && data.workspaces) || [])).map(workspace => workspace.cwd || "(未知工作目录)"));
}

function flattenSessions(data) {
  const rows = [];
  (((data && data.workspaces) || [])).forEach(workspace => {
    (workspace.sessions || []).forEach(session => rows.push({ workspace: workspace.cwd, session }));
  });
  return rows;
}

function countUniqueWorkspaces(items) {
  return new Set(items.map(item => item.workspace || "(未知工作目录)")).size;
}

function formatGroupedChangeMessage(title, items, mapper) {
  return title + ":" + items.map(mapper).join("|");
}

function prepareData() {}
function updateStats() {}
function refreshFilterMenus() {}
function getSelectedSession() {
  return null;
}
function renderWorkspaceList() {
  throw new Error("renderWorkspaceList should not run on failed refresh");
}
function renderViewer() {
  throw new Error("renderViewer should not run on failed refresh");
}
async function loadSessionDetail() {
  throw new Error("loadSessionDetail should not run on failed refresh");
}
function applyLoadedDetail() {
  throw new Error("applyLoadedDetail should not run on failed refresh");
}

const sessionCache = {
  clear() {
    throw new Error("sessionCache.clear should not run on failed refresh");
  }
};

let CURRENT_DETAIL = { stale: true };
let selectedWorkspaceId = "workspace-before";
let selectedSessionKey = "session-1";
let selectedQuestionKey = null;
let APP = null;

const toasts = [];
global.fetch = async () => {
  throw new Error("network down");
};
function showToast(message, options) {
  toasts.push({ message, options });
}

(async () => {
  await refreshIndex();
  console.log(JSON.stringify({
    toasts,
    currentDetailAfterRefresh: CURRENT_DETAIL,
    selectedWorkspaceId,
    selectedSessionKey
  }));
})().catch(error => {
  console.error(error);
  process.exit(1);
});
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20

        @($result.toasts).Count | Should Be 1
        $result.toasts[0].message | Should Match '刷新失败'
        $result.toasts[0].message | Should Match 'network down'
        $result.currentDetailAfterRefresh.stale | Should Be $true
        $result.selectedWorkspaceId | Should Be 'workspace-before'
        $result.selectedSessionKey | Should Be 'session-1'
    }

    It 'keeps concise tool summaries with invocation context' {
        $detail | Should Not BeNullOrEmpty
        $toolEvent = @($detail.events | Where-Object { $_.kind -eq 'tool' } | Select-Object -First 1)[0]
        $toolEvent | Should Not BeNullOrEmpty
        $toolEvent.summary | Should Match '^exec_command: '
        $toolEvent.summary | Should Match 'exit=0'
    }

    It 'uses stable session identity for refresh diffing instead of bare id' {
        $python = @'
import importlib.util
import json
import pathlib
import sys

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("codex_chat_index_server", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
sample = {
    "workspaces": [
        {
            "sessions": [
                {"id": "dup-id", "path": "workspace-a/session.jsonl", "key": "workspace-a/session.jsonl"},
                {"id": "dup-id", "path": "workspace-b/session.jsonl", "key": "workspace-b/session.jsonl"},
            ]
        }
    ]
}
values = sorted(module.collect_ids(sample))
print(json.dumps(values))
'@
        $values = python -c $python $serverScript | ConvertFrom-Json
        @($values).Count | Should Be 2
        ((@($values) -contains 'workspace-a/session.jsonl')) | Should Be $true
        ((@($values) -contains 'workspace-b/session.jsonl')) | Should Be $true
    }

    It 'exposes separate server endpoints for current refresh, incremental refresh, and rebuild' {
        $serverSource = Get-Content -LiteralPath $serverScript -Raw
        $serverSource | Should Match '/api/refresh-current'
        $serverSource | Should Match '/api/refresh'
        $serverSource | Should Match '/api/rebuild'
        $serverSource | Should Match 'currentDetail'
        $serverSource | Should Match 'RefreshMode'
        $serverSource | Should Match 'CurrentSessionPath'
    }

    It 'loads current detail payloads for refresh responses by session path' {
        $python = @'
import importlib.util
import json
import pathlib
import sys
import tempfile

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("codex_chat_index_server", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as tmp_dir:
    tmp_root = pathlib.Path(tmp_dir)
    module.ROOT = tmp_root / "软件版本_V0.08"
    module.ROOT.mkdir(parents=True, exist_ok=True)
    module.SERVE_ROOT = tmp_root
    module.RUNTIME_DATA_DIR = tmp_root / "运行数据"
    module.RUNTIME_DATA_DIR.mkdir(parents=True, exist_ok=True)
    detail_dir = module.RUNTIME_DATA_DIR / "CodexChatIndex.sessions"
    detail_dir.mkdir(parents=True, exist_ok=True)

    detail_payload = {
        "id": "session-1",
        "path": "C:/demo/session-1.jsonl",
        "events": [{"kind": "user", "rawText": "hello"}]
    }
    detail_path = detail_dir / "detail.json"
    detail_path.write_text(json.dumps(detail_payload, ensure_ascii=False), encoding="utf-8")

    data = {
        "workspaces": [
            {
                "cwd": "C:/demo",
                "sessions": [
                    {
                        "id": "session-1",
                        "key": "C:/demo/session-1.jsonl",
                        "path": "C:/demo/session-1.jsonl",
                        "detailHref": "../运行数据/CodexChatIndex.sessions/detail.json"
                    }
                ]
            }
        ]
    }
    result = module.load_current_detail_for_path(data, "C:/demo/session-1.jsonl")
    print(json.dumps({"path": result["path"], "eventCount": len(result["events"])}, ensure_ascii=False))
'@
        $result = (python -c $python $serverScript | Select-Object -Last 1) | ConvertFrom-Json

        $result.path | Should Be 'C:/demo/session-1.jsonl'
        $result.eventCount | Should Be 1
    }

    It 'prefers Windows shell browser launching with a webbrowser fallback' {
        $python = @'
import importlib.util
import json
import pathlib
import sys

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("codex_chat_index_server", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

calls = []
def fake_startfile(url):
    calls.append({"kind": "startfile", "url": url})

def fake_webbrowser_open(url):
    calls.append({"kind": "webbrowser", "url": url})
    return True

module.os.startfile = fake_startfile
module.webbrowser.open = fake_webbrowser_open
module.open_browser("http://127.0.0.1:8765/demo")
print(json.dumps(calls))
'@
        $calls = python -c $python $serverScript | ConvertFrom-Json

        @($calls).Count | Should BeGreaterThan 0
        $calls[0].kind | Should Be 'startfile'
        $calls[0].url | Should Be 'http://127.0.0.1:8765/demo'
    }

    It 'reuses an already-running local service when the port is already bound by this app' {
        $python = @'
import importlib.util
import json
import pathlib
import sys

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("codex_chat_index_server", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

module.run_build = lambda refresh_mode="Incremental", current_session_path=None, source_id="local-codex": (True, "", {})

class BusyServer:
    def __init__(self, *args, **kwargs):
        error = OSError("Address already in use")
        error.winerror = 10048
        raise error

module.ThreadingHTTPServer = BusyServer
module.is_reusable_existing_service = lambda url: True

opened = []
module.open_browser = lambda url: opened.append(url) or True
sys.argv = ["CodexChatIndexServer.py", "--open"]
code = module.main()
print(json.dumps({"code": code, "opened": opened}, ensure_ascii=False))
'@
        $result = (python -c $python $serverScript | Select-Object -Last 1) | ConvertFrom-Json

        $result.code | Should Be 0
        @($result.opened).Count | Should Be 1
        $result.opened[0] | Should Match '127.0.0.1:8765'
    }

    It 'fails clearly when the port is in use by another program' {
        $python = @'
import importlib.util
import json
import pathlib
import sys

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("codex_chat_index_server", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

module.run_build = lambda refresh_mode="Incremental", current_session_path=None, source_id="local-codex": (True, "", {})

class BusyServer:
    def __init__(self, *args, **kwargs):
        error = OSError("Address already in use")
        error.winerror = 10048
        raise error

module.ThreadingHTTPServer = BusyServer
module.is_reusable_existing_service = lambda url: False
module.open_browser = lambda url: (_ for _ in ()).throw(RuntimeError("browser should not open"))
sys.argv = ["CodexChatIndexServer.py"]
code = module.main()
print(json.dumps({"code": code}, ensure_ascii=False))
'@
        $result = (python -c $python $serverScript | Select-Object -Last 1) | ConvertFrom-Json

        $result.code | Should Be 1
    }

    It 'points the local server at per-source shared runtime data directories' {
        $python = @'
import importlib.util
import json
import pathlib
import sys

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("codex_chat_index_server", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
payload = {
    "serveRootMatchesLayout": module.SERVE_ROOT == module.ROOT.parent,
    "tempDirMatchesSourceRoot": module.TEMP_DIR == module.ROOT / "temp",
    "htmlFileMatchesVersion": module.HTML_FILE == module.ROOT / "temp" / "CodexChatIndex.html",
    "dataFileMatchesRuntime": module.get_source_paths("local-codex")["data"] == module.ROOT.parent / "运行数据" / "CodexChatIndex.sources" / "local-codex" / "CodexChatIndex.data.json",
    "searchFileMatchesRuntime": module.get_source_paths("local-codex")["search"] == module.ROOT.parent / "运行数据" / "CodexChatIndex.sources" / "local-codex" / "CodexChatIndex.search.json",
    "sourcesFileMatchesRuntime": module.SOURCES_FILE == module.ROOT.parent / "运行数据" / "CodexChatIndex.sources.json",
    "externalRootMatchesLayout": module.EXTERNAL_SOURCES_ROOT == module.ROOT.parent / "外部聊天记录",
    "entryPathMatchesVersionHtml": module.ENTRY_PATH == f"/{module.ROOT.name}/temp/CodexChatIndex.html",
    "dataFileName": module.get_source_paths("local-codex")["data"].name,
}
print(json.dumps(payload, ensure_ascii=False))
'@
        $result = python -c $python $serverScript | ConvertFrom-Json
        $result.serveRootMatchesLayout | Should Be $true
        $result.tempDirMatchesSourceRoot | Should Be $true
        $result.htmlFileMatchesVersion | Should Be $true
        $result.dataFileMatchesRuntime | Should Be $true
        $result.searchFileMatchesRuntime | Should Be $true
        $result.sourcesFileMatchesRuntime | Should Be $true
        $result.externalRootMatchesLayout | Should Be $true
        $result.entryPathMatchesVersionHtml | Should Be $true
        $result.dataFileName | Should Be 'CodexChatIndex.data.json'
    }

    It 'redirects root and legacy HTML routes to the V0.26 temp entry path' {
        $python = @'
import importlib.util
import json
import pathlib
import sys

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("codex_chat_index_server", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

results = {}

def fake_super_get(self):
    self.calls.append(["super", self.path])

module.SimpleHTTPRequestHandler.do_GET = fake_super_get

for path in ["/", "/CodexChatIndex.html", f"/{module.ROOT.name}/CodexChatIndex.html"]:
    handler = object.__new__(module.Handler)
    handler.path = path
    handler.calls = []
    handler.send_response = lambda status, h=handler: h.calls.append(["status", int(status)])
    handler.send_header = lambda name, value, h=handler: h.calls.append(["header", name, value])
    handler.end_headers = lambda h=handler: h.calls.append(["end"])
    module.Handler.do_GET(handler)
    results[path] = handler.calls

print(json.dumps({"entryPath": module.ENTRY_PATH, "results": results}, ensure_ascii=False))
'@
        $result = python -c $python $serverScript | ConvertFrom-Json -Depth 20
        foreach ($path in @('/', '/CodexChatIndex.html', '/CodexChatIndex/CodexChatIndex.html')) {
            $calls = @($result.results.$path)
            (($calls | ConvertTo-Json -Depth 5) -match '"super"') | Should Be $false
            @($calls | Where-Object { $_[0] -eq 'status' -and $_[1] -eq 302 }).Count | Should Be 1
            @($calls | Where-Object { $_[0] -eq 'header' -and $_[1] -eq 'Location' -and $_[2] -eq $result.entryPath }).Count | Should Be 1
        }
    }

    It 'passes the temp HTML output path when the server triggers a build' {
        $python = @'
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("codex_chat_index_server", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as tmp_dir:
    tmp_root = pathlib.Path(tmp_dir)
    module.ROOT = tmp_root / "CodexChatIndex"
    module.ROOT.mkdir(parents=True, exist_ok=True)
    module.TEMP_DIR = module.ROOT / "temp"
    module.HTML_FILE = module.TEMP_DIR / "CodexChatIndex.html"
    module.SERVE_ROOT = tmp_root
    module.RUNTIME_DATA_DIR = tmp_root / "运行数据"
    module.SOURCES_FILE = module.RUNTIME_DATA_DIR / "CodexChatIndex.sources.json"
    module.EXTERNAL_SOURCES_ROOT = tmp_root / "外部聊天记录"
    module.BUILD_SCRIPT = module.ROOT / "Build-CodexChatIndex.ps1"

    paths = module.get_source_paths("local-codex")
    captured = {}

    def fake_run(cmd, cwd=None, capture_output=None, text=None):
        captured["cmd"] = [str(item) for item in cmd]
        captured["cwd"] = str(cwd)
        module.HTML_FILE.parent.mkdir(parents=True, exist_ok=True)
        module.HTML_FILE.write_text("html", encoding="utf-8")
        paths["root"].mkdir(parents=True, exist_ok=True)
        paths["data"].write_text(json.dumps({"workspaces": []}), encoding="utf-8")
        paths["search"].write_text(json.dumps({"version": 1, "sessions": []}), encoding="utf-8")
        return subprocess.CompletedProcess(cmd, 0, stdout=b'{"Mode":"Incremental"}', stderr=b"")

    module.subprocess.run = fake_run
    ok, message, summary = module.run_build("Incremental", None, "local-codex")
    output_index = captured["cmd"].index("-OutputPath")
    print(json.dumps({
        "ok": ok,
        "outputPath": captured["cmd"][output_index + 1],
        "expectedOutputPath": str(module.HTML_FILE),
        "cwd": captured["cwd"],
        "expectedCwd": str(module.ROOT),
    }, ensure_ascii=False))
'@
        $result = python -c $python $serverScript | ConvertFrom-Json
        $result.ok | Should Be $true
        $result.outputPath | Should Be $result.expectedOutputPath
        $result.cwd | Should Be $result.expectedCwd
    }

    It 'opens quickly by skipping startup rebuild when local-codex source data already exists' {
        $python = @'
import importlib.util
import json
import pathlib
import sys
import tempfile

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("codex_chat_index_server", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as tmp_dir:
    tmp_root = pathlib.Path(tmp_dir)
    module.ROOT = tmp_root / "CodexChatIndex"
    module.ROOT.mkdir(parents=True, exist_ok=True)
    module.SERVE_ROOT = tmp_root
    module.RUNTIME_DATA_DIR = tmp_root / "运行数据"
    module.SOURCES_FILE = module.RUNTIME_DATA_DIR / "CodexChatIndex.sources.json"
    module.EXTERNAL_SOURCES_ROOT = tmp_root / "外部聊天记录"
    module.TEMP_DIR = module.ROOT / "temp"
    module.TEMP_DIR.mkdir(parents=True, exist_ok=True)
    module.HTML_FILE = module.TEMP_DIR / "CodexChatIndex.html"
    module.HTML_FILE.write_text("Codex 聊天记录浏览器", encoding="utf-8")
    paths = module.get_source_paths("local-codex")
    paths["root"].mkdir(parents=True, exist_ok=True)
    paths["data"].write_text(json.dumps({"workspaces": []}), encoding="utf-8")
    paths["search"].write_text(json.dumps({"version": 1, "sessions": []}), encoding="utf-8")

    build_calls = []
    module.run_build = lambda refresh_mode="Incremental", current_session_path=None, source_id="local-codex": (build_calls.append(refresh_mode) or (True, "unexpected build", {}))

    class OneShotServer:
        def __init__(self, *args, **kwargs):
            pass
        def serve_forever(self):
            raise KeyboardInterrupt()
        def server_close(self):
            pass

    module.ThreadingHTTPServer = OneShotServer
    sys.argv = ["CodexChatIndexServer.py"]
    code = module.main()
    print(json.dumps({"code": code, "buildCalls": build_calls}, ensure_ascii=False))
'@
        $result = python -c $python $serverScript | Select-Object -Last 1 | ConvertFrom-Json

        $result.code | Should Be 0
        @($result.buildCalls).Count | Should Be 0
    }

    It 'reads old notes as local-codex and writes V0.16 notes with sourceId' {
        $python = @'
import importlib.util
import json
import pathlib
import sys
import tempfile

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("codex_chat_index_server", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as tmp_dir:
    tmp_root = pathlib.Path(tmp_dir)
    module.ROOT = tmp_root / "软件版本_V0.16"
    module.ROOT.mkdir(parents=True, exist_ok=True)
    module.SERVE_ROOT = tmp_root
    module.RUNTIME_DATA_DIR = tmp_root / "运行数据"
    module.RUNTIME_DATA_DIR.mkdir(parents=True, exist_ok=True)
    module.NOTES_FILE = module.RUNTIME_DATA_DIR / "CodexChatIndex.notes.json"
    module.NOTES_FILE.write_text(json.dumps({
        "version": 1,
        "updatedAt": "",
        "notes": {
            "group:legacy": {
                "type": "group",
                "workspace": "M:/WORK/demo",
                "title": "旧备注",
                "note": "legacy note"
            }
        }
    }, ensure_ascii=False), encoding="utf-8")

    initial_local = module.load_notes("local-codex")
    initial_external = module.load_notes("external-alpha-test")
    saved = module.save_note({
        "key": "group:abc",
        "type": "group",
        "sourceId": "external-alpha-test",
        "workspace": "M:/WORK/demo",
        "title": "\u6807\u9898",
        "note": "  \u7b2c\u4e00\u884c\n\u7b2c\u4e8c\u884c  ",
    })
    updated_external = module.load_notes("external-alpha-test")
    updated_local = module.load_notes("local-codex")
    deleted = module.delete_note("group:abc", "external-alpha-test")
    after_delete = module.load_notes("external-alpha-test")
    print(json.dumps({
        "initialLocal": initial_local,
        "initialExternal": initial_external,
        "saved": saved,
        "updatedExternal": updated_external,
        "updatedLocal": updated_local,
        "deleted": deleted,
        "afterDelete": after_delete,
        "notesFileName": module.NOTES_FILE.name,
        "notesParentName": module.NOTES_FILE.parent.name,
    }))
'@
        $result = python -c $python $serverScript | ConvertFrom-Json -Depth 30

        $result.initialLocal.ok | Should Be $true
        $result.initialLocal.notes.'group:legacy'.note | Should Be 'legacy note'
        $result.initialLocal.notes.'group:legacy'.sourceId | Should Be 'local-codex'
        @($result.initialExternal.notes.PSObject.Properties).Count | Should Be 0
        $result.saved.ok | Should Be $true
        $result.saved.item.sourceId | Should Be 'external-alpha-test'
        $result.saved.item.note | Should Be "第一行`n第二行"
        $result.updatedExternal.notes.'group:abc'.note | Should Be "第一行`n第二行"
        @($result.updatedLocal.notes.PSObject.Properties | Where-Object { $_.Name -eq 'group:abc' }).Count | Should Be 0
        $result.deleted.ok | Should Be $true
        @($result.afterDelete.notes.PSObject.Properties).Count | Should Be 0
        $result.notesFileName | Should Be 'CodexChatIndex.notes.json'
        $result.notesParentName | Should Be '运行数据'
    }

    It 'validates V0.16 notes payloads before writing user data' {
        $python = @'
import importlib.util
import json
import pathlib
import sys
import tempfile

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("codex_chat_index_server", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as tmp_dir:
    module.RUNTIME_DATA_DIR = pathlib.Path(tmp_dir) / "运行数据"
    module.RUNTIME_DATA_DIR.mkdir(parents=True, exist_ok=True)
    module.NOTES_FILE = module.RUNTIME_DATA_DIR / "CodexChatIndex.notes.json"
    cases = []
    for payload in [
        {"key": "", "type": "group", "note": "备注"},
        {"key": "bad:type", "type": "bad", "note": "备注"},
        {"key": "group:blank", "type": "group", "note": "   "},
        {"key": "group:long", "type": "group", "note": "x" * (module.MAX_NOTE_LENGTH + 1)},
    ]:
        try:
            module.save_note(payload)
            cases.append({"ok": True})
        except ValueError as error:
            cases.append({"ok": False, "error": str(error)})
    print(json.dumps(cases, ensure_ascii=False))
'@
        $cases = python -c $python $serverScript | ConvertFrom-Json

        @($cases).Count | Should Be 4
        @($cases | Where-Object { $_.ok -eq $false }).Count | Should Be 4
        ($cases[0].error) | Should Match 'key'
        ($cases[1].error) | Should Match 'type'
        ($cases[2].error) | Should Match 'note'
        ($cases[3].error) | Should Match 'too long'
    }

    It 'exposes V0.16 source-aware API endpoints without mixing notes into refresh routes' {
        $serverSource = Get-Content -LiteralPath $serverScript -Raw
        $serverSource | Should Match 'NOTES_FILE = RUNTIME_DATA_DIR / "CodexChatIndex\.notes\.json"'
        $serverSource | Should Match 'SOURCES_FILE = RUNTIME_DATA_DIR / "CodexChatIndex\.sources\.json"'
        $serverSource | Should Match 'EXTERNAL_SOURCES_ROOT = SERVE_ROOT / "外部聊天记录"'
        $serverSource | Should Match 'MAX_NOTE_LENGTH = 10000'
        $serverSource | Should Match 'def discover_sources\(\)'
        $serverSource | Should Match 'def get_source_paths\(source_id: str\)'
        $serverSource | Should Match 'def get_selected_source_id\(\)'
        $serverSource | Should Match 'def resolve_source_id'
        $serverSource | Should Match 'def load_notes\(source_id'
        $serverSource | Should Match 'def save_note\(payload: dict\)'
        $serverSource | Should Match 'def delete_note\(key: str, source_id: str = LOCAL_SOURCE_ID\)'
        $serverSource | Should Match 'if parsed\.path == "/api/sources"'
        $serverSource | Should Match 'if parsed\.path == "/api/source-data"'
        $serverSource | Should Match 'if parsed\.path == "/api/notes"'
        $serverSource | Should Match 'if parsed\.path == "/api/notes"'
        $serverSource | Should Match 'source_id = resolve_source_id'
        $serverSource | Should Match 'def do_DELETE\(self\)'
    }

    It 'discovers external source folders and gives each a stable source id' {
        $python = @'
import importlib.util
import json
import pathlib
import sys
import tempfile

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("codex_chat_index_server", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as tmp_dir:
    tmp_root = pathlib.Path(tmp_dir)
    module.ROOT = tmp_root / "软件版本_V0.16"
    module.ROOT.mkdir(parents=True, exist_ok=True)
    module.SERVE_ROOT = tmp_root
    module.RUNTIME_DATA_DIR = tmp_root / "运行数据"
    module.SOURCES_FILE = module.RUNTIME_DATA_DIR / "CodexChatIndex.sources.json"
    module.EXTERNAL_SOURCES_ROOT = tmp_root / "外部聊天记录"
    (module.EXTERNAL_SOURCES_ROOT / "\u65e7\u7535\u8111Codex").mkdir(parents=True)
    (module.EXTERNAL_SOURCES_ROOT / "\u670b\u53cb\u7535\u8111\u590d\u5236").mkdir(parents=True)
    sources_payload = module.discover_sources()
    print(json.dumps(sources_payload))
'@
        $result = python -c $python $serverScript | ConvertFrom-Json -Depth 20
        $result.selectedSourceId | Should Be 'local-codex'
        @($result.sources).Count | Should Be 4
        @($result.sources | Where-Object { $_.id -eq 'local-codex' -and $_.label -eq '本机 Codex' -and $_.type -eq 'local-codex' }).Count | Should Be 1
        @($result.sources | Where-Object { $_.id -eq 'local-claude' -and $_.label -eq '本机 Claude' -and $_.type -eq 'local-claude' }).Count | Should Be 1
        @($result.sources | Where-Object { $_.label -eq '旧电脑Codex' -and $_.type -eq 'external-codex-jsonl' -and $_.id -match '^external-' }).Count | Should Be 1
        @($result.sources | Where-Object { $_.label -eq '朋友电脑复制' -and $_.type -eq 'external-codex-jsonl' -and $_.id -match '^external-' }).Count | Should Be 1
    }

    It 'discovers the V0.17 local Claude source beside local Codex and external sources' {
        $python = @'
import importlib.util
import json
import pathlib
import sys
import tempfile

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("codex_chat_index_server", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as tmp_dir:
    tmp_root = pathlib.Path(tmp_dir)
    module.ROOT = tmp_root / "软件版本_V0.17"
    module.ROOT.mkdir(parents=True, exist_ok=True)
    module.SERVE_ROOT = tmp_root
    module.RUNTIME_DATA_DIR = tmp_root / "运行数据"
    module.SOURCES_FILE = module.RUNTIME_DATA_DIR / "CodexChatIndex.sources.json"
    module.EXTERNAL_SOURCES_ROOT = tmp_root / "外部聊天记录"
    module.CLAUDE_HOME = tmp_root / ".claude"
    (module.CLAUDE_HOME / "projects").mkdir(parents=True)
    (module.CLAUDE_HOME / "sessions").mkdir(parents=True)
    (module.EXTERNAL_SOURCES_ROOT / "Alpha").mkdir(parents=True)
    sources_payload = module.discover_sources()
    print(json.dumps(sources_payload))
'@
        $result = python -c $python $serverScript | ConvertFrom-Json -Depth 20
        $result.selectedSourceId | Should Be 'local-codex'
        @($result.sources | Where-Object { $_.id -eq 'local-codex' -and $_.label -eq '本机 Codex' -and $_.type -eq 'local-codex' }).Count | Should Be 1
        @($result.sources | Where-Object { $_.id -eq 'local-claude' -and $_.label -eq '本机 Claude' -and $_.type -eq 'local-claude' }).Count | Should Be 1
        @($result.sources | Where-Object { $_.label -eq 'Alpha' -and $_.type -eq 'external-codex-jsonl' }).Count | Should Be 1
    }

    It 'runs refresh, rebuild, current refresh, and search against the requested source only' {
        $python = @'
import importlib.util
import json
import pathlib
import sys
import tempfile

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("codex_chat_index_server", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as tmp_dir:
    tmp_root = pathlib.Path(tmp_dir)
    module.ROOT = tmp_root / "软件版本_V0.16"
    module.ROOT.mkdir(parents=True, exist_ok=True)
    module.SERVE_ROOT = tmp_root
    module.RUNTIME_DATA_DIR = tmp_root / "运行数据"
    module.SOURCES_FILE = module.RUNTIME_DATA_DIR / "CodexChatIndex.sources.json"
    module.EXTERNAL_SOURCES_ROOT = tmp_root / "外部聊天记录"
    external_root = module.EXTERNAL_SOURCES_ROOT / "Alpha"
    external_root.mkdir(parents=True)
    source_id = module.make_external_source_id(external_root.name, external_root)
    calls = []
    module.run_build = lambda refresh_mode="Incremental", current_session_path=None, source_id="local-codex": (calls.append({
        "mode": refresh_mode,
        "current": current_session_path,
        "source": source_id
    }) or (True, "ok", {"mode": refresh_mode, "sourceId": source_id}))
    paths = module.get_source_paths(source_id)
    paths["root"].mkdir(parents=True, exist_ok=True)
    paths["data"].write_text(json.dumps({"workspaces": []}), encoding="utf-8")
    paths["search"].write_text(json.dumps({"version": 1, "sessions": [{"key": "external-key", "title": "Alpha", "cwd": "M:/Alpha", "path": "alpha.jsonl", "searchText": "needle"}]}), encoding="utf-8")
    search_hits = module.search_sessions("needle", source_id)
    ok, message, summary = module.run_build("Current", "alpha.jsonl", source_id)
    print(json.dumps({
        "sourceId": source_id,
        "pathsRoot": paths["root"].name,
        "searchHits": search_hits,
        "calls": calls,
        "summary": summary,
    }, ensure_ascii=False))
'@
        $result = python -c $python $serverScript | ConvertFrom-Json -Depth 20
        $result.sourceId | Should Match '^external-'
        $result.pathsRoot | Should Be $result.sourceId
        @($result.searchHits).Count | Should Be 1
        $result.searchHits[0].key | Should Be 'external-key'
        @($result.calls).Count | Should Be 1
        $result.calls[0].source | Should Be $result.sourceId
        $result.calls[0].mode | Should Be 'Current'
        $result.calls[0].current | Should Be 'alpha.jsonl'
    }

    It 'uses V0.22 multi-keyword AND semantics for server-side search' {
        $python = @'
import importlib.util
import json
import pathlib
import sys
import tempfile

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("codex_chat_index_server", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as tmp_dir:
    tmp_root = pathlib.Path(tmp_dir)
    module.ROOT = tmp_root / "软件版本_V0.22"
    module.ROOT.mkdir(parents=True, exist_ok=True)
    module.SERVE_ROOT = tmp_root
    module.RUNTIME_DATA_DIR = tmp_root / "运行数据"
    module.SOURCES_FILE = module.RUNTIME_DATA_DIR / "CodexChatIndex.sources.json"
    module.EXTERNAL_SOURCES_ROOT = tmp_root / "外部聊天记录"
    paths = module.get_source_paths("local-codex")
    paths["root"].mkdir(parents=True, exist_ok=True)
    paths["search"].write_text(json.dumps({
        "version": 1,
        "sessions": [
            {"key": "both", "title": "Both", "cwd": "M:/Demo", "path": "both.jsonl", "searchText": "exit happened before a later code block"},
            {"key": "one", "title": "One", "cwd": "M:/Demo", "path": "one.jsonl", "searchText": "exit happened only"},
            {"key": "phrase", "title": "Phrase", "cwd": "M:/Demo", "path": "phrase.jsonl", "searchText": "exit code adjacent"}
        ]
    }), encoding="utf-8")
    print(json.dumps({
        "exitCode": [row["key"] for row in module.search_sessions(" exit   code ", "local-codex")],
        "codeExit": [row["key"] for row in module.search_sessions("code exit", "local-codex")],
        "blank": module.search_sessions("   ", "local-codex")
    }))
'@
        $result = python -c $python $serverScript | ConvertFrom-Json -Depth 20

        ($result.exitCode -join ',') | Should Be 'both,phrase'
        ($result.codeExit -join ',') | Should Be 'both,phrase'
        @($result.blank).Count | Should Be 0
    }

    It 'evicts V0.22 search indexes by LRU when the cache exceeds its size limit' {
        $python = @'
import importlib.util
import json
import pathlib
import sys
import tempfile

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("codex_chat_index_server", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as tmp_dir:
    tmp_root = pathlib.Path(tmp_dir)
    module.ROOT = tmp_root / "软件版本_V0.22"
    module.ROOT.mkdir(parents=True, exist_ok=True)
    module.SERVE_ROOT = tmp_root
    module.RUNTIME_DATA_DIR = tmp_root / "运行数据"
    module.SOURCES_FILE = module.RUNTIME_DATA_DIR / "CodexChatIndex.sources.json"
    module.EXTERNAL_SOURCES_ROOT = tmp_root / "外部聊天记录"
    module.SEARCH_INDEX_CACHE_MAX_BYTES = 360
    module.SEARCH_INDEX_CACHE_MAX_ENTRIES = 8
    module._search_index_cache.clear()
    module._search_index_mtime_ns.clear()
    module._search_index_cache_sizes.clear()
    module._search_index_access_order.clear()

    for source_id in ("source-a", "source-b", "source-c"):
        paths = module.get_source_paths(source_id)
        paths["root"].mkdir(parents=True, exist_ok=True)
        payload = {
            "version": 1,
            "sessions": [
                {"key": source_id, "title": source_id, "cwd": "M:/Demo", "path": source_id + ".jsonl", "searchText": source_id + " needle " + ("x" * 180)}
            ]
        }
        paths["search"].write_text(json.dumps(payload), encoding="utf-8")
        module.search_sessions("needle", source_id)

    print(json.dumps({
        "cached": list(module._search_index_cache.keys()),
        "sizes": dict(module._search_index_cache_sizes),
        "hitsC": [row["key"] for row in module.search_sessions("needle", "source-c")]
    }))
'@
        $result = python -c $python $serverScript | ConvertFrom-Json -Depth 20

        ($result.cached -contains 'source-a') | Should Be $false
        ($result.cached -contains 'source-c') | Should Be $true
        ($result.hitsC -join ',') | Should Be 'source-c'
    }

    It 'sets a recognizable title on the opened cmd window' {
        $openCmd = Get-Content -LiteralPath (Join-Path $projectRoot 'Open-CodexChatIndex.cmd') -Raw
        $openCmd | Should Match '(?mi)^title Open-CodexChatIndex V0\.26 - Local Server Running'
        $openCmd | Should Match "root / 'temp'"
        $openCmd | Should Match "root\.parent / '\\u8fd0\\u884c\\u6570\\u636e'"
        $openCmd | Should Match "root\.parent / '\\u5916\\u90e8\\u804a\\u5929\\u8bb0\\u5f55'"
        $openCmd | Should Match 'CodexChatIndexServer\.py'
        $openCmd | Should Match '(?mi)^if errorlevel 1 \('
        $openCmd | Should Match '(?mi)^\s*pause\s*$'
    }

    It 'build cmd defaults runtime data to the shared data root' {
        $buildCmd = Get-Content -LiteralPath (Join-Path $projectRoot 'Build-CodexChatIndex.cmd') -Raw
        $buildCmd | Should Match '(?i)-DataRoot\s+"%~dp0\.\.\\运行数据"'
        $buildCmd | Should Not Match '(?i)-OutputPath'
        (Get-Content -LiteralPath $buildScript -Raw) | Should Match '\$OutputPath = Join-Path \(Join-Path \$PSScriptRoot ''temp''\) ''CodexChatIndex\.html'''
    }

    It 'keeps the cmd launcher ASCII-only so cmd.exe does not misparse UTF-8 Chinese bytes' {
        $openCmd = Get-Content -LiteralPath (Join-Path $projectRoot 'Open-CodexChatIndex.cmd') -Raw
        $openCmd | Should Not Match '[^\u0000-\u007F]'
    }

    AfterAll {
        Remove-Item -LiteralPath $tempRoot -Force -Recurse
        if ($null -eq $previousPythonDontWriteBytecode) {
            Remove-Item Env:\PYTHONDONTWRITEBYTECODE -ErrorAction SilentlyContinue
        } else {
            $env:PYTHONDONTWRITEBYTECODE = $previousPythonDontWriteBytecode
        }
    }
}








