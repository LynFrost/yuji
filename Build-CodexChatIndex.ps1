param(
    [string]$CodexHome = "$HOME\.codex",
    [string]$ClaudeHome = "$HOME\.claude",
    [string[]]$ClaudeScanRoots = @(),
    [string]$OutputPath = "",
    [string]$DataRoot = "",
    [string]$SourceId = "local-codex",
    [string]$SourceLabel = "",
    [string]$SourceType = "local-codex",
    [string]$ExternalSourcePath = "",
    [ValidateSet("Full", "Incremental", "Current")]
    [string]$RefreshMode = "Full",
    [string]$CurrentSessionPath = "",
    [switch]$JsonSummary
)

$ErrorActionPreference = "Stop"
$buildStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

$outputPathWasProvided = -not [string]::IsNullOrWhiteSpace($OutputPath)
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Join-Path $PSScriptRoot 'temp') 'CodexChatIndex.html'
}

function Convert-ToHtmlText {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return "" }
    return [System.Net.WebUtility]::HtmlEncode($Value)
}

function Convert-ToJavaScriptSingleQuotedContent {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return "" }
    return ([string]$Value).Replace('\', '\\').Replace("'", "\'")
}

function Render-HtmlTemplate {
    param(
        [string]$TemplatePath,
        [hashtable]$Values
    )

    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        throw "HTML template was not found: $TemplatePath"
    }

    $template = Get-Content -LiteralPath $TemplatePath -Raw
    $renderValues = [ordered]@{
        BUILDER_VERSION = Convert-ToHtmlText $Values['BUILDER_VERSION']
        INDEX_URL = [string]$Values['INDEX_URL']
        TOTAL_SESSIONS = Convert-ToHtmlText $Values['TOTAL_SESSIONS']
        TOTAL_WORKSPACES = Convert-ToHtmlText $Values['TOTAL_WORKSPACES']
        ARCHIVED_COUNT = Convert-ToHtmlText $Values['ARCHIVED_COUNT']
        IMAGE_REF_COUNT = Convert-ToHtmlText $Values['IMAGE_REF_COUNT']
        GENERATED_AT = Convert-ToHtmlText $Values['GENERATED_AT']
    }

    foreach ($key in $renderValues.Keys) {
        $placeholder = '{{' + $key + '}}'
        if (-not $template.Contains($placeholder)) {
            throw "HTML template is missing required placeholder: $placeholder"
        }
        $template = $template.Replace($placeholder, [string]$renderValues[$key])
    }

    if ($template -match '{{[A-Z0-9_]+}}') {
        throw "HTML template contains unresolved placeholders."
    }

    return $template
}

function Convert-ToFileUri {
    param([string]$Path)
    try {
        return ([System.Uri]::new((Resolve-Path -LiteralPath $Path).ProviderPath)).AbsoluteUri
    } catch {
        return ""
    }
}

function Convert-ToRelativeWebPath {
    param(
        [string]$FromDirectory,
        [string]$ToPath
    )

    $fromFullPath = [System.IO.Path]::GetFullPath($FromDirectory)
    if (-not $fromFullPath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $fromFullPath += [System.IO.Path]::DirectorySeparatorChar
    }
    $toFullPath = [System.IO.Path]::GetFullPath($ToPath)
    $fromUri = [System.Uri]::new($fromFullPath)
    $toUri = [System.Uri]::new($toFullPath)
    return [System.Uri]::UnescapeDataString($fromUri.MakeRelativeUri($toUri).ToString()).Replace('\', '/')
}

function Convert-ToLocalTimeText {
    param([AllowNull()]$Timestamp)
    if ($null -eq $Timestamp) { return "" }
    try {
        if ($Timestamp -is [DateTimeOffset]) {
            return $Timestamp.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
        }
        if ($Timestamp -is [DateTime]) {
            if ($Timestamp.Kind -eq [DateTimeKind]::Utc) {
                return $Timestamp.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
            }
            if ($Timestamp.Kind -eq [DateTimeKind]::Local) {
                return $Timestamp.ToString("yyyy-MM-dd HH:mm:ss")
            }
        }
        $text = [string]$Timestamp
        if ([string]::IsNullOrWhiteSpace($text)) { return "" }
        return ([DateTimeOffset]::Parse($text)).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
    } catch {
        return [string]$Timestamp
    }
}

function Convert-ToUtcIsoText {
    param([AllowNull()]$Timestamp)
    if ($null -eq $Timestamp) { return "" }
    try {
        if ($Timestamp -is [DateTimeOffset]) {
            return $Timestamp.ToUniversalTime().ToString("o")
        }
        if ($Timestamp -is [DateTime]) {
            return $Timestamp.ToUniversalTime().ToString("o")
        }
        $text = [string]$Timestamp
        if ([string]::IsNullOrWhiteSpace($text)) { return "" }
        return ([DateTimeOffset]::Parse($text)).ToUniversalTime().ToString("o")
    } catch {
        return [string]$Timestamp
    }
}

function Get-FirstLine {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    return (($Text -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1) -as [string]).Trim()
}

function Get-ShortText {
    param(
        [AllowNull()][string]$Text,
        [int]$MaxLength = 220
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $clean = ($Text -replace "\s+", " ").Trim()
    if ($clean.Length -le $MaxLength) { return $clean }
    return $clean.Substring(0, $MaxLength - 1) + "…"
}

function New-ReaderEvent {
    param(
        [string]$Kind,
        [string]$Timestamp,
        [string]$TimestampLocal,
        [string]$TurnId = "",
        [string]$Phase = "",
        [string]$Role = "",
        [string]$CallId = "",
        [string]$ToolName = "",
        [string]$Status = "",
        [string]$Summary = "",
        [string]$RawText = "",
        [string]$RenderMode = "plain_text",
        [string]$GroupKey = "",
        [object[]]$Images = @()
    )

    $event = [ordered]@{
        kind = $Kind
        timestamp = $Timestamp
        timestampLocal = $TimestampLocal
        turnId = $TurnId
        phase = $Phase
        role = $Role
        callId = $CallId
        toolName = $ToolName
        status = $Status
        summary = $Summary
        rawText = $RawText
        renderMode = $RenderMode
        groupKey = $GroupKey
    }
    if ($Images -and @($Images).Count -gt 0) {
        $event.images = @($Images)
    }
    return $event
}

function Get-CodexMessageContentText {
    param([AllowNull()]$Content)
    if ($null -eq $Content) { return "" }
    if ($Content -is [string]) { return [string]$Content }
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($part in @($Content)) {
        if ($null -eq $part) { continue }
        if ($part -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($part)) { [void]$parts.Add([string]$part) }
            continue
        }
        $type = [string](Get-ObjectPropertyValue $part @('type'))
        if ($type -in @('input_text', 'text')) {
            $text = [string](Get-ObjectPropertyValue $part @('text'))
            if (-not [string]::IsNullOrWhiteSpace($text)) { [void]$parts.Add($text) }
        }
    }
    return (@($parts) -join "`n").Trim()
}

function Get-CodexMessageContentImages {
    param([AllowNull()]$Content)
    $images = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Content -or $Content -is [string]) { return @() }
    foreach ($part in @($Content)) {
        if ($null -eq $part -or $part -is [string]) { continue }
        $type = [string](Get-ObjectPropertyValue $part @('type'))
        if ($type -ne 'input_image') { continue }
        $src = [string](Get-ObjectPropertyValue $part @('image_url', 'url', 'data', 'source'))
        if ([string]::IsNullOrWhiteSpace($src)) {
            $imageUrl = Get-ObjectPropertyValue $part @('image_url')
            $src = [string](Get-ObjectPropertyValue $imageUrl @('url', 'data'))
        }
        if ([string]::IsNullOrWhiteSpace($src)) { continue }
        [void]$images.Add([ordered]@{
            src = $src
            type = 'input_image'
        })
    }
    return @($images)
}

function Test-ReaderEventHasImages {
    param([AllowNull()]$Event)
    if ($null -eq $Event) { return $false }
    if ($Event -is [System.Collections.IDictionary]) {
        if (-not $Event.Contains('images')) { return $false }
        return @($Event['images']).Count -gt 0
    }
    if ($Event.PSObject.Properties.Name -notcontains 'images') { return $false }
    return @($Event.images).Count -gt 0
}

function Test-IsInjectedCodexContextMessage {
    param(
        [AllowNull()][string]$RawText,
        [bool]$HasImages = $false
    )
    if ($HasImages) { return $false }
    if ([string]::IsNullOrWhiteSpace($RawText)) { return $false }
    $text = $RawText.Trim()
    if ($text -match '(?s)^# AGENTS\.md instructions for .+?<INSTRUCTIONS>.*?</INSTRUCTIONS>') { return $true }
    if ($text -match '(?s)^<environment_context>.*?</environment_context>$') { return $true }
    if ($text -match '(?s)^<permissions instructions>.*?</permissions instructions>$') { return $true }
    if ($text -match '(?s)^<collaboration_mode>.*?</collaboration_mode>$') { return $true }
    if ($text -match '(?s)^<skills_instructions>.*?</skills_instructions>$') { return $true }
    if ($text -match '(?s)^<app-context>.*?</app-context>$') { return $true }
    return $false
}

function Get-NormalizedUserMessageSignature {
    param([AllowNull()][string]$RawText)
    if ([string]::IsNullOrWhiteSpace($RawText)) { return "" }
    return (($RawText -replace "`r`n", "`n") -replace "`r", "`n").Trim()
}

function Test-IsNearTimestamp {
    param(
        [AllowNull()][string]$Left,
        [AllowNull()][string]$Right,
        [double]$MaxSeconds = 5
    )
    if ([string]$Left -eq [string]$Right) { return $true }
    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
    try {
        $leftTime = [datetimeoffset]::Parse([string]$Left)
        $rightTime = [datetimeoffset]::Parse([string]$Right)
        return ([Math]::Abs(($leftTime - $rightTime).TotalSeconds) -le $MaxSeconds)
    } catch {
        return $false
    }
}

function Test-IsDuplicateAdjacentUserEvent {
    param(
        [System.Collections.Generic.List[object]]$Events,
        [AllowNull()][string]$Timestamp,
        [AllowNull()][string]$RawText
    )
    if ($null -eq $Events -or $Events.Count -eq 0) { return $false }
    if ([string]::IsNullOrWhiteSpace($RawText)) { return $false }
    $messageSignature = Get-NormalizedUserMessageSignature $RawText
    if ([string]::IsNullOrWhiteSpace($messageSignature)) { return $false }
    $checkedEvents = 0
    for ($eventIndex = $Events.Count - 1; $eventIndex -ge 0 -and $checkedEvents -lt 80; $eventIndex--) {
        $checkedEvents++
        $event = $Events[$eventIndex]
        if ($null -eq $event -or [string]$event.kind -ne 'user') { continue }
        if ((Get-NormalizedUserMessageSignature ([string]$event.rawText)) -ne $messageSignature) { continue }
        if (Test-IsNearTimestamp -Left ([string]$event.timestamp) -Right ([string]$Timestamp) -MaxSeconds 5) {
            return $true
        }
    }
    return $false
}

function New-SkippedReaderSession {
    param([string]$Reason)
    return [pscustomobject]@{
        Skipped = $true
        Reason = $Reason
    }
}

function Test-IsSkippedReaderSession {
    param([AllowNull()]$Session)
    if ($null -eq $Session) { return $false }
    return ($Session.PSObject.Properties.Name -contains 'Skipped' -and [bool]$Session.Skipped)
}

function Get-ToolSummary {
    param([string]$ToolName, [string]$Arguments)
    $snippet = [string]$Arguments
    if ($snippet.Length -gt 120) { $snippet = $snippet.Substring(0, 119) + '…' }
    return ($ToolName + ': ' + $snippet).Trim()
}

function Get-CommandResultSummary {
    param($Payload)
    $exitCode = if ($null -ne $Payload.exit_code) { [string]$Payload.exit_code } else { '?' }
    $status = if ($Payload.status) { [string]$Payload.status } else { 'unknown' }
    $output = [string]$Payload.aggregated_output
    $preview = if ([string]::IsNullOrWhiteSpace($output)) { '' } else { Get-ShortText $output 160 }
    return ('exit=' + $exitCode + ' status=' + $status + ' ' + $preview).Trim()
}

function Get-DetailShardSuffix {
    param([string]$Path)
    $normalized = [string]$Path
    if ([string]::IsNullOrWhiteSpace($normalized)) { return '000000000000' }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized.ToLowerInvariant())
        $hash = $sha256.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash)).Replace('-', '').Substring(0, 12).ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Get-NormalizedFilePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    return [System.IO.Path]::GetFullPath($Path)
}

function Test-PathWithinDirectory {
    param(
        [string]$Path,
        [string]$Directory
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Directory)) { return $false }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $fullDirectory = [System.IO.Path]::GetFullPath($Directory)
        if (-not $fullDirectory.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
            $fullDirectory += [System.IO.Path]::DirectorySeparatorChar
        }
        return $fullPath.StartsWith($fullDirectory, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Test-IsArchivedSessionPath {
    param([string]$Path)
    return ([string]$Path) -match '(^|[\\/])archived_sessions([\\/]|$)'
}

function Get-SafeSourceId {
    param([string]$Value)
    $candidate = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) { return "local-codex" }
    $candidate = $candidate -replace '[^A-Za-z0-9._-]+', '-'
    $candidate = $candidate.Trim('-')
    if ([string]::IsNullOrWhiteSpace($candidate)) { return "local-codex" }
    return $candidate
}

function Update-SourceManifest {
    param(
        [string]$RuntimeDataRoot,
        $Source
    )
    if ([string]::IsNullOrWhiteSpace($RuntimeDataRoot) -or $null -eq $Source) { return }
    $manifestPath = Join-Path $RuntimeDataRoot 'CodexChatIndex.sources.json'
    $sources = [System.Collections.Generic.List[object]]::new()
    $existing = Read-JsonFileDetailed $manifestPath
    if ($existing.Parsed -and $existing.Value -and $existing.Value.sources) {
        foreach ($item in @($existing.Value.sources)) {
            if ($item -and -not [string]::IsNullOrWhiteSpace([string]$item.id)) {
                [void]$sources.Add($item)
            }
        }
    }

    $localExists = @($sources | Where-Object { [string]$_.id -eq 'local-codex' }).Count -gt 0
    if (-not $localExists) {
        [void]$sources.Insert(0, [ordered]@{
            id = 'local-codex'
            label = '本机 Codex'
            type = 'local-codex'
            roots = @(
                (Join-Path $CodexHome 'sessions'),
                (Join-Path $CodexHome 'archived_sessions')
            )
        })
    }

    $localClaudeExists = @($sources | Where-Object { [string]$_.id -eq 'local-claude' }).Count -gt 0
    if (-not $localClaudeExists) {
        [void]$sources.Insert([Math]::Min(1, $sources.Count), [ordered]@{
            id = 'local-claude'
            label = '本机 Claude'
            type = 'local-claude'
            root = (Join-Path $ClaudeHome 'projects')
            sessionsRoot = (Join-Path $ClaudeHome 'sessions')
        })
    }

    $nextSources = [System.Collections.Generic.List[object]]::new()
    $replaced = $false
    foreach ($item in $sources) {
        if ([string]$item.id -eq [string]$Source.id) {
            [void]$nextSources.Add($Source)
            $replaced = $true
        } else {
            [void]$nextSources.Add($item)
        }
    }
    if (-not $replaced) {
        [void]$nextSources.Add($Source)
    }

    $payload = [ordered]@{
        version = 1
        selectedSourceId = [string]$Source.id
        sources = @($nextSources)
    }
    Write-Utf8FileAtomic -Path $manifestPath -Value ($payload | ConvertTo-Json -Depth 20)
}

function Get-SessionDetailFileName {
    param($Session)
    return ([string]$Session.Id + '-' + (Get-DetailShardSuffix ([string]$Session.Path)) + '.json')
}

function Get-SessionSearchText {
    param($Session)
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @(
        $Session.Title,
        $Session.Summary,
        $Session.Path,
        $Session.Cwd,
        $Session.Source,
        $Session.ModelProvider
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            [void]$parts.Add([string]$value)
        }
    }

    foreach ($event in @($Session.Events)) {
        if ($null -eq $event) { continue }
        foreach ($value in @(
            $event.kind,
            $event.phase,
            $event.role,
            $event.toolName,
            $event.status,
            $event.summary,
            $event.rawText
        )) {
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                [void]$parts.Add([string]$value)
            }
        }
    }

    return (($parts -join "`n") -replace "`0", "")
}

function Write-Utf8FileAtomic {
    param(
        [string]$Path,
        [AllowNull()][string]$Value
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Force $directory | Out-Null
    }

    $leaf = [System.IO.Path]::GetFileName($Path)
    $tempPath = Join-Path $directory ('.' + $leaf + '.' + [System.Guid]::NewGuid().ToString('N') + '.tmp')
    Set-Content -LiteralPath $tempPath -Value $Value -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Read-JsonFileDetailed {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Exists = $false
            Parsed = $false
            Value = $null
            Error = "missing"
        }
    }
    try {
        return [pscustomobject]@{
            Exists = $true
            Parsed = $true
            Value = (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100)
            Error = ""
        }
    } catch {
        return [pscustomobject]@{
            Exists = $true
            Parsed = $false
            Value = $null
            Error = "invalid"
        }
    }
}

function New-SourceSignatureFileEntry {
    param([System.IO.FileInfo]$File)
    if ($null -eq $File) { return $null }
    return [ordered]@{
        path = Get-NormalizedFilePath $File.FullName
        sizeBytes = [int64]$File.Length
        lastWriteTimeUtc = $File.LastWriteTimeUtc.ToUniversalTime().ToString("o")
    }
}

function Get-SourceSignatureFileEntries {
    param([object[]]$Files)
    return @(
        @($Files) |
            Where-Object { $null -ne $_ } |
            ForEach-Object { New-SourceSignatureFileEntry $_ } |
            Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.path) } |
            Sort-Object path
    )
}

function Get-ClaudeMetadataSignatureEntries {
    param([string]$ClaudeSessionsRoot)
    if ([string]::IsNullOrWhiteSpace($ClaudeSessionsRoot) -or -not (Test-Path -LiteralPath $ClaudeSessionsRoot -PathType Container)) {
        return @()
    }

    return Get-SourceSignatureFileEntries -Files @(
        Get-ChildItem -LiteralPath $ClaudeSessionsRoot -File -Filter '*.json' -ErrorAction SilentlyContinue
    )
}

function New-SourceSignature {
    param(
        [object[]]$Files,
        [string]$SourceId,
        [string]$SourceType,
        [string]$BuilderVersion,
        [string]$ExternalSourcePath,
        [string]$ClaudeSessionsRoot,
        [string[]]$ClaudeScanRoots
    )

    $sourceFiles = @(Get-SourceSignatureFileEntries -Files $Files)
    $isClaudeSource = [string]$SourceType -eq 'local-claude'
    return [ordered]@{
        sourceId = [string]$SourceId
        sourceType = [string]$SourceType
        builderVersion = [string]$BuilderVersion
        refreshMode = 'Incremental'
        externalSourcePath = if ([string]::IsNullOrWhiteSpace($ExternalSourcePath)) { "" } else { Get-NormalizedFilePath $ExternalSourcePath }
        claudeSessionsRoot = if ($isClaudeSource -and -not [string]::IsNullOrWhiteSpace($ClaudeSessionsRoot)) { Get-NormalizedFilePath $ClaudeSessionsRoot } else { "" }
        claudeScanRoots = if ($isClaudeSource) {
            @($ClaudeScanRoots | ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace([string]$_)) {
                    Get-NormalizedFilePath ([string]$_)
                }
            } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        } else {
            @()
        }
        fileCount = $sourceFiles.Count
        files = @($sourceFiles)
        claudeSessionMetadataFiles = if ($isClaudeSource) { @(Get-ClaudeMetadataSignatureEntries -ClaudeSessionsRoot $ClaudeSessionsRoot) } else { @() }
    }
}

function Convert-SourceSignatureToText {
    param([AllowNull()]$Signature)
    if ($null -eq $Signature) { return "" }
    try {
        return [string]($Signature | ConvertTo-Json -Depth 100 -Compress)
    } catch {
        return ""
    }
}

function Test-BuildOutputsComplete {
    param(
        [string]$HtmlPath,
        [string]$DataPath,
        [string]$SearchPath,
        [string]$CachePath
    )

    foreach ($path in @($HtmlPath, $DataPath, $SearchPath, $CachePath)) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $false
        }
    }
    return $true
}

function Test-CachedDetailFilesComplete {
    param(
        [AllowNull()]$CacheData,
        [string]$DetailRoot
    )

    if ($null -eq $CacheData) { return $false }
    foreach ($record in @($CacheData.files)) {
        if ([string]::IsNullOrWhiteSpace([string]$record.detailFileName)) { return $false }
        if (-not (Test-Path -LiteralPath (Join-Path $DetailRoot ([string]$record.detailFileName)) -PathType Leaf)) {
            return $false
        }
    }
    return $true
}

function Convert-ToCacheTimeText {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return "" }
    try {
        if ($Value -is [DateTimeOffset]) {
            return $Value.ToUniversalTime().ToString("o")
        }
        if ($Value -is [DateTime]) {
            return $Value.ToUniversalTime().ToString("o")
        }
        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text)) { return "" }
        return ([DateTimeOffset]::Parse($text)).ToUniversalTime().ToString("o")
    } catch {
        return [string]$Value
    }
}

function Add-SessionRuntimeFields {
    param(
        $Session,
        [System.IO.FileInfo]$File,
        [string]$DetailFileName,
        [bool]$Cached,
        [string]$SourceId = "local-codex"
    )

    $lastWriteTimeUtc = if ($File) { $File.LastWriteTimeUtc.ToString("o") } else { Convert-ToCacheTimeText $Session.LastWriteTimeUtc }
    $sizeBytes = if ($File) { [int64]$File.Length } else { [int64]$Session.SizeBytes }
    $Session | Add-Member -NotePropertyName DetailFileName -NotePropertyValue $DetailFileName -Force
    $Session | Add-Member -NotePropertyName SourceId -NotePropertyValue $SourceId -Force
    $Session | Add-Member -NotePropertyName LastWriteTimeUtc -NotePropertyValue $lastWriteTimeUtc -Force
    $Session | Add-Member -NotePropertyName SizeBytes -NotePropertyValue $sizeBytes -Force
    if (-not $Cached -or -not ($Session.PSObject.Properties.Name -contains 'SearchText')) {
        $Session | Add-Member -NotePropertyName SearchText -NotePropertyValue (Get-SessionSearchText $Session) -Force
    }
    $Session | Add-Member -NotePropertyName Cached -NotePropertyValue $Cached -Force
    return $Session
}

function New-SessionFromCacheRecord {
    param($Record)
    if ($null -eq $Record) { return $null }
    return [pscustomobject]@{
        Id = [string]$Record.id
        Cwd = [string]$Record.cwd
        Title = [string]$Record.title
        Summary = [string]$Record.summary
        CreatedAt = [string]$Record.createdAt
        CreatedLocal = [string]$Record.createdLocal
        UpdatedAt = [string]$Record.updatedAt
        UpdatedLocal = [string]$Record.updatedLocal
        Source = [string]$Record.source
        SourceId = if ([string]::IsNullOrWhiteSpace([string]$Record.sourceId)) { "local-codex" } else { [string]$Record.sourceId }
        ModelProvider = [string]$Record.modelProvider
        CliVersion = [string]$Record.cliVersion
        UserCount = [int]$Record.userCount
        AssistantCount = [int]$Record.assistantCount
        HasImageReference = [bool]$Record.hasImageReference
        Archived = [bool]$Record.archived
        Path = [string]$Record.path
        FileUri = [string]$Record.fileUri
        SizeBytes = [int64]$Record.sizeBytes
        LastWriteTimeUtc = Convert-ToCacheTimeText $Record.lastWriteTimeUtc
        DetailFileName = [string]$Record.detailFileName
        SearchText = [string]$Record.searchText
        Cached = $true
        Events = $null
    }
}

function New-CacheRecordFromSession {
    param($Session)
    return [ordered]@{
        path = [string]$Session.Path
        id = [string]$Session.Id
        detailFileName = [string]$Session.DetailFileName
        sourceId = if ([string]::IsNullOrWhiteSpace([string]$Session.SourceId)) { "local-codex" } else { [string]$Session.SourceId }
        sizeBytes = [int64]$Session.SizeBytes
        lastWriteTimeUtc = [string]$Session.LastWriteTimeUtc
        archived = [bool]$Session.Archived
        cwd = [string]$Session.Cwd
        title = [string]$Session.Title
        summary = [string]$Session.Summary
        createdAt = [string]$Session.CreatedAt
        createdLocal = [string]$Session.CreatedLocal
        updatedAt = [string]$Session.UpdatedAt
        updatedLocal = [string]$Session.UpdatedLocal
        userCount = [int]$Session.UserCount
        assistantCount = [int]$Session.AssistantCount
        messageCount = ([int]$Session.UserCount + [int]$Session.AssistantCount)
        source = [string]$Session.Source
        modelProvider = [string]$Session.ModelProvider
        cliVersion = [string]$Session.CliVersion
        codexSession = $true
        hasImageReference = [bool]$Session.HasImageReference
        fileUri = [string]$Session.FileUri
        searchText = if ($Session.PSObject.Properties.Name -contains 'SearchText') { [string]$Session.SearchText } else { Get-SessionSearchText $Session }
    }
}

function Test-CacheRecordFresh {
    param(
        $Record,
        [System.IO.FileInfo]$File,
        [string]$DetailRoot
    )

    if ($null -eq $Record -or $null -eq $File) { return $false }
    if ([bool]$Record.codexSession -ne $true) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Record.detailFileName)) { return $false }
    $detailPath = Join-Path $DetailRoot ([string]$Record.detailFileName)
    if (-not (Test-Path -LiteralPath $detailPath -PathType Leaf)) { return $false }
    if ([int64]$Record.sizeBytes -ne [int64]$File.Length) { return $false }
    return (Convert-ToCacheTimeText $Record.lastWriteTimeUtc) -eq $File.LastWriteTimeUtc.ToString("o")
}

function Get-ObjectPropertyValue {
    param(
        [AllowNull()]$Object,
        [string[]]$Names
    )
    if ($null -eq $Object) { return $null }
    foreach ($name in @($Names)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property) { return $property.Value }
    }
    return $null
}

function Convert-ToCompactJsonText {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return "" }
    try {
        return [string]($Value | ConvertTo-Json -Depth 40 -Compress)
    } catch {
        return [string]$Value
    }
}

function Convert-ClaudeContentPartToText {
    param([AllowNull()]$Part)
    if ($null -eq $Part) { return "" }
    if ($Part -is [string]) { return [string]$Part }
    foreach ($name in @('text', 'thinking', 'content', 'message', 'summary')) {
        $value = Get-ObjectPropertyValue $Part @($name)
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            if ($value -is [array]) {
                return (($value | ForEach-Object { Convert-ClaudeContentPartToText $_ }) -join "`n").Trim()
            }
            return [string]$value
        }
    }
    return ""
}

function Convert-ClaudeContentToText {
    param(
        [AllowNull()]$Content,
        [string[]]$PreferredTypes = @('text')
    )
    if ($null -eq $Content) { return "" }
    if ($Content -is [string]) { return [string]$Content }

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($part in @($Content)) {
        if ($null -eq $part) { continue }
        $type = [string](Get-ObjectPropertyValue $part @('type'))
        if ($PreferredTypes.Count -gt 0 -and -not ($PreferredTypes -contains $type)) { continue }
        $text = Convert-ClaudeContentPartToText $part
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            [void]$parts.Add($text)
        }
    }
    return (($parts -join "`n").TrimEnd())
}

function Read-ClaudeSessionMetadataMap {
    param([string]$ClaudeSessionsRoot)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($ClaudeSessionsRoot) -or -not (Test-Path -LiteralPath $ClaudeSessionsRoot -PathType Container)) {
        return $map
    }

    Get-ChildItem -LiteralPath $ClaudeSessionsRoot -File -Filter '*.json' | ForEach-Object {
        try {
            $metadata = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 100
        } catch {
            return
        }
        $sessionId = [string](Get-ObjectPropertyValue $metadata @('sessionId', 'session_id', 'id'))
        if ([string]::IsNullOrWhiteSpace($sessionId)) {
            $sessionId = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
        }
        if (-not [string]::IsNullOrWhiteSpace($sessionId)) {
            $map[$sessionId] = $metadata
        }
    }
    return $map
}

function Get-ClaudeExtraSourceRoots {
    param(
        [string]$ClaudeHome,
        [string[]]$ClaudeScanRoots = @()
    )
    if ($ClaudeScanRoots -and @($ClaudeScanRoots).Count -gt 0) {
        return @($ClaudeScanRoots | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace([string]$_)) { return }
            [System.IO.Path]::GetFullPath([string]$_)
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    }

    $roots = [System.Collections.Generic.List[string]]::new()
    $homePath = if ([string]::IsNullOrWhiteSpace($ClaudeHome)) { "" } else { [System.IO.Path]::GetFullPath($ClaudeHome) }

    if (-not [string]::IsNullOrWhiteSpace($homePath)) {
        $roots.Add((Join-Path $homePath 'projects'))
    }

    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $roamingAppData = [Environment]::GetFolderPath('ApplicationData')
    $packagesRoot = Join-Path $localAppData 'Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p'
    $vscodeChatRoot = Join-Path $roamingAppData 'Code\User\workspaceStorage'

    foreach ($root in @(
        (Join-Path $packagesRoot 'local-agent-mode-sessions'),
        (Join-Path $vscodeChatRoot '')
    )) {
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            $roots.Add($root)
        }
    }

    return @($roots | Sort-Object -Unique)
}

function New-ClaudeSessionFromJsonEntry {
    param(
        [AllowNull()]$Entry,
        [string]$SourceRootHint,
        [string]$MetadataSource
    )

    if ($null -eq $Entry) { return $null }
    $sessionId = [string](Get-ObjectPropertyValue $Entry @('sessionId', 'session_id', 'conversationId', 'uuid'))
    if ([string]::IsNullOrWhiteSpace($sessionId)) { return $null }
    $entryType = [string](Get-ObjectPropertyValue $Entry @('type'))
    $message = Get-ObjectPropertyValue $Entry @('message')
    $role = [string](Get-ObjectPropertyValue $message @('role'))
    if ([string]::IsNullOrWhiteSpace($role)) {
        $role = [string](Get-ObjectPropertyValue $Entry @('role'))
    }
    if ([string]::IsNullOrWhiteSpace($role) -and $entryType -in @('user', 'assistant', 'system')) {
        $role = $entryType
    }

    $content = Get-ObjectPropertyValue $message @('content')
    if ($null -eq $content) { $content = Get-ObjectPropertyValue $Entry @('content', 'text') }
    $timestamp = Get-ObjectPropertyValue $Entry @('timestamp', 'created_at', 'createdAt')
    $cwd = [string](Get-ObjectPropertyValue $Entry @('cwd', 'workingDirectory', 'workspace'))
    if ([string]::IsNullOrWhiteSpace($cwd)) {
        $cwd = [string](Get-ObjectPropertyValue $message @('cwd', 'workingDirectory', 'workspace'))
    }
    $entrypoint = [string](Get-ObjectPropertyValue $Entry @('entrypoint', 'entryPoint'))
    if ([string]::IsNullOrWhiteSpace($entrypoint)) {
        $entrypoint = [string](Get-ObjectPropertyValue $Entry @('userType', 'source'))
    }
    $title = [string](Get-ObjectPropertyValue $Entry @('title', 'summary'))
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = [string](Get-ObjectPropertyValue $Entry @('firstPrompt'))
    }

    $events = [System.Collections.Generic.List[object]]::new()
    $recognizedClaudeRecordSeen = $false
    $firstUserMessage = ""

    if ($entryType -eq 'queue-operation') {
        $recognizedClaudeRecordSeen = $true
        return $null
    }
    if ($entryType -eq 'file-history-snapshot' -or $entryType -eq 'updateTokens' -or $entryType -eq 'sessionInfo' -or $entryType -eq 'error') {
        return $null
    }

    if ($role -eq 'user') {
        $recognizedClaudeRecordSeen = $true
        $messageText = Convert-ClaudeContentToText $content @('text')
        if ([string]::IsNullOrWhiteSpace($messageText) -and $content -is [string]) { $messageText = [string]$content }
        if (-not [string]::IsNullOrWhiteSpace($messageText)) {
            if ([string]::IsNullOrWhiteSpace($firstUserMessage)) { $firstUserMessage = $messageText }
            $events.Add((New-ReaderEvent `
                -Kind 'user' `
                -Timestamp (Convert-ToUtcIsoText $timestamp) `
                -TimestampLocal (Convert-ToLocalTimeText $timestamp) `
                -TurnId $sessionId `
                -Role 'user' `
                -Summary (Get-ShortText $messageText 160) `
                -RawText ($messageText.TrimEnd()) `
                -RenderMode 'plain_text'))
        }
    } elseif ($role -eq 'assistant') {
        $recognizedClaudeRecordSeen = $true
        foreach ($part in @($content)) {
            if ($null -eq $part) { continue }
            if ($part -is [string]) {
                $events.Add((New-ReaderEvent `
                    -Kind 'assistant_final' `
                    -Timestamp (Convert-ToUtcIsoText $timestamp) `
                    -TimestampLocal (Convert-ToLocalTimeText $timestamp) `
                    -TurnId $sessionId `
                    -Role 'assistant' `
                    -Summary (Get-ShortText ([string]$part) 160) `
                    -RawText ([string]$part).TrimEnd() `
                    -RenderMode 'deterministic_markdown'))
                continue
            }
            $partType = [string](Get-ObjectPropertyValue $part @('type'))
            if ($partType -eq 'text') {
                $text = Convert-ClaudeContentPartToText $part
                if ([string]::IsNullOrWhiteSpace($text)) { continue }
                $events.Add((New-ReaderEvent `
                    -Kind 'assistant_final' `
                    -Timestamp (Convert-ToUtcIsoText $timestamp) `
                    -TimestampLocal (Convert-ToLocalTimeText $timestamp) `
                    -TurnId $sessionId `
                    -Role 'assistant' `
                    -Summary (Get-ShortText $text 160) `
                    -RawText ($text.TrimEnd()) `
                    -RenderMode 'deterministic_markdown'))
                continue
            }
            if ($partType -eq 'thinking') {
                $thinking = Convert-ClaudeContentPartToText $part
                if ([string]::IsNullOrWhiteSpace($thinking)) { continue }
                $events.Add((New-ReaderEvent `
                    -Kind 'assistant_commentary' `
                    -Timestamp (Convert-ToUtcIsoText $timestamp) `
                    -TimestampLocal (Convert-ToLocalTimeText $timestamp) `
                    -TurnId $sessionId `
                    -Phase 'thinking' `
                    -Role 'assistant' `
                    -Summary (Get-ShortText $thinking 160) `
                    -RawText ($thinking.TrimEnd()) `
                    -RenderMode 'plain_text'))
                continue
            }
        }
    }

    if (-not $recognizedClaudeRecordSeen) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = Get-FirstLine $firstUserMessage
    }
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = if ($MetadataSource) { $MetadataSource } else { $sessionId }
    }

    $metadata = @{}
    if (-not [string]::IsNullOrWhiteSpace($MetadataSource)) {
        $metadata['entrypoint'] = $entrypoint
    }

    [pscustomobject]@{
        Id = $sessionId
        Cwd = $cwd
        Title = $title
        Summary = (Get-ShortText $firstUserMessage 220)
        CreatedAt = (Convert-ToUtcIsoText $timestamp)
        CreatedLocal = (Convert-ToLocalTimeText $timestamp)
        UpdatedAt = (Convert-ToUtcIsoText $timestamp)
        UpdatedLocal = (Convert-ToLocalTimeText $timestamp)
        Source = if ([string]::IsNullOrWhiteSpace($entrypoint)) { $MetadataSource } else { $entrypoint }
        ModelProvider = "Claude"
        CliVersion = ""
        UserCount = @($events | Where-Object { $_.kind -eq 'user' }).Count
        AssistantCount = @($events | Where-Object { $_.kind -in @('assistant_commentary','assistant_final') }).Count
        HasImageReference = $false
        Archived = $false
        Path = $SourceRootHint
        FileUri = ""
        SizeBytes = 0
        Events = @($events)
    }
}

function Read-ClaudeCodeChatConversation {
    param([System.IO.FileInfo]$File)

    try {
        $conversation = Get-Content -LiteralPath $File.FullName -Raw | ConvertFrom-Json -Depth 100
    } catch {
        return $null
    }
    $sessionId = [string](Get-ObjectPropertyValue $conversation @('sessionId'))
    if ([string]::IsNullOrWhiteSpace($sessionId)) {
        return $null
    }

    $events = [System.Collections.Generic.List[object]]::new()
    $firstUserMessage = ""
    $title = [string](Get-ObjectPropertyValue $conversation @('title'))
    $startTime = [string](Get-ObjectPropertyValue $conversation @('startTime'))
    $endTime = [string](Get-ObjectPropertyValue $conversation @('endTime'))
    $cwd = ""
    foreach ($message in @($conversation.messages)) {
        $messageType = [string](Get-ObjectPropertyValue $message @('messageType', 'type'))
        $data = Get-ObjectPropertyValue $message @('data')
        $timestamp = [string](Get-ObjectPropertyValue $message @('timestamp'))
        if ($messageType -eq 'sessionInfo') {
            $cwdCandidate = [string](Get-ObjectPropertyValue $data @('cwd'))
            if (-not [string]::IsNullOrWhiteSpace($cwdCandidate)) { $cwd = $cwdCandidate }
            if ([string]::IsNullOrWhiteSpace($title)) {
                $title = [string](Get-ObjectPropertyValue $data @('title'))
            }
            continue
        }
        if ($messageType -eq 'userInput') {
            $text = [string]$data
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                if ([string]::IsNullOrWhiteSpace($firstUserMessage)) { $firstUserMessage = $text }
                $events.Add((New-ReaderEvent `
                    -Kind 'user' `
                    -Timestamp (Convert-ToUtcIsoText $timestamp) `
                    -TimestampLocal (Convert-ToLocalTimeText $timestamp) `
                    -TurnId $sessionId `
                    -Role 'user' `
                    -Summary (Get-ShortText $text 160) `
                    -RawText ($text.TrimEnd()) `
                    -RenderMode 'plain_text'))
            }
            continue
        }
        if ($messageType -eq 'output') {
            $text = [string]$data
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $events.Add((New-ReaderEvent `
                    -Kind 'assistant_final' `
                    -Timestamp (Convert-ToUtcIsoText $timestamp) `
                    -TimestampLocal (Convert-ToLocalTimeText $timestamp) `
                    -TurnId $sessionId `
                    -Role 'assistant' `
                    -Summary (Get-ShortText $text 160) `
                    -RawText ($text.TrimEnd()) `
                    -RenderMode 'deterministic_markdown'))
            }
            continue
        }
    }

    if ($events.Count -eq 0) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = Get-FirstLine $firstUserMessage
    }
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = $File.Name
    }
    if ([string]::IsNullOrWhiteSpace($startTime)) {
        $startTime = $File.CreationTimeUtc.ToString("o")
    }
    if ([string]::IsNullOrWhiteSpace($endTime)) {
        $endTime = $File.LastWriteTimeUtc.ToString("o")
    }

    [pscustomobject]@{
        Id = $sessionId
        Cwd = $cwd
        Title = $title
        Summary = (Get-ShortText $firstUserMessage 220)
        CreatedAt = (Convert-ToUtcIsoText $startTime)
        CreatedLocal = (Convert-ToLocalTimeText $startTime)
        UpdatedAt = (Convert-ToUtcIsoText $endTime)
        UpdatedLocal = (Convert-ToLocalTimeText $endTime)
        Source = "vscode-claude-code-chat"
        ModelProvider = "Claude"
        CliVersion = ""
        UserCount = @($events | Where-Object { $_.kind -eq 'user' }).Count
        AssistantCount = @($events | Where-Object { $_.kind -in @('assistant_commentary','assistant_final') }).Count
        HasImageReference = $false
        Archived = $false
        Path = $File.FullName
        FileUri = (Convert-ToFileUri $File.FullName)
        SizeBytes = $File.Length
        Events = @($events)
    }
}

function Add-ClaudeToolResultEvent {
    param(
        [System.Collections.Generic.List[object]]$Events,
        [AllowNull()]$Part,
        [AllowNull()]$Entry,
        [string]$SessionId
    )
    $toolUseId = [string](Get-ObjectPropertyValue $Part @('tool_use_id', 'toolUseId', 'id'))
    $content = Convert-ClaudeContentPartToText $Part
    $summary = Get-ShortText (('tool_result ' + $toolUseId + ': ' + $content).Trim()) 220
    $Events.Add((New-ReaderEvent `
        -Kind 'tool' `
        -Timestamp (Convert-ToUtcIsoText (Get-ObjectPropertyValue $Entry @('timestamp', 'created_at', 'createdAt'))) `
        -TimestampLocal (Convert-ToLocalTimeText (Get-ObjectPropertyValue $Entry @('timestamp', 'created_at', 'createdAt'))) `
        -TurnId $SessionId `
        -CallId $toolUseId `
        -ToolName 'tool_result' `
        -Status 'result' `
        -Summary $summary `
        -RawText $content `
        -RenderMode 'tool_output' `
        -GroupKey $toolUseId))
}

function Read-ClaudeSession {
    param(
        [System.IO.FileInfo]$File,
        $SessionMetadataMap
    )

    $id = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    $cwd = ""
    $createdAt = ""
    $updatedAt = ""
    $entrypoint = ""
    $title = ""
    $firstUserMessage = ""
    $events = [System.Collections.Generic.List[object]]::new()
    $recognizedClaudeRecordSeen = $false

    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.FileStream]::new(
            $File.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        )
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)

        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            try {
                $entry = $line | ConvertFrom-Json -Depth 100
            } catch {
                continue
            }

            $timestamp = Get-ObjectPropertyValue $entry @('timestamp', 'created_at', 'createdAt')
            if ($timestamp) {
                if ([string]::IsNullOrWhiteSpace($createdAt)) { $createdAt = $timestamp }
                $updatedAt = $timestamp
            }

            $entrySessionId = [string](Get-ObjectPropertyValue $entry @('sessionId', 'session_id', 'conversationId', 'uuid'))
            if (-not [string]::IsNullOrWhiteSpace($entrySessionId)) { $id = $entrySessionId }
            $entryCwd = [string](Get-ObjectPropertyValue $entry @('cwd', 'workingDirectory', 'workspace'))
            if (-not [string]::IsNullOrWhiteSpace($entryCwd)) { $cwd = $entryCwd }
            $entryEntryPoint = [string](Get-ObjectPropertyValue $entry @('entrypoint', 'entryPoint'))
            if (-not [string]::IsNullOrWhiteSpace($entryEntryPoint)) { $entrypoint = $entryEntryPoint }

            $entryType = [string](Get-ObjectPropertyValue $entry @('type'))
            if ($entryType -eq 'custom-title') {
                $recognizedClaudeRecordSeen = $true
                $customTitle = [string](Get-ObjectPropertyValue $entry @('title', 'text', 'summary'))
                if ([string]::IsNullOrWhiteSpace($customTitle)) {
                    $customTitle = Convert-ClaudeContentToText (Get-ObjectPropertyValue $entry @('content')) @('text')
                }
                if (-not [string]::IsNullOrWhiteSpace($customTitle)) {
                    $title = (Get-FirstLine $customTitle)
                }
                continue
            }
            if ($entryType -eq 'queue-operation') {
                $recognizedClaudeRecordSeen = $true
                continue
            }

            $message = Get-ObjectPropertyValue $entry @('message')
            $role = [string](Get-ObjectPropertyValue $message @('role'))
            if ([string]::IsNullOrWhiteSpace($role)) {
                $role = [string](Get-ObjectPropertyValue $entry @('role'))
            }
            if ([string]::IsNullOrWhiteSpace($role) -and $entryType -in @('user', 'assistant', 'system')) {
                $role = $entryType
            }

            $content = Get-ObjectPropertyValue $message @('content')
            if ($null -eq $content) { $content = Get-ObjectPropertyValue $entry @('content', 'text') }

            if ($role -eq 'user') {
                $recognizedClaudeRecordSeen = $true
                $toolResultParts = @($content | Where-Object {
                    $_ -and -not ($_ -is [string]) -and [string](Get-ObjectPropertyValue $_ @('type')) -eq 'tool_result'
                })
                if ($toolResultParts.Count -gt 0) {
                    foreach ($part in $toolResultParts) {
                        Add-ClaudeToolResultEvent -Events $events -Part $part -Entry $entry -SessionId $id
                    }
                    continue
                }

                $messageText = Convert-ClaudeContentToText $content @('text')
                if ([string]::IsNullOrWhiteSpace($messageText) -and $content -is [string]) { $messageText = [string]$content }
                if (-not [string]::IsNullOrWhiteSpace($messageText)) {
                    if ([string]::IsNullOrWhiteSpace($firstUserMessage)) { $firstUserMessage = $messageText }
                    $events.Add((New-ReaderEvent `
                        -Kind 'user' `
                        -Timestamp (Convert-ToUtcIsoText $timestamp) `
                        -TimestampLocal (Convert-ToLocalTimeText $timestamp) `
                        -TurnId $id `
                        -Role 'user' `
                        -Summary (Get-ShortText $messageText 160) `
                        -RawText ($messageText.TrimEnd()) `
                        -RenderMode 'plain_text'))
                }
                continue
            }

            if ($role -eq 'assistant') {
                $recognizedClaudeRecordSeen = $true
                foreach ($part in @($content)) {
                    if ($null -eq $part) { continue }
                    if ($part -is [string]) {
                        $events.Add((New-ReaderEvent `
                            -Kind 'assistant_final' `
                            -Timestamp (Convert-ToUtcIsoText $timestamp) `
                            -TimestampLocal (Convert-ToLocalTimeText $timestamp) `
                            -TurnId $id `
                            -Role 'assistant' `
                            -Summary (Get-ShortText ([string]$part) 160) `
                            -RawText ([string]$part).TrimEnd() `
                            -RenderMode 'deterministic_markdown'))
                        continue
                    }

                    $partType = [string](Get-ObjectPropertyValue $part @('type'))
                    if ($partType -eq 'text') {
                        $text = Convert-ClaudeContentPartToText $part
                        if ([string]::IsNullOrWhiteSpace($text)) { continue }
                        $events.Add((New-ReaderEvent `
                            -Kind 'assistant_final' `
                            -Timestamp (Convert-ToUtcIsoText $timestamp) `
                            -TimestampLocal (Convert-ToLocalTimeText $timestamp) `
                            -TurnId $id `
                            -Role 'assistant' `
                            -Summary (Get-ShortText $text 160) `
                            -RawText ($text.TrimEnd()) `
                            -RenderMode 'deterministic_markdown'))
                        continue
                    }
                    if ($partType -eq 'thinking') {
                        $thinking = Convert-ClaudeContentPartToText $part
                        if ([string]::IsNullOrWhiteSpace($thinking)) { continue }
                        $events.Add((New-ReaderEvent `
                            -Kind 'assistant_commentary' `
                            -Timestamp (Convert-ToUtcIsoText $timestamp) `
                            -TimestampLocal (Convert-ToLocalTimeText $timestamp) `
                            -TurnId $id `
                            -Phase 'thinking' `
                            -Role 'assistant' `
                            -Summary (Get-ShortText $thinking 160) `
                            -RawText ($thinking.TrimEnd()) `
                            -RenderMode 'plain_text'))
                        continue
                    }
                    if ($partType -eq 'tool_use') {
                        $toolName = [string](Get-ObjectPropertyValue $part @('name', 'tool_name', 'toolName'))
                        $toolId = [string](Get-ObjectPropertyValue $part @('id', 'tool_use_id', 'toolUseId'))
                        $input = Get-ObjectPropertyValue $part @('input', 'arguments')
                        $rawInput = Convert-ToCompactJsonText $input
                        $events.Add((New-ReaderEvent `
                            -Kind 'tool' `
                            -Timestamp (Convert-ToUtcIsoText $timestamp) `
                            -TimestampLocal (Convert-ToLocalTimeText $timestamp) `
                            -TurnId $id `
                            -CallId $toolId `
                            -ToolName $toolName `
                            -Status 'requested' `
                            -Summary (Get-ToolSummary $toolName $rawInput) `
                            -RawText $rawInput `
                            -RenderMode 'tool_output' `
                            -GroupKey $toolId))
                        continue
                    }
                    if ($partType -eq 'tool_result') {
                        Add-ClaudeToolResultEvent -Events $events -Part $part -Entry $entry -SessionId $id
                        continue
                    }
                }
                continue
            }

            if ($role -eq 'system' -or $entryType -eq 'system') {
                $recognizedClaudeRecordSeen = $true
                $rawText = Convert-ClaudeContentToText $content @('text')
                if ([string]::IsNullOrWhiteSpace($rawText)) { $rawText = Convert-ToCompactJsonText $entry }
                $events.Add((New-ReaderEvent `
                    -Kind 'system' `
                    -Timestamp (Convert-ToUtcIsoText $timestamp) `
                    -TimestampLocal (Convert-ToLocalTimeText $timestamp) `
                    -TurnId $id `
                    -Summary (Get-ShortText $rawText 160) `
                    -RawText $rawText `
                    -RenderMode 'system_meta'))
            }
        }
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
    }

    $metadata = if ($SessionMetadataMap -and $SessionMetadataMap.ContainsKey($id)) { $SessionMetadataMap[$id] } else { $null }
    if ($metadata) {
        if ([string]::IsNullOrWhiteSpace($entrypoint)) {
            $entrypoint = [string](Get-ObjectPropertyValue $metadata @('entrypoint', 'entryPoint'))
        }
        if ([string]::IsNullOrWhiteSpace($cwd)) {
            $cwd = [string](Get-ObjectPropertyValue $metadata @('cwd', 'workingDirectory', 'workspace'))
        }
        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = [string](Get-ObjectPropertyValue $metadata @('title', 'summary'))
        }
    }

    if ([string]::IsNullOrWhiteSpace($createdAt)) {
        $createdAt = $File.CreationTimeUtc.ToString("o")
    }
    if ([string]::IsNullOrWhiteSpace($updatedAt)) {
        $updatedAt = $File.LastWriteTimeUtc.ToString("o")
    }
    if ([string]::IsNullOrWhiteSpace($entrypoint)) {
        $entrypoint = "unknown"
    }
    if (-not $recognizedClaudeRecordSeen) {
        return $null
    }

    $userEvents = @($events | Where-Object { $_.kind -eq 'user' })
    $assistantEvents = @($events | Where-Object { $_.kind -in @('assistant_commentary','assistant_final') })
    if ([string]::IsNullOrWhiteSpace($firstUserMessage) -and $userEvents.Count -gt 0) {
        $firstUserMessage = [string]$userEvents[0].rawText
    }
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = Get-FirstLine $firstUserMessage
    }
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = $File.Name
    }
    $hasImageReference = @($userEvents | Where-Object { [string]$_.rawText -match '\.(png|jpg|jpeg|gif|webp)\b' }).Count -gt 0

    [pscustomobject]@{
        Id = $id
        Cwd = $cwd
        Title = $title
        Summary = (Get-ShortText $firstUserMessage 220)
        CreatedAt = (Convert-ToUtcIsoText $createdAt)
        CreatedLocal = (Convert-ToLocalTimeText $createdAt)
        UpdatedAt = (Convert-ToUtcIsoText $updatedAt)
        UpdatedLocal = (Convert-ToLocalTimeText $updatedAt)
        Source = $entrypoint
        ModelProvider = "Claude"
        CliVersion = ""
        UserCount = $userEvents.Count
        AssistantCount = $assistantEvents.Count
        HasImageReference = $hasImageReference
        Archived = $false
        Path = $File.FullName
        FileUri = (Convert-ToFileUri $File.FullName)
        SizeBytes = $File.Length
        Events = @($events)
    }
}

function Read-CodexSession {
    param([System.IO.FileInfo]$File)

    $fileStem = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    $id = $fileStem -replace '^rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-', ''
    $idLockedToFile = $id -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $cwd = "(未知工作目录)"
    $createdAt = ""
    $updatedAt = ""
    $source = ""
    $modelProvider = ""
    $cliVersion = ""
    $firstUserMessage = ""
    $userCount = 0
    $assistantCount = 0
    $hasImageReference = $false
    $events = [System.Collections.Generic.List[object]]::new()
    $pendingTools = @{}
    $sessionMetaSeen = $false
    $recognizedCodexRecordSeen = $false
    $currentTurnId = ""
    $effectiveTurnOrder = [System.Collections.Generic.List[string]]::new()

    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.FileStream]::new(
            $File.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        )
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)

        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            try {
                $entry = $line | ConvertFrom-Json -Depth 100
            } catch {
                continue
            }

            if ($entry.timestamp) {
                $updatedAt = $entry.timestamp
            }

            if ($entry.type -eq "session_meta") {
                $recognizedCodexRecordSeen = $true
                if (-not $sessionMetaSeen) {
                    if (-not $idLockedToFile -and $entry.payload.id) { $id = [string]$entry.payload.id }
                    if ($entry.payload.timestamp) { $createdAt = $entry.payload.timestamp }
                    if ($entry.payload.cwd) { $cwd = [string]$entry.payload.cwd }
                    if ($entry.payload.source) { $source = [string]$entry.payload.source }
                    if ($entry.payload.model_provider) { $modelProvider = [string]$entry.payload.model_provider }
                    if ($entry.payload.cli_version) { $cliVersion = [string]$entry.payload.cli_version }
                    $sessionMetaSeen = $true
                }
                continue
            }

            if ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'thread_rolled_back') {
                $recognizedCodexRecordSeen = $true
                $turnsToRemove = 0
                if ($null -ne $entry.payload.num_turns) {
                    $turnsToRemove = [int]$entry.payload.num_turns
                }
                $rolledBackTurnIds = [System.Collections.Generic.List[string]]::new()
                while ($turnsToRemove -gt 0 -and $effectiveTurnOrder.Count -gt 0) {
                    $lastIndex = $effectiveTurnOrder.Count - 1
                    $turnIdToRemove = [string]$effectiveTurnOrder[$lastIndex]
                    $effectiveTurnOrder.RemoveAt($lastIndex)
                    if (-not [string]::IsNullOrWhiteSpace($turnIdToRemove)) {
                        $rolledBackTurnIds.Add($turnIdToRemove)
                    }
                    $turnsToRemove--
                }
                if ($rolledBackTurnIds.Count -gt 0) {
                    for ($eventIndex = $events.Count - 1; $eventIndex -ge 0; $eventIndex--) {
                        if ($rolledBackTurnIds -contains [string]$events[$eventIndex].turnId) {
                            $events.RemoveAt($eventIndex)
                        }
                    }
                }
                $currentTurnId = if ($effectiveTurnOrder.Count -gt 0) { [string]$effectiveTurnOrder[$effectiveTurnOrder.Count - 1] } else { "" }
                continue
            }

            $entryTurnId = if ($entry.turn_id) { [string]$entry.turn_id } elseif ($entry.payload.turn_id) { [string]$entry.payload.turn_id } else { $currentTurnId }

            if ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'task_started') {
                $recognizedCodexRecordSeen = $true
                if (-not [string]::IsNullOrWhiteSpace($entryTurnId)) {
                    $currentTurnId = $entryTurnId
                    if ($effectiveTurnOrder.Count -eq 0 -or [string]$effectiveTurnOrder[$effectiveTurnOrder.Count - 1] -ne $entryTurnId) {
                        $effectiveTurnOrder.Add($entryTurnId)
                    }
                }
            }

            if ($entry.type -eq 'response_item' -and $entry.payload.type -eq 'function_call') {
                $recognizedCodexRecordSeen = $true
                $pendingTools[[string]$entry.payload.call_id] = [ordered]@{
                    callId = [string]$entry.payload.call_id
                    toolName = [string]$entry.payload.name
                    summary = Get-ToolSummary ([string]$entry.payload.name) ([string]$entry.payload.arguments)
                }
                continue
            }

            if ($entry.type -eq 'response_item' -and $entry.payload.type -eq 'message' -and $entry.payload.role -eq 'user') {
                $recognizedCodexRecordSeen = $true
                $message = Get-CodexMessageContentText $entry.payload.content
                $images = @(Get-CodexMessageContentImages $entry.payload.content)
                if ([string]::IsNullOrWhiteSpace($message) -and $images.Count -gt 0) {
                    $message = "[图片]"
                }
                if (-not [string]::IsNullOrWhiteSpace($message) -or $images.Count -gt 0) {
                    $messageText = $message.Trim()
                    if (Test-IsInjectedCodexContextMessage -RawText $messageText -HasImages ($images.Count -gt 0)) {
                        continue
                    }
                    $messageTimestamp = Convert-ToUtcIsoText $entry.timestamp
                    if (Test-IsDuplicateAdjacentUserEvent -Events $events -Timestamp $messageTimestamp -RawText $messageText) {
                        continue
                    }
                    $events.Add((New-ReaderEvent `
                        -Kind 'user' `
                        -Timestamp $messageTimestamp `
                        -TimestampLocal (Convert-ToLocalTimeText $entry.timestamp) `
                        -TurnId $entryTurnId `
                        -Role 'user' `
                        -Summary (Get-ShortText $message 160) `
                        -RawText $messageText `
                        -RenderMode 'plain_text' `
                        -Images $images))
                }
                continue
            }

            if ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'agent_message') {
                $recognizedCodexRecordSeen = $true
                $phase = [string]$entry.payload.phase
                $message = [string]$entry.payload.message
                $kind = if ($phase -eq 'commentary') { 'assistant_commentary' } else { 'assistant_final' }
                $renderMode = if ($kind -eq 'assistant_final') { 'deterministic_markdown' } else { 'plain_text' }
                $events.Add((New-ReaderEvent `
                    -Kind $kind `
                    -Timestamp (Convert-ToUtcIsoText $entry.timestamp) `
                    -TimestampLocal (Convert-ToLocalTimeText $entry.timestamp) `
                    -TurnId $entryTurnId `
                    -Phase $phase `
                    -Role 'assistant' `
                    -Summary (Get-ShortText $message 160) `
                    -RawText ($message.TrimEnd()) `
                    -RenderMode $renderMode `
                    -GroupKey ([string]$entry.turn_id)))
                continue
            }

            if ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'user_message') {
                $recognizedCodexRecordSeen = $true
                $message = [string]$entry.payload.message
                $messageText = $message.Trim()
                if (Test-IsInjectedCodexContextMessage -RawText $messageText) {
                    continue
                }
                $messageTimestamp = Convert-ToUtcIsoText $entry.timestamp
                if (Test-IsDuplicateAdjacentUserEvent -Events $events -Timestamp $messageTimestamp -RawText $messageText) {
                    continue
                }
                $events.Add((New-ReaderEvent `
                    -Kind 'user' `
                    -Timestamp $messageTimestamp `
                    -TimestampLocal (Convert-ToLocalTimeText $entry.timestamp) `
                    -TurnId $entryTurnId `
                    -Role 'user' `
                    -Summary (Get-ShortText $message 160) `
                    -RawText $messageText `
                    -RenderMode 'plain_text'))
                continue
            }

            if ($entry.type -eq 'event_msg' -and $entry.payload.type -in @('exec_command_end', 'function_call_output', 'mcp_tool_call_end', 'patch_apply_end')) {
                $recognizedCodexRecordSeen = $true
                $tool = $pendingTools[[string]$entry.payload.call_id]
                $toolName = if ($null -ne $tool -and $tool.toolName) { [string]$tool.toolName } else { [string]$entry.payload.name }
                $resultSummary = Get-CommandResultSummary $entry.payload
                $toolSummary = if ($null -ne $tool -and -not [string]::IsNullOrWhiteSpace([string]$tool.summary)) {
                    Get-ShortText ($tool.summary + ' | ' + $resultSummary) 220
                } else {
                    $resultSummary
                }
                $events.Add((New-ReaderEvent `
                    -Kind 'tool' `
                    -Timestamp (Convert-ToUtcIsoText $entry.timestamp) `
                    -TimestampLocal (Convert-ToLocalTimeText $entry.timestamp) `
                    -TurnId $entryTurnId `
                    -CallId ([string]$entry.payload.call_id) `
                    -ToolName $toolName `
                    -Status ([string]$entry.payload.status) `
                    -Summary $toolSummary `
                    -RawText ([string]$entry.payload.aggregated_output) `
                    -RenderMode 'tool_output' `
                    -GroupKey ([string]$entry.payload.call_id)))
                continue
            }

            if ($entry.type -eq 'event_msg' -and $entry.payload.type -in @('task_started', 'task_complete', 'token_count')) {
                $recognizedCodexRecordSeen = $true
                $events.Add((New-ReaderEvent `
                    -Kind 'system' `
                    -Timestamp (Convert-ToUtcIsoText $entry.timestamp) `
                    -TimestampLocal (Convert-ToLocalTimeText $entry.timestamp) `
                    -TurnId $entryTurnId `
                    -Summary ([string]$entry.payload.type) `
                    -RawText ($entry.payload | ConvertTo-Json -Depth 20 -Compress) `
                    -RenderMode 'system_meta'))
                if ($entry.payload.type -eq 'task_complete' -and -not [string]::IsNullOrWhiteSpace($entryTurnId) -and $entryTurnId -eq $currentTurnId) {
                    $currentTurnId = ""
                }
                continue
            }
        }
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
    }

    if ([string]::IsNullOrWhiteSpace($createdAt)) {
        $createdAt = $File.CreationTimeUtc.ToString("o")
    }
    if ([string]::IsNullOrWhiteSpace($updatedAt)) {
        $updatedAt = $File.LastWriteTimeUtc.ToString("o")
    }
    if (-not $recognizedCodexRecordSeen) {
        return $null
    }

    $userEvents = @($events | Where-Object { $_.kind -eq 'user' })
    $assistantEvents = @($events | Where-Object { $_.kind -in @('assistant_commentary','assistant_final') })
    if ($userEvents.Count -eq 0 -and $assistantEvents.Count -eq 0) {
        return New-SkippedReaderSession 'empty-after-context-filter'
    }
    $userCount = $userEvents.Count
    $assistantCount = $assistantEvents.Count
    $firstUserMessage = if ($userEvents.Count -gt 0) { [string]$userEvents[0].rawText } else { "" }
    $hasImageReference = @($userEvents | Where-Object {
        ([string]$_.rawText -match '\.(png|jpg|jpeg|gif|webp)\b') -or
        (Test-ReaderEventHasImages $_)
    }).Count -gt 0

    $title = Get-FirstLine $firstUserMessage
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = $File.Name
    }

    [pscustomobject]@{
        Id = $id
        Cwd = $cwd
        Title = $title
        Summary = (Get-ShortText $firstUserMessage 220)
        CreatedAt = (Convert-ToUtcIsoText $createdAt)
        CreatedLocal = (Convert-ToLocalTimeText $createdAt)
        UpdatedAt = (Convert-ToUtcIsoText $updatedAt)
        UpdatedLocal = (Convert-ToLocalTimeText $updatedAt)
        Source = $source
        ModelProvider = $modelProvider
        CliVersion = $cliVersion
        UserCount = $userCount
        AssistantCount = $assistantCount
        HasImageReference = $hasImageReference
        Archived = (Test-IsArchivedSessionPath $File.FullName)
        Path = $File.FullName
        FileUri = (Convert-ToFileUri $File.FullName)
        SizeBytes = $File.Length
        Events = @($events)
    }
}

$generatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$outputDir = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Force $outputDir | Out-Null
$SourceId = Get-SafeSourceId $SourceId
$SourceType = if ([string]::IsNullOrWhiteSpace($SourceType)) { "local-codex" } else { [string]$SourceType }
if ($SourceType -ne 'local-codex' -and $SourceType -ne 'external-codex-jsonl' -and $SourceType -ne 'local-claude') {
    throw "Unsupported SourceType: $SourceType"
}
if ($SourceType -eq 'local-codex') {
    $SourceId = 'local-codex'
} elseif ($SourceType -eq 'local-claude') {
    $SourceId = 'local-claude'
}
if ([string]::IsNullOrWhiteSpace($SourceLabel)) {
    $SourceLabel = if ($SourceType -eq 'local-codex') {
        '本机 Codex'
    } elseif ($SourceType -eq 'local-claude') {
        '本机 Claude'
    } elseif (-not [string]::IsNullOrWhiteSpace($ExternalSourcePath)) {
        Split-Path -Leaf $ExternalSourcePath
    } else {
        $SourceId
    }
}
$sessionRoot = Join-Path $CodexHome "sessions"
$archiveRoot = Join-Path $CodexHome "archived_sessions"
$claudeProjectsRoot = Join-Path $ClaudeHome "projects"
$claudeSessionsRoot = Join-Path $ClaudeHome "sessions"
$resolvedExternalSourcePath = ""
if ($SourceType -eq 'external-codex-jsonl') {
    if ([string]::IsNullOrWhiteSpace($ExternalSourcePath)) {
        throw "ExternalSourcePath is required when SourceType is external-codex-jsonl."
    }
    $resolvedExternalSourcePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ExternalSourcePath)
}
$sourceInfo = if ($SourceType -eq 'local-codex') {
    [ordered]@{
        id = $SourceId
        label = $SourceLabel
        type = $SourceType
        roots = @($sessionRoot, $archiveRoot)
    }
} elseif ($SourceType -eq 'local-claude') {
    [ordered]@{
        id = $SourceId
        label = $SourceLabel
        type = $SourceType
        root = $claudeProjectsRoot
        sessionsRoot = $claudeSessionsRoot
    }
} else {
    [ordered]@{
        id = $SourceId
        label = $SourceLabel
        type = $SourceType
        root = $resolvedExternalSourcePath
    }
}
if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $DataRoot = Join-Path (Split-Path -Parent $PSScriptRoot) '运行数据'
}
$resolvedDataRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DataRoot)
New-Item -ItemType Directory -Force $resolvedDataRoot | Out-Null
$useSourceDataLayout = $true
$effectiveDataRoot = if ($useSourceDataLayout) {
    Join-Path (Join-Path $resolvedDataRoot 'CodexChatIndex.sources') $SourceId
} else {
    $resolvedDataRoot
}
New-Item -ItemType Directory -Force $effectiveDataRoot | Out-Null
if (-not $outputPathWasProvided) {
    $sharedRoot = Split-Path -Parent $PSScriptRoot
    New-Item -ItemType Directory -Force (Join-Path $sharedRoot '外部聊天记录') | Out-Null
}
$dataOutput = if (-not $useSourceDataLayout -and $outputPathWasProvided) {
    [System.IO.Path]::ChangeExtension($resolvedOutput, ".data.json")
} else {
    Join-Path $effectiveDataRoot 'CodexChatIndex.data.json'
}
$detailRoot = Join-Path $effectiveDataRoot 'CodexChatIndex.sessions'
New-Item -ItemType Directory -Force $detailRoot | Out-Null
$cacheOutput = Join-Path $effectiveDataRoot 'CodexChatIndex.cache.json'
$searchOutput = if (-not $useSourceDataLayout -and $outputPathWasProvided) {
    [System.IO.Path]::ChangeExtension($resolvedOutput, ".search.json")
} else {
    Join-Path $effectiveDataRoot 'CodexChatIndex.search.json'
}
Update-SourceManifest -RuntimeDataRoot $resolvedDataRoot -Source $sourceInfo
$builderVersion = "V0.25"
$indexRelativePath = Convert-ToRelativeWebPath -FromDirectory $outputDir -ToPath $dataOutput
if ($indexRelativePath -notmatch '^(\./|\.\./|/)') {
    $indexRelativePath = './' + $indexRelativePath
}
$indexUrlForScript = Convert-ToJavaScriptSingleQuotedContent $indexRelativePath
$detailRelativeRoot = (Convert-ToRelativeWebPath -FromDirectory $outputDir -ToPath $detailRoot).TrimEnd('/')
$expectedDetailPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

$cacheRead = if ($RefreshMode -eq 'Full') {
    [pscustomobject]@{
        Exists = $false
        Parsed = $false
        Value = $null
        Error = "skipped"
    }
} else {
    Read-JsonFileDetailed $cacheOutput
}
$cacheData = $cacheRead.Value
$cacheMap = @{}
$cacheNotice = ""
if ($RefreshMode -ne 'Full') {
    if (-not $cacheRead.Exists) {
        $cacheNotice = "共享缓存不存在，已自动执行全量重建。"
    } elseif (-not $cacheRead.Parsed) {
        $cacheNotice = "共享缓存损坏，已自动执行全量重建。"
    } elseif ($null -eq $cacheData -or $cacheData.cacheVersion -ne 3 -or [string]$cacheData.builderVersion -ne $builderVersion) {
        $cacheNotice = "共享缓存版本不兼容，已自动执行全量重建。"
    } elseif (-not $cacheData.files) {
        $cacheNotice = "共享缓存为空，已自动执行全量重建。"
    }
}
if ([string]::IsNullOrWhiteSpace($cacheNotice) -and $null -ne $cacheData -and $cacheData.files) {
    foreach ($record in @($cacheData.files)) {
        $recordPath = Get-NormalizedFilePath ([string]$record.path)
        if (-not [string]::IsNullOrWhiteSpace($recordPath)) {
            $cacheMap[$recordPath] = $record
        }
    }
}

$effectiveRefreshMode = $RefreshMode
if ($RefreshMode -ne 'Full' -and $cacheMap.Count -eq 0) {
    $effectiveRefreshMode = 'Full'
}

$currentPath = ""
if ($effectiveRefreshMode -eq 'Current') {
    $currentPath = Get-NormalizedFilePath $CurrentSessionPath
    if ([string]::IsNullOrWhiteSpace($currentPath)) {
        throw "CurrentSessionPath is required when RefreshMode is Current."
    }
    if ($SourceType -eq 'external-codex-jsonl' -and -not (Test-PathWithinDirectory -Path $currentPath -Directory $resolvedExternalSourcePath)) {
        throw "Current session file is outside the selected external source: $currentPath"
    }
    if ($SourceType -eq 'local-claude' -and -not (Test-PathWithinDirectory -Path $currentPath -Directory $claudeProjectsRoot)) {
        throw "Current session file is outside the local Claude projects root: $currentPath"
    }
}

$files = @()
$fileMap = @{}
$scannedCount = 0
$effectiveClaudeScanRoots = @()
$claudeSessionMetadataMap = if ($SourceType -eq 'local-claude') {
    Read-ClaudeSessionMetadataMap -ClaudeSessionsRoot $claudeSessionsRoot
} else {
    @{}
}
if ($effectiveRefreshMode -eq 'Current') {
    if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) {
        throw "Current session file was not found: $currentPath"
    }
    $currentFileItem = Get-Item -LiteralPath $currentPath
    $files = @($currentFileItem)
    $fileMap[$currentPath] = $currentFileItem
    $scannedCount = 1
} else {
    if ($SourceType -eq 'external-codex-jsonl') {
        if (Test-Path -LiteralPath $resolvedExternalSourcePath -PathType Container) {
            $files += Get-ChildItem -LiteralPath $resolvedExternalSourcePath -Recurse -File -Filter "*.jsonl"
        }
    } elseif ($SourceType -eq 'local-claude') {
        $effectiveClaudeScanRoots = Get-ClaudeExtraSourceRoots -ClaudeHome $ClaudeHome -ClaudeScanRoots $ClaudeScanRoots
        $claudeCandidates = [System.Collections.Generic.Dictionary[string, System.IO.FileInfo]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($claudeRoot in $effectiveClaudeScanRoots) {
            if (-not (Test-Path -LiteralPath $claudeRoot -PathType Container)) { continue }
            foreach ($candidate in @(Get-ChildItem -LiteralPath $claudeRoot -Recurse -File -Filter "*.jsonl" -ErrorAction SilentlyContinue)) {
                $candidatePath = Get-NormalizedFilePath $candidate.FullName
                if (-not [string]::IsNullOrWhiteSpace($candidatePath)) {
                    $claudeCandidates[$candidatePath] = $candidate
                }
            }
            foreach ($candidate in @(Get-ChildItem -LiteralPath $claudeRoot -Recurse -File -Filter "*.json" -ErrorAction SilentlyContinue)) {
                $candidatePath = Get-NormalizedFilePath $candidate.FullName
                if (-not [string]::IsNullOrWhiteSpace($candidatePath)) {
                    $claudeCandidates[$candidatePath] = $candidate
                }
            }
        }
        $files += @($claudeCandidates.Values | Where-Object {
            $_.FullName -match '\\projects\\.+\.jsonl$' -or
            $_.FullName -match '\\local-agent-mode-sessions\\.+\\\.claude\\projects\\.+\.jsonl$' -or
            $_.FullName -match 'AndrePimenta\.claude-code-chat\\conversations\\.+\.json$'
        })
    } else {
        if (Test-Path -LiteralPath $sessionRoot) {
            $files += Get-ChildItem -LiteralPath $sessionRoot -Recurse -File -Filter "*.jsonl"
        }
        if (Test-Path -LiteralPath $archiveRoot) {
            $files += Get-ChildItem -LiteralPath $archiveRoot -Recurse -File -Filter "*.jsonl"
        }
    }
    $files = @($files)
    foreach ($file in $files) {
        $fileMap[(Get-NormalizedFilePath $file.FullName)] = $file
    }
    $scannedCount = $files.Count
}

$sourceSignature = New-SourceSignature `
    -Files $files `
    -SourceId $SourceId `
    -SourceType $SourceType `
    -BuilderVersion $builderVersion `
    -ExternalSourcePath $resolvedExternalSourcePath `
    -ClaudeSessionsRoot $claudeSessionsRoot `
    -ClaudeScanRoots $effectiveClaudeScanRoots
$sourceSignatureText = Convert-SourceSignatureToText $sourceSignature
$cachedSourceSignatureText = if ($null -ne $cacheData -and ($cacheData.PSObject.Properties.Name -contains 'sourceSignature')) {
    Convert-SourceSignatureToText $cacheData.sourceSignature
} else {
    ""
}

if (
    $RefreshMode -eq 'Incremental' -and
    $effectiveRefreshMode -eq 'Incremental' -and
    [string]::IsNullOrWhiteSpace($cacheNotice) -and
    -not [string]::IsNullOrWhiteSpace($sourceSignatureText) -and
    $sourceSignatureText -eq $cachedSourceSignatureText -and
    (Test-BuildOutputsComplete -HtmlPath $resolvedOutput -DataPath $dataOutput -SearchPath $searchOutput -CachePath $cacheOutput) -and
    (Test-CachedDetailFilesComplete -CacheData $cacheData -DetailRoot $detailRoot)
) {
    $existingData = Read-JsonFileDetailed $dataOutput
    $existingAppData = if ($existingData.Parsed -and $existingData.Value) { $existingData.Value } else { $null }
    $buildStopwatch.Stop()
    $summary = [pscustomobject]@{
        Mode = $effectiveRefreshMode
        SourceId = $SourceId
        SourceLabel = $SourceLabel
        SourceType = $SourceType
        OutputPath = $resolvedOutput
        DataPath = $dataOutput
        SearchPath = $searchOutput
        CachePath = $cacheOutput
        DetailRoot = $detailRoot
        ScannedCount = $scannedCount
        ParsedCount = 0
        FailedCount = 0
        ReusedCount = $scannedCount
        DeletedCount = 0
        ElapsedMs = [int][Math]::Round($buildStopwatch.Elapsed.TotalMilliseconds)
        Sessions = if ($existingAppData) { [int]$existingAppData.totalSessions } else { 0 }
        Workspaces = if ($existingAppData) { [int]$existingAppData.totalWorkspaces } else { 0 }
        Archived = if ($existingAppData) { [int]$existingAppData.archived } else { 0 }
        ImageReferences = if ($existingAppData) { [int]$existingAppData.imageReferences } else { 0 }
        Notice = "未发现新增或修改记录，已跳过重写。"
        NoChange = $true
        SkippedWrite = $true
    }

    if ($JsonSummary) {
        $summary | ConvertTo-Json -Depth 20 -Compress
    } else {
        $summary
    }
    return
}

$sessionsList = [System.Collections.Generic.List[object]]::new()
$parsedCount = 0
$reusedCount = 0
$deletedCount = 0
$failedCount = 0

if ($effectiveRefreshMode -eq 'Full') {
    foreach ($file in $files) {
        $session = if ($SourceType -eq 'local-claude') {
            if ($file.Extension -ieq '.json') {
                $conversationSession = Read-ClaudeCodeChatConversation -File $file
                if ($null -ne $conversationSession) { $conversationSession } else { Read-ClaudeSession -File $file -SessionMetadataMap $claudeSessionMetadataMap }
            } else {
                Read-ClaudeSession -File $file -SessionMetadataMap $claudeSessionMetadataMap
            }
        } else {
            Read-CodexSession -File $file
        }
        if (Test-IsSkippedReaderSession $session) {
            continue
        }
        if ($null -eq $session) {
            $failedCount++
            continue
        }
        $detailFileName = Get-SessionDetailFileName $session
        $sessionsList.Add((Add-SessionRuntimeFields -Session $session -File $file -DetailFileName $detailFileName -Cached $false -SourceId $SourceId))
        $parsedCount++
    }
} elseif ($effectiveRefreshMode -eq 'Incremental') {
    foreach ($file in $files) {
        $pathKey = Get-NormalizedFilePath $file.FullName
        $cachedRecord = $cacheMap[$pathKey]
        if (Test-CacheRecordFresh -Record $cachedRecord -File $file -DetailRoot $detailRoot) {
            $cachedSession = New-SessionFromCacheRecord $cachedRecord
            $sessionsList.Add($cachedSession)
            $reusedCount++
            continue
        }

        $session = if ($SourceType -eq 'local-claude') {
            if ($file.Extension -ieq '.json') {
                $conversationSession = Read-ClaudeCodeChatConversation -File $file
                if ($null -ne $conversationSession) { $conversationSession } else { Read-ClaudeSession -File $file -SessionMetadataMap $claudeSessionMetadataMap }
            } else {
                Read-ClaudeSession -File $file -SessionMetadataMap $claudeSessionMetadataMap
            }
        } else {
            Read-CodexSession -File $file
        }
        if (Test-IsSkippedReaderSession $session) {
            continue
        }
        if ($null -eq $session) {
            $failedCount++
            continue
        }
        $detailFileName = Get-SessionDetailFileName $session
        $sessionsList.Add((Add-SessionRuntimeFields -Session $session -File $file -DetailFileName $detailFileName -Cached $false -SourceId $SourceId))
        $parsedCount++
    }

    foreach ($cachedPath in $cacheMap.Keys) {
        if (-not $fileMap.ContainsKey($cachedPath)) {
            $deletedCount++
        }
    }
} else {
    foreach ($cachedPath in $cacheMap.Keys) {
        if ($cachedPath -eq $currentPath) { continue }
        $cachedRecord = $cacheMap[$cachedPath]
        $detailFileName = [string]$cachedRecord.detailFileName
        if (-not [string]::IsNullOrWhiteSpace($detailFileName) -and (Test-Path -LiteralPath (Join-Path $detailRoot $detailFileName) -PathType Leaf)) {
            $sessionsList.Add((New-SessionFromCacheRecord $cachedRecord))
            $reusedCount++
            continue
        }
        if (Test-Path -LiteralPath $cachedPath -PathType Leaf) {
            $repairFile = Get-Item -LiteralPath $cachedPath
            $session = if ($SourceType -eq 'local-claude') {
                if ($repairFile.Extension -ieq '.json') {
                    $conversationSession = Read-ClaudeCodeChatConversation -File $repairFile
                    if ($null -ne $conversationSession) { $conversationSession } else { Read-ClaudeSession -File $repairFile -SessionMetadataMap $claudeSessionMetadataMap }
                } else {
                    Read-ClaudeSession -File $repairFile -SessionMetadataMap $claudeSessionMetadataMap
                }
            } else {
                Read-CodexSession -File $repairFile
            }
            if (Test-IsSkippedReaderSession $session) {
                continue
            }
            if ($null -eq $session) {
                $failedCount++
                continue
            }
            $repairDetailFileName = Get-SessionDetailFileName $session
            $sessionsList.Add((Add-SessionRuntimeFields -Session $session -File $repairFile -DetailFileName $repairDetailFileName -Cached $false -SourceId $SourceId))
            $parsedCount++
            $scannedCount++
            continue
        }
        $sessionsList.Add((New-SessionFromCacheRecord $cachedRecord))
        $reusedCount++
    }

    $currentFile = $fileMap[$currentPath]
    $session = if ($SourceType -eq 'local-claude') {
        if ($currentFile.Extension -ieq '.json') {
            $conversationSession = Read-ClaudeCodeChatConversation -File $currentFile
            if ($null -ne $conversationSession) { $conversationSession } else { Read-ClaudeSession -File $currentFile -SessionMetadataMap $claudeSessionMetadataMap }
        } else {
            Read-ClaudeSession -File $currentFile -SessionMetadataMap $claudeSessionMetadataMap
        }
    } else {
        Read-CodexSession -File $currentFile
    }
    if (Test-IsSkippedReaderSession $session) {
        # The selected file only contains injected context after filtering.
    } elseif ($null -eq $session) {
        $failedCount++
    } else {
        $detailFileName = Get-SessionDetailFileName $session
        $sessionsList.Add((Add-SessionRuntimeFields -Session $session -File $currentFile -DetailFileName $detailFileName -Cached $false -SourceId $SourceId))
        $parsedCount++
    }
}

$sessions = @($sessionsList | Sort-Object Cwd, @{ Expression = "UpdatedAt"; Descending = $true })
$groups = @($sessions | Group-Object Cwd | Sort-Object Name)
$totalSessions = $sessions.Count
$totalWorkspaces = $groups.Count
$archivedCount = @($sessions | Where-Object Archived).Count
$imageRefCount = @($sessions | Where-Object HasImageReference).Count

$workspaceData = foreach ($group in $groups) {
    $cwd = [string]$group.Name
    $sessionsInGroup = foreach ($session in ($group.Group | Sort-Object UpdatedAt -Descending)) {
        $detailFileName = if (-not [string]::IsNullOrWhiteSpace([string]$session.DetailFileName)) { [string]$session.DetailFileName } else { Get-SessionDetailFileName $session }
        $detailRelativePath = ($detailRelativeRoot + '/' + $detailFileName)
        $detailFullPath = Join-Path $detailRoot $detailFileName
        [void]$expectedDetailPaths.Add([System.IO.Path]::GetFullPath($detailFullPath))

        if (-not [bool]$session.Cached) {
            $detailPayload = [ordered]@{
                id = $session.Id
                sourceId = if ([string]::IsNullOrWhiteSpace([string]$session.SourceId)) { $SourceId } else { [string]$session.SourceId }
                title = $session.Title
                path = $session.Path
                cwd = $session.Cwd
                fileUri = $session.FileUri
                createdLocal = $session.CreatedLocal
                updatedLocal = $session.UpdatedLocal
                userCount = $session.UserCount
                assistantCount = $session.AssistantCount
                events = @($session.Events)
            }

            Write-Utf8FileAtomic -Path $detailFullPath -Value ($detailPayload | ConvertTo-Json -Depth 100)
        }

        [ordered]@{
            key = $session.Path
            id = $session.Id
            sourceId = if ([string]::IsNullOrWhiteSpace([string]$session.SourceId)) { $SourceId } else { [string]$session.SourceId }
            title = $session.Title
            summary = $session.Summary
            cwd = $session.Cwd
            createdAt = $session.CreatedAt
            createdLocal = $session.CreatedLocal
            updatedAt = $session.UpdatedAt
            updatedLocal = $session.UpdatedLocal
            userCount = $session.UserCount
            assistantCount = $session.AssistantCount
            messageCount = ($session.UserCount + $session.AssistantCount)
            archived = $session.Archived
            hasImageReference = $session.HasImageReference
            source = $session.Source
            modelProvider = $session.ModelProvider
            path = $session.Path
            fileUri = $session.FileUri
            detailHref = $detailRelativePath
        }
    }

    [ordered]@{
        id = "ws-" + ([System.Guid]::NewGuid().ToString("N"))
        cwd = $cwd
        count = $group.Count
        activeCount = @($group.Group | Where-Object { -not $_.Archived }).Count
        archivedCount = @($group.Group | Where-Object Archived).Count
        latestUpdatedAt = (($group.Group | Sort-Object UpdatedAt -Descending | Select-Object -First 1).UpdatedAt)
        latestUpdatedLocal = (($group.Group | Sort-Object UpdatedAt -Descending | Select-Object -First 1).UpdatedLocal)
        sessions = @($sessionsInGroup)
    }
}

$appData = [ordered]@{
    generatedAt = $generatedAt
    source = $sourceInfo
    totalSessions = $totalSessions
    totalWorkspaces = $totalWorkspaces
    archived = $archivedCount
    imageReferences = $imageRefCount
    workspaces = @($workspaceData)
}

$searchPayload = [ordered]@{
    version = 1
    generatedAt = $generatedAt
    sessions = @($sessions | ForEach-Object {
        [ordered]@{
            key = [string]$_.Path
            id = [string]$_.Id
            sourceId = if ([string]::IsNullOrWhiteSpace([string]$_.SourceId)) { $SourceId } else { [string]$_.SourceId }
            cwd = [string]$_.Cwd
            title = [string]$_.Title
            path = [string]$_.Path
            searchText = if ($_.PSObject.Properties.Name -contains 'SearchText') { [string]$_.SearchText } else { Get-SessionSearchText $_ }
        }
    })
}

$cachePayload = [ordered]@{
    cacheVersion = 3
    builderVersion = $builderVersion
    generatedAt = $generatedAt
    sourceSignature = $sourceSignature
    files = @($sessions | ForEach-Object { New-CacheRecordFromSession $_ })
}

Get-ChildItem -LiteralPath $detailRoot -File -Filter '*.json' | ForEach-Object {
    $existingPath = [System.IO.Path]::GetFullPath($_.FullName)
    if (-not $expectedDetailPaths.Contains($existingPath)) {
        Remove-Item -LiteralPath $_.FullName -Force
    }
}

$json = $appData | ConvertTo-Json -Depth 100 -Compress
$json = $json -replace '</script', '<\/script'

$templatePath = Join-Path $PSScriptRoot 'templates\CodexChatIndex.template.html'
$html = Render-HtmlTemplate -TemplatePath $templatePath -Values ([ordered]@{
    BUILDER_VERSION = [string]$builderVersion
    INDEX_URL = [string]$indexUrlForScript
    TOTAL_SESSIONS = [string]$totalSessions
    TOTAL_WORKSPACES = [string]$totalWorkspaces
    ARCHIVED_COUNT = [string]$archivedCount
    IMAGE_REF_COUNT = [string]$imageRefCount
    GENERATED_AT = [string]$generatedAt
})

Write-Utf8FileAtomic -Path $resolvedOutput -Value $html
Write-Utf8FileAtomic -Path $dataOutput -Value ($appData | ConvertTo-Json -Depth 100)
Write-Utf8FileAtomic -Path $searchOutput -Value ($searchPayload | ConvertTo-Json -Depth 100)
Write-Utf8FileAtomic -Path $cacheOutput -Value ($cachePayload | ConvertTo-Json -Depth 100)

$buildStopwatch.Stop()

$summary = [pscustomobject]@{
    Mode = $effectiveRefreshMode
    SourceId = $SourceId
    SourceLabel = $SourceLabel
    SourceType = $SourceType
    OutputPath = $resolvedOutput
    DataPath = $dataOutput
    SearchPath = $searchOutput
    CachePath = $cacheOutput
    DetailRoot = $detailRoot
    ScannedCount = $scannedCount
    ParsedCount = $parsedCount
    FailedCount = $failedCount
    ReusedCount = $reusedCount
    DeletedCount = $deletedCount
    ElapsedMs = [int][Math]::Round($buildStopwatch.Elapsed.TotalMilliseconds)
    Sessions = $totalSessions
    Workspaces = $totalWorkspaces
    Archived = $archivedCount
    ImageReferences = $imageRefCount
    Notice = $cacheNotice
}

if ($JsonSummary) {
    $summary | ConvertTo-Json -Depth 20 -Compress
} else {
    $summary
}


