---
name: codex-plugin-fix
description: Codex Desktop 自动更新后修复插件（Computer Use、Chrome、Browser）报错、不显示、安装失败的完整流程
---

# Codex 插件修复技能

当 Codex Desktop 自动更新后插件（Computer Use、Chrome、Browser 等）出现报错、不显示、安装失败时，按以下流程排查修复。

## 流程概览

```
Codex 自动更新
  → 检查版本号 & MSIX 路径
  → 检查 config.toml 运行时 hash
  → 修复 @oai/sky exports
  → 同步 marketplace 文件
  → Chrome 特有：注册表 + manifest
  → 重启 Codex
```

---

## 1. 检查版本和路径

```powershell
# Codex 版本
$pkg = Get-AppxPackage -Name "OpenAI.Codex"
$pkg.Version  # 如 26.609.4994.0

# MSIX marketplace 新位置（26.608+）
$msixMkt = "$($pkg.InstallLocation)\app\resources\plugins\openai-bundled"

# 当前运行时
Get-ChildItem "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node" -Directory

# 路径变量（后续步骤复用）
$codexHome = "$env:USERPROFILE\.codex"
$mktDest = "$codexHome\marketplaces\openai-bundled"
$runtimeDir = "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node"
```

## 2. 同步 marketplace 文件

MSIX 内置市场文件是**最新**且**完整**的（含 scripts/node_modules）。必须复制到非隐藏目录。

```powershell
$msixMkt = "$($pkg.InstallLocation)\app\resources\plugins\openai-bundled"

# 清旧 + 复制（EFS 绕过）
cmd /c "rmdir /s /q `"$mktDest`"" 2>$null
[System.IO.Directory]::CreateDirectory($mktDest) | Out-Null

function Copy-EFS { param($s,$d)
    if (!(Test-Path $d)) { [System.IO.Directory]::CreateDirectory($d)|Out-Null }
    Get-ChildItem $s | % {
        $dest = Join-Path $d $_.Name
        if ($_.PSIsContainer) { Copy-EFS $_.FullName $dest }
        else { [System.IO.File]::WriteAllBytes($dest, [System.IO.File]::ReadAllBytes($_.FullName)) }
    }
}
Copy-EFS $msixMkt $mktDest
```

**⚠️ critical**: 目标目录必须是**非隐藏**目录（如 `marketplaces\` 而非 `.tmp\`），不能用 `\\?\` 前缀。

## 3. 补充 computer-use 的 @oai/sky

MSIX 的 computer-use 插件不包含 `node_modules/@oai/sky`，需从运行时补：

```powershell
# 找到最新运行时 hash
$runtimeHash = (Get-ChildItem $runtimeDir -Directory | Sort-Object LastWriteTime -Descending)[0].Name
$runtimeSky = "$runtimeDir\$runtimeHash\bin\node_modules\@oai\sky"
$destSky = "$mktDest\plugins\computer-use\node_modules\@oai\sky"
Copy-EFS $runtimeSky $destSky
```

## 4. 修复 @oai/sky exports

`computer-use-client.mjs` 需要的子路径不在 exports 中，Node.js 会拒绝导入。

```powershell
# 修复 marketplace 中的 @oai/sky
$skyPkg = "$mktDest\plugins\computer-use\node_modules\@oai\sky\package.json"
$json = Get-Content $skyPkg -Raw | ConvertFrom-Json
$json.exports | Add-Member -MemberType NoteProperty `
  -Name "./dist/project/cua/sky_js/src/targets/windows/internal/computer_use_client_base.js" `
  -Value "./dist/project/cua/sky_js/src/targets/windows/internal/computer_use_client_base.js" -Force
$json | ConvertTo-Json -Depth 10 | Set-Content $skyPkg -Encoding UTF8

# 同样修复运行时中的 @oai/sky
$runtimeSkyPkg = "$runtimeDir\$runtimeHash\bin\node_modules\@oai\sky\package.json"
$json2 = Get-Content $runtimeSkyPkg -Raw | ConvertFrom-Json
$json2.exports | Add-Member -MemberType NoteProperty `
  -Name "./dist/project/cua/sky_js/src/targets/windows/internal/computer_use_client_base.js" `
  -Value "./dist/project/cua/sky_js/src/targets/windows/internal/computer_use_client_base.js" -Force
$json2 | ConvertTo-Json -Depth 10 | Set-Content $runtimeSkyPkg -Encoding UTF8
```

## 5. 更新 config.toml

config.toml 受 EFS/权限保护，**只能用 `[System.IO.File]::WriteAllBytes` 写入**。

### 5a. 更新运行时 hash（4 处）

```powershell
$configPath = "$codexHome\config.toml"
$bytes = [System.IO.File]::ReadAllBytes($configPath)
$content = [System.Text.Encoding]::UTF8.GetString($bytes)

# 找到旧 hash（从 config 中读取）
if ($content -match 'cua_node\\([a-f0-9]+)\\') { $oldHash = $Matches[1] }
$content = $content -replace $oldHash, $runtimeHash

[System.IO.File]::WriteAllBytes($configPath, [System.Text.Encoding]::UTF8.GetBytes($content))
```

影响的行：
```
notify = "...\\<old_hash>\\..."
command = '...\\<old_hash>\\...'
NODE_REPL_NODE_MODULE_DIRS = '...\\<old_hash>\\...'
NODE_REPL_NODE_PATH = '...\\<old_hash>\\...'
```

### 5b. 确保 marketplace 节存在

```toml
[marketplaces.openai-bundled]
last_updated = "<ISO timestamp>"
source = '<codexHome>\\marketplaces\\openai-bundled'
source_type = "local"
```

**⚠️ critical**: 不能有 `\\?\` 前缀！source 必须用普通绝对路径。

如果 config.toml 缺少此节：

```powershell
$escapedHome = $codexHome -replace '\\', '\\'
$mktSection = @"
[marketplaces.openai-bundled]
last_updated = "$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
source = '$escapedHome\\marketplaces\\openai-bundled'
source_type = "local"

"@
$content = $content -replace '(\[plugins\])', "$mktSection`n`$1"
[System.IO.File]::WriteAllBytes($configPath, [System.Text.Encoding]::UTF8.GetBytes($content))
```

### 5c. 确保插件已启用

```toml
[plugins."computer-use@openai-bundled"]
enabled = true
[plugins."browser@openai-bundled"]
enabled = true
[plugins."chrome@openai-bundled"]
enabled = true
```

### 5d. 更新版本号

```powershell
$pluginVer = (Get-Content "$mktDest\plugins\computer-use\.codex-plugin\plugin.json" -Raw | ConvertFrom-Json).version
$content = $content -replace 'BROWSER_USE_CODEX_APP_VERSION = "[^"]*"', "BROWSER_USE_CODEX_APP_VERSION = `"$pluginVer`""
```

### 5e. 确保 features 开启

```toml
[features]
computer_use = true
memories = true
```

## 6. Chrome 插件专属修复

Chrome 插件安装需要 3 样东西：

```powershell
$extId = "hehggadaopoacecdllhhajmbjkdcmajg"  # 来自 extension-id.json
$extHost = "$mktDest\plugins\chrome\extension-host\windows\x64\extension-host.exe"
$extHostDir = Split-Path $extHost -Parent

# 6a. Native messaging manifest
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

# 6b. Registry
cmd /c "reg add `"HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension`" /ve /t REG_SZ /d `"$manifestDir\com.openai.codexextension.json`" /f"

# 6c. Extension host config（extension-host.exe 同级目录）
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

## 7. 清理插件缓存

```powershell
cmd /c "rmdir /s /q `"$codexHome\plugins\cache\openai-bundled`"" 2>$null
```

## 8. 最终验证

```powershell
Write-Host "Marketplace files: $((Get-ChildItem $mktDest -Recurse -File).Count)"
Write-Host "Plugin version: $((Get-Content '$mktDest\plugins\computer-use\.codex-plugin\plugin.json' -Raw|ConvertFrom-Json).version)"
Write-Host "config marketplace: $(Select-String -Path $codexHome\config.toml -Pattern 'source = .*marketplaces.*openai-bundled')"
Write-Host "Chrome registry: $(cmd /c 'reg query HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension 2>&1')"
```

---

## 常见陷阱

| 问题 | 原因 | 解决 |
|------|------|------|
| 市场找不到插件 | marketplace 目录隐藏或 `\\?\` 前缀 | 用普通路径 + 非隐藏目录 |
| Computer Use 报 exports 错 | `@oai/sky` exports 缺少子路径 | 手动添加 |
| 安装失败 | 缓存过时或权限问题 | 清缓存 + 检查 marketplace 来源 |
| 换供应商后插件全丢 | Codex 重置 config.toml | 重跑步骤 5b-5e |
| config.toml 写不进去 | EFS 加密 + 权限限制 | 用 `[System.IO.File]::WriteAllBytes` |
| Chrome 插件装不上 | 注册表/manifest 未创建 | 执行步骤 6 |
| 插件版本不匹配 | Codex 更了新版本 | 重跑步骤 2-3 从新 MSIX 复制 |
