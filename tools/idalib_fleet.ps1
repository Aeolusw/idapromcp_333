[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("start", "stop", "restart", "status", "logs", "config")]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [ValidateSet("all", "codex", "claude")]
    [string]$Client = "all",

    [string[]]$Alias,

    [int]$Tail = 80,

    [int]$ProbeTimeoutSeconds = 30,

    [int]$StartTimeoutSeconds = 300,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$probeScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "idalib_probe.py")).Path

function Get-OptionalProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
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

function New-UniqueName {
    param(
        [Parameter(Mandatory = $true)][string]$BaseName,
        [Parameter(Mandatory = $true)]$UsedNames
    )

    $candidate = $BaseName
    $suffix = 2
    while (-not $UsedNames.Add($candidate)) {
        $candidate = "{0}_{1}" -f $BaseName, $suffix
        $suffix += 1
    }
    return $candidate
}

function Get-DefaultAlias {
    param([Parameter(Mandatory = $true)][string]$InputPath)

    $item = Get-Item -LiteralPath $InputPath
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

function Get-ManifestModel {
    param([Parameter(Mandatory = $true)][string]$ManifestPathValue)

    $resolvedManifest = (Resolve-Path -LiteralPath $ManifestPathValue).Path
    $manifestRaw = Get-Content -LiteralPath $resolvedManifest -Raw -Encoding UTF8
    $manifest = $manifestRaw | ConvertFrom-Json

    $pythonExe = Get-OptionalProperty -Object $manifest -Name "python_exe"
    $idaDir = Get-OptionalProperty -Object $manifest -Name "ida_dir"
    $transport = Get-OptionalProperty -Object $manifest -Name "transport" -Default "streamable-http"

    if (-not $pythonExe) {
        throw "Manifest missing python_exe: $resolvedManifest"
    }
    if (-not $idaDir) {
        throw "Manifest missing ida_dir: $resolvedManifest"
    }
    if (-not (Test-Path -LiteralPath $pythonExe)) {
        throw "python_exe not found: $pythonExe"
    }
    if (-not (Test-Path -LiteralPath $idaDir)) {
        throw "ida_dir not found: $idaDir"
    }
    if ($transport -ne "streamable-http") {
        throw "Fleet currently supports only transport=streamable-http."
    }

    $instanceValues = @(Get-OptionalProperty -Object $manifest -Name "instances" -Default @())
    if ($instanceValues.Count -eq 0) {
        throw "Manifest has no instances: $resolvedManifest"
    }

    $manifestName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedManifest)
    $stateRoot = Ensure-Directory -Path (Join-Path $repoRoot ".idalib-fleet\$manifestName")
    $runRoot = Ensure-Directory -Path (Join-Path $stateRoot "run")
    $logRoot = Ensure-Directory -Path (Join-Path $stateRoot "logs")
    $idaUsrRoot = Ensure-Directory -Path (Join-Path $stateRoot "idausr")

    $usedAliases = [System.Collections.Generic.HashSet[string]]::new()
    $usedSafeKeys = [System.Collections.Generic.HashSet[string]]::new()
    $usedPorts = [System.Collections.Generic.HashSet[int]]::new()
    $normalizedInstances = @()

    foreach ($instance in $instanceValues) {
        $inputPath = Get-OptionalProperty -Object $instance -Name "input_path"
        if (-not $inputPath) {
            throw "Every instance must define input_path."
        }
        if (-not (Test-Path -LiteralPath $inputPath)) {
            throw "Input path not found: $inputPath"
        }

        $port = Get-OptionalProperty -Object $instance -Name "port"
        if ($null -eq $port) {
            throw "Every instance must define port: $inputPath"
        }
        $portNumber = [int]$port
        if ($portNumber -lt 1 -or $portNumber -gt 65535) {
            throw "Invalid port $portNumber for $inputPath"
        }
        if (-not $usedPorts.Add($portNumber)) {
            throw "Duplicate port in manifest: $portNumber"
        }

        $enabled = [bool](Get-OptionalProperty -Object $instance -Name "enabled" -Default $true)
        $aliasBase = Get-OptionalProperty -Object $instance -Name "alias"
        if (-not $aliasBase) {
            $aliasBase = Get-DefaultAlias -InputPath $inputPath
        }
        $aliasValue = New-UniqueName -BaseName $aliasBase -UsedNames $usedAliases
        $safeKeyBase = Get-SafeKeyBase -AliasValue $aliasValue
        $safeKey = New-UniqueName -BaseName $safeKeyBase -UsedNames $usedSafeKeys

        $expectedModule = [System.IO.Path]::GetFileName($inputPath)
        $stdoutLog = Join-Path $logRoot ("{0}.stdout.log" -f $safeKey)
        $stderrLog = Join-Path $logRoot ("{0}.stderr.log" -f $safeKey)
        $pidFile = Join-Path $runRoot ("{0}.pid" -f $safeKey)
        $idaUsrDir = Ensure-Directory -Path (Join-Path $idaUsrRoot $safeKey)

        $normalizedInstances += [ordered]@{
            alias = $aliasValue
            safe_key = $safeKey
            enabled = $enabled
            input_path = (Resolve-Path -LiteralPath $inputPath).Path
            expected_module = $expectedModule
            port = $portNumber
            host = "127.0.0.1"
            url = "http://127.0.0.1:{0}/mcp" -f $portNumber
            stdout_log = $stdoutLog
            stderr_log = $stderrLog
            pid_file = $pidFile
            idausr_dir = $idaUsrDir
        }
    }

    return [ordered]@{
        manifest_path = $resolvedManifest
        manifest_name = $manifestName
        python_exe = (Resolve-Path -LiteralPath $pythonExe).Path
        ida_dir = (Resolve-Path -LiteralPath $idaDir).Path
        transport = $transport
        state_root = $stateRoot
        state_file = Join-Path $stateRoot "state.json"
        instances = $normalizedInstances
    }
}

function Select-Instances {
    param(
        [Parameter(Mandatory = $true)]$ManifestModel,
        [string[]]$Aliases,
        [switch]$IncludeDisabled
    )

    $instances = @($ManifestModel.instances)
    if (-not $IncludeDisabled) {
        $instances = @($instances | Where-Object { $_.enabled })
    }

    if ($Aliases -and $Aliases.Count -gt 0) {
        $selected = @($instances | Where-Object { $Aliases -contains $_.alias })
        $missingAliases = @($Aliases | Where-Object { $_ -notin $selected.alias })
        if ($missingAliases.Count -gt 0) {
            throw "Alias not found in manifest: $($missingAliases -join ', ')"
        }
        return $selected
    }

    return $instances
}

function Get-RunningPid {
    param([Parameter(Mandatory = $true)]$Instance)

    if (-not (Test-Path -LiteralPath $Instance.pid_file)) {
        return $null
    }

    $pidText = (Get-Content -LiteralPath $Instance.pid_file -Raw -Encoding ASCII).Trim()
    if (-not $pidText) {
        Remove-Item -LiteralPath $Instance.pid_file -Force -ErrorAction SilentlyContinue
        return $null
    }

    $pidValue = 0
    if (-not [int]::TryParse($pidText, [ref]$pidValue)) {
        Remove-Item -LiteralPath $Instance.pid_file -Force -ErrorAction SilentlyContinue
        return $null
    }

    try {
        Get-Process -Id $pidValue -ErrorAction Stop | Out-Null
        return $pidValue
    }
    catch {
        Remove-Item -LiteralPath $Instance.pid_file -Force -ErrorAction SilentlyContinue
        return $null
    }
}

function Invoke-IdalibProbe {
    param(
        [Parameter(Mandatory = $true)]$ManifestModel,
        [Parameter(Mandatory = $true)]$Instance,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $probeOutput = & $ManifestModel.python_exe $probeScript --url $Instance.url --timeout-seconds $TimeoutSeconds
    if (-not $probeOutput) {
        return [ordered]@{
            ok = $false
            error = "Probe returned no output."
        }
    }

    try {
        return ($probeOutput | ConvertFrom-Json)
    }
    catch {
        return [ordered]@{
            ok = $false
            error = "Probe returned invalid JSON: $probeOutput"
        }
    }
}

function Get-InstanceStatus {
    param(
        [Parameter(Mandatory = $true)]$ManifestModel,
        [Parameter(Mandatory = $true)]$Instance,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $pidValue = Get-RunningPid -Instance $Instance
    $probe = $null
    $health = "stopped"
    $module = $null
    $reportedPath = $null
    $toolCount = $null
    $probeError = $null

    if ($pidValue) {
        $probe = Invoke-IdalibProbe -ManifestModel $ManifestModel -Instance $Instance -TimeoutSeconds $TimeoutSeconds
        $module = Get-OptionalProperty -Object $probe -Name "module"
        $reportedPath = Get-OptionalProperty -Object $probe -Name "path"
        $toolCount = Get-OptionalProperty -Object $probe -Name "tool_count"
        if ((Get-OptionalProperty -Object $probe -Name "ok" -Default $false) -and $module -eq $Instance.expected_module) {
            $health = "healthy"
        }
        else {
            $health = "degraded"
            $probeError = Get-OptionalProperty -Object $probe -Name "error"
            if (-not $probeError -and $module -and $module -ne $Instance.expected_module) {
                $probeError = "Reported module '$module' does not match expected '$($Instance.expected_module)'."
            }
        }
    }
    elseif (Test-ListeningPort -HostName $Instance.host -Port $Instance.port) {
        $health = "degraded"
        $probeError = "Port is listening but no tracked PID exists."
    }

    return [ordered]@{
        alias = $Instance.alias
        safe_key = $Instance.safe_key
        enabled = $Instance.enabled
        port = $Instance.port
        pid = $pidValue
        health = $health
        module = $module
        tool_count = $toolCount
        input_path = $Instance.input_path
        reported_path = $reportedPath
        url = $Instance.url
        stdout_log = $Instance.stdout_log
        stderr_log = $Instance.stderr_log
        idausr_dir = $Instance.idausr_dir
        error = $probeError
    }
}

function Write-StateFile {
    param(
        [Parameter(Mandatory = $true)]$ManifestModel,
        [Parameter(Mandatory = $true)][object[]]$Statuses
    )

    $document = [ordered]@{
        manifest_path = $ManifestModel.manifest_path
        manifest_name = $ManifestModel.manifest_name
        updated_at = [DateTimeOffset]::Now.ToString("o")
        instances = $Statuses
    }

    $json = $document | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $ManifestModel.state_file -Encoding UTF8 -Value $json
}

function Stop-InstanceProcess {
    param([Parameter(Mandatory = $true)]$Instance)

    $pidValue = Get-RunningPid -Instance $Instance
    if (-not $pidValue) {
        return $false
    }

    try {
        Stop-Process -Id $pidValue -Force -ErrorAction Stop
        Wait-Process -Id $pidValue -Timeout 30 -ErrorAction SilentlyContinue
    }
    finally {
        Remove-Item -LiteralPath $Instance.pid_file -Force -ErrorAction SilentlyContinue
    }

    return $true
}

function Start-InstanceProcess {
    param(
        [Parameter(Mandatory = $true)]$ManifestModel,
        [Parameter(Mandatory = $true)]$Instance,
        [Parameter(Mandatory = $true)][int]$StartTimeout,
        [Parameter(Mandatory = $true)][int]$ProbeTimeout
    )

    $existingPid = Get-RunningPid -Instance $Instance
    if ($existingPid) {
        if ($Force) {
            Stop-InstanceProcess -Instance $Instance | Out-Null
        }
        else {
            throw "Instance already running: $($Instance.alias) (PID $existingPid)"
        }
    }

    if (Test-ListeningPort -HostName $Instance.host -Port $Instance.port) {
        throw "Port already in use: $($Instance.port) for $($Instance.alias)"
    }

    Remove-Item -LiteralPath $Instance.stdout_log -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Instance.stderr_log -Force -ErrorAction SilentlyContinue

    $argumentList = @(
        "-m"
        "ida_pro_mcp.idalib_server"
        "--transport"
        $ManifestModel.transport
        "--host"
        $Instance.host
        "--port"
        ([string]$Instance.port)
        $Instance.input_path
    )

    $previousIdaDir = $env:IDADIR
    $previousIdaUsr = $env:IDAUSR
    try {
        $env:IDADIR = $ManifestModel.ida_dir
        $env:IDAUSR = $Instance.idausr_dir
        $process = Start-Process `
            -FilePath $ManifestModel.python_exe `
            -ArgumentList $argumentList `
            -WorkingDirectory $repoRoot `
            -RedirectStandardOutput $Instance.stdout_log `
            -RedirectStandardError $Instance.stderr_log `
            -PassThru `
            -WindowStyle Hidden
    }
    finally {
        if ($null -eq $previousIdaDir) {
            Remove-Item Env:IDADIR -ErrorAction SilentlyContinue
        }
        else {
            $env:IDADIR = $previousIdaDir
        }

        if ($null -eq $previousIdaUsr) {
            Remove-Item Env:IDAUSR -ErrorAction SilentlyContinue
        }
        else {
            $env:IDAUSR = $previousIdaUsr
        }
    }

    Set-Content -LiteralPath $Instance.pid_file -Encoding ASCII -Value ([string]$process.Id)

    $deadline = (Get-Date).AddSeconds($StartTimeout)
    do {
        Start-Sleep -Seconds 2

        try {
            Get-Process -Id $process.Id -ErrorAction Stop | Out-Null
        }
        catch {
            $stderrText = ""
            if (Test-Path -LiteralPath $Instance.stderr_log) {
                $stderrText = (Get-Content -LiteralPath $Instance.stderr_log -Tail 40 -Encoding UTF8) -join [Environment]::NewLine
            }
            Remove-Item -LiteralPath $Instance.pid_file -Force -ErrorAction SilentlyContinue
            throw "Instance exited before becoming healthy: $($Instance.alias)`n$stderrText"
        }

        $probe = Invoke-IdalibProbe -ManifestModel $ManifestModel -Instance $Instance -TimeoutSeconds $ProbeTimeout
        if ((Get-OptionalProperty -Object $probe -Name "ok" -Default $false) -and (Get-OptionalProperty -Object $probe -Name "module") -eq $Instance.expected_module) {
            return $probe
        }
    } while ((Get-Date) -lt $deadline)

    Stop-InstanceProcess -Instance $Instance | Out-Null
    $stderrTimeoutText = ""
    if (Test-Path -LiteralPath $Instance.stderr_log) {
        $stderrTimeoutText = (Get-Content -LiteralPath $Instance.stderr_log -Tail 40 -Encoding UTF8) -join [Environment]::NewLine
    }
    throw "Timed out waiting for healthy instance: $($Instance.alias)`n$stderrTimeoutText"
}

function Get-AllStatuses {
    param(
        [Parameter(Mandatory = $true)]$ManifestModel,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    return @(
        foreach ($instance in $ManifestModel.instances) {
            Get-InstanceStatus -ManifestModel $ManifestModel -Instance $instance -TimeoutSeconds $TimeoutSeconds
        }
    )
}

function Write-JsonResult {
    param(
        [Parameter(Mandatory = $true)][string]$ActionName,
        [Parameter(Mandatory = $true)]$ManifestModel,
        [Parameter(Mandatory = $true)][object[]]$Statuses
    )

    $payload = [ordered]@{
        action = $ActionName
        manifest = $ManifestModel.manifest_path
        state_file = $ManifestModel.state_file
        instances = $Statuses
    }
    $payload | ConvertTo-Json -Depth 10
}

$manifestModel = Get-ManifestModel -ManifestPathValue $ManifestPath

switch ($Action) {
    "start" {
        $targetInstances = @(Select-Instances -ManifestModel $manifestModel -Aliases $Alias)
        foreach ($instance in $targetInstances) {
            Start-InstanceProcess -ManifestModel $manifestModel -Instance $instance -StartTimeout $StartTimeoutSeconds -ProbeTimeout $ProbeTimeoutSeconds | Out-Null
        }
        $statuses = Get-AllStatuses -ManifestModel $manifestModel -TimeoutSeconds $ProbeTimeoutSeconds
        Write-StateFile -ManifestModel $manifestModel -Statuses $statuses
        Write-Output (Write-JsonResult -ActionName "start" -ManifestModel $manifestModel -Statuses $statuses)
    }
    "stop" {
        $targetInstances = @(Select-Instances -ManifestModel $manifestModel -Aliases $Alias -IncludeDisabled)
        foreach ($instance in $targetInstances) {
            Stop-InstanceProcess -Instance $instance | Out-Null
        }
        $statuses = Get-AllStatuses -ManifestModel $manifestModel -TimeoutSeconds $ProbeTimeoutSeconds
        Write-StateFile -ManifestModel $manifestModel -Statuses $statuses
        Write-Output (Write-JsonResult -ActionName "stop" -ManifestModel $manifestModel -Statuses $statuses)
    }
    "restart" {
        $targetInstances = @(Select-Instances -ManifestModel $manifestModel -Aliases $Alias)
        foreach ($instance in $targetInstances) {
            Stop-InstanceProcess -Instance $instance | Out-Null
        }
        foreach ($instance in $targetInstances) {
            Start-InstanceProcess -ManifestModel $manifestModel -Instance $instance -StartTimeout $StartTimeoutSeconds -ProbeTimeout $ProbeTimeoutSeconds | Out-Null
        }
        $statuses = Get-AllStatuses -ManifestModel $manifestModel -TimeoutSeconds $ProbeTimeoutSeconds
        Write-StateFile -ManifestModel $manifestModel -Statuses $statuses
        Write-Output (Write-JsonResult -ActionName "restart" -ManifestModel $manifestModel -Statuses $statuses)
    }
    "status" {
        $allStatuses = Get-AllStatuses -ManifestModel $manifestModel -TimeoutSeconds $ProbeTimeoutSeconds
        if ($Alias -and $Alias.Count -gt 0) {
            $statusOutput = @($allStatuses | Where-Object { $Alias -contains $_.alias })
        }
        else {
            $statusOutput = $allStatuses
        }
        Write-StateFile -ManifestModel $manifestModel -Statuses $allStatuses
        Write-Output (Write-JsonResult -ActionName "status" -ManifestModel $manifestModel -Statuses $statusOutput)
    }
    "logs" {
        $targetInstances = @(Select-Instances -ManifestModel $manifestModel -Aliases $Alias -IncludeDisabled)
        foreach ($instance in $targetInstances) {
            Write-Output ("=== {0} | stdout | {1} ===" -f $instance.alias, $instance.stdout_log)
            if (Test-Path -LiteralPath $instance.stdout_log) {
                Get-Content -LiteralPath $instance.stdout_log -Tail $Tail -Encoding UTF8
            }
            else {
                Write-Output "(no stdout log)"
            }
            Write-Output ""
            Write-Output ("=== {0} | stderr | {1} ===" -f $instance.alias, $instance.stderr_log)
            if (Test-Path -LiteralPath $instance.stderr_log) {
                Get-Content -LiteralPath $instance.stderr_log -Tail $Tail -Encoding UTF8
            }
            else {
                Write-Output "(no stderr log)"
            }
            Write-Output ""
        }
    }
    "config" {
        $targetInstances = @(Select-Instances -ManifestModel $manifestModel -Aliases $Alias)
        Write-Output "# Alias Map"
        foreach ($instance in $targetInstances) {
            Write-Output ("- {0} -> {1} -> http://127.0.0.1:{2}/mcp -> {3}" -f $instance.alias, $instance.safe_key, $instance.port, $instance.input_path)
        }
        Write-Output ""

        if ($Client -in @("all", "codex")) {
            Write-Output "# Codex"
            foreach ($instance in $targetInstances) {
                Write-Output ("[mcp_servers.""ida-android-idalib-{0}""]" -f $instance.safe_key)
                Write-Output ("url = ""http://127.0.0.1:{0}/mcp""" -f $instance.port)
                Write-Output ""
            }
        }

        if ($Client -in @("all", "claude")) {
            Write-Output "# Claude Code"
            Write-Output "{"
            for ($index = 0; $index -lt $targetInstances.Count; $index++) {
                $instance = $targetInstances[$index]
                $suffix = if ($index -lt $targetInstances.Count - 1) { "," } else { "" }
                Write-Output ("  ""ida-pro-mcp-idalib-{0}"": {{ ""type"": ""http"", ""url"": ""http://127.0.0.1:{1}/mcp"" }}{2}" -f $instance.safe_key, $instance.port, $suffix)
            }
            Write-Output "}"
        }
    }
}
