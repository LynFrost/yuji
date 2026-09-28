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
    [string]$MachineName = [Environment]::MachineName,
    [switch]$StatusOnly,
    [string]$ExportSyncInventoryPath = "",
    [string]$RemoteSourceRoot = "",
    [string]$OriginMapPath = "",
    [switch]$DisableLocalPathImages,
    [switch]$JsonSummary
)

$ErrorActionPreference = "Stop"
$buildStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:MaxLocalImageBytes = 30MB
$script:ImageAssetRoot = ""
$script:ImageObjectRoot = ""
$script:ImageManifestPath = ""
$script:ImageStatePath = ""
$script:ImageReferenceSourceId = ""
$script:ImageManifestAssets = @{}
$script:ImageManifestReferences = @{}
$script:ImageManifestDirty = $false
$script:ToolRawSearchEventCharLimit = 16KB
$script:ToolRawSearchSessionCharLimit = 256KB
$script:ToolRawSearchGlobalCharLimit = 128MB
$script:SearchTextGlobalCharLimit = 384MB

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

    return ($template -replace "`r`n?", "`n")
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
        $source = Get-ObjectPropertyValue $part @('image_url', 'url', 'data', 'source', 'path')
        $src = if ($source -is [string]) { [string]$source } else { "" }
        if ([string]::IsNullOrWhiteSpace($src) -and $null -ne $source) {
            $src = [string](Get-ObjectPropertyValue $source @('url', 'data', 'path', 'file_path', 'filePath'))
        }
        if ([string]::IsNullOrWhiteSpace($src)) { continue }
        [void]$images.Add([ordered]@{
            src = $src
            type = 'input_image'
        })
    }
    return @($images)
}

function Get-ClaudeMessageContentImages {
    param([AllowNull()]$Content)
    $images = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Content -or $Content -is [string]) { return @() }
    foreach ($part in @($Content)) {
        if ($null -eq $part -or $part -is [string]) { continue }
        if ([string](Get-ObjectPropertyValue $part @('type')) -ne 'image') { continue }
        $source = Get-ObjectPropertyValue $part @('source')
        $sourceType = [string](Get-ObjectPropertyValue $source @('type'))
        $src = ""
        if ($sourceType -eq 'base64') {
            $mediaType = [string](Get-ObjectPropertyValue $source @('media_type', 'mediaType'))
            $data = [string](Get-ObjectPropertyValue $source @('data'))
            if ($mediaType -match '^image/(png|jpeg|gif|webp|avif)$' -and -not [string]::IsNullOrWhiteSpace($data)) {
                $src = 'data:' + $mediaType.ToLowerInvariant() + ';base64,' + $data
            }
        } else {
            $candidate = Get-ObjectPropertyValue $source @('url', 'path', 'file_path', 'filePath', 'data')
            if ($candidate -is [string]) { $src = [string]$candidate }
        }
        if ([string]::IsNullOrWhiteSpace($src)) {
            $candidate = Get-ObjectPropertyValue $part @('url', 'path', 'file_path', 'filePath', 'data')
            if ($candidate -is [string]) { $src = [string]$candidate }
        }
        if ([string]::IsNullOrWhiteSpace($src)) { continue }
        [void]$images.Add([ordered]@{
            src = $src
            type = 'claude_image'
        })
    }
    return @($images)
}

function Get-ReaderEventImages {
    param([AllowNull()]$Event)
    if ($null -eq $Event) { return @() }
    if ($Event -is [System.Collections.IDictionary]) {
        if ($Event.Contains('images')) { return @($Event['images']) }
        return @()
    }
    if ($Event.PSObject.Properties.Name -contains 'images') { return @($Event.images) }
    return @()
}

function Set-ReaderEventImages {
    param(
        [AllowNull()]$Event,
        [object[]]$Images
    )
    if ($null -eq $Event) { return }
    if ($Event -is [System.Collections.IDictionary]) {
        if ($Images -and @($Images).Count -gt 0) { $Event['images'] = @($Images) }
        elseif ($Event.Contains('images')) { $Event.Remove('images') }
        return
    }
    if ($Images -and @($Images).Count -gt 0) {
        $Event | Add-Member -NotePropertyName images -NotePropertyValue @($Images) -Force
    } elseif ($Event.PSObject.Properties.Name -contains 'images') {
        $Event.PSObject.Properties.Remove('images')
    }
}

function Get-Sha256HexFromBytes {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes) { return "" }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-Sha256HexFromText {
    param([AllowNull()][string]$Text)
    return Get-Sha256HexFromBytes ([System.Text.Encoding]::UTF8.GetBytes([string]$Text))
}

function Get-ImageMimeTypeFromBytes {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -lt 3) { return "" }
    if (
        $Bytes.Length -ge 8 -and
        $Bytes[0] -eq 0x89 -and $Bytes[1] -eq 0x50 -and $Bytes[2] -eq 0x4E -and $Bytes[3] -eq 0x47 -and
        $Bytes[4] -eq 0x0D -and $Bytes[5] -eq 0x0A -and $Bytes[6] -eq 0x1A -and $Bytes[7] -eq 0x0A
    ) { return 'image/png' }
    if ($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xD8 -and $Bytes[2] -eq 0xFF) { return 'image/jpeg' }
    if ($Bytes.Length -ge 6) {
        $gif = [System.Text.Encoding]::ASCII.GetString($Bytes, 0, 6)
        if ($gif -in @('GIF87a', 'GIF89a')) { return 'image/gif' }
    }
    if ($Bytes.Length -ge 12) {
        $riff = [System.Text.Encoding]::ASCII.GetString($Bytes, 0, 4)
        $webp = [System.Text.Encoding]::ASCII.GetString($Bytes, 8, 4)
        if ($riff -eq 'RIFF' -and $webp -eq 'WEBP') { return 'image/webp' }
    }
    if ($Bytes.Length -ge 16 -and [System.Text.Encoding]::ASCII.GetString($Bytes, 4, 4) -eq 'ftyp') {
        $limit = [Math]::Min($Bytes.Length, 64)
        for ($offset = 8; $offset + 3 -lt $limit; $offset += 4) {
            $brand = [System.Text.Encoding]::ASCII.GetString($Bytes, $offset, 4)
            if ($brand -in @('avif', 'avis')) { return 'image/avif' }
        }
    }
    return ""
}

function Get-ImageCandidateSourceText {
    param([AllowNull()]$Candidate)
    if ($null -eq $Candidate) { return "" }
    if ($Candidate -is [string]) { return ([string]$Candidate).Trim(' ', '"', "'", '<', '>') }
    return ([string](Get-ObjectPropertyValue $Candidate @('src', 'localPath', 'path', 'url', 'data'))).Trim(' ', '"', "'", '<', '>')
}

function Get-ImageAssetObjectPath {
    param([string]$AssetId)
    if ($AssetId -notmatch '^[0-9a-f]{64}$' -or [string]::IsNullOrWhiteSpace($script:ImageObjectRoot)) { return "" }
    return Join-Path (Join-Path $script:ImageObjectRoot $AssetId.Substring(0, 2)) ($AssetId + '.bin')
}

function Initialize-ImageAssetStore {
    param(
        [string]$RuntimeDataRoot,
        [string]$SourceId,
        [string]$SourceType
    )
    $script:ImageAssetRoot = Join-Path $RuntimeDataRoot 'CodexChatIndex.images'
    $script:ImageObjectRoot = Join-Path $script:ImageAssetRoot 'objects'
    $manifestRoot = Join-Path $script:ImageAssetRoot 'manifests'
    $script:ImageManifestPath = Join-Path $manifestRoot ((Get-SafeSourceId $SourceId) + '.json')
    $script:ImageStatePath = Join-Path $script:ImageAssetRoot 'state.json'
    $script:ImageReferenceSourceId = if ($SourceType -eq 'webdav-codex') {
        'local-codex'
    } elseif ($SourceType -eq 'webdav-claude') {
        'local-claude'
    } else {
        $SourceId
    }
    $script:ImageManifestAssets = @{}
    $script:ImageManifestReferences = @{}
    $script:ImageManifestDirty = $false
    New-Item -ItemType Directory -Force $script:ImageObjectRoot | Out-Null
    New-Item -ItemType Directory -Force $manifestRoot | Out-Null

    if (-not (Test-Path -LiteralPath $script:ImageManifestPath -PathType Leaf)) { return }
    try {
        $manifest = Get-Content -LiteralPath $script:ImageManifestPath -Raw | ConvertFrom-Json -Depth 100
        foreach ($asset in @($manifest.assets)) {
            $assetId = ([string]$asset.assetId).ToLowerInvariant()
            if ($assetId -notmatch '^[0-9a-f]{64}$') { continue }
            $objectPath = Get-ImageAssetObjectPath $assetId
            if ([string]::IsNullOrWhiteSpace($objectPath) -or -not (Test-Path -LiteralPath $objectPath -PathType Leaf)) { continue }
            $script:ImageManifestAssets[$assetId] = [ordered]@{
                assetId = $assetId
                mimeType = [string]$asset.mimeType
                sizeBytes = [int64]$asset.sizeBytes
            }
        }
        foreach ($reference in @($manifest.references)) {
            $referenceKey = [string]$reference.referenceKey
            $assetId = ([string]$reference.assetId).ToLowerInvariant()
            if (
                -not [string]::IsNullOrWhiteSpace($referenceKey) -and
                $assetId -match '^[0-9a-f]{64}$' -and
                $script:ImageManifestAssets.ContainsKey($assetId)
            ) {
                $script:ImageManifestReferences[$referenceKey] = $assetId
            }
        }
    } catch {
        $script:ImageManifestAssets = @{}
        $script:ImageManifestReferences = @{}
    }
}

function Save-ImageAssetStore {
    param(
        [string]$SourceId,
        [string]$SourceType
    )
    if ([string]::IsNullOrWhiteSpace($script:ImageManifestPath)) { return }
    $assets = @(
        $script:ImageManifestAssets.Keys |
            Sort-Object |
            ForEach-Object { $script:ImageManifestAssets[$_] }
    )
    $references = @(
        $script:ImageManifestReferences.Keys |
            Sort-Object |
            ForEach-Object {
                [ordered]@{
                    referenceKey = [string]$_
                    assetId = [string]$script:ImageManifestReferences[$_]
                }
            }
    )
    $manifest = [ordered]@{
        schemaVersion = 1
        protocol = 'YujiImageSync/v1'
        sourceId = $SourceId
        sourceType = $SourceType
        assets = @($assets)
        references = @($references)
        totalObjects = $assets.Count
        totalBytes = [int64](($assets | Measure-Object -Property sizeBytes -Sum).Sum)
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-Utf8FileAtomic -Path $script:ImageManifestPath -Value ($manifest | ConvertTo-Json -Depth 100)

    $state = [ordered]@{
        version = 1
        imageMigrationVersion = 1
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    if (Test-Path -LiteralPath $script:ImageStatePath -PathType Leaf) {
        try {
            $oldState = Get-Content -LiteralPath $script:ImageStatePath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
            if ($oldState -is [System.Collections.IDictionary]) {
                foreach ($key in $oldState.Keys) {
                    if (-not $state.Contains($key)) { $state[$key] = $oldState[$key] }
                }
            }
        } catch {}
    }
    $migration = if ($state.Contains('migrations') -and $state.migrations -is [System.Collections.IDictionary]) {
        $state.migrations
    } else {
        @{}
    }
    $migration[$SourceId] = 1
    $state.migrations = $migration
    Write-Utf8FileAtomic -Path $script:ImageStatePath -Value ($state | ConvertTo-Json -Depth 20)
}

function Get-ImageReferenceKey {
    param(
        [string]$SessionId,
        [AllowNull()]$Event,
        [int]$UserEventIndex,
        [int]$ImageIndex,
        [string]$OriginalReference
    )
    $turnId = [string](Get-ObjectPropertyValue $Event @('turnId', 'messageId', 'itemId'))
    $eventIdentity = if ([string]::IsNullOrWhiteSpace($turnId)) { 'user-' + $UserEventIndex } else { $turnId }
    $normalizedReference = ([string]$OriginalReference).Trim().Replace('\', '/')
    $originHash = Get-Sha256HexFromText $normalizedReference
    return Get-Sha256HexFromText ((@(
        [string]$script:ImageReferenceSourceId,
        [string]$SessionId,
        [string]$eventIdentity,
        [string]$ImageIndex,
        [string]$originHash
    )) -join '|')
}

function Read-UrlImageBytes {
    param([string]$Url)
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $true
    $handler.MaxAutomaticRedirections = 5
    $handler.UseCookies = $false
    $handler.UseDefaultCredentials = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(15)
    $response = $null
    $stream = $null
    $memory = $null
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
        try {
            $response = $client.SendAsync(
                $request,
                [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
            ).GetAwaiter().GetResult()
        } finally {
            $request.Dispose()
        }
        if (-not $response.IsSuccessStatusCode) {
            throw "HTTP $([int]$response.StatusCode)"
        }
        if (
            $response.Content.Headers.ContentLength.HasValue -and
            [int64]$response.Content.Headers.ContentLength.Value -gt [int64]$script:MaxLocalImageBytes
        ) {
            throw 'too-large'
        }
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $memory = [System.IO.MemoryStream]::new()
        $buffer = [byte[]]::new(64KB)
        while ($true) {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            if ($memory.Length + $read -gt [int64]$script:MaxLocalImageBytes) { throw 'too-large' }
            $memory.Write($buffer, 0, $read)
        }
        return $memory.ToArray()
    } finally {
        if ($memory) { $memory.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Dispose() }
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-TextImageCandidates {
    param([AllowNull()][string]$RawText)
    if ([string]::IsNullOrWhiteSpace($RawText)) { return @() }
    $candidates = [System.Collections.Generic.List[object]]::new()
    $markdownPattern = '!\[[^\]]*\]\((?<target><[^>]+>|[^)\r\n]+)\)'
    foreach ($match in [regex]::Matches($RawText, $markdownPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $target = ([string]$match.Groups['target'].Value).Trim()
        if ($target.StartsWith('<') -and $target.EndsWith('>')) {
            $target = $target.Substring(1, $target.Length - 2).Trim()
        } elseif ($target -match '^(?<path>.+?)\s+["''][^"'']*["'']$') {
            $target = [string]$Matches['path']
        }
        $target = $target.Trim(' ', '"', "'")
        if (-not [string]::IsNullOrWhiteSpace($target)) {
            [void]$candidates.Add([ordered]@{ src = $target; type = 'markdown_image' })
        }
    }

    $patterns = @(
        'https?://[^\s<>"'']+\.(?:png|jpe?g|gif|webp|avif)(?:\?[^\s<>"'']*)?',
        '(?<![A-Za-z0-9])(?:[A-Za-z]:[\\/]|\\\\)[^\r\n<>|?*"]+?\.(?:png|jpe?g|gif|webp|avif)(?=$|[\s)\]},;!?，。；！])',
        '["''][^"''\r\n]+\.(?:png|jpe?g|gif|webp|avif)["'']',
        '(?:\.{1,2}[\\/])?[^\s<>"''()、，。]+[\\/][^\s<>"''()、，。]+\.(?:png|jpe?g|gif|webp|avif)',
        '(?<![\p{L}\p{N}_.-])[\p{L}\p{N}_.-]+\.(?:png|jpe?g|gif|webp|avif)(?![\p{L}\p{N}_.-])'
    )
    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches($RawText, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $candidate = ([string]$match.Value).Trim(' ', '"', "'", ')', ']', '}', ',', ';', '!', '，', '。', '；', '！')
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $coveredByHigherPriorityCandidate = $false
                if ($candidate -notmatch '[\\/]' -and $candidate -notmatch '^https?://') {
                    foreach ($existing in $candidates) {
                        $existingValue = [string](Get-ObjectPropertyValue $existing @('src'))
                        $existingValue = $existingValue.Trim(' ', '"', "'", '<', '>')
                        if (-not $existingValue.EndsWith($candidate, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                        $prefixLength = $existingValue.Length - $candidate.Length
                        if ($prefixLength -eq 0 -or $existingValue[$prefixLength - 1] -match '[\\/\s]') {
                            $coveredByHigherPriorityCandidate = $true
                            break
                        }
                    }
                }
                if ($coveredByHigherPriorityCandidate) { continue }
                [void]$candidates.Add([ordered]@{ src = $candidate; type = 'text_image' })
            }
        }
    }
    return @($candidates)
}

function Resolve-ImageCandidate {
    param(
        [AllowNull()]$Candidate,
        [AllowNull()][string]$Cwd
    )
    if ($null -eq $Candidate) { return $null }
    $value = Get-ImageCandidateSourceText $Candidate
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }

    if ($value -match '^data:(?<mime>image/(?:png|jpeg|gif|webp|avif));base64,(?<data>.+)$') {
        return [ordered]@{ src = $value; type = 'data' }
    }
    if ($value -match '^data:image/') { return $null }

    if ($value -match '^https?://') {
        try {
            $uri = [System.Uri]::new($value)
            if ($uri.AbsolutePath -match '\.svg$') { return $null }
        } catch {
            return $null
        }
        return [ordered]@{ src = $value; type = 'url' }
    }

    if ($DisableLocalPathImages) { return $null }

    $candidateType = [string](Get-ObjectPropertyValue $Candidate @('type'))
    if ($value -match '^file://') {
        try { $value = ([System.Uri]::new($value)).LocalPath } catch { return $null }
    }

    $pathCandidates = [System.Collections.Generic.List[string]]::new()
    [void]$pathCandidates.Add($value)
    if (
        $candidateType -in @('markdown_image', 'text_image') -and
        -not [System.IO.Path]::IsPathRooted($value) -and
        $value.Contains('\_')
    ) {
        $markdownUnescaped = $value.Replace('\_', '_')
        if ($markdownUnescaped -cne $value) {
            [void]$pathCandidates.Add($markdownUnescaped)
        }
    }

    $firstMissingPath = ''
    foreach ($pathValue in $pathCandidates) {
        $path = $null
        try {
            if ([System.IO.Path]::IsPathRooted($pathValue)) {
                $path = [System.IO.Path]::GetFullPath($pathValue)
            } elseif (-not [string]::IsNullOrWhiteSpace($Cwd) -and $Cwd -ne '(未知工作目录)') {
                $path = [System.IO.Path]::GetFullPath((Join-Path $Cwd $pathValue))
            } else {
                continue
            }
        } catch {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($firstMissingPath)) { $firstMissingPath = $path }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }

        $file = Get-Item -LiteralPath $path
        $resolved = [ordered]@{
            src = $value
            type = 'local'
            localPath = $file.FullName
            name = $file.Name
            sizeBytes = [int64]$file.Length
        }
        if ([int64]$file.Length -gt [int64]$script:MaxLocalImageBytes) {
            $resolved.status = 'too-large'
        }
        return $resolved
    }

    if ([string]::IsNullOrWhiteSpace($firstMissingPath)) { return $null }
    return [ordered]@{ src = $value; type = 'local'; localPath = $firstMissingPath; status = 'unavailable' }
}

function Get-ManagedImageFromReferenceKey {
    param([string]$ReferenceKey)
    if (
        [string]::IsNullOrWhiteSpace($ReferenceKey) -or
        -not $script:ImageManifestReferences.ContainsKey($ReferenceKey)
    ) {
        return $null
    }
    $assetId = [string]$script:ImageManifestReferences[$ReferenceKey]
    if (-not $script:ImageManifestAssets.ContainsKey($assetId)) { return $null }
    $asset = $script:ImageManifestAssets[$assetId]
    $objectPath = Get-ImageAssetObjectPath $assetId
    if ([string]::IsNullOrWhiteSpace($objectPath) -or -not (Test-Path -LiteralPath $objectPath -PathType Leaf)) {
        return $null
    }
    return [ordered]@{
        type = 'managed'
        assetId = $assetId
        mimeType = [string]$asset.mimeType
        sizeBytes = [int64]$asset.sizeBytes
    }
}

function Convert-ToManagedImage {
    param(
        [AllowNull()]$Resolved,
        [string]$ReferenceKey
    )
    if ($null -eq $Resolved -or [string]::IsNullOrWhiteSpace($ReferenceKey)) { return $Resolved }
    $existingManaged = Get-ManagedImageFromReferenceKey -ReferenceKey $ReferenceKey
    if ($null -ne $existingManaged) { return $existingManaged }

    $bytes = $null
    try {
        $resolvedType = [string]$Resolved.type
        if ($resolvedType -eq 'data') {
            $source = [string]$Resolved.src
            if ($source -notmatch '^data:image/(?:png|jpeg|gif|webp|avif);base64,(?<data>.+)$') {
                throw 'unsupported'
            }
            $bytes = [Convert]::FromBase64String([string]$Matches['data'])
        } elseif ($resolvedType -eq 'url') {
            $bytes = Read-UrlImageBytes -Url ([string]$Resolved.src)
        } elseif ($resolvedType -eq 'local') {
            $localPath = [string]$Resolved.localPath
            if ([string]::IsNullOrWhiteSpace($localPath) -or -not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
                throw 'unavailable'
            }
            $file = Get-Item -LiteralPath $localPath
            if ([int64]$file.Length -gt [int64]$script:MaxLocalImageBytes) { throw 'too-large' }
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
        } else {
            throw 'unsupported'
        }
        if ($null -eq $bytes -or $bytes.Length -le 0) { throw 'empty' }
        if ([int64]$bytes.Length -gt [int64]$script:MaxLocalImageBytes) { throw 'too-large' }
        $mimeType = Get-ImageMimeTypeFromBytes $bytes
        if ([string]::IsNullOrWhiteSpace($mimeType)) { throw 'unsupported' }
        $assetId = Get-Sha256HexFromBytes $bytes
        $objectPath = Get-ImageAssetObjectPath $assetId
        $objectDir = Split-Path -Parent $objectPath
        New-Item -ItemType Directory -Force $objectDir | Out-Null
        if (-not (Test-Path -LiteralPath $objectPath -PathType Leaf)) {
            $temporary = Join-Path $objectDir ('.' + $assetId + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
            try {
                [System.IO.File]::WriteAllBytes($temporary, $bytes)
                try {
                    [System.IO.File]::Move($temporary, $objectPath)
                } catch {
                    if (-not (Test-Path -LiteralPath $objectPath -PathType Leaf)) { throw }
                }
            } finally {
                Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            }
        }
        $script:ImageManifestAssets[$assetId] = [ordered]@{
            assetId = $assetId
            mimeType = $mimeType
            sizeBytes = [int64]$bytes.Length
        }
        $script:ImageManifestReferences[$ReferenceKey] = $assetId
        $script:ImageManifestDirty = $true
        return [ordered]@{
            type = 'managed'
            assetId = $assetId
            mimeType = $mimeType
            sizeBytes = [int64]$bytes.Length
        }
    } catch {
        $failureStatus = if ([string]$_.Exception.Message -eq 'too-large') {
            'too-large'
        } elseif ([string]$_.Exception.Message -eq 'unsupported') {
            'unsupported'
        } else {
            'unavailable'
        }
        $fallback = [ordered]@{
            type = [string]$Resolved.type
            status = $failureStatus
        }
        if ([string]$Resolved.type -eq 'local') {
            $fallback.localPath = [string]$Resolved.localPath
            $fallback.src = [string]$Resolved.src
        } elseif ([string]$Resolved.type -eq 'url') {
            $fallback.src = [string]$Resolved.src
        }
        return $fallback
    }
}

function Add-ResolvedUserEventImages {
    param(
        [AllowNull()]$Events,
        [AllowNull()][string]$Cwd,
        [AllowNull()][string]$SessionId
    )
    $userEventIndex = 0
    foreach ($event in @($Events)) {
        if ($null -eq $event -or [string](Get-ObjectPropertyValue $event @('kind')) -ne 'user') { continue }
        $userEventIndex++
        $candidates = [System.Collections.Generic.List[object]]::new()
        foreach ($candidate in @(Get-ReaderEventImages $event)) { [void]$candidates.Add($candidate) }
        $rawText = [string](Get-ObjectPropertyValue $event @('rawText', 'summary'))
        foreach ($candidate in @(Get-TextImageCandidates $rawText)) { [void]$candidates.Add($candidate) }

        $resolvedImages = [System.Collections.Generic.List[object]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $imageIndex = 0
        foreach ($candidate in $candidates) {
            $originalReference = Get-ImageCandidateSourceText $candidate
            if ([string]::IsNullOrWhiteSpace($originalReference)) { continue }
            $imageIndex++
            $referenceKey = Get-ImageReferenceKey -SessionId $SessionId -Event $event -UserEventIndex $userEventIndex -ImageIndex $imageIndex -OriginalReference $originalReference
            $existingManaged = Get-ManagedImageFromReferenceKey -ReferenceKey $referenceKey
            if ($null -ne $existingManaged) {
                $dedupeKey = 'managed-reference:' + $originalReference
                if ($seen.Add($dedupeKey)) { [void]$resolvedImages.Add($existingManaged) }
                continue
            }
            $resolved = Resolve-ImageCandidate -Candidate $candidate -Cwd $Cwd
            if ($null -eq $resolved) { continue }
            $dedupeValue = if ([string]$resolved.type -eq 'local') { [string]$resolved.localPath } else { [string]$resolved.src }
            $dedupeKey = [string]$resolved.type + ':' + $dedupeValue
            if ([string]::IsNullOrWhiteSpace($dedupeValue) -or -not $seen.Add($dedupeKey)) { continue }
            [void]$resolvedImages.Add((Convert-ToManagedImage -Resolved $resolved -ReferenceKey $referenceKey))
        }
        Set-ReaderEventImages -Event $event -Images @($resolvedImages)
    }
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

$script:CodexInjectedContextTagNames = @(
    'recommended_plugins',
    'environment_context',
    'app-context',
    'permissions instructions',
    'collaboration_mode',
    'skills_instructions',
    'apps_instructions',
    'plugins_instructions',
    'subagent_notification',
    'turn_aborted'
)

function Remove-CodexInjectedContextPrefix {
    param([AllowNull()][string]$RawText)

    $text = if ($null -eq $RawText) { '' } else { [string]$RawText }
    $cursor = 0
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $cursor++ }
    while ($cursor -lt $text.Length -and [char]::IsWhiteSpace($text[$cursor])) { $cursor++ }

    $changed = $false
    $removedBlockCount = 0
    while ($cursor -lt $text.Length) {
        $blockEnd = -1
        foreach ($tagName in $script:CodexInjectedContextTagNames) {
            $openTag = '<' + $tagName + '>'
            if ($cursor + $openTag.Length -gt $text.Length) { continue }
            if ($text.Substring($cursor, $openTag.Length) -cne $openTag) { continue }
            $closeTag = '</' + $tagName + '>'
            $closeIndex = $text.IndexOf($closeTag, $cursor + $openTag.Length, [System.StringComparison]::Ordinal)
            if ($closeIndex -ge 0) {
                $blockEnd = $closeIndex + $closeTag.Length
            }
            break
        }

        if ($blockEnd -lt 0) {
            $agentsHeader = '# AGENTS.md instructions for '
            if ($cursor + $agentsHeader.Length -le $text.Length -and $text.Substring($cursor, $agentsHeader.Length) -ceq $agentsHeader) {
                $instructionsOpen = '<INSTRUCTIONS>'
                $instructionsClose = '</INSTRUCTIONS>'
                $openIndex = $text.IndexOf($instructionsOpen, $cursor + $agentsHeader.Length, [System.StringComparison]::Ordinal)
                if ($openIndex -ge 0) {
                    $closeIndex = $text.IndexOf($instructionsClose, $openIndex + $instructionsOpen.Length, [System.StringComparison]::Ordinal)
                    if ($closeIndex -ge 0) {
                        $blockEnd = $closeIndex + $instructionsClose.Length
                    }
                }
            }
        }

        if ($blockEnd -lt 0) { break }
        $changed = $true
        $removedBlockCount++
        $cursor = $blockEnd
        while ($cursor -lt $text.Length -and [char]::IsWhiteSpace($text[$cursor])) { $cursor++ }
    }

    $remaining = if ($changed) { $text.Substring($cursor).Trim() } else { $text }
    return [pscustomobject]@{
        Text = $remaining
        Changed = $changed
        FullyInjected = $changed -and [string]::IsNullOrWhiteSpace($remaining)
        RemovedBlockCount = $removedBlockCount
    }
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

function ConvertTo-CodexDateTimeOffset {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    try {
        if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
        if ($Value -is [DateTime]) {
            return ([DateTimeOffset]$Value).ToUniversalTime()
        }
        $text = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return [DateTimeOffset]::Parse(
            $text,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
    } catch {
        return $null
    }
}

function ConvertFrom-CodexUnixTime {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    try {
        $text = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        $number = [decimal]0
        if (-not [decimal]::TryParse(
            $text,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$number
        )) { return $null }
        if ($number -lt 0) { return $null }
        $milliseconds = if ([decimal]::Abs($number) -ge 100000000000) {
            [int64][Math]::Round([double]$number, [MidpointRounding]::AwayFromZero)
        } else {
            [int64][Math]::Round(([double]$number * 1000), [MidpointRounding]::AwayFromZero)
        }
        $result = [DateTimeOffset]::FromUnixTimeMilliseconds($milliseconds).ToUniversalTime()
        if ($result.Year -lt 2000 -or $result.Year -gt 2200) { return $null }
        return $result
    } catch {
        return $null
    }
}

function ConvertFrom-CodexUuidV7Time {
    param([AllowNull()][string]$Value)
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    if ($text.StartsWith('msg_', [System.StringComparison]::OrdinalIgnoreCase)) {
        $text = $text.Substring(4)
    }
    if ($text -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-7[0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$') {
        return $null
    }
    try {
        $milliseconds = [Convert]::ToInt64(($text.Substring(0, 8) + $text.Substring(9, 4)), 16)
        $result = [DateTimeOffset]::FromUnixTimeMilliseconds($milliseconds).ToUniversalTime()
        if ($result.Year -lt 2000 -or $result.Year -gt 2200) { return $null }
        return $result
    } catch {
        return $null
    }
}

function Add-CodexTimeSecondsSafe {
    param([AllowNull()]$Value, [double]$Seconds)
    if ($null -eq $Value) { return $null }
    try {
        return ([DateTimeOffset]$Value).AddSeconds($Seconds)
    } catch {
        return $null
    }
}

function Get-CodexEntryTurnId {
    param(
        [AllowNull()]$Entry,
        [AllowNull()][string]$CurrentTurnId = '',
        [switch]$AllowCurrentTurnFallback
    )
    if ($null -eq $Entry) { return '' }
    foreach ($candidate in @(
        (Get-ObjectPropertyValue $Entry @('turn_id')),
        (Get-ObjectPropertyValue $Entry.payload @('turn_id')),
        (Get-ObjectPropertyValue $Entry.payload.item @('turn_id')),
        (Get-ObjectPropertyValue $Entry.payload.internal_chat_message_metadata_passthrough @('turn_id'))
    )) {
        $text = ([string]$candidate).Trim()
        if (-not [string]::IsNullOrWhiteSpace($text)) { return $text }
    }
    if ($AllowCurrentTurnFallback) { return ([string]$CurrentTurnId).Trim() }
    return ''
}

function Test-CodexUserCandidateIntervalSafe {
    param(
        [System.Collections.Generic.HashSet[int]]$BarrierOrdinals,
        [int]$LowOrdinal,
        [int]$HighOrdinal
    )
    if ($HighOrdinal - $LowOrdinal -gt 2) { return $false }
    if ($HighOrdinal - $LowOrdinal -le 1) { return $true }
    foreach ($ordinal in (($LowOrdinal + 1)..($HighOrdinal - 1))) {
        if ($BarrierOrdinals.Contains($ordinal)) { return $false }
    }
    return $true
}

function Test-CodexAssistantWrapperCluster {
    param(
        [hashtable]$WrappersByOrdinal,
        [int]$LowOrdinal,
        [int]$HighOrdinal,
        [AllowNull()][string]$TurnId,
        [AllowNull()][string]$RawText,
        [string]$EventKind,
        [string[]]$StableItemIds = @()
    )
    if ($HighOrdinal - $LowOrdinal -gt 3) { return $false }
    if ($HighOrdinal - $LowOrdinal -le 1) { return $false }
    $stableIds = @($StableItemIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $normalizedText = ([string]$RawText).Trim()
    $expectedPhase = switch ($EventKind) {
        'assistant_commentary' { 'commentary' }
        'assistant_final' { 'final_answer' }
        default { '' }
    }
    $matchingWrappers = 0
    foreach ($ordinal in (($LowOrdinal + 1)..($HighOrdinal - 1))) {
        if (-not $WrappersByOrdinal.ContainsKey($ordinal)) { return $false }
        $marker = $WrappersByOrdinal[$ordinal]
        $markerTurnId = ([string]$marker.TurnId).Trim()
        $markerStableId = ([string]$marker.StableItemId).Trim()
        $stableIdMatch = $stableIds.Count -gt 0 -and $stableIds -contains $markerStableId
        if ($stableIdMatch) {
            if (-not [string]::IsNullOrWhiteSpace($markerTurnId) -and $markerTurnId -ne [string]$TurnId) { return $false }
            $matchingWrappers++
            continue
        }
        if (
            [string]::IsNullOrWhiteSpace($expectedPhase) -or
            ([string]$marker.Phase).Trim() -ne $expectedPhase -or
            [string]::IsNullOrWhiteSpace($normalizedText) -or
            ([string]$marker.RawText).Trim() -ne $normalizedText -or
            $markerTurnId -ne [string]$TurnId
        ) { return $false }
        $matchingWrappers++
    }
    return $matchingWrappers -gt 0
}

function Get-CodexContentText {
    param([AllowNull()]$Content)
    if ($null -eq $Content) { return '' }
    if ($Content -is [string]) { return ([string]$Content).Trim() }
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($part in @($Content)) {
        if ($null -eq $part) { continue }
        if ($part -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace([string]$part)) { $parts.Add([string]$part) }
            continue
        }
        $type = ([string](Get-ObjectPropertyValue $part @('type'))).ToLowerInvariant()
        $text = Get-ObjectPropertyValue $part @('text', 'output_text', 'input_text')
        if ($type -in @('text', 'input_text', 'output_text', 'inputtext', 'outputtext') -and -not [string]::IsNullOrWhiteSpace([string]$text)) {
            $parts.Add([string]$text)
        }
    }
    return (@($parts) -join "`n").Trim()
}

function Get-CodexOutputSequenceText {
    param([AllowNull()]$Content)
    if ($null -eq $Content) { return '' }
    if ($Content -is [string]) { return [string]$Content }
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($part in @($Content)) {
        if ($null -eq $part) { continue }
        if ($part -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace([string]$part)) { $parts.Add([string]$part) }
            continue
        }
        $type = ([string](Get-ObjectPropertyValue $part @('type'))).ToLowerInvariant()
        $text = Get-ObjectPropertyValue $part @('text')
        if ($type -in @('text', 'input_text', 'output_text', 'inputtext', 'outputtext') -and -not [string]::IsNullOrWhiteSpace([string]$text)) {
            $parts.Add([string]$text)
        } else {
            $serialized = Convert-ToCompactJsonText $part
            if (-not [string]::IsNullOrWhiteSpace($serialized)) { $parts.Add($serialized) }
        }
    }
    return (@($parts) -join "`n").Trim()
}

function New-CodexEventCandidate {
    param(
        $Event,
        [int]$RawLineOrdinal,
        [string]$WrapperSource,
        [AllowNull()][string]$StableItemId = '',
        [AllowNull()]$TopTimestamp,
        [AllowNull()]$ItemStartedAt,
        [AllowNull()]$ItemCompletedAt,
        [AllowNull()]$CreateTime,
        [AllowNull()][string]$UserMessageId = '',
        [switch]$AuthoritativeTool
    )
    [pscustomobject]@{
        Event = $Event
        RawLineOrdinal = $RawLineOrdinal
        WrapperSource = $WrapperSource
        StableItemId = ([string]$StableItemId).Trim()
        TopUtc = ConvertTo-CodexDateTimeOffset $TopTimestamp
        ItemStartedUtc = ConvertFrom-CodexUnixTime $ItemStartedAt
        ItemCompletedUtc = ConvertFrom-CodexUnixTime $ItemCompletedAt
        CreateUtc = ConvertFrom-CodexUnixTime $CreateTime
        UserUuidUtc = ConvertFrom-CodexUuidV7Time $UserMessageId
        AuthoritativeTool = [bool]$AuthoritativeTool
    }
}

function Test-CodexCandidateTimeWithinTask {
    param(
        [AllowNull()]$Value,
        [AllowNull()]$Task,
        [AllowNull()]$PreviousTask,
        [AllowNull()]$NextTask
    )
    if ($null -eq $Value) { return $false }
    if ($null -eq $Task) { return $true }
    $started = $Task.StartedUtc
    $completed = $Task.CompletedUtc
    if ($null -ne $started -and $null -ne $completed -and $started -gt $completed) {
        $started = $null
        $completed = $null
    }
    $lower = Add-CodexTimeSecondsSafe $started -5
    $upper = Add-CodexTimeSecondsSafe $completed 5
    if ($null -eq $lower -and $null -ne $PreviousTask -and $null -ne $PreviousTask.CompletedUtc) {
        $lower = Add-CodexTimeSecondsSafe $PreviousTask.CompletedUtc -5
    }
    if ($null -eq $upper -and $null -ne $NextTask -and $null -ne $NextTask.StartedUtc) {
        $upper = Add-CodexTimeSecondsSafe $NextTask.StartedUtc 5
    }
    if ($null -ne $lower -and $Value -lt $lower) { return $false }
    if ($null -ne $upper -and $Value -gt $upper) { return $false }
    return $true
}

function Get-CodexResolvedCandidateTime {
    param(
        $Candidate,
        [AllowNull()]$Task,
        [AllowNull()]$PreviousTask,
        [AllowNull()]$NextTask,
        [int]$TurnFinalCount = 0
    )
    $event = $Candidate.Event
    $taskRangeValid = -not (
        $null -ne $Task -and
        $null -ne $Task.StartedUtc -and
        $null -ne $Task.CompletedUtc -and
        $Task.StartedUtc -gt $Task.CompletedUtc
    )
    $itemStarted = $Candidate.ItemStartedUtc
    $itemCompleted = $Candidate.ItemCompletedUtc
    if ($null -ne $itemStarted -and $null -ne $itemCompleted -and $itemStarted -gt $itemCompleted) {
        $itemStarted = $null
        $itemCompleted = $null
    }
    $valid = {
        param($value)
        if (Test-CodexCandidateTimeWithinTask $value $Task $PreviousTask $NextTask) { return $value }
        return $null
    }
    $started = & $valid $itemStarted
    $completed = & $valid $itemCompleted
    $created = & $valid $Candidate.CreateUtc
    $uuid = & $valid $Candidate.UserUuidUtc
    $top = & $valid $Candidate.TopUtc

    if ([string]$event.kind -eq 'system' -and [string]$event.summary -eq 'task_started') {
        if ($taskRangeValid -and $null -ne $Task -and $null -ne $Task.StartedUtc) { return $Task.StartedUtc }
        return $top
    }
    if ([string]$event.kind -eq 'system' -and [string]$event.summary -eq 'task_complete') {
        if ($null -ne $Task -and $null -ne $Task.CompletedUtc) { return $Task.CompletedUtc }
        return $top
    }
    if ([string]$event.kind -eq 'user') {
        foreach ($value in @($started, $completed, $created, $uuid)) {
            if ($null -ne $value) { return $value }
        }
        if ($null -ne $top) { return $top }
        if ($taskRangeValid -and $null -ne $Task -and $null -ne $Task.StartedUtc) { return $Task.StartedUtc }
        if ($null -ne $Task -and $null -ne $Task.TurnUuidUtc) { return $Task.TurnUuidUtc }
        return $null
    }
    if ([string]$event.kind -eq 'assistant_final') {
        foreach ($value in @($completed, $started, $created)) {
            if ($null -ne $value) { return $value }
        }
        if ($null -ne $top) { return $top }
        if ($taskRangeValid -and $null -ne $Task -and $null -ne $Task.CompletedUtc) {
            $matchesLast = -not [string]::IsNullOrWhiteSpace([string]$Task.LastAgentMessage) -and
                ([string]$Task.LastAgentMessage).Trim() -eq ([string]$event.rawText).Trim()
            if ($matchesLast -or $TurnFinalCount -eq 1) { return $Task.CompletedUtc }
        }
        return $null
    }
    foreach ($value in @($completed, $started, $created)) {
        if ($null -ne $value) { return $value }
    }
    return $top
}

function Set-CodexResolvedEventTime {
    param($Event, [AllowNull()]$Value)
    if ($null -eq $Value) {
        $Event.timestamp = ''
        $Event.timestampLocal = ''
        return
    }
    $Event.timestamp = ([DateTimeOffset]$Value).ToUniversalTime().ToString('o')
    $Event.timestampLocal = ([DateTimeOffset]$Value).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
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

function Get-LocalSourceLabel {
    param(
        [string]$SourceType,
        [AllowNull()][string]$MachineName
    )
    $baseLabel = if ($SourceType -eq 'local-claude') { '本机 Claude' } else { '本机 Codex' }
    $normalizedMachineName = ([string]$MachineName).Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedMachineName)) { return $baseLabel }
    return $normalizedMachineName + '-' + $baseLabel
}

function Get-SourceCapabilities {
    param([string]$SourceType)

    if ($SourceType -in @('local-codex', 'local-claude')) {
        return [ordered]@{
            canRefresh = $true
            canQuickRefresh = $true
            canRebuild = $true
            canUpload = $true
            canDownload = $false
            canResume = $true
            canReply = $true
            canEditNotes = $true
            canResolveLocalImages = $true
            isReadOnly = $false
        }
    }
    if ($SourceType -in @('webdav-codex', 'webdav-claude')) {
        return [ordered]@{
            canRefresh = $false
            canQuickRefresh = $false
            canRebuild = $true
            canUpload = $false
            canDownload = $true
            canResume = $false
            canReply = $false
            canEditNotes = $false
            canResolveLocalImages = $false
            isReadOnly = $true
        }
    }
    return [ordered]@{
        canRefresh = $true
        canQuickRefresh = $true
        canRebuild = $true
        canUpload = $false
        canDownload = $false
        canResume = $false
        canReply = $false
        canEditNotes = $true
        canResolveLocalImages = $true
        isReadOnly = $false
    }
}

function Get-RelativeSyncPath {
    param(
        [string]$Root,
        [string]$Path,
        [string]$Prefix
    )
    $relative = [System.IO.Path]::GetRelativePath(
        [System.IO.Path]::GetFullPath($Root),
        [System.IO.Path]::GetFullPath($Path)
    ).Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($relative) -or $relative -eq '.' -or $relative.StartsWith('../')) {
        throw "Unable to create a safe sync logical path for: $Path"
    }
    return ($Prefix.Trim('/') + '/' + $relative.TrimStart('/'))
}

function New-SyncInventoryFileEntry {
    param(
        [System.IO.FileInfo]$File,
        [string]$SourceType,
        [string]$SessionRoot,
        [string]$ArchiveRoot,
        [string]$ClaudeHome,
        [string]$ClaudeSessionsRoot
    )
    if ($null -eq $File) { return $null }
    $filePath = [System.IO.Path]::GetFullPath($File.FullName)
    $logicalPath = ''
    $rootKind = ''
    $recordFormat = if ($File.Extension -ieq '.json') { 'json' } else { 'jsonl' }
    $archived = $false
    $entrypoint = ''

    if ($SourceType -eq 'local-codex') {
        if (Test-PathWithinDirectory -Path $filePath -Directory $SessionRoot) {
            $logicalPath = Get-RelativeSyncPath -Root $SessionRoot -Path $filePath -Prefix 'sessions'
            $rootKind = 'sessions'
        } elseif (Test-PathWithinDirectory -Path $filePath -Directory $ArchiveRoot) {
            $logicalPath = Get-RelativeSyncPath -Root $ArchiveRoot -Path $filePath -Prefix 'archived_sessions'
            $rootKind = 'archived_sessions'
            $archived = $true
        } else {
            throw "Codex sync file is outside the supported roots: $filePath"
        }
    } elseif ($SourceType -eq 'local-claude') {
        $claudeProjectsRoot = Join-Path $ClaudeHome 'projects'
        if (Test-PathWithinDirectory -Path $filePath -Directory $claudeProjectsRoot) {
            $logicalPath = Get-RelativeSyncPath -Root $claudeProjectsRoot -Path $filePath -Prefix 'projects'
            $rootKind = 'projects'
            $entrypoint = 'cli'
        } elseif (Test-PathWithinDirectory -Path $filePath -Directory $ClaudeSessionsRoot) {
            $logicalPath = Get-RelativeSyncPath -Root $ClaudeSessionsRoot -Path $filePath -Prefix 'sessions_metadata'
            $rootKind = 'sessions_metadata'
            $entrypoint = 'cli'
        } else {
            $pathHashBytes = [System.Text.Encoding]::UTF8.GetBytes($filePath.ToLowerInvariant())
            $pathHash = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData($pathHashBytes))).Replace('-', '').ToLowerInvariant().Substring(0, 12)
            $recognizedTail = if ($filePath -match '(?i)(local-agent-mode-sessions[\\/].+[\\/]\.claude[\\/]projects[\\/].+\.jsonl)$') {
                $Matches[1].Replace('\', '/')
            } elseif ($filePath -match '(?i)(AndrePimenta\.claude-code-chat[\\/]conversations[\\/].+\.json)$') {
                $Matches[1].Replace('\', '/')
            } else {
                throw "Claude sync file is outside the supported parser roots: $filePath"
            }
            $logicalPath = 'claude_desktop/' + $pathHash + '/' + $recognizedTail
            $rootKind = 'claude_desktop'
            $entrypoint = 'claude-desktop-3p'
        }
    } else {
        throw "Sync inventory is only supported for local-codex and local-claude."
    }

    return [ordered]@{
        absolutePath = $filePath
        logicalPath = $logicalPath
        originPath = $filePath
        sizeBytes = [int64]$File.Length
        lastWriteTimeUtc = $File.LastWriteTimeUtc.ToUniversalTime().ToString('o')
        rootKind = $rootKind
        recordFormat = $recordFormat
        archived = $archived
        entrypoint = $entrypoint
    }
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
            label = Get-LocalSourceLabel -SourceType 'local-codex' -MachineName $MachineName
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
            label = Get-LocalSourceLabel -SourceType 'local-claude' -MachineName $MachineName
            type = 'local-claude'
            root = (Join-Path $ClaudeHome 'projects')
            sessionsRoot = (Join-Path $ClaudeHome 'sessions')
        })
    }

    foreach ($item in $sources) {
        $itemId = [string](Get-ObjectPropertyValue $item @('id'))
        if ($itemId -notin @('local-codex', 'local-claude')) { continue }
        $label = Get-LocalSourceLabel -SourceType $itemId -MachineName $MachineName
        if ($item -is [System.Collections.IDictionary]) {
            $item['label'] = $label
        } else {
            $item | Add-Member -NotePropertyName label -NotePropertyValue $label -Force
        }
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

function Get-BoundedSearchExcerpt {
    param(
        [AllowNull()][string]$Text,
        [int64]$MaxChars
    )
    if ([string]::IsNullOrEmpty($Text) -or $MaxChars -le 0) { return "" }
    $clean = ([string]$Text -replace "`0", "")
    if ([int64]$clean.Length -le $MaxChars) { return $clean }
    if ($MaxChars -eq 1) { return $clean.Substring(0, 1) }

    $separator = "`n"
    $contentChars = $MaxChars - $separator.Length
    $headChars = [int][Math]::Ceiling($contentChars / 2.0)
    $tailChars = [int]($contentChars - $headChars)
    return $clean.Substring(0, $headChars) + $separator + $clean.Substring($clean.Length - $tailChars, $tailChars)
}

function Get-SessionSearchParts {
    param(
        $Session,
        [int64]$ToolRawEventCharLimit = $script:ToolRawSearchEventCharLimit,
        [int64]$ToolRawSessionCharLimit = $script:ToolRawSearchSessionCharLimit
    )
    $questionTexts = [System.Collections.Generic.List[string]]::new()
    $otherBaseParts = [System.Collections.Generic.List[string]]::new()
    $toolRawParts = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @(
        $Session.Title,
        $Session.Summary,
        $Session.Path,
        $Session.Cwd,
        $Session.Source,
        $Session.ModelProvider
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            [void]$otherBaseParts.Add([string]$value)
        }
    }

    $events = @($Session.Events)
    $toolRawEvents = @($events | Where-Object {
        $null -ne $_ -and [string]$_.kind -eq 'tool' -and -not [string]::IsNullOrWhiteSpace([string]$_.rawText)
    })
    $toolRawSeparatorChars = [Math]::Max(0, $toolRawEvents.Count - 1)
    $toolRawAvailableChars = [Math]::Max(0, $ToolRawSessionCharLimit - $toolRawSeparatorChars)
    $toolRawEventBudget = if ($toolRawEvents.Count -gt 0) {
        [Math]::Min($ToolRawEventCharLimit, [Math]::Floor($toolRawAvailableChars / $toolRawEvents.Count))
    } else {
        0
    }
    $toolRawOriginalChars = [int64]0
    $toolRawTruncatedEvents = 0

    foreach ($event in $events) {
        if ($null -eq $event) { continue }
        if ([string]$event.kind -eq 'user') {
            $questionText = if (-not [string]::IsNullOrWhiteSpace([string]$event.rawText)) {
                [string]$event.rawText
            } else {
                [string]$event.summary
            }
            if (-not [string]::IsNullOrWhiteSpace($questionText)) {
                [void]$questionTexts.Add(($questionText -replace "`0", ""))
            }
            foreach ($value in @($event.kind, $event.phase, $event.role, $event.toolName, $event.status)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                    [void]$otherBaseParts.Add([string]$value)
                }
            }
            continue
        }
        foreach ($value in @(
            $event.kind,
            $event.phase,
            $event.role,
            $event.toolName,
            $event.status,
            $event.summary
        )) {
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                [void]$otherBaseParts.Add([string]$value)
            }
        }
        if ([string]$event.kind -eq 'tool') {
            $rawText = ([string]$event.rawText -replace "`0", "")
            if (-not [string]::IsNullOrWhiteSpace($rawText)) {
                $toolRawOriginalChars += $rawText.Length
                $excerpt = Get-BoundedSearchExcerpt -Text $rawText -MaxChars $toolRawEventBudget
                if ($excerpt.Length -lt $rawText.Length) { $toolRawTruncatedEvents++ }
                if (-not [string]::IsNullOrWhiteSpace($excerpt)) { [void]$toolRawParts.Add($excerpt) }
            }
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$event.rawText)) {
            [void]$otherBaseParts.Add([string]$event.rawText)
        }
    }

    $otherBaseText = (($otherBaseParts -join "`n") -replace "`0", "")
    $toolRawText = (($toolRawParts -join "`n") -replace "`0", "")
    $otherText = (@($otherBaseText, $toolRawText) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
    return [pscustomobject]@{
        QuestionTexts = @($questionTexts)
        OtherBaseText = $otherBaseText
        ToolRawText = $toolRawText
        OtherText = $otherText
        ToolRawOriginalChars = $toolRawOriginalChars
        ToolRawIndexedChars = [int64]$toolRawText.Length
        ToolRawTruncatedEvents = $toolRawTruncatedEvents
    }
}

function Set-SessionSearchFields {
    param(
        $Session,
        [int64]$ToolRawEventCharLimit = $script:ToolRawSearchEventCharLimit,
        [int64]$ToolRawSessionCharLimit = $script:ToolRawSearchSessionCharLimit
    )
    $parts = Get-SessionSearchParts -Session $Session -ToolRawEventCharLimit $ToolRawEventCharLimit -ToolRawSessionCharLimit $ToolRawSessionCharLimit
    $Session | Add-Member -NotePropertyName QuestionSearchTexts -NotePropertyValue @($parts.QuestionTexts) -Force
    $Session | Add-Member -NotePropertyName OtherSearchBaseText -NotePropertyValue ([string]$parts.OtherBaseText) -Force
    $Session | Add-Member -NotePropertyName ToolRawSearchText -NotePropertyValue ([string]$parts.ToolRawText) -Force
    $Session | Add-Member -NotePropertyName OtherSearchText -NotePropertyValue ([string]$parts.OtherText) -Force
    $Session | Add-Member -NotePropertyName ToolRawSearchOriginalChars -NotePropertyValue ([int64]$parts.ToolRawOriginalChars) -Force
    $Session | Add-Member -NotePropertyName ToolRawSearchTruncatedEvents -NotePropertyValue ([int]$parts.ToolRawTruncatedEvents) -Force
    return $Session
}

function Set-GlobalSearchTextLimits {
    param(
        [object[]]$Sessions,
        [int64]$ToolRawGlobalCharLimit = $script:ToolRawSearchGlobalCharLimit,
        [int64]$SearchTextGlobalCharLimit = $script:SearchTextGlobalCharLimit
    )
    $sessionList = @($Sessions)
    $questionChars = [int64]0
    $otherBaseChars = [int64]0
    $toolRawOriginalChars = [int64]0
    $toolRawBeforeGlobalChars = [int64]0
    $toolRawTruncatedEvents = 0
    foreach ($session in $sessionList) {
        foreach ($questionText in @($session.QuestionSearchTexts)) { $questionChars += ([string]$questionText).Length }
        $otherBaseChars += ([string]$session.OtherSearchBaseText).Length
        $toolRawOriginalChars += [int64]$session.ToolRawSearchOriginalChars
        $toolRawBeforeGlobalChars += ([string]$session.ToolRawSearchText).Length
        $toolRawTruncatedEvents += [int]$session.ToolRawSearchTruncatedEvents
    }

    $requiredBaseChars = $questionChars + $otherBaseChars
    if ($requiredBaseChars -gt $SearchTextGlobalCharLimit) {
        throw ("Search text excluding tool raw output is too large ({0:N0} characters; safety limit {1:N0}). " +
            "Tool output is already excluded from this measurement. Split the source or upgrade the search storage format.") -f `
            $requiredBaseChars, $SearchTextGlobalCharLimit
    }

    $availableToolChars = [Math]::Max(0, $SearchTextGlobalCharLimit - $requiredBaseChars)
    $effectiveToolLimit = [Math]::Min([int64]$ToolRawGlobalCharLimit, [int64]$availableToolChars)
    if ($toolRawBeforeGlobalChars -gt $effectiveToolLimit) {
        $nonEmptyToolSessions = @($sessionList | Where-Object { ([string]$_.ToolRawSearchText).Length -gt 0 })
        $remainingBudget = [int64]$effectiveToolLimit
        $remainingCount = $nonEmptyToolSessions.Count
        $fairLimit = [int64]0
        foreach ($session in @($nonEmptyToolSessions | Sort-Object { ([string]$_.ToolRawSearchText).Length })) {
            if ($remainingCount -le 0) { break }
            $share = [int64][Math]::Floor($remainingBudget / $remainingCount)
            $length = ([string]$session.ToolRawSearchText).Length
            if ($length -le $share) {
                $remainingBudget -= $length
                $remainingCount--
                continue
            }
            $fairLimit = $share
            break
        }
        foreach ($session in $nonEmptyToolSessions) {
            $text = [string]$session.ToolRawSearchText
            if ($text.Length -gt $fairLimit) {
                $session | Add-Member -NotePropertyName ToolRawSearchText `
                    -NotePropertyValue (Get-BoundedSearchExcerpt -Text $text -MaxChars $fairLimit) -Force
            }
        }
    }

    $toolRawIndexedChars = [int64]0
    foreach ($session in $sessionList) {
        $toolRawText = [string]$session.ToolRawSearchText
        $toolRawIndexedChars += $toolRawText.Length
        $otherText = (@([string]$session.OtherSearchBaseText, $toolRawText) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
        $session | Add-Member -NotePropertyName OtherSearchText -NotePropertyValue $otherText -Force
    }

    return [pscustomobject]@{
        QuestionChars = $questionChars
        OtherBaseChars = $otherBaseChars
        ToolRawOriginalChars = $toolRawOriginalChars
        ToolRawBeforeGlobalChars = $toolRawBeforeGlobalChars
        ToolRawIndexedChars = $toolRawIndexedChars
        ToolRawTruncatedEvents = $toolRawTruncatedEvents
        TotalIndexedChars = $questionChars + $otherBaseChars + $toolRawIndexedChars
        ToolRawGlobalLimit = $effectiveToolLimit
        SearchTextGlobalLimit = $SearchTextGlobalCharLimit
    }
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
    $isClaudeSource = [string]$SourceType -in @('local-claude', 'webdav-claude')
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
        [string]$OtherSearchPath,
        [string]$CachePath
    )

    foreach ($path in @($HtmlPath, $DataPath, $SearchPath, $OtherSearchPath, $CachePath)) {
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
    if (
        -not $Cached -or
        -not ($Session.PSObject.Properties.Name -contains 'QuestionSearchTexts') -or
        -not ($Session.PSObject.Properties.Name -contains 'OtherSearchBaseText') -or
        -not ($Session.PSObject.Properties.Name -contains 'ToolRawSearchText')
    ) {
        [void](Set-SessionSearchFields $Session)
    }
    $Session | Add-Member -NotePropertyName Cached -NotePropertyValue $Cached -Force
    return $Session
}

function Complete-ParsedSessionForBuild {
    param(
        $Session,
        [System.IO.FileInfo]$File,
        [string]$DetailFileName,
        [string]$DetailRoot,
        [string]$SourceId,
        [bool]$DeferDetailWrite
    )
    $runtimeSession = Add-SessionRuntimeFields -Session $Session -File $File -DetailFileName $DetailFileName -Cached $false -SourceId $SourceId
    if ($DeferDetailWrite) { return $runtimeSession }

    $detailPayload = [ordered]@{
        id = $runtimeSession.Id
        sourceId = [string]$runtimeSession.SourceId
        title = $runtimeSession.Title
        path = $runtimeSession.Path
        cwd = $runtimeSession.Cwd
        fileUri = $runtimeSession.FileUri
        createdLocal = $runtimeSession.CreatedLocal
        updatedLocal = $runtimeSession.UpdatedLocal
        userCount = $runtimeSession.UserCount
        assistantCount = $runtimeSession.AssistantCount
        events = @($runtimeSession.Events)
    }
    Write-Utf8FileAtomic -Path (Join-Path $DetailRoot $DetailFileName) -Value ($detailPayload | ConvertTo-Json -Depth 100)
    $runtimeSession.Events = $null
    $runtimeSession.Cached = $true
    return $runtimeSession
}

function New-SessionFromCacheRecord {
    param($Record)
    if ($null -eq $Record) { return $null }
    $otherBaseText = [string]$Record.otherBaseText
    $toolRawText = [string]$Record.toolRawText
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
        QuestionSearchTexts = @($Record.questionTexts | ForEach-Object { [string]$_ })
        OtherSearchBaseText = $otherBaseText
        ToolRawSearchText = $toolRawText
        OtherSearchText = (@($otherBaseText, $toolRawText) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
        ToolRawSearchOriginalChars = [int64]$Record.toolRawOriginalChars
        ToolRawSearchTruncatedEvents = [int]$Record.toolRawTruncatedEvents
        Cached = $true
        Events = $null
    }
}

function New-CacheRecordFromSession {
    param($Session)
    if (
        -not ($Session.PSObject.Properties.Name -contains 'QuestionSearchTexts') -or
        -not ($Session.PSObject.Properties.Name -contains 'OtherSearchBaseText') -or
        -not ($Session.PSObject.Properties.Name -contains 'ToolRawSearchText')
    ) {
        [void](Set-SessionSearchFields $Session)
    }
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
        questionTexts = @($Session.QuestionSearchTexts)
        otherBaseText = [string]$Session.OtherSearchBaseText
        toolRawText = [string]$Session.ToolRawSearchText
        toolRawOriginalChars = [int64]$Session.ToolRawSearchOriginalChars
        toolRawTruncatedEvents = [int]$Session.ToolRawSearchTruncatedEvents
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
        if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($name)) {
            return $Object[$name]
        }
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
        $images = @(Get-ClaudeMessageContentImages $content)
        if ([string]::IsNullOrWhiteSpace($messageText) -and $content -is [string]) { $messageText = [string]$content }
        if ([string]::IsNullOrWhiteSpace($messageText) -and $images.Count -gt 0) { $messageText = '[图片]' }
        if (-not [string]::IsNullOrWhiteSpace($messageText) -or $images.Count -gt 0) {
            if ([string]::IsNullOrWhiteSpace($firstUserMessage)) { $firstUserMessage = $messageText }
            $events.Add((New-ReaderEvent `
                -Kind 'user' `
                -Timestamp (Convert-ToUtcIsoText $timestamp) `
                -TimestampLocal (Convert-ToLocalTimeText $timestamp) `
                -TurnId $sessionId `
                -Role 'user' `
                -Summary (Get-ShortText $messageText 160) `
                -RawText ($messageText.TrimEnd()) `
                -RenderMode 'plain_text' `
                -Images $images))
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

    Add-ResolvedUserEventImages -Events $events -Cwd $cwd -SessionId $sessionId
    $hasImageReference = @($events | Where-Object { $_.kind -eq 'user' -and (Test-ReaderEventHasImages $_) }).Count -gt 0

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
        HasImageReference = $hasImageReference
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

    Add-ResolvedUserEventImages -Events $events -Cwd $cwd -SessionId $sessionId
    $hasImageReference = @($events | Where-Object { $_.kind -eq 'user' -and (Test-ReaderEventHasImages $_) }).Count -gt 0

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
        HasImageReference = $hasImageReference
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
                $images = @(Get-ClaudeMessageContentImages $content)
                if ([string]::IsNullOrWhiteSpace($messageText) -and $content -is [string]) { $messageText = [string]$content }
                if ([string]::IsNullOrWhiteSpace($messageText) -and $images.Count -gt 0) { $messageText = '[图片]' }
                if (-not [string]::IsNullOrWhiteSpace($messageText) -or $images.Count -gt 0) {
                    if ([string]::IsNullOrWhiteSpace($firstUserMessage)) { $firstUserMessage = $messageText }
                    $events.Add((New-ReaderEvent `
                        -Kind 'user' `
                        -Timestamp (Convert-ToUtcIsoText $timestamp) `
                        -TimestampLocal (Convert-ToLocalTimeText $timestamp) `
                        -TurnId $id `
                        -Role 'user' `
                        -Summary (Get-ShortText $messageText 160) `
                        -RawText ($messageText.TrimEnd()) `
                        -RenderMode 'plain_text' `
                        -Images $images))
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

    Add-ResolvedUserEventImages -Events $events -Cwd $cwd -SessionId $id
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
    $hasImageReference = @($userEvents | Where-Object { Test-ReaderEventHasImages $_ }).Count -gt 0

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

function Read-CodexSessionV030Fallback {
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
                $cleanedMessage = Remove-CodexInjectedContextPrefix -RawText $message
                $messageText = ([string]$cleanedMessage.Text).Trim()
                if ([string]::IsNullOrWhiteSpace($messageText) -and $images.Count -gt 0) {
                    $messageText = "[图片]"
                }
                if (-not [string]::IsNullOrWhiteSpace($messageText) -or $images.Count -gt 0) {
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
                        -Summary (Get-ShortText $messageText 160) `
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
                $cleanedMessage = Remove-CodexInjectedContextPrefix -RawText $message
                $messageText = ([string]$cleanedMessage.Text).Trim()
                if ([string]::IsNullOrWhiteSpace($messageText)) { continue }
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
                    -Summary (Get-ShortText $messageText 160) `
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

    Add-ResolvedUserEventImages -Events $events -Cwd $cwd -SessionId $id
    $userEvents = @($events | Where-Object { $_.kind -eq 'user' })
    $assistantEvents = @($events | Where-Object { $_.kind -in @('assistant_commentary','assistant_final') })
    if ($userEvents.Count -eq 0 -and $assistantEvents.Count -eq 0) {
        return New-SkippedReaderSession 'empty-after-context-filter'
    }
    $userCount = $userEvents.Count
    $assistantCount = $assistantEvents.Count
    $firstUserMessage = if ($userEvents.Count -gt 0) { [string]$userEvents[0].rawText } else { "" }
    $hasImageReference = @($userEvents | Where-Object { Test-ReaderEventHasImages $_ }).Count -gt 0

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

function Read-CodexSession {
    param([System.IO.FileInfo]$File)

    $fileStem = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    $id = $fileStem -replace '^rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-', ''
    $idLockedToFile = $id -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $cwd = '(未知工作目录)'
    $createdAt = ''
    $updatedAt = ''
    $source = ''
    $modelProvider = ''
    $cliVersion = ''
    $sessionMetaSeen = $false
    $recognizedCodexRecordSeen = $false
    $currentTurnId = ''
    $rawLineOrdinal = 0
    $unassignedRecordCount = 0
    $unrecognizedRecordCount = 0
    $candidateEvents = [System.Collections.Generic.List[object]]::new()
    $assistantWrappers = [System.Collections.Generic.List[object]]::new()
    $assistantWrappersByOrdinal = @{}
    $userDedupeBarrierOrdinals = [System.Collections.Generic.HashSet[int]]::new()
    $customCalls = [System.Collections.Generic.List[object]]::new()
    $customCallsByTurn = @{}
    $pendingCustomCalls = @{}
    $pendingTools = @{}
    $taskByTurn = @{}
    $taskOrder = [System.Collections.Generic.List[string]]::new()
    $effectiveTurnOrder = [System.Collections.Generic.List[string]]::new()
    $rolledBackTurns = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

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
            $rawLineOrdinal++
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $entry = $line | ConvertFrom-Json -Depth 100
            } catch {
                continue
            }

            if ($entry.timestamp) { $updatedAt = $entry.timestamp }
            if ($entry.type -eq 'session_meta') {
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
                [void]$userDedupeBarrierOrdinals.Add($rawLineOrdinal)
                $turnsToRemove = if ($null -ne $entry.payload.num_turns) { [int]$entry.payload.num_turns } else { 0 }
                while ($turnsToRemove -gt 0 -and $effectiveTurnOrder.Count -gt 0) {
                    $lastIndex = $effectiveTurnOrder.Count - 1
                    $turnIdToRemove = [string]$effectiveTurnOrder[$lastIndex]
                    $effectiveTurnOrder.RemoveAt($lastIndex)
                    if (-not [string]::IsNullOrWhiteSpace($turnIdToRemove)) { [void]$rolledBackTurns.Add($turnIdToRemove) }
                    $turnsToRemove--
                }
                $currentTurnId = if ($effectiveTurnOrder.Count -gt 0) { [string]$effectiveTurnOrder[$effectiveTurnOrder.Count - 1] } else { '' }
                continue
            }

            $allowCurrentFallback = $entry.type -eq 'event_msg' -and
                $entry.payload.type -in @('user_message', 'agent_message', 'exec_command_end', 'function_call_output', 'mcp_tool_call_end', 'patch_apply_end', 'token_count')
            $entryTurnId = Get-CodexEntryTurnId -Entry $entry -CurrentTurnId $currentTurnId -AllowCurrentTurnFallback:$allowCurrentFallback
            if (
                $entry.type -in @('response_item', 'custom_tool_call', 'custom_tool_call_output') -and
                [string]::IsNullOrWhiteSpace($entryTurnId)
            ) { $unassignedRecordCount++ }

            $isUserDedupeBarrier =
                ($entry.type -eq 'event_msg' -and $entry.payload.type -in @('task_started', 'task_complete', 'user_message', 'agent_message', 'exec_command_end', 'function_call_output', 'mcp_tool_call_end', 'patch_apply_end')) -or
                ($entry.type -eq 'response_item' -and $entry.payload.type -in @('message', 'function_call')) -or
                $entry.type -in @('custom_tool_call', 'custom_tool_call_output') -or
                ($entry.type -eq 'response_item' -and $entry.payload.type -in @('custom_tool_call', 'custom_tool_call_output'))
            if ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'item_completed') {
                $completedItemType = [string]$entry.payload.item.type
                if ($completedItemType -notin @('Reasoning', 'ContextCompaction')) { $isUserDedupeBarrier = $true }
            }
            if ($isUserDedupeBarrier) { [void]$userDedupeBarrierOrdinals.Add($rawLineOrdinal) }

            if ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'task_started') {
                $recognizedCodexRecordSeen = $true
                if (-not [string]::IsNullOrWhiteSpace($entryTurnId)) {
                    $currentTurnId = $entryTurnId
                    if ($effectiveTurnOrder.Count -eq 0 -or [string]$effectiveTurnOrder[$effectiveTurnOrder.Count - 1] -ne $entryTurnId) {
                        $effectiveTurnOrder.Add($entryTurnId)
                    }
                    if (-not $taskByTurn.ContainsKey($entryTurnId)) {
                        $taskByTurn[$entryTurnId] = [pscustomobject]@{
                            TurnId = $entryTurnId
                            StartedUtc = $null
                            CompletedUtc = $null
                            TurnUuidUtc = ConvertFrom-CodexUuidV7Time $entryTurnId
                            LastAgentMessage = ''
                            StartOrdinal = $rawLineOrdinal
                            CompleteOrdinal = 0
                        }
                        $taskOrder.Add($entryTurnId)
                    }
                    $taskByTurn[$entryTurnId].StartedUtc = ConvertFrom-CodexUnixTime $entry.payload.started_at
                    $taskByTurn[$entryTurnId].StartOrdinal = $rawLineOrdinal
                }
            }

            if ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'task_complete' -and -not [string]::IsNullOrWhiteSpace($entryTurnId)) {
                $recognizedCodexRecordSeen = $true
                if (-not $taskByTurn.ContainsKey($entryTurnId)) {
                    $taskByTurn[$entryTurnId] = [pscustomobject]@{
                        TurnId = $entryTurnId
                        StartedUtc = ConvertFrom-CodexUnixTime $entry.payload.started_at
                        CompletedUtc = $null
                        TurnUuidUtc = ConvertFrom-CodexUuidV7Time $entryTurnId
                        LastAgentMessage = ''
                        StartOrdinal = 0
                        CompleteOrdinal = $rawLineOrdinal
                    }
                    $taskOrder.Add($entryTurnId)
                }
                if ($null -eq $taskByTurn[$entryTurnId].StartedUtc) {
                    $taskByTurn[$entryTurnId].StartedUtc = ConvertFrom-CodexUnixTime $entry.payload.started_at
                }
                $taskByTurn[$entryTurnId].CompletedUtc = ConvertFrom-CodexUnixTime $entry.payload.completed_at
                $taskByTurn[$entryTurnId].LastAgentMessage = [string]$entry.payload.last_agent_message
                $taskByTurn[$entryTurnId].CompleteOrdinal = $rawLineOrdinal
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

            if ($entry.type -eq 'response_item' -and $entry.payload.type -eq 'message') {
                $recognizedCodexRecordSeen = $true
                $metadata = $entry.payload.internal_chat_message_metadata_passthrough
                $createTime = Get-ObjectPropertyValue $metadata @('create_time')
                $role = [string]$entry.payload.role
                $messageId = [string]$entry.payload.id
                $message = Get-CodexMessageContentText $entry.payload.content
                if ($role -eq 'user') {
                    $images = @(Get-CodexMessageContentImages $entry.payload.content)
                    $cleanedMessage = Remove-CodexInjectedContextPrefix -RawText $message
                    $messageText = ([string]$cleanedMessage.Text).Trim()
                    if ([string]::IsNullOrWhiteSpace($messageText) -and $images.Count -gt 0) { $messageText = '[图片]' }
                    if (-not [string]::IsNullOrWhiteSpace($messageText) -or $images.Count -gt 0) {
                        $event = New-ReaderEvent -Kind 'user' -Timestamp '' -TimestampLocal '' -TurnId $entryTurnId -Role 'user' `
                            -Summary (Get-ShortText $messageText 160) -RawText $messageText -RenderMode 'plain_text' -Images $images
                        $candidateEvents.Add((New-CodexEventCandidate -Event $event -RawLineOrdinal $rawLineOrdinal `
                            -WrapperSource 'response_item_user' -StableItemId $messageId -TopTimestamp $entry.timestamp `
                            -CreateTime $createTime -UserMessageId $messageId))
                    }
                } elseif ($role -eq 'assistant') {
                    $assistantWrapper = [pscustomobject]@{
                        RawLineOrdinal = $rawLineOrdinal
                        TurnId = $entryTurnId
                        StableItemId = $messageId
                        Phase = [string]$entry.payload.phase
                        RawText = $message.TrimEnd()
                    }
                    $assistantWrappers.Add($assistantWrapper)
                    $assistantWrappersByOrdinal[$rawLineOrdinal] = $assistantWrapper
                }
                continue
            }

            if ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'agent_message') {
                $recognizedCodexRecordSeen = $true
                $phase = [string]$entry.payload.phase
                $message = [string]$entry.payload.message
                if ([string]::IsNullOrWhiteSpace($message)) { continue }
                $kind = if ($phase -eq 'commentary') { 'assistant_commentary' } else { 'assistant_final' }
                $renderMode = if ($kind -eq 'assistant_final') { 'deterministic_markdown' } else { 'plain_text' }
                $event = New-ReaderEvent -Kind $kind -Timestamp '' -TimestampLocal '' -TurnId $entryTurnId -Phase $phase `
                    -Role 'assistant' -Summary (Get-ShortText $message 160) -RawText ($message.TrimEnd()) `
                    -RenderMode $renderMode -GroupKey $entryTurnId
                $candidateEvents.Add((New-CodexEventCandidate -Event $event -RawLineOrdinal $rawLineOrdinal `
                    -WrapperSource 'legacy_agent_message' -TopTimestamp $entry.timestamp))
                continue
            }

            if ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'user_message') {
                $recognizedCodexRecordSeen = $true
                $cleanedMessage = Remove-CodexInjectedContextPrefix -RawText ([string]$entry.payload.message)
                $messageText = ([string]$cleanedMessage.Text).Trim()
                if ([string]::IsNullOrWhiteSpace($messageText)) { continue }
                $event = New-ReaderEvent -Kind 'user' -Timestamp '' -TimestampLocal '' -TurnId $entryTurnId -Role 'user' `
                    -Summary (Get-ShortText $messageText 160) -RawText $messageText -RenderMode 'plain_text'
                $candidateEvents.Add((New-CodexEventCandidate -Event $event -RawLineOrdinal $rawLineOrdinal `
                    -WrapperSource 'legacy_user_message' -TopTimestamp $entry.timestamp))
                continue
            }

            if ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'item_completed') {
                $recognizedCodexRecordSeen = $true
                $item = $entry.payload.item
                $itemType = [string]$item.type
                $itemId = [string]$item.id
                $itemStartedAt = $entry.payload.started_at_ms
                $itemCompletedAt = $entry.payload.completed_at_ms
                if ($itemType -eq 'AgentMessage') {
                    $phase = [string]$item.phase
                    if ($phase -notin @('commentary', 'final_answer')) {
                        $unrecognizedRecordCount++
                        continue
                    }
                    $message = Get-CodexContentText $item.content
                    if ([string]::IsNullOrWhiteSpace($message)) { continue }
                    $kind = if ($phase -eq 'commentary') { 'assistant_commentary' } else { 'assistant_final' }
                    $renderMode = if ($kind -eq 'assistant_final') { 'deterministic_markdown' } else { 'plain_text' }
                    $event = New-ReaderEvent -Kind $kind -Timestamp '' -TimestampLocal '' -TurnId $entryTurnId -Phase $phase `
                        -Role 'assistant' -Summary (Get-ShortText $message 160) -RawText ($message.TrimEnd()) `
                        -RenderMode $renderMode -GroupKey $entryTurnId
                    $candidateEvents.Add((New-CodexEventCandidate -Event $event -RawLineOrdinal $rawLineOrdinal `
                        -WrapperSource 'completed_item_message' -StableItemId $itemId -TopTimestamp $entry.timestamp `
                        -ItemStartedAt $itemStartedAt -ItemCompletedAt $itemCompletedAt))
                    continue
                }
                if ($itemType -eq 'UserMessage') {
                    $message = Get-CodexContentText $item.content
                    $images = @(Get-CodexMessageContentImages $item.content)
                    $cleanedMessage = Remove-CodexInjectedContextPrefix -RawText $message
                    $messageText = ([string]$cleanedMessage.Text).Trim()
                    if ([string]::IsNullOrWhiteSpace($messageText) -and $images.Count -gt 0) { $messageText = '[图片]' }
                    if (-not [string]::IsNullOrWhiteSpace($messageText) -or $images.Count -gt 0) {
                        $event = New-ReaderEvent -Kind 'user' -Timestamp '' -TimestampLocal '' -TurnId $entryTurnId -Role 'user' `
                            -Summary (Get-ShortText $messageText 160) -RawText $messageText -RenderMode 'plain_text' -Images $images
                        $candidateEvents.Add((New-CodexEventCandidate -Event $event -RawLineOrdinal $rawLineOrdinal `
                            -WrapperSource 'completed_item_user' -StableItemId $itemId -TopTimestamp $entry.timestamp `
                            -ItemStartedAt $itemStartedAt -ItemCompletedAt $itemCompletedAt -UserMessageId $itemId))
                    }
                    continue
                }
                if ($itemType -eq 'CommandExecution') {
                    $commandValue = Get-ObjectPropertyValue $item @('command')
                    $commandText = if ($commandValue -is [array]) {
                        (@($commandValue) | ForEach-Object { [string]$_ }) -join ' '
                    } elseif (-not [string]::IsNullOrWhiteSpace([string]$commandValue)) {
                        [string]$commandValue
                    } else {
                        Convert-ToCompactJsonText (Get-ObjectPropertyValue $item @('parsed_cmd'))
                    }
                    $status = [string]$item.status
                    if ([string]::IsNullOrWhiteSpace($status) -and $null -ne $item.exit_code) {
                        $status = if ([int]$item.exit_code -eq 0) { 'completed' } else { 'failed' }
                    }
                    $outputParts = [System.Collections.Generic.List[string]]::new()
                    $aggregate = [string]$item.aggregated_output
                    if (-not [string]::IsNullOrWhiteSpace($aggregate)) { $outputParts.Add($aggregate) }
                    foreach ($value in @([string]$item.stdout, [string]$item.stderr)) {
                        if ([string]::IsNullOrWhiteSpace($value)) { continue }
                        if ($outputParts.Count -eq 0 -or -not (($outputParts -join "`n").Contains($value))) { $outputParts.Add($value) }
                    }
                    if ($outputParts.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$item.formatted_output)) {
                        $outputParts.Add([string]$item.formatted_output)
                    }
                    $previewSource = @(
                        [string]$item.formatted_output,
                        [string]$item.aggregated_output,
                        [string]$item.stdout,
                        [string]$item.stderr
                    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1
                    $resultPreview = Get-ShortText ([string]$previewSource) 120
                    $summaryParts = @((Get-ShortText $commandText 120), $status)
                    if ($null -ne $item.exit_code) { $summaryParts += 'exit=' + [string]$item.exit_code }
                    if ($null -ne $item.duration) { $summaryParts += 'duration=' + [string]$item.duration }
                    if (-not [string]::IsNullOrWhiteSpace($resultPreview)) { $summaryParts += $resultPreview }
                    $event = New-ReaderEvent -Kind 'tool' -Timestamp '' -TimestampLocal '' -TurnId $entryTurnId `
                        -CallId $itemId -ToolName 'exec_command' -Status $status -Summary (($summaryParts | Where-Object { $_ }) -join ' | ') `
                        -RawText (@($outputParts) -join "`n`n") -RenderMode 'tool_output' -GroupKey $itemId
                    $candidateEvents.Add((New-CodexEventCandidate -Event $event -RawLineOrdinal $rawLineOrdinal `
                        -WrapperSource 'completed_item_tool' -StableItemId $itemId -TopTimestamp $entry.timestamp `
                        -ItemStartedAt $itemStartedAt -ItemCompletedAt $itemCompletedAt -AuthoritativeTool))
                    continue
                }
                if ($itemType -eq 'DynamicToolCall') {
                    $namespace = [string]$item.namespace
                    $tool = [string]$item.tool
                    $toolName = if (-not [string]::IsNullOrWhiteSpace($namespace) -and -not [string]::IsNullOrWhiteSpace($tool)) {
                        $namespace + '.' + $tool
                    } elseif (-not [string]::IsNullOrWhiteSpace($tool)) { $tool } else { 'dynamic_tool' }
                    $status = [string]$item.status
                    if ([string]::IsNullOrWhiteSpace($status) -and $null -ne $item.success) {
                        $status = if ([bool]$item.success) { 'completed' } else { 'failed' }
                    }
                    $arguments = Convert-ToCompactJsonText $item.arguments
                    $contentText = Get-CodexOutputSequenceText $item.content_items
                    $rawParts = [System.Collections.Generic.List[string]]::new()
                    if (-not [string]::IsNullOrWhiteSpace($arguments)) { $rawParts.Add("Arguments:`n" + $arguments) }
                    if (-not [string]::IsNullOrWhiteSpace($contentText)) { $rawParts.Add("Output:`n" + $contentText) }
                    $event = New-ReaderEvent -Kind 'tool' -Timestamp '' -TimestampLocal '' -TurnId $entryTurnId `
                        -CallId $itemId -ToolName $toolName -Status $status `
                        -Summary (Get-ShortText ($toolName + ' | ' + $status + ' | ' + $arguments) 220) `
                        -RawText (@($rawParts) -join "`n`n") -RenderMode 'tool_output' -GroupKey $itemId
                    $candidateEvents.Add((New-CodexEventCandidate -Event $event -RawLineOrdinal $rawLineOrdinal `
                        -WrapperSource 'completed_item_tool' -StableItemId $itemId -TopTimestamp $entry.timestamp `
                        -ItemStartedAt $itemStartedAt -ItemCompletedAt $itemCompletedAt -AuthoritativeTool))
                    continue
                }
                if ($itemType -eq 'ImageView') {
                    $path = [string]$item.path
                    $summary = if ([string]::IsNullOrWhiteSpace($path)) { 'view_image | completed' } else { 'view_image | completed | ' + $path }
                    $event = New-ReaderEvent -Kind 'tool' -Timestamp '' -TimestampLocal '' -TurnId $entryTurnId `
                        -CallId $itemId -ToolName 'view_image' -Status 'completed' -Summary (Get-ShortText $summary 220) `
                        -RawText $path -RenderMode 'tool_output' -GroupKey $itemId
                    $candidateEvents.Add((New-CodexEventCandidate -Event $event -RawLineOrdinal $rawLineOrdinal `
                        -WrapperSource 'completed_item_tool' -StableItemId $itemId -TopTimestamp $entry.timestamp `
                        -ItemStartedAt $itemStartedAt -ItemCompletedAt $itemCompletedAt -AuthoritativeTool))
                    continue
                }
                if ($itemType -notin @('Reasoning', 'ContextCompaction')) { $unrecognizedRecordCount++ }
                continue
            }

            $isCustomToolCall = $entry.type -eq 'custom_tool_call' -or
                ($entry.type -eq 'response_item' -and $entry.payload.type -eq 'custom_tool_call')
            if ($isCustomToolCall) {
                $recognizedCodexRecordSeen = $true
                $metadata = $entry.payload.internal_chat_message_metadata_passthrough
                $customCall = [pscustomobject]@{
                    CallId = [string]$entry.payload.call_id
                    TurnId = $entryTurnId
                    Name = [string]$entry.payload.name
                    Input = Get-ObjectPropertyValue $entry.payload @('input')
                    Output = $null
                    StartOrdinal = $rawLineOrdinal
                    EndOrdinal = 0
                    StartTop = $entry.timestamp
                    EndTop = $null
                    StartCreate = Get-ObjectPropertyValue $metadata @('create_time')
                    EndCreate = $null
                    SuppressFallback = $false
                }
                $customCalls.Add($customCall)
                if (-not $customCallsByTurn.ContainsKey($entryTurnId)) {
                    $customCallsByTurn[$entryTurnId] = [System.Collections.Generic.List[object]]::new()
                }
                $customCallsByTurn[$entryTurnId].Add($customCall)
                $pendingKey = $entryTurnId + '|' + [string]$entry.payload.call_id
                if (-not $pendingCustomCalls.ContainsKey($pendingKey)) {
                    $pendingCustomCalls[$pendingKey] = [System.Collections.Generic.List[object]]::new()
                }
                $pendingCustomCalls[$pendingKey].Add($customCall)
                continue
            }

            $isCustomToolOutput = $entry.type -eq 'custom_tool_call_output' -or
                ($entry.type -eq 'response_item' -and $entry.payload.type -eq 'custom_tool_call_output')
            if ($isCustomToolOutput) {
                $recognizedCodexRecordSeen = $true
                $matchedCustomOutput = $false
                if (-not [string]::IsNullOrWhiteSpace($entryTurnId)) {
                    $pendingKey = $entryTurnId + '|' + [string]$entry.payload.call_id
                    if ($pendingCustomCalls.ContainsKey($pendingKey)) {
                        $pendingList = $pendingCustomCalls[$pendingKey]
                        for ($pendingIndex = $pendingList.Count - 1; $pendingIndex -ge 0; $pendingIndex--) {
                            $matchingCall = $pendingList[$pendingIndex]
                            if ([int]$matchingCall.EndOrdinal -ne 0) { continue }
                            $matchingCall.Output = Get-ObjectPropertyValue $entry.payload @('output')
                            $matchingCall.EndOrdinal = $rawLineOrdinal
                            $matchingCall.EndTop = $entry.timestamp
                            $matchingCall.EndCreate = Get-ObjectPropertyValue $entry.payload.internal_chat_message_metadata_passthrough @('create_time')
                            $pendingList.RemoveAt($pendingIndex)
                            if ($pendingList.Count -eq 0) { [void]$pendingCustomCalls.Remove($pendingKey) }
                            $matchedCustomOutput = $true
                            break
                        }
                    }
                }
                if (-not $matchedCustomOutput) { $unrecognizedRecordCount++ }
                continue
            }

            if ($entry.type -eq 'event_msg' -and $entry.payload.type -in @('exec_command_end', 'function_call_output', 'mcp_tool_call_end', 'patch_apply_end')) {
                $recognizedCodexRecordSeen = $true
                $toolInfo = $pendingTools[[string]$entry.payload.call_id]
                $toolName = if ($null -ne $toolInfo -and $toolInfo.toolName) { [string]$toolInfo.toolName } else { [string]$entry.payload.name }
                $resultSummary = Get-CommandResultSummary $entry.payload
                $toolSummary = if ($null -ne $toolInfo -and -not [string]::IsNullOrWhiteSpace([string]$toolInfo.summary)) {
                    Get-ShortText ($toolInfo.summary + ' | ' + $resultSummary) 220
                } else { $resultSummary }
                $event = New-ReaderEvent -Kind 'tool' -Timestamp '' -TimestampLocal '' -TurnId $entryTurnId `
                    -CallId ([string]$entry.payload.call_id) -ToolName $toolName -Status ([string]$entry.payload.status) `
                    -Summary $toolSummary -RawText ([string]$entry.payload.aggregated_output) `
                    -RenderMode 'tool_output' -GroupKey ([string]$entry.payload.call_id)
                $candidateEvents.Add((New-CodexEventCandidate -Event $event -RawLineOrdinal $rawLineOrdinal `
                    -WrapperSource 'legacy_tool_result' -TopTimestamp $entry.timestamp))
                continue
            }

            if ($entry.type -eq 'event_msg' -and $entry.payload.type -in @('task_started', 'task_complete', 'token_count')) {
                $recognizedCodexRecordSeen = $true
                $event = New-ReaderEvent -Kind 'system' -Timestamp '' -TimestampLocal '' -TurnId $entryTurnId `
                    -Summary ([string]$entry.payload.type) -RawText ($entry.payload | ConvertTo-Json -Depth 20 -Compress) `
                    -RenderMode 'system_meta'
                $candidateEvents.Add((New-CodexEventCandidate -Event $event -RawLineOrdinal $rawLineOrdinal `
                    -WrapperSource ('system_' + [string]$entry.payload.type) -TopTimestamp $entry.timestamp))
                if ($entry.payload.type -eq 'task_complete' -and $entryTurnId -eq $currentTurnId) { $currentTurnId = '' }
                continue
            }
        }
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
    }

    if (-not $recognizedCodexRecordSeen) {
        return Read-CodexSessionV030Fallback $File
    }

    $authoritativeToolsByTurn = @{}
    foreach ($candidate in @($candidateEvents)) {
        if (-not $candidate.AuthoritativeTool) { continue }
        $turnId = [string]$candidate.Event.turnId
        if ([string]::IsNullOrWhiteSpace($turnId)) { continue }
        if (-not $authoritativeToolsByTurn.ContainsKey($turnId)) {
            $authoritativeToolsByTurn[$turnId] = [System.Collections.Generic.List[object]]::new()
        }
        $authoritativeToolsByTurn[$turnId].Add($candidate)
    }
    foreach ($turnId in @($customCallsByTurn.Keys)) {
        if (-not $authoritativeToolsByTurn.ContainsKey($turnId)) { continue }
        $intervals = @($customCallsByTurn[$turnId] | Where-Object { [int]$_.EndOrdinal -gt 0 } | Sort-Object StartOrdinal)
        if ($intervals.Count -eq 0) { continue }
        $activeIntervals = [System.Collections.Generic.List[object]]::new()
        $intervalIndex = 0
        foreach ($authoritative in @($authoritativeToolsByTurn[$turnId] | Sort-Object RawLineOrdinal)) {
            $ordinal = [int]$authoritative.RawLineOrdinal
            while ($intervalIndex -lt $intervals.Count -and [int]$intervals[$intervalIndex].StartOrdinal -le $ordinal) {
                $activeIntervals.Add($intervals[$intervalIndex])
                $intervalIndex++
            }
            for ($activeIndex = $activeIntervals.Count - 1; $activeIndex -ge 0; $activeIndex--) {
                if ([int]$activeIntervals[$activeIndex].EndOrdinal -lt $ordinal) { $activeIntervals.RemoveAt($activeIndex) }
            }
            $owner = $null
            $ownerSpan = [int]::MaxValue
            foreach ($interval in @($activeIntervals)) {
                if ([int]$interval.StartOrdinal -gt $ordinal -or [int]$interval.EndOrdinal -lt $ordinal) { continue }
                $span = [int]$interval.EndOrdinal - [int]$interval.StartOrdinal
                if ($null -eq $owner -or $span -lt $ownerSpan -or ($span -eq $ownerSpan -and [int]$interval.StartOrdinal -gt [int]$owner.StartOrdinal)) {
                    $owner = $interval
                    $ownerSpan = $span
                }
            }
            if ($null -ne $owner) { $owner.SuppressFallback = $true }
        }
    }

    foreach ($custom in @($customCalls)) {
        if ([string]::IsNullOrWhiteSpace([string]$custom.TurnId)) { continue }
        if ([bool]$custom.SuppressFallback) { continue }
        $inputText = if ($custom.Input -is [string]) { [string]$custom.Input } else { Convert-ToCompactJsonText $custom.Input }
        $outputText = Get-CodexOutputSequenceText $custom.Output
        $rawParts = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($inputText)) { $rawParts.Add("Input:`n" + $inputText) }
        if (-not [string]::IsNullOrWhiteSpace($outputText)) { $rawParts.Add("Output:`n" + $outputText) }
        $status = if ([int]$custom.EndOrdinal -gt 0) { 'completed' } else { 'unknown' }
        $toolName = if ([string]::IsNullOrWhiteSpace([string]$custom.Name)) { 'custom_tool' } else { [string]$custom.Name }
        $event = New-ReaderEvent -Kind 'tool' -Timestamp '' -TimestampLocal '' -TurnId $custom.TurnId `
            -CallId ([string]$custom.CallId) -ToolName $toolName -Status $status `
            -Summary (Get-ShortText ($toolName + ' | ' + $status + ' | ' + $inputText) 220) `
            -RawText (@($rawParts) -join "`n`n") -RenderMode 'tool_output' -GroupKey ([string]$custom.CallId)
        $candidateEvents.Add((New-CodexEventCandidate -Event $event -RawLineOrdinal ([int]$custom.StartOrdinal) `
            -WrapperSource 'custom_tool_fallback' -StableItemId ([string]$custom.CallId) `
            -TopTimestamp $(if ($null -ne $custom.EndTop) { $custom.EndTop } else { $custom.StartTop }) `
            -CreateTime $(if ($null -ne $custom.EndCreate) { $custom.EndCreate } else { $custom.StartCreate })))
    }

    $orderedCandidates = @($candidateEvents | Where-Object {
        [string]::IsNullOrWhiteSpace([string]$_.Event.turnId) -or -not $rolledBackTurns.Contains([string]$_.Event.turnId)
    } | Sort-Object RawLineOrdinal)
    $deduped = [System.Collections.Generic.List[object]]::new()
    $seenStableToolKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($candidate in $orderedCandidates) {
        $event = $candidate.Event
        $merged = $false
        if ([string]$event.kind -eq 'user') {
            for ($index = $deduped.Count - 1; $index -ge 0 -and $index -ge $deduped.Count - 100; $index--) {
                $existing = $deduped[$index]
                if ([string]$existing.Event.kind -ne 'user') { continue }
                $sameStableId = -not [string]::IsNullOrWhiteSpace($candidate.StableItemId) -and $candidate.StableItemId -eq $existing.StableItemId
                $sameText = (Get-NormalizedUserMessageSignature ([string]$candidate.Event.rawText)) -eq
                    (Get-NormalizedUserMessageSignature ([string]$existing.Event.rawText))
                $sameTurn = [string]$candidate.Event.turnId -eq [string]$existing.Event.turnId
                $crossWrapper = [string]$candidate.WrapperSource -ne [string]$existing.WrapperSource
                $low = [Math]::Min([int]$candidate.RawLineOrdinal, [int]$existing.RawLineOrdinal)
                $high = [Math]::Max([int]$candidate.RawLineOrdinal, [int]$existing.RawLineOrdinal)
                $tightPair = Test-CodexUserCandidateIntervalSafe -BarrierOrdinals $userDedupeBarrierOrdinals -LowOrdinal $low -HighOrdinal $high
                $sameResponseWrapper = $candidate.WrapperSource -eq 'response_item_user' -and $existing.WrapperSource -eq 'response_item_user'
                $sameTopTimestamp = $null -ne $candidate.TopUtc -and $null -ne $existing.TopUtc -and $candidate.TopUtc -eq $existing.TopUtc
                $sameResponseDuplicate = $sameResponseWrapper -and $tightPair -and $sameTopTimestamp
                if (-not ($sameStableId -or ($sameText -and $sameTurn -and (($crossWrapper -and $tightPair) -or $sameResponseDuplicate)))) { continue }

                $preferred = if ($candidate.WrapperSource -eq 'response_item_user') { $candidate } elseif ($existing.WrapperSource -eq 'response_item_user') { $existing } else { $existing }
                $metadata = if ($candidate.WrapperSource -eq 'completed_item_user') { $candidate } elseif ($existing.WrapperSource -eq 'completed_item_user') { $existing } else { $candidate }
                if (-not [string]::IsNullOrWhiteSpace($metadata.StableItemId)) { $preferred.StableItemId = $metadata.StableItemId }
                if ($null -ne $metadata.ItemStartedUtc) { $preferred.ItemStartedUtc = $metadata.ItemStartedUtc }
                if ($null -ne $metadata.ItemCompletedUtc) { $preferred.ItemCompletedUtc = $metadata.ItemCompletedUtc }
                if ($null -ne $metadata.CreateUtc) { $preferred.CreateUtc = $metadata.CreateUtc }
                if ($null -ne $metadata.UserUuidUtc) { $preferred.UserUuidUtc = $metadata.UserUuidUtc }
                if (-not [string]::IsNullOrWhiteSpace([string]$metadata.Event.turnId)) {
                    $preferred.Event.turnId = [string]$metadata.Event.turnId
                }
                $preferred.RawLineOrdinal = [Math]::Min([int]$candidate.RawLineOrdinal, [int]$existing.RawLineOrdinal)
                $deduped[$index] = $preferred
                $merged = $true
                break
            }
        } elseif ([string]$event.kind -in @('assistant_commentary', 'assistant_final')) {
            for ($index = $deduped.Count - 1; $index -ge 0 -and $index -ge $deduped.Count - 30; $index--) {
                $existing = $deduped[$index]
                if ([string]$existing.Event.kind -ne [string]$event.kind) { continue }
                if ([string]$existing.Event.turnId -ne [string]$event.turnId) { continue }
                $sameStableId = -not [string]::IsNullOrWhiteSpace($candidate.StableItemId) -and $candidate.StableItemId -eq $existing.StableItemId
                $bothAuthoritative = $candidate.WrapperSource -eq 'completed_item_message' -and $existing.WrapperSource -eq 'completed_item_message'
                if ($bothAuthoritative -and -not $sameStableId) { continue }
                $sameText = ([string]$candidate.Event.rawText).Trim() -eq ([string]$existing.Event.rawText).Trim()
                $legacyCompletedPair = @($candidate.WrapperSource, $existing.WrapperSource) -contains 'legacy_agent_message' -and
                    @($candidate.WrapperSource, $existing.WrapperSource) -contains 'completed_item_message'
                $low = [Math]::Min([int]$candidate.RawLineOrdinal, [int]$existing.RawLineOrdinal)
                $high = [Math]::Max([int]$candidate.RawLineOrdinal, [int]$existing.RawLineOrdinal)
                if (-not $sameStableId -and (-not $sameText -or -not $legacyCompletedPair -or ($high - $low) -gt 3)) { continue }
                $wrapperMatch = @($assistantWrappers | Where-Object {
                    $_.RawLineOrdinal -gt $low -and $_.RawLineOrdinal -lt $high -and
                    (
                        ($_.StableItemId -in @($candidate.StableItemId, $existing.StableItemId) -and -not [string]::IsNullOrWhiteSpace($_.StableItemId) -and
                            ([string]::IsNullOrWhiteSpace([string]$_.TurnId) -or $_.TurnId -eq [string]$event.turnId)) -or
                        ($_.TurnId -eq [string]$event.turnId -and $_.RawText.Trim() -eq ([string]$event.rawText).Trim())
                    )
                }).Count -gt 0
                $wrapperClusterSafe = Test-CodexAssistantWrapperCluster -WrappersByOrdinal $assistantWrappersByOrdinal `
                    -LowOrdinal $low -HighOrdinal $high -TurnId ([string]$event.turnId) -RawText ([string]$event.rawText) `
                    -EventKind ([string]$event.kind) `
                    -StableItemIds @([string]$candidate.StableItemId, [string]$existing.StableItemId)
                if (-not ($sameStableId -or ($sameText -and $legacyCompletedPair -and $wrapperMatch -and $wrapperClusterSafe))) { continue }
                $preferred = if ($candidate.WrapperSource -eq 'completed_item_message') { $candidate } else { $existing }
                $preferred.RawLineOrdinal = $low
                $deduped[$index] = $preferred
                $merged = $true
                break
            }
        } elseif ([string]$event.kind -eq 'tool' -and -not [string]::IsNullOrWhiteSpace($candidate.StableItemId)) {
            $stableToolKey = [string]$event.turnId + '|' + [string]$candidate.StableItemId
            if (-not $seenStableToolKeys.Add($stableToolKey)) { $merged = $true }
        }
        if (-not $merged) { $deduped.Add($candidate) }
    }

    $finalCounts = @{}
    foreach ($candidate in @($deduped)) {
        if ($candidate.Event.kind -ne 'assistant_final') { continue }
        $turnId = [string]$candidate.Event.turnId
        if (-not $finalCounts.ContainsKey($turnId)) { $finalCounts[$turnId] = 0 }
        $finalCounts[$turnId]++
    }
    $taskSequence = [System.Collections.Generic.List[object]]::new()
    $taskPosition = @{}
    foreach ($turnId in @($taskOrder)) {
        if ($rolledBackTurns.Contains([string]$turnId) -or $taskPosition.ContainsKey([string]$turnId)) { continue }
        $taskPosition[[string]$turnId] = $taskSequence.Count
        $taskSequence.Add($taskByTurn[[string]$turnId])
    }

    $events = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in @($deduped | Sort-Object RawLineOrdinal)) {
        $turnId = [string]$candidate.Event.turnId
        $task = if ($taskByTurn.ContainsKey($turnId)) { $taskByTurn[$turnId] } else { $null }
        $previousTask = $null
        $nextTask = $null
        if ($taskPosition.ContainsKey($turnId)) {
            $position = [int]$taskPosition[$turnId]
            if ($position -gt 0) { $previousTask = $taskSequence[$position - 1] }
            if ($position + 1 -lt $taskSequence.Count) { $nextTask = $taskSequence[$position + 1] }
        }
        $turnFinalCount = if ($finalCounts.ContainsKey($turnId)) { [int]$finalCounts[$turnId] } else { 0 }
        $resolvedTime = Get-CodexResolvedCandidateTime -Candidate $candidate -Task $task `
            -PreviousTask $previousTask -NextTask $nextTask -TurnFinalCount $turnFinalCount
        Set-CodexResolvedEventTime -Event $candidate.Event -Value $resolvedTime
        $events.Add($candidate.Event)
    }

    if ([string]::IsNullOrWhiteSpace($createdAt)) { $createdAt = $File.CreationTimeUtc.ToString('o') }
    if ($null -eq (ConvertTo-CodexDateTimeOffset $updatedAt)) { $updatedAt = $File.LastWriteTimeUtc.ToString('o') }
    Add-ResolvedUserEventImages -Events $events -Cwd $cwd -SessionId $id
    $userEvents = @($events | Where-Object kind -eq 'user')
    $assistantEvents = @($events | Where-Object kind -in @('assistant_commentary', 'assistant_final'))
    if ($userEvents.Count -eq 0 -and $assistantEvents.Count -eq 0) { return New-SkippedReaderSession 'empty-after-context-filter' }
    $firstUserMessage = if ($userEvents.Count -gt 0) { [string]$userEvents[0].rawText } else { '' }
    $title = Get-FirstLine $firstUserMessage
    if ([string]::IsNullOrWhiteSpace($title)) { $title = $File.Name }

    [pscustomobject]@{
        Id = $id
        Cwd = $cwd
        Title = $title
        Summary = Get-ShortText $firstUserMessage 220
        CreatedAt = Convert-ToUtcIsoText $createdAt
        CreatedLocal = Convert-ToLocalTimeText $createdAt
        UpdatedAt = Convert-ToUtcIsoText $updatedAt
        UpdatedLocal = Convert-ToLocalTimeText $updatedAt
        Source = $source
        ModelProvider = $modelProvider
        CliVersion = $cliVersion
        UserCount = $userEvents.Count
        AssistantCount = $assistantEvents.Count
        UnassignedRecordCount = $unassignedRecordCount
        UnrecognizedRecordCount = $unrecognizedRecordCount
        HasImageReference = @($userEvents | Where-Object { Test-ReaderEventHasImages $_ }).Count -gt 0
        Archived = Test-IsArchivedSessionPath $File.FullName
        Path = $File.FullName
        FileUri = Convert-ToFileUri $File.FullName
        SizeBytes = $File.Length
        Events = @($events)
    }
}

$generatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$outputDir = Split-Path -Parent $resolvedOutput
$SourceId = Get-SafeSourceId $SourceId
$SourceType = if ([string]::IsNullOrWhiteSpace($SourceType)) { "local-codex" } else { [string]$SourceType }
if ($SourceType -notin @('local-codex', 'external-codex-jsonl', 'local-claude', 'webdav-codex', 'webdav-claude')) {
    throw "Unsupported SourceType: $SourceType"
}
$isClaudeSource = $SourceType -in @('local-claude', 'webdav-claude')
$isRemoteSource = $SourceType -in @('webdav-codex', 'webdav-claude')
if ($SourceType -eq 'local-codex') {
    $SourceId = 'local-codex'
} elseif ($SourceType -eq 'local-claude') {
    $SourceId = 'local-claude'
}
if ($SourceType -in @('local-codex', 'local-claude')) {
    $SourceLabel = Get-LocalSourceLabel -SourceType $SourceType -MachineName $MachineName
} elseif ([string]::IsNullOrWhiteSpace($SourceLabel)) {
    $SourceLabel = if (-not [string]::IsNullOrWhiteSpace($ExternalSourcePath)) {
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
$resolvedRemoteSourceRoot = ""
if ($SourceType -eq 'external-codex-jsonl') {
    if ([string]::IsNullOrWhiteSpace($ExternalSourcePath)) {
        throw "ExternalSourcePath is required when SourceType is external-codex-jsonl."
    }
    $resolvedExternalSourcePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ExternalSourcePath)
}
if ($isRemoteSource) {
    if ([string]::IsNullOrWhiteSpace($RemoteSourceRoot)) {
        throw "RemoteSourceRoot is required for WebDAV sources."
    }
    if ([string]::IsNullOrWhiteSpace($OriginMapPath)) {
        throw "OriginMapPath is required for WebDAV sources."
    }
    $resolvedRemoteSourceRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RemoteSourceRoot)
    if (-not (Test-Path -LiteralPath $resolvedRemoteSourceRoot -PathType Container)) {
        throw "RemoteSourceRoot was not found: $resolvedRemoteSourceRoot"
    }
    if (-not (Test-Path -LiteralPath $OriginMapPath -PathType Leaf)) {
        throw "OriginMapPath was not found: $OriginMapPath"
    }
    if ($SourceType -eq 'webdav-codex') {
        $sessionRoot = Join-Path $resolvedRemoteSourceRoot 'sessions'
        $archiveRoot = Join-Path $resolvedRemoteSourceRoot 'archived_sessions'
    } else {
        $ClaudeHome = $resolvedRemoteSourceRoot
        $claudeProjectsRoot = Join-Path $resolvedRemoteSourceRoot 'projects'
        $claudeSessionsRoot = Join-Path $resolvedRemoteSourceRoot 'sessions_metadata'
    }
    $DisableLocalPathImages = $true
}
$sourceInfo = if ($SourceType -eq 'local-codex') {
    [ordered]@{
        id = $SourceId
        label = $SourceLabel
        type = $SourceType
        roots = @($sessionRoot, $archiveRoot)
        capabilities = Get-SourceCapabilities $SourceType
    }
} elseif ($isClaudeSource) {
    [ordered]@{
        id = $SourceId
        label = $SourceLabel
        type = $SourceType
        root = $claudeProjectsRoot
        sessionsRoot = $claudeSessionsRoot
        capabilities = Get-SourceCapabilities $SourceType
    }
} elseif ($SourceType -eq 'webdav-codex') {
    [ordered]@{
        id = $SourceId
        label = $SourceLabel
        type = $SourceType
        roots = @($sessionRoot, $archiveRoot)
        capabilities = Get-SourceCapabilities $SourceType
    }
} else {
    [ordered]@{
        id = $SourceId
        label = $SourceLabel
        type = $SourceType
        root = $resolvedExternalSourcePath
        capabilities = Get-SourceCapabilities $SourceType
    }
}
if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $DataRoot = Join-Path (Split-Path -Parent $PSScriptRoot) '运行数据'
}
$resolvedDataRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DataRoot)
$useSourceDataLayout = $true
$effectiveDataRoot = if ($useSourceDataLayout) {
    Join-Path (Join-Path $resolvedDataRoot 'CodexChatIndex.sources') $SourceId
} else {
    $resolvedDataRoot
}
$dataOutput = if (-not $useSourceDataLayout -and $outputPathWasProvided) {
    [System.IO.Path]::ChangeExtension($resolvedOutput, ".data.json")
} else {
    Join-Path $effectiveDataRoot 'CodexChatIndex.data.json'
}
$detailRoot = Join-Path $effectiveDataRoot 'CodexChatIndex.sessions'
$cacheOutput = Join-Path $effectiveDataRoot 'CodexChatIndex.cache.json'
$searchOutput = if (-not $useSourceDataLayout -and $outputPathWasProvided) {
    [System.IO.Path]::ChangeExtension($resolvedOutput, ".search.json")
} else {
    Join-Path $effectiveDataRoot 'CodexChatIndex.search.json'
}
$otherSearchOutput = if (-not $useSourceDataLayout -and $outputPathWasProvided) {
    [System.IO.Path]::ChangeExtension($resolvedOutput, ".search.other.json")
} else {
    Join-Path $effectiveDataRoot 'CodexChatIndex.search.other.json'
}
$builderVersion = "V0.33"
$parserRevision = 4
$templatePath = Join-Path $PSScriptRoot 'templates\CodexChatIndex.template.html'
$indexRelativePath = Convert-ToRelativeWebPath -FromDirectory $outputDir -ToPath $dataOutput
if ($indexRelativePath -notmatch '^(\./|\.\./|/)') {
    $indexRelativePath = './' + $indexRelativePath
}
$indexUrlForScript = Convert-ToJavaScriptSingleQuotedContent $indexRelativePath
$detailRelativeRoot = (Convert-ToRelativeWebPath -FromDirectory $outputDir -ToPath $detailRoot).TrimEnd('/')
$expectedDetailPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

$cacheRead = if ($RefreshMode -eq 'Full' -and -not $StatusOnly) {
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
    } elseif (
        $null -eq $cacheData -or
        $cacheData.cacheVersion -ne 5 -or
        [string]$cacheData.builderVersion -ne $builderVersion -or
        [int]$cacheData.parserRevision -ne $parserRevision
    ) {
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
    if ($isRemoteSource) {
        throw "Current refresh is not supported for WebDAV sources."
    }
    $currentPath = Get-NormalizedFilePath $CurrentSessionPath
    if ([string]::IsNullOrWhiteSpace($currentPath)) {
        throw "CurrentSessionPath is required when RefreshMode is Current."
    }
    if ($SourceType -eq 'external-codex-jsonl' -and -not (Test-PathWithinDirectory -Path $currentPath -Directory $resolvedExternalSourcePath)) {
        throw "Current session file is outside the selected external source: $currentPath"
    }
    if ($isClaudeSource -and -not (Test-PathWithinDirectory -Path $currentPath -Directory $claudeProjectsRoot)) {
        throw "Current session file is outside the local Claude projects root: $currentPath"
    }
}

$files = @()
$fileMap = @{}
$scannedCount = 0
$effectiveClaudeScanRoots = @()
$syncInventoryErrors = [System.Collections.Generic.List[string]]::new()
$hasExplicitClaudeScanRoots = $ClaudeScanRoots -and @($ClaudeScanRoots).Count -gt 0
$claudeSessionMetadataMap = if ($isClaudeSource) {
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
    } elseif ($isClaudeSource) {
        $effectiveClaudeScanRoots = if ($isRemoteSource) {
            @($resolvedRemoteSourceRoot)
        } else {
            Get-ClaudeExtraSourceRoots -ClaudeHome $ClaudeHome -ClaudeScanRoots $ClaudeScanRoots
        }
        $claudeCandidates = [System.Collections.Generic.Dictionary[string, System.IO.FileInfo]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($claudeRoot in $effectiveClaudeScanRoots) {
            if (-not (Test-Path -LiteralPath $claudeRoot -PathType Container)) {
                if (-not [string]::IsNullOrWhiteSpace($ExportSyncInventoryPath) -and $hasExplicitClaudeScanRoots) {
                    $syncInventoryErrors.Add("Claude scan root is not a readable directory: $claudeRoot")
                }
                continue
            }
            $claudeEnumerationErrors = @()
            $claudeJsonlCandidates = @(Get-ChildItem -LiteralPath $claudeRoot -Recurse -File -Filter "*.jsonl" -ErrorAction SilentlyContinue -ErrorVariable +claudeEnumerationErrors)
            $claudeJsonCandidates = @(Get-ChildItem -LiteralPath $claudeRoot -Recurse -File -Filter "*.json" -ErrorAction SilentlyContinue -ErrorVariable +claudeEnumerationErrors)
            foreach ($enumerationError in @($claudeEnumerationErrors)) {
                $syncInventoryErrors.Add("Claude scan failed under ${claudeRoot}: $($enumerationError.Exception.Message)")
            }
            foreach ($candidate in $claudeJsonlCandidates) {
                $candidatePath = Get-NormalizedFilePath $candidate.FullName
                if (-not [string]::IsNullOrWhiteSpace($candidatePath)) {
                    $claudeCandidates[$candidatePath] = $candidate
                }
            }
            foreach ($candidate in $claudeJsonCandidates) {
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

if (-not [string]::IsNullOrWhiteSpace($ExportSyncInventoryPath)) {
    if ($SourceType -notin @('local-codex', 'local-claude')) {
        throw "ExportSyncInventoryPath is only supported for local-codex and local-claude."
    }
    $inventoryFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($file in @($files)) { [void]$inventoryFiles.Add($file) }
    if ($SourceType -eq 'local-claude' -and (Test-Path -LiteralPath $claudeSessionsRoot -PathType Container)) {
        $claudeMetadataErrors = @()
        foreach ($metadataFile in @(Get-ChildItem -LiteralPath $claudeSessionsRoot -File -Filter '*.json' -ErrorAction SilentlyContinue -ErrorVariable +claudeMetadataErrors)) {
            [void]$inventoryFiles.Add($metadataFile)
        }
        foreach ($metadataError in @($claudeMetadataErrors)) {
            $syncInventoryErrors.Add("Claude session metadata scan failed: $($metadataError.Exception.Message)")
        }
    }
    $inventoryEntries = @(
        $inventoryFiles |
            Sort-Object FullName -Unique |
            ForEach-Object {
                New-SyncInventoryFileEntry `
                    -File $_ `
                    -SourceType $SourceType `
                    -SessionRoot $sessionRoot `
                    -ArchiveRoot $archiveRoot `
                    -ClaudeHome $ClaudeHome `
                    -ClaudeSessionsRoot $claudeSessionsRoot
            }
    )
    $inventoryPayload = [ordered]@{
        version = 1
        sourceId = $SourceId
        sourceType = $SourceType
        sourceSignature = $sourceSignature
        scanComplete = ($syncInventoryErrors.Count -eq 0)
        errors = @($syncInventoryErrors | Sort-Object -Unique)
        files = @($inventoryEntries)
    }
    $resolvedInventoryPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ExportSyncInventoryPath)
    Write-Utf8FileAtomic -Path $resolvedInventoryPath -Value ($inventoryPayload | ConvertTo-Json -Depth 100)
    $buildStopwatch.Stop()
    $inventorySummary = [pscustomobject]@{
        Mode = 'ExportSyncInventory'
        SourceId = $SourceId
        SourceType = $SourceType
        InventoryPath = $resolvedInventoryPath
        ScannedCount = $inventoryEntries.Count
        ScanComplete = ($syncInventoryErrors.Count -eq 0)
        ElapsedMs = [int][Math]::Round($buildStopwatch.Elapsed.TotalMilliseconds)
    }
    if ($JsonSummary) { $inventorySummary | ConvertTo-Json -Depth 20 -Compress } else { $inventorySummary }
    return
}

if ($StatusOnly) {
    if ($SourceType -notin @('local-codex', 'local-claude')) {
        throw "StatusOnly is only supported for local-codex and local-claude."
    }
    $outputsComplete = (Test-BuildOutputsComplete -HtmlPath $resolvedOutput -DataPath $dataOutput -SearchPath $searchOutput -OtherSearchPath $otherSearchOutput -CachePath $cacheOutput)
    $detailsComplete = $outputsComplete -and (Test-CachedDetailFilesComplete -CacheData $cacheData -DetailRoot $detailRoot)
    $signatureMatches = -not [string]::IsNullOrWhiteSpace($sourceSignatureText) -and $sourceSignatureText -eq $cachedSourceSignatureText
    $noChange = $signatureMatches -and $outputsComplete -and $detailsComplete
    $buildStopwatch.Stop()
    $statusSummary = [pscustomobject]@{
        Mode = 'StatusOnly'
        SourceId = $SourceId
        SourceType = $SourceType
        SourceSignature = $sourceSignature
        ScannedCount = $scannedCount
        NoChange = $noChange
        OutputsComplete = $outputsComplete
        DetailsComplete = $detailsComplete
        Reason = if ($noChange) { '' } elseif (-not $outputsComplete) { '构建输出不完整' } elseif (-not $detailsComplete) { '会话详情不完整' } else { '本机来源已变化' }
        ElapsedMs = [int][Math]::Round($buildStopwatch.Elapsed.TotalMilliseconds)
    }
    if ($JsonSummary) { $statusSummary | ConvertTo-Json -Depth 100 -Compress } else { $statusSummary }
    return
}

New-Item -ItemType Directory -Force $outputDir | Out-Null
New-Item -ItemType Directory -Force $resolvedDataRoot | Out-Null
New-Item -ItemType Directory -Force $effectiveDataRoot | Out-Null
New-Item -ItemType Directory -Force $detailRoot | Out-Null
Initialize-ImageAssetStore -RuntimeDataRoot $resolvedDataRoot -SourceId $SourceId -SourceType $SourceType
if (-not $outputPathWasProvided) {
    $sharedRoot = Split-Path -Parent $PSScriptRoot
    New-Item -ItemType Directory -Force (Join-Path $sharedRoot '外部聊天记录') | Out-Null
}
Update-SourceManifest -RuntimeDataRoot $resolvedDataRoot -Source $sourceInfo

if (
    $RefreshMode -eq 'Incremental' -and
    $effectiveRefreshMode -eq 'Incremental' -and
    [string]::IsNullOrWhiteSpace($cacheNotice) -and
    -not [string]::IsNullOrWhiteSpace($sourceSignatureText) -and
    $sourceSignatureText -eq $cachedSourceSignatureText -and
    (Test-BuildOutputsComplete -HtmlPath $resolvedOutput -DataPath $dataOutput -SearchPath $searchOutput -OtherSearchPath $otherSearchOutput -CachePath $cacheOutput) -and
    (Test-CachedDetailFilesComplete -CacheData $cacheData -DetailRoot $detailRoot)
) {
    $existingData = Read-JsonFileDetailed $dataOutput
    $existingAppData = if ($existingData.Parsed -and $existingData.Value) { $existingData.Value } else { $null }
    $htmlUpdated = $false
    if ($existingAppData) {
        $expectedHtml = Render-HtmlTemplate -TemplatePath $templatePath -Values ([ordered]@{
            BUILDER_VERSION = [string]$builderVersion
            INDEX_URL = [string]$indexUrlForScript
            TOTAL_SESSIONS = [string]$existingAppData.totalSessions
            TOTAL_WORKSPACES = [string]$existingAppData.totalWorkspaces
            ARCHIVED_COUNT = [string]$existingAppData.archived
            IMAGE_REF_COUNT = [string]$existingAppData.imageReferences
            GENERATED_AT = [string]$existingAppData.generatedAt
        })
        $currentHtml = ((Get-Content -LiteralPath $resolvedOutput -Raw) -replace "`r`n?", "`n").TrimEnd([char[]]"`r`n")
        $expectedHtmlForComparison = $expectedHtml.TrimEnd([char[]]"`r`n")
        if ($currentHtml -cne $expectedHtmlForComparison) {
            Write-Utf8FileAtomic -Path $resolvedOutput -Value $expectedHtml
            $htmlUpdated = $true
        }
    }
    $buildStopwatch.Stop()
    $summary = [pscustomobject]@{
        Mode = $effectiveRefreshMode
        SourceId = $SourceId
        SourceLabel = $SourceLabel
        SourceType = $SourceType
        OutputPath = $resolvedOutput
        DataPath = $dataOutput
        SearchPath = $searchOutput
        OtherSearchPath = $otherSearchOutput
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
        UnassignedRecordCount = 0
        UnrecognizedRecordCount = 0
        Notice = if ($htmlUpdated) { "未发现新增或修改记录，已同步页面模板。" } else { "未发现新增或修改记录，已跳过重写。" }
        NoChange = $true
        SkippedWrite = -not $htmlUpdated
        HtmlUpdated = $htmlUpdated
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
        $session = if ($isClaudeSource) {
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
        $sessionsList.Add((Complete-ParsedSessionForBuild -Session $session -File $file -DetailFileName $detailFileName `
            -DetailRoot $detailRoot -SourceId $SourceId -DeferDetailWrite $isRemoteSource))
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

        $session = if ($isClaudeSource) {
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
        $sessionsList.Add((Complete-ParsedSessionForBuild -Session $session -File $file -DetailFileName $detailFileName `
            -DetailRoot $detailRoot -SourceId $SourceId -DeferDetailWrite $isRemoteSource))
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
            $session = if ($isClaudeSource) {
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
            $sessionsList.Add((Complete-ParsedSessionForBuild -Session $session -File $repairFile -DetailFileName $repairDetailFileName `
                -DetailRoot $detailRoot -SourceId $SourceId -DeferDetailWrite $isRemoteSource))
            $parsedCount++
            $scannedCount++
            continue
        }
        $sessionsList.Add((New-SessionFromCacheRecord $cachedRecord))
        $reusedCount++
    }

    $currentFile = $fileMap[$currentPath]
    $session = if ($isClaudeSource) {
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
        $sessionsList.Add((Complete-ParsedSessionForBuild -Session $session -File $currentFile -DetailFileName $detailFileName `
            -DetailRoot $detailRoot -SourceId $SourceId -DeferDetailWrite $isRemoteSource))
        $parsedCount++
    }
}

if ($isRemoteSource) {
    $originMapRead = Read-JsonFileDetailed $OriginMapPath
    if (-not $originMapRead.Parsed -or $null -eq $originMapRead.Value) {
        throw "OriginMapPath does not contain a valid JSON object."
    }
    $remoteOriginMap = @{}
    foreach ($property in @($originMapRead.Value.PSObject.Properties)) {
        $logicalPath = ([string]$property.Name).Replace('\', '/').TrimStart('/')
        if (-not [string]::IsNullOrWhiteSpace($logicalPath)) {
            $remoteOriginMap[$logicalPath] = [string]$property.Value
        }
    }
    foreach ($session in @($sessionsList)) {
        $rawSessionPath = [string]$session.Path
        $logicalPath = [System.IO.Path]::GetRelativePath($resolvedRemoteSourceRoot, $rawSessionPath).Replace('\', '/')
        if (-not $remoteOriginMap.ContainsKey($logicalPath) -or [string]::IsNullOrWhiteSpace([string]$remoteOriginMap[$logicalPath])) {
            throw "Origin map is missing the parsed remote file: $logicalPath"
        }
        $originPath = [string]$remoteOriginMap[$logicalPath]
        $session | Add-Member -NotePropertyName Path -NotePropertyValue $originPath -Force
        $session | Add-Member -NotePropertyName FileUri -NotePropertyValue (Convert-ToFileUri $originPath) -Force
        [void](Set-SessionSearchFields $session)
    }
}

$buildUnassignedRecordCount = 0
$buildUnrecognizedRecordCount = 0
foreach ($session in @($sessionsList)) {
    if ($session.PSObject.Properties.Name -contains 'UnassignedRecordCount') {
        $buildUnassignedRecordCount += [int]$session.UnassignedRecordCount
    }
    if ($session.PSObject.Properties.Name -contains 'UnrecognizedRecordCount') {
        $buildUnrecognizedRecordCount += [int]$session.UnrecognizedRecordCount
    }
}

$sessions = @($sessionsList | Sort-Object Cwd, @{ Expression = "UpdatedAt"; Descending = $true })
$searchLimitSummary = Set-GlobalSearchTextLimits -Sessions $sessions
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
    version = 4
    part = 'questions'
    generatedAt = $generatedAt
    sessions = @($sessions | ForEach-Object {
        [ordered]@{
            key = [string]$_.Path
            id = [string]$_.Id
            sourceId = if ([string]::IsNullOrWhiteSpace([string]$_.SourceId)) { $SourceId } else { [string]$_.SourceId }
            cwd = [string]$_.Cwd
            title = [string]$_.Title
            path = [string]$_.Path
            questionTexts = @($_.QuestionSearchTexts)
        }
    })
}

$otherSearchPayload = [ordered]@{
    version = 4
    part = 'other'
    generatedAt = $generatedAt
    sessions = @($sessions | ForEach-Object {
        [ordered]@{
            key = [string]$_.Path
            otherText = [string]$_.OtherSearchText
        }
    })
}

$cachePayload = [ordered]@{
    cacheVersion = 5
    builderVersion = $builderVersion
    parserRevision = $parserRevision
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
Write-Utf8FileAtomic -Path $otherSearchOutput -Value ($otherSearchPayload | ConvertTo-Json -Depth 100)
Write-Utf8FileAtomic -Path $cacheOutput -Value ($cachePayload | ConvertTo-Json -Depth 100)
Save-ImageAssetStore -SourceId $SourceId -SourceType $SourceType

$buildStopwatch.Stop()

$summary = [pscustomobject]@{
    Mode = $effectiveRefreshMode
    SourceId = $SourceId
    SourceLabel = $SourceLabel
    SourceType = $SourceType
    OutputPath = $resolvedOutput
    DataPath = $dataOutput
    SearchPath = $searchOutput
    OtherSearchPath = $otherSearchOutput
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
    UnassignedRecordCount = $buildUnassignedRecordCount
    UnrecognizedRecordCount = $buildUnrecognizedRecordCount
    ToolRawSearchOriginalChars = [int64]$searchLimitSummary.ToolRawOriginalChars
    ToolRawSearchIndexedChars = [int64]$searchLimitSummary.ToolRawIndexedChars
    ToolRawSearchTruncatedEvents = [int]$searchLimitSummary.ToolRawTruncatedEvents
    SearchTextIndexedChars = [int64]$searchLimitSummary.TotalIndexedChars
    Notice = $cacheNotice
}

if ($JsonSummary) {
    $summary | ConvertTo-Json -Depth 20 -Compress
} else {
    $summary
}


