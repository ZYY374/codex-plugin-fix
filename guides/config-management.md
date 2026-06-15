# config.toml 管理：备份、恢复、迁移

## config.toml 是什么

位于 `C:\Users\<用户名>\.codex\config.toml`，是 Codex Desktop 的核心配置文件。TOML 格式，控制：

| 节 | 内容 |
|----|------|
| 顶层 | `model`, `model_provider`, `notify`, `personality` |
| `[model_providers.*]` | API 供应商配置（URL、token） |
| `[features]` | `js_repl`, `computer_use`, `memories` |
| `[mcp_servers.node_repl]` | 运行时路径、环境变量 |
| `[marketplaces.*]` | 插件市场来源路径 |
| `[plugins.*]` | 每个插件的启用状态 |
| `[windows]` | 沙箱级别 |
| `[memories]` | 记忆功能设置 |
| `[projects.*]` | 项目信任列表 |

## 自动备份脚本

每次 Codex 更新前、或你想改设置前，先跑：

```powershell
# 保存为 backup-config.ps1
$codexHome = "$env:USERPROFILE\.codex"
$backupDir = "$codexHome\backups"
$timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")

New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

# 备份 config
Copy-Item "$codexHome\config.toml" "$backupDir\config-$timestamp.toml" -ErrorAction SilentlyContinue

# 备份 marketplace（如果有）
if (Test-Path "$codexHome\marketplaces") {
    Compress-Archive -Path "$codexHome\marketplaces" -DestinationPath "$backupDir\marketplaces-$timestamp.zip" -Force
}

# 备份 chrome native hosts
if (Test-Path "$codexHome\chrome-native-hosts-v2.json") {
    Copy-Item "$codexHome\chrome-native-hosts-v2.json" "$backupDir\chrome-native-hosts-$timestamp.json"
}

Write-Host "✅ 备份完成: $backupDir"
Get-ChildItem $backupDir | Sort-Object LastWriteTime -Descending | Select-Object -First 5
```

## 恢复备份

```powershell
# 保存为 restore-config.ps1
$codexHome = "$env:USERPROFILE\.codex"
$backupDir = "$codexHome\backups"

# 列出可用备份
Write-Host "可用备份:"
Get-ChildItem "$backupDir\config-*.toml" | Sort-Object LastWriteTime -Descending | ForEach-Object { Write-Host "  $_" }

# 恢复最新的
$latestConfig = Get-ChildItem "$backupDir\config-*.toml" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$bytes = [System.IO.File]::ReadAllBytes($latestConfig.FullName)
[System.IO.File]::WriteAllBytes("$codexHome\config.toml", $bytes)
Write-Host "✅ 已恢复: $($latestConfig.Name)"

# 恢复 marketplace
$latestMkt = Get-ChildItem "$backupDir\marketplaces-*.zip" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latestMkt) {
    Expand-Archive -Path $latestMkt.FullName -DestinationPath "$codexHome\marketplaces" -Force
    Write-Host "✅ Marketplace 已恢复"
}
```

## 安全更换 API 供应商

直接去 Codex 设置里改供应商 → Codex 会**重置 config.toml**，丢失大量配置。

**正确流程**：

1. **先备份**（跑上面的备份脚本）
2. 打开 `%USERPROFILE%\.codex\config.toml`
3. 修改这几个字段：
```toml
[model_providers.custom]
base_url = "你的新地址"
experimental_bearer_token = "你的新 token"
```
4. 保存后**重启 Codex**
5. 如果插件丢了，跑 [SKILL.md 场景 B](../SKILL.md#场景-b更换-api-供应商后修复)

## config.toml 写入注意事项

`.codex` 目录有 EFS 加密保护，以下方法**全部失败**：

| 方法 | 结果 |
|------|------|
| `Set-Content` / `Out-File` | ❌ Access Denied |
| `[System.IO.File]::WriteAllText` | ❌ Access Denied |
| `Copy-Item` | ❌ Access Denied |
| VS Code 直接保存 | ❌ EFS error |
| **`[System.IO.File]::WriteAllBytes`** | ✅ 成功 |
| 先写到临时文件再 `Move-Item -Force` | ✅ 有时可行 |

推荐写法：
```powershell
$configPath = "$env:USERPROFILE\.codex\config.toml"
$bytes = [System.IO.File]::ReadAllBytes($configPath)
$content = [System.Text.Encoding]::UTF8.GetString($bytes)
# ... 修改 $content ...
[System.IO.File]::WriteAllBytes($configPath, [System.Text.Encoding]::UTF8.GetBytes($content))
```

## 配置文件关键行速查

| 行 | 作用 | 丢了会怎样 |
|----|------|------------|
| `model = "gpt-5.5"` | 模型 | 没模型 |
| `base_url = "..."` | API 地址 | 连不上 |
| `computer_use = true` | CU 功能 | 灰掉 |
| `[marketplaces.openai-bundled]` | 插件来源 | 市场空的 |
| `[plugins."computer-use@openai-bundled"]` | CU 插件 | 不显示 |
| `NODE_REPL_NODE_MODULE_DIRS` | 运行时 node_modules | 插件启动失败 |
| `NODE_REPL_NODE_PATH` | Node.js 路径 | 同上 |
| `BROWSER_USE_CODEX_APP_VERSION` | 版本匹配 | 插件不认 |
