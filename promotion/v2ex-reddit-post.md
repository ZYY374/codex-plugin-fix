# Codex Desktop 自动更新幸存指南

## 每次更新都是一场豪赌

如果你用 Codex Desktop（OpenAI 的 AI 编程桌面应用），你一定经历过：

> 早上打开 Codex，发现 Computer Use 插件灰了。
> Chrome 插件消失了。
> 插件市场一片空白。
> 报了一堆 `exports` 错误，完全看不懂。

原因很简单：Codex 通过 Microsoft Store 静默自动更新，但用户本地的插件文件、运行时路径、配置文件**不会自动同步**。每次版本号一跳，版本对不上，插件就炸。

我踩了三次坑之后，写了一套自动化修复工具。

## 一键修复

```powershell
powershell -ExecutionPolicy Bypass -File fix-codex-plugins.ps1
```

或者如果你是 Reasonix 用户：

```
/install-skill https://github.com/ZYY374/codex-plugin-fix
/codex-plugin-fix
```

## 它做了什么

1. 从新版 MSIX 安装包提取最新的插件市场文件
2. 修复 `@oai/sky` 的 Node.js exports 缺失问题
3. 更新 `config.toml` 中 4 处过时的运行时路径
4. 补回被 Codex 重置的 marketplace 和插件配置
5. Chrome 插件专属：创建注册表 + Native Messaging manifest
6. 清理过时缓存

全程 PowerShell 脚本，透明可审计，不联网，不动你的 API key。

## 适用的场景

- Codex 自动更新后 Computer Use / Chrome / Browser 插件报错或消失
- 更换 API 供应商后配置被重置
- Chrome 插件安装失败
- 想做配置备份防止意外

## 技术原理（感兴趣的话）

几个不太容易发现的关键点：

1. **MSIX 路径变了**：26.608+ 版本 marketplace 从 `resources\app\extensions\` 搬到了 `app\resources\plugins\`
2. **`\\?\` 路径前缀**会让 Codex 无法解析 marketplace 中的相对路径
3. **隐藏目录**（`.tmp\`）会导致 Codex 扫不到市场文件
4. **EFS 加密**：`.codex` 目录被 Codex 用 EFS + 严格 ACL 锁死，只有 `[System.IO.File]::WriteAllBytes` 能写入
5. **`@oai/sky` 的 package.json** 的 `exports` 字段是个白名单，缺少一个内部子路径导致 Node.js 拒绝 import

## 仓库地址

https://github.com/ZYY374/codex-plugin-fix

欢迎 Star ⭐，提 Issue 补充更多场景。
