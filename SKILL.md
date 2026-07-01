---
name: codex-plugin-fix
description: Codex Desktop 插件问题一站式修复 — 支持自动更新后修复、备份恢复、Chrome 配置、更换 API 供应商等场景。
trigger: Codex 插件报错、消失、安装失败、更新后异常
---

# Codex 插件修复技能

## 适用场景

| 场景 | 症状 | 跳转 |
|------|------|------|
| 🔄 自动更新后异常 | 插件报 `exports` 错、市场找不到插件 | [场景 A](#场景-a自动更新后修复) |
| 🔑 更换 API 供应商 | 插件配置丢失、市场节消失 | [场景 B](#场景-b更换-api-供应商后修复) |
| 🌐 Chrome 插件专属 | Chrome 插件安装失败 | [场景 C](#场景-cchrome-插件专属) |
| 💾 备份/恢复 | 防止配置丢失 | [场景 D](#场景-d备份与恢复) |
| 🔍 不确定问题 | 先诊断再对症 | [诊断流程](#0-诊断先查清楚再动手) |

---

## 0. 诊断：先查清楚再动手

```powershell
# 1. Codex 版本
$pkg = Get-AppxPackage -Name "OpenAI.Codex"
Write-Host "Codex: $($pkg.Version)"

# 2. 运行时
$runtimeDir = "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node"
Get-ChildItem $runtimeDir -Directory | ForEach-Object { Write-Host "Runtime: $($_.Name)" }
$runtimeHash = (Get-ChildItem $runtimeDir -Directory | Sort-Object LastWriteTime -Descending)[0].Name

# 3. Marketplace 状态
$codexHome = "$env:USERPROFILE\.codex"
$mktDest = "$codexHome\marketplaces\openai-bundled"
Write-Host "Marketplace exists: $(Test-Path $mktDest)"
if (Test-Path $mktDest) {
    Write-Host "Marketplace files: $((Get-ChildItem $mktDest -Recurse -File).Count)"
    Write-Host "Plugin version: $((Get-Content '$mktDest\plugins\computer-use\.codex-plugin\plugin.json' -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue).version)"
}

# 4. config.toml 关键项
$configPath = "$codexHome\config.toml"
$config = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($configPath))
Write-Host "Has marketplace section: $($config -match '\[marketplaces\.openai-bundled\]')"
Write-Host "Has computer_use: $($config -match 'computer_use = true')"
Write-Host "Has browser plugin: $($config -match 'browser@openai-bundled')"
Write-Host "Has chrome plugin: $($config -match 'chrome@openai-bundled')"
Write-Host "Runtime hash in config matches: $($config -match $runtimeHash)"

# 5. v0.142.5+ js_repl 特性检查
try {
    $features = codex features list 2>$null
    $jsReplLine = ($features | Select-String "js_repl").ToString()
    Write-Host "js_repl status: $jsReplLine"
    if ($jsReplLine -match "removed") {
        Write-Host "⚠️  js_repl 已被移除 (v0.142.5+) — MCP 工具无法暴露给模型，本轮修复无法完全生效"
    }
} catch {
    Write-Host "js_repl status: unable to check"
}
```

输出解读：

| 检查项 | 异常值 | 对应修复 |
|--------|--------|----------|
| Marketplace exists | False 或 files < 500 | [场景 A-步骤 2](#a2-同步-marketplace-文件) |
| Plugin version 与 Codex 不同 | 版本号差异大 | [场景 A-步骤 2](#a2-同步-marketplace-文件) |
| Has marketplace section | False | [场景 A-步骤 5b](#a5b-确保-marketplace-节存在) |
| Has computer_use | False | [场景 A-步骤 5e](#a5e-确保-features-开启) |
| Has browser/chrome plugin | False | [场景 A-步骤 5c](#a5c-确保插件已启用) |
| Runtime hash matches | False | [场景 A-步骤 5a](#a5a-更新运行时-hash) |
| js_repl = removed | True (v0.142.5+) | ⚠️ 无解 — 见下方「v0.142.5+ 限制」 |

---

## 场景 A：自动更新后修复

流程：`诊断 → 同步文件 → 修复 exports → 更新 config → Chrome 专属 → 清缓存 → 重启`

### A1. 确认版本

```powershell
$pkg = Get-AppxPackage -Name "OpenAI.Codex"
$codexHome = "$env:USERPROFILE\.codex"
$mktDest = "$codexHome\marketplaces\openai-bundled"
$runtimeDir = "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node"
$runtimeHash = (Get-ChildItem $runtimeDir -Directory | Sort-Object LastWriteTime -Descending)[0].Name
$msixMkt = "$($pkg.InstallLocation)\app\resources\plugins\openai-bundled"
```

### A2. 同步 marketplace 文件

> **原理**：Codex 自动更新后 MSIX 内置市场文件是最新的，但不会自动同步到用户目录。旧文件版本不匹配导致 Codex 不认。

```powershell
cmd /c "rmdir /s /q `"$mktDest`"" 2>$null
[System.IO.Directory]::CreateDirectory($mktDest) | Out-Null

# EFS 绕过复制（WindowsApps 目录有加密）
function Copy-EFS { param($s,$d)
    if (!(Test-Path $d)) { [System.IO.Directory]::CreateDirectory($d)|Out-Null }
    Get-ChildItem $s | % {
        $dest = Join-Path $d $_.Name
        if ($_.PSIsContainer) { Copy-EFS $_.FullName $dest }
        else { [System.IO.File]::WriteAllBytes($dest, [System.IO.File]::ReadAllBytes($_.FullName)) }
    }
}
Copy-EFS $msixMkt $mktDest
Write-Host "Files: $((Get-ChildItem $mktDest -Recurse -File).Count)"
```

**⚠️ 关键规则**：
- 目标目录必须**非隐藏**（`marketplaces\` ✅，`.tmp\` ❌）
- 路径不要用 `\\?\` 前缀
- `.codex` 目录有 EFS 加密，只能用 `[System.IO.File]::WriteAllBytes` 写文件

### A3. 补充 computer-use 的 @oai/sky

```powershell
$runtimeSky = "$runtimeDir\$runtimeHash\bin\node_modules\@oai\sky"
$destSky = "$mktDest\plugins\computer-use\node_modules\@oai\sky"
Copy-EFS $runtimeSky $destSky
```

### A4. 修复 @oai/sky exports

> **原理**：`computer-use-client.mjs` import 了 `@oai/sky` 的子路径，但 `package.json` 的 `exports` 字段没声明。Node.js 严格执行 exports 限制，拒绝导入。

```powershell
$subpath = "./dist/project/cua/sky_js/src/targets/windows/internal/computer_use_client_base.js"

# Marketplace 中的 @oai/sky
$skyPkg = "$mktDest\plugins\computer-use\node_modules\@oai\sky\package.json"
$json = Get-Content $skyPkg -Raw | ConvertFrom-Json
$json.exports | Add-Member -MemberType NoteProperty -Name $subpath -Value $subpath -Force
$json | ConvertTo-Json -Depth 10 | Set-Content $skyPkg -Encoding UTF8

# 运行时中的 @oai/sky
$runtimeSkyPkg = "$runtimeDir\$runtimeHash\bin\node_modules\@oai\sky\package.json"
$json2 = Get-Content $runtimeSkyPkg -Raw | ConvertFrom-Json
$json2.exports | Add-Member -MemberType NoteProperty -Name $subpath -Value $subpath -Force
$json2 | ConvertTo-Json -Depth 10 | Set-Content $runtimeSkyPkg -Encoding UTF8
```

### A5. 更新 config.toml

> **原理**：`config.toml` 受 EFS 加密 + Codex 沙箱保护，普通工具写不进去。必须用 `[System.IO.File]::WriteAllBytes`。

```powershell
$configPath = "$codexHome\config.toml"
$bytes = [System.IO.File]::ReadAllBytes($configPath)
$content = [System.Text.Encoding]::UTF8.GetString($bytes)
```

#### A5a. 更新运行时 hash

Codex 更新后运行时 hash 会变，config.toml 中 4 处引用必须更新：

- `notify`
- `command`
- `NODE_REPL_NODE_MODULE_DIRS`
- `NODE_REPL_NODE_PATH`

```powershell
if ($content -match 'cua_node\\([a-f0-9]+)\\') { $oldHash = $Matches[1] }
$content = $content -replace $oldHash, $runtimeHash
```

#### A5b. 确保 marketplace 节存在

```toml
[marketplaces.openai-bundled]
last_updated = "<ISO timestamp>"
source = '<codexHome>\\marketplaces\\openai-bundled'
source_type = "local"
```

```powershell
if ($content -notmatch '\[marketplaces\.openai-bundled\]') {
    $escapedHome = $codexHome -replace '\\', '\\'
    $mktSection = @"
[marketplaces.openai-bundled]
last_updated = "$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
source = '$escapedHome\\marketplaces\\openai-bundled'
source_type = "local"

"@
    $content = $content -replace '(\[plugins\])', "$mktSection`n`$1"
}
```

#### A5c. 确保插件已启用

```powershell
if ($content -notmatch 'computer-use@openai-bundled') {
    $content = $content -replace '(\[plugins\.)', "[plugins.`"computer-use@openai-bundled`"]`nenabled = true`n`$1"
}
if ($content -notmatch 'browser@openai-bundled') {
    $content = $content -replace '(\[plugins\.)', "[plugins.`"browser@openai-bundled`"]`nenabled = true`n`$1"
}
if ($content -notmatch 'chrome@openai-bundled') {
    $content = $content -replace '(\[plugins\.)', "[plugins.`"chrome@openai-bundled`"]`nenabled = true`n`$1"
}
```

#### A5d. 更新版本号

```powershell
$pluginVer = (Get-Content "$mktDest\plugins\chrome\.codex-plugin\plugin.json" -Raw | ConvertFrom-Json).version
$content = $content -replace 'BROWSER_USE_CODEX_APP_VERSION = "[^"]*"', "BROWSER_USE_CODEX_APP_VERSION = `"$pluginVer`""
```

#### A5e. 确保 features 开启

```powershell
if ($content -notmatch 'computer_use = true') {
    $content = $content -replace '\[features\]', "[features]`ncomputer_use = true`nmemories = true"
}
```

#### A5f. 写入

```powershell
[System.IO.File]::WriteAllBytes($configPath, [System.Text.Encoding]::UTF8.GetBytes($content))
```

### A6. Chrome 插件专属

见 [场景 C](#场景-cchrome-插件专属)。

### A7. 清理缓存

```powershell
cmd /c "rmdir /s /q `"$codexHome\plugins\cache\openai-bundled`"" 2>$null
```

### ⚠️ v0.142.5+ 已知限制

Codex v0.142.5 及更高版本中，`js_repl` 和 `tool_search` 特性被标记为 `removed`。
**即使所有文件同步正确、config.toml 配置完美，MCP 工具（`mcp__node_repl__js`）也无法暴露给模型。**

验证方法：
```powershell
codex features list | Select-String "js_repl"
```
如果输出包含 `removed`，以下功能将不可用：
- Computer Use 插件（`sky.list_apps()`, `sky.click()` 等）
- Codex 内置 browser / chrome 插件

**替代方案：**
- 降级到 Codex v0.141.x 或更早版本
- 使用 Hermes 的 `computer_use` 工具（功能等价，无此限制）

本工具集修复的是**文件层面**的问题（marketplace 同步、exports、config）。架构层面的特性移除目前无法通过文件修复解决。

---

### A8. 最终验证

```powershell
Write-Host "=== 验证结果 ==="
Write-Host "Marketplace: $((Get-ChildItem $mktDest -Recurse -File).Count) files"
Write-Host "Plugin ver: $((Get-Content '$mktDest\plugins\computer-use\.codex-plugin\plugin.json' -Raw|ConvertFrom-Json).version)"
Write-Host "Config OK: $(([System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($configPath))) -match '\[marketplaces\.openai-bundled\]')"
Write-Host "Chrome reg: $(cmd /c 'reg query HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension 2>&1')"
```

**重启 Codex Desktop**。

---

## 场景 B：更换 API 供应商后修复

> **原理**：更换供应商时 Codex 会重写 `config.toml`，清空 marketplace 配置、插件条目、features 等。

### B1. 更换前备份（下次用）

```powershell
$backupDir = "$env:USERPROFILE\.codex\backups"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
Copy-Item "$env:USERPROFILE\.codex\config.toml" "$backupDir\config-$timestamp.toml"
Write-Host "Backed up to: $backupDir\config-$timestamp.toml"
```

### B2. 更换后修复

更换供应商完成后，跑一遍 [场景 A 的诊断](#0-诊断先查清楚再动手)，看哪些配置丢了，然后跳到对应的 A5 子步骤补回。

最常丢的：
- [A5b](#a5b-确保-marketplace-节存在) — marketplace 节
- [A5c](#a5c-确保插件已启用) — browser / chrome 插件条目
- [A5e](#a5e-确保-features-开启) — `computer_use = true`

---

## 场景 C：Chrome 插件专属

> **原理**：Chrome 插件需要通过 Windows 注册表 + Native Messaging 机制与 Chrome 浏览器通信。仅复制 marketplace 文件不够。

```powershell
$extId = "hehggadaopoacecdllhhajmbjkdcmajg"  # 来自 extension-id.json
$extHost = "$mktDest\plugins\chrome\extension-host\windows\x64\extension-host.exe"
$extHostDir = Split-Path $extHost -Parent
$runtimeDir = "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node"
$runtimeHash = (Get-ChildItem $runtimeDir -Directory | Sort-Object LastWriteTime -Descending)[0].Name

# C1. Native Messaging Manifest
$manifestDir = "$env:LOCALAPPDATA\OpenAI\extension"
[System.IO.Directory]::CreateDirectory($manifestDir) | Out-Null
$manifest = @{
    allowed_origins = @("chrome-extension://$extId/")
    description = "Codex chrome native messaging host"
    name = "com.openai.codexextension"
    path = $extHost
    type = "stdio"
} | ConvertTo-Json -Depth 3
[System.IO.File]::WriteAllBytes("$manifestDir\com.openai.codexextension.json",
    [System.Text.Encoding]::UTF8.GetBytes($manifest))

# C2. 注册表
cmd /c "reg add `"HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension`" /ve /t REG_SZ /d `"$manifestDir\com.openai.codexextension.json`" /f"

# C3. Extension Host 配置
$appConfig = @{
    browserClientPath = "$mktDest\plugins\chrome\scripts\browser-client.mjs"
    channel = "prod"
    extensionId = $extId
    nodePath = "$runtimeDir\$runtimeHash\bin\node.exe"
    nodeReplPath = "$runtimeDir\$runtimeHash\bin\node_repl.exe"
    proxyHost = "127.0.0.1"
    proxyPort = 0
} | ConvertTo-Json -Depth 2
[System.IO.File]::WriteAllBytes("$extHostDir\extension-host-config.json",
    [System.Text.Encoding]::UTF8.GetBytes($appConfig))
```

---

## 场景 D：备份与恢复

### D1. 创建备份

```powershell
$codexHome = "$env:USERPROFILE\.codex"
$backupDir = "$codexHome\backups"
$timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

# 备份 config.toml
Copy-Item "$codexHome\config.toml" "$backupDir\config-$timestamp.toml"

# 备份 marketplace
if (Test-Path "$codexHome\marketplaces") {
    Compress-Archive -Path "$codexHome\marketplaces" -DestinationPath "$backupDir\marketplaces-$timestamp.zip" -Force
}

Write-Host "Backup complete: $backupDir"
Get-ChildItem $backupDir | Select-Object Name, Length
```

### D2. 恢复

```powershell
$backupDir = "$env:USERPROFILE\.codex\backups"
$latestConfig = Get-ChildItem "$backupDir\config-*.toml" | Sort-Object LastWriteTime -Descending | Select-Object -First 1

# 恢复 config
$bytes = [System.IO.File]::ReadAllBytes($latestConfig.FullName)
[System.IO.File]::WriteAllBytes("$env:USERPROFILE\.codex\config.toml", $bytes)

# 恢复 marketplace（如果有 zip）
$latestMkt = Get-ChildItem "$backupDir\marketplaces-*.zip" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latestMkt) {
    Expand-Archive -Path $latestMkt.FullName -DestinationPath "$env:USERPROFILE\.codex\marketplaces" -Force
}

Write-Host "Restored from: $($latestConfig.Name)"
```

---

## 常见陷阱速查

| 问题 | 原因 | 解决 |
|------|------|------|
| 市场找不到插件 | 目录隐藏或 `\\?\` 前缀 | 用普通路径 + 非隐藏目录 |
| Computer Use 报 exports 错 | `@oai/sky` exports 缺少子路径 | [A4](#a4-修复-oaisky-exports) |
| 安装失败 | 缓存过时或权限问题 | 清缓存 → [A7](#a7-清理缓存) |
| 换供应商后插件全丢 | Codex 重置 config.toml | [场景 B](#场景-b更换-api-供应商后修复) |
| config.toml 写不进去 | EFS 加密 + 权限 | `[System.IO.File]::WriteAllBytes` |
| Chrome 装不上 | 注册表/manifest 缺失 | [场景 C](#场景-cchrome-插件专属) |
| 版本不匹配 | Codex 又更新了 | 重跑 [A2](#a2-同步-marketplace-文件) |
| js_repl = removed | v0.142.5+ 架构变更 | ⚠️ 文件修复无效，需降级或用 Hermes computer-use |

---

## 给其他 Agent 的使用说明

本技能支持多种 Agent 平台（Hermes / Reasonix 等）。其他用户可以通过以下方式加载：

1. **直接安装**：`/install-skill https://github.com/ZYY374/codex-plugin-fix`
2. **手动复制**：将本文件放入 `skills 目录下的 codex-plugin-fix/SKILL.md（如 `~/.hermes/skills/` 或 `.reasonix/skills/`）`
3. **独立脚本**：运行 `scripts/fix-codex-plugins.ps1`（无需 Agent 平台，独立运行）

技能会先跑 [诊断](#0-诊断先查清楚再动手)，然后根据输出跳转到对应场景执行修复。
