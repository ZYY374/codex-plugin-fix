<#
.SYNOPSIS
    Codex Desktop 自动更新后修复插件（Computer Use、Chrome、Browser）
.DESCRIPTION
    检测 Codex 安装 → 同步 marketplace → 修复 @oai/sky exports → 更新 config.toml → Chrome 注册表
    支持 Appx 安装和非 Appx（便携/zip）安装两种方式。
.NOTES
    编码：UTF-8 with BOM，PowerShell 5.x / 7.x 均可运行
#>

$ErrorActionPreference = "Stop"
$codexHome = "$env:USERPROFILE\.codex"
$backupDir = "$codexHome\backups"

# ============================================================
# 1. FIND CODEX — multi-method, fallback chain
# ============================================================
Write-Host "=== [1/7] 检测 Codex 安装 ===" -ForegroundColor Cyan

$msixMkt = $null
$codexVersion = $null

# Method 1: Appx package (most common)
$pkg = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue
if ($pkg) {
    $codexVersion = $pkg.Version.ToString()
    $msixMkt = "$($pkg.InstallLocation)\app\resources\plugins\openai-bundled"
    Write-Host "  [Appx] 版本: $codexVersion" -ForegroundColor Green
    Write-Host "  [Appx] 路径: $($pkg.InstallLocation)" -ForegroundColor Green
}

# Method 2: Scan WindowsApps directly (fallback when Get-AppxPackage fails)
if (-not $msixMkt -or -not (Test-Path $msixMkt)) {
    Write-Host "  Appx 检测失败或 marketplace 不存在，尝试扫描 WindowsApps..." -ForegroundColor Yellow
    $waBase = "C:\Program Files\WindowsApps"
    $codexDirs = Get-ChildItem $waBase -Directory -Filter "OpenAI.Codex_*" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    if ($codexDirs) {
        $latest = $codexDirs[0]
        # Try both known MSIX marketplace paths
        $candidates = @(
            "$($latest.FullName)\app\resources\plugins\openai-bundled",
            "$($latest.FullName)\resources\app\extensions\marketplace\openai-bundled"
        )
        foreach ($c in $candidates) {
            if (Test-Path $c) {
                $msixMkt = $c
                if ($latest.Name -match 'Codex_(\d+\.\d+\.\d+\.\d+)') {
                    $codexVersion = $Matches[1]
                }
                Write-Host "  [Scan] 找到: $msixMkt" -ForegroundColor Green
                break
            }
        }
    }
}

# Method 3: LocalAppData check (portable installs)
if (-not $msixMkt) {
    Write-Host "  WindowsApps 扫描无结果，检查 LocalAppData..." -ForegroundColor Yellow
    $localCodex = "$env:LOCALAPPDATA\OpenAI\Codex"
    $pluginDirs = Get-ChildItem $localCodex -Recurse -Directory -Filter "openai-bundled" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*\plugins\openai-bundled" -and $_.FullName -like "*\resources\*" }
    if ($pluginDirs) {
        $msixMkt = $pluginDirs[0].FullName
        Write-Host "  [Local] 找到: $msixMkt" -ForegroundColor Green
    }
}

# Final fallback: ask user
if (-not $msixMkt) {
    Write-Host "  [FAIL] 无法自动检测 Codex marketplace 路径。" -ForegroundColor Red
    Write-Host "  请手动指定 MSIX marketplace 路径（openai-bundled 目录）:" -ForegroundColor Yellow
    $msixMkt = Read-Host "  路径"
    if (-not (Test-Path $msixMkt)) {
        Write-Host "  指定路径不存在，退出。" -ForegroundColor Red
        exit 1
    }
}

if (-not $codexVersion) {
    # Try to extract version from path
    if ($msixMkt -match 'Codex[\\_]([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)') {
        $codexVersion = $Matches[1]
    } else {
        $codexVersion = "unknown"
    }
}
Write-Host "  Codex 版本: $codexVersion" -ForegroundColor Green
Write-Host "  Marketplace 源: $msixMkt" -ForegroundColor Green

# ============================================================
# 2. BACKUP config.toml
# ============================================================
Write-Host "`n=== [2/7] 备份 config.toml ===" -ForegroundColor Cyan

if (-not (Test-Path $backupDir)) {
    [System.IO.Directory]::CreateDirectory($backupDir) | Out-Null
}
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupPath = "$backupDir\config-$timestamp.toml"
if (Test-Path "$codexHome\config.toml") {
    [System.IO.File]::Copy("$codexHome\config.toml", $backupPath, $true)
    Write-Host "  已备份到: $backupPath" -ForegroundColor Green
} else {
    Write-Host "  config.toml 不存在，跳过备份" -ForegroundColor Yellow
}

# ============================================================
# 3. SYNC MARKETPLACE
# ============================================================
Write-Host "`n=== [3/7] 同步 marketplace 文件 ===" -ForegroundColor Cyan

$mktDest = "$codexHome\marketplaces\openai-bundled"

# EFS-safe recursive copy function
function Copy-EFS {
    param([string]$Source, [string]$Dest)
    if (-not (Test-Path $Dest)) {
        [System.IO.Directory]::CreateDirectory($Dest) | Out-Null
    }
    Get-ChildItem $Source -ErrorAction Stop | ForEach-Object {
        $destItem = Join-Path $Dest $_.Name
        if ($_.PSIsContainer) {
            Copy-EFS $_.FullName $destItem
        } else {
            try {
                [System.IO.File]::WriteAllBytes($destItem, [System.IO.File]::ReadAllBytes($_.FullName))
            } catch {
                Write-Host "    skip locked: $($_.Name)" -ForegroundColor DarkGray
            }
        }
    }
}

# Clean destination first (ignore locked files — Codex may be running)
$oldEAP = $ErrorActionPreference
$ErrorActionPreference = "SilentlyContinue"
cmd /c "if exist `"$mktDest`" rmdir /s /q `"$mktDest`"" 2>$null
# Fallback: if rmdir failed due to locks, delete what we can with PowerShell
if (Test-Path $mktDest) {
    Get-ChildItem $mktDest -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem $mktDest -Recurse -Directory -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
}
$ErrorActionPreference = $oldEAP
[System.IO.Directory]::CreateDirectory($mktDest) | Out-Null

Write-Host "  从 MSIX 复制 marketplace（EFS-safe）..."
Copy-EFS $msixMkt $mktDest

$fileCount = (Get-ChildItem $mktDest -Recurse -File -ErrorAction SilentlyContinue).Count
Write-Host "  复制完成: $fileCount 个文件" -ForegroundColor Green

# Resolve runtime path (needed for @oai/sky copy and hash updates)
$runtimeBase = "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node"
$latestHash = if (Test-Path $runtimeBase) {
    (Get-ChildItem $runtimeBase -Directory -ErrorAction SilentlyContinue | Sort-Object Name)[0].Name
} else { $null }

# 3b. 补充 computer-use 的 @oai/sky（MSIX 通常不含此模块，需从运行时补）
$cuNodeModules = "$mktDest\plugins\computer-use\node_modules"
$cuSkyDest = "$cuNodeModules\@oai\sky"
if (-not (Test-Path $cuSkyDest)) {
    $runtimeSky = "$runtimeBase\$latestHash\bin\node_modules\@oai\sky"
    if (Test-Path $runtimeSky) {
        Write-Host "  从运行时补充 @oai/sky..." -ForegroundColor Yellow
        Copy-EFS $runtimeSky $cuSkyDest
        Write-Host "  已补充 @oai/sky 到 marketplace 插件" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] 运行时也没有 @oai/sky，Computer Use 可能不完整" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [OK] @oai/sky 已存在于 marketplace 插件" -ForegroundColor Green
}

# 3c. Verify computer-use plugin integrity
$cuPluginJson = "$mktDest\plugins\computer-use\.codex-plugin\plugin.json"
if (Test-Path $cuPluginJson) {
    $cuVer = (Get-Content $cuPluginJson -Raw -Encoding UTF8 | ConvertFrom-Json).version
    Write-Host "  Computer Use 插件版本: $cuVer" -ForegroundColor Green
} else {
    Write-Host "  [WARN] computer-use plugin.json 缺失 — 插件不完整，Codex 可能找不到" -ForegroundColor Yellow
}

# ============================================================
# 4. FIX @oai/sky EXPORTS
# ============================================================
Write-Host "`n=== [4/7] 修复 @oai/sky exports ===" -ForegroundColor Cyan

$skyPkgPaths = @()

# Marketplace copy
$mktSky = "$mktDest\plugins\computer-use\node_modules\@oai\sky\package.json"
if (Test-Path $mktSky) { $skyPkgPaths += $mktSky }

# Runtime copies
$runtimeBase = "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node"
if (Test-Path $runtimeBase) {
    Get-ChildItem $runtimeBase -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $rtSky = "$($_.FullName)\bin\node_modules\@oai\sky\package.json"
        if (Test-Path $rtSky) { $skyPkgPaths += $rtSky }
    }
}

# Plugin cache copy
$cacheSky = "$codexHome\plugins\cache\openai-bundled\plugins\computer-use\node_modules\@oai\sky\package.json"
if (Test-Path $cacheSky) { $skyPkgPaths += $cacheSky }

$requiredExport = "./dist/project/cua/sky_js/src/targets/windows/internal/computer_use_client_base.js"
$fixedCount = 0

foreach ($skyPkg in $skyPkgPaths) {
    $json = Get-Content $skyPkg -Raw -Encoding UTF8 | ConvertFrom-Json
    $existing = $json.exports | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name

    if ($existing -contains $requiredExport) {
        Write-Host "  [OK] 已存在: $skyPkg" -ForegroundColor Green
    } else {
        $json.exports | Add-Member -MemberType NoteProperty -Name $requiredExport -Value $requiredExport -Force
        $newJson = $json | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllBytes($skyPkg, [System.Text.Encoding]::UTF8.GetBytes($newJson))
        Write-Host "  [FIXED] $skyPkg" -ForegroundColor Green
        $fixedCount++
    }
}

if ($fixedCount -eq 0) {
    Write-Host "  所有 @oai/sky exports 已正确，无需修复" -ForegroundColor Green
} else {
    Write-Host "  共修复 $fixedCount 处" -ForegroundColor Green
}

# ============================================================
# 5. UPDATE config.toml (idempotent) — includes sandbox for CU
# ============================================================
Write-Host "`n=== [5/7] 更新 config.toml ===" -ForegroundColor Cyan

$configPath = "$codexHome\config.toml"
if (-not (Test-Path $configPath)) {
    Write-Host "  config.toml 不存在，创建新文件..." -ForegroundColor Yellow
    [System.IO.File]::WriteAllBytes($configPath, [System.Text.Encoding]::UTF8.GetBytes(""))
}

$bytes = [System.IO.File]::ReadAllBytes($configPath)
$content = [System.Text.Encoding]::UTF8.GetString($bytes)

# 5a. Update runtime hash references (all old hashes → current)
if ($latestHash) {
    # Find all 32-char hex hashes in config that look like old runtime paths
    $hashPattern = '[0-9a-f]{32}'
    $oldHashes = [regex]::Matches($content, $hashPattern) |
        Select-Object -ExpandProperty Value -Unique |
        Where-Object { $_ -ne $latestHash }

    foreach ($old in $oldHashes) {
        # Only replace if the old hash actually exists as a directory reference
        if ($content -match [regex]::Escape($old)) {
            $content = $content -replace [regex]::Escape($old), $latestHash
            Write-Host "  运行时 hash: $old → $latestHash" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  未找到运行时 hash，跳过" -ForegroundColor Yellow
}

# 5b. Idempotent marketplace section — ensure exactly ONE occurrence
Write-Host "  检查 marketplace 配置..." -ForegroundColor Gray

$mktSection = @"

[marketplaces.openai-bundled]
last_updated = "$((Get-Date).ToString("o"))"
source = '$mktDest'
source_type = "local"
"@

# Count existing sections
$mktMatches = [regex]::Matches($content, '\[marketplaces\.openai-bundled\]')

if ($mktMatches.Count -gt 1) {
    # Duplicates found — remove ALL of them, then add once
    Write-Host "  [WARN] 发现 $($mktMatches.Count) 个重复的 marketplace 段，清理中..." -ForegroundColor Yellow
    # Remove all [marketplaces.openai-bundled] sections (multi-line until next [section] or EOF)
    $content = $content -replace '(?s)\[marketplaces\.openai-bundled\].*?(\r?\n\[|\z)', {
        if ($args[0].Groups[1].Value -match '^\r?\n\[') { $args[0].Groups[1].Value }
        else { "" }
    }
    $content = $content.TrimEnd() + $mktSection
    Write-Host "  已清理并重新添加 marketplace 段" -ForegroundColor Green
} elseif ($mktMatches.Count -eq 1) {
    Write-Host "  [OK] marketplace 段已存在" -ForegroundColor Green
} else {
    $content = $content.TrimEnd() + $mktSection
    Write-Host "  已添加 marketplace 段" -ForegroundColor Green
}

# 5c. Idempotent plugin sections
Write-Host "  检查插件配置..." -ForegroundColor Gray

$plugins = @("computer-use@openai-bundled", "browser@openai-bundled", "chrome@openai-bundled")
foreach ($plugin in $plugins) {
    $pluginSection = @"

[plugins."$plugin"]
enabled = true
"@
    if ($content -match [regex]::Escape("[plugins.`"$plugin`"]")) {
        # Exists — ensure enabled = true
        $escaped = [regex]::Escape("[plugins.`"$plugin`"]")
        $pattern = "(?s)($escaped.*?)(\r?\n\[|\z)"
        $replacement = "[plugins.`"$plugin`"]`r`nenabled = true`r`n`$2"
        $content = $content -replace $pattern, $replacement
        Write-Host "  [OK] $plugin" -ForegroundColor Green
    } else {
        $content = $content.TrimEnd() + $pluginSection
        Write-Host "  已添加 $plugin" -ForegroundColor Green
    }
}

# 5d. Features section — ensure computer_use = true
if ($content -match '\[features\]') {
    # Exists: ensure computer_use = true
    if ($content -match 'computer_use\s*=\s*true') {
        Write-Host "  [OK] features.computer_use = true" -ForegroundColor Green
    } else {
        $content = $content -replace '(\[features\][\r\n]+)', "`$1computer_use = true`r`n"
        Write-Host "  已设置 features.computer_use = true" -ForegroundColor Green
    }
} else {
    $content = $content.TrimEnd() + "`r`n`r`n[features]`r`ncomputer_use = true`r`n"
    Write-Host "  已添加 [features] 段" -ForegroundColor Green
}

# 5f. Windows sandbox — required for Computer Use native pipe
Write-Host "  检查 [windows] sandbox..." -ForegroundColor Gray
if ($content -match '\[windows\]') {
    if ($content -match 'sandbox\s*=\s*"unelevated"') {
        Write-Host "  [OK] sandbox = unelevated" -ForegroundColor Green
    } else {
        $content = $content -replace '(\[windows\][\r\n]+)', "`$1sandbox = `"unelevated`"`r`n"
        Write-Host "  已设置 sandbox = unelevated" -ForegroundColor Green
    }
} else {
    $content = $content.TrimEnd() + "`r`n`r`n[windows]`r`nsandbox = `"unelevated`"`r`n"
    Write-Host "  已添加 [windows] sandbox = unelevated" -ForegroundColor Green
}

# 5g. Update BROWSER_USE_CODEX_APP_VERSION
$pluginJson = "$mktDest\plugins\chrome\.codex-plugin\plugin.json"
if (Test-Path $pluginJson) {
    $pluginVer = (Get-Content $pluginJson -Raw -Encoding UTF8 | ConvertFrom-Json).version
    if ($pluginVer) {
        $content = $content -replace 'BROWSER_USE_CODEX_APP_VERSION\s*=\s*"[^"]*"',
            "BROWSER_USE_CODEX_APP_VERSION = `"$pluginVer`""
        Write-Host "  BROWSER_USE_CODEX_APP_VERSION = $pluginVer" -ForegroundColor Green
    }
}

# Write back (EFS-safe)
[System.IO.File]::WriteAllBytes($configPath, [System.Text.Encoding]::UTF8.GetBytes($content))
Write-Host "  config.toml 已保存" -ForegroundColor Green

# ============================================================
# 6. COMPUTER USE RUNTIME FIXES
# ============================================================
Write-Host "`n=== [6/7] Computer Use 运行时修复 ===" -ForegroundColor Cyan

# 6a. Set CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE environment variable
$cuEnvName = "CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE"
$cuEnvCurrent = [Environment]::GetEnvironmentVariable($cuEnvName, "User")
if ($cuEnvCurrent -ne "1") {
    [Environment]::SetEnvironmentVariable($cuEnvName, "1", "User")
    # Also set in current process so it's present for verification
    $env:CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE = "1"
    Write-Host "  已设置环境变量: $cuEnvName = 1 (用户级)" -ForegroundColor Green
} else {
    Write-Host "  [OK] 环境变量: $cuEnvName = 1" -ForegroundColor Green
}

# 6b. Verify helper_transport.js exists (needed for native pipe on older versions)
$helperTransport = "$mktDest\plugins\computer-use\scripts\helper_transport.js"
if (Test-Path $helperTransport) {
    $htSize = (Get-Item $helperTransport).Length
    Write-Host "  [OK] helper_transport.js ($htSize bytes)" -ForegroundColor Green
} else {
    Write-Host "  helper_transport.js 不存在（26.611+ 已内置，可忽略）" -ForegroundColor Gray
}

# 6c. Verify codex-computer-use.exe exists
$cuExe = "$mktDest\plugins\computer-use\scripts\codex-computer-use.exe"
if (Test-Path $cuExe) {
    $cuExeVer = (Get-Item $cuExe).Length
    Write-Host "  [OK] codex-computer-use.exe ($cuExeVer bytes)" -ForegroundColor Green
} else {
    Write-Host "  codex-computer-use.exe 不存在（26.611+ 已内置，可忽略）" -ForegroundColor Gray
}

# ============================================================
# 7. CHROME NATIVE MESSAGING
# ============================================================
Write-Host "`n=== [7/7] Chrome Native Messaging 配置 ===" -ForegroundColor Cyan

$chromePlugins = "$mktDest\plugins\chrome"
$extIdFile = "$chromePlugins\.codex-plugin\extension-id.json"
$extHost = "$chromePlugins\extension-host\windows\x64\extension-host.exe"

if (-not (Test-Path $extIdFile)) {
    Write-Host "  未找到 extension-id.json，跳过 Chrome 配置" -ForegroundColor Yellow
} elseif (-not (Test-Path $extHost)) {
    Write-Host "  未找到 extension-host.exe，跳过 Chrome 配置" -ForegroundColor Yellow
} else {
    $extId = (Get-Content $extIdFile -Raw -Encoding UTF8 | ConvertFrom-Json).extensionId
    if (-not $extId) {
        Write-Host "  extension-id.json 无效，跳过" -ForegroundColor Yellow
    } else {
        Write-Host "  Extension ID: $extId" -ForegroundColor Gray

        # Native messaging manifest
        $manifestDir = "$env:LOCALAPPDATA\OpenAI\extension"
        [System.IO.Directory]::CreateDirectory($manifestDir) | Out-Null
        $manifestPath = "$manifestDir\com.openai.codexextension.json"

        $manifest = @{
            allowed_origins = @("chrome-extension://$extId/")
            description     = "Codex chrome native messaging host"
            name            = "com.openai.codexextension"
            path            = $extHost
            type            = "stdio"
        } | ConvertTo-Json -Depth 3
        [System.IO.File]::WriteAllBytes($manifestPath, [System.Text.Encoding]::UTF8.GetBytes($manifest))
        Write-Host "  Manifest: $manifestPath" -ForegroundColor Green

        # Registry
        $regKey = "HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension"
        cmd /c "reg add `"$regKey`" /ve /t REG_SZ /d `"$manifestPath`" /f" 2>&1 | Out-Null
        Write-Host "  Registry: $regKey" -ForegroundColor Green

        # Extension host config
        $extHostDir = Split-Path $extHost -Parent
        $extConfigPath = "$extHostDir\extension-host-config.json"
        $extConfig = @{
            browserClientPath = "$chromePlugins\scripts\browser-client.mjs"
            channel           = "prod"
            extensionId       = $extId
            nodePath          = "$runtimeBase\$latestHash\bin\node.exe"
            nodeReplPath      = "$runtimeBase\$latestHash\bin\node_repl.exe"
            proxyHost         = "127.0.0.1"
            proxyPort         = 0
        } | ConvertTo-Json -Depth 2
        [System.IO.File]::WriteAllBytes($extConfigPath, [System.Text.Encoding]::UTF8.GetBytes($extConfig))
        Write-Host "  Extension host config: $extConfigPath" -ForegroundColor Green
    }
}

# ============================================================
# VERIFICATION
# ============================================================
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  修复完成！验证结果:" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "  Marketplace 文件数: $((Get-ChildItem $mktDest -Recurse -File -ErrorAction SilentlyContinue).Count)"
if (Test-Path "$mktDest\plugins\computer-use\.codex-plugin\plugin.json") {
    $cv = (Get-Content "$mktDest\plugins\computer-use\.codex-plugin\plugin.json" -Raw -Encoding UTF8 | ConvertFrom-Json).version
    Write-Host "  Computer Use 版本: $cv"
}
if ($skyPkgPaths.Count -gt 0 -and (Test-Path $skyPkgPaths[0])) {
    $skyExports = (Get-Content $skyPkgPaths[0] -Raw -Encoding UTF8 | ConvertFrom-Json).exports
    $hasSubpath = ($skyExports | Get-Member -MemberType NoteProperty).Name -contains $requiredExport
    Write-Host "  @oai/sky exports 修复: $(if($hasSubpath){'[OK]'}else{'[FAIL]'})"
}
Write-Host "  @oai/sky in marketplace: $(if(Test-Path "$mktDest\plugins\computer-use\node_modules\@oai\sky"){'[OK]'}else{'[MISSING]'})"
Write-Host "  sandbox: $(if((Get-Content $configPath -Raw) -match 'sandbox\s*=\s*\"unelevated\"'){'unelevated [OK]'}else{'[CHECK]'})"
Write-Host "  Env CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE: $([Environment]::GetEnvironmentVariable('CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE','User'))"
Write-Host "  备份: $backupPath"
Write-Host "`n  请重启 Codex Desktop 使修复生效。" -ForegroundColor Yellow
