# Codex 自动更新后完整修复教程

## 为什么 Codex 自动更新会炸插件

Codex Desktop 通过 Microsoft Store 静默更新，每次更新会：

1. **更换 MSIX 路径** — 安装目录从 `OpenAI.Codex_旧版本` 变成 `OpenAI.Codex_新版本`
2. **内部结构可能变化** — 26.608+ 版本 marketplace 从 `resources\app\extensions\` 搬到了 `app\resources\plugins\`
3. **插件版本升级** — 市场里的插件 metadata（plugin.json）版本号跟着变
4. **运行时 hash 刷新** — `C:\Users\<user>\AppData\Local\OpenAI\Codex\runtimes\cua_node\<hash>\` 换新

但 config.toml 和用户本地的 marketplace 副本**不会自动同步**，导致版本不匹配。

## 一步一步修

### 第 1 步：确认更新了

打开 PowerShell，粘贴：

```powershell
$pkg = Get-AppxPackage -Name "OpenAI.Codex"
Write-Host "当前版本: $($pkg.Version)"
Write-Host "安装位置: $($pkg.InstallLocation)"
```

记住版本号（如 `26.609.4994.0`），后面会用。

### 第 2 步：同步市场文件

Codex 把最新插件文件放在安装目录里，我们需要复制到用户目录。

```powershell
# 源（MSIX 内置）
$msixMkt = "$($pkg.InstallLocation)\app\resources\plugins\openai-bundled"

# 目标（用户目录，注意是 marketplaces 不是 .tmp）
$mktDest = "$env:USERPROFILE\.codex\marketplaces\openai-bundled"

# 删除旧的，建新的
cmd /c "rmdir /s /q `"$mktDest`"" 2>$null
[System.IO.Directory]::CreateDirectory($mktDest) | Out-Null

# 复制（EFS 加密绕过）
function Copy-EFS { param($s,$d)
    if (!(Test-Path $d)) { [System.IO.Directory]::CreateDirectory($d)|Out-Null }
    Get-ChildItem $s | % {
        $dest = Join-Path $d $_.Name
        if ($_.PSIsContainer) { Copy-EFS $_.FullName $dest }
        else { [System.IO.File]::WriteAllBytes($dest, [System.IO.File]::ReadAllBytes($_.FullName)) }
    }
}
Copy-EFS $msixMkt $mktDest

Write-Host "复制完成: $((Get-ChildItem $mktDest -Recurse -File).Count) 个文件"
```

### 第 3 步：补 @oai/sky

Computer Use 插件的 node_modules 不在 MSIX 里，要从运行时补：

```powershell
$runtimeDir = "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node"
$runtimeHash = (Get-ChildItem $runtimeDir -Directory | Sort-Object LastWriteTime -Descending)[0].Name
$runtimeSky = "$runtimeDir\$runtimeHash\bin\node_modules\@oai\sky"
$destSky = "$mktDest\plugins\computer-use\node_modules\@oai\sky"
Copy-EFS $runtimeSky $destSky
```

### 第 4 步：修 @oai/sky exports

```powershell
$subpath = "./dist/project/cua/sky_js/src/targets/windows/internal/computer_use_client_base.js"

foreach ($pkgPath in @(
    "$mktDest\plugins\computer-use\node_modules\@oai\sky\package.json",
    "$runtimeDir\$runtimeHash\bin\node_modules\@oai\sky\package.json"
)) {
    $json = Get-Content $pkgPath -Raw | ConvertFrom-Json
    if (($json.exports | Get-Member -MemberType NoteProperty).Name -notcontains $subpath) {
        $json.exports | Add-Member -MemberType NoteProperty -Name $subpath -Value $subpath -Force
        $json | ConvertTo-Json -Depth 10 | Set-Content $pkgPath -Encoding UTF8
        Write-Host "Fixed: $pkgPath"
    }
}
```

### 第 5 步：更新 config.toml

```powershell
$configPath = "$env:USERPROFILE\.codex\config.toml"
$bytes = [System.IO.File]::ReadAllBytes($configPath)
$content = [System.Text.Encoding]::UTF8.GetString($bytes)

# 5a. 更新运行时 hash（4 处）
if ($content -match 'cua_node\\([a-f0-9]+)\\') { $oldHash = $Matches[1] }
$content = $content -replace $oldHash, $runtimeHash

# 5b. 确保 marketplace 节
if ($content -notmatch '\[marketplaces\.openai-bundled\]') {
    $escapedHome = $env:USERPROFILE -replace '\\', '\\'
    $mktSection = @"

[marketplaces.openai-bundled]
last_updated = "$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
source = '$escapedHome\\.codex\\marketplaces\\openai-bundled'
source_type = "local"

"@
    $content = $content -replace '(\[plugins\])', "$mktSection`n`$1"
}

# 5c. 确保插件条目
foreach ($plugin in @("computer-use", "browser", "chrome")) {
    if ($content -notmatch "$plugin@openai-bundled") {
        $content = $content -replace '(\[plugins\.)', "[plugins.`"$plugin@openai-bundled`"]`nenabled = true`n`$1"
    }
}

# 5d. 更新版本号
$pluginVer = (Get-Content "$mktDest\plugins\chrome\.codex-plugin\plugin.json" -Raw | ConvertFrom-Json).version
$content = $content -replace 'BROWSER_USE_CODEX_APP_VERSION = "[^"]*"', "BROWSER_USE_CODEX_APP_VERSION = `"$pluginVer`""

# 5e. 确保 features
if ($content -notmatch 'computer_use = true') {
    $content = $content -replace '\[features\]', "[features]`ncomputer_use = true`nmemories = true"
}

# 写入
[System.IO.File]::WriteAllBytes($configPath, [System.Text.Encoding]::UTF8.GetBytes($content))
Write-Host "config.toml 已更新"
```

### 第 6 步：Chrome 插件（如果需要用 Chrome 的话）

```powershell
$extId = "hehggadaopoacecdllhhajmbjkdcmajg"
$extHost = "$mktDest\plugins\chrome\extension-host\windows\x64\extension-host.exe"
$extHostDir = Split-Path $extHost -Parent

# Manifest
$manifestDir = "$env:LOCALAPPDATA\OpenAI\extension"
[System.IO.Directory]::CreateDirectory($manifestDir) | Out-Null
@{ allowed_origins = @("chrome-extension://$extId/"); description = "Codex chrome native messaging host"; name = "com.openai.codexextension"; path = $extHost; type = "stdio" } | ConvertTo-Json -Depth 3 | Set-Content "$manifestDir\com.openai.codexextension.json" -Encoding UTF8

# 注册表
cmd /c "reg add `"HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension`" /ve /t REG_SZ /d `"$manifestDir\com.openai.codexextension.json`" /f"

# Host config
@{ browserClientPath = "$mktDest\plugins\chrome\scripts\browser-client.mjs"; channel = "prod"; extensionId = $extId; nodePath = "$runtimeDir\$runtimeHash\bin\node.exe"; nodeReplPath = "$runtimeDir\$runtimeHash\bin\node_repl.exe"; proxyHost = "127.0.0.1"; proxyPort = 0 } | ConvertTo-Json -Depth 2 | Set-Content "$extHostDir\extension-host-config.json" -Encoding UTF8
```

### 第 7 步：清缓存 + 重启

```powershell
cmd /c "rmdir /s /q `"$env:USERPROFILE\.codex\plugins\cache\openai-bundled`"" 2>$null
Write-Host "缓存已清理，请重启 Codex Desktop"
```

---

## 为什么必须这么做（技术原理）

### 为什么不能直接用 MSIX 里的 marketplace？

因为：
1. WindowsApps 目录权限很特殊，Codex 安装插件时需要往 marketplace 目录写缓存
2. Computer Use 插件的 `node_modules` 不全，MSIX 只放 metadata

### 为什么 `\\?\` 路径前缀会出问题？

`\\?\` 是 Windows 扩展路径前缀，绕过 MAX_PATH 限制。但 Codex 内部解析 marketplace source 时，如果带了 `\\?\` 可能无法正确解析 `.agents/plugins/marketplace.json` 中的相对路径 `./plugins/xxx`。

### 为什么 config.toml 用普通方式写不进去？

`.codex` 目录被 Codex 设置了 EFS（Encrypting File System）加密 + 严格的 ACL。PowerShell 的 `Set-Content`、`Out-File` 等命令会被拦截。只有 `[System.IO.File]::WriteAllBytes` 能绕过（因为它在文件系统驱动层操作）。

### 为什么 `@oai/sky` 需要手动修 exports？

Node.js 的 `exports` 字段是 package.json 里用来控制哪些文件可以被外部 import 的"白名单"。如果没有声明某个子路径，Node.js 会直接拒绝 `import from "@oai/sky/sub/path"`。Codex 的 `computer-use-client.mjs` 用了一个内部子路径，但 `@oai/sky` 的 package.json 没声明。这应该是 Codex 的 bug，手动补上不影响功能。
