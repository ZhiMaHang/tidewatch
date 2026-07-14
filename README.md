# QuotaBar

macOS 菜单栏应用:同时查看多个 **Claude**(Pro/Max)和 **Codex**(ChatGPT Plus/Pro)账号的订阅额度。

## 功能

- 菜单栏常驻,汇总显示两家最高用量(`C 42% X 11%`),异常时带 ⚠︎
- 每个账号展示所有额度窗口:5 小时窗口、周额度、Opus/Sonnet 周额度、Codex 附加模型额度、Credits
- 每个窗口显示已用百分比、进度条(绿/橙/红)与重置倒计时
- 定时自动刷新(3/5/15/30 分钟可选,Claude 端点安全轮询下限约 180s)+ 手动刷新
- token 过期自动刷新;同一凭据存储的刷新严格串行(refresh token 单次有效),刷新后写回原存储,不会搞坏 CLI 登录;写回失败时新 token 会暂存到 QuotaBar 的钥匙串 `rescue-*` 条目

## 多账号

| 提供方 | 添加方式 |
|---|---|
| Claude | ① 应用内 OAuth 登录(浏览器授权 → 粘贴授权码),每个账号独立 token,互不干扰;② 导入本机 Claude Code CLI 凭据(钥匙串) |
| Codex | ① 导入任意 `auth.json`(多账号可用多个 `CODEX_HOME` 目录,如 `~/.codex-work/auth.json`);② 应用内 OAuth 登录(浏览器授权 → localhost 回调) |

凭据存储:应用内登录的 token 存在你自己的钥匙串条目(service `com.quotabar.credentials`)里;导入类账号则实时读取 CLI 的存储(文件或钥匙串),刷新后写回保持同步。

## 构建与安装

```bash
./scripts/build-app.sh          # 生成 dist/QuotaBar.app
cp -R dist/QuotaBar.app /Applications/
open /Applications/QuotaBar.app
```

要求 macOS 14+。首次读取 Claude Code / Codex 的钥匙串条目时,系统会弹授权框,选"始终允许"即可。

## 无头自检

```bash
.build/debug/QuotaBar --check              # 拉取所有已添加账号的额度并打印
.build/debug/QuotaBar --check-codex-cli    # 顺带探测本机 ~/.codex/auth.json
```

## 接口说明(非官方,可能变动)

- Claude:`GET https://api.anthropic.com/api/oauth/usage`(OAuth Bearer + `anthropic-beta: oauth-2025-04-20`);token 刷新走 `console.anthropic.com/v1/oauth/token`
- Codex:`GET https://chatgpt.com/backend-api/wham/usage`(OAuth Bearer + `chatgpt-account-id`);token 刷新走 `auth.openai.com/oauth/token`(刷新 token 单次有效会轮转,应用会写回原存储)

两者都是各家 CLI 自用的私有接口,仅用于读取你自己账号的用量。

## License

MIT © 2026 智码航,详见 [LICENSE](LICENSE)。
