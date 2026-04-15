# AI MCP Quickstart

This file is the shortest practical entry point for another AI agent that needs to use this repository's MCP servers quickly.

It focuses on:

- which mode to use
- how to start it
- how to connect from Codex or Claude Code
- how to handle multiple headless `.so` targets

## 1. Choose the Right Mode

This repository exposes two different MCP server modes.

| Mode | Command | Use When |
| --- | --- | --- |
| `server` | `python -m ida_pro_mcp.server` | You already have a GUI IDA instance open and the IDA plugin is serving JSON-RPC on port `13339`. |
| `idalib_server` | `python -m ida_pro_mcp.idalib_server <binary>` | You want headless analysis without opening the full IDA GUI. |

If you need to inspect multiple `.so` files at the same time, do not try to make one `idalib_server` handle multiple inputs.

Use the fleet model:

- one `.so` file
- one `idalib_server` process
- one MCP URL
- one alias / safe key

## 2. Recommended Multi-Target Headless Flow

For AI-oriented usage, the recommended entry point is:

- [tools/idalib_fleet.ps1](D:/0Document/pgm/mcp/idapromcp_333/tools/idalib_fleet.ps1)

It manages multiple headless `idalib_server` instances from one manifest file.

Supported actions:

- `start`
- `stop`
- `restart`
- `status`
- `logs`
- `config`

The fleet script also:

- creates separate `IDAUSR` directories per target
- keeps separate PID and log files
- probes each instance with `initialize -> list_tools -> get_metadata`
- generates Codex and Claude Code config snippets

## 3. Minimal Manifest

Use a JSON manifest like this:

```json
{
  "python_exe": "D:\\Tools\\Python311\\python.exe",
  "ida_dir": "E:\\CS\\Tools\\IDA Pro 9.1",
  "transport": "streamable-http",
  "instances": [
    {
      "alias": "15083758libsec2026_runtime.so",
      "input_path": "D:\\path\\to\\first.so",
      "port": 8746,
      "enabled": true
    },
    {
      "alias": "13165417libsec2026_runtime.so",
      "input_path": "D:\\path\\to\\second.so",
      "port": 8747,
      "enabled": true
    }
  ]
}
```

Fields:

- `python_exe`: Python interpreter that can import `ida_pro_mcp`
- `ida_dir`: local IDA installation directory for `idapro` / `idalib`
- `transport`: currently keep this as `streamable-http`
- `alias`: human-facing instance name
- `input_path`: file to analyze
- `port`: explicit MCP port, one per instance
- `enabled`: whether the instance participates by default

There is a working sample here:

- [examples/idalib-fleet.sample.json](D:/0Document/pgm/mcp/idapromcp_333/examples/idalib-fleet.sample.json)

## 4. Alias and Safe Key Rules

`alias` is for humans and AI reasoning.

`safe key` is for config output.

Safe key rule:

- replace every character except `A-Z`, `a-z`, `0-9`, `-`, `_` with `_`

Examples:

- `15083758libsec2026_runtime.so` -> `15083758libsec2026_runtime_so`
- `13165417libsec2026_runtime.so` -> `13165417libsec2026_runtime_so`

If `alias` is omitted, the fleet script auto-generates one from the nearest `yyyyMMddHHmmss` directory:

- take the last 8 digits as `ddHHmmss`
- append the file name

If that still collides, the script appends a numeric suffix.

## 5. Start, Inspect, Stop

Start the fleet:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\idalib_fleet.ps1 `
  -Action start `
  -ManifestPath .\examples\idalib-fleet.sample.json
```

Check status:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\idalib_fleet.ps1 `
  -Action status `
  -ManifestPath .\examples\idalib-fleet.sample.json
```

Show logs:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\idalib_fleet.ps1 `
  -Action logs `
  -ManifestPath .\examples\idalib-fleet.sample.json `
  -Tail 60
```

Stop the fleet:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\idalib_fleet.ps1 `
  -Action stop `
  -ManifestPath .\examples\idalib-fleet.sample.json
```

## 6. How to Read `status`

`status` returns JSON.

Important fields:

- `alias`: the logical target name
- `safe_key`: the config-safe name
- `port`: listening port
- `pid`: tracked Python process
- `health`: `healthy`, `degraded`, or `stopped`
- `module`: file name reported by `get_metadata`
- `reported_path`: full path reported by `get_metadata`
- `tool_count`: number of MCP tools exposed
- `url`: MCP endpoint URL

Interpretation:

- `healthy`: process is alive and probe succeeded
- `degraded`: port or process state is inconsistent, or probe failed
- `stopped`: no tracked process and no healthy service

## 7. Generate Client Config Snippets

The fleet script does not directly modify user config files.

It prints ready-to-paste snippets instead.

Generate both Codex and Claude Code snippets:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\idalib_fleet.ps1 `
  -Action config `
  -ManifestPath .\examples\idalib-fleet.sample.json `
  -Client all
```

Typical output:

```toml
[mcp_servers."ida-android-idalib-15083758libsec2026_runtime_so"]
url = "http://127.0.0.1:8746/mcp"

[mcp_servers."ida-android-idalib-13165417libsec2026_runtime_so"]
url = "http://127.0.0.1:8747/mcp"
```

```json
{
  "ida-pro-mcp-idalib-15083758libsec2026_runtime_so": {
    "type": "http",
    "url": "http://127.0.0.1:8746/mcp"
  },
  "ida-pro-mcp-idalib-13165417libsec2026_runtime_so": {
    "type": "http",
    "url": "http://127.0.0.1:8747/mcp"
  }
}
```

## 8. Single-Target Headless Fallback

If you only need one headless target and do not want the fleet helper, this still works:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\start_idalib_server.ps1 `
  -InputPath "D:\\path\\to\\binary.so" `
  -IdaDir "E:\\CS\\Tools\\IDA Pro 9.1" `
  -Port 8746
```

But for AI usage across multiple files, prefer `idalib_fleet.ps1`.

## 9. Common Failure Cases

`Cannot load IDA library file idalib.dll`

- `IDADIR` is wrong
- IDA version is too old
- the local Python environment cannot load the IDA runtime

`Port already in use`

- another process is already listening on that port
- choose a different explicit port in the manifest
- or stop the old instance first

`degraded` status after a previous crash

- a stale process may still be listening
- inspect `logs`
- stop the old process
- rerun `restart`

No usable health result

- inspect `stdout` / `stderr` logs in `.idalib-fleet/<manifest-name>/logs/`
- verify `get_metadata` can run
- verify the file path exists and is readable

## 10. Practical Rule for Another AI Agent

If you are another AI system trying to use this repository, use this decision rule:

1. If the user already has GUI IDA open and wants the live plugin, use `python -m ida_pro_mcp.server`.
2. If the user wants headless analysis for one binary, use `tools/start_idalib_server.ps1`.
3. If the user wants headless analysis for two or more binaries, use `tools/idalib_fleet.ps1`.
4. When unsure, ask for:
   - `python_exe`
   - `ida_dir`
   - target binary paths
   - one port per target

For multi-target headless usage, treat each alias as a separate MCP server.
