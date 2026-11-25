# 动漫模块合并规划（Kazumi → 青枢）

> 状态：**第 3 期已交付**（v1.9.0）；细节打磨进行中（源管理/选源/播放功能已改，见第十节）
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

> **状态：已完成**（v1.6.0，commit `921f1f6`）。
> 实际落地：`anime_source.dart` / `anime_page.dart` / `anime_detail_page.dart`；
> 镜像 `api.kazumi.fyi`；封面 wsrv.nl 代理；底栏第 2 项固定「动漫」。

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

**第 1 期结论**：已按 Kazumi 的做法套 `wsrv.nl` 图片代理（`anime_source.dart` 的 `_cover()`），实测返回真实图片。设备上若仍不显示，退路是在设置里加图床代理开关。

### 9.4 第 1 期实现补充

- 榜单接口 `/kazumi/v1/popular/subjects` 每行是**直接一个 subject**（不是 `{subject: {...}}` 包一层，season 接口才是包一层），代码里两种都认。
- 中文名字段是 `nameCN`（大写 CN），不是 `nameCn`；`/p1/subjects/{id}` 与榜单同形。
- `HomeMediaCard` **没有** `cacheWidth` 参数（只有 `StoryCover` 有），传了会编译失败。
- 底栏「动漫」不再跟 `DramaFeaturePreferences` 联动：关掉短剧后动画入口仍然在。

### 9.5 已知遗留

- 动漫详情页**还没有剧集列表**，这是第 2 期的事（要装播放内核）。
- `HomeKindIcon` / `homeKindLabel` 已加 `anime`，但书架分区（小说 / 动漫）还没做。
- 「我的」里的播放源管理入口还没加。

---

## 十、第 2 期交接（2026-11-25 17:00 下班挂起）

### 已经做完并推送

| 内容 | 位置 | commit |
|---|---|---|
| 播放源管理页 | `lib/pages/play_source_page.dart`，入口在「我的」桌面框架 + 手机列表 | `66704fd` |
| libmpv 依赖 | `pubspec.yaml` 的 `media_kit_libs_android_video: 1.3.8` | `66704fd` |
| 剧集表 | `anime_source.dart` 的 `AnimeEpisode` + `fetchEpisodes()`；详情页方格 | `bbc9b4d` |

### 两个修正原计划的实测结论

1. **「没有 WebView 内核」这道门槛不存在。** kazumi 包把 `flutter_inappwebview_android`
   作为传递依赖带进来了，APK 的 `classes.dex` 里 320 处 `com/pichillilorenzo`。
2. **镜像直接代理 v0 路径。** `api.kazumi.fyi/v0/episodes?subject_id=…` 返回 200，
   `total` 与字段和官方一致，不需要 Kazumi 的 `BangumiAcceleration` 三层加速。

### 2026-11-25 17:55 更新：v1.7.0 已发布

- 构建 `989a195`：run `45585739782` → **success**。
- APK 已发布：https://github.com/lzjloveyjx/qingshu-apk/releases/tag/v1.7.0
- 文件 `qingshu-merge-v1.7.0.apk`，99,915,160 字节，
  sha256 `d939b4052099180fa024eaeb7b7cd0c1299b3e500e7458d9743d4b427e504c76`。
- 解包验证：arm64 `libmpv.so` 12,369,680 字节，确实进包了。
- 下载链接 gh-proxy 返回 200，首字节 `504b0304`。

 downloads 的坑：GitHub artifact 的 blob 直连（productionresultssa16）只有 ~20KB/s，
 走 `https://gh-proxy.org/<blob-url>` 能到 ~322KB/s，50MB 约 2.5 分钟。
 artifact zip 是压缩的（50MB），解出来的 APK 是 99.9MB —— 两个数字别搞混。

 编译错误复盘（三次）：
 1. `LucideIcons.trash_2` 不存在 → 改 `trash`。
 2. `Future.wait<Object>` 装不下 `Future<AnimeDetail?>` → 改 `Future.wait<Object?>`。
 3. 注意：concurrency 会把旧 run 取消，文档提交也会触发（build-apk 的 paths 不含 docs，
    但 push 事件本身仍触发 workflow，只是新 run 顶掉旧的）。
### 2026-11-25 19:05 更新：第 2 期完成，v1.8.0 已发布

- 构建 `058c484`：run `45594970369` → **success**。
- APK：https://github.com/lzjloveyjx/qingshu-apk/releases/tag/v1.8.0
- 文件 `qingshu-merge-v1.8.0.apk`，100,636,060 字节，
  sha256 `1742e5e407e102633f11c91bd335550cfff6941eae7024efecf4289c6bbf7809`。
- 下载 gh-proxy 返回 200，首字节 `504b0304`；解包确认 arm64 `libmpv.so` 12.4MB。

第 2 期最终交付：
1. **播放源管理页**（`pages/play_source_page.dart`）：装/更新/删规则、改仓库地址。
   经典主题入口在 `widgets/mine/classic_mine_entries.dart`（书源旁，showTools 之外）。
2. **精简播放页**（`pages/anime_player_page.dart`）：自己写的，没搬 Kazumi 581 行原皮。
   链路 = 规则搜索 → queryChapterRoads → WebView 解析真实地址 → media_kit 播放；
   带选集、换源、解析状态与错误重试。点详情页剧集方块进入。
3. **Android MediaKit 初始化**（main.dart）：装了 libmpv 后必须补。

编译踩坑（这几轮逐个修的，别再犯）：
- `LucideIcons.trash_2` 不存在 → 用 `trash`，别拿自己刚写的文件当图标白名单。
- `Future.wait<Object>` 装不下 `Future<AnimeDetail?>` → 用 `Future.wait<Object?>`。
- setState 块里赋值用逗号结尾 → 必须分号（我犯过）。
- `int.clamp` 静态返回 `num` → 赋给 int 前要 `.toInt()`。
- `VideoController` 没有 `dispose()` → 只 dispose Player。
- main.dart 里 `media_kit` 直接 import 会带进同名 `NativePlayer` 与本地冲突 → `as mediakit`。
- main.dart 的 `foundation.dart` 只 show 了 LicenseRegistry → 用 `dart:io` 的 `Platform.isAndroid`。
- 播放页漏 import `models/media_item.dart`（anime_source 的 import 不传递）。

下载坑：artifact 的 blob 直连（productionresultssa16）只有 ~20KB/s，
走 `https://gh-proxy.org/<blob-url>` ~322KB/s。artifact zip 50MB，解出的 APK 100MB，别搞混。

下一步（第 3 期）：书架小说/动漫分区。播放体验可再补弹幕/进度记忆（迁移自 Kazumi）。
### 2026-11-25 19:45 更新：第 3 期完成，v1.9.0 已发布

- 构建 `2529291`：run `45603187721` → **success**（build 花 ~18 分钟，比平时久）。
- APK：https://github.com/lzjloveyjx/qingshu-apk/releases/tag/v1.9.0
- 文件 `qingshu-merge-v1.9.0.apk`，100,636,054 字节，
  sha256 `bc5e86a08ea8c487d4121432b07bee001d81a01f8e72e214efec85cc50454d86`。
- 下载 gh-proxy 返回 200，首字节 `504b0304`；解包确认 4 个 libmpv.so 都在。

第 3 期交付（书架小说/动漫分区）：
1. `ShelfIdentity.kinds` 加 `anime`，记录能被书架解析。
2. anime_source 的 MediaItem 设 `seriesId=纯数字 subject id`：
   id（`anime:数字`）带冒号不满足 contentIdPattern，内容键用 seriesId ?? id。
3. 动漫详情页 AppBar 加「加入书架/移出书架」按钮。
4. 书架媒介筛选行加「动漫」（_ShelfKindFilter，archive 与 classic 共用），
   两种主题都能按动漫分区。

### 收尾待调整的细节（用户说最后统一调）

- 书架重开动漫时**评分丢失**：ShelfStore._recordOf 没存 score，_itemFrom 也不读。
  次要问题，不影响分区；要修就在这两个函数加 score 的存取。
- 播放体验：弹幕、播放进度记忆还没接（Kazumi 里有实现，可迁）。
- 用户实测 v1.8.0「大体没问题，细节需要处理」——具体细节等用户逐条提。
### 2026-11-26 05:40 更新：细节打磨第一轮（源管理 / 选源 / 播放功能）

用户实测 v1.9.0 后提了三条，都要「学 Kazumi 原版的界面/节奏」：

**① 源管理界面换成 Kazumi 原版**（commit `3056562`）
  关键发现：Kazumi 那 6 个源管理界面文件（plugin_view_page / plugin_shop_page /
  plugin_catalog_view / rule_card / rule_management_widgets / plugin_editor_page）
  **与原始库 Predidit/Kazumi 逐字节一致**，早就在 packages/kazumi 里了。
  之前是我们自己写的简易一页式 UI（play_source_page）把它挡住了。
  - PlaySourcePage 改成委托 PluginViewPage（已安装规则：搜索/筛选/批量删/拖拽排序/三点菜单/单条更新）
  - Kazumi 里 7 处 flutter_modular 的 context.pushNamed 改为 Navigator.push
    （主壳是 Riverpod，没有 ModularApp，原跳转全失效）；plugin_editor_page 的
    context.pop() 同样改成 Navigator.of(context).pop()
  - controller 用 KazumiBootstrap.plugins 传下去，inject 点需改 0 个

**② 选源流程学 Kazumi**（commit `bbba2f2`）
  - 新增 pages/source_picker_sheet.dart：点剧集先弹面板，并发搜全部规则，
    按源分组展示，五态（pending/success/noResult/error/captcha），用户选一条。
  - 只复用底层 plugin.queryBangumi / queryChapterRoads，不碰 SourceSheet/InfoController
  - 播放页入参改为 PickedSource，删掉「自动搜所有源 + 自动选第一个」
    （这正是用户说的节奏不对的根源）

**③ 播放页功能补齐**（commit `bbba2f2`）
  按成本排序，本轮做了 6 项零依赖的：倍速 / 画幅 / 跳过片头(+90s) / 定时关闭 /
  锁屏 / 播放信息 HUD（时长+分辨率+倍速，分辨率走 player.stream.width/height）。

### 编译踩的坑（都修在 fd8390b / cdf65d8）

- source_picker_sheet.dart 用了 MediaItem 却没 import models/media_item.dart
  （anime_source 的 import 不传递）
- Icons.skip_forward 不存在 -> Icons.fast_forward
- ActionChip.color 参数类型是 WidgetStateProperty -> 去掉该参数
- context.pop() 是 flutter_modular 扩展，删 import 后失效 -> Navigator.of(context).pop()
- int.clamp(0, -1) 在分集为空时抛 ArgumentError（cdf65d8 修）

### 还没做（用户后续要逐条提）

- **弹幕**：Kazumi 用 canvas_danmaku + DanDanPlay API（api.dandanplay.net）。
  实测直连 403（Kazumi 的 DanmakuClient 有专门鉴权），需先解决接口鉴权。
  canvas_danmaku 只在 kazumi 子包声明，主工程要加依赖。
- 超分辨率 / 同步播放 / PiP / 截图 / 亮度音量竖滑手势：
  这些要搬 Kazumi 的 PlayerController 整套（mobx + modular），成本高，暂缓。
- 播放进度记忆（Kazumi 的 playResume / historyOffset）

### 调研材料位置

原始 Kazumi 关键源码已下载到 D:/小肥鱼工作区/07-影音App/qingshu-apk/upstream-kazumi/
（文件名把 / 换成 __，如 lib__pages__plugin_editor__plugin_view_page.dart），
共 15 个文件，是 Predidit/Kazumi main 分支快照，可随时对照。
### 2026-11-26 06:40 v2.1.0：修「规则仓库空白 / 整页灰块」

用户实测 v2.0.0 反馈：进「规则管理」看到一大块灰色，规则仓库全空。

**三个根因（都已在 80d8651 修复）**：

1. `GeneralEmptyState` / `GeneralErrorWidget` 内部套了 `SingleChildScrollView`，
   被放进 sliver（无界高度）时抛「Vertical viewport was given unbounded height」，
   **release 构建把出错子树渲染成没有文字的灰块** —— 就是截图里那块。
   空态/错误态不需要滚动，去掉滚动层即可。
2. `SysAppBar` 返回按钮用 `context.maybePop()`（flutter_modular 扩展），
   主壳是 Riverpod 没有 ModularApp，一渲染就抛异常（同样变灰块）。
   改 `Navigator.maybePop(context)`，删 modular import。
3. `RulesRepoClient` 原来只试一个镜像，该镜像在用户网络下挂掉就整页空白。
   改成按「当前设置 -> 其余镜像」依次回退，任一成功即返回。

**教训**：release 模式下的「无文字灰块」几乎都是构建异常被 ErrorWidget 吞掉。
以后开新页面先检查：sliver 里的子项不能有无界高度的滚动容器；
不能调用 flutter_modular 的 context 扩展（pushNamed / pop / maybePop）。

另：这次 push 后的构建因 Gradle 下载 Maven 依赖断网失败（基础设施，不是代码），
用 workflow_dispatch 重跑即通过。
### 重新开工第一件事

看 `bbc9b4d` 的 Build APK 结果（workflow `build-apk.yml`）。
晚上关机前那次构建是 16:49 起的，正常 13–15 分钟出包。
成功 → 下载 artifacts、发 release v1.7.0；失败 → 拉日志看 `build/10_Build APK.txt`。

### 第 2 期剩下的活（播放页）

链路已经摸清，但有个取舍没定：

- `VideoPage` 需要 `PlayerController` + `VideoPageController` + `HistoryController` + `DownloadController`
- `PlayerController(shaderAssetService, downloadController, audioController)`
- `VideoPageController(historyController, downloadRepository, downloadManager)`
- 播放地址解析走 `WebViewVideoSourceService`（可用），依赖 `Plugin.queryBangumi` → `queryChapterRoads` 找源

**取舍**：`video_page.dart` 是 581 行的 Kazumi 原皮页面，直接塞进青枢会变成两个 App 拼在一起。
两条路：① 搬过来包一层青枢样式的壳；② 自己写一个精简播放页（只做播放/进度/选集）。

### 踩过的坑（别再踩）

- `LucideIcons.trash_2` **不存在**，用 `trash`。核对图标名时不要拿自己刚写的文件当白名单。
- `HomeMediaCard` **没有** `cacheWidth` 参数（`StoryCover` 才有）。
- `pubspec.yaml` 是**混用 CRLF/LF**，`edit_file` 匹配 `\n` 会失败，要用 `\r\n`。

## 十一、灰块真根因（2026-11-26，v2.1.0 实测复现后重查）

**上一轮的结论是错的**：把灰块归因到空态里的 `SingleChildScrollView` 和
`SysAppBar` 的 `context.maybePop()`。两处都确实该修（前者在 sliver 里必崩，
后者是 modular 扩展），但修完 v2.1.0 用户实测**仍是整页灰块**。

### 真根因：两套 Material 实现混用

| | 用的什么 | 数量 |
|---|---|---|
| 主壳 `lib/` | `package:material_ui/material_ui.dart` | 295 个文件 |
| `packages/kazumi` | `package:flutter/material.dart` | **172 个文件** |

Flutter 3.47 起，`package:flutter/material.dart` 被拆成独立包 `material_ui`
（SDK 里那份已标 `@Deprecated`，见 `flutter/lib/material.dart:17-21`）。
两者**各有一份 `Theme` / `MaterialLocalizations` / `DefaultMaterialLocalizations`**，
InheritedWidget 类型不同，互相认不出来。

后果（与用户截图逐点吻合）：

1. `Theme.of(context)` 找不到主壳的 `Theme` → 回退 Flutter 默认紫。
   截图里「我的规则」卡片正是 `#EADDFF / #6750A4` —— 这就是默认 Material 紫，
   而不是青枢品牌色 `#EF5038`。
2. `MaterialLocalizations.of(context)` 找不到 → `TextField` 在 build 里抛
   `No MaterialLocalizations found`（`text_field.dart:1531` 的
   `debugCheckHasMaterialLocalizations`）。
3. release 构建的 `ErrorWidget` 把出错的子树画成纯灰块（`RenderErrorBox`，
   背景 `Color(0xF0C0C0C0)`），正好盖住整页列表区 —— 就是截图里那块灰。

### 复现与验证（本机）

本机装了 Flutter 3.50.1（`D:/flt-sdk/flutter`，注意 APPDATA/TEMP 要重定向，
否则 flutter 工具写 `%APPDATA%\.flutter_tool_state` 被拒；SDK 路径不能含中文，
否则 impellerc 编 shader 会因路径乱码失败）。

| 实验 | 结果 |
|---|---|
| probe5：material_ui 的 MaterialApp 里放 flutter/material 的 TextField | **复现** `No MaterialLocalizations found` |
| probe5 + 补 `flutter/material` 的 `DefaultMaterialLocalizations.delegate` | 异常消失（证明就是类型不匹配） |
| probe6：probe5 换成 `GlobalMaterialLocalizations.delegates`（主壳真实配置） | 同样通过 |
| 172 个文件 sed 到 material_ui 后 `flutter analyze packages/kazumi/lib` | **0 error** |
| 同上，`flutter analyze lib` | **0 error** |

### 改法

1. `packages/kazumi` 172 处 `package:flutter/material.dart` → `package:material_ui/material_ui.dart`；
   `package:flutter/cupertino.dart` → `package:cupertino_ui/cupertino_ui.dart`（1 处）。
2. `packages/kazumi/pubspec.yaml` 补 `material_ui: ^1.11.0` / `cupertino_ui: ^1.1.6`。
3. 回归测试 `test/widget/plugin_view_page_test.dart` 必须用 **material_ui + 中文
   delegates** 的真实壳配置建 `MaterialApp`。用 `package:flutter/material` 自建
   会把 bug 藏起来（第一版就是因此误判「测试通过」）。
4. `.github/workflows/widget-test.yml` 在每次 push 跑这个测试。

### 教训（给以后的我）

- **release 下的灰块 = 有异常被 ErrorWidget 吞了**，但错误原文只有 debug 才看得到。
  先搭一个能跑的 widget test 把异常原文打出来，比在 release 里猜快得多。
- 判断「两个东西是不是同一套」时，看 **import 路径的包名**，不是看类名。
  `Theme`、`MaterialLocalizations` 两边同名同签名，编译器不会报错，
  但运行时是两个类型。
- 主工程和子包**混用两套 UI 库**是这类「界面莫名灰色/主题不对」的高发原因。

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