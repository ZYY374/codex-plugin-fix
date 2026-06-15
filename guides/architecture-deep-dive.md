# 深入理解 Codex Desktop 的插件系统

> 本文适合想了解 Codex 插件工作原理、以及为什么自动更新会炸插件的技术读者。

## 架构概览

Codex Desktop 是一个 Electron + Windows App SDK 混合应用，通过 MSIX 打包发布在 Microsoft Store。它的插件系统由四层组成：

```
┌─────────────────────────────────┐
│  Codex Desktop UI (Electron)    │  ← 设置界面、市场浏览
├─────────────────────────────────┤
│  Plugin Marketplace             │  ← marketplace.json + .codex-plugin/
├─────────────────────────────────┤
│  MCP Server (node_repl.exe)     │  ← Node.js 运行时，执行插件脚本
├─────────────────────────────────┤
│  Windows Native (extension-host)│  ← Chrome 原生消息、Computer Use 管道
└─────────────────────────────────┘
```

## 第一层：Marketplace 发现机制

Codex 在启动时扫描 `config.toml` 中的 `[marketplaces.*]` 节，找到本地市场路径。然后读取 `.agents/plugins/marketplace.json`，解析每个插件的元数据。

关键代码逻辑（逆向推断）：

```javascript
// 伪代码：Codex 解析 marketplace
const marketplaceDir = config.marketplaces["openai-bundled"].source;
const manifest = readJSON(`${marketplaceDir}/.agents/plugins/marketplace.json`);

for (const plugin of manifest.plugins) {
  const pluginPath = resolve(marketplaceDir, plugin.source.path);
  const pluginJson = readJSON(`${pluginPath}/.codex-plugin/plugin.json`);
  
  if (isVersionCompatible(pluginJson.version, appVersion)) {
    showInMarketplace(plugin);
  }
}
```

这就是问题所在：

1. **路径解析**：如果 `source` 用了 `\\?\` 前缀，`resolve()` 可能无法正确处理 `./plugins/xxx` 相对路径
2. **隐藏目录**：如果 marketplace 在 `.tmp\` 下，Codex 的文件扫描可能跳过 dot 开头的目录
3. **版本检查**：如果 `plugin.json` 中的 version 和 Codex 期望的不一致，插件不会显示

## 第二层：运行时 hash

Codex 的 MCP server（`node_repl.exe`）和 Node.js 运行时按 hash 管理：

```
C:\Users\<user>\AppData\Local\OpenAI\Codex\runtimes\cua_node\
  2f053e67fec2d258\    ← 旧版本
  789504f803e82e2b\    ← 新版本
    bin\
      node.exe
      node_repl.exe
      node_modules\
        @oai\
          sky\           ← Computer Use 核心库
```

每次 Codex 更新，这个 hash 就会变。`config.toml` 中有 4 处引用：

```toml
notify = "...\\<hash>\\bin\\node_modules\\@oai\\sky\\bin\\windows\\codex-computer-use.exe"
command = '...\\<hash>\\bin\\node_repl.exe'
NODE_REPL_NODE_MODULE_DIRS = '...\\<hash>\\bin\\node_modules'
NODE_REPL_NODE_PATH = '...\\<hash>\\bin\\node.exe'
```

如果 hash 没更新，`node_repl.exe` 启动失败，所有插件不可用。

## 第三层：Node.js exports 陷阱

`computer-use-client.mjs` 中有这样一行：

```javascript
import { WindowsComputerUseClientBase } from "@oai/sky/dist/project/cua/sky_js/src/targets/windows/internal/computer_use_client_base.js";
```

但 `@oai/sky/package.json` 的 exports 字段只声明了：

```json
{
  "exports": {
    ".": "./dist/project/cua/sky_js/src/index.js"
  }
}
```

Node.js 的 `exports` 是一个**白名单**——只有声明过的路径才能被 import。这行 import 的目标路径不在白名单中，Node.js 直接抛错。

这应该是 Codex 的 bug：要么 `exports` 应该包含这个子路径，要么 `computer-use-client.mjs` 应该从 `"."` 入口导入。

## 第四层：Chrome Native Messaging

Chrome 插件与普通插件不同，它需要通过 Windows Native Messaging 协议与 Chrome 浏览器通信：

```
Chrome 浏览器
    ↕ Native Messaging Protocol (stdio)
extension-host.exe
    ↕ IPC
node_repl.exe (MCP Server)
    ↕
Codex Desktop
```

为此需要：
1. **注册表**：`HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension`
2. **Manifest 文件**：`%LOCALAPPDATA%\OpenAI\extension\com.openai.codexextension.json`
3. **Host 配置**：`extension-host-config.json`（extension-host.exe 同级目录）

三者缺一不可。只复制 marketplace 文件远远不够。

## EFS 加密与文件写入

`.codex` 目录被 Codex 设置了 EFS 加密 + 严格 ACL：

```
icacls .codex\config.toml
# CodexSandboxUsers:(RX)  ← 只读
# zyy:(F)                 ← 完全控制（但 EFS 拦截）
```

EFS 加密意味着文件在文件系统驱动层被透明加解密。普通用户态 API 在写入时会触发 EFS 驱动拦截。但 `.NET` 的 `[System.IO.File]::WriteAllBytes` 使用的是更底层的 Win32 API，有时能绕过这层拦截。

这是为什么我们只能用这个特定方法写入 config.toml。

## 总结

Codex Desktop 的插件系统非常精巧，但当前版本（26.609.x）对自动更新后的状态同步做得不够好。理解上述四层的机制，就能快速定位和修复绝大多数插件问题。

工具地址：https://github.com/ZYY374/codex-plugin-fix
