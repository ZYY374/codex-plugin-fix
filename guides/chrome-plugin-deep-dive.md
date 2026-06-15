# Chrome 插件深度解析

## 为什么 Chrome 插件比 Browser 插件复杂

Codex 有两个浏览器控制插件：

| 插件 | 后端 | 机制 | 配置复杂度 |
|------|------|------|-----------|
| **Browser** (in-app) | Codex 内置浏览器 | 内部进程通信 | ⭐ 简单 |
| **Chrome** | Google Chrome | Windows Native Messaging | ⭐⭐⭐ 复杂 |

Chrome 插件需要借助 Windows 原生消息机制与 Chrome 浏览器通信，涉及注册表、manifest 文件、extension host 进程三部分。

## 三步走安装

### 1. Native Messaging Manifest

位置：`%LOCALAPPDATA%\OpenAI\extension\com.openai.codexextension.json`

```json
{
    "allowed_origins": ["chrome-extension://hehggadaopoacecdllhhajmbjkdcmajg/"],
    "description": "Codex chrome native messaging host",
    "name": "com.openai.codexextension",
    "path": "C:\\Users\\<user>\\.codex\\marketplaces\\openai-bundled\\plugins\\chrome\\extension-host\\windows\\x64\\extension-host.exe",
    "type": "stdio"
}
```

- `name`：Chrome 通过这个名字找到 manifest
- `path`：extension-host.exe 的绝对路径
- `allowed_origins`：只允许这个 Chrome 扩展连接

### 2. 注册表

键：`HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension`

默认值指向 manifest 文件路径。

Chrome 启动时会扫这个注册表位置，找到所有已注册的 Native Messaging Host。

### 3. Extension Host 配置

位置：`extension-host.exe` 同级目录的 `extension-host-config.json`

```json
{
    "browserClientPath": "...",
    "channel": "prod",
    "extensionId": "hehggadaopoacecdllhhajmbjkdcmajg",
    "nodePath": "...",
    "nodeReplPath": "...",
    "proxyHost": "127.0.0.1",
    "proxyPort": 0
}
```

extension-host.exe 启动时读取这个配置，知道去哪里找 node.exe、node_repl.exe、browser-client.mjs。

## 安装故障排查

### Chrome 插件安装后没反应

检查三步：

```powershell
# 1. Manifest 存在？
Test-Path "$env:LOCALAPPDATA\OpenAI\extension\com.openai.codexextension.json"

# 2. 注册表存在？
cmd /c "reg query HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension"

# 3. Extension host 存在？
Test-Path "C:\Users\$env:USERNAME\.codex\marketplaces\openai-bundled\plugins\chrome\extension-host\windows\x64\extension-host.exe"
```

三步全 True 才能正常工作。

### "无法连接到 Chrome"

1. 确保 Chrome 已打开
2. 确保 Chrome 没被其他程序远程控制（Chrome 只允许一个 debug 连接）
3. 检查 extension-host.exe 没有被杀软拦截

### 装了两个浏览器插件该用哪个？

- **Browser (in-app)**：功能完整，不依赖外部浏览器，推荐日常使用
- **Chrome**：适合需要在已登录的 Chrome 中操作（保留 cookie/session），或需要 Chrome 特定功能
