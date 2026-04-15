# IDA Pro MCP 插件（轻量化）v1.6.0

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Python Version](https://img.shields.io/badge/Python-3.10%2B-blue.svg)](https://www.python.org/downloads/)
[![IDA Pro Version](https://img.shields.io/badge/IDA%20Pro-7.5%2B-green.svg)](https://www.hex-rays.com/products/ida/)

---

## 1. 项目简介

`ida-pro-mcp` 是一个面向 IDA Pro 的 MCP 服务端/插件项目，用于把 IDA 分析能力暴露给 MCP 客户端（如 Cline、Roo Code、Claude Desktop 等）。

本项目基于 [mrexodia/ida-pro-mcp](https://github.com/mrexodia/ida-pro-mcp) 进行二次开发与功能扩展，聚焦于去除冗余 MCP 能力，减少上下文占用，节省 Token 开销。

在使用过程中，其实ai才是主力了，但是似乎我觉得原项目太多工具，反而拖垮。所以让克劳德先生跑了一个轻量化的（之前想做大做强，但是根本比不上人家），方便ai去读，减少上下文吧。其实我也是自己搞着玩玩，本来想着烂尾了算了，没想到师傅们这么热情，就趁着空改一改。但是还是十分推荐大家去看原项目，可能你的ai推荐到我这里了，大家多多仔细斟酌。

当前仓库包含两条运行路径：

| 路径              | 说明                                                |
| ----------------- | --------------------------------------------------- |
| `server`        | 连接 IDA 内插件提供的 JSON-RPC 能力（常用模式，端口 13339）     |
| `idalib_server` | 基于 `idalib` 的无界面模式（需要本机 IDA 运行库） |

---

## 2. 主要能力

- 暴露 IDA 反汇编 / 反编译与符号信息查询能力
- 支持批量重命名、注释、类型相关操作（含 unsafe 工具）
- 支持自动安装 MCP 客户端配置与 IDA 插件入口
- 支持轻量辅助能力：
  - `get_current_context_summary`
  - `get_selected_function_overview`

---

## 3. 项目结构

```text
src/ida_pro_mcp/
├── __init__.py
├── server.py            # MCP 主服务（连接 IDA 插件 JSON-RPC）
├── idalib_server.py     # idalib 模式 MCP 服务
├── mcp-plugin.py        # IDA 侧插件（JSON-RPC 服务，基于 MCP-Test v1.6.0）
├── script_utils.py      # 脚本生成辅助
├── mcp_config.json      # 默认配置
└── server_generated.py  # 自动生成（请勿手改）
```

---

## 4. 环境要求

### 4.1 通用

- Python `>= 3.8`（兼容 IDA Pro 内置 Python 环境）
- IDA Pro `>= 7.5`（插件模式）

### 4.2 idalib 模式额外要求

- IDA Pro `>= 9.0`（`idapro` / `idalib` 运行库可用）
- 设置 `IDADIR` 到有效 IDA 安装目录

---

## 5. 安装

```bash
pip install -e .
```

可选依赖（按需）：

```bash
pip install angr frida-tools
```

---

## 6. 配置说明

默认配置文件：`src/ida_pro_mcp/mcp_config.json`

```json
{
  "host": "127.0.0.1",
  "port": 13339,
  "script_utils_path": "script_utils.py",
  "plugin": { "port": 13339, "auto_reuse": true, "auto_select_port": true },
  "simple_server": { "port": 13339 },
  "idalib_server": { "port": 8746 }
}
```

配置优先级（高 → 低）：

1. 环境变量
2. 配置文件
3. 代码内默认值

| 环境变量            | 说明                                                  |
| ------------------- | ----------------------------------------------------- |
| `MCP_HOST`        | 覆盖监听地址                                          |
| `MCP_PORT`        | 覆盖 `server.py` 的 RPC 目标端口                    |
| `IDALIB_MCP_PORT` | 覆盖 `idalib_server.py` 端口（优先于 `MCP_PORT`） |

> 注：若缺少配置文件，`server.py` 内置端口默认为 `13339`（与新版插件 MCP-Test v1.6.0 一致）。

---

## 7. 使用方法

### 7.1 安装 MCP 客户端配置与 IDA 插件

```bash
# 安装
ida-pro-mcp --install

# 卸载
ida-pro-mcp --uninstall
```

### 7.2 启动主 MCP 服务（连接 IDA 插件）

```bash
python -m ida_pro_mcp.server
```

常用参数：

| 参数                        | 说明                                                      |
| --------------------------- | --------------------------------------------------------- |
| `--transport`             | `stdio`（默认）或 `http://127.0.0.1:8744`             |
| `--ida-rpc`               | 指定 IDA 插件 RPC 地址（默认 `http://127.0.0.1:13339`） |
| `--unsafe`                | 启用危险工具                                              |
| `--config`                | 打印 MCP 客户端配置 JSON                                  |
| `--auto-run-ida <binary>` | 自动启动 IDA 并加载指定样本（Windows 体验更完整）         |

### 7.3 启动 idalib 模式

```bash
python -m ida_pro_mcp.idalib_server <binary_path> --host 127.0.0.1 --port 8746
```

若报错 `Cannot load IDA library file idalib.dll`，请检查：

- IDA 版本是否为 9.0+
- `IDADIR` 是否指向有效 IDA 安装目录

### 7.4 多 `.so` headless fleet（推荐给 AI 同时查看多个目标）

如果你希望让 Codex / Claude Code 同时接入两个及以上的 headless IDA 分析目标，不要把多个文件塞进同一个 `idalib_server` 进程里，而是采用“一文件一实例”的 fleet 方式。

如果你是想给另一个 AI 项目一个最短入口，直接看 [AI_MCP_QUICKSTART.md](D:/0Document/pgm/mcp/idapromcp_333/AI_MCP_QUICKSTART.md)。

仓库内提供了两个脚本：

- `tools/idalib_fleet.ps1`
- `tools/idalib_probe.py`

它们负责：

- 按 manifest 批量启动多个 `idalib_server`
- 为每个实例分配独立的 `IDAUSR`、PID、stdout/stderr 日志
- 用 `initialize -> list_tools -> get_metadata` 做健康检查
- 生成可直接粘贴到 Codex / Claude Code 的多实例 MCP 配置片段

示例 manifest：`examples/idalib-fleet.sample.json`

```json
{
  "python_exe": "D:\\Tools\\Python311\\python.exe",
  "ida_dir": "E:\\CS\\Tools\\IDA Pro 9.1",
  "transport": "streamable-http",
  "instances": [
    {
      "alias": "15083758libsec2026_runtime.so",
      "input_path": "D:\\0Document\\pgm\\Android\\ACE\\ACE2026-Pre\\question\\26-prelim\\output\\20260415083758\\libsec2026_runtime.so",
      "port": 8746,
      "enabled": true
    },
    {
      "alias": "13165417libsec2026_runtime.so",
      "input_path": "D:\\0Document\\pgm\\Android\\ACE\\ACE2026-Pre\\question\\26-prelim\\output\\20260413165154\\20260413165417\\libsec2026_runtime.so",
      "port": 8747,
      "enabled": true
    }
  ]
}
```

运行示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\idalib_fleet.ps1 `
  -Action start `
  -ManifestPath .\examples\idalib-fleet.sample.json

powershell -ExecutionPolicy Bypass -File .\tools\idalib_fleet.ps1 `
  -Action status `
  -ManifestPath .\examples\idalib-fleet.sample.json

powershell -ExecutionPolicy Bypass -File .\tools\idalib_fleet.ps1 `
  -Action config `
  -ManifestPath .\examples\idalib-fleet.sample.json `
  -Client all

powershell -ExecutionPolicy Bypass -File .\tools\idalib_fleet.ps1 `
  -Action stop `
  -ManifestPath .\examples\idalib-fleet.sample.json
```

支持的 action：

- `start`
- `stop`
- `restart`
- `status`
- `logs`
- `config`

fleet 的状态目录固定为：

```text
.idalib-fleet/<manifest-name>/
├── state.json
├── run/<safe-key>.pid
├── logs/<safe-key>.stdout.log
├── logs/<safe-key>.stderr.log
└── idausr/<safe-key>/
```

#### alias 与 safe key 规则

- manifest 中显式写了 `alias` 时，优先使用该值
- 若未写 `alias`，脚本会从最近的 `yyyyMMddHHmmss` 目录提取 `ddHHmmss`，再拼接文件名
- 若仍冲突，则自动追加数字后缀
- 配置片段使用 `safe key`，规则是把 alias 中除字母数字、`-`、`_` 之外的字符全部替换为 `_`

例如：

- `15083758libsec2026_runtime.so` -> `15083758libsec2026_runtime_so`
- `13165417libsec2026_runtime.so` -> `13165417libsec2026_runtime_so`

`config` 动作会输出：

- alias -> safe key -> port -> path 对照表
- Codex 配置片段，例如：

```toml
[mcp_servers."ida-android-idalib-15083758libsec2026_runtime_so"]
url = "http://127.0.0.1:8746/mcp"
```

- Claude Code 配置片段，例如：

```json
{
  "ida-pro-mcp-idalib-15083758libsec2026_runtime_so": {
    "type": "http",
    "url": "http://127.0.0.1:8746/mcp"
  }
}
```

注意事项：

- fleet 目前固定使用 `streamable-http`
- 端口必须在 manifest 中显式指定，不会自动顺延
- 若端口已被其他进程占用，`start` 会直接失败
- 健康检查以 `get_metadata.module == 原始文件名` 为准
- 该脚本只生成配置片段，不会自动改写你的 Codex / Claude Code 用户配置文件

### 7.5 直连插件 JSON-RPC（调试）

IDA 插件启动后，可对以下路径发起请求：

- `http://127.0.0.1:13339/mcp`
- `http://127.0.0.1:13339/jsonrpc`

示例：

```python
import json
import requests

resp = requests.post(
    "http://127.0.0.1:13339/jsonrpc",
    headers={"Content-Type": "application/json"},
    data=json.dumps({
        "jsonrpc": "2.0",
        "method": "check_connection",
        "params": [],
        "id": 1
    })
)
print(resp.json())
```

> 插件可在 IDA 中通过 `Edit → Plugins → IDA Pro MCP Test` 启动，热键为 `Ctrl+Alt+T`（macOS 下为 `Ctrl+Option+T`）。

就是安装插件那一套，ida里面开mcp即可。这些都是给ai看的，方便它甚至不用配置json就能跑

---

## 8. 项目完整性检查（本地）

最近一次检查结果：

| 检查项                                    | 状态          |
| ----------------------------------------- | ------------- |
| `python -m compileall src`              | ✅ 通过       |
| `python -m ida_pro_mcp.server --help`   | ✅ 通过       |
| `python -m ida_pro_mcp.server --config` | ✅ 通过       |
| `check_connection`（端口 13339）          | ✅ 通过       |
| `get_current_context_summary`           | ✅ 通过       |
| `get_selected_function_overview`        | ✅ 通过       |
| 轻量版接口验收                            | ✅ 40/40 通过 |

> 当前仓库未包含可直接执行的单元测试集合，`pytest` 依赖存在但需自行安装并补充测试用例。`idalib_server` 在无 IDA 运行库环境下无法直接导入，属于预期行为。

---

## 9. 常见问题

### 9.1 MCP 无法连接 IDA

- 确认 IDA 已加载样本
- 在 IDA 中手动启动插件：`Edit → Plugins → IDA Pro MCP Test`（默认热键 `Ctrl+Alt+T`）
- 检查端口占用与 `mcp_config.json` 端口一致性（默认 13339）

### 9.2 端口冲突

- 修改 `mcp_config.json` 中的 `port` / `plugin.port`（默认 13339）
- 或通过环境变量 `MCP_PORT` / `IDALIB_MCP_PORT` 覆盖

---

## 10. 开发说明

入口脚本：

- `ida-pro-mcp` → `ida_pro_mcp.server:main`
- `idalib-mcp` → `ida_pro_mcp.idalib_server:main`

> `server_generated.py` 由 `server.py` 动态生成，不建议手工维护。

---

## 11. 联系方式

### 开发者

| 名称    | 联系方式       |
| ------- | -------------- |
| name    | QQ：1559820232 |
| grand   | QQ：3527424707 |
| Britney | QQ：2855057900 |

### 项目链接

- GitHub 仓库：[https://github.com/namename333/idapromcp_333](https://github.com/namename333/idapromcp_333)
- 原项目：[https://github.com/mrexodia/ida-pro-mcp](https://github.com/mrexodia/ida-pro-mcp)

---

## 12. 许可证

本项目采用 [MIT License](https://opensource.org/licenses/MIT) 开源，任何人均可自由使用、复制、修改、合并、发布、分发、再授权或销售本软件，无需经过作者许可。

```
MIT License

Copyright (c) 2025 name, grand, Britney

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 13. 致谢

* 感谢 mrexodia 提供的原始 IDA Pro MCP 插件
* 感谢克劳德先生的辛苦付出
* 感谢所有为该项目做出贡献的开发者和用户
