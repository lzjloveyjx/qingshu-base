import 'package:material_ui/material_ui.dart';
import 'package:kazumi/bean/widget/state_presentation.dart';

/// Shrink-wraps in slivers and scrolls within bounded viewports.
class GeneralEmptyState extends StatelessWidget {
  const GeneralEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.actions = const [],
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final List<Widget> actions;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    // 青枢：这里原来套 SingleChildScrollView，被放进 sliver（无界高度）时
    // 会抛 "Vertical viewport was given unbounded height"，release 构建下
    // 整块退化成没有文字的灰块（规则管理/规则仓库空列表时必现）。
    // 空态本来就不需要滚动，去掉滚动层即可。
    return Center(
      child: Padding(
        padding: compact
            ? const EdgeInsets.all(16)
            : const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              StateIconBadge(
                icon: icon,
                size: compact ? 56 : 88,
                iconSize: compact ? 28 : 36,
                backgroundColor: colorScheme.secondaryContainer,
                foregroundColor: colorScheme.onSecondaryContainer,
              ),
              SizedBox(height: compact ? 16 : 24),
              Semantics(
                header: true,
                liveRegion: true,
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style:
                      (compact ? textTheme.titleMedium : textTheme.titleLarge)
                          ?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (actions.isNotEmpty) ...[
                SizedBox(height: compact ? 16 : 24),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
