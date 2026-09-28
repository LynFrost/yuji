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
        & $buildScript -CodexHome $fixtureHome -OutputPath $outputPath -DataRoot $tempRoot -MachineName 'Demo-PC' | Out-Null
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
        $otherSearchIndexPath = Join-Path $defaultSourceRoot 'CodexChatIndex.search.other.json'
        $script:otherSearchIndexPath = $otherSearchIndexPath
        $script:otherSearchIndex = if (Test-Path -LiteralPath $otherSearchIndexPath -PathType Leaf) {
            Get-Content -LiteralPath $otherSearchIndexPath -Raw | ConvertFrom-Json -Depth 100
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

    It 'writes physically split V0.30 question and other search indexes without duplicated text' {
        (Test-Path -LiteralPath $searchIndexPath -PathType Leaf) | Should Be $true
        (Test-Path -LiteralPath $otherSearchIndexPath -PathType Leaf) | Should Be $true
        $searchIndex.version | Should Be 4
        $searchIndex.part | Should Be 'questions'
        $otherSearchIndex.version | Should Be 4
        $otherSearchIndex.part | Should Be 'other'
        $searchIndex.sessions.Count | Should BeGreaterThan 1

        $fixtureSearch = @($searchIndex.sessions | Where-Object { $_.id -eq $fixtureSessionId } | Select-Object -First 1)
        $fixtureOtherSearch = @($otherSearchIndex.sessions | Where-Object { $_.key -eq $fixtureSearch.key } | Select-Object -First 1)
        $fixtureSearch | Should Not BeNullOrEmpty
        $fixtureOtherSearch | Should Not BeNullOrEmpty
        @($fixtureSearch.questionTexts).Count | Should Be 1
        @($fixtureSearch.questionTexts)[0] | Should Match '请检查 `Build-CodexChatIndex\.ps1`'
        $fixtureSearch.questionTexts -join "`n" | Should Not Match 'line 2|我已经定位到阅读器逻辑'
        ($fixtureSearch.PSObject.Properties.Name -contains 'otherText') | Should Be $false
        $fixtureOtherSearch.otherText | Should Match 'line 2'
        $fixtureOtherSearch.otherText | Should Match '我已经定位到阅读器逻辑'
        ($fixtureOtherSearch.PSObject.Properties.Name -contains 'questionTexts') | Should Be $false
        ($fixtureSearch.PSObject.Properties.Name -contains 'searchText') | Should Be $false

        (($sessionIndex | ConvertTo-Json -Depth 20 -Compress) -match '"searchText"') | Should Be $false
    }

    It 'boots from the lightweight index instead of embedding full app data' {
        $html | Should Match "const INDEX_URL = './CodexChatIndex\.sources/local-codex/CodexChatIndex\.data\.json';"
        $html | Should Match 'async function loadIndex\(\)'
        $html | Should Match 'async function loadSessionDetail\(session\)'
        $html | Should Not Match '<script id="app-data" type="application/json">'
    }

    It 'renders the streamlined V0.34 Yuji brand without renaming internal files' {
        $html | Should Match '<title>语迹</title>'
        $html | Should Match '<h1>语迹 <span class="version-badge">V0\.34</span></h1>'
        $html | Should Not Match 'app-subtitle'
        $html | Should Not Match '>AI 对话记录浏览器<'
        (Get-Content -LiteralPath (Join-Path $projectRoot 'README.md') -Raw) | Should Match 'AI 对话记录浏览器'
        $html | Should Match "const INDEX_URL = './CodexChatIndex\.sources/local-codex/CodexChatIndex\.data\.json';"
        (Test-Path -LiteralPath (Join-Path $projectRoot 'CodexChatIndex.html') -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath $buildScript -PathType Leaf) | Should Be $true
    }

    It 'uses V0.34 builder and visible version markers' {
        $buildSource = Get-Content -LiteralPath $buildScript -Raw

        $html | Should Match '<span class="version-badge">V0\.34</span>'
        $buildSource | Should Match '\$builderVersion = "V0\.34"'
        $html | Should Not Match '<span class="version-badge">V0\.30</span>'
        $buildSource | Should Not Match '\$builderVersion = "V0\.30"'
        $html | Should Not Match '<span class="version-badge">V0\.29</span>'
        $buildSource | Should Not Match '\$builderVersion = "V0\.29"'
        $html | Should Not Match '<span class="version-badge">V0\.28</span>'
        $buildSource | Should Not Match '\$builderVersion = "V0\.28"'
        $html | Should Not Match '<span class="version-badge">V0\.27</span>'
        $buildSource | Should Not Match '\$builderVersion = "V0\.27"'
        $html | Should Not Match '<span class="version-badge">V0\.26</span>'
        $buildSource | Should Not Match '\$builderVersion = "V0\.26"'
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

    It 'uses a single V0.34 HTML template source without PowerShell interpolation leftovers' {
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

        & (Join-Path $versionRoot 'Build-CodexChatIndex.ps1') -CodexHome $fixtureHome -MachineName 'Demo-PC' | Out-Null

        $versionHtmlPath = Join-Path (Join-Path $versionRoot 'temp') 'CodexChatIndex.html'
        $sourceRoot = Join-Path $layoutRoot '运行数据\CodexChatIndex.sources\local-codex'
        $sourceManifestPath = Join-Path $layoutRoot '运行数据\CodexChatIndex.sources.json'
        $sharedDataPath = Join-Path $sourceRoot 'CodexChatIndex.data.json'
        $sharedSearchPath = Join-Path $sourceRoot 'CodexChatIndex.search.json'
        $sharedOtherSearchPath = Join-Path $sourceRoot 'CodexChatIndex.search.other.json'
        $sharedCachePath = Join-Path $sourceRoot 'CodexChatIndex.cache.json'
        $sharedDetailRoot = Join-Path $sourceRoot 'CodexChatIndex.sessions'
        (Test-Path -LiteralPath $versionHtmlPath -PathType Leaf) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $versionRoot 'CodexChatIndex.html') -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath $sourceManifestPath -PathType Leaf) | Should Be $true
        (Test-Path -LiteralPath $sharedDataPath -PathType Leaf) | Should Be $true
        (Test-Path -LiteralPath $sharedSearchPath -PathType Leaf) | Should Be $true
        (Test-Path -LiteralPath $sharedOtherSearchPath -PathType Leaf) | Should Be $true
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
        $sharedIndex.source.label | Should Be 'Demo-PC-本机 Codex'
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

    It 'keeps the V0.34 source directory free of generated runtime artifacts' {
        foreach ($artifact in @(
            'CodexChatIndex.html',
            'CodexChatIndex.data.json',
            'CodexChatIndex.search.json',
            'CodexChatIndex.search.other.json',
            'CodexChatIndex.cache.json',
            'CodexChatIndex.sessions',
            '.playwright-mcp',
            '__pycache__'
        )) {
            Test-Path -LiteralPath (Join-Path $projectRoot $artifact) | Should Be $false
        }
    }

    It 'stores the V0.34 version marker in a dedicated source file' {
        $versionFile = Join-Path $projectRoot 'VERSION_V0.34.txt'
        (Test-Path -LiteralPath $versionFile -PathType Leaf) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $projectRoot 'VERSION_V0.33.txt') -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $projectRoot 'VERSION_V0.32.txt') -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $projectRoot 'VERSION_V0.31.txt') -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $projectRoot 'VERSION_V0.30.txt') -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $projectRoot 'VERSION_V0.29.txt') -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $projectRoot 'VERSION_V0.27.txt') -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $projectRoot 'VERSION_V0.26.txt') -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $projectRoot 'VERSION_V0.25.txt') -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $projectRoot 'VERSION_V0.24.txt') -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $projectRoot 'VERSION_V0.23.txt') -PathType Leaf) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $projectRoot 'VERSION_V0.28.txt') -PathType Leaf) | Should Be $false
        (Get-Content -LiteralPath $versionFile -Raw).Trim() | Should Be 'V0.34'
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
            -MachineName 'Demo-PC' `
            -ClaudeHome $claudeHome `
            -ClaudeScanRoots @((Join-Path $claudeHome 'projects')) `
            -RefreshMode Full `
            -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json

        $sourceRoot = Join-Path $dataRoot 'CodexChatIndex.sources\local-claude'
        $claudeIndex = Get-Content -LiteralPath (Join-Path $sourceRoot 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $claudeSearch = Get-Content -LiteralPath (Join-Path $sourceRoot 'CodexChatIndex.search.json') -Raw | ConvertFrom-Json -Depth 100
        $claudeOtherSearch = Get-Content -LiteralPath (Join-Path $sourceRoot 'CodexChatIndex.search.other.json') -Raw | ConvertFrom-Json -Depth 100
        $claudeSession = @($claudeIndex.workspaces | ForEach-Object { @($_.sessions) } | Select-Object -First 1)[0]
        $claudeDetailPath = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $claudeHtmlPath) ([string]$claudeSession.detailHref)))
        $claudeDetail = Get-Content -LiteralPath $claudeDetailPath -Raw | ConvertFrom-Json -Depth 100

        $summary.scannedCount | Should Be 1
        $summary.parsedCount | Should Be 1
        $claudeIndex.source.id | Should Be 'local-claude'
        $claudeIndex.source.label | Should Be 'Demo-PC-本机 Claude'
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
        $claudeSearch.sessions[0].questionTexts -join "`n" | Should Match 'Claude first question'
        $claudeOtherSearch.sessions[0].otherText | Should Match 'Claude final answer'
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
            -MachineName 'Demo-PC' `
            -ClaudeHome $claudeHome `
            -ClaudeScanRoots @((Join-Path $claudeHome 'projects'), (Join-Path $profileRoot 'AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p\local-agent-mode-sessions'), (Join-Path $profileRoot 'AppData\Roaming\Code\User\workspaceStorage')) `
            -RefreshMode Full `
            -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json

        $sourceRoot = Join-Path $dataRoot 'CodexChatIndex.sources\local-claude'
        $claudeIndex = Get-Content -LiteralPath (Join-Path $sourceRoot 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $claudeSearch = Get-Content -LiteralPath (Join-Path $sourceRoot 'CodexChatIndex.search.json') -Raw | ConvertFrom-Json -Depth 100
        $claudeOtherSearch = Get-Content -LiteralPath (Join-Path $sourceRoot 'CodexChatIndex.search.other.json') -Raw | ConvertFrom-Json -Depth 100
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
        $claudeSearch.sessions.questionTexts -join "`n" | Should Match '桌面 Claude 提问'
        $claudeSearch.sessions.questionTexts -join "`n" | Should Match 'VS Code Claude 提问'
        $claudeOtherSearch.sessions.otherText -join "`n" | Should Match '桌面 Claude 回答'
        $claudeOtherSearch.sessions.otherText -join "`n" | Should Match 'VS Code Claude 回答'
        $claudeOtherSearch.sessions.otherText -join "`n" | Should Not Match 'MCP log only'
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
        $otherSearchPath = Join-Path $noChangeSourceRoot 'CodexChatIndex.search.other.json'
        $cachePath = Join-Path $noChangeSourceRoot 'CodexChatIndex.cache.json'
        $index = Get-Content -LiteralPath $dataPath -Raw | ConvertFrom-Json -Depth 100
        $detailPath = [System.IO.Path]::GetFullPath((Join-Path $noChangeRoot ([string]$index.workspaces[0].sessions[0].detailHref)))
        $beforeTimes = @{
            Html = (Get-Item -LiteralPath $noChangeOutputPath).LastWriteTimeUtc
            Data = (Get-Item -LiteralPath $dataPath).LastWriteTimeUtc
            Search = (Get-Item -LiteralPath $searchPath).LastWriteTimeUtc
            OtherSearch = (Get-Item -LiteralPath $otherSearchPath).LastWriteTimeUtc
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
        (Get-Item -LiteralPath $otherSearchPath).LastWriteTimeUtc | Should Be $beforeTimes.OtherSearch
        (Get-Item -LiteralPath $cachePath).LastWriteTimeUtc | Should Be $beforeTimes.Cache
        (Get-Item -LiteralPath $detailPath).LastWriteTimeUtc | Should Be $beforeTimes.Detail
    }

    It 'repairs stale generated html without reparsing unchanged chat records' {
        $staleRoot = Join-Path $tempRoot 'incremental-stale-html'
        $staleOutputPath = Join-Path $staleRoot 'CodexChatIndex.html'
        New-Item -ItemType Directory -Force $staleRoot | Out-Null

        & $buildScript -CodexHome $fixtureHome -OutputPath $staleOutputPath -DataRoot $staleRoot -RefreshMode Full -JsonSummary | Out-Null
        $staleSourceRoot = Get-TestSourceRoot $staleRoot
        $dataPath = Join-Path $staleSourceRoot 'CodexChatIndex.data.json'
        $searchPath = Join-Path $staleSourceRoot 'CodexChatIndex.search.json'
        $otherSearchPath = Join-Path $staleSourceRoot 'CodexChatIndex.search.other.json'
        $cachePath = Join-Path $staleSourceRoot 'CodexChatIndex.cache.json'
        $index = Get-Content -LiteralPath $dataPath -Raw | ConvertFrom-Json -Depth 100
        $detailPath = [System.IO.Path]::GetFullPath((Join-Path $staleRoot ([string]$index.workspaces[0].sessions[0].detailHref)))
        $beforeTimes = @{
            Data = (Get-Item -LiteralPath $dataPath).LastWriteTimeUtc
            Search = (Get-Item -LiteralPath $searchPath).LastWriteTimeUtc
            OtherSearch = (Get-Item -LiteralPath $otherSearchPath).LastWriteTimeUtc
            Cache = (Get-Item -LiteralPath $cachePath).LastWriteTimeUtc
            Detail = (Get-Item -LiteralPath $detailPath).LastWriteTimeUtc
        }
        $staleHtml = (Get-Content -LiteralPath $staleOutputPath -Raw).Replace('<title>语迹</title>', '<title>旧页面</title>')
        [System.IO.File]::WriteAllText($staleOutputPath, $staleHtml, [System.Text.UTF8Encoding]::new($false))

        Start-Sleep -Milliseconds 1200

        $summary = (& $buildScript -CodexHome $fixtureHome -OutputPath $staleOutputPath -DataRoot $staleRoot -RefreshMode Incremental -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json
        $repairedHtml = Get-Content -LiteralPath $staleOutputPath -Raw

        $summary.mode | Should Be 'Incremental'
        $summary.noChange | Should Be $true
        $summary.skippedWrite | Should Be $false
        $summary.htmlUpdated | Should Be $true
        $summary.parsedCount | Should Be 0
        $summary.reusedCount | Should Be 2
        $summary.notice | Should Match '已同步页面模板'
        $repairedHtml | Should Match '<title>语迹</title>'
        $repairedHtml | Should Not Match '<title>旧页面</title>'
        (Get-Item -LiteralPath $dataPath).LastWriteTimeUtc | Should Be $beforeTimes.Data
        (Get-Item -LiteralPath $searchPath).LastWriteTimeUtc | Should Be $beforeTimes.Search
        (Get-Item -LiteralPath $otherSearchPath).LastWriteTimeUtc | Should Be $beforeTimes.OtherSearch
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
        $otherSearchPath = Join-Path $missingSourceRoot 'CodexChatIndex.search.other.json'
        $index = Get-Content -LiteralPath $dataPath -Raw | ConvertFrom-Json -Depth 100
        $detailPath = [System.IO.Path]::GetFullPath((Join-Path $missingRoot ([string]$index.workspaces[0].sessions[0].detailHref)))
        Remove-Item -LiteralPath $dataPath -Force

        $summaryMissingData = (& $buildScript -CodexHome $fixtureHome -OutputPath $missingOutputPath -DataRoot $missingRoot -RefreshMode Incremental -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json
        $summaryMissingData.noChange | Should Not Be $true
        $summaryMissingData.skippedWrite | Should Not Be $true
        $summaryMissingData.parsedCount | Should Be 0
        (Test-Path -LiteralPath $dataPath -PathType Leaf) | Should Be $true

        Remove-Item -LiteralPath $otherSearchPath -Force
        $summaryMissingOtherSearch = (& $buildScript -CodexHome $fixtureHome -OutputPath $missingOutputPath -DataRoot $missingRoot -RefreshMode Incremental -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json
        $summaryMissingOtherSearch.noChange | Should Not Be $true
        $summaryMissingOtherSearch.skippedWrite | Should Not Be $true
        $summaryMissingOtherSearch.parsedCount | Should Be 0
        (Test-Path -LiteralPath $otherSearchPath -PathType Leaf) | Should Be $true

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
        $imageRecord = @($imageDetail.events[0].images)[0]
        $imageRecord.type | Should Be 'managed'
        $imageRecord.assetId | Should Match '^[0-9a-f]{64}$'
        $imageRecord.mimeType | Should Be 'image/png'
        ($imageRecord.PSObject.Properties.Name -contains 'src') | Should Be $false
        $managedObjectPath = Join-Path $imageRoot ('CodexChatIndex.images\objects\' + $imageRecord.assetId.Substring(0, 2) + '\' + $imageRecord.assetId + '.bin')
        (Test-Path -LiteralPath $managedObjectPath -PathType Leaf) | Should Be $true
        $imageDetail.events[0].rawText | Should Be '请看这张图，不要把 base64 放进搜索。'
        ($imageIndex | ConvertTo-Json -Depth 100 -Compress) | Should Not Match 'iVBORw0KGgo'
        ($imageSearch | ConvertTo-Json -Depth 100 -Compress) | Should Not Match 'iVBORw0KGgo'
        $imageHtml | Should Match 'class="message-images"'
        $imageHtml | Should Match 'loading="lazy"'
        $imageHtml | Should Match 'function showImagePreviewAt'
        $imageHtml | Should Match 'function openImagePreviewFromButton'
        $imageHtml | Should Match 'onclick="openImagePreviewFromButton\(this\)"'
        $imageHtml | Should Not Match 'onclick="openImagePreview\('
        $imageHtml | Should Match 'id="imagePreviewModal"'
        $imageHtml | Should Match 'id="imagePreviewImage"'
        $imageHtml | Should Match 'id="imagePreviewClose"'
        $imageHtml | Should Match 'id="imagePreviewPrev"'
        $imageHtml | Should Match 'id="imagePreviewNext"'
        $imageHtml | Should Match 'id="imagePreviewStage"'
        $imageHtml | Should Match 'id="imagePreviewCount"'
        $imageHtml | Should Match 'id="imagePreviewStatus"'
        $imageHtml | Should Not Match 'window\.open\(src'
    }

    It 'renders one responsive image preview control set with protected modal click boundaries' {
        foreach ($id in @('imagePreviewPrev', 'imagePreviewNext', 'imagePreviewStage', 'imagePreviewCount', 'imagePreviewStatus')) {
            ([regex]::Matches($html, 'id="' + $id + '"')).Count | Should Be 1
        }
        $html | Should Match 'id="imagePreviewCount" class="image-preview-count" aria-live="polite" hidden'
        $html | Should Match '\.image-preview-stage \{[\s\S]*?position: relative'
        $html | Should Match '\.image-preview-nav \{[\s\S]*?position: absolute[\s\S]*?top: 50%[\s\S]*?min-width: 44px[\s\S]*?min-height: 44px'
        $html | Should Match '\.image-preview-nav--prev \{[\s\S]*?left: 18px'
        $html | Should Match '\.image-preview-nav--next \{[\s\S]*?right: 18px'
        $html | Should Match '@media \(max-width: 640px\) \{[\s\S]*?\.image-preview-nav--prev \{ left: 8px; \}[\s\S]*?\.image-preview-nav--next \{ right: 8px; \}'
        $html | Should Match '\.image-preview-count \{[\s\S]*?position: absolute[\s\S]*?left: 50%[\s\S]*?bottom: 10px'
        $html | Should Match "event\.target\.closest\(\s*'#imagePreviewImage, #imagePreviewPrev, #imagePreviewNext, #imagePreviewCount, #imagePreviewClose'"
        $html | Should Match "document\.addEventListener\('keydown', handleImagePreviewKeydown, true\)"
    }

    It 'renders a stable V0.30 image zoom stage and scoped pointer controls' {
        $html | Should Match '\.image-preview-stage \{[\s\S]*?width:[\s\S]*?height:[\s\S]*?overflow: hidden[\s\S]*?touch-action: none'
        $html | Should Match '\.image-preview-stage img \{[\s\S]*?user-select: none[\s\S]*?will-change: transform'
        $html | Should Match '\.image-preview-stage\.is-zoomed \{[\s\S]*?cursor: grab'
        $html | Should Match '\.image-preview-stage\.is-dragging \{[\s\S]*?cursor: grabbing'
        $html | Should Match 'const IMAGE_PREVIEW_MIN_SCALE = 0\.25'
        $html | Should Match 'const IMAGE_PREVIEW_MAX_SCALE = 5'
        $html | Should Match 'function resetImagePreviewTransform\('
        $html | Should Match 'function applyImagePreviewTransform\('
        $html | Should Match 'function queueImagePreviewZoom\('
        $html | Should Match 'function clampImagePreviewTranslation\('
        $html | Should Match "imagePreviewStage\.addEventListener\('wheel', queueImagePreviewZoom, \{ passive: false \}\)"
        $html | Should Match 'setPointerCapture\(event\.pointerId\)'
        $html | Should Match 'releasePointerCapture\(pointerId\)'
        $html | Should Match "imagePreviewImage\.addEventListener\('dragstart'"
    }

    It 'switches only within the current question image group and clears preview state on close' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/let imagePreviewTrigger = null;[\s\S]*?\n    function renderEventImages\(event\) \{/);
if (!match) throw new Error("image preview helpers not found");
let closeFocused = 0;
const imagePreviewClose = { focus() { closeFocused++; } };
const imagePreviewModal = { hidden: true };
const imagePreviewImage = { src: "", alt: "", hidden: false, style: {}, offsetWidth: 800, offsetHeight: 600 };
const imagePreviewPrev = { hidden: true, disabled: false };
const imagePreviewNext = { hidden: true, disabled: false };
const imagePreviewStage = {
  clientWidth: 1000,
  clientHeight: 700,
  classList: { toggle() {} },
  getBoundingClientRect() { return { left: 0, top: 0, width: 1000, height: 700 }; },
  hasPointerCapture() { return false; },
  releasePointerCapture() {}
};
const imagePreviewCount = { hidden: true, textContent: "" };
const imagePreviewStatus = { hidden: true, textContent: "" };
const document = {
  contains(element) { return !!element && element.isConnected !== false; }
};
function requestAnimationFrame(callback) { callback(); return 1; }
function cancelAnimationFrame() {}
eval(match[0].replace(/\n    function renderEventImages\(event\) \{$/, "") + `
function inspectImagePreviewState() {
  return { items: imagePreviewItems.slice(), index: imagePreviewIndex, trigger: imagePreviewTrigger };
}`);

function makeButton(src, alt) {
  const image = {
    src,
    currentSrc: src,
    alt,
    hidden: false,
    getAttribute(name) { return name === "src" ? src : ""; }
  };
  return {
    disabled: false,
    isConnected: true,
    focusCount: 0,
    image,
    querySelector(selector) { return selector === "img" ? image : null; },
    getAttribute(name) { return name === "title" ? alt : ""; },
    closest(selector) { return selector === ".message-images" ? this.group : null; },
    focus() { this.focusCount++; }
  };
}
function makeGroup(buttons) {
  const group = {
    querySelectorAll(selector) {
      return selector === ".message-image-button:not(:disabled)" ? buttons.filter(button => !button.disabled) : [];
    }
  };
  buttons.forEach(button => { button.group = group; });
  return group;
}
function keyEvent(key) {
  return {
    key,
    prevented: 0,
    stopped: 0,
    preventDefault() { this.prevented++; },
    stopPropagation() { this.stopped++; }
  };
}

const first = makeButton("image-1", "查看图片 1");
const second = makeButton("image-2", "查看图片 2");
const third = makeButton("image-3", "查看图片 3");
const disabled = makeButton("image-disabled", "禁用图片");
disabled.disabled = true;
makeGroup([first, second, third, disabled]);
const other = makeButton("other-question", "其他提问图片");
makeGroup([other]);

openImagePreviewFromButton(second);
const openedState = inspectImagePreviewState();
const opened = {
  hidden: imagePreviewModal.hidden,
  itemCount: openedState.items.length,
  index: openedState.index,
  src: imagePreviewImage.src,
  count: imagePreviewCount.textContent,
  prevDisabled: imagePreviewPrev.disabled,
  nextDisabled: imagePreviewNext.disabled,
  includesOtherQuestion: openedState.items.includes(other),
  closeFocused
};
const right = keyEvent("ArrowRight");
handleImagePreviewKeydown(right);
const afterRightState = inspectImagePreviewState();
const afterRight = {
  index: afterRightState.index,
  src: imagePreviewImage.src,
  triggerIsThird: afterRightState.trigger === third,
  nextDisabled: imagePreviewNext.disabled,
  count: imagePreviewCount.textContent,
  prevented: right.prevented,
  stopped: right.stopped
};
const boundary = showImagePreviewAt(3);
closeImagePreview();
const closedState = inspectImagePreviewState();
const closed = {
  hidden: imagePreviewModal.hidden,
  src: imagePreviewImage.src,
  alt: imagePreviewImage.alt,
  itemCount: closedState.items.length,
  index: closedState.index,
  triggerCleared: closedState.trigger === null,
  thirdFocused: third.focusCount
};
const single = makeButton("single-image", "单图");
makeGroup([single]);
openImagePreviewFromButton(single);
const singleState = {
  prevHidden: imagePreviewPrev.hidden,
  nextHidden: imagePreviewNext.hidden,
  countHidden: imagePreviewCount.hidden
};
console.log(JSON.stringify({ opened, afterRight, boundary, closed, singleState }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.opened.hidden | Should Be $false
        $result.opened.itemCount | Should Be 3
        $result.opened.index | Should Be 1
        $result.opened.src | Should Be 'image-2'
        $result.opened.count | Should Be '2 / 3'
        $result.opened.prevDisabled | Should Be $false
        $result.opened.nextDisabled | Should Be $false
        $result.opened.includesOtherQuestion | Should Be $false
        $result.opened.closeFocused | Should Be 1
        $result.afterRight.index | Should Be 2
        $result.afterRight.src | Should Be 'image-3'
        $result.afterRight.triggerIsThird | Should Be $true
        $result.afterRight.nextDisabled | Should Be $true
        $result.afterRight.count | Should Be '3 / 3'
        $result.afterRight.prevented | Should Be 1
        $result.afterRight.stopped | Should Be 1
        $result.boundary | Should Be $false
        $result.closed.hidden | Should Be $true
        $result.closed.src | Should Be ''
        $result.closed.alt | Should Be ''
        $result.closed.itemCount | Should Be 0
        $result.closed.index | Should Be -1
        $result.closed.triggerCleared | Should Be $true
        $result.closed.thirdFocused | Should Be 1
        $result.singleState.prevHidden | Should Be $true
        $result.singleState.nextHidden | Should Be $true
        $result.singleState.countHidden | Should Be $true
    }

    It 'zooms around the pointer and drags V0.30 previews without leaking animation state' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/let imagePreviewTrigger = null;[\s\S]*?\n    function renderEventImages\(event\) \{/);
if (!match) throw new Error("image preview helpers not found");
let frameSerial = 0;
const frames = new Map();
function requestAnimationFrame(callback) { const id = ++frameSerial; frames.set(id, callback); return id; }
function cancelAnimationFrame(id) { frames.delete(id); }
function flushFrames() {
  const pending = Array.from(frames.entries());
  frames.clear();
  pending.forEach(([, callback]) => callback());
}
const stageClasses = new Set();
const captures = new Set();
let captureCount = 0;
let releaseCount = 0;
const imagePreviewClose = { focus() {} };
const imagePreviewModal = { hidden: false };
const imagePreviewImage = {
  src: "preview-image",
  alt: "preview",
  hidden: false,
  style: {},
  offsetWidth: 600,
  offsetHeight: 700
};
const imagePreviewPrev = { hidden: true, disabled: false };
const imagePreviewNext = { hidden: true, disabled: false };
const imagePreviewStage = {
  clientWidth: 1000,
  clientHeight: 700,
  classList: {
    toggle(name, active) { if (active) stageClasses.add(name); else stageClasses.delete(name); }
  },
  getBoundingClientRect() { return { left: 0, top: 0, width: 1000, height: 700 }; },
  setPointerCapture(id) { captures.add(id); captureCount++; },
  hasPointerCapture(id) { return captures.has(id); },
  releasePointerCapture(id) { captures.delete(id); releaseCount++; }
};
const imagePreviewCount = { hidden: true, textContent: "" };
const imagePreviewStatus = { hidden: true, textContent: "" };
const document = { contains() { return true; } };
eval(match[0].replace(/\n    function renderEventImages\(event\) \{$/, "") + `
function inspectTransform() { return Object.assign({}, imagePreviewTransform); }
`);

function wheel(deltaY, x = 700, y = 350) {
  return {
    deltaY,
    deltaMode: 0,
    clientX: x,
    clientY: y,
    prevented: 0,
    preventDefault() { this.prevented++; }
  };
}
function pointer(type, x, y, button = 0) {
  return {
    type,
    pointerId: 7,
    isPrimary: true,
    button,
    clientX: x,
    clientY: y,
    prevented: 0,
    preventDefault() { this.prevented++; }
  };
}

resetImagePreviewTransform();
const initial = inspectTransform();
const firstWheel = wheel(-120);
queueImagePreviewZoom(firstWheel);
queueImagePreviewZoom(wheel(-120));
const coalescedFrames = frames.size;
flushFrames();
const zoomed = inspectTransform();
const pointerContentBefore = 200;
const pointerContentAfter = (200 - zoomed.translateX) / zoomed.scale;

for (let index = 0; index < 20; index++) {
  queueImagePreviewZoom(wheel(-1000, 500, 350));
  flushFrames();
}
const maximum = inspectTransform().scale;
for (let index = 0; index < 40; index++) {
  queueImagePreviewZoom(wheel(1000, 500, 350));
  flushFrames();
}
const minimum = inspectTransform().scale;

for (let index = 0; index < 5; index++) {
  queueImagePreviewZoom(wheel(-1000, 500, 350));
  flushFrames();
}
const beforeDrag = inspectTransform();
handleImagePreviewPointerDown(pointer("pointerdown", 400, 300));
handleImagePreviewPointerMove(pointer("pointermove", 402, 302));
flushFrames();
const belowThreshold = inspectTransform();
handleImagePreviewPointerMove(pointer("pointermove", 440, 335));
flushFrames();
const dragged = inspectTransform();
handleImagePreviewPointerEnd(pointer("pointerup", 440, 335));
const afterDrag = inspectTransform();
handleImagePreviewPointerDown(pointer("pointerdown", 400, 300, 2));
const nonPrimaryCaptureCount = captureCount;

queueImagePreviewZoom(wheel(-120));
const pendingBeforeReset = frames.size;
resetImagePreviewTransform();
const reset = inspectTransform();

console.log(JSON.stringify({
  initial,
  firstWheelPrevented: firstWheel.prevented,
  coalescedFrames,
  zoomed,
  pointerDelta: Math.abs(pointerContentAfter - pointerContentBefore),
  maximum,
  minimum,
  beforeDrag,
  belowThreshold,
  dragged,
  afterDrag,
  captureCount,
  releaseCount,
  nonPrimaryCaptureCount,
  pendingBeforeReset,
  pendingAfterReset: frames.size,
  reset,
  transform: imagePreviewImage.style.transform,
  zoomClass: stageClasses.has("is-zoomed"),
  dragClass: stageClasses.has("is-dragging")
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20

        $result.initial.scale | Should Be 1
        $result.initial.translateX | Should Be 0
        $result.initial.translateY | Should Be 0
        $result.firstWheelPrevented | Should Be 1
        $result.coalescedFrames | Should Be 1
        $result.zoomed.scale | Should BeGreaterThan 1
        $result.pointerDelta | Should BeLessThan 0.01
        $result.maximum | Should Be 5
        $result.minimum | Should Be 0.25
        $result.belowThreshold.dragMoved | Should Be $false
        $result.belowThreshold.translateX | Should Be $result.beforeDrag.translateX
        $result.dragged.dragMoved | Should Be $true
        $result.dragged.translateX | Should Not Be $result.beforeDrag.translateX
        $result.afterDrag.pointerId | Should BeNullOrEmpty
        $result.captureCount | Should Be 1
        $result.releaseCount | Should Be 1
        $result.nonPrimaryCaptureCount | Should Be 1
        $result.pendingBeforeReset | Should Be 1
        $result.pendingAfterReset | Should Be 0
        $result.reset.scale | Should Be 1
        $result.reset.translateX | Should Be 0
        $result.reset.translateY | Should Be 0
        $result.transform | Should Be 'translate3d(0px, 0px, 0) scale(1)'
        $result.zoomClass | Should Be $false
        $result.dragClass | Should Be $false
    }

    It 'renders V0.27 registered local image URLs and explicit failure states' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function getEventImageSource\(image\) \{[\s\S]*?\n    \}(?=\n\n    function isExplicitQuoteBlock)/);
if (!match) throw new Error("V0.27 image render helpers not found");
const SESSION_IMAGE_API_URL = "/api/session-image";
const MAX_FAILED_MESSAGE_IMAGE_KEYS = 128;
const failedMessageImageKeys = new Map();
function escapeHtml(value) { return String(value || "").replace(/&/g, "&amp;"); }
function getCurrentSourceId() { return "local-codex"; }
function getSelectedSession() { return { key: "session key" }; }
function getSessionKey(session) { return session.key; }
eval(match[0]);
console.log(JSON.stringify({
  local: renderEventImages({ images: [{ type: "local", imageId: "image/id" }] }),
  huge: renderEventImages({ images: [{ type: "local", imageId: "huge", status: "too-large" }] }),
  remote: renderEventImages({ images: [{ type: "url", src: "https://example.test/a.png" }] })
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10
        $result.local | Should Match '/api/session-image\?sourceId=local-codex&amp;sessionKey=session%20key&amp;imageId=image%2Fid'
        $result.local | Should Match 'loading="lazy"'
        $result.local | Should Match 'onerror="handleMessageImageError\(this\)"'
        $result.local | Should Not Match 'localPath'
        $result.huge | Should Match '图片过大，无法预览'
        $result.huge | Should Not Match '<img'
        $result.remote | Should Match 'https://example\.test/a\.png'
    }

    It 'does not retry a failed message image after viewer rerender' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function getEventImageSource\(image\) \{[\s\S]*?\n    \}(?=\n\n    function isExplicitQuoteBlock)/);
if (!match) throw new Error("V0.27 image render helpers not found");
const SESSION_IMAGE_API_URL = "/api/session-image";
const MAX_FAILED_MESSAGE_IMAGE_KEYS = 128;
const failedMessageImageKeys = new Map();
function escapeHtml(value) { return String(value || "").replace(/&/g, "&amp;"); }
function getCurrentSourceId() { return "local-codex"; }
function getSelectedSession() { return { key: "session key" }; }
function getSessionKey(session) { return session.key; }
eval(match[0]);

const imageRecord = { type: "url", src: "https://example.test/missing.png" };
const firstMarkup = renderEventImages({ images: [imageRecord] });
const failureKey = getMessageImageFailureKey(imageRecord, imageRecord.src);
const status = { hidden: true };
const button = {
  disabled: false,
  querySelector(selector) {
    return selector === ".message-image-status" ? status : null;
  },
  removeAttribute(name) {
    if (name === "onclick") this.onclickRemoved = true;
  }
};
const image = {
  hidden: false,
  currentSrc: imageRecord.src,
  src: imageRecord.src,
  getAttribute(name) {
    if (name === "data-image-failure-key") return failureKey;
    return name === "src" ? imageRecord.src : "";
  },
  closest(selector) {
    return selector === ".message-image-button" ? button : null;
  }
};
handleMessageImageError(image);
const secondMarkup = renderEventImages({ images: [imageRecord] });
console.log(JSON.stringify({
  firstMarkup,
  secondMarkup,
  remembered: failedMessageImageKeys.has(failureKey),
  currentHidden: image.hidden,
  statusHidden: status.hidden,
  buttonDisabled: button.disabled
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10
        $result.firstMarkup | Should Match '<img'
        $result.remembered | Should Be $true
        $result.secondMarkup | Should Not Match '<img'
        $result.secondMarkup | Should Match '图片无法加载'
        $result.currentHidden | Should Be $true
        $result.statusHidden | Should Be $false
        $result.buttonDisabled | Should Be $true
    }

    It 'bounds failed image keys, scopes them by session, and avoids retaining data URLs' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function getEventImageSource\(image\) \{[\s\S]*?\n    \}(?=\n\n    function isExplicitQuoteBlock)/);
if (!match) throw new Error("V0.27 image cache helpers not found");
const SESSION_IMAGE_API_URL = "/api/session-image";
const MAX_FAILED_MESSAGE_IMAGE_KEYS = 3;
const failedMessageImageKeys = new Map();
let currentSourceId = "local-codex";
let selectedSession = { key: "session-a" };
function escapeHtml(value) { return String(value || "").replace(/&/g, "&amp;"); }
function getCurrentSourceId() { return currentSourceId; }
function getSelectedSession() { return selectedSession; }
function getSessionKey(session) { return session.key; }
eval(match[0]);

const remote = { type: "url", src: "https://example.test/image.png" };
const sessionAKey = getMessageImageFailureKey(remote, remote.src);
rememberFailedMessageImage(sessionAKey);
const failedInSessionA = renderEventImages({ images: [remote] });
selectedSession = { key: "session-b" };
const sessionBKey = getMessageImageFailureKey(remote, remote.src);
const retriedInSessionB = renderEventImages({ images: [remote] });

const largeDataUrl = "data:image/png;base64," + "A".repeat(12000);
const dataKey = getMessageImageFailureKey({ type: "url", src: largeDataUrl }, largeDataUrl);
const inserted = [];
for (let index = 0; index < 5; index += 1) {
  const key = getMessageImageFailureKey({ type: "url", src: "https://example.test/" + index + ".png" }, "https://example.test/" + index + ".png");
  inserted.push(key);
  rememberFailedMessageImage(key);
}
const bounded = {
  size: failedMessageImageKeys.size,
  oldestRetained: failedMessageImageKeys.has(inserted[0]),
  newestRetained: failedMessageImageKeys.has(inserted[4])
};
clearFailedMessageImageCache();
console.log(JSON.stringify({
  sessionAKey,
  sessionBKey,
  failedInSessionA,
  retriedInSessionB,
  dataKey,
  dataKeyLength: dataKey.length,
  dataPayloadRetained: dataKey.includes("A".repeat(100)),
  bounded,
  sizeAfterClear: failedMessageImageKeys.size
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10
        $result.sessionAKey | Should Not Be $result.sessionBKey
        $result.failedInSessionA | Should Not Match '<img'
        $result.retriedInSessionB | Should Match '<img'
        $result.dataKey | Should Match 'data:'
        [int]$result.dataKeyLength | Should BeLessThan 200
        $result.dataPayloadRetained | Should Be $false
        $result.bounded.size | Should Be 3
        $result.bounded.oldestRetained | Should Be $false
        $result.bounded.newestRetained | Should Be $true
        $result.sizeAfterClear | Should Be 0
    }

    It 'resolves V0.27 Codex structured and text image references without recursive lookup' {
        $imageCwd = Join-Path $tempRoot 'v027-codex-image-cwd'
        $nestedImageDir = Join-Path $imageCwd 'nested'
        New-Item -ItemType Directory -Force $nestedImageDir | Out-Null
        $pixelBytes = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lrWg9QAAAABJRU5ErkJggg==')
        $targetImagePath = Join-Path $imageCwd 'target.png'
        $nestedImagePath = Join-Path $nestedImageDir 'second.webp'
        $unicodeImagePath = Join-Path $imageCwd '中文截图.png'
        $spacedImagePath = Join-Path $imageCwd '含 空格.png'
        [IO.File]::WriteAllBytes($targetImagePath, $pixelBytes)
        [IO.File]::WriteAllBytes($nestedImagePath, $pixelBytes)
        [IO.File]::WriteAllBytes($unicodeImagePath, $pixelBytes)
        [IO.File]::WriteAllBytes($spacedImagePath, $pixelBytes)
        [IO.File]::WriteAllBytes((Join-Path $imageCwd 'second.webp'), $pixelBytes)
        [IO.File]::WriteAllBytes((Join-Path $imageCwd '空格.png'), $pixelBytes)
        New-Item -ItemType Directory -Force (Join-Path $imageCwd 'child') | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $imageCwd 'child\not-recursive.png'), $pixelBytes)

        $codexHome = Join-Path $tempRoot 'v027-codex-image-home'
        $sessionDir = Join-Path $codexHome 'sessions\2026\07\18'
        New-Item -ItemType Directory -Force $sessionDir | Out-Null
        $sessionId = '44444444-4444-4444-4444-444444444444'
        $sessionPath = Join-Path $sessionDir ('rollout-2026-07-18T08-00-00-' + $sessionId + '.jsonl')
        $records = @(
            [ordered]@{
                timestamp = '2026-07-18T08:00:00Z'
                type = 'session_meta'
                payload = [ordered]@{ id = $sessionId; timestamp = '2026-07-18T08:00:00Z'; cwd = $imageCwd; source = 'cli'; model_provider = 'openai'; cli_version = '0.27-test' }
            },
            [ordered]@{
                timestamp = '2026-07-18T08:00:01Z'
                type = 'response_item'
                payload = [ordered]@{
                    type = 'message'
                    role = 'user'
                    content = @(
                        [ordered]@{ type = 'input_text'; text = '请看 ![目标](target.png)、.\nested\second.webp、中文截图.png、"含 空格.png" 和 not-recursive.png。' },
                        [ordered]@{ type = 'input_image'; image_url = $targetImagePath }
                    )
                }
            },
            [ordered]@{ timestamp = '2026-07-18T08:00:02Z'; type = 'event_msg'; payload = [ordered]@{ type = 'agent_message'; phase = 'final_answer'; message = '已查看。' } }
        )
        $records | ForEach-Object { $_ | ConvertTo-Json -Depth 30 -Compress } | Set-Content -LiteralPath $sessionPath -Encoding UTF8

        $runtimeRoot = Join-Path $tempRoot 'v027-codex-image-runtime'
        $htmlPath = Join-Path $runtimeRoot 'CodexChatIndex.html'
        & $buildScript -CodexHome $codexHome -OutputPath $htmlPath -DataRoot $runtimeRoot -RefreshMode Full | Out-Null
        $index = Get-Content -LiteralPath (Join-Path (Get-TestSourceRoot $runtimeRoot) 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $session = @($index.workspaces | ForEach-Object { @($_.sessions) })[0]
        $detail = Get-Content -LiteralPath ([IO.Path]::GetFullPath((Join-Path $runtimeRoot ([string]$session.detailHref)))) -Raw | ConvertFrom-Json -Depth 100
        $images = @($detail.events | Where-Object kind -eq 'user' | Select-Object -First 1).images

        @($images).Count | Should Be 5
        $managed = @($images | Where-Object type -eq 'managed')
        $unavailable = @($images | Where-Object { $_.type -eq 'local' -and $_.status -eq 'unavailable' })
        $expectedAsset = (Get-FileHash -LiteralPath $targetImagePath -Algorithm SHA256).Hash.ToLowerInvariant()
        @($managed).Count | Should Be 4
        @($managed | Where-Object assetId -eq $expectedAsset).Count | Should Be 4
        @($unavailable).Count | Should Be 1
        $unavailable[0].localPath | Should Match 'not-recursive\.png$'
        $unavailable[0].localPath | Should Not Match 'child[\\/]not-recursive\.png$'
        $session.hasImageReference | Should Be $true
    }

    It 'attaches V0.27 Claude base64 URL and local images to the user question' {
        $claudeHome = Join-Path $tempRoot 'v027-claude-image-home'
        $projectRoot = Join-Path $claudeHome 'projects\demo'
        $imageCwd = Join-Path $tempRoot 'v027-claude-image-cwd'
        New-Item -ItemType Directory -Force $projectRoot | Out-Null
        New-Item -ItemType Directory -Force $imageCwd | Out-Null
        $localImagePath = Join-Path $imageCwd 'claude-local.jpg'
        [IO.File]::WriteAllBytes($localImagePath, [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lrWg9QAAAABJRU5ErkJggg=='))
        $sessionId = '55555555-5555-5555-5555-555555555555'
        $sessionPath = Join-Path $projectRoot ($sessionId + '.jsonl')
        $base64Data = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lrWg9QAAAABJRU5ErkJggg=='
        $records = @(
            [ordered]@{
                uuid = $sessionId
                timestamp = '2026-07-18T09:00:00Z'
                type = 'user'
                cwd = $imageCwd
                message = [ordered]@{
                    role = 'user'
                    content = @(
                        [ordered]@{ type = 'text'; text = '请检查这些 Claude 图片。' },
                        [ordered]@{ type = 'image'; source = [ordered]@{ type = 'base64'; media_type = 'image/png'; data = $base64Data } },
                        [ordered]@{ type = 'image'; source = [ordered]@{ type = 'url'; url = 'https://example.test/claude.png' } },
                        [ordered]@{ type = 'image'; source = [ordered]@{ type = 'file'; path = 'claude-local.jpg' } }
                    )
                }
            },
            [ordered]@{ uuid = $sessionId; timestamp = '2026-07-18T09:00:01Z'; type = 'assistant'; message = [ordered]@{ role = 'assistant'; content = @([ordered]@{ type = 'text'; text = '图片已收到。' }) } }
        )
        $records | ForEach-Object { $_ | ConvertTo-Json -Depth 30 -Compress } | Set-Content -LiteralPath $sessionPath -Encoding UTF8

        $runtimeRoot = Join-Path $tempRoot 'v027-claude-image-runtime'
        $htmlPath = Join-Path $runtimeRoot 'CodexChatIndex.html'
        & $buildScript -ClaudeHome $claudeHome -ClaudeScanRoots @((Join-Path $claudeHome 'projects')) -OutputPath $htmlPath -DataRoot $runtimeRoot -SourceId 'local-claude' -SourceType 'local-claude' -RefreshMode Full | Out-Null
        $index = Get-Content -LiteralPath (Join-Path (Get-TestSourceRoot $runtimeRoot 'local-claude') 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $session = @($index.workspaces | ForEach-Object { @($_.sessions) })[0]
        $detail = Get-Content -LiteralPath ([IO.Path]::GetFullPath((Join-Path $runtimeRoot ([string]$session.detailHref)))) -Raw | ConvertFrom-Json -Depth 100
        $images = @($detail.events | Where-Object kind -eq 'user' | Select-Object -First 1).images

        @($images).Count | Should Be 3
        $managed = @($images | Where-Object type -eq 'managed')
        $remote = @($images | Where-Object type -eq 'url')
        $expectedAsset = (Get-FileHash -LiteralPath $localImagePath -Algorithm SHA256).Hash.ToLowerInvariant()
        @($managed).Count | Should Be 2
        @($managed | Where-Object assetId -eq $expectedAsset).Count | Should Be 2
        @($remote).Count | Should Be 1
        $remote[0].src | Should Be 'https://example.test/claude.png'
        $remote[0].status | Should Be 'unavailable'
        $session.hasImageReference | Should Be $true
    }

    It 'serves only registered V0.32 managed image assets and rejects unsafe asset requests' {
        $python = @'
import base64
import hashlib
import importlib.util
import json
import pathlib
import tempfile

spec = importlib.util.spec_from_file_location("codex_server", __import__("sys").argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as tmp_dir:
    root = pathlib.Path(tmp_dir)
    module.RUNTIME_DATA_DIR = root / "runtime"
    module.IMAGE_ASSET_ROOT = module.RUNTIME_DATA_DIR / "CodexChatIndex.images"
    module.IMAGE_OBJECT_ROOT = module.IMAGE_ASSET_ROOT / "objects"
    module.IMAGE_MANIFEST_ROOT = module.IMAGE_ASSET_ROOT / "manifests"
    module.IMAGE_MANIFEST_ROOT.mkdir(parents=True)

    valid_bytes = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lrWg9QAAAABJRU5ErkJggg==")
    valid_id = hashlib.sha256(valid_bytes).hexdigest()
    valid_path = module.IMAGE_OBJECT_ROOT / valid_id[:2] / f"{valid_id}.bin"
    valid_path.parent.mkdir(parents=True)
    valid_path.write_bytes(valid_bytes)

    corrupt_id = "b" * 64
    corrupt_path = module.IMAGE_OBJECT_ROOT / corrupt_id[:2] / f"{corrupt_id}.bin"
    corrupt_path.parent.mkdir(parents=True, exist_ok=True)
    corrupt_path.write_bytes(b"not an image")

    oversized_id = "c" * 64
    manifest = {
        "schemaVersion": 1,
        "protocol": "YujiImageSync/v1",
        "sourceId": "local-codex",
        "assets": [
            {"assetId": valid_id, "mimeType": "image/png", "sizeBytes": len(valid_bytes)},
            {"assetId": corrupt_id, "mimeType": "image/png", "sizeBytes": len(b"not an image")},
            {"assetId": oversized_id, "mimeType": "image/png", "sizeBytes": module.MAX_LOCAL_IMAGE_BYTES + 1},
        ],
    }
    (module.IMAGE_MANIFEST_ROOT / "local-codex.json").write_text(json.dumps(manifest), encoding="utf-8")

    def outcome(asset_id):
        try:
            resolved, mime_type = module.resolve_managed_image_asset("local-codex", asset_id)
            return {"path": str(resolved), "mime": mime_type}
        except Exception as error:
            return {"error": type(error).__name__}

    print(json.dumps({
        "validId": valid_id,
        "ok": outcome(valid_id),
        "corrupt": outcome(corrupt_id),
        "oversized": outcome(oversized_id),
        "unknown": outcome("d" * 64),
        "invalid": outcome("../bad"),
    }))
'@
        $result = python -c $python $serverScript | ConvertFrom-Json -Depth 20
        $result.validId | Should Match '^[0-9a-f]{64}$'
        $result.ok.path | Should Match ([regex]::Escape($result.validId) + '\.bin$')
        $result.ok.mime | Should Be 'image/png'
        $result.corrupt.error | Should Be 'UnsupportedImageError'
        $result.oversized.error | Should Be 'ImageTooLargeError'
        $result.unknown.error | Should Be 'FileNotFoundError'
        $result.invalid.error | Should Be 'ValueError'

        $serverSource = Get-Content -LiteralPath $serverScript -Raw
        $serverSource | Should Match 'if parsed\.path == "/api/image-asset"'
        $serverSource | Should Match 'resolve_managed_image_asset'
        $serverSource | Should Match 'X-Content-Type-Options'
        $serverSource | Should Not Match 'query_params\.get\("path"'
    }

    It 'keeps image source resolution read-only and serializes concurrent source discovery' {
        $python = @'
import concurrent.futures
import importlib.util
import json
import pathlib
import tempfile

spec = importlib.util.spec_from_file_location("codex_server", __import__("sys").argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as tmp_dir:
    root = pathlib.Path(tmp_dir)
    module.RUNTIME_DATA_DIR = root / "runtime"
    module.SOURCE_DATA_ROOT = module.RUNTIME_DATA_DIR / "CodexChatIndex.sources"
    module.SOURCES_FILE = module.RUNTIME_DATA_DIR / "CodexChatIndex.sources.json"
    module.EXTERNAL_SOURCES_ROOT = root / "external"
    module.CLAUDE_HOME = root / "claude"

    original_write = module.write_sources_manifest
    write_calls = []
    def reject_write(payload):
        write_calls.append(payload)
        raise AssertionError("read-only resolution attempted to write the source manifest")
    module.write_sources_manifest = reject_write
    read_only_error = ""
    try:
        read_only_source = module.resolve_source_id("local-codex", persist=False)
    except Exception as error:
        read_only_source = ""
        read_only_error = type(error).__name__
    finally:
        module.write_sources_manifest = original_write
    external_created_by_read_only = module.EXTERNAL_SOURCES_ROOT.exists()

    def discover_once(_):
        try:
            return {"selected": module.discover_sources().get("selectedSourceId"), "error": ""}
        except Exception as error:
            return {"selected": "", "error": type(error).__name__}

    with concurrent.futures.ThreadPoolExecutor(max_workers=32) as executor:
        outcomes = list(executor.map(discover_once, range(200)))
    errors = [item["error"] for item in outcomes if item["error"]]
    manifest = json.loads(module.SOURCES_FILE.read_text(encoding="utf-8"))
    print(json.dumps({
        "readOnlySource": read_only_source,
        "readOnlyError": read_only_error,
        "readOnlyWrites": len(write_calls),
        "externalCreatedByReadOnly": external_created_by_read_only,
        "concurrentErrors": errors,
        "selected": manifest.get("selectedSourceId"),
        "sourceIds": [item.get("id") for item in manifest.get("sources", [])]
    }))
'@
        $result = python -c $python $serverScript | ConvertFrom-Json -Depth 20
        $result.readOnlySource | Should Be 'local-codex'
        $result.readOnlyError | Should Be ''
        $result.readOnlyWrites | Should Be 0
        $result.externalCreatedByReadOnly | Should Be $false
        @($result.concurrentErrors).Count | Should Be 0
        $result.selected | Should Be 'local-codex'
        ($result.sourceIds -join ',') | Should Be 'local-codex,local-claude'

        $serverSource = Get-Content -LiteralPath $serverScript -Raw
        $serverSource | Should Match 'resolve_source_id\([\s\S]*?persist=False'
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
        $dedupeImage = @($userEvents[0].images)[0]
        $dedupeImage.type | Should Be 'managed'
        $dedupeImage.assetId | Should Match '^[0-9a-f]{64}$'
        $dedupeImage.mimeType | Should Be 'image/png'
        ($dedupeImage.PSObject.Properties.Name -contains 'src') | Should Be $false
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
        $subagentText = "<subagent_notification>`n{`"agent_path`":`"internal-review`",`"status`":{`"completed`":`"Internal review result.`"}}`n</subagent_notification>"
        $turnAbortedText = "<turn_aborted>`nThe user interrupted the previous turn on purpose.`n</turn_aborted>"
        @(
            '{"timestamp":"2026-06-17T08:08:00Z","type":"session_meta","payload":{"id":"88888888-8888-8888-8888-888888888888","timestamp":"2026-06-17T08:08:00Z","cwd":"M:\\Context Filter Demo","source":"cli","model_provider":"openai","cli_version":"0.18-test"}}',
            (@{ timestamp = '2026-06-17T08:08:01Z'; type = 'response_item'; payload = @{ type = 'message'; role = 'user'; content = @(@{ type = 'input_text'; text = $agentsText }) } } | ConvertTo-Json -Depth 10 -Compress),
            (@{ timestamp = '2026-06-17T08:08:02Z'; type = 'response_item'; payload = @{ type = 'message'; role = 'user'; content = @(@{ type = 'input_text'; text = $environmentText }) } } | ConvertTo-Json -Depth 10 -Compress),
            (@{ timestamp = '2026-06-17T08:08:03Z'; type = 'response_item'; payload = @{ type = 'message'; role = 'user'; content = @(@{ type = 'input_text'; text = $subagentText }) } } | ConvertTo-Json -Depth 10 -Compress),
            (@{ timestamp = '2026-06-17T08:08:04Z'; type = 'event_msg'; payload = @{ type = 'user_message'; message = $turnAbortedText } } | ConvertTo-Json -Depth 10 -Compress),
            '{"timestamp":"2026-06-17T08:08:05Z","type":"event_msg","payload":{"type":"user_message","message":"这才是真实提问。"}}',
            '{"timestamp":"2026-06-17T08:08:06Z","type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"真实回复。"}}'
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
        $contextSession.userCount | Should Be 1
        $userEvents.Count | Should Be 1
        $userEvents[0].rawText | Should Be '这才是真实提问。'
        ($contextDetail.events | ConvertTo-Json -Depth 20 -Compress) | Should Not Match 'environment_context'
        ($contextDetail.events | ConvertTo-Json -Depth 20 -Compress) | Should Not Match 'AGENTS\.md instructions'
        ($contextDetail.events | ConvertTo-Json -Depth 20 -Compress) | Should Not Match 'subagent_notification'
        ($contextDetail.events | ConvertTo-Json -Depth 20 -Compress) | Should Not Match 'turn_aborted'
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

    It 'strips consecutive injected prefixes from both Codex user message formats' {
        $prefixHome = Join-Path $tempRoot 'prefix-filter-home'
        $prefixSessionDir = Join-Path $prefixHome 'sessions\2026\08\02'
        New-Item -ItemType Directory -Force $prefixSessionDir | Out-Null
        $prefixSessionPath = Join-Path $prefixSessionDir 'rollout-2026-08-02T08-30-00-30303030-3030-4030-8030-303030303030.jsonl'
        $recommendedText = "<recommended_plugins>`n  <plugin>脱敏插件清单</plugin>`n</recommended_plugins>"
        $environmentText = "<environment_context>`n  <cwd>M:\Demo</cwd>`n  <shell>powershell</shell>`n</environment_context>"
        $fullPrefix = "$recommendedText`n`n$environmentText"
        @(
            '{"timestamp":"2026-08-02T08:30:00Z","type":"session_meta","payload":{"id":"30303030-3030-4030-8030-303030303030","timestamp":"2026-08-02T08:30:00Z","cwd":"M:\\Prefix Filter Demo","source":"cli","model_provider":"openai","cli_version":"0.30-test"}}',
            (@{ timestamp = '2026-08-02T08:30:01Z'; type = 'response_item'; payload = @{ type = 'message'; role = 'user'; content = @(@{ type = 'input_text'; text = $fullPrefix }) } } | ConvertTo-Json -Depth 10 -Compress),
            (@{ timestamp = '2026-08-02T08:30:02Z'; type = 'response_item'; payload = @{ type = 'message'; role = 'user'; content = @(
                @{ type = 'input_text'; text = "$fullPrefix`n`n请保留这个真实问题作为标题。" },
                @{ type = 'input_image'; image_url = 'data:image/png;base64,iVBORw0KGgo=' }
            ) } } | ConvertTo-Json -Depth 10 -Compress),
            (@{ timestamp = '2026-08-02T08:30:03Z'; type = 'event_msg'; payload = @{ type = 'user_message'; message = "$fullPrefix`n`n第二个真实问题也必须保留。" } } | ConvertTo-Json -Depth 10 -Compress),
            '{"timestamp":"2026-08-02T08:30:04Z","type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"真实回复。"}}'
        ) | Set-Content -LiteralPath $prefixSessionPath -Encoding UTF8
        $fixtureHashBefore = (Get-FileHash -LiteralPath $prefixSessionPath -Algorithm SHA256).Hash

        $prefixRoot = Join-Path $tempRoot 'prefix-filter-runtime'
        $prefixOutputPath = Join-Path $prefixRoot 'CodexChatIndex.html'
        & $buildScript -CodexHome $prefixHome -OutputPath $prefixOutputPath -DataRoot $prefixRoot -RefreshMode Full -JsonSummary | Out-Null

        $prefixIndex = Get-Content -LiteralPath (Join-Path (Get-TestSourceRoot $prefixRoot) 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $prefixSession = @($prefixIndex.workspaces | ForEach-Object { @($_.sessions) } | Select-Object -First 1)[0]
        $prefixDetailPath = [System.IO.Path]::GetFullPath((Join-Path $prefixRoot ([string]$prefixSession.detailHref)))
        $prefixDetail = Get-Content -LiteralPath $prefixDetailPath -Raw | ConvertFrom-Json -Depth 100
        $prefixSearch = Get-Content -LiteralPath (Join-Path (Get-TestSourceRoot $prefixRoot) 'CodexChatIndex.search.json') -Raw
        $userEvents = @($prefixDetail.events | Where-Object { $_.kind -eq 'user' })

        $prefixSession.title | Should Be '请保留这个真实问题作为标题。'
        $prefixSession.summary | Should Be '请保留这个真实问题作为标题。'
        $prefixSession.userCount | Should Be 2
        $userEvents.Count | Should Be 2
        $userEvents[0].rawText | Should Be '请保留这个真实问题作为标题。'
        @($userEvents[0].images).Count | Should Be 1
        $userEvents[1].rawText | Should Be '第二个真实问题也必须保留。'
        ($prefixDetail.events | ConvertTo-Json -Depth 30 -Compress) | Should Not Match 'recommended_plugins|environment_context|脱敏插件清单'
        $prefixSearch | Should Not Match 'recommended_plugins|environment_context|脱敏插件清单'
        (Get-FileHash -LiteralPath $prefixSessionPath -Algorithm SHA256).Hash | Should Be $fixtureHashBefore
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

    It 'fully rebuilds the pre-bounded-search cache once and then reuses cache version 5 incrementally' {
        $versionRoot = Join-Path $tempRoot 'version-mismatch-cache'
        $versionOutputPath = Join-Path $versionRoot 'CodexChatIndex.html'
        New-Item -ItemType Directory -Force $versionRoot | Out-Null

        & $buildScript -CodexHome $fixtureHome -OutputPath $versionOutputPath -DataRoot $versionRoot -RefreshMode Full -JsonSummary | Out-Null
        $versionSourceRoot = Get-TestSourceRoot $versionRoot
        $cachePath = Join-Path $versionSourceRoot 'CodexChatIndex.cache.json'
        $cacheData = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -Depth 100
        $cacheData.cacheVersion = 3
        Set-Content -LiteralPath $cachePath -Value ($cacheData | ConvertTo-Json -Depth 100) -Encoding UTF8

        $summary = (& $buildScript -CodexHome $fixtureHome -OutputPath $versionOutputPath -DataRoot $versionRoot -RefreshMode Incremental -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json
        $rebuiltCache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -Depth 100
        $secondSummary = (& $buildScript -CodexHome $fixtureHome -OutputPath $versionOutputPath -DataRoot $versionRoot -RefreshMode Incremental -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json

        $summary.mode | Should Be 'Full'
        $summary.parsedCount | Should Be 2
        $summary.notice | Should Match '缓存版本不兼容'
        $rebuiltCache.builderVersion | Should Be 'V0.34'
        $rebuiltCache.cacheVersion | Should Be 5
        @($rebuiltCache.files[0].questionTexts).Count | Should BeGreaterThan 0
        ($rebuiltCache.files[0].PSObject.Properties.Name -contains 'otherBaseText') | Should Be $true
        ($rebuiltCache.files[0].PSObject.Properties.Name -contains 'toolRawText') | Should Be $true
        ($rebuiltCache.files[0].PSObject.Properties.Name -contains 'otherText') | Should Be $false
        $secondSummary.mode | Should Be 'Incremental'
        $secondSummary.noChange | Should Be $true
        $secondSummary.parsedCount | Should Be 0
        $secondSummary.reusedCount | Should Be 2
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

        $rollbackSession.createdLocal | Should Be ([DateTimeOffset]::Parse('2026-05-04T08:02:37.856Z').ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))
        $rollbackSession.updatedLocal | Should Be ([DateTimeOffset]::Parse('2026-05-04T08:03:10.100Z').ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))
        $rollbackSession.userCount | Should Be 2
        $rollbackSession.assistantCount | Should Be 2
        @($rollbackDetail.events | Where-Object { $_.kind -eq 'user' })[1].timestampLocal | Should Be ([DateTimeOffset]::Parse('2026-05-04T08:02:57.576Z').ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))
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
        $forkSession.createdLocal | Should Be ([DateTimeOffset]::Parse('2026-04-25T09:00:00Z').ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))

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
        $finalEvents = @($detail.events | Where-Object { $_.kind -eq 'assistant_final' })
        @($finalEvents).Count | Should BeGreaterThan 0
        $finalEvents | ForEach-Object {
            $_.renderMode | Should Be 'deterministic_markdown'
            $_.rawText | Should Not BeNullOrEmpty
        }
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
var noteDisplayMode = "hover";
var pinnedNotesLayer = null;
var pinnedNotesFrame = 0;
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
var noteDisplayMode = "hover";
var pinnedNotesLayer = null;
var pinnedNotesFrame = 0;
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
var noteDisplayMode = "hover";
var pinnedNotesLayer = null;
var pinnedNotesFrame = 0;
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
var noteDisplayMode = "hover";
var pinnedNotesLayer = null;
var pinnedNotesFrame = 0;
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
var noteDisplayMode = "hover";
var pinnedNotesLayer = null;
var pinnedNotesFrame = 0;
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
        $html | Should Match '<span class="version-badge">V0\.34</span>'
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
var noteDisplayMode = "hover";
var pinnedNotesLayer = null;
var pinnedNotesFrame = 0;
function schedulePinnedNotesRefresh() {}
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
var noteDisplayMode = "hover";
var pinnedNotesLayer = null;
var pinnedNotesFrame = 0;
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
var noteDisplayMode = "hover";
var pinnedNotesLayer = null;
var pinnedNotesFrame = 0;
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
        $html | Should Match 'function scheduleGlobalSearch\(options\)'
        $html | Should Match 'async function runGlobalSearch\(query, field\)'
        $html | Should Match 'function sessionMatchesGlobalSearch\(session\)'
        $html | Should Match 'const globalSearchMatch = sessionMatchesGlobalSearch\(session\)'
        $html | Should Match 'if \(hasLibrarySearchQuery\(\)\) \{[\s\S]*?return;[\s\S]*?\}'
        $html | Should Match 'if \(getGlobalSearchQuery\(\) && !sessionMatchesGlobalSearch\(session\)\)'
        $html | Should Match 'function scheduleViewerSearch\(options\)[\s\S]*?scheduleGlobalSearch\(settings\)'
        $html | Should Match 'viewerSearchInput\.addEventListener\(''input'', \(\) => \{[\s\S]*?scheduleViewerSearch\(\)'
        $html | Should Not Match 'viewerSearchInput\.addEventListener\(''input'', \(\) => \{[\s\S]*?renderViewer\(\);\s*\}\);'
    }

    It 'ignores an older async library-search response after the query or field changes' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8").replace(/\r\n/g, "\n");
const match = html.match(/async function runGlobalSearch\(query, field\) \{[\s\S]*?\n    \}(?=\n\n    function loadSortPrefs)/);
if (!match) throw new Error("runGlobalSearch not found");

const SEARCH_API_URL = "/api/search";
const globalSearchState = { timer: 0, query: "", field: "all", pending: false, matchKeys: null, error: "", requestId: 0 };
let currentQuery = "old";
let currentField = "all";
let workspaceRenders = 0;
let viewerRenders = 0;
const pending = [];
function getCurrentSourceId() { return "local-codex"; }
function getGlobalSearchQuery() { return currentQuery; }
function getGlobalSearchField() { return currentField; }
function scheduleGlobalSearch() {}
function renderWorkspaceList() { workspaceRenders += 1; }
function renderViewer() { viewerRenders += 1; }
function fetch(url) {
  return new Promise(resolve => pending.push({
    url,
    resolve: keys => resolve({
      ok: true,
      status: 200,
      json: async () => ({ sessionKeys: keys })
    })
  }));
}

eval(match[0]);
(async () => {
  const oldRequest = runGlobalSearch("old", "all");
  currentQuery = "new";
  currentField = "questions";
  const newRequest = runGlobalSearch("new", "questions");
  pending[1].resolve(["new-session"]);
  await newRequest;
  pending[0].resolve(["old-session"]);
  await oldRequest;
  console.log(JSON.stringify({
    query: globalSearchState.query,
    field: globalSearchState.field,
    keys: Array.from(globalSearchState.matchKeys || []),
    requestId: globalSearchState.requestId,
    workspaceRenders,
    viewerRenders,
    urls: pending.map(item => item.url)
  }));
})().catch(error => {
  console.error(error);
  process.exit(1);
});
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.query | Should Be 'new'
        $result.field | Should Be 'questions'
        ($result.keys -join ',') | Should Be 'new-session'
        $result.requestId | Should Be 2
        $result.workspaceRenders | Should Be 1
        $result.viewerRenders | Should Be 1
        $result.urls[0] | Should Match 'field=all'
        $result.urls[1] | Should Match 'field=questions'
    }

    It 'shows V0.30 matched titles without automatically selecting a search result' {
        $html | Should Match 'const selectedWorkspace = visible\.find\(item => item\.workspace\.id === selectedWorkspaceId\)'
        $html | Should Match 'const current = selectedWorkspace \|\| \(hasLibrarySearchQuery\(\) \? visible\[0\] : null\)'
        $html | Should Match 'groupHead\.onclick = async \(\) => \{\s*selectedWorkspaceId = current\.workspace\.id;\s*await selectSessionFromTitlePane\(group\.sessions\[0\]\)'
        $html | Should Match 'if \(!sessionVisible\) \{\s*if \(hasLibrarySearchQuery\(\)\) \{\s*return;\s*\}\s*selectedSessionKey = currentWorkspace\.sessions\[0\]\.key'
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

    It 'renders an independent V0.30 question-only search toggle beside the question-only view toggle' {
        $html | Should Match 'data-search-field="questions"'
        $html | Should Match 'title="只搜索用户提问正文">提问</button>'
        $html | Should Match 'data-view-mode="questions" title="只显示用户提问">提问</button>'
        $html | Should Match 'let viewerSearchQuestionsOnly = false'
        $html | Should Match 'button\.dataset\.searchField === ''questions'''
        $html | Should Match 'button\.setAttribute\(''aria-pressed'', viewerSearchQuestionsOnly \? ''true'' : ''false''\)'
        $html | Should Match 'viewerSearchQuestionsOnly = !viewerSearchQuestionsOnly;[\s\S]*?scheduleViewerSearch\(\{ immediate: true \}\)'
        $html | Should Match 'viewerSearchQuestionsOnly = false;[\s\S]*?viewerSearchScope = ''all'''
        $html | Should Match 'globalSearchState\.requestId\+\+'
        $html | Should Match '''&field='' \+ encodeURIComponent\(normalizedField\) \+ ''&q='''
    }

    It 'matches question search terms within one user question and only pairs its final answers' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8").replace(/\r\n/g, "\n");
const termsMatch = html.match(/function getSearchTerms\(query\) \{[\s\S]*?\n    \}(?=\n\n    function eventMatchesSearch)/);
const eventMatch = html.match(/function eventMatchesSearch\(event, query\) \{[\s\S]*?\n    \}/);
const questionMatch = html.match(/function questionMatchesSearch\(event, query\) \{[\s\S]*?\n    \}/);
const visibleMatch = html.match(/function getVisibleDetailEvents\(\) \{[\s\S]*?\n    \}(?=\n\n    function getEventLabel)/);
if (!termsMatch || !eventMatch || !questionMatch || !visibleMatch) throw new Error("V0.30 question search helpers not found");
eval(termsMatch[0] + "\n" + eventMatch[0] + "\n" + questionMatch[0] + "\n" + visibleMatch[0]);
const sourceEvents = [
  { kind: "user", rawText: "刷新 失败", questionKey: "q1" },
  { kind: "assistant_final", rawText: "回答也包含刷新失败", questionKey: "a1" },
  { kind: "user", rawText: "只说刷新", questionKey: "q2" },
  { kind: "assistant_final", rawText: "这里只说失败", questionKey: "a2" },
  { kind: "user", rawText: "普通问题", questionKey: "q3" },
  { kind: "assistant_final", rawText: "回答单独包含刷新和失败", questionKey: "a3" }
];
let viewerSearchQuestionsOnly = true;
let viewerSearchQuery = "刷新 失败";
let viewerViewMode = "all";
function getCurrentDetailEventsWithKeys() { return sourceEvents; }
function eventMatchesView(event) { return viewerViewMode === "questions" ? event.kind === "user" : true; }
const paired = getVisibleDetailEvents();
viewerViewMode = "questions";
const questionsOnly = getVisibleDetailEvents();
viewerSearchQuestionsOnly = false;
viewerViewMode = "all";
const fullText = getVisibleDetailEvents();
console.log(JSON.stringify({
  whitespaceTerms: getSearchTerms("  刷新\t失败\n"),
  commaTerms: getSearchTerms("刷新,失败"),
  paired: paired.map(event => ({ kind: event.kind, key: event.questionKey, direct: !!event.isDirectSearchHit, companion: !!event.isSearchCompanion })),
  questionsOnly: questionsOnly.map(event => event.questionKey),
  fullTextQuestions: fullText.filter(event => event.kind === "user").map(event => event.questionKey)
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        ($result.whitespaceTerms -join ',') | Should Be '刷新,失败'
        @($result.commaTerms).Count | Should Be 1
        $result.commaTerms[0] | Should Be '刷新,失败'
        @($result.paired).Count | Should Be 2
        $result.paired[0].key | Should Be 'q1'
        $result.paired[0].direct | Should Be $true
        $result.paired[0].companion | Should Be $false
        $result.paired[1].kind | Should Be 'assistant_final'
        $result.paired[1].direct | Should Be $false
        $result.paired[1].companion | Should Be $true
        ($result.questionsOnly -join ',') | Should Be 'q1'
        ($result.fullTextQuestions -join ',') | Should Match 'q3'
    }

    It 'highlights V0.22 visible transcript text without changing registered copy text' {
        $html | Should Match 'function highlightMatchesInElement\(root, terms\)'
        $html | Should Match 'document\.createTreeWalker\([^)]*NodeFilter\.SHOW_TEXT'
        $html | Should Match 'mark\.className = ''search-hit'''
        $html | Should Match 'node\.parentElement\.closest\(''mark,script,style,\.is-search-companion''\)'
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
        $html | Should Match 'function scheduleViewerSearch\(options\)'
        $html | Should Match 'viewerSearchScope === ''current'''
        $html | Should Match 'viewerSearchInput\.addEventListener\(''input'', \(\) => \{[\s\S]*?scheduleViewerSearch\(\)'
        $html | Should Match 'button\[data-search-scope\]'
        $searchInputIndex = $html.IndexOf('id="viewerSearch"')
        $searchScopeIndex = $html.IndexOf('toolbar-segment toolbar-segment--search')
        $searchFieldIndex = $html.IndexOf('toolbar-segment toolbar-segment--field')
        $viewModeIndex = $html.IndexOf('toolbar-segment toolbar-segment--view')
        $toolsIndex = $html.IndexOf('toolbar-segment toolbar-segment--tools')
        $searchInputIndex | Should BeGreaterThan -1
        $searchScopeIndex | Should BeGreaterThan $searchInputIndex
        $searchFieldIndex | Should BeGreaterThan $searchScopeIndex
        $viewModeIndex | Should BeGreaterThan $searchFieldIndex
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
        $html | Should Match 'setTimeout\(\(\) => \{[\s\S]*?runGlobalSearch\(query, field\);[\s\S]*?\}, 240\)'
    }

    It 'keeps the V0.27 search anchor until the user selects a visible result' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function updateQuestionNavState\(\) \{[\s\S]*?\n    \}(?=\n\n    function findQuestionElement)/);
const jumpMatch = html.match(/function jumpQuestion\(direction\) \{[\s\S]*?\n    \}(?=\n\n    function handleTranscriptEnter)/);
if (!match || !jumpMatch) {
  throw new Error("question navigation helpers not found");
}
let viewerSearchQuery = "needle";
let viewerSearchQuestionsOnly = false;
let viewerSearchScope = "current";
let selectedQuestionKey = "q2";
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
const missingAnchorNextDisabled = questionNextButton.disabled;
jumpQuestion(1);
const selectedWithoutVisibleAnchor = selected.slice();
selectedQuestionKey = "q1";
updateQuestionNavState();
jumpQuestion(1);
updateQuestionNavState();
console.log(JSON.stringify({
  missingAnchorNextDisabled,
  selectedWithoutVisibleAnchor,
  selected,
  nextDisabled: questionNextButton.disabled
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.missingAnchorNextDisabled | Should Be $false
        @($result.selectedWithoutVisibleAnchor).Count | Should Be 0
        $result.selected[0].key | Should Be 'q3'
        $result.selected[0].options.behavior | Should Be 'keyboard'
        $result.nextDisabled | Should Be $false
        $html | Should Not Match 'selectedQuestionKey\s*=\s*visibleQuestionKeys\[0\]'
        $html | Should Not Match 'if \(query\) selectedQuestionKeyIsTemporary'
    }

    It 'executes the complete V0.27 current-search focus and selection flow' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const selectionMatch = html.match(/function highlightCurrentQuestion\(\) \{[\s\S]*?\n    \}(?=\n\n    function syncViewerToolbar)/);
const renderMatch = html.match(/function renderViewer\(\) \{[\s\S]*?\n    \}(?=\n\n    async function selectSessionFromTitlePane)/);
const scheduleMatch = html.match(/function resetGlobalSearchStateForCurrentScope\(\) \{[\s\S]*?\n    \}(?=\n\n    async function runGlobalSearch)/);
const inputMatch = html.match(/viewerSearchInput\.addEventListener\('input', \(\) => \{[\s\S]*?\n    \}\);(?=\n    viewerSearchInput\.addEventListener\('compositionstart')/);
const clickMatch = html.match(/transcript\.addEventListener\('click', event => \{[\s\S]*?\n    \}\);(?=\n    transcript\.addEventListener\('toggle')/);
if (!selectionMatch || !renderMatch || !scheduleMatch || !inputMatch || !clickMatch) {
  throw new Error("complete V0.27 search flow helpers not found");
}

function createClassList() {
  const values = new Set();
  return {
    toggle(name, enabled) {
      if (enabled) values.add(name);
      else values.delete(name);
    },
    contains(name) { return values.has(name); }
  };
}
function createQuestionNode(key) {
  return { dataset: { questionKey: key }, classList: createClassList() };
}

const document = { activeElement: null };
const viewerSearchInput = {
  value: "",
  addEventListener(name, handler) {
    this.handlers = this.handlers || {};
    this.handlers[name] = handler;
  },
  focus() { document.activeElement = this; }
};
const transcript = {
  nodes: [],
  handlers: {},
  _html: "",
  set innerHTML(value) {
    this._html = value;
    this.nodes = Array.from(value.matchAll(/data-question-key="([^"]+)"/g), match => createQuestionNode(match[1]));
  },
  get innerHTML() { return this._html; },
  querySelectorAll(selector) {
    return selector === "[data-question-key]" ? this.nodes : [];
  },
  addEventListener(name, handler) { this.handlers[name] = handler; },
  focus() { document.activeElement = this; },
  contains(node) { return node === this; }
};
const viewerHead = { innerHTML: "" };
const viewerToolbar = {};
const session = {
  key: "session-1",
  path: "M:\\Demo\\session.jsonl",
  createdLocal: "2026-07-18 10:00:00",
  userCount: 3,
  assistantCount: 2
};
const allEvents = [
  { kind: "user", questionKey: "q1", rawText: "context question" },
  { kind: "assistant_final", rawText: "needle answer" },
  { kind: "user", questionKey: "q2", rawText: "current question" },
  { kind: "assistant_final", rawText: "other answer" },
  { kind: "user", questionKey: "q3", rawText: "needle question" }
];

let viewerSearchQuery = "";
let viewerSearchQuestionsOnly = false;
let viewerSearchScope = "current";
let viewerSearchInputIsComposing = false;
let viewerViewMode = "all";
let selectedQuestionKey = "q2";
let selectedQuestionKeyIsTemporary = false;
let pendingQuestionFocus = null;
let currentScopeSearchTimer = 0;
let pendingTimer = null;
let savedAnchors = 0;
const globalSearchState = { timer: 0, query: "", pending: false, matchKeys: null, error: "", requestId: 0 };
const CURRENT_SCOPE_SEARCH_DELAY_MS = 160;

global.setTimeout = callback => { pendingTimer = callback; return 7; };
global.clearTimeout = () => { pendingTimer = null; };
global.requestAnimationFrame = callback => { callback(); return 1; };
function flushSearchTimer() {
  const callback = pendingTimer;
  pendingTimer = null;
  if (callback) callback();
}
function getSelectedSession() { return session; }
function escapeHtml(value) { return String(value || ""); }
function getGlobalSearchQuery() { return ""; }
function getGlobalSearchField() { return "all"; }
function sessionMatchesGlobalSearch() { return true; }
function resetMessageCopyTexts() {}
function getGlobalSearchEmptyText() { return ""; }
function getEmptySourceText() { return ""; }
function syncViewerToolbar() {}
function isDetailLoadedForSession() { return true; }
function getVisibleDetailEvents() {
  return viewerSearchQuery.trim() ? [allEvents[0], allEvents[1], allEvents[4]] : allEvents;
}
function syncSelectedQuestionKey() {
  return allEvents.filter(event => event.kind === "user");
}
function buildReaderMarkup(events, options) {
  return events.map(event => event.kind === "user"
    ? '<article data-question-key="' + event.questionKey + '" class="' +
      (event.questionKey === options.selectedQuestionKey ? 'is-current-question' : '') + '"></article>'
    : '<article class="assistant"></article>').join("");
}
function hydrateOpenLazyDetails() {}
function highlightMatchesInElement() {}
function getSearchTerms() { return []; }
function scrollToQuestion() { return true; }
function updateReplyComposerState() {}
function updateQuestionNavState() {}
function saveProgressAnchorForCurrentSession() { savedAnchors += 1; }
function stableScrollToQuestionForKeyboard() {}
function getNavigableQuestionKeys() { return transcript.nodes.map(node => node.dataset.questionKey); }
function renderWorkspaceList() { renderViewer(); }
function restoreCurrentProgressAnchorIfReadable() { return false; }

eval(selectionMatch[0]);
eval(renderMatch[0]);
eval(scheduleMatch[0]);
eval(inputMatch[0]);
eval(clickMatch[0]);

renderViewer();
const initialHighlighted = transcript.nodes.filter(node => node.classList.contains("is-current-question")).map(node => node.dataset.questionKey);

viewerSearchInput.focus();
viewerSearchInput.value = "needle";
viewerSearchInput.handlers.input();
flushSearchTimer();
const searched = {
  selected: selectedQuestionKey,
  highlighted: transcript.nodes.filter(node => node.classList.contains("is-current-question")).map(node => node.dataset.questionKey),
  focusStayed: document.activeElement === viewerSearchInput,
  savedAnchors
};
jumpQuestion(1);
const afterUnanchoredArrow = { selected: selectedQuestionKey, savedAnchors };

viewerSearchInput.focus();
viewerSearchInput.value = "";
viewerSearchInput.handlers.input();
flushSearchTimer();
const cleared = {
  selected: selectedQuestionKey,
  highlighted: transcript.nodes.filter(node => node.classList.contains("is-current-question")).map(node => node.dataset.questionKey),
  focusStayed: document.activeElement === viewerSearchInput,
  savedAnchors
};

viewerSearchInput.value = "needle";
viewerSearchInput.handlers.input();
flushSearchTimer();
const q1 = transcript.nodes.find(node => node.dataset.questionKey === "q1");
const clickTarget = {
  closest(selector) {
    if (selector === "button, a, input, textarea, select") return null;
    if (selector === "[data-question-key]") return q1;
    return null;
  }
};
transcript.handlers.click({ defaultPrevented: false, target: clickTarget });
const clicked = {
  selected: selectedQuestionKey,
  transcriptFocused: document.activeElement === transcript,
  savedAnchors
};
jumpQuestion(1);
const navigated = { selected: selectedQuestionKey, savedAnchors };

console.log(JSON.stringify({
  initialHighlighted,
  searched,
  afterUnanchoredArrow,
  cleared,
  clicked,
  navigated
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20
        ($result.initialHighlighted -join ',') | Should Be 'q2'
        $result.searched.selected | Should Be 'q2'
        @($result.searched.highlighted).Count | Should Be 0
        $result.searched.focusStayed | Should Be $true
        $result.searched.savedAnchors | Should Be 0
        $result.afterUnanchoredArrow.selected | Should Be 'q2'
        $result.afterUnanchoredArrow.savedAnchors | Should Be 0
        $result.cleared.selected | Should Be 'q2'
        ($result.cleared.highlighted -join ',') | Should Be 'q2'
        $result.cleared.focusStayed | Should Be $true
        $result.cleared.savedAnchors | Should Be 0
        $result.clicked.selected | Should Be 'q1'
        $result.clicked.transcriptFocused | Should Be $true
        $result.clicked.savedAnchors | Should Be 1
        $result.navigated.selected | Should Be 'q3'
        $result.navigated.savedAnchors | Should Be 2
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

    It 'keeps transcript card geometry stable during question and answer navigation' {
        $html | Should Not Match '\.message \{[\s\S]*?content-visibility:\s*auto'
        $html | Should Not Match '\.collapsed-group \{[\s\S]*?content-visibility:\s*auto'
        $html | Should Not Match '\.transcript\.is-programmatic-scroll[\s\S]*?content-visibility:\s*visible'
        $html | Should Not Match 'contain-intrinsic-size:'
    }

    It 'keeps keyboard question navigation anchored near the top of the transcript' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const scrollMatch = html.match(/function scrollTranscriptTo\(top, behavior, fallbackElement, options\) \{[\s\S]*?\n    \}(?=\n\n    function convergeScrollToQuestion)/);
const convergeMatch = html.match(/function convergeScrollToQuestion\(questionKey, behavior\) \{[\s\S]*?\n    \}(?=\n\n    function scrollToQuestion)/);
const questionMatch = html.match(/function scrollToQuestion\(questionKey, behavior\) \{[\s\S]*?\n    \}(?=\n\n    function highlightCurrentQuestion)/);
const selectMatch = html.match(/function setSelectedQuestionKey\(questionKey, options\) \{[\s\S]*?\n    \}(?=\n\n    function focusFirstQuestion)/);
const jumpMatch = html.match(/function jumpQuestion\(direction\) \{[\s\S]*?\n    \}(?=\n\n    function handleTranscriptEnter)/);
if (!scrollMatch || !convergeMatch || !questionMatch || !selectMatch || !jumpMatch) {
  throw new Error("question scroll helpers not found");
}
let activeQuestionScrollAnimation = 0;
let activeQuestionScrollToken = 0;
let viewerSearchQuery = "";
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
function calculateTranscriptScrollSpacer() { return 0; }
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
const unlockMatch = html.match(/function unlockTranscriptLayoutForProgrammaticScroll\(\) \{[\s\S]*?\n    \}(?=\n\n    function calculateTranscriptScrollSpacer)/);
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
function calculateTranscriptScrollSpacer() { return 32; }
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

    It 'recalculates question scroll room without counting an existing spacer twice' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const spacerMatch = html.match(/function calculateTranscriptScrollSpacer\(element\) \{[\s\S]*?\n    \}(?=\n\n    function scrollElementToTranscriptTop)/);
if (!spacerMatch) {
  throw new Error("question spacer helper not found");
}
const transcript = {
  scrollHeight: 874,
  clientHeight: 410,
  style: {
    getPropertyValue(name) {
      return name === "--transcript-scroll-spacer" ? "112px" : "";
    }
  }
};
const question = { offsetTop: 464, offsetHeight: 92 };
eval(spacerMatch[0]);
console.log(JSON.stringify({ spacer: calculateTranscriptScrollSpacer(question) }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json

        $result.spacer | Should Be 112
    }

    It 'corrects keyboard question scroll once after layout unlock clamps scroll position' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const cancelMatch = html.match(/function cancelQuestionScrollAnimation\(\) \{[\s\S]*?\n    \}(?=\n\n    function lockTranscriptLayoutForProgrammaticScroll)/);
const lockMatch = html.match(/function lockTranscriptLayoutForProgrammaticScroll\([^)]*\) \{[\s\S]*?\n    \}(?=\n\n    function unlockTranscriptLayoutForProgrammaticScroll)/);
const unlockMatch = html.match(/function unlockTranscriptLayoutForProgrammaticScroll\(\) \{[\s\S]*?\n    \}(?=\n\n    function calculateTranscriptScrollSpacer)/);
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
function calculateTranscriptScrollSpacer() { return unlockCount ? 800 : 0; }
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
const unlockMatch = html.match(/function unlockTranscriptLayoutForProgrammaticScroll\(\) \{[\s\S]*?\n    \}(?=\n\n    function calculateTranscriptScrollSpacer)/);
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
function calculateTranscriptScrollSpacer() { return 0; }
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
function calculateTranscriptScrollSpacer() { return 0; }
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

    It 'pairs V0.28 question and final-answer search results without mutating source events' {
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
    { kind: "user", timestampLocal: "2026-06-15 10:00:00", rawText: "question-only-hit" },
    { kind: "assistant_final", timestampLocal: "2026-06-15 10:00:01", rawText: "first plain answer" },
    { kind: "assistant_final", timestampLocal: "2026-06-15 10:00:02", rawText: "answer-only-hit" },
    { kind: "tool", timestampLocal: "2026-06-15 10:00:03", toolName: "exec_command", summary: "same-group-process", rawText: "raw output" },
    { kind: "user", timestampLocal: "2026-06-15 10:01:00", rawText: "both-hit second question" },
    { kind: "assistant_final", timestampLocal: "2026-06-15 10:01:01", rawText: "both-hit second answer" },
    { kind: "user", timestampLocal: "2026-06-15 10:02:00", rawText: "lonely-question-hit" },
    { kind: "user", timestampLocal: "2026-06-15 10:03:00", rawText: "process owner" },
    { kind: "tool", timestampLocal: "2026-06-15 10:03:01", toolName: "exec_command", summary: "process-only-hit", rawText: "raw output" },
    { kind: "assistant_final", timestampLocal: "2026-06-15 10:03:02", rawText: "unmatched process answer" }
  ]
};
var viewerSearchQuery = "question-only-hit";
var viewerSearchQuestionsOnly = false;
var viewerViewMode = "all";
var selectedQuestionKey = null;
var messageCopyTexts = new Map();
var messageCopySerial = 0;
var lazyDetailRenderers = new Map();
var lazyDetailSerial = 0;
var noteDisplayMode = "hover";
var pinnedNotesLayer = null;
var pinnedNotesFrame = 0;
eval(match[0]);

function capture(query, mode = "all") {
  viewerSearchQuery = query;
  viewerViewMode = mode;
  const events = getVisibleDetailEvents();
  return {
    kinds: events.map(event => event.kind),
    direct: events.map(event => !!event.isDirectSearchHit),
    companion: events.map(event => !!event.isSearchCompanion),
    text: events.map(event => event.rawText || event.summary || ""),
    markup: buildReaderMarkup(events, {})
  };
}
const question = capture("question-only-hit");
const answer = capture("answer-only-hit");
const both = capture("both-hit");
const lonely = capture("lonely-question-hit");
const processResult = capture("process-only-hit");
const questionView = capture("answer-only-hit", "questions");
const sourceMutated = CURRENT_DETAIL.events.some(event =>
  Object.prototype.hasOwnProperty.call(event, "isDirectSearchHit") ||
  Object.prototype.hasOwnProperty.call(event, "isSearchCompanion")
);
console.log(JSON.stringify({
  question,
  answer,
  both,
  lonely,
  processResult,
  questionView,
  sourceMutated
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20

        ($result.question.kinds -join ',') | Should Be 'user,assistant_final,assistant_final'
        ($result.question.direct -join ',') | Should Be 'True,False,False'
        ($result.question.companion -join ',') | Should Be 'False,True,True'
        $result.question.markup | Should Match 'is-search-direct-hit'
        $result.question.markup | Should Match 'is-search-companion'

        ($result.answer.kinds -join ',') | Should Be 'user,assistant_final,assistant_final'
        ($result.answer.direct -join ',') | Should Be 'False,False,True'
        ($result.answer.companion -join ',') | Should Be 'True,True,False'
        ($result.answer.text -join '|') | Should Not Match 'both-hit second answer'

        ($result.both.kinds -join ',') | Should Be 'user,assistant_final'
        ($result.both.direct -join ',') | Should Be 'True,True'
        ($result.both.companion -join ',') | Should Be 'False,False'
        ($result.lonely.kinds -join ',') | Should Be 'user'

        ($result.processResult.kinds -join ',') | Should Be 'user,tool'
        ($result.processResult.companion -join ',') | Should Be 'True,False'
        ($result.processResult.text -join '|') | Should Not Match 'unmatched process answer'
        $result.processResult.markup | Should Match '执行过程'
        @($result.questionView.kinds).Count | Should Be 0
        $result.sourceMutated | Should Be $false
        $html | Should Not Match 'context-label'
        $html | Should Not Match '上下文提问'
        $html | Should Match '\.message\.is-search-direct-hit'
        $html | Should Match '\.message\.is-search-companion'
    }

    It 'associates every final answer with the preceding V0.28 question key' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function escapeHtml\(value\) \{[\s\S]*?\n    \}(?=\n\n    function renderViewer)/);
if (!match) throw new Error("reader render helpers not found");
var messageCopyTexts = new Map();
var messageCopySerial = 0;
var lazyDetailRenderers = new Map();
var lazyDetailSerial = 0;
var noteDisplayMode = "hover";
var pinnedNotesLayer = null;
var pinnedNotesFrame = 0;
eval(match[0]);
const markup = buildReaderMarkup([
  { kind: "user", questionKey: "question-1", rawText: "first question" },
  { kind: "assistant_final", rawText: "first answer" },
  { kind: "assistant_final", rawText: "second answer" },
  { kind: "user", questionKey: "question-2", rawText: "second question" },
  { kind: "assistant_final", rawText: "third answer" }
], {});
console.log(JSON.stringify({ markup }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        ([regex]::Matches($result.markup, 'data-answer-for-question-key="question-1"')).Count | Should Be 2
        ([regex]::Matches($result.markup, 'data-answer-for-question-key="question-2"')).Count | Should Be 1
        $html | Should Match 'function findAnswerElement\(questionKey\)'
    }

    It 'handles V0.28 transcript Enter without changing the selected question or input behavior' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const findMatch = html.match(/function findAnswerElement\(questionKey\) \{[\s\S]*?\n    \}/);
const enterMatch = html.match(/function handleTranscriptEnter\(event\) \{[\s\S]*?\n    \}(?=\n\n    function handleQuestionSelectionFromRender)/);
if (!findMatch || !enterMatch) throw new Error("V0.28 answer Enter helpers not found");

const answers = [{ dataset: { answerForQuestionKey: "question-1" }, id: "answer-1" }];
const transcript = {
  contains(node) { return node === this || node === textTarget; },
  querySelectorAll(selector) { return selector === "[data-answer-for-question-key]" ? answers : []; }
};
const textTarget = {
  closest() { return null; }
};
const interactiveTarget = {
  closest(selector) { return selector.includes("button") ? this : null; }
};
const document = { activeElement: transcript };
const imagePreviewModal = { hidden: true };
const noteModal = { hidden: true };
let selectedQuestionKey = "question-1";
let selectedQuestionKeyIsTemporary = false;
let viewerViewMode = "all";
let pendingAnswerFocusQuestionKey = null;
let renderCalls = 0;
let anchorCalls = 0;
let selectionCalls = 0;
const scrolls = [];
const toasts = [];
function renderViewer() { renderCalls++; }
function scrollElementToTranscriptTop(element) { scrolls.push(element.id); return true; }
function showToast(message, options) { toasts.push({ message, options }); }
function saveProgressAnchorForCurrentSession() { anchorCalls++; }
function setSelectedQuestionKey() { selectionCalls++; }
eval(findMatch[0] + "\n" + enterMatch[0]);

function makeEvent(overrides = {}) {
  return Object.assign({
    key: "Enter",
    target: textTarget,
    isComposing: false,
    shiftKey: false,
    ctrlKey: false,
    altKey: false,
    metaKey: false,
    prevented: 0,
    preventDefault() { this.prevented++; }
  }, overrides);
}

const directEvent = makeEvent();
const directHandled = handleTranscriptEnter(directEvent);
const direct = {
  handled: directHandled,
  prevented: directEvent.prevented,
  selectedQuestionKey,
  scrolls: scrolls.slice(),
  renderCalls,
  anchorCalls,
  selectionCalls
};

scrolls.length = 0;
viewerViewMode = "questions";
const questionsEvent = makeEvent();
const questionsHandled = handleTranscriptEnter(questionsEvent);
const questions = {
  handled: questionsHandled,
  viewerViewMode,
  pendingAnswerFocusQuestionKey,
  renderCalls,
  scrollCount: scrolls.length
};

viewerViewMode = "all";
pendingAnswerFocusQuestionKey = null;
answers.length = 0;
const missingHandled = handleTranscriptEnter(makeEvent());

const guardedEvents = [
  makeEvent({ target: interactiveTarget }),
  makeEvent({ isComposing: true }),
  makeEvent({ shiftKey: true }),
  makeEvent({ ctrlKey: true }),
  makeEvent({ altKey: true }),
  makeEvent({ metaKey: true })
];
const guardedResults = guardedEvents.map(event => handleTranscriptEnter(event));
console.log(JSON.stringify({
  direct,
  questions,
  missingHandled,
  toasts,
  guardedResults,
  guardedPrevented: guardedEvents.map(event => event.prevented),
  finalSelectedQuestionKey: selectedQuestionKey,
  finalAnchorCalls: anchorCalls,
  finalSelectionCalls: selectionCalls
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20

        $result.direct.handled | Should Be $true
        $result.direct.prevented | Should Be 1
        $result.direct.selectedQuestionKey | Should Be 'question-1'
        ($result.direct.scrolls -join ',') | Should Be 'answer-1'
        $result.direct.renderCalls | Should Be 0
        $result.direct.anchorCalls | Should Be 0
        $result.direct.selectionCalls | Should Be 0

        $result.questions.handled | Should Be $true
        $result.questions.viewerViewMode | Should Be 'all'
        $result.questions.pendingAnswerFocusQuestionKey | Should Be 'question-1'
        $result.questions.renderCalls | Should Be 1
        $result.questions.scrollCount | Should Be 0

        $result.missingHandled | Should Be $false
        $result.toasts[0].message | Should Be '该提问暂时没有最终回答'
        $result.toasts[0].options.duration | Should Be 2200
        ($result.guardedResults -join ',') | Should Be 'False,False,False,False,False,False'
        ($result.guardedPrevented -join ',') | Should Be '0,0,0,0,0,0'
        $result.finalSelectedQuestionKey | Should Be 'question-1'
        $result.finalAnchorCalls | Should Be 0
        $result.finalSelectionCalls | Should Be 0
        $html | Should Match "if \(event\.key === 'Enter'\) \{[\s\S]*?handleTranscriptEnter\(event\)"
        $handleSource = [regex]::Match($html, 'function handleTranscriptEnter\(event\) \{[\s\S]*?\n    \}(?=\n\n    function handleQuestionSelectionFromRender)').Value
        $handleSource | Should Not Match 'setSelectedQuestionKey\(|scrollToQuestion\(|saveProgressAnchorForCurrentSession\('
    }

    It 'consumes pending V0.28 answer focus with one render scroll and suppresses question scrolling' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const renderMatch = html.match(/function renderViewer\(\) \{[\s\S]*?\n    \}(?=\n\n    async function selectSessionFromTitlePane)/);
if (!renderMatch) throw new Error("renderViewer not found");
const session = { key: "session-1", path: "demo.jsonl", createdLocal: "2026-07-19", userCount: 1, assistantCount: 1 };
const viewerHead = { innerHTML: "" };
const transcript = { innerHTML: "" };
let viewerSearchQuery = "";
let viewerSearchQuestionsOnly = false;
let viewerViewMode = "all";
let selectedQuestionKey = "question-1";
let selectedQuestionKeyIsTemporary = false;
let pendingQuestionFocus = null;
let pendingAnswerFocusQuestionKey = "question-1";
let rafCallbacks = [];
let answerScrolls = 0;
let questionScrolls = 0;
let toasts = 0;
function requestAnimationFrame(callback) { rafCallbacks.push(callback); return rafCallbacks.length; }
function getSelectedSession() { return session; }
function getGlobalSearchQuery() { return ""; }
function getEmptySourceText() { return ""; }
function getGlobalSearchEmptyText() { return ""; }
function sessionMatchesGlobalSearch() { return true; }
function escapeHtml(value) { return String(value || ""); }
function syncViewerToolbar() {}
function isDetailLoadedForSession() { return true; }
function getVisibleDetailEvents() { return [{ kind: "user", questionKey: "question-1" }, { kind: "assistant_final" }]; }
function syncSelectedQuestionKey() {}
function resetMessageCopyTexts() {}
function buildReaderMarkup() { return '<article data-question-key="question-1"></article><article data-answer-for-question-key="question-1"></article>'; }
function hydrateOpenLazyDetails() {}
function highlightMatchesInElement() {}
function getSearchTerms() { return []; }
function highlightCurrentQuestion() {}
function updateReplyComposerState() {}
function findAnswerElement(key) { return key === "question-1" && transcript.innerHTML.includes('data-answer-for-question-key="question-1"') ? { key } : null; }
function scrollElementToTranscriptTop() { answerScrolls++; return true; }
function scrollToQuestion() { questionScrolls++; return true; }
function showToast() { toasts++; }
eval(renderMatch[0]);
renderViewer();
const beforeFrames = { pendingAnswerFocusQuestionKey, rafCount: rafCallbacks.length, answerScrolls, questionScrolls };
while (rafCallbacks.length) rafCallbacks.shift()();
console.log(JSON.stringify({
  beforeFrames,
  afterFrames: { pendingAnswerFocusQuestionKey, answerScrolls, questionScrolls, toasts, selectedQuestionKey }
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.beforeFrames.pendingAnswerFocusQuestionKey | Should BeNullOrEmpty
        $result.beforeFrames.rafCount | Should Be 1
        $result.beforeFrames.answerScrolls | Should Be 0
        $result.beforeFrames.questionScrolls | Should Be 0
        $result.afterFrames.answerScrolls | Should Be 1
        $result.afterFrames.questionScrolls | Should Be 0
        $result.afterFrames.toasts | Should Be 0
        $result.afterFrames.selectedQuestionKey | Should Be 'question-1'
    }

    It 'scrolls a V0.28 answer to the transcript top with one bounded auto correction path' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const cancelMatch = html.match(/function cancelQuestionScrollAnimation\(\) \{[\s\S]*?\n    \}(?=\n\n    function lockTranscriptLayoutForProgrammaticScroll)/);
const lockMatch = html.match(/function lockTranscriptLayoutForProgrammaticScroll\([^)]*\) \{[\s\S]*?\n    \}(?=\n\n    function unlockTranscriptLayoutForProgrammaticScroll)/);
const unlockMatch = html.match(/function unlockTranscriptLayoutForProgrammaticScroll\(\) \{[\s\S]*?\n    \}(?=\n\n    function calculateTranscriptScrollSpacer)/);
const spacerMatch = html.match(/function calculateTranscriptScrollSpacer\(element\) \{[\s\S]*?\n    \}/);
const answerScrollMatch = html.match(/function scrollElementToTranscriptTop\(element\) \{[\s\S]*?\n    \}(?=\n\n    function scrollTranscriptTo)/);
if (!cancelMatch || !lockMatch || !unlockMatch || !spacerMatch || !answerScrollMatch) {
  throw new Error("V0.28 answer scroll helpers not found");
}
let activeQuestionScrollAnimation = 0;
let activeQuestionScrollToken = 0;
let transcriptLayoutLockTimer = 0;
let rafCallbacks = [];
let timeoutCallbacks = [];
let spacerPixels = 0;
let lockAdds = 0;
let lockRemoves = 0;
const scrollCalls = [];
const styleCalls = [];
function requestAnimationFrame(callback) { rafCallbacks.push(callback); return rafCallbacks.length; }
function cancelAnimationFrame() {}
function setTimeout(callback) { timeoutCallbacks.push(callback); return timeoutCallbacks.length; }
function clearTimeout() {}
const answer = {
  offsetTop: 126,
  offsetHeight: 92,
  getBoundingClientRect() { return { top: 100 + this.offsetTop - transcript.scrollTop }; }
};
const transcript = {
  scrollTop: 0,
  get scrollHeight() { return Math.max(this.clientHeight, 362 + spacerPixels); },
  clientHeight: 410,
  classList: {
    add() { lockAdds++; },
    remove() {
      lockRemoves++;
      transcript.scrollTop = 0;
    }
  },
  style: {
    setProperty(name, value) {
      styleCalls.push({ name, value });
      if (name === '--transcript-scroll-spacer') spacerPixels = Number.parseFloat(value) || 0;
    }
  },
  getBoundingClientRect() { return { top: 100 }; },
  scrollTo(args) {
    scrollCalls.push(args);
    this.scrollTop = Math.max(0, Math.min(args.top, this.scrollHeight - this.clientHeight));
  }
};
eval(cancelMatch[0] + "\n" + lockMatch[0] + "\n" + unlockMatch[0] + "\n" + spacerMatch[0] + "\n" + answerScrollMatch[0]);
const started = scrollElementToTranscriptTop(answer);
let frames = 0;
while (rafCallbacks.length && frames < 4) {
  rafCallbacks.shift()();
  frames++;
}
console.log(JSON.stringify({
  started,
  frames,
  lockAdds,
  lockRemoves,
  scrollCalls,
  styleCalls,
  finalScrollTop: transcript.scrollTop,
  finalAnswerTop: answer.getBoundingClientRect().top - transcript.getBoundingClientRect().top,
  finalSpacer: spacerPixels
}));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20

        $result.started | Should Be $true
        $result.lockAdds | Should Be 1
        $result.lockRemoves | Should Be 1
        @($result.scrollCalls).Count | Should Be 2
        $result.scrollCalls[0].top | Should Be 110
        $result.scrollCalls[0].behavior | Should Be 'auto'
        $result.scrollCalls[1].top | Should Be 110
        $result.scrollCalls[1].behavior | Should Be 'auto'
        $result.finalScrollTop | Should Be 110
        $result.finalAnswerTop | Should Be 16
        $result.finalSpacer | Should BeGreaterThan 126
        $result.styleCalls[0].name | Should Be '--transcript-scroll-spacer'
        $result.styleCalls[0].value | Should Match 'px$'
        $html | Should Not Match 'calculateQuestionScrollSpacer'
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
        $html | Should Match '@media \(max-width: 640px\) \{\s*#viewerToolbar \{ padding-right: 72px; \}'
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
const defaultFocusCalls = focusCalls;
focusCalls = 0;
scrollCalls = 0;
const restoredWithoutFocus = restoreProgressAnchor(anchor, { token: 1, behavior: "auto", focusOnComplete: false });
while (rafCallbacks.length && frames < 16) {
  const callback = rafCallbacks.shift();
  callback();
  frames += 1;
}
console.log(JSON.stringify({ restored, restoredWithoutFocus, frames, scrollCalls, defaultFocusCalls, preservedFocusCalls: focusCalls, selectedQuestionKey, selectedQuestionKeyIsTemporary }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20

        $result.restored | Should Be $true
        $result.restoredWithoutFocus | Should Be $true
        [int]$result.scrollCalls | Should BeGreaterThan 2
        $result.defaultFocusCalls | Should Be 1
        $result.preservedFocusCalls | Should Be 0
        $result.selectedQuestionKey | Should Be 'session-1::question::2'
        $result.selectedQuestionKeyIsTemporary | Should Be $false
        $html | Should Match 'restoreCurrentProgressAnchorIfReadable\(\{ focusOnComplete: false \}\)'
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

        $html | Should Match '<span class="version-badge">V0\.34</span>'
        $html | Should Not Match '<span class="version-badge">V0\.12\.1</span>'
        $buildSource | Should Match '\$builderVersion = "V0\.34"'
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
        $html | Should Match '<label class="source-selector" for="sourceSelect"><select id="sourceSelect" aria-label="选择聊天记录来源">'
        $html | Should Not Match '来源：<select id="sourceSelect"'
        $html | Should Match '<button type="button" id="refreshButton"'
        $html.IndexOf('<select id="sourceSelect"') -lt $html.IndexOf('<button type="button" id="refreshButton"') | Should Be $true
        $html | Should Match 'const SOURCES_API_URL = ''/api/sources'''
        $html | Should Match 'let currentSourceId = ''local-codex'''
        $html | Should Match 'async function loadSources\(\)'
        $html | Should Match 'async function switchSource\(sourceId\)'
        $html | Should Match 'function getCurrentSourceId\(\)'
        $html | Should Match 'function buildSourceUrl\(url\)'
        $html | Should Match 'fetch\(buildSourceUrl\(INDEX_URL\), \{ cache: ''no-store'' \}\)'
        $html | Should Match 'SEARCH_API_URL \+ ''\?sourceId='' \+ encodeURIComponent\(getCurrentSourceId\(\)\) \+ ''&field='' \+ encodeURIComponent\(normalizedField\) \+ ''&q='''
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
let failedImageCacheClearCalls = 0;
function clearFailedMessageImageCache() {
  failedImageCacheClearCalls += 1;
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
    selectedSessionKey,
    failedImageCacheClearCalls
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
        $result.failedImageCacheClearCalls | Should Be 1
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

    It 'redirects root and legacy HTML routes to the V0.27 temp entry path' {
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

print(json.dumps({
    "entryPath": module.ENTRY_PATH,
    "legacyRootPath": f"/{module.ROOT.name}/CodexChatIndex.html",
    "results": results
}, ensure_ascii=False))
'@
        $result = python -c $python $serverScript | ConvertFrom-Json -Depth 20
        foreach ($path in @('/', '/CodexChatIndex.html', [string]$result.legacyRootPath)) {
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
        paths["search"].write_text(json.dumps({"version": 4, "part": "questions", "sessions": []}), encoding="utf-8")
        paths["search_other"].write_text(json.dumps({"version": 4, "part": "other", "sessions": []}), encoding="utf-8")
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
    paths["search"].write_text(json.dumps({"version": 4, "part": "questions", "sessions": []}), encoding="utf-8")
    paths["search_other"].write_text(json.dumps({"version": 4, "part": "other", "sessions": []}), encoding="utf-8")

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

    It 'syncs the generated page at startup when the template is newer' {
        $python = @'
import importlib.util
import json
import os
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
    module.HTML_FILE.write_text("old html", encoding="utf-8")
    module.TEMPLATE_FILE = module.ROOT / "templates" / "CodexChatIndex.template.html"
    module.TEMPLATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    module.TEMPLATE_FILE.write_text("new template", encoding="utf-8")
    os.utime(module.HTML_FILE, (1000, 1000))
    os.utime(module.TEMPLATE_FILE, (2000, 2000))
    paths = module.get_source_paths("local-codex")
    paths["root"].mkdir(parents=True, exist_ok=True)
    paths["data"].write_text(json.dumps({"workspaces": []}), encoding="utf-8")
    paths["search"].write_text(json.dumps({"version": 4, "part": "questions", "sessions": []}), encoding="utf-8")
    paths["search_other"].write_text(json.dumps({"version": 4, "part": "other", "sessions": []}), encoding="utf-8")

    build_calls = []
    module.run_build = lambda refresh_mode="Incremental", current_session_path=None, source_id="local-codex": (build_calls.append(refresh_mode) or (True, "template synced", {}))

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
        ($result.buildCalls -join ',') | Should Be 'Incremental'
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
        $serverSource | Should Match 'def discover_sources\(persist: bool = True\)'
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
    module.os.environ["COMPUTERNAME"] = "Demo-PC"
    sources_payload = module.discover_sources()
    print(json.dumps(sources_payload))
'@
        $result = python -c $python $serverScript | ConvertFrom-Json -Depth 20
        $result.selectedSourceId | Should Be 'local-codex'
        @($result.sources).Count | Should Be 4
        @($result.sources | Where-Object { $_.id -eq 'local-codex' -and $_.label -eq 'Demo-PC-本机 Codex' -and $_.type -eq 'local-codex' }).Count | Should Be 1
        @($result.sources | Where-Object { $_.id -eq 'local-claude' -and $_.label -eq 'Demo-PC-本机 Claude' -and $_.type -eq 'local-claude' }).Count | Should Be 1
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
module.os.environ["COMPUTERNAME"] = "Demo-PC"

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
        @($result.sources | Where-Object { $_.id -eq 'local-codex' -and $_.label -eq 'Demo-PC-本机 Codex' -and $_.type -eq 'local-codex' }).Count | Should Be 1
        @($result.sources | Where-Object { $_.id -eq 'local-claude' -and $_.label -eq 'Demo-PC-本机 Claude' -and $_.type -eq 'local-claude' }).Count | Should Be 1
        @($result.sources | Where-Object { $_.label -eq 'Alpha' -and $_.type -eq 'external-codex-jsonl' }).Count | Should Be 1
    }

    It 'uses V0.27 machine-prefixed local labels with generic empty-name fallbacks' {
        $python = @'
import importlib.util
import json
import pathlib
import sys

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("codex_chat_index_server", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.os.environ["COMPUTERNAME"] = "Demo-PC"
prefixed = {
    "codex": module.local_source(),
    "claude": module.local_claude_source(),
}
module.os.environ["COMPUTERNAME"] = " "
module.socket.gethostname = lambda: ""
fallback = {
    "codex": module.local_source(),
    "claude": module.local_claude_source(),
}
print(json.dumps({"prefixed": prefixed, "fallback": fallback}))
'@
        $result = python -c $python $serverScript | ConvertFrom-Json -Depth 20
        $result.prefixed.codex.label | Should Be 'Demo-PC-本机 Codex'
        $result.prefixed.claude.label | Should Be 'Demo-PC-本机 Claude'
        $result.prefixed.codex.id | Should Be 'local-codex'
        $result.prefixed.claude.id | Should Be 'local-claude'
        $result.fallback.codex.label | Should Be '本机 Codex'
        $result.fallback.claude.label | Should Be '本机 Claude'

        $buildSource = Get-Content -LiteralPath $buildScript -Raw
        $buildSource | Should Match 'function Get-LocalSourceLabel'
        $html | Should Match 'sourceSelect\.title = label'
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
    paths["search"].write_text(json.dumps({"version": 4, "part": "questions", "sessions": [{"key": "external-key", "title": "Alpha", "cwd": "M:/Alpha", "path": "alpha.jsonl", "questionTexts": []}]}), encoding="utf-8")
    paths["search_other"].write_text(json.dumps({"version": 4, "part": "other", "sessions": [{"key": "external-key", "otherText": "needle"}]}), encoding="utf-8")
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

    It 'uses field-aware AND semantics without combining separate questions or answers into a question hit' {
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
    question_sessions = [
        {"key": "both", "title": "Both", "cwd": "M:/Demo", "path": "both.jsonl", "questionTexts": ["exit code together"]},
        {"key": "split", "title": "Split", "cwd": "M:/Demo", "path": "split.jsonl", "questionTexts": ["exit only"]},
        {"key": "two-questions", "title": "Two questions", "cwd": "M:/Demo", "path": "two.jsonl", "questionTexts": ["exit only", "code only"]},
        {"key": "answer", "title": "Answer", "cwd": "M:/Demo", "path": "answer.jsonl", "questionTexts": ["ordinary question"]},
        {"key": "phrase", "title": "Phrase", "cwd": "M:/Demo", "path": "phrase.jsonl", "questionTexts": ["exit code adjacent"]}
    ]
    paths["search"].write_text(json.dumps({
        "version": 4,
        "part": "questions",
        "sessions": question_sessions
    }), encoding="utf-8")
    questions_without_other = [row["key"] for row in module.search_sessions("exit code", "local-codex", "questions")]
    paths["search_other"].write_text(json.dumps({
        "version": 4,
        "part": "other",
        "sessions": [
            {"key": "both", "otherText": ""},
            {"key": "split", "otherText": "answer has code"},
            {"key": "two-questions", "otherText": ""},
            {"key": "answer", "otherText": "exit code in answer"},
            {"key": "phrase", "otherText": ""}
        ]
    }), encoding="utf-8")
    invalid_error = ""
    try:
        module.search_sessions("exit", "local-codex", "invalid")
    except ValueError as error:
        invalid_error = str(error)
    print(json.dumps({
        "exitCode": [row["key"] for row in module.search_sessions(" exit   code ", "local-codex", "all")],
        "codeExit": [row["key"] for row in module.search_sessions("code exit", "local-codex")],
        "questions": [row["key"] for row in module.search_sessions("exit code", "local-codex", "questions")],
        "questionsWithoutOther": questions_without_other,
        "blank": module.search_sessions("   ", "local-codex", "questions"),
        "invalid": invalid_error
    }))
'@
        $result = python -c $python $serverScript | ConvertFrom-Json -Depth 20

        ($result.exitCode -join ',') | Should Be 'both,split,two-questions,answer,phrase'
        ($result.codeExit -join ',') | Should Be 'both,split,two-questions,answer,phrase'
        ($result.questions -join ',') | Should Be 'both,phrase'
        ($result.questionsWithoutOther -join ',') | Should Be 'both,phrase'
        @($result.blank).Count | Should Be 0
        $result.invalid | Should Match 'field'
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
            "version": 4,
            "part": "questions",
            "sessions": [
                {"key": source_id, "title": source_id, "cwd": "M:/Demo", "path": source_id + ".jsonl", "questionTexts": [source_id + " needle " + ("x" * 80)]}
            ]
        }
        paths["search"].write_text(json.dumps(payload), encoding="utf-8")
        module.search_sessions("needle", source_id, "questions")

    print(json.dumps({
        "cached": list(module._search_index_cache.keys()),
        "sizes": dict(module._search_index_cache_sizes),
        "hitsC": [row["key"] for row in module.search_sessions("needle", "source-c", "questions")]
    }))
'@
        $result = python -c $python $serverScript | ConvertFrom-Json -Depth 20

        ($result.cached -contains 'source-a::questions') | Should Be $false
        ($result.cached -contains 'source-c::questions') | Should Be $true
        ($result.hitsC -join ',') | Should Be 'source-c'
    }

    It 'keeps the questions index cached when the other index is too large to cache' {
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
    module.ROOT = tmp_root / "V0.30"
    module.ROOT.mkdir(parents=True, exist_ok=True)
    module.SERVE_ROOT = tmp_root
    module.RUNTIME_DATA_DIR = tmp_root / "runtime"
    module.SOURCES_FILE = module.RUNTIME_DATA_DIR / "CodexChatIndex.sources.json"
    module.EXTERNAL_SOURCES_ROOT = tmp_root / "external"
    module.SEARCH_INDEX_CACHE_MAX_BYTES = 1024
    module.SEARCH_INDEX_CACHE_MAX_ENTRIES = 8
    module._search_index_cache.clear()
    module._search_index_mtime_ns.clear()
    module._search_index_cache_sizes.clear()
    module._search_index_access_order.clear()

    paths = module.get_source_paths("local-codex")
    paths["root"].mkdir(parents=True, exist_ok=True)
    paths["search"].write_text(json.dumps({
        "version": 4,
        "part": "questions",
        "sessions": [{
            "key": "cached-question",
            "title": "Cached question",
            "cwd": "M:/Demo",
            "path": "cached.jsonl",
            "questionTexts": ["question needle"]
        }]
    }), encoding="utf-8")
    paths["search_other"].write_text(json.dumps({
        "version": 4,
        "part": "other",
        "sessions": [{"key": "cached-question", "otherText": "answer needle " + ("x" * 4096)}]
    }), encoding="utf-8")

    question_hits = [row["key"] for row in module.search_sessions("question needle", "local-codex", "questions")]
    all_hits = [row["key"] for row in module.search_sessions("answer needle", "local-codex", "all")]
    print(json.dumps({
        "questionHits": question_hits,
        "allHits": all_hits,
        "cached": list(module._search_index_cache.keys()),
        "sizes": dict(module._search_index_cache_sizes)
    }))
'@
        $result = python -c $python $serverScript | ConvertFrom-Json -Depth 20

        ($result.questionHits -join ',') | Should Be 'cached-question'
        ($result.allHits -join ',') | Should Be 'cached-question'
        ($result.cached -contains 'local-codex::questions') | Should Be $true
        ($result.cached -contains 'local-codex::other') | Should Be $false
        [int]$result.sizes.'local-codex::questions' | Should BeGreaterThan 0
    }

    It 'sets a recognizable title on the opened cmd window' {
        $openCmd = Get-Content -LiteralPath (Join-Path $projectRoot 'Open-CodexChatIndex.cmd') -Raw
        $openCmd | Should Match '(?mi)^title Open-CodexChatIndex V0\.34 - Local Server Running'
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

    It 'keeps the build cmd on CRLF line endings for cmd.exe' {
        $buildCmdBytes = [IO.File]::ReadAllBytes((Join-Path $projectRoot 'Build-CodexChatIndex.cmd'))
        $lineFeedIndexes = @(for ($index = 0; $index -lt $buildCmdBytes.Length; $index++) {
            if ($buildCmdBytes[$index] -eq 10) { $index }
        })
        $bareLineFeeds = @($lineFeedIndexes | Where-Object {
            $_ -eq 0 -or $buildCmdBytes[$_ - 1] -ne 13
        })

        $lineFeedIndexes.Count | Should BeGreaterThan 0
        $bareLineFeeds.Count | Should Be 0
    }

    It 'pins cmd checkout line endings to CRLF in git' {
        $attributesPath = Join-Path $projectRoot '.gitattributes'
        (Test-Path -LiteralPath $attributesPath -PathType Leaf) | Should Be $true
        (Get-Content -LiteralPath $attributesPath -Raw) | Should Match '(?m)^\*\.cmd text eol=crlf\s*$'
    }

    It 'keeps the cmd launcher ASCII-only so cmd.exe does not misparse UTF-8 Chinese bytes' {
        $openCmd = Get-Content -LiteralPath (Join-Path $projectRoot 'Open-CodexChatIndex.cmd') -Raw
        $openCmd | Should Not Match '[^\u0000-\u007F]'
    }

    It 'exports a complete local Codex sync inventory without writing build outputs' {
        $caseRoot = Join-Path $tempRoot 'v029-inventory'
        $caseCodexHome = Join-Path $caseRoot 'codex-home'
        $inventoryPath = Join-Path $caseRoot 'task\inventory.json'
        $isolatedData = Join-Path $caseRoot 'data'
        $isolatedHtml = Join-Path $caseRoot 'output.html'
        $sessionTarget = Join-Path $caseCodexHome 'sessions\2026\04\24\session.jsonl'
        $archiveTarget = Join-Path $caseCodexHome 'archived_sessions\2026\04\25\archive.jsonl'
        New-Item -ItemType Directory -Force (Split-Path -Parent $sessionTarget), (Split-Path -Parent $archiveTarget) | Out-Null
        Copy-Item -LiteralPath (Join-Path $fixtureHome 'sessions\2026\04\24\rollout-2026-04-24T12-00-00-00000000-0000-0000-0000-000000000001.jsonl') -Destination $sessionTarget
        Copy-Item -LiteralPath (Join-Path $fixtureHome 'sessions\2026\04\25\rollout-2026-04-25T09-00-00-22222222-2222-2222-2222-222222222222.jsonl') -Destination $archiveTarget

        & $buildScript `
            -CodexHome $caseCodexHome `
            -OutputPath $isolatedHtml `
            -DataRoot $isolatedData `
            -SourceId 'local-codex' `
            -SourceType 'local-codex' `
            -ExportSyncInventoryPath $inventoryPath `
            -JsonSummary | Out-Null

        (Test-Path -LiteralPath $inventoryPath -PathType Leaf) | Should Be $true
        (Test-Path -LiteralPath $isolatedHtml) | Should Be $false
        (Test-Path -LiteralPath $isolatedData) | Should Be $false
        $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json -Depth 100
        $inventory.scanComplete | Should Be $true
        @($inventory.errors).Count | Should Be 0
        $inventory.sourceId | Should Be 'local-codex'
        $inventory.sourceType | Should Be 'local-codex'
        @($inventory.files).Count | Should Be 2
        @($inventory.files | Where-Object { $_.rootKind -eq 'sessions' }).Count | Should Be 1
        @($inventory.files | Where-Object { $_.rootKind -eq 'archived_sessions' }).Count | Should Be 1
        @($inventory.files | Where-Object { $_.recordFormat -ne 'jsonl' }).Count | Should Be 0
        @($inventory.files | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.absolutePath) -or [string]::IsNullOrWhiteSpace([string]$_.logicalPath) }).Count | Should Be 0
    }

    It 'marks Claude sync inventory incomplete when an explicit scan root cannot be enumerated' {
        $caseRoot = Join-Path $tempRoot 'v029-claude-inventory-error'
        $invalidRoot = Join-Path $caseRoot 'not-a-directory.txt'
        $inventoryPath = Join-Path $caseRoot 'task\inventory.json'
        New-Item -ItemType Directory -Force $caseRoot | Out-Null
        Set-Content -LiteralPath $invalidRoot -Value 'not a directory' -Encoding UTF8

        & $buildScript `
            -ClaudeHome (Join-Path $caseRoot 'claude-home') `
            -ClaudeScanRoots @($invalidRoot) `
            -SourceId 'local-claude' `
            -SourceType 'local-claude' `
            -ExportSyncInventoryPath $inventoryPath `
            -JsonSummary | Out-Null

        $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json -Depth 100
        $inventory.scanComplete | Should Be $false
        @($inventory.errors).Count | Should BeGreaterThan 0
        @($inventory.files).Count | Should Be 0
    }

    It 'checks local source status without writing any existing build file' {
        $caseRoot = Join-Path $tempRoot 'v029-status'
        $caseData = Join-Path $caseRoot 'data'
        $caseHtml = Join-Path $caseRoot 'output.html'
        & $buildScript -CodexHome $fixtureHome -OutputPath $caseHtml -DataRoot $caseData -RefreshMode Full | Out-Null
        $before = @{}
        Get-ChildItem -LiteralPath $caseRoot -File -Recurse -Force | ForEach-Object {
            $before[$_.FullName] = [pscustomobject]@{
                Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                LastWrite = $_.LastWriteTimeUtc.Ticks
            }
        }

        $summaryText = & $buildScript `
            -CodexHome $fixtureHome `
            -OutputPath $caseHtml `
            -DataRoot $caseData `
            -SourceId 'local-codex' `
            -SourceType 'local-codex' `
            -StatusOnly `
            -JsonSummary
        $summary = $summaryText | Select-Object -Last 1 | ConvertFrom-Json -Depth 100
        $afterFiles = @(Get-ChildItem -LiteralPath $caseRoot -File -Recurse -Force)

        $summary.mode | Should Be 'StatusOnly'
        $summary.noChange | Should Be $true
        $summary.sourceSignature | Should Not BeNullOrEmpty
        $afterFiles.Count | Should Be $before.Count
        foreach ($file in $afterFiles) {
            (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash | Should Be $before[$file.FullName].Hash
            $file.LastWriteTimeUtc.Ticks | Should Be $before[$file.FullName].LastWrite
        }
    }

    It 'builds a read-only webdav Codex source only from its controlled raw root' {
        $caseRoot = Join-Path $tempRoot 'v029-remote'
        $remoteRoot = Join-Path $caseRoot 'raw'
        $remoteSession = Join-Path $remoteRoot 'sessions\2026\04\24\remote.jsonl'
        $originMapPath = Join-Path $caseRoot 'origin-map.json'
        $caseData = Join-Path $caseRoot 'data'
        $caseHtml = Join-Path $caseRoot 'output.html'
        New-Item -ItemType Directory -Force (Split-Path -Parent $remoteSession) | Out-Null
        Copy-Item -LiteralPath (Join-Path $fixtureHome 'sessions\2026\04\24\rollout-2026-04-24T12-00-00-00000000-0000-0000-0000-000000000001.jsonl') -Destination $remoteSession
        [ordered]@{
            'sessions/2026/04/24/remote.jsonl' = 'C:/Users/Source/.codex/sessions/2026/04/24/remote.jsonl'
        } | ConvertTo-Json | Set-Content -LiteralPath $originMapPath -Encoding UTF8

        & $buildScript `
            -OutputPath $caseHtml `
            -DataRoot $caseData `
            -SourceId 'webdav-11111111-1111-4111-8111-111111111111-22222222-2222-4222-8222-222222222222-local-codex' `
            -SourceLabel 'Laptop-云端 Codex' `
            -SourceType 'webdav-codex' `
            -RemoteSourceRoot $remoteRoot `
            -OriginMapPath $originMapPath `
            -DisableLocalPathImages `
            -RefreshMode Full | Out-Null

        $sourceRoot = Get-TestSourceRoot $caseData 'webdav-11111111-1111-4111-8111-111111111111-22222222-2222-4222-8222-222222222222-local-codex'
        $data = Get-Content -LiteralPath (Join-Path $sourceRoot 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $session = @($data.workspaces | ForEach-Object { @($_.sessions) } | Select-Object -First 1)
        $data.source.type | Should Be 'webdav-codex'
        $data.source.capabilities.isReadOnly | Should Be $true
        $data.source.capabilities.canDownload | Should Be $true
        $data.source.capabilities.canReply | Should Be $false
        $data.source.capabilities.canResolveLocalImages | Should Be $false
        $session.path | Should Be 'C:/Users/Source/.codex/sessions/2026/04/24/remote.jsonl'
    }

    It 'renders V0.29 cloud settings and contextual transfer controls' {
        $html | Should Match 'id="cloudSettingsButton"'
        $html | Should Match 'id="syncButton"'
        $html | Should Match 'id="webdavModal"'
        $html | Should Match 'id="webdavBaseUrl"'
        $html | Should Match 'id="webdavUsername"'
        $html | Should Match 'id="webdavPassword"'
        $html | Should Match 'id="webdavRemoteRoot"'
        $html | Should Match 'id="webdavDeviceName"'
        $html | Should Match 'id="webdavTaskProgress"'
        $html | Should Match 'id="webdavCacheList"'
        $html | Should Match 'function formatWebdavTaskError\(task\)'
        $html | Should Match 'Retry-After:'
        $html | Should Match 'value\.lastCheck\.message'
        $html | Should Match '!payload\.ok'
        $html | Should Match '标准条件请求模式检查通过'
        $html | Should Match '坚果云兼容提交模式检查通过'
    }

    It 'preserves the server safety reason when a WebDAV check is blocked' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/async function webdavMutation\(path, body, method\) \{[\s\S]*?\n    \}(?=\n\n    async function openWebdavSettings)/);
if (!match) throw new Error("WebDAV mutation helper not found");
const WEBDAV_API_ROOT = "/api/webdav";
async function mutationFetch() {
  return {
    ok: true,
    status: 200,
    json: async () => ({
      ok: false,
      message: "WebDAV 安全提交能力不足，同步已被阻止"
    })
  };
}
eval(match[0]);
(async () => {
  try {
    await webdavMutation("/check", {});
    throw new Error("blocked response unexpectedly succeeded");
  } catch (error) {
    console.log(JSON.stringify({ message: error.message }));
  }
})().catch(error => {
  console.error(error);
  process.exit(1);
});
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.message | Should Be 'WebDAV 安全提交能力不足，同步已被阻止'
    }

    It 'renders complete WebDAV task errors as escaped plain text' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function formatWebdavTaskError\(task\) \{[\s\S]*?\n    \}(?=\n\n    function renderWebdavTask)/);
if (!match) throw new Error("WebDAV task error formatter not found");
eval(match[0]);
const value = formatWebdavTaskError({
  action: "download",
  stage: "下载对象<img src=x onerror=alert(1)>",
  httpStatus: 429,
  errorReason: "请求过多<script>alert(1)</script>",
  retryAfter: "60",
  updatedAt: "2026-08-02T01:02:03Z",
  errorTarget: "https://dav.example.test/dav/item",
  errorSummary: "fallback"
});
console.log(JSON.stringify({ value }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 10

        $result.value | Should Match '操作：下载'
        $result.value | Should Match '阶段：下载对象<img src=x onerror=alert\(1\)>'
        $result.value | Should Match 'HTTP 状态：429'
        $result.value | Should Match '原因：请求过多<script>alert\(1\)</script>'
        $result.value | Should Match 'Retry-After: 60'
        $result.value | Should Match '发生时间：2026-08-02T01:02:03Z'
        $result.value | Should Match '脱敏地址：https://dav\.example\.test/dav/item'
        $result.value | Should Match '建议检查：'
        $html | Should Match 'webdavTaskText\.textContent = formatWebdavTaskError\(current\)'
        $html | Should Not Match 'webdavTaskText\.innerHTML'
    }

    It 'routes every browser mutation through the V0.29 same-origin token helper' {
        $html | Should Match "const SESSION_TOKEN_API_URL = '/api/session-token'"
        $html | Should Match 'async function loadSessionToken\(\)'
        $html | Should Match 'function mutationFetch\(url, options\)'
        $html | Should Match "headers\.set\('X-Yuji-Session-Token', apiSessionToken\)"
        $html | Should Not Match "(?<!mutation)fetch\(SOURCES_API_URL, \{\s*method: 'POST'"
        $html | Should Not Match "(?<!mutation)fetch\(NOTES_API_URL, \{\s*method: '(POST|DELETE)'"
        $html | Should Match "mutationFetch\(SOURCES_API_URL, \{\s*method: 'POST'"
        $html | Should Match "mutationFetch\(NOTES_API_URL, \{\s*method: 'POST'"
        $html | Should Match "mutationFetch\(NOTES_API_URL, \{\s*method: 'DELETE'"
    }

    It 'updates V0.29 cloud status and task progress without rebuilding transcript DOM' {
        $statusMatch = [regex]::Match($html, 'async function checkCurrentSourceStatus\([\s\S]*?\n    \}(?=\n\n    async function)')
        $taskMatch = [regex]::Match($html, 'async function pollWebdavTask\([\s\S]*?\n    \}(?=\n\n    function|\n\n    async function)')
        $statusMatch.Success | Should Be $true
        $taskMatch.Success | Should Be $true
        $statusMatch.Value | Should Not Match 'renderViewer\('
        $taskMatch.Value | Should Not Match 'renderViewer\('
        $html | Should Match 'getSourceCapability\(''canEditNotes''\)'
        $html | Should Match 'getSourceCapability\(''canReply''\)'
        $html | Should Match 'getSourceCapability\(''canQuickRefresh''\)'
    }

    It 'throttles background cloud status checks for 60 seconds but checks immediately after source switching' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const pollMatch = html.match(/async function pollWebdavTask\(\) \{[\s\S]*?\n    \}(?=\n\n    async function handleCompletedWebdavTask)/);
const switchMatch = html.match(/async function switchSource\(sourceId\) \{[\s\S]*?\n    \}(?=\n\n    async function loadSessionDetail)/);
if (!pollMatch || !switchMatch) throw new Error("cloud status functions not found");

let now = 100000;
Date.now = () => now;
const statusCalls = [];
const catalogCalls = [];
const webdavState = { pollTimer: 0, lastStatusCheckAt: now - 59999, task: null, lastTaskSignature: '' };
const document = { visibilityState: 'visible' };
function clearTimeout() {}
function setTimeout() { return 1; }
async function fetch() { return { ok: true, async json() { return { task: { status: 'idle' } }; } }; }
function renderWebdavTask(task) { webdavState.task = task; }
async function refreshCloudSources(force) { catalogCalls.push(force); }
async function checkCurrentSourceStatus(force) { statusCalls.push(force); }
function confirm() { return false; }
async function startCurrentSync() {}
async function handleCompletedWebdavTask() {}
function showToast() {}
function formatWebdavTaskError() { return ''; }
const WEBDAV_API_ROOT = '/api/webdav';
eval(pollMatch[0]);

let currentSourceId = 'local-codex';
const sourceSelect = { value: '' };
const viewerHead = { innerHTML: '' };
const transcript = { innerHTML: '' };
const sourceSwitchChecks = [];
function getCurrentSourceId() { return currentSourceId; }
async function saveSelectedSource() {}
function resetSourceScopedState() {}
async function loadIndex() {}
async function loadNotes() {}
function updateStats() {}
function refreshFilterMenus() {}
function renderWorkspaceList() {}
async function loadSelectedDetailIfAvailable() {}
function renderViewer() {}
function updateTopSourceActions() {}
function checkCurrentSourceStatusAfterSwitch(force) { sourceSwitchChecks.push(force); }
const originalCheck = checkCurrentSourceStatus;
eval(switchMatch[0].replace('void checkCurrentSourceStatus(true);', 'void checkCurrentSourceStatusAfterSwitch(true);'));

(async () => {
  await pollWebdavTask();
  const beforeBoundary = statusCalls.length;
  webdavState.lastStatusCheckAt = now - 60000;
  await pollWebdavTask();
  await switchSource('webdav-test');
  process.stdout.write(JSON.stringify({
    beforeBoundary,
    statusCalls,
    catalogCalls,
    sourceSwitchChecks,
    selected: currentSourceId
  }));
})().catch(error => { console.error(error); process.exit(1); });
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20
        $result.beforeBoundary | Should Be 0
        @($result.statusCalls).Count | Should Be 1
        $result.statusCalls[0] | Should Be $false
        @($result.catalogCalls).Count | Should Be 1
        $result.catalogCalls[0] | Should Be $false
        @($result.sourceSwitchChecks).Count | Should Be 1
        $result.sourceSwitchChecks[0] | Should Be $true
        $result.selected | Should Be 'webdav-test'
    }

    It 'refreshes V0.29 source status immediately after saving or deleting notes' {
        $saveMatch = [regex]::Match($html, 'async function saveActiveNote\(\)[\s\S]*?\n    \}(?=\n\n    async function)')
        $deleteMatch = [regex]::Match($html, 'async function deleteNoteForTarget\(target\)[\s\S]*?\n    \}(?=\n\n    function)')
        $saveMatch.Success | Should Be $true
        $deleteMatch.Success | Should Be $true
        $saveMatch.Value | Should Match 'await checkCurrentSourceStatus\(true\)'
        $deleteMatch.Value | Should Match 'await checkCurrentSourceStatus\(true\)'

        $serverSource = Get-Content -LiteralPath $serverScript -Raw
        $serverSource | Should Match 'get_webdav_service\(\)\.invalidate_source_status\(source_id\)'
    }

    It 'requires an explicit V0.29 cache decision when unregistering the current device' {
        $html | Should Match 'id="webdavUnregisterClearCache"'
        $html | Should Match 'clearCache:\s*!!\(webdavUnregisterClearCache\s*&&\s*webdavUnregisterClearCache\.checked\)'
        $html | Should Not Match "clearCache:\s*false"
        $closeMatch = [regex]::Match($html, 'function closeWebdavSettings\(\)[\s\S]*?\n    \}(?=\n\n    async function refreshCloudSources)')
        $closeMatch.Success | Should Be $true
        $closeMatch.Value | Should Match 'webdavUnregisterClearCache\.checked\s*=\s*false'
    }

    It 'keeps failed cache rows visible and never switches source after a failed single-source cleanup' {
        $handlerMatch = [regex]::Match($html, 'if \(webdavCacheList\) \{[\s\S]*?\n    \}(?=\n    Object\.keys\(collapseButtons\))')
        $handlerMatch.Success | Should Be $true
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/if \(webdavCacheList\) \{[\s\S]*?\n    \}(?=\n    Object\.keys\(collapseButtons\))/);
const formatter = html.match(/function formatWebdavCleanupFailures\(summary, failed\) \{[\s\S]*?\n    \}/);
if (!match || !formatter) throw new Error("cache cleanup functions not found");
const listeners = {};
const rows = [{ sourceId: "webdav-source", bytes: 42, label: "Remote" }];
const statuses = [];
const switches = [];
const webdavCacheList = { addEventListener(name, handler) { listeners[name] = handler; } };
const webdavState = { settings: { cache: rows } };
const button = { dataset: { clearCloudCache: "webdav-source" } };
const event = { target: { closest() { return button; } } };
function confirm() { return true; }
function webdavMutation() { return Promise.resolve({ ok: false, cleared: [], failed: [{ sourceId: "webdav-source", area: "cache", path: "C:/cache/<locked>", reason: "locked & denied" }], cache: rows }); }
function renderWebdavCache() {}
function refreshCloudSources() { return Promise.resolve(); }
function getCurrentSourceId() { return "webdav-source"; }
function switchSource(value) { switches.push(value); return Promise.resolve(); }
function setWebdavStatus(message, error) { statuses.push({ message, error }); }
eval(formatter[0]);
eval(match[0]);
(async () => {
  await listeners.click(event);
  await new Promise(resolve => setTimeout(resolve, 0));
  process.stdout.write(JSON.stringify({ switches, statuses, cache: webdavState.settings.cache }));
})().catch(error => { console.error(error); process.exit(1); });
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20
        @($result.switches).Count | Should Be 0
        @($result.cache).Count | Should Be 1
        $result.statuses[-1].error | Should Be $true
        $result.statuses[-1].message | Should Match '失败'
        $result.statuses[-1].message | Should Match 'C:/cache/<locked>'
        $result.statuses[-1].message | Should Match 'locked & denied'
    }

    It 'renders every cache cleanup failure detail through textContent HTML escaping' {
        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const formatter = html.match(/function formatWebdavCleanupFailures\(summary, failed\) \{[\s\S]*?\n    \}/);
const setter = html.match(/function setWebdavStatus\(message, error\) \{[\s\S]*?\n    \}/);
if (!formatter || !setter) throw new Error("cleanup formatter not found");
function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[character]));
}
const webdavStatus = {
  _text: "",
  innerHTML: "",
  classList: { toggle() {} },
  set textContent(value) { this._text = String(value); this.innerHTML = escapeHtml(value); },
  get textContent() { return this._text; }
};
eval(formatter[0]);
eval(setter[0]);
const failures = [
  { sourceId: "source-<one>", area: "cache", path: "C:/cache/<img src=x onerror=1>", reason: "locked & denied" },
  { sourceId: "source-two", area: "index", path: "C:/index/two", reason: "read-only" }
];
setWebdavStatus(formatWebdavCleanupFailures("清理失败", failures), true);
process.stdout.write(JSON.stringify({ text: webdavStatus.textContent, html: webdavStatus.innerHTML }));
'@
        $result = node -e $node $outputPath | ConvertFrom-Json -Depth 20
        $result.text | Should Match 'source-<one>'
        $result.text | Should Match '区域：cache'
        $result.text | Should Match '路径：C:/cache/<img src=x onerror=1>'
        $result.text | Should Match '原因：locked & denied'
        $result.text | Should Match 'source-two'
        $result.html | Should Match '&lt;img src=x onerror=1&gt;'
        $result.html | Should Not Match '<img src=x onerror=1>'
    }

    It 'shows warnings for saved settings, unregister, and partial all-cache cleanup results' {
        $formMatch = [regex]::Match($html, 'if \(webdavForm\) \{[\s\S]*?\n    \}(?=\n    if \(webdavCheckButton\))')
        $unregisterMatch = [regex]::Match($html, 'if \(webdavUnregisterButton\) \{[\s\S]*?\n    \}(?=\n    if \(webdavCancelTask\))')
        $clearAllMatch = [regex]::Match($html, 'if \(webdavClearAllButton\) \{[\s\S]*?\n    \}(?=\n    if \(webdavUnregisterButton\))')
        $formMatch.Success | Should Be $true
        $unregisterMatch.Success | Should Be $true
        $clearAllMatch.Success | Should Be $true
        $formMatch.Value | Should Match 'oldCacheCleanupOk'
        $unregisterMatch.Value | Should Match 'localCacheCleanupOk'
        $clearAllMatch.Value | Should Match 'payload\.failed'
        $clearAllMatch.Value | Should Match 'setWebdavStatus'
    }

    It 'returns JSON 500 from the cache DELETE API when cleanup raises OSError' {
        $python = @'
import http.client
import json
import threading
import sys
from http.server import ThreadingHTTPServer
from pathlib import Path
import importlib.util

spec = importlib.util.spec_from_file_location("server_under_test", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class BrokenService:
    def clear_cache(self, source_id):
        raise OSError("injected cache cleanup failure")

module.get_webdav_service = lambda: BrokenService()
server = ThreadingHTTPServer(("127.0.0.1", 0), module.Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    body = json.dumps({"sourceId": ""}).encode("utf-8")
    connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=2)
    connection.request("DELETE", "/api/webdav/cache", body=body, headers={
        "Content-Type": "application/json",
        "Content-Length": str(len(body)),
        "Origin": f"http://127.0.0.1:{server.server_port}",
        "Host": f"127.0.0.1:{server.server_port}",
        "X-Yuji-Session-Token": module.SESSION_TOKEN,
    })
    response = connection.getresponse()
    payload = json.loads(response.read().decode("utf-8"))
    print(json.dumps({"status": response.status, "payload": payload}))
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=2)
'@
        $result = python -c $python $serverScript | Select-Object -Last 1 | ConvertFrom-Json
        $result.status | Should Be 500
        $result.payload.ok | Should Be $false
        $result.payload.error | Should Match '清理|cache'
    }

    It 'shares one V0.29 build resource coordinator between local and WebDAV builds' {
        $serverSource = Get-Content -LiteralPath $serverScript -Raw
        $serverSource | Should Match '_build_resource_coordinator\s*=\s*BuildResourceCoordinator\(\)'
        $serverSource | Should Match 'resource_coordinator\s*=\s*_build_resource_coordinator'
        $serverSource | Should Match '_build_resource_coordinator\.begin_local_build\(\)'
        $serverSource | Should Match 'finally:\s*\r?\n\s*_build_resource_coordinator\.end_local_build\(\)'
    }

    It 'exposes V0.29 WebDAV APIs and enforces server-side mutation authorization' {
        $serverSource = Get-Content -LiteralPath $serverScript -Raw
        foreach ($route in @(
            '/api/session-token',
            '/api/source-status',
            '/api/webdav/settings',
            '/api/webdav/check',
            '/api/webdav/disable',
            '/api/webdav/unregister',
            '/api/webdav/upload',
            '/api/webdav/download',
            '/api/webdav/task',
            '/api/webdav/task/cancel',
            '/api/webdav/cache'
        )) {
            $serverSource | Should Match ([regex]::Escape($route))
        }
        $serverSource | Should Match 'def is_mutation_request_authorized\('
        $serverSource | Should Match 'X-Yuji-Session-Token'
        $serverSource | Should Match 'MAX_JSON_BODY_BYTES = 256 \* 1024'
        $serverSource | Should Match 'require_source_capability\(source_id, "canEditNotes", "云端备注只能在来源设备编辑"\)'
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

Describe 'V0.31 continued-session time and Codex event compatibility' {
    BeforeAll {
        $script:v031TempRoot = Join-Path $env:TEMP ('CodexChatIndex-V031-Test-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force $script:v031TempRoot | Out-Null

        function Build-V031FixtureDetail {
            param([string]$FixtureName, [string]$SessionId)
            $fixtureRoot = Join-Path $here ('fixtures\' + $FixtureName)
            $fixtureOutputRoot = Join-Path $script:v031TempRoot $FixtureName
            $fixtureOutput = Join-Path $fixtureOutputRoot 'CodexChatIndex.html'
            $summary = (& $buildScript -CodexHome $fixtureRoot -OutputPath $fixtureOutput -DataRoot $fixtureOutputRoot -MachineName 'V031-PC' -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json
            $sourceRoot = Get-TestSourceRoot $fixtureOutputRoot
            $index = Get-Content -LiteralPath (Join-Path $sourceRoot 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
            $session = @($index.workspaces | ForEach-Object { @($_.sessions) } | Where-Object id -eq $SessionId | Select-Object -First 1)
            if (-not $session) { throw "V0.31 fixture session '$SessionId' was not found." }
            $detailPath = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $fixtureOutput) ([string]$session.detailHref)))
            [pscustomobject]@{
                Html = Get-Content -LiteralPath $fixtureOutput -Raw
                Detail = Get-Content -LiteralPath $detailPath -Raw | ConvertFrom-Json -Depth 100
                Cache = Get-Content -LiteralPath (Join-Path $sourceRoot 'CodexChatIndex.cache.json') -Raw | ConvertFrom-Json -Depth 100
                Index = $index
                Session = $session
                Summary = $summary
            }
        }

        $script:v031Time = Build-V031FixtureDetail 'codex-v031-time' '00000000-0000-4000-8000-000000000031'
        $script:v031Events = Build-V031FixtureDetail 'codex-v031-events' '00000000-0000-4000-8000-000000000032'
    }

    It 'uses reliable task and item timestamps instead of a fixed rollout timestamp' {
        $historicalUser = @($v031Time.Detail.events | Where-Object { $_.kind -eq 'user' -and $_.rawText -eq 'Historical question' })
        $historicalFinal = @($v031Time.Detail.events | Where-Object { $_.kind -eq 'assistant_final' -and $_.rawText -eq 'Historical final answer' })
        $historicalProcess = @($v031Time.Detail.events | Where-Object { $_.kind -eq 'assistant_commentary' -and $_.rawText -match 'Historical process' })
        $taskStarted = @($v031Time.Detail.events | Where-Object { $_.kind -eq 'system' -and $_.summary -eq 'task_started' } | Select-Object -First 1)
        $taskComplete = @($v031Time.Detail.events | Where-Object { $_.kind -eq 'system' -and $_.summary -eq 'task_complete' } | Select-Object -First 1)

        $historicalUser.Count | Should Be 1
        $historicalUser[0].timestampLocal | Should Be ([DateTimeOffset]::Parse('2026-07-18T14:53:45Z').ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))
        $historicalFinal.Count | Should Be 1
        $historicalFinal[0].timestampLocal | Should Be ([DateTimeOffset]::Parse('2026-07-18T15:00:39Z').ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))
        $historicalProcess[0].timestampLocal | Should Be ''
        $taskStarted.timestampLocal | Should Be ([DateTimeOffset]::Parse('2026-07-18T14:53:45Z').ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))
        $taskComplete.timestampLocal | Should Be ([DateTimeOffset]::Parse('2026-07-18T15:00:39Z').ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))
        $fixedTopLocal = [DateTimeOffset]::Parse('2026-07-19T02:53:04Z').ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
        @($v031Time.Detail.events | Where-Object timestampLocal -eq $fixedTopLocal).Count | Should Be 0
    }

    It 'prefers item-level timestamps even when the fixed top timestamp is inside the task range' {
        $question = @($v031Time.Detail.events | Where-Object rawText -eq 'In-range fixed timestamp question' | Select-Object -First 1)
        $answer = @($v031Time.Detail.events | Where-Object rawText -eq 'In-range fixed timestamp answer' | Select-Object -First 1)
        $question.timestampLocal | Should Be ([DateTimeOffset]::Parse('2026-07-18T10:05:00Z').ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))
        $answer.timestampLocal | Should Be ([DateTimeOffset]::Parse('2026-07-18T10:30:00Z').ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))
    }

    It 'restores visible completed AgentMessage records without response-only summaries' {
        $finalTexts = @($v031Events.Detail.events | Where-Object kind -eq 'assistant_final' | ForEach-Object rawText)
        $commentaryTexts = @($v031Events.Detail.events | Where-Object kind -eq 'assistant_commentary' | ForEach-Object rawText)
        ($finalTexts -contains 'Legacy answer') | Should Be $true
        ($finalTexts -contains 'New final answer') | Should Be $true
        ($commentaryTexts -contains 'Visible commentary') | Should Be $true
        ($finalTexts -join "`n") | Should Not Match 'Current Task|Handoff Summary|Current Progress'
        ($commentaryTexts -join "`n") | Should Not Match 'hidden reasoning'
    }

    It 'deduplicates confirmed wrappers but preserves distinct authoritative messages' {
        @($v031Events.Detail.events | Where-Object rawText -eq 'Mixed duplicate answer').Count | Should Be 1
        @($v031Events.Detail.events | Where-Object rawText -eq 'Repeated authoritative answer').Count | Should Be 2
        $newQuestion = @($v031Events.Detail.events | Where-Object rawText -eq 'New question')
        $newQuestion.Count | Should Be 1
        ($newQuestion[0].PSObject.Properties.Name -contains 'images') | Should Be $true
        @($newQuestion[0].images).Count | Should Be 1
        $newQuestion[0].turnId | Should Be '01a024c4-5228-7000-8000-000000000031'
        @($v031Events.Detail.events | Where-Object rawText -eq 'Cluster-separated duplicate answer').Count | Should Be 2
        @($v031Events.Detail.events | Where-Object rawText -eq 'Repeated real question').Count | Should Be 2
    }

    It 'requires phase-kind agreement only for assistant wrapper fallback matching' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($buildScript, [ref]$tokens, [ref]$errors)
        $functionAst = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Test-CodexAssistantWrapperCluster'
        }, $true) | Select-Object -First 1)[0]
        $functionSource = $functionAst.Extent.Text

        $functionSource | Should Match '\[string\]\$EventKind'
        . ([scriptblock]::Create($functionSource))

        $turnId = '01a024c4-5228-7000-8000-000000000031'
        $fallbackWrappers = @{
            2 = [pscustomobject]@{
                TurnId = $turnId
                StableItemId = 'different-wrapper-id'
                Phase = 'commentary'
                RawText = 'same assistant text'
            }
        }
        $directWrappers = @{
            2 = [pscustomobject]@{
                TurnId = $turnId
                StableItemId = 'shared-stable-id'
                Phase = 'commentary'
                RawText = 'same assistant text'
            }
        }

        (Test-CodexAssistantWrapperCluster -WrappersByOrdinal $fallbackWrappers `
            -LowOrdinal 1 -HighOrdinal 3 -TurnId $turnId -RawText 'same assistant text' `
            -EventKind 'assistant_final' -StableItemIds @('completed-final-id')) | Should Be $false
        (Test-CodexAssistantWrapperCluster -WrappersByOrdinal $fallbackWrappers `
            -LowOrdinal 1 -HighOrdinal 3 -TurnId $turnId -RawText 'same assistant text' `
            -EventKind 'assistant_commentary' -StableItemIds @('completed-commentary-id')) | Should Be $true
        (Test-CodexAssistantWrapperCluster -WrappersByOrdinal $directWrappers `
            -LowOrdinal 1 -HighOrdinal 3 -TurnId $turnId -RawText 'same assistant text' `
            -EventKind 'assistant_final' -StableItemIds @('shared-stable-id')) | Should Be $true
    }

    It 'does not use invalid task ranges to backfill user or final timestamps' {
        $invalidQuestion = @($v031Time.Detail.events | Where-Object rawText -eq 'Invalid-range question' | Select-Object -First 1)
        $invalidAnswer = @($v031Time.Detail.events | Where-Object rawText -eq 'Invalid-range answer' | Select-Object -First 1)
        $invalidQuestion.timestampLocal | Should Be ''
        $invalidAnswer.timestampLocal | Should Be ''
    }

    It 'maps authoritative and fallback V0.31 tool records without duplicate wrappers' {
        $tools = @($v031Events.Detail.events | Where-Object kind -eq 'tool')
        @($tools | Where-Object toolName -eq 'exec_command').Count | Should Be 1
        @($tools | Where-Object toolName -eq 'view_image').Count | Should Be 2
        @($tools | Where-Object toolName -eq 'fixture.lookup').Count | Should Be 1
        @($tools | Where-Object toolName -eq 'fallback_tool').Count | Should Be 1
        @($tools | Where-Object toolName -eq 'outer_tool').Count | Should Be 0
        @($tools | Where-Object toolName -eq 'nested_outer').Count | Should Be 1
        @($tools | Where-Object toolName -eq 'nested_inner').Count | Should Be 0
        ($tools | Where-Object toolName -eq 'exec_command').rawText | Should Match 'fixture aggregate'
        ($tools | Where-Object toolName -eq 'exec_command').rawText | Should Match 'fixture stderr'
        ($tools | Where-Object toolName -eq 'exec_command').summary | Should Match 'fixture formatted'
        ($tools | Where-Object toolName -eq 'exec_command').summary | Should Not Match 'fixture aggregate'
        ($tools | Where-Object toolName -eq 'fixture.lookup').rawText | Should Match 'dynamic input'
        ($tools | Where-Object toolName -eq 'fixture.lookup').rawText | Should Match 'safe unknown'
        ($tools | Where-Object toolName -eq 'fallback_tool').rawText | Should Match 'fallback first[\s\S]*fallback second'
        ($tools | Where-Object toolName -eq 'nested_outer').rawText | Should Match 'outer nested output'
    }

    It 'does not persist parser-only diagnostics in V0.31 details' {
        ($v031Events.Detail | ConvertTo-Json -Depth 100 -Compress) | Should Not Match 'rawLineOrdinal|wrapperSource|topTimestampCandidate|eventStartedUtc|eventCompletedUtc|stableItemId'
    }

    It 'reports unassigned and unrecognized V0.31 records without persisting parser diagnostics' {
        $v031Events.Summary.unassignedRecordCount | Should Be 1
        $v031Events.Summary.unrecognizedRecordCount | Should Be 2
    }

    It 'falls back to the source file time when UpdatedAt is not parseable' {
        $fixturePath = Join-Path $here 'fixtures\codex-v031-time\sessions\2026\07\18\rollout-2026-07-18T14-53-45-00000000-0000-4000-8000-000000000031.jsonl'
        ([DateTimeOffset]$v031Time.Session.updatedAt).ToUniversalTime().Ticks | Should Be ([DateTimeOffset](Get-Item -LiteralPath $fixturePath).LastWriteTimeUtc).Ticks
    }

    It 'rejects impossible assistant wrapper pairs before scanning wrapper records' {
        $buildSource = Get-Content -LiteralPath $buildScript -Raw
        $buildSource | Should Match 'if \(-not \$sameStableId -and \(-not \$sameText -or -not \$legacyCompletedPair -or \(\$high - \$low\) -gt 3\)\) \{ continue \}[\s\S]*?\$wrapperMatch = @\(\$assistantWrappers'
        $buildSource | Should Match '\$seenStableToolKeys = \[System\.Collections\.Generic\.HashSet\[string\]\]::new'
        $buildSource | Should Not Match '\$duplicateTool = @\(\$deduped \| Where-Object'
        $buildSource | Should Match 'function Complete-ParsedSessionForBuild\s*\{'
        $buildSource | Should Match '\$runtimeSession\.Events = \$null[\s\S]*?\$runtimeSession\.Cached = \$true'
        $buildSource | Should Match '-DeferDetailWrite \$isRemoteSource'
    }

    It 'adds local-only search history controls and bounded interaction rules' {
        $html = $v031Events.Html
        $html | Should Match 'id="viewerSearchHistoryButton"'
        $html | Should Match 'id="viewerSearchHistoryMenu"'
        $html | Should Match 'yuji-search-history-v1'
        $html | Should Match 'const SEARCH_HISTORY_LIMIT = 20'
        $html | Should Match 'max-height:\s*50vh'
        $html | Should Match 'overflow-wrap:\s*anywhere'
        $html | Should Match 'function normalizeSearchHistoryQuery\('
        $html | Should Match 'function confirmSearchHistoryQuery\('
        $html | Should Match '再次点击确认清空'
        $html | Should Match '5000'
        $html | Should Match 'viewerSearchInput\.addEventListener\(''keydown'''
        $html | Should Match 'confirmSearchHistoryQuery\(\);[\s\S]*?data-search-scope'
        $html | Should Match 'valueButton\.textContent = item'
        $html | Should Not Match 'valueButton\.innerHTML'
        $html | Should Match 'function useSearchHistoryItem\(value\)[\s\S]*?viewerSearchInput\.focus\(\{ preventScroll: true \}\);[\s\S]*?closeSearchHistoryMenu\(\);[\s\S]*?scheduleViewerSearch\(\{ immediate: true \}\)'
    }

    It 'cleans, deduplicates, bounds, and safely degrades local search history storage' {
        $htmlPath = Join-Path $script:v031TempRoot 'codex-v031-events\CodexChatIndex.html'
        $node = @'
const fs = require('fs');
const html = fs.readFileSync(process.argv[1], 'utf8');
const match = html.match(/function normalizeSearchHistoryQuery\(value\) \{[\s\S]*?(?=\n    function getGlobalSearchQuery\(\))/);
if (!match) throw new Error('search history helpers not found');

let rawValue = JSON.stringify({
  version: 1,
  items: ['  Alpha   Beta  ', 'alpha beta', '中文\t测试', null].concat(Array.from({ length: 25 }, (_, index) => 'item-' + index))
});
let writes = 0;
let toasts = [];
let mode = 'normal';
const storage = {
  getItem(key) { return rawValue; },
  setItem(key, value) {
    writes += 1;
    const itemCount = JSON.parse(value).items.length;
    if (mode === 'quota' && itemCount > 2) {
      const error = new Error('quota');
      error.name = 'QuotaExceededError';
      throw error;
    }
    if (mode === 'security') {
      const error = new Error('blocked');
      error.name = 'SecurityError';
      throw error;
    }
    rawValue = value;
  },
  removeItem(key) {
    if (mode === 'remove-security') {
      const error = new Error('blocked remove');
      error.name = 'SecurityError';
      throw error;
    }
    rawValue = null;
  }
};
const windowMock = { localStorage: storage };
const factory = new Function('window', [
  "const SEARCH_HISTORY_STORAGE_KEY = 'yuji-search-history-v1';",
  'const SEARCH_HISTORY_LIMIT = 20;',
  'const SEARCH_HISTORY_CLEAR_CONFIRM_MS = 5000;',
  'let searchHistoryItems = [];',
  'let searchHistoryHighlightIndex = -1;',
  'let searchHistoryClearTimer = 0;',
  'let searchHistoryStorageWritable = true;',
  "const viewerSearchHistoryButton = { disabled: false, setAttribute() {} };",
  "const viewerSearchHistoryMenu = { hidden: true };",
  "const viewerSearchInput = { value: '', setAttribute() {}, removeAttribute() {} };",
  "const viewerSearchHistoryClear = { textContent: '' };",
  'const viewerSearchHistoryList = null;',
  'function showToast(message) { toasts.push(message); }',
  match[0],
  'return {',
  '  loadSearchHistory, confirmSearchHistoryQuery, normalizeSearchHistoryQuery, sanitizeSearchHistoryItems, clearSearchHistory,',
  '  getItems: () => searchHistoryItems.slice(),',
  '  isWritable: () => searchHistoryStorageWritable,',
  '  setWritable: value => { searchHistoryStorageWritable = value; },',
  '  setItems: value => { searchHistoryItems = value.slice(); },',
  '  getToasts: () => toasts.slice()',
  '};'
].join('\n'));
const harness = factory(windowMock);

harness.loadSearchHistory();
const loaded = harness.getItems();
const loadResult = {
  first: loaded[0],
  second: loaded[1],
  count: loaded.length,
  rewrote: writes > 0
};

harness.confirmSearchHistoryQuery('ALPHA\n beta');
const deduped = harness.getItems();
const dedupResult = {
  first: deduped[0],
  duplicateCount: deduped.filter(item => item.toLowerCase() === 'alpha beta').length,
  count: deduped.length
};

mode = 'quota';
harness.setWritable(true);
harness.setItems(['old-1', 'old-2', 'old-3', 'old-4']);
harness.confirmSearchHistoryQuery('new-search');
const quotaItems = harness.getItems();

mode = 'security';
harness.setWritable(true);
harness.setItems(['kept-in-memory']);
harness.confirmSearchHistoryQuery('private-search');
const securityResult = {
  items: harness.getItems(),
  writable: harness.isWritable()
};

mode = 'normal';
rawValue = '{broken-json';
harness.setWritable(true);
harness.loadSearchHistory();
const malformedResult = {
  count: harness.getItems().length,
  writable: harness.isWritable(),
  removed: rawValue === null
};

mode = 'remove-security';
rawValue = JSON.stringify({ version: 1, items: ['keep-a', 'keep-b'] });
harness.setWritable(true);
harness.setItems(['keep-a', 'keep-b']);
harness.clearSearchHistory();
const clearResultValue = harness.clearSearchHistory();
const clearFailureResult = {
  returnedFalse: clearResultValue === false,
  items: harness.getItems(),
  failureToast: harness.getToasts().some(item => item.includes('无法保存')),
  successToast: harness.getToasts().some(item => item.includes('已清空'))
};

console.log(JSON.stringify({ loadResult, dedupResult, quotaItems, securityResult, malformedResult, clearFailureResult }));
'@
        $result = node -e $node $htmlPath | ConvertFrom-Json -Depth 20

        $result.loadResult.first | Should Be 'Alpha Beta'
        $result.loadResult.second | Should Be '中文 测试'
        $result.loadResult.count | Should Be 20
        $result.loadResult.rewrote | Should Be $true
        $result.dedupResult.first | Should Be 'ALPHA beta'
        $result.dedupResult.duplicateCount | Should Be 1
        $result.dedupResult.count | Should Be 20
        @($result.quotaItems).Count | Should Be 2
        $result.quotaItems[0] | Should Be 'new-search'
        $result.securityResult.items[0] | Should Be 'private-search'
        $result.securityResult.writable | Should Be $false
        $result.malformedResult.count | Should Be 0
        $result.malformedResult.writable | Should Be $true
        $result.malformedResult.removed | Should Be $true
        $result.clearFailureResult.returnedFalse | Should Be $true
        @($result.clearFailureResult.items).Count | Should Be 2
        $result.clearFailureResult.failureToast | Should Be $true
        $result.clearFailureResult.successToast | Should Be $false
    }

    It 'rebuilds a V0.30 cache once before returning to no-change V0.34 refreshes' {
        $cacheRoot = Join-Path $script:v031TempRoot 'v030-cache-upgrade'
        $outputPath = Join-Path $cacheRoot 'CodexChatIndex.html'
        $fixtureRoot = Join-Path $here 'fixtures\codex-v031-events'
        & $buildScript -CodexHome $fixtureRoot -OutputPath $outputPath -DataRoot $cacheRoot -RefreshMode Full -JsonSummary | Out-Null
        $sourceRoot = Get-TestSourceRoot $cacheRoot
        $cachePath = Join-Path $sourceRoot 'CodexChatIndex.cache.json'
        $cache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -Depth 100
        $cache.builderVersion = 'V0.30'
        Set-Content -LiteralPath $cachePath -Value ($cache | ConvertTo-Json -Depth 100) -Encoding UTF8

        $first = (& $buildScript -CodexHome $fixtureRoot -OutputPath $outputPath -DataRoot $cacheRoot -RefreshMode Incremental -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json
        $upgradedCache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -Depth 100
        $second = (& $buildScript -CodexHome $fixtureRoot -OutputPath $outputPath -DataRoot $cacheRoot -RefreshMode Incremental -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json

        $first.mode | Should Be 'Full'
        $first.parsedCount | Should BeGreaterThan 0
        $first.notice | Should Match '缓存版本不兼容'
        $upgradedCache.cacheVersion | Should Be 5
        $upgradedCache.builderVersion | Should Be 'V0.34'
        $second.mode | Should Be 'Incremental'
        $second.noChange | Should Be $true
        $second.parsedCount | Should Be 0
    }

    It 'rebuilds a V0.31 cache once during the V0.32 migration' {
        $cacheRoot = Join-Path $script:v031TempRoot 'v031-parser-revision-upgrade'
        $outputPath = Join-Path $cacheRoot 'CodexChatIndex.html'
        $fixtureRoot = Join-Path $here 'fixtures\codex-v031-events'
        & $buildScript -CodexHome $fixtureRoot -OutputPath $outputPath -DataRoot $cacheRoot -RefreshMode Full -JsonSummary | Out-Null
        $sourceRoot = Get-TestSourceRoot $cacheRoot
        $cachePath = Join-Path $sourceRoot 'CodexChatIndex.cache.json'
        $cache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -Depth 100
        $cache.builderVersion = 'V0.31'
        $cache.PSObject.Properties.Remove('parserRevision')
        Set-Content -LiteralPath $cachePath -Value ($cache | ConvertTo-Json -Depth 100) -Encoding UTF8

        $first = (& $buildScript -CodexHome $fixtureRoot -OutputPath $outputPath -DataRoot $cacheRoot -RefreshMode Incremental -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json
        $upgradedCache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -Depth 100
        $second = (& $buildScript -CodexHome $fixtureRoot -OutputPath $outputPath -DataRoot $cacheRoot -RefreshMode Incremental -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json

        $first.mode | Should Be 'Full'
        $first.parsedCount | Should BeGreaterThan 0
        $first.notice | Should Match '缓存版本不兼容'
        $upgradedCache.cacheVersion | Should Be 5
        $upgradedCache.builderVersion | Should Be 'V0.34'
        $upgradedCache.parserRevision | Should Be 5
        $second.mode | Should Be 'Incremental'
        $second.noChange | Should Be $true
    }

    It 'rebuilds a parser revision 4 cache once for escaped image punctuation recovery' {
        $cacheRoot = Join-Path $script:v031TempRoot 'v034-parser-revision-5-upgrade'
        $outputPath = Join-Path $cacheRoot 'CodexChatIndex.html'
        $fixtureRoot = Join-Path $here 'fixtures\codex-v031-events'
        & $buildScript -CodexHome $fixtureRoot -OutputPath $outputPath -DataRoot $cacheRoot -RefreshMode Full -JsonSummary | Out-Null
        $sourceRoot = Get-TestSourceRoot $cacheRoot
        $cachePath = Join-Path $sourceRoot 'CodexChatIndex.cache.json'
        $cache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -Depth 100
        $cache.builderVersion = 'V0.34'
        $cache.parserRevision = 4
        Set-Content -LiteralPath $cachePath -Value ($cache | ConvertTo-Json -Depth 100) -Encoding UTF8

        $first = (& $buildScript -CodexHome $fixtureRoot -OutputPath $outputPath -DataRoot $cacheRoot -RefreshMode Incremental -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json
        $upgradedCache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -Depth 100
        $second = (& $buildScript -CodexHome $fixtureRoot -OutputPath $outputPath -DataRoot $cacheRoot -RefreshMode Incremental -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json

        $first.mode | Should Be 'Full'
        $first.notice | Should Match '缓存版本不兼容'
        $upgradedCache.builderVersion | Should Be 'V0.34'
        $upgradedCache.parserRevision | Should Be 5
        $second.mode | Should Be 'Incremental'
        $second.noChange | Should Be $true
    }

    It 'uses V0.34 markers with bounded-search cache version 5' {
        $buildSource = Get-Content -LiteralPath $buildScript -Raw
        $openSource = Get-Content -LiteralPath (Join-Path $projectRoot 'Open-CodexChatIndex.cmd') -Raw
        (Get-Content -LiteralPath (Join-Path $projectRoot 'VERSION_V0.34.txt') -Raw).Trim() | Should Be 'V0.34'
        $buildSource | Should Match '\$builderVersion = "V0\.34"'
        $openSource | Should Match 'V0\.34'
        $v031Events.Html | Should Match '<span class="version-badge">V0\.34</span>'
        $v031Events.Cache.cacheVersion | Should Be 5
        $v031Events.Cache.builderVersion | Should Be 'V0.34'
        $v031Events.Cache.parserRevision | Should Be 5
    }

    AfterAll {
        Remove-Item -LiteralPath $script:v031TempRoot -Force -Recurse -ErrorAction SilentlyContinue
    }
}

Describe 'V0.31 bounded full-library tool output search' {
    BeforeAll {
        $script:boundedSearchTempRoot = Join-Path $env:TEMP ('CodexChatIndex-BoundedSearch-' + [guid]::NewGuid().ToString('N'))
        $script:boundedSearchHome = Join-Path $script:boundedSearchTempRoot 'codex-home'
        $script:boundedSearchRuntime = Join-Path $script:boundedSearchTempRoot 'runtime'
        $sessionRoot = Join-Path $script:boundedSearchHome 'sessions\2026\08\24'
        New-Item -ItemType Directory -Force $sessionRoot | Out-Null

        $sessionId = '00000000-0000-4000-8000-000000000099'
        $turnId = '01a024c4-9000-7000-8000-000000000099'
        $toolOutput = 'HEAD_GLOBAL_TOOL_MARKER' + ('H' * 24000) +
            'MIDDLE_PRIVATE_TOOL_MARKER' + ('M' * 24000) + 'TAIL_GLOBAL_TOOL_MARKER'
        $sessionPath = Join-Path $sessionRoot ('rollout-2026-08-24T09-00-00-' + $sessionId + '.jsonl')
        @(
            ([ordered]@{ timestamp = '2026-08-24T09:00:00Z'; type = 'session_meta'; payload = [ordered]@{
                id = $sessionId; timestamp = '2026-08-24T09:00:00Z'; cwd = 'C:\fixture\bounded-search'
                source = 'cli'; model_provider = 'openai'; cli_version = 'v031-bounded-search'
            } } | ConvertTo-Json -Depth 30 -Compress),
            ([ordered]@{ timestamp = '2026-08-24T09:00:01Z'; type = 'event_msg'; payload = [ordered]@{
                type = 'task_started'; turn_id = $turnId; started_at = 1787562001
            } } | ConvertTo-Json -Depth 30 -Compress),
            ([ordered]@{ timestamp = '2026-08-24T09:00:02Z'; type = 'event_msg'; payload = [ordered]@{
                type = 'user_message'; turn_id = $turnId; message = 'Find bounded tool output'
            } } | ConvertTo-Json -Depth 30 -Compress),
            ([ordered]@{ timestamp = '2026-08-24T09:00:03Z'; type = 'event_msg'; payload = [ordered]@{
                type = 'item_completed'; turn_id = $turnId; started_at_ms = 1787562003000; completed_at_ms = 1787562003500
                item = [ordered]@{
                    type = 'CommandExecution'; id = 'exec-bounded-search'; command = @('pwsh', '-Command', 'Write-Output bounded')
                    status = 'completed'; stdout = $toolOutput; stderr = ''; aggregated_output = $toolOutput
                    formatted_output = 'bounded command complete'; exit_code = 0; duration = 500
                }
            } } | ConvertTo-Json -Depth 30 -Compress),
            ([ordered]@{ timestamp = '2026-08-24T09:00:04Z'; type = 'event_msg'; payload = [ordered]@{
                type = 'task_complete'; turn_id = $turnId; completed_at = 1787562004
            } } | ConvertTo-Json -Depth 30 -Compress)
        ) | Set-Content -LiteralPath $sessionPath -Encoding UTF8

        $script:boundedSearchOutput = Join-Path $script:boundedSearchRuntime 'CodexChatIndex.html'
        $script:boundedSearchFirstSummary = (& $buildScript -CodexHome $script:boundedSearchHome `
            -OutputPath $script:boundedSearchOutput -DataRoot $script:boundedSearchRuntime `
            -RefreshMode Full -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json
        $sourceRoot = Get-TestSourceRoot $script:boundedSearchRuntime
        $script:boundedSearchQuestions = Get-Content -LiteralPath (Join-Path $sourceRoot 'CodexChatIndex.search.json') -Raw | ConvertFrom-Json -Depth 100
        $script:boundedSearchOther = Get-Content -LiteralPath (Join-Path $sourceRoot 'CodexChatIndex.search.other.json') -Raw | ConvertFrom-Json -Depth 100
        $script:boundedSearchCache = Get-Content -LiteralPath (Join-Path $sourceRoot 'CodexChatIndex.cache.json') -Raw | ConvertFrom-Json -Depth 100
        $index = Get-Content -LiteralPath (Join-Path $sourceRoot 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $session = @($index.workspaces | ForEach-Object { @($_.sessions) } | Select-Object -First 1)[0]
        $detailPath = [System.IO.Path]::GetFullPath((Join-Path $script:boundedSearchRuntime ([string]$session.detailHref)))
        $script:boundedSearchDetail = Get-Content -LiteralPath $detailPath -Raw | ConvertFrom-Json -Depth 100
    }

    It 'keeps complete tool details but indexes only deterministic head and tail excerpts globally' {
        $toolDetail = @($boundedSearchDetail.events | Where-Object kind -eq 'tool' | Select-Object -First 1)[0]
        $otherText = [string]$boundedSearchOther.sessions[0].otherText

        $toolDetail.rawText | Should Match 'HEAD_GLOBAL_TOOL_MARKER'
        $toolDetail.rawText | Should Match 'MIDDLE_PRIVATE_TOOL_MARKER'
        $toolDetail.rawText | Should Match 'TAIL_GLOBAL_TOOL_MARKER'
        $otherText | Should Match 'HEAD_GLOBAL_TOOL_MARKER'
        $otherText | Should Not Match 'MIDDLE_PRIVATE_TOOL_MARKER'
        $otherText | Should Match 'TAIL_GLOBAL_TOOL_MARKER'
        $otherText | Should Match 'bounded command complete'
        $boundedSearchFirstSummary.toolRawSearchOriginalChars | Should BeGreaterThan $boundedSearchFirstSummary.toolRawSearchIndexedChars
    }

    It 'uses upgraded bounded-search index and cache formats then resumes incremental reuse' {
        $boundedSearchQuestions.version | Should Be 4
        $boundedSearchOther.version | Should Be 4
        $boundedSearchCache.cacheVersion | Should Be 5
        ($boundedSearchCache.files[0].PSObject.Properties.Name -contains 'otherBaseText') | Should Be $true
        ($boundedSearchCache.files[0].PSObject.Properties.Name -contains 'toolRawText') | Should Be $true
        ($boundedSearchCache.files[0].PSObject.Properties.Name -contains 'otherText') | Should Be $false

        $secondSummary = (& $buildScript -CodexHome $boundedSearchHome -OutputPath $boundedSearchOutput `
            -DataRoot $boundedSearchRuntime -RefreshMode Incremental -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json
        $secondSummary.mode | Should Be 'Incremental'
        $secondSummary.noChange | Should Be $true
        $secondSummary.parsedCount | Should Be 0
        $secondSummary.reusedCount | Should Be 1
    }

    It 'enforces per-session and global tool-output budgets independently' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($buildScript, [ref]$tokens, [ref]$errors)
        foreach ($functionName in @('Get-BoundedSearchExcerpt', 'Get-SessionSearchParts', 'Set-SessionSearchFields', 'Set-GlobalSearchTextLimits')) {
            $functionAst = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
            }, $true) | Select-Object -First 1)[0]
            . ([scriptblock]::Create($functionAst.Extent.Text))
        }

        $events = @(
            1..8 | ForEach-Object {
                [pscustomobject]@{
                    kind = 'tool'; toolName = ('tool-' + $_); status = 'completed'; summary = ('summary-' + $_)
                    rawText = ('HEAD-' + $_ + '-' + ('X' * 80) + '-TAIL-' + $_)
                }
            }
        )
        $sessionA = [pscustomobject]@{ Id = 'a'; Title = 'A'; Events = $events }
        $sessionB = [pscustomobject]@{ Id = 'b'; Title = 'B'; Events = $events }
        [void](Set-SessionSearchFields -Session $sessionA -ToolRawEventCharLimit 30 -ToolRawSessionCharLimit 80)
        [void](Set-SessionSearchFields -Session $sessionB -ToolRawEventCharLimit 30 -ToolRawSessionCharLimit 80)

        $sessionA.ToolRawSearchText.Length | Should Not BeGreaterThan 80
        $sessionA.OtherSearchBaseText | Should Match 'tool-8'
        $sessionA.OtherSearchBaseText | Should Match 'summary-8'
        $result = Set-GlobalSearchTextLimits -Sessions @($sessionA, $sessionB) -ToolRawGlobalCharLimit 60 -SearchTextGlobalCharLimit 1000
        $result.ToolRawIndexedChars | Should Not BeGreaterThan 60
        ([int64]$sessionA.ToolRawSearchText.Length + [int64]$sessionB.ToolRawSearchText.Length) | Should Not BeGreaterThan 60
        $sessionA.OtherSearchText | Should Match 'tool-8'
        $sessionB.OtherSearchText | Should Match 'summary-8'
    }

    AfterAll {
        Remove-Item -LiteralPath $script:boundedSearchTempRoot -Force -Recurse -ErrorAction SilentlyContinue
    }
}

Describe 'V0.32 managed images with V0.34 title and note interactions' {
    BeforeAll {
        $script:v032TempRoot = Join-Path $env:TEMP ('CodexChatIndex-V032-' + [guid]::NewGuid().ToString('N'))
        $script:v032Home = Join-Path $script:v032TempRoot 'codex-home'
        $script:v032Runtime = Join-Path $script:v032TempRoot 'runtime'
        $script:v032Cwd = Join-Path $script:v032TempRoot 'workspace'
        $sessionDir = Join-Path $script:v032Home 'sessions\2026\09\27'
        New-Item -ItemType Directory -Force $sessionDir, $script:v032Cwd | Out-Null
        $script:v032LocalPngBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZswAAAABJRU5ErkJggg=='
        $script:v032DataGifBase64 = 'R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=='
        $script:v032LocalImage = Join-Path $script:v032Cwd 'snapshot.png'
        [IO.File]::WriteAllBytes($script:v032LocalImage, [Convert]::FromBase64String($script:v032LocalPngBase64))
        $script:v032EscapedLegacyImage = Join-Path $script:v032Cwd '微信图片_20260908185726_8363_7.png'
        [IO.File]::WriteAllBytes($script:v032EscapedLegacyImage, [Convert]::FromBase64String($script:v032LocalPngBase64))
        $script:v032ExpectedLocalAsset = (Get-FileHash -LiteralPath $script:v032LocalImage -Algorithm SHA256).Hash.ToLowerInvariant()
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $script:v032ExpectedDataAsset = [BitConverter]::ToString($sha.ComputeHash([Convert]::FromBase64String($script:v032DataGifBase64))).Replace('-', '').ToLowerInvariant()
        } finally { $sha.Dispose() }

        $sessionId = '32323232-3232-4232-8232-323232323232'
        $sessionPath = Join-Path $sessionDir ('rollout-2026-09-27T10-00-00-' + $sessionId + '.jsonl')
        @(
            ([ordered]@{ timestamp = '2026-09-27T10:00:00Z'; type = 'session_meta'; payload = [ordered]@{
                id = $sessionId; timestamp = '2026-09-27T10:00:00Z'; cwd = $script:v032Cwd
                source = 'cli'; model_provider = 'openai'; cli_version = 'v032-image-test'
            } } | ConvertTo-Json -Depth 30 -Compress),
            ([ordered]@{ timestamp = '2026-09-27T10:00:01Z'; type = 'response_item'; payload = [ordered]@{
                type = 'message'; role = 'user'; content = @(
                    [ordered]@{ type = 'input_text'; text = '托管图片：![local](snapshot.png) ![loopback](http://127.0.0.1:1/missing.png) 历史图片：微信图片\_20260908185726\_8363\_7.png' },
                    [ordered]@{ type = 'input_image'; image_url = ('data:image/gif;base64,' + $script:v032DataGifBase64) }
                )
            } } | ConvertTo-Json -Depth 30 -Compress),
            ([ordered]@{ timestamp = '2026-09-27T10:00:02Z'; type = 'event_msg'; payload = [ordered]@{
                type = 'agent_message'; phase = 'final_answer'; message = 'done'
            } } | ConvertTo-Json -Depth 30 -Compress)
        ) | Set-Content -LiteralPath $sessionPath -Encoding UTF8

        $script:v032Output = Join-Path $script:v032Runtime 'CodexChatIndex.html'
        $script:v032FirstSummary = (& $buildScript -CodexHome $script:v032Home -OutputPath $script:v032Output -DataRoot $script:v032Runtime -RefreshMode Full -JsonSummary | Select-Object -Last 1) | ConvertFrom-Json
        $sourceRoot = Get-TestSourceRoot $script:v032Runtime
        $index = Get-Content -LiteralPath (Join-Path $sourceRoot 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $session = @($index.workspaces | ForEach-Object { @($_.sessions) } | Select-Object -First 1)[0]
        $script:v032DetailPath = [IO.Path]::GetFullPath((Join-Path $script:v032Runtime ([string]$session.detailHref)))
        $script:v032FirstDetail = Get-Content -LiteralPath $script:v032DetailPath -Raw | ConvertFrom-Json -Depth 100
    }

    It 'manages local and Base64 images by content hash while a failed localhost URL stays nonfatal' {
        $v032FirstSummary.failedCount | Should Be 0
        $user = @($v032FirstDetail.events | Where-Object kind -eq 'user' | Select-Object -First 1)[0]
        $managed = @($user.images | Where-Object type -eq 'managed')
        $failedUrl = @($user.images | Where-Object { $_.type -eq 'url' -and $_.status -eq 'unavailable' })
        @($managed).Count | Should Be 3
        (@($managed.assetId) -contains $v032ExpectedLocalAsset) | Should Be $true
        @($managed | Where-Object { $_.assetId -eq $v032ExpectedLocalAsset }).Count | Should Be 2
        (@($managed.assetId) -contains $v032ExpectedDataAsset) | Should Be $true
        @($failedUrl).Count | Should Be 1
        foreach ($image in $managed) {
            $image.assetId | Should Match '^[0-9a-f]{64}$'
            $objectPath = Join-Path $v032Runtime ('CodexChatIndex.images\objects\' + $image.assetId.Substring(0, 2) + '\' + $image.assetId + '.bin')
            (Get-FileHash -LiteralPath $objectPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should Be $image.assetId
        }
        $state = Get-Content -LiteralPath (Join-Path $v032Runtime 'CodexChatIndex.images\state.json') -Raw | ConvertFrom-Json -Depth 100
        $state.imageMigrationVersion | Should Be 1
        $state.migrations.'local-codex' | Should Be 1
    }

    It 'restores Markdown-escaped underscores in legacy relative image filenames' {
        $user = @($v032FirstDetail.events | Where-Object kind -eq 'user' | Select-Object -First 1)[0]
        $user.rawText | Should Match '微信图片\\_20260908185726\\_8363\\_7\.png'
        (Get-Content -LiteralPath $buildScript -Raw) | Should Match '、，。:：'
        $managed = @($user.images | Where-Object type -eq 'managed')
        @($managed | Where-Object { $_.assetId -eq $v032ExpectedLocalAsset }).Count | Should Be 2
    }

    It 'restores managed local images for a downloaded WebDAV source without reading the original local path' {
        $remoteSourceId = 'webdav-11111111-1111-4111-8111-111111111111-22222222-2222-4222-8222-222222222222-local-codex'
        $remoteRoot = Join-Path $script:v032TempRoot 'remote-raw'
        $remoteSessionDir = Join-Path $remoteRoot 'sessions\2026\09\27'
        New-Item -ItemType Directory -Force $remoteSessionDir | Out-Null
        $sourceSession = Get-ChildItem -LiteralPath (Join-Path $script:v032Home 'sessions\2026\09\27') -Filter '*.jsonl' -File | Select-Object -First 1
        Copy-Item -LiteralPath $sourceSession.FullName -Destination (Join-Path $remoteSessionDir $sourceSession.Name)
        $originMapPath = Join-Path $script:v032TempRoot 'remote-origin-map.json'
        [ordered]@{
            ('sessions/2026/09/27/' + $sourceSession.Name) = $sourceSession.FullName
        } | ConvertTo-Json | Set-Content -LiteralPath $originMapPath -Encoding UTF8

        $manifestRoot = Join-Path $script:v032Runtime 'CodexChatIndex.images\manifests'
        $remoteManifest = Get-Content -LiteralPath (Join-Path $manifestRoot 'local-codex.json') -Raw | ConvertFrom-Json -Depth 100
        $remoteManifest.sourceId = $remoteSourceId
        $remoteManifest.sourceType = 'webdav-codex'
        $remoteManifest | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $manifestRoot ($remoteSourceId + '.json')) -Encoding UTF8

        $remoteOutput = Join-Path $script:v032Runtime 'remote-output.html'
        & $buildScript `
            -OutputPath $remoteOutput `
            -DataRoot $script:v032Runtime `
            -SourceId $remoteSourceId `
            -SourceLabel 'Laptop-云端 Codex' `
            -SourceType 'webdav-codex' `
            -RemoteSourceRoot $remoteRoot `
            -OriginMapPath $originMapPath `
            -DisableLocalPathImages `
            -RefreshMode Full | Out-Null

        $remoteSourceRoot = Get-TestSourceRoot $script:v032Runtime $remoteSourceId
        $remoteIndex = Get-Content -LiteralPath (Join-Path $remoteSourceRoot 'CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $remoteSession = @($remoteIndex.workspaces | ForEach-Object { @($_.sessions) } | Select-Object -First 1)[0]
        $remoteDetailPath = [IO.Path]::GetFullPath((Join-Path $script:v032Runtime ([string]$remoteSession.detailHref)))
        $remoteDetail = Get-Content -LiteralPath $remoteDetailPath -Raw | ConvertFrom-Json -Depth 100
        $remoteUser = @($remoteDetail.events | Where-Object kind -eq 'user' | Select-Object -First 1)[0]
        $remoteManagedIds = @((@($remoteUser.images) | Where-Object type -eq 'managed').assetId)
        ($remoteManagedIds -contains $script:v032ExpectedLocalAsset) | Should Be $true
        ($remoteManagedIds -contains $script:v032ExpectedDataAsset) | Should Be $true
    }

    It 'reuses the first managed snapshot across replacement deletion and Full rebuilds' {
        [IO.File]::WriteAllBytes($v032LocalImage, [Convert]::FromBase64String($v032DataGifBase64))
        & $buildScript -CodexHome $v032Home -OutputPath $v032Output -DataRoot $v032Runtime -RefreshMode Full -JsonSummary | Out-Null
        $replaced = Get-Content -LiteralPath $v032DetailPath -Raw | ConvertFrom-Json -Depth 100
        $replacedIds = @((@($replaced.events | Where-Object kind -eq 'user' | Select-Object -First 1)[0].images | Where-Object type -eq 'managed').assetId)
        ($replacedIds -contains $v032ExpectedLocalAsset) | Should Be $true
        Remove-Item -LiteralPath $v032LocalImage -Force
        & $buildScript -CodexHome $v032Home -OutputPath $v032Output -DataRoot $v032Runtime -RefreshMode Full -JsonSummary | Out-Null
        $deleted = Get-Content -LiteralPath $v032DetailPath -Raw | ConvertFrom-Json -Depth 100
        $assetIds = @((@($deleted.events | Where-Object kind -eq 'user' | Select-Object -First 1)[0].images | Where-Object type -eq 'managed').assetId)
        ($assetIds -contains $v032ExpectedLocalAsset) | Should Be $true
        ($assetIds -contains $v032ExpectedDataAsset) | Should Be $true
    }

    It 'keeps title-group collapse browser-only with sibling accessible controls' {
        $template = Get-Content -LiteralPath (Join-Path $projectRoot 'templates\CodexChatIndex.template.html') -Raw
        $template | Should Match "TITLE_GROUP_COLLAPSE_STORAGE_KEY = 'Yuji\.titleGroupCollapse\.v1'"
        $template | Should Match 'groupHeader\.appendChild\(groupHead\)'
        $template | Should Match 'groupHeader\.appendChild\(groupToggle\)'
        $template | Should Not Match 'groupHead\.appendChild\(groupToggle\)'
        $template | Should Match "groupToggle\.setAttribute\('aria-expanded'"
        $template | Should Match "String\(getCurrentSourceId\(\) \|\| ''\)"
        $template | Should Match "String\(workspace && workspace\.cwd \|\| ''\)"
        $template | Should Match "String\(group && group\.title \|\| ''\)"
        $template | Should Match 'state\[getTitleGroupCollapseKey\(workspace, group\)\] === true'
        $template | Should Match '\.title-group\.collapsed \.title-group-sessions'
    }

    It 'uses V0.34 mother-title clicks only for collapse while single titles still open sessions' {
        $template = Get-Content -LiteralPath (Join-Path $projectRoot 'templates\CodexChatIndex.template.html') -Raw
        $template | Should Match 'function toggleTitleGroup\(groupNode, groupToggle, workspace, group\)'
        $template | Should Match 'groupHead\.onclick = event => \{[\s\S]*?toggleTitleGroup\(groupNode, groupToggle, current\.workspace, group\)'
        $template | Should Match 'groupToggle\.onclick = event => \{[\s\S]*?event\.stopPropagation\(\);[\s\S]*?toggleTitleGroup\(groupNode, groupToggle, current\.workspace, group\)'
        $template | Should Match "\} else \{\s*groupHead\.onclick = async \(\) => \{[\s\S]*?selectSessionFromTitlePane\(group\.sessions\[0\]\)"
        $template | Should Not Match 'if \(hasMultipleSessionBranches\(group\)\)[\s\S]{0,900}?selectSessionFromTitlePane\(group\.sessions\[0\]\)'
        $template | Should Match 'groupHead\.setAttribute\(''aria-expanded'''
        $template | Should Match '\.title-toggle-button \{[\s\S]*?border: 1px solid rgba\(143,77,31,\.34\)'
    }

    It 'adds browser-only pinned note mode without changing title card note text' {
        $template = Get-Content -LiteralPath (Join-Path $projectRoot 'templates\CodexChatIndex.template.html') -Raw
        $template | Should Match "NOTE_DISPLAY_MODE_STORAGE_KEY = 'Yuji\.noteDisplayMode\.v1'"
        $template | Should Match 'id="noteDisplayToggleButton"[^>]*>备注</button>\s*<button type="button" id="cloudSettingsButton"'
        $template | Should Match 'id="pinnedNotesLayer" class="pinned-notes-layer"'
        $template | Should Match '\.note-tooltip-pinned \{[\s\S]*?pointer-events: auto'
        $template | Should Match 'noteDisplayToggleButton\.textContent = pinned \? ''隐藏'' : ''备注'''
        $template | Should Match "localStorage\.setItem\(NOTE_DISPLAY_MODE_STORAGE_KEY, noteDisplayMode\)"
        $template | Should Match "panel\.className = 'note-tooltip note-tooltip-pinned'"
        $template | Should Match 'body\.textContent = note\.note'
        $template | Should Not Match 'innerHTML\s*=\s*note\.note'
        $template | Should Not Match '<span class="note-tooltip-label">备注</span>'
        $template | Should Not Match "label\.className = 'note-tooltip-label'"
        $template | Should Not Match "label\.textContent = '备注'"
        $template | Should Match "sessionList\.querySelectorAll\('\.title-group-head\.has-note, \.session-btn\.has-note'\)"
        $template | Should Match 'if \(noteDisplayMode === ''pinned''\) return;'
    }

    It 'keeps pinned notes aligned to visible title cards and refreshed by layout changes' {
        $template = Get-Content -LiteralPath (Join-Path $projectRoot 'templates\CodexChatIndex.template.html') -Raw
        $template | Should Match 'function positionPinnedNote\(panel, anchor\)[\s\S]*?anchorRect\.right \+ gap'
        $template | Should Match 'function isPinnedNoteAnchorVisible\(element\)[\s\S]*?rect\.bottom > listRect\.top[\s\S]*?rect\.top < listRect\.bottom'
        $template | Should Match 'function schedulePinnedNotesRefresh\(\)[\s\S]*?requestAnimationFrame'
        $template | Should Match "sessionList\.addEventListener\('scroll', schedulePinnedNotesRefresh, \{ passive: true \}\)"
        $template | Should Match "window\.addEventListener\('resize',[\s\S]*?schedulePinnedNotesRefresh\(\)"
        $template | Should Match 'setTitleGroupCollapsed\(workspace, group, nextCollapsed\);\s*syncTitleGroupsToggleAllButton\(\);\s*if \(typeof schedulePinnedNotesRefresh'
        $template | Should Match 'syncPaneCollapseState\(\)[\s\S]*?schedulePinnedNotesRefresh\(\)'
        $template | Should Match 'renderSessionList\(skipViewerSync\)[\s\S]*?clearPinnedNotes\(\)[\s\S]*?schedulePinnedNotesRefresh\(\)'
    }

    It 'adds the V0.34 bulk title-group toggle immediately before the title sort menu' {
        $template = Get-Content -LiteralPath (Join-Path $projectRoot 'templates\CodexChatIndex.template.html') -Raw
        $template | Should Match 'id="toggleAllTitleGroupsButton"[^>]*class="title-toggle-button title-groups-toggle-all"[^>]*disabled>⌄</button>\s*<details class="sort-menu">'
        $template | Should Match '\.title-toggle-button \{[\s\S]*?width: 26px;[\s\S]*?height: 26px;[\s\S]*?border: 1px solid rgba\(143,77,31,\.34\)'
        $template | Should Match '\.title-group-toggle \{\s*position: absolute;[\s\S]*?right: 8px;[\s\S]*?bottom: 8px;'
        $template | Should Match '\.title-groups-toggle-all \{\s*flex: 0 0 auto;'
        $template | Should Match '\.title-group\.collapsed \.title-group-toggle,\s*\.title-groups-toggle-all\.is-collapsed \{\s*transform: rotate\(-90deg\);'
        $template | Should Match '\.title-toggle-button:disabled \{[\s\S]*?opacity: \.42;[\s\S]*?cursor: default;'
        $template | Should Match "groupToggle\.className = 'title-toggle-button title-group-toggle'"
    }

    It 'scopes V0.34 bulk collapse to currently rendered multi-branch groups and persists them in one batch' {
        $template = Get-Content -LiteralPath (Join-Path $projectRoot 'templates\CodexChatIndex.template.html') -Raw
        $template | Should Match "function getVisibleMultiTitleGroupNodes\(\)[\s\S]*?querySelectorAll\('\.title-group\[data-collapse-key\]'\)"
        $template | Should Match 'groupNode\.dataset\.collapseKey = getTitleGroupCollapseKey\(current\.workspace, group\)'
        $bulkFunction = [regex]::Match(
            $template,
            'function toggleAllVisibleTitleGroups\(\) \{[\s\S]*?\r?\n    \}\r?\n\r?\n    function toggleTitleGroup'
        ).Value
        $bulkFunction | Should Not BeNullOrEmpty
        $bulkFunction | Should Match 'const allCollapsed = groups\.every\(groupNode => groupNode\.classList\.contains\(''collapsed''\)\)'
        $bulkFunction | Should Match 'const targetCollapsed = !allCollapsed'
        $bulkFunction | Should Match "groupNode\.classList\.toggle\('collapsed', targetCollapsed\)"
        $bulkFunction | Should Match 'if \(targetCollapsed\) state\[key\] = true;\s*else delete state\[key\];'
        ([regex]::Matches($bulkFunction, 'readTitleGroupCollapseState\(\)')).Count | Should Be 1
        ([regex]::Matches($bulkFunction, 'localStorage\.setItem\(TITLE_GROUP_COLLAPSE_STORAGE_KEY')).Count | Should Be 1
        ([regex]::Matches($bulkFunction, 'schedulePinnedNotesRefresh\(\)')).Count | Should Be 1
        $bulkFunction | Should Not Match 'toggleTitleGroup\('
        $bulkFunction | Should Not Match 'setTitleGroupCollapsed\('
    }

    It 'derives the V0.34 top arrow state from the current rendered groups and disables it when none exist' {
        $template = Get-Content -LiteralPath (Join-Path $projectRoot 'templates\CodexChatIndex.template.html') -Raw
        $template | Should Match 'function syncTitleGroupsToggleAllButton\(\)[\s\S]*?if \(!groups\.length\)[\s\S]*?disabled = true'
        $template | Should Match "setAttribute\('aria-label', '当前没有可收起的母标题'\)"
        $template | Should Match "const label = allCollapsed \? '展开全部母标题' : '收起全部母标题'"
        $template | Should Match "setAttribute\('aria-expanded', allCollapsed \? 'false' : 'true'\)"
        $template | Should Match "toggleAllTitleGroupsButton\.classList\.toggle\('is-collapsed', allCollapsed\)"
        $template | Should Match "toggleAllTitleGroupsButton\.addEventListener\('click', toggleAllVisibleTitleGroups\)"
        $template | Should Match 'renderSessionList\(skipViewerSync\)[\s\S]*?sessionList\.innerHTML = '''';\s*clearPinnedNotes\(\);\s*syncTitleGroupsToggleAllButton\(\);'
        $template | Should Match 'sessionList\.appendChild\(groupNode\);\s*\}\);\s*syncTitleGroupsToggleAllButton\(\);\s*schedulePinnedNotesRefresh\(\);'
    }

    It 'ignores Python cache artifacts without hiding Python source files' {
        $gitignore = Get-Content -LiteralPath (Join-Path $projectRoot '.gitignore')
        $gitignore | Should Contain 'temp/'
        $gitignore | Should Contain '__pycache__/'
        $gitignore | Should Contain '*.pyc'
        $gitignore | Should Not Contain '*.py'
    }

    AfterAll {
        Remove-Item -LiteralPath $script:v032TempRoot -Force -Recurse -ErrorAction SilentlyContinue
    }
}

