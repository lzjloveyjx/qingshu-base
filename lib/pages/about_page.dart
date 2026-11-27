// Two presentations, one about page.
//
// Archive keeps the Wenku8 rev ebcd7f1 shell from #291
// (`ArchiveFeaturePage` + `ArchiveSection` + `ContentPanel`); classic restores
// the pre-#291 `SettingsScaffold` layout from fqapp-backup@f329399
// (`SettingsGroupCard` + `SettingsRow`). Both go through `SettingsArchivePage`,
// so the Windows right pane keeps its content instead of popping itself blank.
//
// 【青枢】与基底项目的差异（同一套两版式，内容只此一份）：
//   • 应用名/简介/版本号换成青枢自己的（不再是什锦铺 1.0.205）
//   • GitHub 链接指向 lzjloveyjx/qingshu-base 与 qingshu-apk
//   • 移除基底项目的「支持作者」卡（爱发电 + 微信赞赏）—— 青枢是自用项目，
//     没有赞助入口，相关常量与弹窗一并删掉
import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/app_ui/app_ui_scope.dart';
import '../widgets/home/home_design.dart';
import '../widgets/settings/classic_settings_icons.dart';
import '../widgets/settings/settings_adaptive.dart';
import '../widgets/settings/settings_archive_page.dart';
import '../widgets/settings/settings_widgets.dart';
import '../widgets/wenku/wenku_ui.dart';

/// About page in the selected presentation: centered logo/name header, a short
/// intro paragraph, then the version / updates / licences / source / feedback
/// rows and the support card.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  /// Display version, kept in lockstep with pubspec.yaml's
  /// `version`. Without a package_info dependency the value is
  /// static, so test/about_version_test.dart parses the pubspec and fails the
  /// build check when the two drift apart after a version bump.
  static const versionText = '2.6.0 (260)';

  /// Pixel width of the bundled logo (assets/images/app_logo.webp). The logo
  /// is displayed at 80dp, so it only needs re-decoding above 4× DPI; clamping
  /// to the asset's real width keeps a high-DPI device from asking the decoder
  /// to upscale a surface the asset does not have. Keep it in sync with
  /// LOGO_SIZE in scripts/generate_app_icons.py.
  static const _logoPixelWidth = 384;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = HomePalette.of(context);
    final scheme = theme.colorScheme;
    final classic = AppUiScope.isClassic(context);

    return SettingsArchivePage(
      title: '关于',
      code: 'SYSTEM / ABOUT',
      child: ListView(
        key: const ValueKey('about-scroll'),
        padding: featurePadding(context),
        children: [
          const _AboutLogo(),
          const SizedBox(height: 12),
          const _AboutHeading(),
          const SizedBox(height: 16),
          Text(
            '青枢是一个自用的日轻小说 + 番剧聚合客户端：'
            '小说来自文库与本地导入，番剧来自 Bangumi 元数据与规则源解析。'
            '数据与播放全部在本地完成，不上传、不依赖第三方账号。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.7,
            ),
          ),
          const SizedBox(height: 12),
          // The archive page labels its info panel; the pre-#291 page put the
          // grouped card straight under the intro paragraph.
          if (!classic) ...[
            const SizedBox(height: 12),
            const SettingsSection(title: '应用信息', code: 'FQAPP / ABOUT'),
            const SizedBox(height: 14),
          ],
          const _AboutInfoCard(),
          const SizedBox(height: 24),
          Center(
            child: Text(
              '仅限个人学习研究使用\n请遵守相关法律法规',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: palette.muted, height: 1.5),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// 版本行点按：把版本号写进剪贴板，并用 SnackBar 明示已复制。
  static void _copyVersion(BuildContext context) {
    unawaited(Clipboard.setData(const ClipboardData(text: versionText)));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制版本号')));
  }

}

/// 信息卡：版本（点按复制）、检查更新、开源许可、源码与反馈。
class _AboutInfoCard extends StatelessWidget {
  const _AboutInfoCard();

  /// Fixed chrome around the version row: card gutters, the 38dp icon tile (or
  /// the 21dp archive glyph), the gaps and the trailing copy glyph/chevron.
  static const _classicChrome = 16 + 16 + 38 + 12 + 12 + 6 + 15;
  static const _archiveChrome = 16 + 16 + 21 + 12 + 8 + 8 + 14 + 6 + 15;

  static double _textWidth(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) {
    final classic = AppUiScope.isClassic(context);
    final scheme = Theme.of(context).colorScheme;
    final palette = HomePalette.of(context);
    final versionStyle = const TextStyle(fontSize: 13);
    final titleStyle = const TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w600,
    );
    final muted = classic ? palette.muted : scheme.onSurfaceVariant;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Keep the version inline while it and the row title fit; otherwise
        // move it to the subtitle so 320dp / 2× text cannot overflow the row
        // (the trailing row has natural width and cannot shrink).
        final chrome = classic ? _classicChrome : _archiveChrome;
        final needed =
            chrome +
            _textWidth(context, '当前版本', titleStyle) +
            _textWidth(context, AboutPage.versionText, versionStyle);
        final inline = constraints.maxWidth >= needed;
        final copyIcon = Icon(
          LucideIcons.copy,
          size: 15,
          color: classic ? palette.muted : scheme.onSurfaceVariant,
        );
        final rows = <Widget>[
          _InfoRow(
            icon: LucideIcons.badge_check,
            title: '当前版本',
            subtitle: inline ? null : AboutPage.versionText,
            trailing: inline
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        AboutPage.versionText,
                        style: TextStyle(fontSize: 13, color: muted),
                      ),
                      const SizedBox(width: 6),
                      copyIcon,
                    ],
                  )
                : copyIcon,
            onTap: () => AboutPage._copyVersion(context),
          ),
          _InfoRow(
            icon: LucideIcons.square_arrow_out_up_right,
            title: '检查更新',
            subtitle: '前往 GitHub 发布页查看新版本',
            onTap: () => _launchExternalUrl(
              context,
              'https://github.com/lzjloveyjx/qingshu-apk/releases',
            ),
          ),
          _InfoRow(
            icon: LucideIcons.scale,
            title: '开源许可',
            subtitle: 'GPL-3.0 与第三方组件许可',
            onTap: () => showLicensePage(
              context: context,
              applicationName: '青枢',
              applicationVersion: AboutPage.versionText,
              applicationLegalese:
                  '青枢基于 GPL-3.0 协议开源，第三方组件遵循其各自的许可协议。'
                  '动漫模块的播放页与规则解析源自 Kazumi（同为 GPL-3.0）；'
                  'Wenku8 Flutter 界面来源与许可文本见 assets/licenses/wenku8。',
            ),
          ),
          _InfoRow(
            icon: LucideIcons.code_xml,
            title: '源代码',
            subtitle: 'github.com/lzjloveyjx/qingshu-base',
            onTap: () => _launchExternalUrl(
              context,
              'https://github.com/lzjloveyjx/qingshu-base',
            ),
          ),
          _InfoRow(
            icon: LucideIcons.message_square,
            title: '问题反馈',
            subtitle: '前往 GitHub Issues 提交',
            onTap: () => _launchExternalUrl(
              context,
              'https://github.com/lzjloveyjx/qingshu-base/issues',
            ),
          ),
        ];
        if (classic) return SettingsGroupCard(children: rows);
        return ContentPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows,
          ),
        );
      },
    );
  }
}

/// Information row: leading icon, title/subtitle and an optional trailing
/// value. The whole row is the tap target.
///
/// Classic renders the pre-#291 `SettingsRow` (soft icon tile, 38dp square);
/// archive keeps the Wenku8 inline row.
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (AppUiScope.isClassic(context)) {
      return SettingsRow(
        icon: classicSettingsIcon(title, icon),
        iconTile: true,
        title: title,
        subtitle: subtitle,
        trailing: trailing,
        onTap: onTap,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          ArchiveIcon(icon, size: 21),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 5),
                  AppText(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          if (onTap != null) ...[
            const SizedBox(width: 8),
            const ArchiveIcon(CupertinoIcons.chevron_right, size: 14),
          ],
        ],
      ),
    );
    if (onTap == null) return content;
    return Semantics(
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: content,
      ),
    );
  }
}

/// 头部 logo：全幅图片，圆角与投影跟随图版的 15% 板式圆角。
class _AboutLogo extends StatelessWidget {
  const _AboutLogo();

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Center(
      // The bundled logo is full-bleed; 12 of 80 keeps the plate's 15%
      // corner radius so the image and the shadow outline agree.
      child: Container(
        key: const ValueKey('about-logo-plate'),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          // 墨水屏没有彩色投影可投；留一圈阴影只会糊成一团黑。
          boxShadow: palette.eink
              ? null
              : [
                  BoxShadow(
                    color: palette.accentText.withValues(alpha: 0.20),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.asset(
            'assets/images/app_logo.webp',
            width: 80,
            height: 80,
            // Decode at the display size rather than the whole 384²
            // surface, which would hold ~590 KB in the image cache for a
            // 80dp logo.
            cacheWidth: (80 * MediaQuery.devicePixelRatioOf(context))
                .round()
                .clamp(80, AboutPage._logoPixelWidth),
            fit: BoxFit.contain,
            excludeFromSemantics: true,
          ),
        ),
      ),
    );
  }
}

/// 头部应用名与一行定位副标题。
class _AboutHeading extends StatelessWidget {
  const _AboutHeading();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        AppText(
          '青枢',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            height: 1.25,
            fontWeight: FontWeight.bold,
            letterSpacing: -0.3,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        AppText(
          '日轻小说 / 番剧播放在线聚合客户端',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
      ],
    );
  }
}

/// 用外部应用打开 [url]。Android 的包可见性可能让浏览器对 canLaunchUrl
/// 不可见，但仍能处理 ACTION_VIEW，所以这里不做预检查，失败统一走可见提示。
Future<void> _launchExternalUrl(BuildContext context, String url) async {
  final uri = Uri.parse(url);
  var launched = false;
  try {
    launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    // Report launch failures through the same visible fallback.
  }
  if (!launched && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法打开链接')));
  }
}
