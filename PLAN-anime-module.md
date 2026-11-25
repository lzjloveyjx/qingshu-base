# 动漫模块合并规划（Kazumi → 青枢）

> 状态：**已定稿，开始实施**（2026-11-25 决策完毕）
> 编写日期：2026-11-25
> 目标读者：本人（决策）+ 后续实现会话

## 决策记录（2026-11-25）

| 问题 | 决定 |
|---|---|
| 播放内核 | **装** `media_kit_libs_android_video`，**不用外挂播放器** |
| 实施节奏 | 按四期顺序推进，一期一验收 |
| 规则仓库 | 沿用 Kazumi 官方 `KazumiRules` |
| 源管理入口 | 「我的」里新增**播放源管理**，界面直接搬 Kazumi 的源管理页 |
| 底部导航 | 不拆「短剧/动漫」；**短剧页整体替换为 Kazumi 的动漫页**（本机无短剧源） |
| 书架 | 小说与动漫**分区**显示 |

---

## 一、结论先说

动漫这块**可以做，但不是「接个页面」那么简单**，有三道硬门槛要先过：

| 门槛 | 现状 | 影响 |
|---|---|---|
| APK 里没有 libmpv | 当前 APK 只有 7 个 .so，无 libmpv | 动漫无法播放，必须加 media_kit_libs_android_video（APK +约 11 MB） |
| 没有 WebView 内核 | 主工程未声明 flutter_inappwebview_android | Kazumi 的在线视频源靠 WebView 嗅探，缺它等于没源 |
| 两套 DI 不通用 | 主壳 Riverpod，Kazumi 用 flutter_modular + mobx | 直接搬页面会 No Element 白屏（轻小说那次已经踩过） |

**建议路线：不整体搬 Kazumi 壳，只搬「数据 + 播放器」，UI 用青枢自己的皮。**

理由：青枢现在的小说/书架/我的都是番茄皮，塞一个 Kazumi 原皮进去会变成两个 App 拼在一起。

---

## 二、Kazumi 有什么（调研结果）

packages/kazumi/lib 下 400 个 dart 文件，按功能分：

| 模块 | 目录 | 是否要搬 |
|---|---|---|
| 番剧数据（Bangumi API） | modules/bangumi/、request/apis/bangumi_api.dart | 要（片单/详情/评分/评论来源） |
| 番剧发现（排行/时间表/搜索） | pages/popular/、pages/timeline/、pages/search/ | 要（数据层） |
| 番剧详情 | pages/info/ | 要（数据层） |
| **视频源解析** | services/video_source/、plugins/ | **核心**，靠 WebView 嗅探 |
| 播放器 | pages/player/、pages/video/、services/player/ | 要（media_kit + 弹幕） |
| 弹幕 | canvas_danmaku + player_danmaku_controller | 二期 |
| 下载/收藏/历史 | pages/download/、collect/、history/ | 二期 |
| Kazumi 自己的「我的」/设置/主题 | pages/my/、settings/ | 不要（用青枢的） |
| onBoarding / about / logs | — | 不要 |

**关键发现**：kazumi_bootstrap.dart 现在只装配了轻小说用到的 4 个依赖，动漫要再加一批（BangumiApi 是静态类可直接用，但 VideoPageController 等是 modular 注入的）。

---

## 三、三道门槛的具体解法

### 门槛 1：播放内核（libmpv）

现状 pubspec.yaml 只声明了 Windows/Linux/iOS 的 media_kit libs，**故意没装 Android 版**（注释写着「APK 多出 ~11 MB」）。

动漫要播就必须加：

```yaml
media_kit_libs_android_video: 1.3.7   # 版本待与 media_kit 1.2.6 对齐验证
```

- 代价：APK 从 45 MB → 约 56 MB
- 风险：该包对 16 KB page size 有要求，需确认 CI 用的 AGP 能过
- 备选：如果只是想「点开能看」，可先走**系统播放器 Intent 外挂**（external_player.dart 已有），零体积代价，但没有内嵌进度/弹幕

### 门槛 2：WebView 嗅探视频源

Kazumi 的动漫源不存视频地址，而是**用 WebView 打开番剧页，拦截网络请求找 .m3u8/.mp4**。

主工程目前：
- third_party/webview_windows 是**桌面**用的，Android 用不上
- 没有 flutter_inappwebview_android

要加：

```yaml
flutter_inappwebview_android: ^1.1.3   # 与 kazumi 同版本，避免解析冲突
```

> 注意：CI 里已经有一步 sed 补丁处理这个包的 proguard，说明这条链路本身是通的，只是主工程没引。

### 门槛 3：DI 不通用

轻小说那次的做法是 KazumiBootstrap 用静态字段装配。动漫同理，但依赖更多：

```dart
// 需要补进 KazumiBootstrap 的
static BangumiApi? _bangumiApi;        // 番剧数据（其实就是静态类）
static PluginManager? _pluginManager;  // 视频源规则
```

**不引入 flutter_modular**：直接给页面传 controller（Kazumi 的 PopularPage 已经是 required this.controller 形态，可以手工 new 出来）。

---
## 四、推荐实施路线（分 4 期）

### 第 1 期：能看见（数据层打通）
**工作量：小 / 风险：低**

- 新增 lib/services/anime/anime_source.dart
  - browsePopular() → Bangumi 排行榜
  - browseCalendar() → 每日放送表
  - search(keyword) → Bangumi 搜索
  - fetchDetail(id) → 番剧详情（简介/评分/话数/标签）
- 把番剧数据接到首页网格（kind:'anime'）
- 顶部 tab 从「动漫」入口进入，先做**只有封面和标题的列表**

**验收**：点动漫 tab 能看到当季新番列表，点进去有详情页（还不能播）。

### 第 2 期：能播放（核心）
**工作量：大 / 风险：中高**

- 加 media_kit_libs_android_video + flutter_inappwebview_android
- 搬 services/video_source/（含 webview_video_source_service.dart）
- 搬 plugins/ 的动漫规则部分，规则仓库用 Kazumi 官方 KazumiRules
- 详情页加「选集 → 播放」，播放页用青枢样式包一层 media_kit

**验收**：随便点一集，能出画面、能拖进度。

### 第 3 期：像样（体验补齐）
**工作量：中 / 风险：低**

- 弹幕（canvas_danmaku）
- 倍速 / 清晰度
- 播放进度记忆（接青枢现有的 MediaHistoryStore）
- 「我的」里加「动漫规则仓库」入口（跟「书源」并列）

### 第 4 期：离线与追番
**工作量：中 / 风险：低**

- 下载（Kazumi 有 download_manager，但依赖 hive box，要接青枢存储）
- 追番列表（接青枢书架，kind:'anime'）

---

## 五、明确不做的事

| 不做 | 原因 |
|---|---|
| 搬 Kazumi 的「我的」/设置/主题 | 青枢已有，重复 |
| 搬 Kazumi 的 onboarding | 青枢没有引导流程 |
| 引入 flutter_modular 全局 | 只为几个页面引入一套 DI 不值得，改成手工注入 |
| 搬 Kazumi 的桌面窗口管理 | Android 用不上 |
| 整体替换底部导航 | 青枢的「动漫」位已经在，继续用它 |

---

## 六、风险清单

| 风险 | 等级 | 应对 |
|---|---|---|
| APK 体积 +11 MB | 中 | 如果介意，第 2 期可先做「外挂播放器」版 |
| WebView 嗅探在某些源失效 | 高 | Kazumi 本身也在跟源站改版；先接 2-3 个稳定源，不追求全量 |
| Bangumi API 限流 | 中 | Kazumi 已有 AsyncRateLimiter，照搬 |
| media_kit Android 首次集成编译失败 | 中 | CI 里已处理过 inappwebview 的 proguard；media_kit 需实测 |
| 版权 | — | 与轻小说同性质，第三方源，自用 |

---

## 七、本次要你先拍板的三件事

1. **播放内核要不要装**（+11 MB）？还是先做外挂播放器版？
2. **第 1 期先做「只能看不能播」**，确认列表和详情满意了再投入第 2 期？还是直接奔第 2 期？
3. **动漫规则仓库**用 Kazumi 官方那套（KazumiRules），还是你想换成别的源？

---

## 八、开放问题（已全部决断）

- ~~「动漫」底部 tab 现在挂短剧页，要不要拆~~ → **不拆，短剧页直接换成动漫页**
- ~~书架里小说和动漫要不要分区~~ → **分区**

---

## 九、实施期实测补充（2026-11-25）

### 9.1 Bangumi 官方 API 国内不可直连

实测 `api.bgm.tv` / `next.bgm.tv` / `bgm.tv` 全部 20 秒超时（DNS 解析正常但 TCP 不通）。

**必须走 Kazumi 官方镜像** `https://api.kazumi.fyi`，实测可用：

| 用途 | 镜像路径 | 实测 |
|---|---|---|
| 榜单 | `/kazumi/v1/popular/subjects?limit=&offset=` | 200 |
| 季度时间表 | `/kazumi/v1/calendar/season?start=&end=` | 200 |
| 番剧详情 | `/p1/subjects/{id}` | 200 |
| 每日放送 | `/p1/calendar` | 200 |

Kazumi 本身就有 `BangumiAcceleration`（direct / ech / mirror）三档，默认走 mirror。青枢也照此实现，且**默认 mirror**。

### 9.2 规则仓库可达

`KazumiRules` 的 `index.json` 实测可直连（2.9 KB，含 7sefun/aafun 等规则）。gh-proxy 也通，留作备用。

### 9.3 封面图床

封面域名 `lain.bgm.tv` / `api.bgm.tv` 的图片同样可能不通，需要走镜像或在设置里暴露图床代理开关。这一项要在第 1 期实测确认。

---

## 附：本次调研的证据

| 结论 | 证据 |
|---|---|
| APK 无 libmpv | 解包 v1.5.3：lib/ 下仅 7 个 .so（libapp/libflutter/libdartjni/libech_http/libshortplay_crypto/libshortplay_tempo/libdatastore_shared_counter） |
| 主工程无 Android 播放库 | pubspec.yaml 仅声明 media_kit_libs_windows_video / linux / ios |
| 主工程无 WebView | pubspec.yaml 无 flutter_inappwebview_android；只有 third_party/webview_windows（桌面） |
| Kazumi 有 WebView | kazumi/pubspec.yaml:104 flutter_inappwebview_android ^1.1.3 |
| Kazumi 用 modular+mobx | kazumi/pubspec.yaml: mobx ^2.6.0 / flutter_modular ^7.1.0 |
| 视频源靠 WebView | services/video_source/webview_video_source_service.dart 注释「使用 WebView 解析视频页面，提取视频源 URL」 |
| Bootstrap 只装了小说 4 件 | kazumi_bootstrap.dart 仅 PluginsController / NovelShelfRepository / NovelReaderPrefs / AudioController |
| 动漫 tab 现挂短剧 | main.dart:1003 if (DramaFeaturePreferences...enabled) const DramaPage() |
