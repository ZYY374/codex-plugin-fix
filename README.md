# Codex Toolkit

一套完整的 Codex Desktop **Computer Use** **Chrome** 插件修复与配置管理工具集。

## 🚀 快速开始

### 如果你是 Reasonix 用户

加载技能：
```
/install-skill https://github.com/ZYY374/codex-plugin-fix
```

然后遇到问题时：
```
/codex-plugin-fix
```

### 如果你不用 Reasonix

直接跑脚本：
```powershell
powershell -ExecutionPolicy Bypass -File fix-codex-plugins.ps1
```

## 📦 包含什么

```
codex-plugin-fix/
├── SKILL.md                         ← Reasonix 技能（Agent 直接读）
├── README.md                        ← 你在这里
├── scripts/
│   └── fix-codex-plugins.ps1        ← 独立 PowerShell 修复脚本
└── guides/
    ├── auto-update-fix.md           ← 自动更新后修复详解
    ├── config-management.md         ← 配置备份/恢复/迁移
    ├── chrome-plugin-deep-dive.md   ← Chrome 插件原理与排查
    └── api-provider-switch.md       ← 安全更换 API 供应商
```

## 🛠️ 能修什么

| 症状 | 工具 | 时间 |
|------|------|------|
| **Computer Use** 插件不可用 | SKILL.md 场景 A 或 .ps1 | 2 分钟 |
| 自动更新后插件报错 / 消失 | SKILL.md 场景 A 或 .ps1 | 2 分钟 |
| 换供应商后插件配置丢失 | SKILL.md 场景 B 或 guides/ | 1 分钟 |
| **Chrome** 插件安装失败 | SKILL.md 场景 C | 30 秒 |
| 想备份配置防止意外 | guides/config-management.md | 1 分钟 |

## 💡 为什么会有这些问题

Codex Desktop 通过 Microsoft Store 自动更新，但：
- 用户目录的插件文件**不会自动同步**
- 更换 API 供应商会**重置** config.toml
- Chrome 插件需要**系统级配置**（注册表）

本工具集自动化处理所有这些情况。

## 🔧 单独功能

### 只修 **Computer Use** 报错
→ 看 [guides/auto-update-fix.md](guides/auto-update-fix.md) 第 4 步

### 只备份配置
→ 跑 [guides/config-management.md](guides/config-management.md) 的备份脚本

### 只看 **Chrome** 怎么配
→ 看 [guides/chrome-plugin-deep-dive.md](guides/chrome-plugin-deep-dive.md)

### 只换 API 供应商
→ 看 [guides/api-provider-switch.md](guides/api-provider-switch.md)

## 📋 给 Agent 的说明

如果你的 Agent 可以加载 Reasonix skill，把 `SKILL.md` 作为技能导入即可。技能的 `description` 字段包含了触发条件，Agent 会自动判断何时使用。

如果你的 Agent 不能加载 skill，让它读 `guides/` 目录下的教程按步骤执行。
