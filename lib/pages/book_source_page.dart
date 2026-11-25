/// 青枢 · 书源设置页：切换「去哪找书」。
///
/// 只影响发现页（首页/搜索/详情/阅读）；书架与阅读进度完全共享。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/book_source_preference.dart';
import '../widgets/home/home_design.dart';
import '../widgets/wenku/wenku_ui.dart';

class BookSourcePage extends StatelessWidget {
  const BookSourcePage({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return WenkuPage(
      header: const Align(
        alignment: Alignment.centerLeft,
        child: ArchiveMasthead(title: '书源', code: '05 / SOURCES'),
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ValueListenableBuilder<BookSource>(
            valueListenable: BookSourcePreference.instance.source,
            builder: (context, current, _) {
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  Text(
                    '书源决定首页与搜索去哪里找书。切换书源不会影响已加入书架的书和阅读进度。',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: palette.ink.withValues(alpha: 0.62),
                    ),
                  ),
                  const SizedBox(height: 16),
                  for (final src in BookSource.values) ...[
                    _SourceTile(
                      source: src,
                      selected: src == current,
                      onTap: () => BookSourcePreference.instance.set(src),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final BookSource source;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Material(
      color: palette.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Icon(
                source == BookSource.wenku8
                    ? LucideIcons.library_big
                    : LucideIcons.book_open,
                size: 20,
                color: selected ? palette.accentText : palette.muted,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                        color: palette.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      source == BookSource.wenku8
                          ? '收录全、有题材分类，站点为第三方分享站'
                          : '轻之国度社区，正文带插图与分卷',
                      style: TextStyle(
                        fontSize: 12,
                        color: palette.ink.withValues(alpha: 0.55),
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(LucideIcons.check, size: 20, color: palette.accentText),
            ],
          ),
        ),
      ),
    );
  }
}