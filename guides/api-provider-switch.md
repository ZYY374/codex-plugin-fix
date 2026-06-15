# 安全更换 API 供应商（不丢插件配置）

## 问题

Codex Desktop 设置界面里更换供应商时，会**重写整个 config.toml**，导致：
- ❌ marketplace 配置丢失 → 插件市场变空
- ❌ 插件条目被删 → 已安装插件消失
- ❌ `computer_use = true` 丢失 → CU 功能灰掉
- ❌ `memories` 设置丢失

## 正确做法：手动改 config.toml

### 1. 备份（必须）

```powershell
$codexHome = "$env:USERPROFILE\.codex"
$timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
Copy-Item "$codexHome\config.toml" "$codexHome\config-backup-$timestamp.toml"
Write-Host "已备份"
```

### 2. 编辑 config.toml

用记事本打开 `%USERPROFILE%\.codex\config.toml`，找到这一段：

```toml
[model_providers.custom]
name = "custom"
wire_api = "responses"
requires_openai_auth = true
base_url = "旧地址"
experimental_bearer_token = "旧token"
```

改成你的新供应商地址和 token：

```toml
base_url = "新地址"
experimental_bearer_token = "新token"
```

### 3. 保存

Ctrl+S 保存。如果保存失败（EFS 加密），用这个 PowerShell 写法：

```powershell
$configPath = "$env:USERPROFILE\.codex\config.toml"
$bytes = [System.IO.File]::ReadAllBytes($configPath)
$content = [System.Text.Encoding]::UTF8.GetString($bytes)
$content = $content -replace 'base_url = "旧地址"', 'base_url = "新地址"'
$content = $content -replace 'experimental_bearer_token = "旧token"', 'experimental_bearer_token = "新token"'
[System.IO.File]::WriteAllBytes($configPath, [System.Text.Encoding]::UTF8.GetBytes($content))
```

### 4. 重启 Codex

重启后检查插件是否都在。

### 5. 如果还是丢了

跑 `/codex-plugin-fix` 技能的 [场景 B](SKILL.md#场景-b更换-api-供应商后修复)。

## 为什么不推荐在设置界面改？

Codex 的设置界面是"全量重写"，不是"增量更新"。它生成的 config.toml 只包含当前界面可见的选项，你之前手动加的 marketplace、插件配置全被清空。

## 常见供应商配置

### OpenAI 官方
```toml
base_url = "https://api.openai.com/v1"
```

### 本地代理 / 中转
```toml
base_url = "http://127.0.0.1:57321/v1"
```

### 其他中转站
```toml
base_url = "https://你的中转站地址/v1"
```
