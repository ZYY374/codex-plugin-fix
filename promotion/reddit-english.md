# Codex Desktop Auto-Update Survival Toolkit

**Every Codex Desktop update is a gamble.**

One morning you open Codex and:
- Computer Use plugin is greyed out
- Chrome plugin vanished
- Marketplace shows nothing
- Cryptic `exports` errors everywhere

Why? Codex auto-updates via Microsoft Store, but your local plugin files, runtime paths, and config.toml **don't sync automatically**. Version mismatch = broken plugins.

After fixing this 3 times, I built an automated toolkit.

## One-liner fix

```powershell
powershell -ExecutionPolicy Bypass -File fix-codex-plugins.ps1
```

Or as a Reasonix skill:
```
/install-skill https://github.com/ZYY374/codex-plugin-fix
```

## What it fixes

- Post-update plugin breakage (Computer Use, Chrome, Browser)
- Plugin marketplace showing empty
- Chrome plugin installation failures
- Config reset after changing API provider

## Technical deep-dive

Some non-obvious findings:

1. **MSIX structure changed** in 26.608+ — marketplace moved from `resources\app\extensions\` to `app\resources\plugins\`
2. **`\\?\` path prefix** breaks Codex's relative path resolution for marketplace
3. **Hidden directories** (`.tmp\`) are invisible to Codex marketplace scanner
4. **EFS encryption** on `.codex` directory — only `[System.IO.File]::WriteAllBytes` bypasses it
5. **Node.js exports field** in `@oai/sky/package.json` is an allowlist — missing one internal subpath causes import failure

Fully open-source, no telemetry, doesn't touch your API keys.

## Repo

https://github.com/ZYY374/codex-plugin-fix

Stars ⭐ and contributions welcome!
