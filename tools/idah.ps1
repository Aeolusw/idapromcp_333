[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputPath,

    [Parameter()]
    [ValidateRange(1, 2)]
    [int]$Slot = 1,

    [string]$IdaDir = "E:\CS\Tools\IDA Pro 9.1",

    [string]$PythonExe = "D:\Tools\Python311\python.exe",

    [string]$HostAddress = "127.0.0.1",

    [string]$IdaUsrDir,

    [ValidateSet("streamable-http", "sse", "stdio")]
    [string]$Transport = "streamable-http"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$delegateScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "start_headless_slot.ps1")).Path
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

$resolvedInputPath = (Resolve-Path -LiteralPath $InputPath).Path
if (-not (Test-SupportedDatabaseInput -PathValue $resolvedInputPath)) {
    $message = $databaseInputRequirementMessage
    $recommendedDatabaseSibling = Get-RecommendedDatabaseSibling -PathValue $resolvedInputPath
    if ($recommendedDatabaseSibling) {
        $message = "{0} Nearby database file: {1}" -f $message, $recommendedDatabaseSibling
    }

    throw $message
}

$arguments = @{
    InputPath = $resolvedInputPath
    Slot = $Slot
    IdaDir = $IdaDir
    PythonExe = $PythonExe
    HostAddress = $HostAddress
    Transport = $Transport
}

if ($PSBoundParameters.ContainsKey("IdaUsrDir")) {
    $arguments["IdaUsrDir"] = $IdaUsrDir
}

if ($WhatIfPreference) {
    $arguments["WhatIf"] = $true
}

& $delegateScript @arguments
