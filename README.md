<p align="center">
  <img src="assets/images/app_logo.webp" width="120" alt="青枢">
</p>

<h1 align="center">青枢</h1>

<p align="center">
  <strong>日轻小说与番剧，一个 App 里看完。</strong><br>
  轻小说 · 番剧 · 弹幕 · 追番
</p>

<p align="center">
  <a href="https://github.com/lzjloveyjx/qingshu-apk/releases/latest"><img src="https://img.shields.io/github/v/release/lzjloveyjx/qingshu-apk?label=Release&color=E89B35" alt="最新版本"></a>
  <img src="https://img.shields.io/badge/Android-7.0%2B-087E8B" alt="Android 7.0+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0-blue" alt="GPL-3.0"></a>
</p>

<p align="center">
  <a href="#主要功能">主要功能</a> ·
  <a href="#下载与安装">下载安装</a> ·
  <a href="#常见问题">常见问题</a> ·
  <a href="HANDOVER.md">交接 / 开发文档</a>
</p>

---

青枢是**自用的**日轻小说 + 番剧聚合客户端。小说来自文库站与本地导入，番剧来自 Bangumi 元数据加规则源解析，播放器和弹幕从 [Kazumi](https://github.com/Predidit/Kazumi) 接进来。

数据与播放全部在本地完成，不上传、不需要注册账号。

> **本项目不分发任何内容，也不绕过付费或访问权限。** 所有作品来自第三方站点，版权归各自权利人。仅供个人学习研究使用。

## 主要功能

### 📖 看轻小说

- **两个文库源**：轻之国度（lightnovel.fun）、wenku8，都是现成可用的。
- **规则源**：走 [Kazumi 规则仓库](https://github.com/Predidit/KazumiRules)，能自己装、能改、能排序。
- **导入自己的书**：TXT / EPUB，导入后和在线书同一套阅读器。
- 字体字号、翻页方式、深色 / 纯黑 / 墨水屏主题。
- 朗读（系统 TTS / 真人有声书），倍速、定时停止、后台播放。

### 🎬 看番

- **热门番组**：跟 Kazumi 同款数据源（Bangumi 热度流），支持 15 个题材筛选。
- **本季新番**：按星期分节的时间表。
- **搜索**：全库搜索 + 本地索引兜底（断网也能翻已同步过的）。
- **多源选番**：点一集先并发搜所有规则源，自己挑一条，不会硬塞给你第一个结果。
- **播放器**：倍速、画幅、跳过片头、定时关闭、锁屏、手势、画中画。
- **超分辨率**：Anime4K 着色器（效率档 / 质量档），开的时候自动切到 copy-back 硬解。
- **弹幕**：BiliBili 源，自动匹配整季合集，也能手动选。
- **追番**：未看集数角标、三档排序（最近活跃 / 未看集数 / 加入时间）。
- **离线**：下载分集，断网可播；播放进度自动记忆，下次接着看。

### 📚 书架与历史

- 小说和动漫分区显示，可加分组、可筛选。
- 观看历史按时间倒序，能直接续播。
- 备份与导入（含 WebDAV 同步）。

## 下载与安装

前往 [**下载最新版**](https://github.com/lzjloveyjx/qingshu-apk/releases/latest)。

| 平台 | 系统要求 | 说明 |
| --- | --- | --- |
| Android | 7.0 及以上，arm64 | 目前唯一正式支持的平台 |

- 安装包约 110 MB。体积大是因为打进了 **libmpv**（播放内核）、**Rust 后端核心**和 9 个 Anime4K 着色器。
- 国内直连 GitHub 下载可能中断，用 `https://gh-proxy.org/` 前缀走代理更稳。
- **暂未提供 Windows / Linux / iOS / macOS 安装包。** 源码里保留了这些平台的工程，但青枢只在 Android 上验证过。

### 开始使用

1. **看小说**：首页浏览，或在书架菜单里「导入图书」。
2. **看番**：底部第二个 tab 是「动漫」，点卡片进详情，点剧集选源播放。
3. **追番**：详情页点「加入书架」，之后在「我的 → 追番」看进度。
4. **换弹幕**：播放页的弹幕按钮里可以手动选番剧。

## 常见问题

<details>
<summary><b>番剧加载不出来 / 一直转圈？</b></summary>

先确认网络。番剧数据走镜像 `api.kazumi.fyi` 和 `bgmapi.anibt.net`，这两个有时会抽风。

如果日志里看到 `tcp: ffurl_read` 之类的报错，是**第三方视频源**那条线路挂了，换一个源即可 —— 源站单条线路失效是常态，不是 App 的问题。

</details>

<details>
<summary><b>超分辨率开了没效果？</b></summary>

去「我的 → 运行日志」找 `SuperResolution:` 开头的行：

- 写「生效」→ 已经挂上了
- 写「未生效 ... vo=null」→ GL 上下文还没就绪，这个版本应该已经修好，如果还出现请反馈
- 写「着色器目录为空」→ 安装包不完整，重装

另外两种渲染器组合本身就不支持：`mediacodec_embed` 没有 GL 管线，遇到会直接提示。

</details>

<details>
<summary><b>弹幕没有 / 对不上？</b></summary>

弹幕来自 BiliBili 公开接口，靠番剧中文名去搜。搜索「进击的巨人」第一条是 OST 试听，所以做了筛选（时长 ≥10 分钟 + 优先整季合集），但仍然可能匹配错。

在播放页的弹幕源面板里可以手动选具体哪个视频，选中后就是那个视频的弹幕。

</details>

<details>
<summary><b>进度没记住 / 换设备怎么搬？</b></summary>

进度存在设备本地的 Hive box 里，播放时每秒写一次。

搬设备用「我的 → 备份与导入」导出，新设备恢复。备份包含书架、收藏、阅读与播放进度；不包含本地电子书文件和下载的视频。

</details>

<details>
<summary><b>换了新版本装不上，提示签名不一致？</b></summary>

必须是同一个签名的 APK 才能覆盖安装。如果你之前装的是从别处来的包，先卸载再装（进度会丢，建议先备份）。

</details>

## 这个项目怎么来的

青枢是在 [**什锦铺 / novel-sound**](https://github.com/ch6vip/novel-sound) 的壳子上长出来的：

- **壳**：小说、短剧、漫剧、漫画、听书的框架和番茄风格 UI 来自什锦铺
- **番剧**：播放器、弹幕、超分、下载、历史整套来自 [Kazumi](https://github.com/Predidit/Kazumi)
- **青枢自己写的**：轻小说数据源、Bangumi 数据接入、动漫首页 / 详情 / 搜索 / 追番页、BiliBili 弹幕源、以及把两边粘起来的那层装配

因为是自用，很多地方只按「我这台机器能跑」的标准做的，没有做多机适配和兼容性兜底。

## 致谢与许可

| 项目 | 用途 | 协议 |
| --- | --- | --- |
| [什锦铺 / novel-sound](https://github.com/ch6vip/novel-sound) | 主壳框架 | GPL-3.0 |
| [Kazumi](https://github.com/Predidit/Kazumi) | 播放器 / 弹幕 / 番剧功能 | GPL-3.0 |
| [KazumiRules](https://github.com/Predidit/KazumiRules) | 视频源规则仓库 | — |
| [Bangumi](https://bgm.tv/) | 番剧元数据 | — |
| [Anime4K](https://github.com/bloc97/Anime4K) | 超分着色器 | MIT |
| [media_kit](https://github.com/media-kit/media-kit) | 播放内核封装 | MIT |

本项目采用 [GPL-3.0](LICENSE) 协议。

在线内容来自第三方，版权归各自权利人。**本项目与内容提供方无隶属关系，不托管任何作品，不绕过付费或访问权限。** 书架、进度和缓存都只保存在你自己的设备上。

---

## 给开发者

改代码、发版、排错请看 [**HANDOVER.md**](HANDOVER.md) —— 里面写了环境版本、构建步骤、发版清单，以及 9 个最容易重复踩的坑。

快速开始：

```bash
git clone https://gh-proxy.org/https://github.com/lzjloveyjx/qingshu-base.git
cd qingshu-base
flutter pub get
flutter run
```

调试版不需要任何密钥。
