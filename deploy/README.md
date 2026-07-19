# 匿名版本检查 · 服务端部署

Tidewatch 启动时/每天一次向自有域拉一个静态 `latest.json` 判断有无新版(见 `Sources/Tidewatch/Support/UpdateChecker.swift`)。**零后端**——服务端只需放一个静态 JSON 文件,「谁在用哪个版本」由 OpenResty 访问日志被动计数。

## 端点

```
https://zhimahang.com/tidewatch/latest.json
```

App 发起的请求形如 `GET /tidewatch/latest.json?v=0.1.0`,User-Agent = `Tidewatch/<版本> (version-check)`。

**隐私红线(代码已落实,勿改坏)**:请求只带当前版本号(query `v` + UA),不带账号/用量/邮箱/设备指纹;不收发 cookie;HTTPS。

## `latest.json` 字段

| 字段 | 必填 | 说明 |
|---|---|---|
| `latest` | 是 | 线上最新版本号,语义化 `x.y.z`。低于或等于用户本机版本则不提示 |
| `notes` | 否 | Release notes(中文),面板横幅二级文案 |
| `notes_en` | 否 | Release notes(英文),仅在中文 `notes` 缺失/为空时回退使用(当前 UI 恒中文) |
| `url` | 否 | 「下载」按钮打开的落地页(承接页 / GitHub Release) |

未知字段一律被忽略(可安全附加 `sha256`、`min_os` 等给别处用)。

## 部署(走 offical / 1Panel + OpenResty)

offical 站(`zhimahang.com`)已在 1Panel 网站列表里托管,**这里只是往已有站点的 web 根目录放一个静态文件,不需要新建站点、不写 vhost conf**(参见记忆 `onepanel-site-workflow` / `zmh-deploy-topology`)。

```sh
# 目标:offical 站 web 根下的 /tidewatch/latest.json
# 静态门户根:/opt/1panel/www/sites/zhimahang.com/index/
scp deploy/latest.json zmh:/opt/1panel/www/sites/zhimahang.com/index/tidewatch/latest.json
# 首次需先建目录:ssh zmh 'mkdir -p /opt/1panel/www/sites/zhimahang.com/index/tidewatch'
```

验证:`curl -sI https://zhimahang.com/tidewatch/latest.json` 应 `200`。

## 发新版时

1. 出好新 `.dmg`,传 GitHub Release(或承接页)。
2. 把 `deploy/latest.json` 的 `latest` 改成新版本号,写好 `notes`/`notes_en`,`url` 指向下载页。
3. scp 覆盖上去即可。旧版本用户下次检查(启动或次日)就会在面板顶部看到一条克制的「有新版」横幅。
4. **同步官网落地页的烘焙版本号**(offical 仓 `tidewatch/index.html`):页面版本文案会从
   `latest.json` 动态拉取(两处 `data-tw-version` span),但 **JSON-LD 的 `softwareVersion`
   与 span 内的兜底文案是写死的**——发版时顺手把这三处也改成新版本号再 scp,否则
   结构化数据会与实际版本漂移(2026-07-15 review 发现)。

> 度量:OpenResty 访问日志按 `?v=<版本>` 分段,即得「周活版本分布」+ 热修后重下载峰值(见发行手册 §8)。
