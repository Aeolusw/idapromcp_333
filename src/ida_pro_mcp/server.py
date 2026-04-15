import os
import sys
import ast
import json
import shutil
import argparse
import http.client
from urllib.parse import urlparse

from mcp.server.fastmcp import FastMCP

# log_level 对于 Cline 正常工作是必需的：https://github.com/jlowin/fastmcp/issues/81
mcp = FastMCP(
    "github.com/namename333/idapromcp_333", 
    log_level="ERROR"
)

jsonrpc_request_id = 1

def get_config_file_path():
    """
    获取配置文件路径
    支持多种配置文件位置
    """
    # 优先检查用户目录
    user_dir = os.path.expanduser("~")
    config_paths = [
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "mcp_config.json"),
        os.path.join(user_dir, ".mcp_config.json"),
        os.path.join(user_dir, "mcp_config.json")
    ]
    
    # 检查是否存在IDA插件目录下的配置文件
    try:
        import ida_idaapi
        plugin_dir = ida_idaapi.idadir("plugins")
        config_paths.append(os.path.join(plugin_dir, "mcp_config.json"))
    except ImportError:
        pass  # 如果不在IDA环境中运行，忽略
    
    # 返回第一个存在的配置文件
    for path in config_paths:
        if os.path.exists(path):
            return path
    
    # 如果没有找到配置文件，返回默认路径
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "mcp_config.json")

def load_config():
    """
    加载配置文件
    返回配置字典，如果配置文件不存则返回默认配置
    """
    default_config = {
        "host": "127.0.0.1",
        "port": 13339,
    }

    def _pick_port(value):
        try:
            port = int(value)
        except (TypeError, ValueError):
            return None
        if 1 <= port <= 65535:
            return port
        return None
    
    config_path = get_config_file_path()
    if os.path.exists(config_path):
        try:
            with open(config_path, 'r', encoding='utf-8') as f:
                user_config = json.load(f)
                if isinstance(user_config, dict):
                    # 顶层port优先，其次兼容历史分组配置
                    port_candidates = [
                        user_config.get("port"),
                        user_config.get("plugin", {}).get("port") if isinstance(user_config.get("plugin"), dict) else None,
                        user_config.get("simple_server", {}).get("port") if isinstance(user_config.get("simple_server"), dict) else None,
                    ]
                    host = user_config.get("host")
                    if isinstance(host, str) and host.strip():
                        default_config["host"] = host
                    for candidate in port_candidates:
                        picked_port = _pick_port(candidate)
                        if picked_port is not None:
                            default_config["port"] = picked_port
                            break
        except Exception as e:
            print(f"警告: 加载配置文件失败: {e}")
    
    # 从环境变量覆盖配置
    if "MCP_HOST" in os.environ:
        default_config["host"] = os.environ["MCP_HOST"]
    
    if "MCP_PORT" in os.environ:
        picked_port = _pick_port(os.environ["MCP_PORT"])
        if picked_port is not None:
            default_config["port"] = picked_port
        else:
            print("警告: 环境变量MCP_PORT不是有效的端口号")
    
    return default_config

# 加载配置
config = load_config()

# 服务器配置
ida_host = config["host"]
ida_port = config["port"]

def make_jsonrpc_request(method: str, *params):
    """Make a JSON-RPC request to the IDA plugin"""
    global jsonrpc_request_id, ida_host, ida_port
    conn = http.client.HTTPConnection(ida_host, ida_port)
    request = {
        "jsonrpc": "2.0",
        "method": method,
        "params": list(params),
        "id": jsonrpc_request_id,
    }
    jsonrpc_request_id += 1

    try:
        conn.request("POST", "/jsonrpc", json.dumps(request), {
            "Content-Type": "application/json"
        })
        response = conn.getresponse()
        data = json.loads(response.read().decode())

        if "error" in data:
            error = data["error"]
            code = error["code"]
            message = error["message"]
            pretty = f"JSON-RPC error {code}: {message}"
            if "data" in error:
                pretty += "\n" + error["data"]
            raise Exception(pretty)

        result = data["result"]
        # NOTE: LLMs do not respond well to empty responses
        if result is None:
            result = "success"
        return result
    except Exception:
        raise
    finally:
        conn.close()

@mcp.tool()
def check_connection() -> str:
    """检查 IDA 插件是否正在运行"""
    try:
        result = make_jsonrpc_request("check_connection")
        if isinstance(result, dict) and result.get("status") == "ok":
            version = result.get("version", "未知")
            server = result.get("server", "IDA Pro MCP Plugin")
            return f"成功连接到 {server} (版本: {version})"
        metadata = make_jsonrpc_request("get_metadata")
        return f"成功连接到 IDA Pro (打开文件: {metadata['module']})"
    except Exception as e:
        if sys.platform == "darwin":
            shortcut = "Ctrl+Option+T"
        else:
            shortcut = "Ctrl+Alt+T"
        return f"无法连接到 IDA Pro! 请在 IDA 中通过 Edit -> Plugins -> IDA Pro MCP Test ({shortcut}) 启动插件服务器。"

# Code taken from https://github.com/namename333/idapromcp_333 (MIT License)
class MCPVisitor(ast.NodeVisitor):
    def __init__(self):
        self.types: dict[str, ast.ClassDef] = {}
        self.functions: dict[str, ast.FunctionDef] = {}
        self.descriptions: dict[str, str] = {}
        self.unsafe: list[str] = []

    def visit_FunctionDef(self, node):
        for decorator in node.decorator_list:
            if isinstance(decorator, ast.Name):
                if decorator.id == "jsonrpc":
                    for i, arg in enumerate(node.args.args):
                        arg_name = arg.arg
                        arg_type = arg.annotation
                        if arg_type is None:
                            raise Exception(f"缺少参数类型 {node.name}.{arg_name}")
                        if isinstance(arg_type, ast.Subscript):
                            assert isinstance(arg_type.value, ast.Name)
                            assert arg_type.value.id == "Annotated"
                            assert isinstance(arg_type.slice, ast.Tuple)
                            assert len(arg_type.slice.elts) == 2
                            annot_type = arg_type.slice.elts[0]
                            annot_description = arg_type.slice.elts[1]
                            assert isinstance(annot_description, ast.Constant)
                            node.args.args[i].annotation = ast.Subscript(
                                value=ast.Name(id="Annotated", ctx=ast.Load()),
                                slice=ast.Tuple(
                                    elts=[
                                    annot_type,
                                    ast.Call(
                                        func=ast.Name(id="Field", ctx=ast.Load()),
                                        args=[],
                                        keywords=[
                                        ast.keyword(
                                            arg="description",
                                            value=annot_description)])],
                                    ctx=ast.Load()),
                                ctx=ast.Load())
                        elif isinstance(arg_type, ast.Name):
                            pass
                        else:
                            raise Exception(f"意外的参数类型注解 {node.name}.{arg_name} -> {type(arg_type)}")

                    body_comment = node.body[0]
                    if isinstance(body_comment, ast.Expr) and isinstance(body_comment.value, ast.Constant):
                        new_body = [body_comment]
                        self.descriptions[node.name] = body_comment.value.value
                    else:
                        new_body = []

                    call_args = [ast.Constant(value=node.name)]
                    for arg in node.args.args:
                        call_args.append(ast.Name(id=arg.arg, ctx=ast.Load()))
                    new_body.append(ast.Return(
                        value=ast.Call(
                            func=ast.Name(id="make_jsonrpc_request", ctx=ast.Load()),
                            args=call_args,
                            keywords=[])))
                    decorator_list = [
                        ast.Call(
                            func=ast.Attribute(
                                value=ast.Name(id="mcp", ctx=ast.Load()),
                                attr="tool",
                                ctx=ast.Load()),
                            args=[],
                            keywords=[]
                        )
                    ]
                    node_nobody = ast.FunctionDef(node.name, node.args, new_body, decorator_list, node.returns, node.type_comment, lineno=node.lineno, col_offset=node.col_offset)
                    assert node.name not in self.functions, f"重复函数: {node.name}"
                    self.functions[node.name] = node_nobody
                elif decorator.id == "unsafe":
                    self.unsafe.append(node.name)

    def visit_ClassDef(self, node):
        for base in node.bases:
            if isinstance(base, ast.Name):
                if base.id == "TypedDict":
                    self.types[node.name] = node


SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
IDA_PLUGIN_PY = os.path.join(SCRIPT_DIR, "mcp-plugin.py")
GENERATED_PY = os.path.join(SCRIPT_DIR, "server_generated.py")

# NOTE: This is in the global scope on purpose
if not os.path.exists(IDA_PLUGIN_PY):
    raise RuntimeError(f"IDA 插件未找到 {IDA_PLUGIN_PY} (您是否移动了它？)")
with open(IDA_PLUGIN_PY, "r", encoding="utf-8") as f:
    code = f.read()
module = ast.parse(code, IDA_PLUGIN_PY)
visitor = MCPVisitor()
visitor.visit(module)
code = """# NOTE: This file has been automatically generated, do not modify!
# Architecture based on https://github.com/namename333/idapromcp_333 (MIT License)
import sys
if sys.version_info >= (3, 12):
    from typing import Annotated, Optional, TypedDict, Generic, TypeVar, NotRequired, Union
else:
    from typing_extensions import Annotated, Optional, TypedDict, Generic, TypeVar, NotRequired
    from typing import Union
from pydantic import Field

T = TypeVar("T")

"""
for type in visitor.types.values():
    code += ast.unparse(type)
    code += "\n\n"
for function in visitor.functions.values():
    code += ast.unparse(function)
    code += "\n\n"

# Wheels are commonly installed into a non-writable site-packages directory.
# The generated module is useful for debugging, but server startup must not depend
# on being able to write next to the installed package.
try:
    with open(GENERATED_PY, "w", encoding="utf-8") as f:
        f.write(code)
except OSError:
    pass
exec(compile(code, GENERATED_PY, "exec"))

# 所有可用的 MCP 函数列表 - 确保包含标准MCP协议接口
MCP_FUNCTIONS = ["check_connection", "get_methods"] + list(visitor.functions.keys())
UNSAFE_FUNCTIONS = visitor.unsafe

def generate_readme():
    print("README:")
    print(f"- `check_connection()`: 检查 IDA 插件是否正在运行。")
    def get_description(name: str):
        if name not in visitor.functions:
            return f"- `{name}()`: <函数未定义>"
        function = visitor.functions[name]
        signature = function.name + "("
        for i, arg in enumerate(function.args.args):
            if i > 0:
                signature += ", "
            signature += arg.arg
        signature += ")"
        description = visitor.descriptions.get(function.name, "<无描述>").strip()
        if description and description[-1] != ".":
            description += "."
        return f"- `{signature}`: {description}"
    for safe_function in MCP_FUNCTIONS:
        if safe_function in visitor.functions:
            print(get_description(safe_function))
    print("\n不安全函数 (`--unsafe` 标志需要)`:\n")
    for unsafe_function in UNSAFE_FUNCTIONS:
        if unsafe_function in visitor.functions:
            print(get_description(unsafe_function))
    print("\nMCP 配置:")
    mcp_config = {
        "mcpServers": {
            "github.com/namename333/idapromcp_333": {
            "command": get_python_executable(),
            "args": [
                __file__,
            ],
            "timeout": 1800,
            "disabled": False,
            }
        }
    }
    print(json.dumps(mcp_config, indent=2))

def get_python_executable():
    """获取 Python 可执行文件的路径"""
    venv = os.environ.get("VIRTUAL_ENV")
    if venv:
        if sys.platform == "win32":
            python = os.path.join(venv, "Scripts", "python.exe")
        else:
            python = os.path.join(venv, "bin", "python3")
        if os.path.exists(python):
            return python

    for path in sys.path:
        if sys.platform == "win32":
            path = path.replace("/", "\\")

        split = path.split(os.sep)
        if split[-1].endswith(".zip"):
            path = os.path.dirname(path)
            if sys.platform == "win32":
                python_executable = os.path.join(path, "python.exe")
            else:
                python_executable = os.path.join(path, "..", "bin", "python3")
            python_executable = os.path.abspath(python_executable)

            if os.path.exists(python_executable):
                return python_executable
    return sys.executable

def print_mcp_config():
    server_config = {
        "command": get_python_executable(),
        "args": [
            __file__,
        ],
        "timeout": 1800,
        "disabled": False,
        "paths": ["/jsonrpc", "/mcp"],
    }
    protocol_version = getattr(mcp, "protocol_version", None)
    if protocol_version:
        server_config["protocolVersion"] = protocol_version

    print(json.dumps({
            "mcpServers": {
                mcp.name: server_config
            }
        }, indent=2)
    )

def install_mcp_servers(*, uninstall=False, quiet=False, env=None):
    if env is None:
        env = {}

    if sys.platform == "win32":
        configs = {
            "Cline": (os.path.join(os.getenv("APPDATA"), "Code", "User", "globalStorage", "saoudrizwan.claude-dev", "settings"), "cline_mcp_settings.json"),
            "Roo Code": (os.path.join(os.getenv("APPDATA"), "Code", "User", "globalStorage", "rooveterinaryinc.roo-cline", "settings"), "mcp_settings.json"),
            "Claude": (os.path.join(os.getenv("APPDATA"), "Claude"), "claude_desktop_config.json"),
            "Cursor": (os.path.join(os.path.expanduser("~"), ".cursor"), "mcp.json"),
            "Windsurf": (os.path.join(os.path.expanduser("~"), ".codeium", "windsurf"), "mcp_config.json"),
            "LM Studio": (os.path.join(os.path.expanduser("~"), ".lmstudio"), "mcp.json"),
        }
    elif sys.platform == "darwin":
        configs = {
            "Cline": (os.path.join(os.path.expanduser("~"), "Library", "Application Support", "Code", "User", "globalStorage", "saoudrizwan.claude-dev", "settings"), "cline_mcp_settings.json"),
            "Roo Code": (os.path.join(os.path.expanduser("~"), "Library", "Application Support", "Code", "User", "globalStorage", "rooveterinaryinc.roo-cline", "settings"), "mcp_settings.json"),
            "Claude": (os.path.join(os.path.expanduser("~"), "Library", "Application Support", "Claude"), "claude_desktop_config.json"),
            "Cursor": (os.path.join(os.path.expanduser("~"), ".cursor"), "mcp.json"),
            "Windsurf": (os.path.join(os.path.expanduser("~"), ".codeium", "windsurf"), "mcp_config.json"),
            "Claude Code": (os.path.join(os.path.expanduser("~")), ".claude.json"),
            "LM Studio": (os.path.join(os.path.expanduser("~"), ".lmstudio"), "mcp.json"),
        }
    elif sys.platform == "linux":
        configs = {
            "Cline": (os.path.join(os.path.expanduser("~"), ".config", "Code", "User", "globalStorage", "saoudrizwan.claude-dev", "settings"), "cline_mcp_settings.json"),
            "Roo Code": (os.path.join(os.path.expanduser("~"), ".config", "Code", "User", "globalStorage", "rooveterinaryinc.roo-cline", "settings"), "mcp_settings.json"),
            "Cursor": (os.path.join(os.path.expanduser("~"), ".cursor"), "mcp.json"),
            "Windsurf": (os.path.join(os.path.expanduser("~"), ".codeium", "windsurf"), "mcp_config.json"),
            "Claude Code": (os.path.join(os.path.expanduser("~")), ".claude.json"),
            "LM Studio": (os.path.join(os.path.expanduser("~"), ".lmstudio"), "mcp.json"),
        }
    else:
        print(f"不支持的平台: {sys.platform}")
        return

    installed = 0
    for name, (config_dir, config_file) in configs.items():
        config_path = os.path.join(config_dir, config_file)
        if not os.path.exists(config_dir):
            action = "卸载" if uninstall else "安装"
            if not quiet:
                print(f"跳过 {name} {action}\n  配置: {config_path} (未找到)")
            continue
        if not os.path.exists(config_path):
            config = {}
        else:
            with open(config_path, "r", encoding="utf-8") as f:
                data = f.read().strip()
                if len(data) == 0:
                    config = {}
                else:
                    try:
                        config = json.loads(data)
                    except json.decoder.JSONDecodeError:
                        if not quiet:
                            print(f"跳过 {name} 卸载\n  配置: {config_path} (无效 JSON)")
                        continue
        if "mcpServers" not in config:
            config["mcpServers"] = {}
        mcp_servers = config["mcpServers"]
        if uninstall:
            if mcp.name not in mcp_servers:
                if not quiet:
                    print(f"跳过 {name} 卸载\n  配置: {config_path} (未安装)")
                continue
            del mcp_servers[mcp.name]
        else:
            merged_env = {}
            if mcp.name in mcp_servers:
                existing_env = mcp_servers[mcp.name].get("env", {})
                if isinstance(existing_env, dict):
                    merged_env.update(existing_env)
            merged_env.update(env)
            mcp_servers[mcp.name] = {
                "command": get_python_executable(),
                "args": [
                    __file__,
                ],
                "timeout": 1800,
                "disabled": False,
                "autoApprove": MCP_FUNCTIONS,
                "alwaysAllow": MCP_FUNCTIONS,
            }
            if merged_env:
                mcp_servers[mcp.name]["env"] = merged_env
        with open(config_path, "w", encoding="utf-8") as f:
            json.dump(config, f, indent=2)
        if not quiet:
            action = "卸载" if uninstall else "安装"
            print(f"{action} {name} MCP 服务器 (需要重启)\n  配置: {config_path}")
        installed += 1
    if not uninstall and installed == 0:
        print("没有 MCP 服务器安装。对于不支持的 MCP 客户端，请使用以下配置:\n")
        print_mcp_config()

def install_ida_plugin(*, uninstall: bool = False, quiet: bool = False):
    if sys.platform == "win32":
        ida_plugin_folder = os.path.join(os.getenv("APPDATA"), "Hex-Rays", "IDA Pro", "plugins")
    else:
        ida_plugin_folder = os.path.join(os.path.expanduser("~"), ".idapro", "plugins")
    plugin_destination = os.path.join(ida_plugin_folder, "mcp-plugin.py")
    script_utils_destination = os.path.join(ida_plugin_folder, "script_utils.py")
    script_utils_source = os.path.join(SCRIPT_DIR, "script_utils.py")
    if uninstall:
        for dst in [plugin_destination, script_utils_destination]:
            if os.path.exists(dst):
                os.remove(dst)
                if not quiet:
                    print(f"卸载 IDA 插件文件\n  路径: {dst}")
            else:
                if not quiet:
                    print(f"跳过卸载 (未找到): {dst}")
    else:
        # Create IDA plugins folder
        if not os.path.exists(ida_plugin_folder):
            os.makedirs(ida_plugin_folder)

        # 安装 mcp-plugin.py
        realpath = os.path.realpath(plugin_destination)
        if realpath == IDA_PLUGIN_PY:
            if not quiet:
                print(f"跳过 IDA 插件安装 (符号链接已是最新)\n  插件: {realpath}")
        else:
            if os.path.lexists(plugin_destination):
                os.remove(plugin_destination)
            try:
                os.symlink(IDA_PLUGIN_PY, plugin_destination)
            except OSError:
                shutil.copy(IDA_PLUGIN_PY, plugin_destination)
            if not quiet:
                print(f"安装 IDA Pro 插件 (需要重启 IDA)\n  插件: {plugin_destination}")

        # 安装 script_utils.py
        if os.path.exists(script_utils_source):
            if os.path.lexists(script_utils_destination):
                os.remove(script_utils_destination)
            try:
                os.symlink(script_utils_source, script_utils_destination)
            except OSError:
                shutil.copy(script_utils_source, script_utils_destination)
            if not quiet:
                print(f"安装 script_utils 模块\n  路径: {script_utils_destination}")

def auto_run_ida_and_load_file(binary_path):
    """自动启动 IDA Pro 并加载指定的二进制文件
    
    Args:
        binary_path: 要分析的二进制文件路径
    """
    import subprocess
    import time
    import os
    import platform
    
    if not os.path.exists(binary_path):
        print(f"错误: 无法找到文件 '{binary_path}'")
        return
    
    ida_path = None
    if platform.system() == "Windows":
        possible_paths = [
            os.path.join(os.getenv("ProgramFiles"), "IDA Pro 7.7", "ida64.exe"),
            os.path.join(os.getenv("ProgramFiles"), "IDA Pro 7.8", "ida64.exe"),
            os.path.join(os.getenv("ProgramFiles"), "IDA Pro 7.9", "ida64.exe"),
            os.path.join(os.getenv("ProgramFiles"), "IDA Pro 8.0", "ida64.exe"),
            os.path.join(os.getenv("ProgramFiles"), "IDA Pro 8.1", "ida64.exe"),
            os.path.join(os.getenv("ProgramFiles"), "IDA Pro 9.1", "ida64.exe"),
        ]
        for path in possible_paths:
            if os.path.exists(path):
                ida_path = path
                break
        if ida_path is None:
            ida_path = input("请输入 IDA Pro 可执行文件的完整路径: ")
            if not os.path.exists(ida_path):
                print(f"错误: 无效的 IDA Pro 路径 '{ida_path}'")
                return
    else:
        print("警告: 自动启动 IDA Pro 功能目前主要支持 Windows 系统")
        ida_path = "ida64"
    
    print(f"正在启动 IDA Pro ({ida_path}) 并加载文件 '{binary_path}'...")
    try:
        subprocess.Popen([ida_path, binary_path])
        print("IDA Pro 已启动，正在等待加载完成...")
        time.sleep(10)
        print("\n提示:\n")
        print("1. IDA Pro 已成功启动并加载了二进制文件")
        print("2. 请在 IDA Pro 中手动启动 MCP 插件 (Edit -> Plugins -> IDA Pro MCP Test 或按 Ctrl-Alt-T)")
        print("3. 启动 MCP 服务器以连接到 IDA Pro")
        print("   命令: python -m ida_pro_mcp.server")
    except Exception as e:
        print(f"启动 IDA Pro 时出错: {e}")

def main():
    global ida_host, ida_port
    parser = argparse.ArgumentParser(description="IDA Pro MCP Server")
    parser.add_argument("--install", action="store_true", help="安装 MCP 服务器和 IDA 插件")
    parser.add_argument("--uninstall", action="store_true", help="卸载 MCP 服务器和 IDA 插件")
    parser.add_argument("--generate-docs", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--install-plugin", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--transport", type=str, default="stdio", help="MCP 传输协议 (stdio 或 http://127.0.0.1:8744)")
    parser.add_argument("--ida-rpc", type=str, default=f"http://{ida_host}:{ida_port}", help=f"IDA RPC 服务器 (默认: http://{ida_host}:{ida_port})")
    parser.add_argument("--unsafe", action="store_true", help="启用不安全函数 (危险)")
    parser.add_argument("--config", action="store_true", help="生成 MCP 配置 JSON")
    parser.add_argument("--auto-run-ida", type=str, help="自动启动 IDA Pro 并加载指定的二进制文件")
    args = parser.parse_args()

    if args.install and args.uninstall:
        print("无法同时安装和卸载")
        return

    if args.install:
        install_mcp_servers()
        install_ida_plugin()
        return

    if args.uninstall:
        install_mcp_servers(uninstall=True)
        install_ida_plugin(uninstall=True)
        return

    if args.generate_docs:
        generate_readme()
        return

    if args.install_plugin:
        install_ida_plugin(quiet=True)

    if args.config:
        print_mcp_config()
        return

    if args.auto_run_ida:
        auto_run_ida_and_load_file(args.auto_run_ida)
        return

    ida_rpc = urlparse(args.ida_rpc)
    if ida_rpc.hostname is None or ida_rpc.port is None:
        raise Exception(f"无效的 IDA RPC 服务器: {args.ida_rpc}")
    ida_host = ida_rpc.hostname
    ida_port = ida_rpc.port

    if not args.unsafe:
        mcp_tools = mcp._tool_manager._tools
        for unsafe in UNSAFE_FUNCTIONS:
            if unsafe in mcp_tools:
                del mcp_tools[unsafe]

    try:
        if args.transport == "stdio":
            mcp.run(transport="stdio")
        else:
            url = urlparse(args.transport)
            if url.hostname is None or url.port is None:
                raise Exception(f"无效的传输 URL: {args.transport}")
            mcp.settings.host = url.hostname
            mcp.settings.port = url.port
            mcp.run(transport="streamable-http")
    except KeyboardInterrupt:
        pass

if __name__ == "__main__":
    main()
