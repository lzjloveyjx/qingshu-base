# 青枢 · 交接文档

> 面向「换一台电脑继续干活」的场景。目标读者是拿到这台机器的人（或下一个会话的 AI）。
> 最后更新：2026-11-28 · 当前版本 **v2.6.0**（versionCode 260）

---

## 一、五分钟上手

```bash
# 1. 克隆（走 gh-proxy，国内直连 GitHub 合成大包容易断）
git clone https://gh-proxy.org/https://github.com/lzjloveyjx/qingshu-base.git
cd qingshu-base

# 2. 装依赖
flutter pub get

# 3. 跑起来（Android 真机/模拟器）
flutter run
```

**不需要配置任何密钥就能跑 debug 版。** 只有打 release 包才需要签名材料（见第五节）。

### 环境要求

| 项 | 版本 | 说明 |
|---|---|---|
| Flutter | **3.50.1** | 与 CI 一致。别的版本可能编不过（Material 拆包问题） |
| Java | 17 | |
| Android NDK | **28.2.13676358** | 编译 Rust 后端要用，版本必须完全一致 |
| Rust | stable | 带 `aarch64-linux-android` / `armv7-linux-androideabi` target |

---

## 二、两个仓库

| 仓库 | 用途 |
|---|---|
| `lzjloveyjx/qingshu-base` | **源码**（就是本仓库）。public |
| `lzjloveyjx/qingshu-apk` | **只放 APK 的 Release**。用户从那里下载 |

发版流程是：源码改完 → 打 tag → CI 出包 → 下载 APK → 传到 apk 仓库的 Release。

> 注意：根目录 `README.md` 还是上游 **什锦铺 / novel-sound** 的原文
> （含爱发电、QQ 群、上游徽章），自 base 合并后没改过。
> App 本身叫**青枢**（`android/app/build.gradle.kts` 的 `appLabel`）。
> 如果这份仓库要给外人看，README 需要重写。

---

## 三、项目结构

```
lib/                        主壳（青枢自己的皮，Riverpod）
  pages/anime_page.dart         动漫首页（热门番组 + 本季新番 + 题材筛选）
  pages/anime_detail_page.dart  番剧详情 / 选集 / 加入书架
  pages/anime_search_page.dart  搜索（全库 + 本地索引兜底）
  pages/anime_follow_page.dart  追番（未看角标 + 排序）
  pages/anime_player_page.dart  精简播放页（早期版本，现已改用 Kazumi VideoPage）
  services/anime/
    anime_source.dart            Bangumi 数据源（镜像、榜单、季度表、搜索）
    anime_loaders.dart           首页 loader 注入
    anime_index.dart             本地全库索引（Hive box: anime_index）
    qingshu_playback.dart        播放装配层（把选源结果接进 Kazumi 播放页）
  widgets/mine/classic_mine_entries.dart  「我的」入口（追番/下载/历史都在这里）

packages/kazumi/            Kazumi 子包（已迁到 material_ui）
  lib/pages/player/              播放器
  lib/services/danmaku/bili_danmaku_source.dart   BiliBili 弹幕源（青枢自建）
  lib/pages/download/            下载管理
  lib/pages/history/             观看历史

android/                    Android 壳
  app/src/main/kotlin/com/fqapp/fqapp/   自定义插件（音量键、系统栏、TTS…）
  build.gradle.kts            签名配置在这里
rust/                        Rust 后端核心（libfqapi_core.so）
third_party/media_kit_video/ media_kit 的本地 fork（见第六节）
assets/shaders/              Anime4K 着色器（9 个 .glsl）
```

---

## 四、构建

### Debug

```bash
flutter run
```

### Release APK（本地）

需要两个东西：

1. **Rust 后端**（`libfqapi_core.so`）—— 缺了 App 启动后后端全挂
2. **签名文件**

```bash
# 1. 编 Rust（需要 ANDROID_NDK_HOME 指到 28.2.13676358）
export ANDROID_NDK_HOME=/path/to/ndk/28.2.13676358
bash scripts/build_rust_backend.sh --skip-codegen

# 2. 准备签名：在 android/keystore.properties 写四行（git-ignored）
#    storeFile=app/qingshu-release.keystore
#    storePassword=***
#    keyAlias=***
#    keyPassword=***

# 3. 打包
flutter build apk --release --target-platform android-arm64
```

产物在 `build/app/outputs/flutter-apk/app-release.apk`。

> CI 只出 **arm64**（`--target-platform android-arm64`），但 `libfqapi_core.so`
> 两个 ABI 都会编进去（`build_rust_backend.sh` 固定编 arm64-v8a + armeabi-v7a）。
> 本地想给 32 位机器也出包，去掉 `--target-platform` 参数即可。

### CI 出包（推荐）

打 tag 就会自动构建并发到 `qingshu-base` 的 Release：

```bash
# 先把 pubspec.yaml 的 version 改好，再打同版本 tag（不一致会直接失败）
git tag v2.6.1
git push origin master v2.6.1
```

Workflow：`.github/workflows/build-apk.yml`（**这是实际在用的那个**）

- 跑在 `ubuntu-24.04`
- 大约 15–20 分钟
- 会顺带跑 Rust 交叉编译（CI 里 NDK 是现装的）

> 仓库里还有 `android-apk.yml` / `windows.yml` / `linux.yml` / `format.yml` 等，
> 那些**历史上一直在失败**，是上游带来的，不用管。

---

## 五、签名

| 项 | 位置 |
|---|---|
| keystore 文件 | `android/app/qingshu-release.keystore`（**git-ignored，不在仓库里**） |
| 凭证 | `android/keystore.properties`（git-ignored） |
| CI 用的四个 Secrets | `RELEASE_KEYSTORE_BASE64` / `RELEASE_STORE_PASSWORD` / `RELEASE_KEY_ALIAS` / `RELEASE_KEY_PASSWORD` |

**证书 SHA-256**：`b26172679cb111316376be7555f9e5c80ae7497396969d19abddd20de5554731`

> ⚠️ 这个指纹目前只钉在 `android-apk.yml` 里（`RELEASE_SIGNER_SHA256`），
> 而**那个 workflow 历史上一直是失败的**，实际出包用的是 `build-apk.yml`，
> 后者**不校验指纹**，只靠 Gradle「缺签名材料就失败」这条兜底。
>
> 也就是说：**签名材料用错了不会被 CI 拦住**，只会打出一个签名不同、装不上的包。
> 换机器 / 重签时要人工核对这个指纹。

> ⚠️ 这个 keystore 目前只在本机 `D:/小肥鱼工作区/06-系统/密钥/qingshu-signing/` 有备份。
> **在新机器上如果没有 keystore，就打不出能覆盖安装的包**（签名不同，Android 会拒绝升级）。
> 要么把那两个文件拷过去，要么继续用 CI 出包。

---

## 六、几个必须知道的坑

这一节是这两年踩过的坑里最容易重复踩的，按重要性排。

### 6.1 media_kit 必须是本地 fork

pub.dev 的 `media_kit_video 2.0.1` **只有 SurfaceProducer 一条 Android 渲染路径**，
那条路在不少机型上渲染不出画面（mpv 打开了 URL、时长 00:00、日志无报错）。

仓库里的 `third_party/media_kit_video/` 是从 Kazumi 用的 Predidit 分支摘出来的，
多了两个开关：

- `enableAndroidSurfaceProducer` —— 设 `false` 走保守的 SurfaceTexture 路径
- `androidAttachSurfaceAfterVideoParameters`

`pubspec.yaml` 里是 `media_kit_video: path: third_party/media_kit_video`，
**不要改成 pub.dev 版本**，改了就是全黑屏。

### 6.2 两套 Material 不能混用

Flutter 3.47 起 `package:flutter/material.dart` 拆成了独立包 `material_ui`。

| | 用的什么 |
|---|---|
| `lib/`（主壳） | `package:material_ui/material_ui.dart` |
| `packages/kazumi/` | 也已全量迁移到 `material_ui` |

两边的 `Theme` / `MaterialLocalizations` 是**不同类型**，编译器不报错，
运行时 `Theme.of` 找不到 → release 下渲染成一整块灰。

**新写代码时看一眼 import 路径的包名，不是看类名。**

### 6.3 flutter_modular 的 context 扩展在主壳里全部失效

主壳是 Riverpod，没有 `ModularApp`。下面这些**静默失效，不报错**：

- `context.pushNamed(...)` → 点了没反应
- `context.pop()` / `context.maybePop()` → 同上

遇到 Kazumi 代码里的这类调用，要换成 `Navigator.of(context).push/pop`。

目前已知修过的地方：`DownloadPage`（起播已下载集）、`SysAppBar`、
`PluginViewPage`、`plugin_editor_page`。

### 6.4 Kazumi 的自定义原生通道全部未移植

`com.predidit.kazumi/{intent,pip,appmenu,shortcut,storage}` —— 一个都没有。

调用这些通道的地方必须做好降级，而且要注意：
**`MissingPluginException` 是 `PlatformException` 的兄弟类，不是子类**，
`on PlatformException catch` 抓不到它。

当前处理：
- PiP → `pip_utils.dart` 里有通道可用性缓存，第一次失败后不再请求
- 系统栏 → 优先走宿主通道 `fqapp/player_system_ui`

### 6.5 超分辨率的正确定时机

Anime4K 是 mpv 的 GLSL 用户着色器，有两个前提：

1. **必须在 `player.open()` 之后挂**。open 之前 `vo` 还是 media_kit 的 `'null'`
   占位，此时写 `glsl-shaders` 只会记下属性值，没有 GL 上下文去编译它 ——
   日志显示 applied，实际一帧没跑。
2. **硬解必须是 copy-back 变体**（`auto-copy` / `mediacodec-copy`）。
   直通解码（`auto-safe` 命中 MediaCodec 直出）时帧不经过内存，着色器拿不到纹理。

现在代码里：开超分时自动切 copy-back，关超分时还原。

### 6.6 Bangumi 官方 API 国内直连不通

`api.bgm.tv` / `next.bgm.tv` 实测 20 秒超时。用这两个镜像：

| 镜像 | 提供什么 |
|---|---|
| `api.kazumi.fyi` | `/kazumi/v1/popular/subjects`（榜单，Kazumi 同款）、`calendar/season`（季度表）、`v0/episodes` |
| `bgmapi.anibt.net` | `/v0/search/subjects`（**全库搜索**，不需要签名）、`/v0/subjects/{id}` |

**注意 `api.kazumi.fyi` 的 `popular/subjects` 会间歇性 502**（2026-11-27 挂了一整天）。
代码里有三级回退：rank → heat → kazumi popular。

镜像单页**固定回 20 条**（limit 传多少都一样），且 offset 上限约 1000。

### 6.7 中文路径会挡住 Gradle

项目目录叫「小肥鱼工作区」「影音App」，AGP 默认直接拒绝。
`android/gradle.properties` 里有 `android.overridePathCheck=true`，**别删**。

另外 Flutter SDK 路径**不能含中文**，否则 impellerc 编 shader 会因路径乱码失败。

### 6.8 Flutter 工具写 %APPDATA% 可能被拒

本机遇到过 `flutter` 起不来，报：

```
Flutter failed to write to a file at "C:\Users\<user>\AppData\Roaming\.flutter_tool_state"
```

绕过办法（把 APPDATA 和 LOCALAPPDATA 一起重定向）：

```bash
APPDATA='D:\tmp\appdata' LOCALAPPDATA='D:\tmp\appdata' flutter analyze --no-pub lib
```

### 6.9 CI 上的两个网络坑（都已修）

| 现象 | 原因 | 修法 |
|---|---|---|
| `403 ... gradle-distributions/...gradle-9.5.0-all.zip` | services.gradle.org 307 到 GitHub release，被限流 | CI 里 `sed` 把 distributionUrl 换成国内镜像 |
| `429 Too Many Requests ... kotlin-gradle-plugins-bom` | Maven Central 限流，会让 Gradle 把整个插件仓库标成 disabled | 加 Google 的 Maven Central 镜像兜底 |

维护提示：**遇到 4xx 先怀疑限流，不是代码坏了。**判据是同一份代码换个时间/分支能不能过。

---

## 七、动漫模块当前状态

底部第 2 个 tab 是「动漫」。功能全部打通：

| 功能 | 入口 | 实现位置 |
|---|---|---|
| 热门番组 + 题材筛选 | 动漫页 | `anime_page.dart` |
| 本季新番（按星期） | 动漫页 | 同上 |
| 搜索（全库 + 本地兜底） | 动漫页右上 | `anime_search_page.dart` |
| 详情 / 选集 / 加入书架 | 点卡片 | `anime_detail_page.dart` |
| 播放（选源/超分/弹幕/倍速/PiP） | 点剧集 | Kazumi `VideoPage` |
| **追番**（未看角标、三档排序） | 我的 → 追番 | `anime_follow_page.dart` |
| **下载管理** + 离线起播 | 我的 → 动漫下载 | Kazumi `DownloadPage` |
| **观看历史** | 我的 → 观看历史 | Kazumi `HistoryPage` |
| 播放进度记忆 | 自动（默认开） | Kazumi `HistoryController` |

### 几个关键约定

- **`QingshuPlayback.history` vs `KazumiBootstrap.history` 是两个不同实例。**
  播放/下载写进度用前者，读的时候必须也用前者，否则永远读到空列表。
- 播放装配统一走 `QingshuPlayback.open()`。别自己 new `PlayerController`。
- `MediaItem` 的 `source == 'anime'`、`kind == 'anime'`、`id == 'anime:{subjectId}'`。
  `seriesId` 存纯数字 id（因为 `id` 带冒号不满足 `contentIdPattern`，不能直接进书架）。

---

## 八、弹幕

**Kazumi 上游只有一个自动弹幕源：DanDanPlay**，而它需要 CI 注入的
`DANDANAPI_APPID` / `DANDANAPI_KEY` 做签名。青枢的构建流程从来没有这两个值，
所以 DanDanPlay 一律 403 —— 上游那套等于不可用。

（上游代码里出现的 `BiliBili` / `Gamer` 只是**过滤已下载弹幕的来源标签**，
不会去请求这两个源。这一点容易看错。）

### 青枢的做法：自建 BiliBili 弹幕源

`packages/kazumi/lib/services/danmaku/bili_danmaku_source.dart`

| 步骤 | 接口 |
|---|---|
| 搜索 | `/x/web-interface/wbi/search/all/v2?keyword=` |
| 取 cid | `/x/web-interface/view?bvid=` |
| 拉弹幕 | `/x/v1/dm/list.so?oid={cid}` |

**全是公开接口，不需要鉴权。**

坑：弹幕 XML 是 **raw deflate**（没有 zlib 头），必须用 `ZLibDecoder(raw: true)`，
直接 inflate 会报 `incorrect header check`。

### 自动匹配规则

不能取搜索结果第一条 —— 搜「进击的巨人」第一条是「在百万豪装录音棚大声听 进击的巨人ost」。
现在是三条判据：标题双向包含番剧名 + 时长 ≥10 分钟 + **优先「全/合集/第N季」**。

匹配不准的话，用户可以在弹幕源面板里手动选。

---

## 九、发版清单

每次发版按这个顺序走，别跳步。

```bash
# 1. 改版本号（两处必须一致，有测试守着）
#    pubspec.yaml            version: 2.6.1+261
#    lib/pages/about_page.dart   versionText = '2.6.1 (261)'

# 2. 本地先过分析（两个包都要）
flutter analyze --no-pub lib
flutter analyze --no-pub packages/kazumi/lib

# 3. 提交 + 打 tag + 推送
git add -A && git commit -m "..."
git tag v2.6.1
git push origin master v2.6.1

# 4. 等 CI（约 15–20 分钟）
#    失败就看 build/17_Build APK.txt 这一步的日志

# 5. 下载 APK（别用 GitHub 直连，会断）
#    走 https://gh-proxy.org/<release asset url>，分 8MB 分段 Range 拉
#    直连只有一个办法能稳定：分段 + 重试

# 6. 校验
sha256sum app-release.apk
aapt2 dump badging app-release.apk | head -3   # 确认 versionName/versionCode
unzip -l app-release.apk | grep -c "\.glsl"     # 应该是 9
unzip -l app-release.apk | grep libfqapi_core   # 应该有 2 个（arm64 + armv7）

# 7. 传到 apk 仓库的 Release
```

### 已知的 APK 下载问题

GitHub 的 artifact/release 下载在部分网络下会：
- 卡在 8–40 MB 之间断掉
- 走 `gh-proxy.org` 约 334 KB/s（114 MB 约 6 分钟）
- `ghfast.top` 约 118 KB/s

**稳定做法：8 MB 分段 + Range 请求 + 每段最多重试 4 次**，拼起来再算 sha256。
`qingshu-apk` 仓库里的 `dl_v260.py` 就是干这个的。

---

## 十、代码健康度（交接时的快照）

```
flutter analyze --no-pub lib                      → 0 error
flutter analyze --no-pub packages/kazumi/lib      → 4 error
```

那 4 个 error 全在 `packages/kazumi/lib/pages/menu/menu.dart`，
引用了不存在的 `pages/router.dart` —— 是 Kazumi 自己的旧壳死代码，
主壳没用到。**改动前就存在，不是新引入的。**

如果哪天要清理，整个文件删掉即可（确认没有引用）。

---

## 十一、下一步可以做什么

按价值排：

| 项 | 说明 |
|---|---|
| **真机回归** | v2.5.0 之后超分和弹幕都是新代码，还没跑过完整真机流程 |
| 弹幕匹配优化 | 现在靠标题猜，可以考虑让用户"绑定"一次后记住 |
| 番剧集数与更新提醒 | 追番页的「共 M 集」目前从标题解析，拿不到就显示「集数未知」 |
| 同步播放 | Kazumi 有 syncplay，没接 |
| 截图 / 亮度音量竖滑手势 | Kazumi 播放器里有，没验证过 |

---

## 十二、重要提醒

- **不要在仓库里放任何密钥。** 曾经把 keystore 和明文密码提交进历史，
  后来用 `git filter-repo` 清过全部 82 个提交。别重犯。
- **`gh-proxy.org` 里带 token 的 remote URL 不要贴到任何地方**。输出前先
  `sed -E "s#x-access-token:[^@]*@#***@#g"`。
- 本机的 keystore 备份在 `D:/小肥鱼工作区/06-系统/密钥/qingshu-signing/`，
  换机器一定要先确认这个文件还在。
