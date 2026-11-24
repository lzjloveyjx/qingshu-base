import 'package:flutter/material.dart';

/// 一个排版单元：一段文字，或一张插图。
///
/// 分页必须在「块」这一层做，而不是把整章塞进一个 TextPainter：插图不参与
/// 文字排版，混进去算高度只能靠猜；拆成块之后，文字块用 TextPainter 精确
/// 测量，图片块用一个估计高度，两者相加就是这一页占了多少。
class NovelBlock {
  const NovelBlock.text(String value)
      : text = value,
        imageUrl = null;

  const NovelBlock.image(String url)
      : imageUrl = url,
        text = '';

  final String text;
  final String? imageUrl;

  bool get isImage => imageUrl != null;
}

/// 一页排版结果。
class NovelPage {
  const NovelPage({
    required this.blocks,
    required this.firstParagraphIndex,
  });

  final List<NovelBlock> blocks;

  /// 本页第一个段落（块）在整章里的下标。
  ///
  /// 这是进度的**锚点**：字号/边距一改，页数会全变，第 5 页可能变成第 4 页，
  /// 但「这一页从第 37 段开始」是稳定的。所以存进度时同时存页码（给用户看）
  /// 和段落下标（用来恢复位置）。
  final int firstParagraphIndex;

  bool get isEmpty => blocks.isEmpty;
}

/// 把一章切成若干页。
///
/// 为什么自己算而不上别人现成的分页组件：中文排版的分页规则跟西文不一样
/// （标点不能出现在行首、段首缩进两个全角空格），而 Flutter 的 TextPainter
/// 已经处理了换行与断行规则，我们只需要在「行」这一层切。所以做法是：
///   1. 每个段落单独 layout，拿到逐行高度
///   2. 按剩余高度决定这一页能放几行
///   3. 用 getPositionForOffset 把「第 N 行的行首」换算成字符偏移，再切字符串
/// 这样切出来的页跟 TextPainter 的实际渲染完全一致，不会出现「这一页最后一行
/// 被截掉半个字」。
class NovelPaginator {
  const NovelPaginator();

  /// 正文里插图的标记前缀，和 NovelContentExtractor 保持一致。
  static const String imageMarker = '[图片] ';

  /// 把「正文段落」转成「排版块」。
  ///
  /// 缩进在这里一次性加好，而不是分页时再拼 —— 分页只做字符串切片，
  /// 一旦要拼接就得记住「这一块是不是段落开头」，出错率高。
  List<NovelBlock> blocksOf(List<String> paragraphs, {required bool indent}) {
    final out = <NovelBlock>[];
    for (final raw in paragraphs) {
      final p = raw.trim();
      if (p.isEmpty) continue;
      if (p.startsWith(imageMarker)) {
        final url = p.substring(imageMarker.length).trim();
        if (url.startsWith('http')) {
          out.add(NovelBlock.image(url));
        }
        // 地址不是 http 的（抽取失败留下的残渣）直接丢掉，不占版面。
        continue;
      }
      out.add(NovelBlock.text(indent ? '\u3000\u3000$p' : p));
    }
    return out;
  }

  /// 分页主入口。
  ///
  /// [maxWidth] / [maxHeight] 是**正文可用区域**（已扣掉页边距与工具栏），
  /// 调用方负责算。
  List<NovelPage> paginate({
    required List<String> paragraphs,
    required TextStyle style,
    required double maxWidth,
    required double maxHeight,
    required bool indent,
    required double paragraphSpacing,
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    if (paragraphs.isEmpty || maxWidth <= 0 || maxHeight <= 0) {
      return const <NovelPage>[];
    }
    final blocks = blocksOf(paragraphs, indent: indent);
    if (blocks.isEmpty) return const <NovelPage>[];

    // 插图高度估计：轻小说插图多是竖版，宽高比约 1 : 1.42。
    // 上限压在 85% 页高，避免一张图把整页撑爆。
    final imageHeight = (maxWidth * 1.42).clamp(0.0, maxHeight * 0.85);

    final pages = <NovelPage>[];
    var page = <NovelBlock>[];
    var pageFirst = 0;
    var used = 0.0;

    double avail() => maxHeight - used;

    void flush() {
      if (page.isEmpty) return;
      pages.add(NovelPage(
        blocks: List<NovelBlock>.unmodifiable(page),
        firstParagraphIndex: pageFirst,
      ));
      page = <NovelBlock>[];
      used = 0;
    }

    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];

      if (block.isImage) {
        if (page.isNotEmpty && avail() < imageHeight + paragraphSpacing) {
          flush();
        }
        if (page.isEmpty) pageFirst = i;
        page.add(block);
        used += imageHeight + paragraphSpacing;
        // 一张图占满剩下的空间后就翻页，避免图下面贴一行字显得很挤。
        if (avail() <= paragraphSpacing) flush();
        continue;
      }

      var rest = block.text;
      while (rest.isNotEmpty) {
        final painter = _layout(rest, style, maxWidth, textScaler);
        final need = painter.height + paragraphSpacing;

        if (need <= avail()) {
          if (page.isEmpty) pageFirst = i;
          page.add(NovelBlock.text(rest));
          used += need;
          break;
        }

        // 放不下 → 看看这一页还能容纳几行
        final room = avail() - paragraphSpacing;
        final split = room > 0
            ? _splitByLines(
                painter: painter,
                text: rest,
                maxHeight: room,
              )
            : null;

        if (split == null) {
          // 一行都放不下：先翻页。如果当前页本来就是空的（页面极矮），
          // 强制塞下整段，宁可溢出也不要死循环。
          if (page.isNotEmpty) {
            flush();
            continue;
          }
          pageFirst = i;
          page.add(NovelBlock.text(rest));
          used = maxHeight;
          flush();
          break;
        }

        if (page.isEmpty) pageFirst = i;
        page.add(NovelBlock.text(split.head));
        used = maxHeight;
        flush();
        rest = split.tail;
      }
    }
    flush();
    return pages;
  }

  TextPainter _layout(
    String text,
    TextStyle style,
    double maxWidth,
    TextScaler textScaler,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout(maxWidth: maxWidth);
    return painter;
  }

  /// 在「行」这一层切一刀。
  ///
  /// 返回 null 表示连一行都放不下（调用方负责翻页）。
  ({String head, String tail})? _splitByLines({
    required TextPainter painter,
    required String text,
    required double maxHeight,
  }) {
    final lines = painter.computeLineMetrics();
    if (lines.isEmpty) return null;

    var usedHeight = 0.0;
    var fitLines = 0;
    for (final line in lines) {
      if (usedHeight + line.height > maxHeight) break;
      usedHeight += line.height;
      fitLines++;
    }
    // 一行都放不下，或者整段其实都放得下（理论上不会走到这里）
    if (fitLines <= 0 || fitLines >= lines.length) return null;

    // 第 fitLines 行的行首 = 下一页的第一个字。行首的 y 就是前面所有行高之和。
    final nextLineTop = usedHeight;
    final offset = painter
        .getPositionForOffset(Offset(0, nextLineTop + 1))
        .offset;
    if (offset <= 0 || offset >= text.length) return null;
    return (head: text.substring(0, offset), tail: text.substring(offset));
  }
}
