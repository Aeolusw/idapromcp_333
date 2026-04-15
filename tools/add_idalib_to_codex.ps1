[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [string]$Alias,

    [string]$PythonExe,

    [string]$IdaDir,

    [string]$ManifestPath = ".\.idalib-fleet\codex-managed.json",

    [string]$CodexConfigPath = (Join-Path $HOME ".codex\config.toml"),

    [switch]$RegisterOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$fleetScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "idalib_fleet.ps1")).Path
$namePrefix = "ida-android-idalib"
$defaultPortBase = 8746
$preferredDatabaseExtensions = @(".i64", ".idb")
$preferredStartTimeoutSeconds = 900
$databaseInputRequirementMessage = "Managed headless workflows only support existing IDA database files (.i64 or .idb). Open the target in GUI IDA first, wait for initialization to finish, save a database file (.i64 preferred, .idb supported), then rerun this command with that database path."

function Get-OptionalProperty {
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    if ($null -eq $property.Value) {
        return $Default
    }

    return $property.Value
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    $expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
    return [System.IO.Path]::GetFullPath($expanded)
}

function Get-PathFromBase {
    param(
        [Parameter(Mandatory = $true)][string]$PathValue,
        [Parameter(Mandatory = $true)][string]$BaseDirectory
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [System.IO.Path]::GetFullPath($expanded)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $expanded))
}

function Resolve-ExistingPath {
    param(
        [Parameter(Mandatory = $true)][string]$PathValue,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
    if (-not (Test-Path -LiteralPath $expanded)) {
        throw "$Label not found: $PathValue"
    }

    return (Resolve-Path -LiteralPath $expanded).Path
}

function Resolve-ExecutableValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Value)
    $looksLikePath = $expanded.Contains("\") -or $expanded.Contains("/") -or $expanded.Contains(":")
    if ($looksLikePath) {
        return Resolve-ExistingPath -PathValue $expanded -Label "Python executable"
    }

    return $expanded
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $directory = Split-Path -Parent $Path
    if ($directory) {
        Ensure-Directory -Path $directory | Out-Null
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Get-DefaultAlias {
    param([Parameter(Mandatory = $true)][string]$ResolvedInputPath)

    $item = Get-Item -LiteralPath $ResolvedInputPath
    $segments = @()
    if ($item.DirectoryName) {
        $segments = $item.DirectoryName -split "[\\/]"
    }

    for ($index = $segments.Length - 1; $index -ge 0; $index--) {
        if ($segments[$index] -match "^\d{14}$") {
            return "{0}{1}" -f $segments[$index].Substring(6), $item.Name
        }
    }

    return $item.Name
}

function Get-SafeKeyBase {
    param([Parameter(Mandatory = $true)][string]$AliasValue)

    $safeKey = [regex]::Replace($AliasValue, "[^A-Za-z0-9_-]", "_")
    $safeKey = $safeKey.Trim("_")
    if ([string]::IsNullOrWhiteSpace($safeKey)) {
        return "instance"
    }

    return $safeKey
}

function Get-ServerName {
    param([Parameter(Mandatory = $true)][string]$SafeKey)

    return "{0}-{1}" -f $namePrefix, $SafeKey
}

function Test-PreferredDatabaseInput {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    $extension = [System.IO.Path]::GetExtension($PathValue)
    if (-not $extension) {
        return $false
    }

    return $preferredDatabaseExtensions -contains $extension.ToLowerInvariant()
}

function Get-RecommendedDatabaseSibling {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    $candidates = @(
        ("{0}.i64" -f $PathValue)
        ([System.IO.Path]::ChangeExtension($PathValue, ".i64"))
        ([System.IO.Path]::ChangeExtension($PathValue, ".idb"))
    )

    foreach ($candidate in $candidates) {
        if (-not $candidate) {
            continue
        }

        $normalizedCandidate = Get-FullPath -PathValue $candidate
        if ((-not (Compare-NormalizedPath -Left $normalizedCandidate -Right $PathValue)) -and (Test-Path -LiteralPath $normalizedCandidate)) {
            return $normalizedCandidate
        }
    }

    return $null
}

function Write-UnsupportedDatabaseInputAndExit {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedInputPath,
        [Parameter(Mandatory = $true)][string]$RequestedMode
    )

    $recommendedDatabaseSibling = Get-RecommendedDatabaseSibling -PathValue $ResolvedInputPath
    $guidance = @(
        "Open the target in GUI IDA."
        "Wait for the initial analysis and loader work to finish."
        "Save the initialized database as an .i64 or .idb file."
        "Re-run this script with the saved database path."
    )

    if ($recommendedDatabaseSibling) {
        $guidance = @(
            ("A nearby database file already exists: {0}" -f $recommendedDatabaseSibling)
        ) + $guidance
    }

    $payload = [ordered]@{
        action = "ensure"
        requested_mode = $RequestedMode
        input_path = $ResolvedInputPath
        error = "unsupported_input"
        message = $databaseInputRequirementMessage
        supported_extensions = $preferredDatabaseExtensions
        recommended_input = $recommendedDatabaseSibling
        guidance = $guidance
    }

    $payload | ConvertTo-Json -Depth 10
    exit 1
}

function Test-ListeningPort {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][int]$Port
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $asyncResult = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne(500)) {
            return $false
        }

        $client.EndConnect($asyncResult)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Get-ExistingServerNames {
    param([string]$ConfigText)

    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ([string]::IsNullOrWhiteSpace($ConfigText)) {
        return ,$names
    }

    $pattern = '(?m)^\[mcp_servers\.(?:"(?<quoted>[^"]+)"|(?<bare>[A-Za-z0-9_-]+))\]'
    foreach ($match in [regex]::Matches($ConfigText, $pattern)) {
        $name = if ($match.Groups["quoted"].Success) { $match.Groups["quoted"].Value } else { $match.Groups["bare"].Value }
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $null = $names.Add($name)
        }
    }

    return ,$names
}

function Get-PreferredPythonExe {
    param([string]$ManifestPythonExe)

    if ($PythonExe) {
        return Resolve-ExecutableValue -Value $PythonExe
    }

    if ($ManifestPythonExe) {
        return Resolve-ExecutableValue -Value $ManifestPythonExe
    }

    $knownPath = "D:\Tools\Python311\python.exe"
    if (Test-Path -LiteralPath $knownPath) {
        return (Resolve-Path -LiteralPath $knownPath).Path
    }

    $command = Get-Command python -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    throw "Unable to determine Python executable. Pass -PythonExe explicitly."
}

function Get-PreferredIdaDir {
    param([string]$ManifestIdaDir)

    if ($IdaDir) {
        return Resolve-ExistingPath -PathValue $IdaDir -Label "IdaDir"
    }

    if ($ManifestIdaDir) {
        return Resolve-ExistingPath -PathValue $ManifestIdaDir -Label "Manifest ida_dir"
    }

    if ($env:IDADIR) {
        return Resolve-ExistingPath -PathValue $env:IDADIR -Label "IDADIR"
    }

    throw "IdaDir is required unless the manifest already defines ida_dir or IDADIR is set."
}

function Load-ManagedManifestState {
    param([Parameter(Mandatory = $true)][string]$ManifestPathValue)

    $manifestObject = $null
    $changed = -not (Test-Path -LiteralPath $ManifestPathValue)

    if (Test-Path -LiteralPath $ManifestPathValue) {
        $rawText = Get-Content -LiteralPath $ManifestPathValue -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($rawText)) {
            $manifestObject = $rawText | ConvertFrom-Json
        }
    }

    $pythonValue = Get-PreferredPythonExe -ManifestPythonExe (Get-OptionalProperty -Object $manifestObject -Name "python_exe")
    $idaDirValue = Get-PreferredIdaDir -ManifestIdaDir (Get-OptionalProperty -Object $manifestObject -Name "ida_dir")
    $transportValue = "streamable-http"
    $instances = @()

    foreach ($instance in @(Get-OptionalProperty -Object $manifestObject -Name "instances" -Default @())) {
        $inputPathValue = Get-OptionalProperty -Object $instance -Name "input_path"
        if (-not $inputPathValue) {
            throw "Manifest instance is missing input_path: $ManifestPathValue"
        }

        $normalizedInputPath = Get-FullPath -PathValue $inputPathValue
        $aliasValue = Get-OptionalProperty -Object $instance -Name "alias"
        if (-not $aliasValue) {
            $aliasValue = Get-DefaultAlias -ResolvedInputPath $normalizedInputPath
            $changed = $true
        }

        $portValue = Get-OptionalProperty -Object $instance -Name "port"
        if ($null -eq $portValue) {
            throw "Manifest instance is missing port: $inputPathValue"
        }

        $enabledValue = [bool](Get-OptionalProperty -Object $instance -Name "enabled" -Default $true)
        if ($null -eq ($instance.PSObject.Properties["enabled"])) {
            $changed = $true
        }

        $instances += [ordered]@{
            alias = [string]$aliasValue
            input_path = $normalizedInputPath
            port = [int]$portValue
            enabled = $enabledValue
        }
    }

    if ((Get-OptionalProperty -Object $manifestObject -Name "python_exe") -ne $pythonValue) {
        $changed = $true
    }
    if ((Get-OptionalProperty -Object $manifestObject -Name "ida_dir") -ne $idaDirValue) {
        $changed = $true
    }
    if ((Get-OptionalProperty -Object $manifestObject -Name "transport" -Default "") -ne $transportValue) {
        $changed = $true
    }

    $manifest = [ordered]@{
        python_exe = $pythonValue
        ida_dir = $idaDirValue
        transport = $transportValue
        instances = $instances
    }

    return [ordered]@{
        manifest = $manifest
        changed = $changed
    }
}

function Save-ManagedManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPathValue,
        [Parameter(Mandatory = $true)]$Manifest
    )

    $json = $Manifest | ConvertTo-Json -Depth 10
    Write-Utf8NoBom -Path $ManifestPathValue -Content $json
}

function Compare-NormalizedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    return [System.StringComparer]::OrdinalIgnoreCase.Equals(
        (Get-FullPath -PathValue $Left),
        (Get-FullPath -PathValue $Right)
    )
}

function Get-ExistingInstance {
    param(
        [Parameter(Mandatory = $true)]$Instances,
        [Parameter(Mandatory = $true)][string]$ResolvedInputPath
    )

    foreach ($instance in $Instances) {
        if (Compare-NormalizedPath -Left $instance.input_path -Right $ResolvedInputPath) {
            return $instance
        }
    }

    return $null
}

function New-ManagedIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$AliasBase,
        [Parameter(Mandatory = $true)]$Instances,
        [Parameter(Mandatory = $true)]$ExistingServerNames
    )

    $usedAliases = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $usedSafeKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($instance in $Instances) {
        $null = $usedAliases.Add([string]$instance.alias)
        $null = $usedSafeKeys.Add((Get-SafeKeyBase -AliasValue ([string]$instance.alias)))
    }

    $suffix = 1
    while ($true) {
        $candidateAlias = if ($suffix -eq 1) { $AliasBase } else { "{0}_{1}" -f $AliasBase, $suffix }
        $candidateSafeKey = Get-SafeKeyBase -AliasValue $candidateAlias
        $candidateServerName = Get-ServerName -SafeKey $candidateSafeKey
        if (
            -not $usedAliases.Contains($candidateAlias) -and
            -not $usedSafeKeys.Contains($candidateSafeKey) -and
            -not $ExistingServerNames.Contains($candidateServerName)
        ) {
            return [ordered]@{
                alias = $candidateAlias
                safe_key = $candidateSafeKey
                server_name = $candidateServerName
            }
        }

        $suffix += 1
    }
}

function Get-NextAvailablePort {
    param([Parameter(Mandatory = $true)]$Instances)

    $usedPorts = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($instance in $Instances) {
        $null = $usedPorts.Add([int]$instance.port)
    }

    $port = $defaultPortBase
    while ($usedPorts.Contains($port) -or (Test-ListeningPort -HostName "127.0.0.1" -Port $port)) {
        $port += 1
    }

    return $port
}

function Get-SectionBounds {
    param(
        [string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$ServerName
    )

    $targetSections = @(
        ('mcp_servers.{0}' -f $ServerName)
        ('mcp_servers."{0}"' -f $ServerName)
    )
    $startIndex = -1
    $endIndex = -1

    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^\[(?<section>[^\]]+)\]\s*$') {
            $sectionName = $Matches["section"]
            if ($startIndex -ge 0) {
                $endIndex = $index - 1
                break
            }

            if ($targetSections -contains $sectionName) {
                $startIndex = $index
            }
        }
    }

    if ($startIndex -lt 0) {
        return $null
    }

    if ($endIndex -lt 0) {
        $endIndex = $Lines.Count - 1
    }

    return [ordered]@{
        start = $startIndex
        end = $endIndex
    }
}

function Remove-LeadingBlankLines {
    param([string[]]$Lines)

    if ($null -eq $Lines) {
        return ,@()
    }

    $startIndex = 0
    while ($startIndex -lt $Lines.Count -and [string]::IsNullOrWhiteSpace($Lines[$startIndex])) {
        $startIndex += 1
    }

    if ($startIndex -ge $Lines.Count) {
        return ,@()
    }

    return ,@($Lines[$startIndex..($Lines.Count - 1)])
}

function Remove-TrailingBlankLines {
    param([string[]]$Lines)

    if ($null -eq $Lines) {
        return ,@()
    }

    $endIndex = $Lines.Count - 1
    while ($endIndex -ge 0 -and [string]::IsNullOrWhiteSpace($Lines[$endIndex])) {
        $endIndex -= 1
    }

    if ($endIndex -lt 0) {
        return ,@()
    }

    return ,@($Lines[0..$endIndex])
}

function Join-LinesWithFinalNewline {
    param([string[]]$Lines)

    if ($Lines.Count -eq 0) {
        return ""
    }

    return ([string]::Join([Environment]::NewLine, $Lines) + [Environment]::NewLine)
}

function Set-CodexServerUrlEntry {
    param(
        [string]$ConfigText,
        [Parameter(Mandatory = $true)][string]$ServerName,
        [Parameter(Mandatory = $true)][string]$Url
    )

    $replacementLines = @(
        ('[mcp_servers."{0}"]' -f $ServerName)
        ('url = "{0}"' -f $Url)
    )

    $lines = @()
    if (-not [string]::IsNullOrEmpty($ConfigText)) {
        $lines = @([regex]::Split($ConfigText, "\r?\n"))
    }
    $lines = Remove-TrailingBlankLines -Lines $lines
    $bounds = Get-SectionBounds -Lines $lines -ServerName $ServerName

    $before = @()
    $after = @()
    if ($bounds) {
        if ($bounds.start -gt 0) {
            $before = @($lines[0..($bounds.start - 1)])
        }
        if ($bounds.end + 1 -lt $lines.Count) {
            $after = @($lines[($bounds.end + 1)..($lines.Count - 1)])
        }
    }
    else {
        $before = @($lines)
    }

    $before = Remove-TrailingBlankLines -Lines $before
    $after = Remove-LeadingBlankLines -Lines $after

    $resultLines = @()
    if ($before.Count -gt 0) {
        $resultLines += $before
        $resultLines += ""
    }
    $resultLines += $replacementLines
    if ($after.Count -gt 0) {
        $resultLines += ""
        $resultLines += $after
    }

    return Join-LinesWithFinalNewline -Lines (Remove-TrailingBlankLines -Lines $resultLines)
}

function Invoke-FleetJsonAction {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$ManifestPathValue,
        [string]$AliasValue,
        [int]$StartTimeoutSeconds = 0,
        [switch]$ForceAction
    )

    if ($AliasValue) {
        if ($ForceAction) {
            if ($StartTimeoutSeconds -gt 0) {
                $output = & $fleetScript -Action $Action -ManifestPath $ManifestPathValue -Alias $AliasValue -StartTimeoutSeconds $StartTimeoutSeconds -Force
            }
            else {
                $output = & $fleetScript -Action $Action -ManifestPath $ManifestPathValue -Alias $AliasValue -Force
            }
        }
        else {
            if ($StartTimeoutSeconds -gt 0) {
                $output = & $fleetScript -Action $Action -ManifestPath $ManifestPathValue -Alias $AliasValue -StartTimeoutSeconds $StartTimeoutSeconds
            }
            else {
                $output = & $fleetScript -Action $Action -ManifestPath $ManifestPathValue -Alias $AliasValue
            }
        }
    }
    else {
        if ($ForceAction) {
            if ($StartTimeoutSeconds -gt 0) {
                $output = & $fleetScript -Action $Action -ManifestPath $ManifestPathValue -StartTimeoutSeconds $StartTimeoutSeconds -Force
            }
            else {
                $output = & $fleetScript -Action $Action -ManifestPath $ManifestPathValue -Force
            }
        }
        else {
            if ($StartTimeoutSeconds -gt 0) {
                $output = & $fleetScript -Action $Action -ManifestPath $ManifestPathValue -StartTimeoutSeconds $StartTimeoutSeconds
            }
            else {
                $output = & $fleetScript -Action $Action -ManifestPath $ManifestPathValue
            }
        }
    }

    $jsonText = ((@($output) -join [Environment]::NewLine).Trim())
    if (-not $jsonText) {
        throw "Fleet action '$Action' returned no output."
    }

    try {
        return ($jsonText | ConvertFrom-Json)
    }
    catch {
        throw "Fleet action '$Action' returned invalid JSON.`n$jsonText"
    }
}

function Get-StatusRecord {
    param(
        [Parameter(Mandatory = $true)]$StatusPayload,
        [Parameter(Mandatory = $true)][string]$AliasValue,
        [Parameter(Mandatory = $true)][string]$ResolvedInputPath
    )

    foreach ($instance in @($StatusPayload.instances)) {
        if ([System.StringComparer]::OrdinalIgnoreCase.Equals([string]$instance.alias, $AliasValue)) {
            return $instance
        }

        $statusInputPath = Get-OptionalProperty -Object $instance -Name "input_path"
        if ($statusInputPath -and (Compare-NormalizedPath -Left $statusInputPath -Right $ResolvedInputPath)) {
            return $instance
        }
    }

    return $null
}

$resolvedInputPath = Resolve-ExistingPath -PathValue $InputPath -Label "Input path"
$requestedMode = if ($RegisterOnly) { "register_only" } else { "ensure_running" }
if (-not (Test-PreferredDatabaseInput -PathValue $resolvedInputPath)) {
    Write-UnsupportedDatabaseInputAndExit -ResolvedInputPath $resolvedInputPath -RequestedMode $requestedMode
}

$effectiveManifestPath = Get-PathFromBase -PathValue $ManifestPath -BaseDirectory $repoRoot
$effectiveCodexConfigPath = Get-FullPath -PathValue $CodexConfigPath
$manifestDirectory = Split-Path -Parent $effectiveManifestPath
$configDirectory = Split-Path -Parent $effectiveCodexConfigPath

if ($manifestDirectory) {
    Ensure-Directory -Path $manifestDirectory | Out-Null
}
if ($configDirectory) {
    Ensure-Directory -Path $configDirectory | Out-Null
}

$configText = ""
if (Test-Path -LiteralPath $effectiveCodexConfigPath) {
    $configText = Get-Content -LiteralPath $effectiveCodexConfigPath -Raw -Encoding UTF8
}

$manifestState = Load-ManagedManifestState -ManifestPathValue $effectiveManifestPath
$manifest = $manifestState.manifest
$manifestChanged = [bool]$manifestState.changed
$configChanged = $false
$instanceAdded = $false
$warnings = @()

$existingInstance = Get-ExistingInstance -Instances $manifest.instances -ResolvedInputPath $resolvedInputPath
if ($null -eq $existingInstance) {
    $aliasBase = if ($Alias) { $Alias } else { Get-DefaultAlias -ResolvedInputPath $resolvedInputPath }
    $identity = New-ManagedIdentity -AliasBase $aliasBase -Instances $manifest.instances -ExistingServerNames (Get-ExistingServerNames -ConfigText $configText)
    $existingInstance = [ordered]@{
        alias = $identity.alias
        input_path = $resolvedInputPath
        port = (Get-NextAvailablePort -Instances $manifest.instances)
        enabled = $true
    }
    $manifest.instances += $existingInstance
    $manifestChanged = $true
    $instanceAdded = $true
}
elseif (-not [bool]$existingInstance.enabled) {
    $existingInstance.enabled = $true
    $manifestChanged = $true
}

if ($manifestChanged) {
    Save-ManagedManifest -ManifestPathValue $effectiveManifestPath -Manifest $manifest
}

$safeKey = Get-SafeKeyBase -AliasValue ([string]$existingInstance.alias)
$serverName = Get-ServerName -SafeKey $safeKey
$url = 'http://127.0.0.1:{0}/mcp' -f ([int]$existingInstance.port)
$preferredInput = Test-PreferredDatabaseInput -PathValue $resolvedInputPath
$startTimeoutSeconds = $preferredStartTimeoutSeconds
$recommendedDatabaseSibling = $null

$updatedConfigText = Set-CodexServerUrlEntry -ConfigText $configText -ServerName $serverName -Url $url
if ($updatedConfigText -ne $configText) {
    Write-Utf8NoBom -Path $effectiveCodexConfigPath -Content $updatedConfigText
    $configChanged = $true
}

$fleetAction = "none"
$statusPayload = Invoke-FleetJsonAction -Action "status" -ManifestPathValue $effectiveManifestPath
$statusRecord = Get-StatusRecord -StatusPayload $statusPayload -AliasValue ([string]$existingInstance.alias) -ResolvedInputPath $resolvedInputPath
if ($null -eq $statusRecord) {
    throw "Unable to locate the managed instance in fleet status: $resolvedInputPath"
}

if (-not $RegisterOnly) {
    switch ([string]$statusRecord.health) {
        "healthy" {
            $fleetAction = "none"
        }
        "stopped" {
            $null = Invoke-FleetJsonAction -Action "start" -ManifestPathValue $effectiveManifestPath -AliasValue ([string]$existingInstance.alias) -StartTimeoutSeconds $startTimeoutSeconds
            $fleetAction = "start"
        }
        "degraded" {
            $null = Invoke-FleetJsonAction -Action "restart" -ManifestPathValue $effectiveManifestPath -AliasValue ([string]$existingInstance.alias) -StartTimeoutSeconds $startTimeoutSeconds -ForceAction
            $fleetAction = "restart"
        }
        default {
            $null = Invoke-FleetJsonAction -Action "start" -ManifestPathValue $effectiveManifestPath -AliasValue ([string]$existingInstance.alias) -StartTimeoutSeconds $startTimeoutSeconds
            $fleetAction = "start"
        }
    }

    if ($fleetAction -ne "none") {
        $statusPayload = Invoke-FleetJsonAction -Action "status" -ManifestPathValue $effectiveManifestPath
        $statusRecord = Get-StatusRecord -StatusPayload $statusPayload -AliasValue ([string]$existingInstance.alias) -ResolvedInputPath $resolvedInputPath
        if ($null -eq $statusRecord) {
            throw "Unable to locate the managed instance after fleet action: $resolvedInputPath"
        }
    }
}

$result = [ordered]@{
    action = "ensure"
    requested_mode = $requestedMode
    fleet_action = $fleetAction
    manifest = $effectiveManifestPath
    state_file = Get-OptionalProperty -Object $statusPayload -Name "state_file"
    config_path = $effectiveCodexConfigPath
    manifest_changed = $manifestChanged
    config_changed = $configChanged
    instance_added = $instanceAdded
    server_name = $serverName
    alias = [string]$existingInstance.alias
    safe_key = $safeKey
    url = $url
    input_path = $resolvedInputPath
    preferred_input = $preferredInput
    recommended_input = $recommendedDatabaseSibling
    warnings = $warnings
    status = $statusRecord
}

$result | ConvertTo-Json -Depth 10
