param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [string]$IdaDir,

    [string]$PythonExe = "D:\Tools\Python311\python.exe",

    [string]$HostAddress = "127.0.0.1",

    [int]$Port = 8746,

    [string]$IdaUsrDir,

    [ValidateSet("streamable-http", "sse", "stdio")]
    [string]$Transport = "streamable-http"
)

$resolvedInput = (Resolve-Path -LiteralPath $InputPath).Path

if ($IdaDir) {
    $env:IDADIR = (Resolve-Path -LiteralPath $IdaDir).Path
}

if (-not $env:IDADIR) {
    throw "IDADIR is not set. Pass -IdaDir or set the IDADIR environment variable first."
}

if ($IdaUsrDir) {
    if (-not (Test-Path -LiteralPath $IdaUsrDir)) {
        New-Item -ItemType Directory -Path $IdaUsrDir -Force | Out-Null
    }
    $env:IDAUSR = (Resolve-Path -LiteralPath $IdaUsrDir).Path
}

& $PythonExe -m ida_pro_mcp.idalib_server --transport $Transport --host $HostAddress --port $Port $resolvedInput
