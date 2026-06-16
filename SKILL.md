---
name: codex-plugin-fix
description: Codex Desktop 自动更新后修复插件（Computer Use、Chrome、Browser）报错、不显示、安装失败的完整流程
---

# Codex 插件修复技能

当 Codex Desktop 自动更新后插件（Computer Use、Chrome、Browser 等）出现报错、不显示、安装失败时，按以下流程排查修复。

## 快速修复（推荐）

直接运行自动化脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\fix-codex-plugins.ps1"
```

脚本会依次执行 6 个步骤并显示彩色进度。支持 **Appx 安装**和**非 Appx 安装**两种方式。

如果脚本无法运行（编码损坏等），按下面的手工步骤逐一执行。

---

## 流程概览

```
Codex 自动更新
  → 检测 Codex 安装（Appx / WindowsApps 扫描 / LocalAppData）
  → 备份 config.toml
  → 同步 marketplace 文件
  → 修复 @oai/sky exports
  → 更新 config.toml（幂等：hash + marketplace + plugins + features + sandbox）
  → Computer Use 运行时修复（环境变量 + helper_transport + .exe）
  → Chrome 特有：注册表 + manifest
  → 清理缓存 → 重启 Codex
```

---

## 1. 检查版本和路径

### 方法 A：Appx 安装（推荐）

```powershell
$pkg = Get-AppxPackage -Name "OpenAI.Codex"
$pkg.Version  # 如 26.609.4994.0
$msixMkt = "$($pkg.InstallLocation)\app\resources\plugins\openai-bundled"
```

### 方法 B：WindowsApps 扫描（Appx 检测失败时的 fallback）

`Get-AppxPackage` 可能因用户上下文不同而返回空（如 SYSTEM 账户、非 Appx 安装等）。此时直接扫描目录：

```powershell
$waBase = "C:\Program Files\WindowsApps"
$latest = Get-ChildItem $waBase -Directory -Filter "OpenAI.Codex_*" -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    Select-Object -First 1

# 26.608+ 新路径
$msixMkt = "$($latest.FullName)\app\resources\plugins\openai-bundled"
# 26.602 旧路径（fallback）
if (-not (Test-Path $msixMkt)) {
    $msixMkt = "$($latest.FullName)\resources\app\extensions\marketplace\openai-bundled"
}
```

### 方法 C：LocalAppData 检测（便携版 / 非标准安装）

```powershell
$pluginDirs = Get-ChildItem "$env:LOCALAPPDATA\OpenAI\Codex" -Recurse -Directory -Filter "openai-bundled" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -like "*\plugins\openai-bundled" -and $_.FullName -like "*\resources\*" }
$msixMkt = $pluginDirs[0].FullName
```

### 当前运行时

```powershell
Get-ChildItem "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node" -Directory
```

---

## 2. 同步 marketplace 文件

MSIX 内置市场文件是**最新**且**完整**的（含 scripts/node_modules）。必须复制到非隐藏目录。

```powershell
$mktDest = "$env:USERPROFILE\.codex\marketplaces\openai-bundled"

# 清旧 + 复制（EFS 绕过）
cmd /c "if exist `"$mktDest`" rmdir /s /q `"$mktDest`"" 2>$null
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

---

## 3. 补充 computer-use 的 @oai/sky

MSIX 的 computer-use 插件不包含 `node_modules/@oai/sky`，需从运行时补：

```powershell
$runtimeHash = (Get-ChildItem "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node" -Directory | Sort-Object Name)[0].Name
$runtimeSky = "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node\$runtimeHash\bin\node_modules\@oai\sky"
$destSky = "$mktDest\plugins\computer-use\node_modules\@oai\sky"
Copy-EFS $runtimeSky $destSky
```

---

## 4. 修复 @oai/sky exports

`computer-use-client.mjs` 需要的子路径不在 exports 中，Node.js 会拒绝导入。

```powershell
# 找到所有 @oai/sky/package.json
$skyPaths = @(
    "$env:USERPROFILE\.codex\marketplaces\openai-bundled\plugins\computer-use\node_modules\@oai\sky\package.json"
)
# 运行时版本
Get-ChildItem "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node" -Directory | % {
    $p = "$($_.FullName)\bin\node_modules\@oai\sky\package.json"
    if (Test-Path $p) { $skyPaths += $p }
}
# 缓存版本
$cache = "$env:USERPROFILE\.codex\plugins\cache\openai-bundled\plugins\computer-use\node_modules\@oai\sky\package.json"
if (Test-Path $cache) { $skyPaths += $cache }

$requiredExport = "./dist/project/cua/sky_js/src/targets/windows/internal/computer_use_client_base.js"

foreach ($skyPkg in $skyPaths) {
    $json = Get-Content $skyPkg -Raw -Encoding UTF8 | ConvertFrom-Json
    $existing = $json.exports | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
    if ($existing -contains $requiredExport) {
        Write-Host "[OK] 已存在: $skyPkg"
    } else {
        $json.exports | Add-Member -MemberType NoteProperty -Name $requiredExport -Value $requiredExport -Force
        $newJson = $json | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllBytes($skyPkg, [System.Text.Encoding]::UTF8.GetBytes($newJson))
        Write-Host "[FIXED] $skyPkg"
    }
}
```

---

## 5. 更新 config.toml（幂等）

config.toml 受 EFS/权限保护，**只能用 `[System.IO.File]::WriteAllBytes` 写入**。

### 5a. 更新运行时 hash

```powershell
$configPath = "$env:USERPROFILE\.codex\config.toml"
$bytes = [System.IO.File]::ReadAllBytes($configPath)
$content = [System.Text.Encoding]::UTF8.GetString($bytes)

# 当前运行时 hash
$runtimeHash = (Get-ChildItem "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node" -Directory | Sort-Object Name)[0].Name

# 找到所有旧 hash（32 位十六进制）并替换
$oldHashes = [regex]::Matches($content, '[0-9a-f]{32}') |
    Select-Object -ExpandProperty Value -Unique |
    Where-Object { $_ -ne $runtimeHash }
foreach ($old in $oldHashes) {
    $content = $content -replace $old, $runtimeHash
}
```

### 5b. 确保 marketplace 段存在（幂等 — 不会重复）

```powershell
$mktDest = "$env:USERPROFILE\.codex\marketplaces\openai-bundled"

# 检测重复段并清理
$mktMatches = [regex]::Matches($content, '\[marketplaces\.openai-bundled\]')
if ($mktMatches.Count -gt 1) {
    # 移除所有重复段，只保留一个
    $content = $content -replace '(?s)\[marketplaces\.openai-bundled\].*?(\r?\n\[|\z)', {
        if ($args[0].Groups[1].Value -match '^\r?\n\[') { $args[0].Groups[1].Value } else { "" }
    }
}

# 如果不存在则添加
if ($content -notmatch '\[marketplaces\.openai-bundled\]') {
    $content += @"

[marketplaces.openai-bundled]
last_updated = "$((Get-Date).ToString("o"))"
source = '$mktDest'
source_type = "local"
"@
}
```

**⚠️ critical**: 不能有 `\\?\` 前缀！source 必须用普通绝对路径。**幂等检查防止重复插入。**

### 5c. 确保插件已启用（幂等）

```powershell
$plugins = @("computer-use@openai-bundled", "browser@openai-bundled", "chrome@openai-bundled")
foreach ($plugin in $plugins) {
    if ($content -notmatch [regex]::Escape("[plugins.`"$plugin`"]")) {
        $content += @"

[plugins."$plugin"]
enabled = true
"@
    }
}
```

### 5d. 更新版本号

```powershell
$pluginVer = (Get-Content "$mktDest\plugins\chrome\.codex-plugin\plugin.json" -Raw -Encoding UTF8 | ConvertFrom-Json).version
$content = $content -replace 'BROWSER_USE_CODEX_APP_VERSION\s*=\s*"[^"]*"',
    "BROWSER_USE_CODEX_APP_VERSION = `"$pluginVer`""
```

### 5e. 确保 features 开启

```powershell
if ($content -notmatch '\[features\]') {
    $content += "`r`n`r`n[features]`r`ncomputer_use = true`r`n"
} elseif ($content -notmatch 'computer_use\s*=\s*true') {
    $content = $content -replace '(\[features\][\r\n]+)', "`$1computer_use = true`r`n"
}
```

### 5f. 确保 Windows sandbox 设置（Computer Use native pipe 必需）

```powershell
if ($content -notmatch '\[windows\]') {
    $content += "`r`n`r`n[windows]`r`nsandbox = `"unelevated`"`r`n"
} elseif ($content -notmatch 'sandbox\s*=\s*"unelevated"') {
    $content = $content -replace '(\[windows\][\r\n]+)', "`$1sandbox = `"unelevated`"`r`n"
}
```

### 写入（EFS-safe）

```powershell
[System.IO.File]::WriteAllBytes($configPath, [System.Text.Encoding]::UTF8.GetBytes($content))
```

---

## 6. Computer Use 运行时修复

Computer Use 插件要正常工作，除了 marketplace 和 config，还需要环境变量和关键文件。

### 6a. 设置环境变量（用户级，永久）

```powershell
$cuEnvName = "CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE"
$cuEnvCurrent = [Environment]::GetEnvironmentVariable($cuEnvName, "User")
if ($cuEnvCurrent -ne "1") {
    [Environment]::SetEnvironmentVariable($cuEnvName, "1", "User")
    Write-Host "已设置: $cuEnvName = 1"
} else {
    Write-Host "[OK] $cuEnvName = 1"
}
```

**⚠️ critical**: 缺少此变量则 Computer Use 在 Windows 上不认 native pipe，CU 图标不会出现。

### 6b. 检查 helper_transport.js

```powershell
$helper = "$env:USERPROFILE\.codex\marketplaces\openai-bundled\plugins\computer-use\scripts\helper_transport.js"
if (Test-Path $helper) {
    Write-Host "[OK] helper_transport.js: $((Get-Item $helper).Length) bytes"
} else {
    Write-Host "[WARN] helper_transport.js 缺失 — 如果 MSIX 也没有，需兼容版实现"
}
```

### 6c. 检查 codex-computer-use.exe

```powershell
$cuExe = "$env:USERPROFILE\.codex\marketplaces\openai-bundled\plugins\computer-use\scripts\codex-computer-use.exe"
if (Test-Path $cuExe) {
    Write-Host "[OK] codex-computer-use.exe: $((Get-Item $cuExe).Length) bytes"
} else {
    Write-Host "[WARN] codex-computer-use.exe 缺失 — Computer Use binary 不完整"
}
```

---

## 7. Chrome 插件专属修复

Chrome 插件安装需要 3 样东西：

```powershell
$extIdFile = "$mktDest\plugins\chrome\.codex-plugin\extension-id.json"
$extHost = "$mktDest\plugins\chrome\extension-host\windows\x64\extension-host.exe"
$extId = (Get-Content $extIdFile -Raw -Encoding UTF8 | ConvertFrom-Json).extensionId

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

# 6c. Extension host config
$runtimeHash = (Get-ChildItem "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node" -Directory | Sort-Object Name)[0].Name
$extHostDir = Split-Path $extHost -Parent
$appConfig = @{
    browserClientPath = "$mktDest\plugins\chrome\scripts\browser-client.mjs"
    channel = "prod"
    extensionId = $extId
    nodePath = "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node\$runtimeHash\bin\node.exe"
    nodeReplPath = "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node\$runtimeHash\bin\node_repl.exe"
    proxyHost = "127.0.0.1"
    proxyPort = 0
} | ConvertTo-Json -Depth 2
[System.IO.File]::WriteAllBytes("$extHostDir\extension-host-config.json",
    [System.Text.Encoding]::UTF8.GetBytes($appConfig))
```

---

## 8. 清理插件缓存

```powershell
cmd /c "if exist `"$env:USERPROFILE\.codex\plugins\cache\openai-bundled`" rmdir /s /q `"$env:USERPROFILE\.codex\plugins\cache\openai-bundled`"" 2>$null
```

---

## 9. 最终验证

```powershell
$mktDest = "$env:USERPROFILE\.codex\marketplaces\openai-bundled"
Write-Host "Marketplace files: $((Get-ChildItem $mktDest -Recurse -File).Count)"  # ~956
Write-Host "Plugin version: $((Get-Content '$mktDest\plugins\computer-use\.codex-plugin\plugin.json' -Raw|ConvertFrom-Json).version)"
Write-Host "@oai/sky subpath: $((Get-Content '$mktDest\plugins\computer-use\node_modules\@oai\sky\package.json' -Raw|ConvertFrom-Json).exports.PSObject.Properties.Name -contains './dist/.../computer_use_client_base.js')"
Write-Host "config marketplace: $(Select-String -Path $env:USERPROFILE\.codex\config.toml -Pattern 'source = .*marketplaces.*openai-bundled')"
Write-Host "Windows sandbox: $(Select-String -Path $env:USERPROFILE\.codex\config.toml -Pattern 'sandbox')"
Write-Host "Env CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE: $([Environment]::GetEnvironmentVariable('CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE','User'))"
Write-Host "helper_transport.js: $(if(Test-Path '$mktDest\plugins\computer-use\scripts\helper_transport.js'){'[OK]'}else{'[WARN]'})"
Write-Host "codex-computer-use.exe: $(if(Test-Path '$mktDest\plugins\computer-use\scripts\codex-computer-use.exe'){'[OK]'}else{'[WARN]'})"
```

---

## 常见陷阱

| 问题 | 原因 | 解决 |
|------|------|------|
| `Get-AppxPackage` 返回空 | 非 Appx 安装或用户上下文不同 | 使用方法 B（WindowsApps 扫描）或方法 C（LocalAppData） |
| 市场找不到插件 | marketplace 目录隐藏或 `\\?\` 前缀 | 用普通路径 + 非隐藏目录 |
| Computer Use 报 exports 错 | `@oai/sky` exports 缺少子路径 | 手动添加（步骤 4） |
| 安装失败 | 缓存过时或权限问题 | 清缓存 + 检查 marketplace 来源 |
| 换供应商后插件全丢 | Codex 重置 config.toml | 重跑步骤 5b-5e |
| config.toml 写不进去 | EFS 加密 + 权限限制 | 用 `[System.IO.File]::WriteAllBytes` |
| Chrome 插件装不上 | 注册表/manifest 未创建 | 执行步骤 6 |
| 插件版本不匹配 | Codex 更了新版本 | 重跑步骤 2-3 从新 MSIX 复制 |
| **插件有但 Codex 用不了** | sandbox/envar/helper_transport 缺失 | 执行步骤 5f + 6 |
| **CU 图标不出现** | 缺少 `CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE=1` | 执行步骤 6a + 重启 |
| **marketplace 段重复** | 多次修复插入重复配置 | 使用步骤 5b 的幂等写法或运行 `fix-codex-plugins.ps1`（自动清理） |
| **脚本编码损坏** | 下载/复制导致编码错误 | 直接按手工步骤执行，或用 `Get-Content -Raw` 检查脚本内容 |
