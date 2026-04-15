[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateRange(1, 2)]
    [int]$Slot = 1,

    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputPath,

    [string]$IdaDir = "E:\CS\Tools\IDA Pro 9.1",

    [string]$PythonExe = "D:\Tools\Python311\python.exe",

    [string]$HostAddress = "127.0.0.1",

    [string]$IdaUsrDir,

    [ValidateSet("streamable-http", "sse", "stdio")]
    [string]$Transport = "streamable-http"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$delegateScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "start_idalib_server.ps1")).Path
$databaseInputRequirementMessage = "Managed headless workflows only support existing IDA database files (.i64 or .idb). Open the target in GUI IDA first, wait for initialization to finish, save a database file (.i64 preferred, .idb supported), then rerun this command with that database path."

function Test-SupportedDatabaseInput {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    $extension = [System.IO.Path]::GetExtension($PathValue)
    return @(".i64", ".idb") -contains $extension.ToLowerInvariant()
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

        $normalizedCandidate = [System.IO.Path]::GetFullPath($candidate)
        if (
            -not [System.StringComparer]::OrdinalIgnoreCase.Equals($normalizedCandidate, $PathValue) -and
            (Test-Path -LiteralPath $normalizedCandidate)
        ) {
            return $normalizedCandidate
        }
    }

    return $null
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

switch ($Slot) {
    1 {
        $port = 8746
        $slotName = "slot1"
    }
    2 {
        $port = 8747
        $slotName = "slot2"
    }
    default {
        throw "Unsupported slot: $Slot"
    }
}

$resolvedInputPath = (Resolve-Path -LiteralPath $InputPath).Path
if (-not (Test-SupportedDatabaseInput -PathValue $resolvedInputPath)) {
    $message = $databaseInputRequirementMessage
    $recommendedDatabaseSibling = Get-RecommendedDatabaseSibling -PathValue $resolvedInputPath
    if ($recommendedDatabaseSibling) {
        $message = "{0} Nearby database file: {1}" -f $message, $recommendedDatabaseSibling
    }

    throw $message
}

$effectiveIdaUsrDir = if ($IdaUsrDir) {
    [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($IdaUsrDir))
} else {
    Join-Path (Join-Path $repoRoot ".idalib-slots") $slotName
}

$mcpUrl = "http://{0}:{1}/mcp" -f $HostAddress, $port

Write-Output ("Slot: {0} ({1})" -f $Slot, $slotName)
Write-Output ("Input: {0}" -f $resolvedInputPath)
Write-Output ("Transport: {0}" -f $Transport)
Write-Output ("MCP URL: {0}" -f $mcpUrl)
Write-Output ("IDAUSR: {0}" -f $effectiveIdaUsrDir)

if (Test-ListeningPort -HostName $HostAddress -Port $port) {
    Write-Warning ("Port {0} is already in use. If another headless instance is already bound to this slot, stop it first or choose the other slot." -f $port)
}

if ($PSCmdlet.ShouldProcess(
        ("slot {0} on {1}:{2}" -f $Slot, $HostAddress, $port),
        ("Start headless IDA MCP for {0}" -f $resolvedInputPath)
    )) {
    & $delegateScript `
        -InputPath $resolvedInputPath `
        -IdaDir $IdaDir `
        -PythonExe $PythonExe `
        -HostAddress $HostAddress `
        -Port $port `
        -IdaUsrDir $effectiveIdaUsrDir `
        -Transport $Transport
}
