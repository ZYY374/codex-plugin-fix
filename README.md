# Codex Plugin Fix

一键修复 Codex Desktop 自动更新后 Computer Use、Chrome、Browser 等插件的报错/消失/安装失败问题。

## 适用场景

- Codex Desktop 自动更新后，Computer Use 插件报 `exports` 错误
- 插件市场中找不到 Chrome / Computer Use / Browser 插件
- 插件能看到但安装失败
- 更换 API 供应商后插件配置丢失

## 快速使用

将 `SKILL.md` 作为 Reasonix 技能加载，然后执行：

```
/codex-plugin-fix
```

或直接在 PowerShell（管理员）中按 `SKILL.md` 的步骤逐步执行。

## 修复流程

```
检查版本 → 同步 marketplace → 补 @oai/sky → 修 exports → 改 config.toml → Chrome 注册表 → 清缓存 → 重启
```

## 原理

Codex Desktop 通过 Microsoft Store 自动更新时：

1. **MSIX 内部路径变更** — marketplace 从 `resources\app\extensions\marketplace` 移到 `app\resources\plugins\openai-bundled`
2. **运行时 hash 变更** — `C:\Users\<user>\AppData\Local\OpenAI\Codex\runtimes\cua_node\<new_hash>\`
3. **插件版本升级** — 旧 marketplace 文件版本不匹配，Codex 不认
4. **config.toml 被重置** — 更换供应商等操作会清空 marketplace/插件配置
5. **`@oai/sky` exports 不完整** — Node.js 拒绝导入未声明的子路径
6. **Chrome 需要额外系统级配置** — 注册表 + Native Messaging manifest

本技能自动化处理以上所有问题。

## 文件

- `SKILL.md` — Reasonix 技能定义（含完整 PowerShell 脚本）
- `README.md` — 本文件
