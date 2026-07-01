# fix-codex-plugins.ps1
# 独立修复脚本 — 独立 PowerShell 脚本，无需 Agent 平台
# 用法: powershell -ExecutionPolicy Bypass -File fix-codex-plugins.ps1

$ErrorActionPreference = "Stop"
Write-Host @"
╔══════════════════════════════════════╗
║   Codex 插件一键修复脚本             ║
║   支持: 自动更新后 / 换供应商后       ║
╚══════════════════════════════════════╝
"@

# ========== 诊断 ==========
Write-Host "[1/8] 诊断中..." -ForegroundColor Cyan

$pkg = Get-AppxPackage -Name "OpenAI.Codex"
if (!$pkg) { Write-Host "❌ 未找到 Codex Desktop" -ForegroundColor Red; exit 1 }

$codexHome = "$env:USERPROFILE\.codex"
$mktDest = "$codexHome\marketplaces\openai-bundled"
$runtimeDir = "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node"
$runtimeHash = (Get-ChildItem $runtimeDir -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)[0].Name
$msixMkt = "$($pkg.InstallLocation)\app\resources\plugins\openai-bundled"
$configPath = "$codexHome\config.toml"

Write-Host "  Codex 版本: $($pkg.Version)"
Write-Host "  运行时: $runtimeHash"
Write-Host "  Marketplace: $(if(Test-Path $mktDest){'存在 ('+(Get-ChildItem $mktDest -Recurse -File).Count+' 文件)'}else{'不存在'})"

$config = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($configPath))
Write-Host "  config marketplace 节: $($config -match '\[marketplaces\.openai-bundled\]')"
Write-Host "  config browser 插件: $($config -match 'browser@openai-bundled')"
Write-Host "  config chrome 插件: $($config -match 'chrome@openai-bundled')"
Write-Host "  config computer_use: $($config -match 'computer_use = true')"

# 代理检测
& {
    $proxyEnv = $env:HTTPS_PROXY, $env:HTTP_PROXY, $env:https_proxy, $env:http_proxy | Where-Object { $_ }
    if ($proxyEnv) { Write-Host "  代理 (env): $($proxyEnv -join ', ')" }
    $winhttp = cmd /c "netsh winhttp show proxy 2>&1"
    if ($winhttp -match "代理服务器") { Write-Host "  代理 (winhttp): $($winhttp -match '\d+\.\d+\.\d+\.\d+:\d+' | Out-String).Trim()" }
}

# v0.142.5+ js_repl 检查
try {
    $features = codex features list 2>$null
    $jsReplLine = ($features | Select-String "js_repl").ToString()
    Write-Host "  js_repl 状态: $jsReplLine"
    if ($jsReplLine -match "removed") {
        Write-Host "  ⚠️  js_repl 已被移除 (v0.142.5+) — MCP 工具无法暴露" -ForegroundColor Yellow
        $global:jsReplRemoved = $true
    }
} catch {
    Write-Host "  js_repl 状态: 无法检查"
}

# ========== 复制 marketplace ==========
Write-Host "[2/8] 同步 marketplace 文件..." -ForegroundColor Cyan

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
Write-Host "  已复制 $((Get-ChildItem $mktDest -Recurse -File).Count) 文件"

# ========== 补 @oai/sky ==========
Write-Host "[3/8] 补充 @oai/sky node_modules..." -ForegroundColor Cyan

$runtimeSky = "$runtimeDir\$runtimeHash\bin\node_modules\@oai\sky"
$destSky = "$mktDest\plugins\computer-use\node_modules\@oai\sky"
if (Test-Path $runtimeSky) {
    Copy-EFS $runtimeSky $destSky
    Write-Host "  已复制 $((Get-ChildItem $destSky -Recurse -File).Count) 文件"
} else {
    Write-Host "  ⚠️ 运行时 @oai/sky 不存在，跳过"
}

# ========== 修 exports ==========
Write-Host "[4/8] 修复 @oai/sky exports..." -ForegroundColor Cyan

$subpath = "./dist/project/cua/sky_js/src/targets/windows/internal/computer_use_client_base.js"

foreach ($p in @(
    "$mktDest\plugins\computer-use\node_modules\@oai\sky\package.json",
    "$runtimeDir\$runtimeHash\bin\node_modules\@oai\sky\package.json"
)) {
    if (Test-Path $p) {
        $json = Get-Content $p -Raw | ConvertFrom-Json
        if (($json.exports | Get-Member -MemberType NoteProperty).Name -notcontains $subpath) {
            $json.exports | Add-Member -MemberType NoteProperty -Name $subpath -Value $subpath -Force
            $json | ConvertTo-Json -Depth 10 | Set-Content $p -Encoding UTF8
            Write-Host "  已修复: $p"
        }
    }
}

# ========== 更新 config.toml ==========
Write-Host "[5/8] 更新 config.toml..." -ForegroundColor Cyan

$bytes = [System.IO.File]::ReadAllBytes($configPath)
$content = [System.Text.Encoding]::UTF8.GetString($bytes)

# 更新 hash
if ($content -match 'cua_node\\([a-f0-9]+)\\') { $oldHash = $Matches[1] }
$content = $content -replace $oldHash, $runtimeHash
Write-Host "  运行时 hash: $oldHash → $runtimeHash"

# marketplace 节
if ($content -notmatch '\[marketplaces\.openai-bundled\]') {
    $escapedHome = $codexHome -replace '\\', '\\'
    $mktSection = @"

[marketplaces.openai-bundled]
last_updated = "$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
source = '$escapedHome\\marketplaces\\openai-bundled'
source_type = "local"

"@
    $content = $content -replace '(\[plugins\])', "$mktSection`n`$1"
    Write-Host "  已添加 marketplace 节"
}

# 插件条目
foreach ($plugin in @("computer-use", "browser", "chrome")) {
    if ($content -notmatch "$plugin@openai-bundled") {
        $content = $content -replace '(\[plugins\.)', "[plugins.`"$plugin@openai-bundled`"]`nenabled = true`n`$1"
        Write-Host "  已添加 $plugin 插件条目"
    }
}

# 版本号
$pluginVer = (Get-Content "$mktDest\plugins\chrome\.codex-plugin\plugin.json" -Raw | ConvertFrom-Json).version
$content = $content -replace 'BROWSER_USE_CODEX_APP_VERSION = "[^"]*"', "BROWSER_USE_CODEX_APP_VERSION = `"$pluginVer`""
Write-Host "  版本号: $pluginVer"

# features
if ($content -notmatch 'computer_use = true') {
    $content = $content -replace '\[features\]', "[features]`ncomputer_use = true`nmemories = true"
    Write-Host "  已添加 computer_use = true"
}

[System.IO.File]::WriteAllBytes($configPath, [System.Text.Encoding]::UTF8.GetBytes($content))
Write-Host "  config.toml 已更新"

# ========== Chrome 专属 ==========
Write-Host "[6/8] Chrome 插件配置..." -ForegroundColor Cyan

$extId = "hehggadaopoacecdllhhajmbjkdcmajg"
$extHost = "$mktDest\plugins\chrome\extension-host\windows\x64\extension-host.exe"
$extHostDir = Split-Path $extHost -Parent

if (Test-Path $extHost) {
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

    cmd /c "reg add `"HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension`" /ve /t REG_SZ /d `"$manifestDir\com.openai.codexextension.json`" /f" 2>$null

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

    Write-Host "  Chrome 配置完成"
} else {
    Write-Host "  ⚠️ extension-host.exe 不存在，跳过 Chrome 配置"
}

# ========== 清缓存 ==========
Write-Host "[7/8] 清理插件缓存..." -ForegroundColor Cyan
cmd /c "rmdir /s /q `"$codexHome\plugins\cache\openai-bundled`"" 2>$null
Write-Host "  缓存已清理"

# ========== 验证 ==========
Write-Host "[8/8] 验证..." -ForegroundColor Cyan
$ok = $true
if ((Get-ChildItem $mktDest -Recurse -File).Count -lt 500) { Write-Host "  ❌ Marketplace 文件不足" -ForegroundColor Red; $ok = $false }
if (!(Test-Path "$mktDest\plugins\computer-use\node_modules\@oai\sky\package.json")) { Write-Host "  ❌ @oai/sky 缺失" -ForegroundColor Red; $ok = $false }
$config2 = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($configPath))
if ($config2 -notmatch '\[marketplaces\.openai-bundled\]') { Write-Host "  ❌ config marketplace 节缺失" -ForegroundColor Red; $ok = $false }
if ($config2 -notmatch 'computer-use@openai-bundled') { Write-Host "  ❌ config computer-use 插件缺失" -ForegroundColor Red; $ok = $false }
if ($config2 -notmatch 'computer_use = true') { Write-Host "  ❌ config computer_use 未开启" -ForegroundColor Red; $ok = $false }

if ($global:jsReplRemoved) {
    Write-Host ""
    Write-Host "⚠️  检测到 js_repl = removed (v0.142.5+) — 文件修复完成，但 MCP 工具无法暴露给模型" -ForegroundColor Yellow
    Write-Host "   替代方案: 降级 Codex 或使用 Hermes computer_use 工具"
}
if ($ok) {
    Write-Host ""
    Write-Host "✅ 全部修复完成！请重启 Codex Desktop" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "⚠️ 部分检查未通过，请查看上面的错误信息" -ForegroundColor Yellow
}
