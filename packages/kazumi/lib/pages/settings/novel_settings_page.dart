import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/services/novel/novel_reader_prefs.dart';

/// 阅读设置（从「设置 → 应用 → 阅读设置」进）。
///
/// 和阅读页里那个浮层面板共用同一份 [NovelReaderPrefs]，改哪边都一样。
/// 这里额外给一块实时预览，因为设置页没有正文可看，光调滑块很难判断
/// 18 号字和 20 号字差多少。
class NovelSettingsPage extends StatefulWidget {
  const NovelSettingsPage({super.key});

  @override
  State<NovelSettingsPage> createState() => _NovelSettingsPageState();
}

class _NovelSettingsPageState extends State<NovelSettingsPage> {
  late final NovelReaderPrefs _prefs;

  @override
  void initState() {
    super.initState();
    _prefs = inject<NovelReaderPrefs>();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _prefs,
      builder: (context, _) {
        final preset = _prefs.theme;
        return SettingsDetailScaffold(
          title: const Text('阅读设置'),
          body: SettingsList(
            sections: [
              SettingsSection(
                title: const Text('预览'),
                tiles: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: preset.background,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: preset.secondary.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Text(
                        '\u3000\u3000傍晚的风把窗帘吹起来，桌上的书翻过一页。'
                        '她想，今天大概也会是平静的一天。',
                        style: _prefs.textStyle,
                      ),
                    ),
                  ),
                ],
                bottomInfo: const Text('预览用的是当前的字号、行距、字体与背景'),
              ),
              SettingsSection(
                title: const Text('阅读方式'),
                tiles: [
                  SettingsRadioSection<bool>(
                    groupValue: _prefs.pagedMode,
                    onChanged: (value) {
                      if (value != null) _prefs.setPagedMode(value);
                    },
                    tiles: const [
                      SettingsTile<bool>.radioTile(
                        leading: Icons.auto_stories,
                        title: Text('翻页'),
                        description: Text('左右滑动翻页，进度精确到第几页'),
                        radioValue: true,
                      ),
                      SettingsTile<bool>.radioTile(
                        leading: Icons.swap_vert,
                        title: Text('滚动'),
                        description: Text('整章上下滑动，进度只到第几章'),
                        radioValue: false,
                      ),
                    ],
                  ),
                ],
                bottomInfo: const Text('翻页模式下会记住你读到第几页，换字号也不会丢'),
              ),
              SettingsSection(
                title: const Text('文字'),
                tiles: [
                  SettingsSliderTile(
                    leading: Icons.format_size_rounded,
                    title: const Text('字号'),
                    description: const Text('正文文字大小'),
                    value: _prefs.fontSize,
                    valueLabel: _prefs.fontSize.round().toString(),
                    min: 12,
                    max: 34,
                    divisions: 22,
                    onChanged: _prefs.setFontSize,
                  ),
                  SettingsSliderTile(
                    leading: Icons.format_line_spacing_rounded,
                    title: const Text('行距'),
                    description: const Text('行与行之间的距离'),
                    value: _prefs.lineHeight,
                    valueLabel: _prefs.lineHeight.toStringAsFixed(1),
                    min: 1.2,
                    max: 2.6,
                    divisions: 14,
                    onChanged: _prefs.setLineHeight,
                  ),
                  SettingsSliderTile(
                    leading: Icons.margin_rounded,
                    title: const Text('页边距'),
                    description: const Text('正文左右留白'),
                    value: _prefs.margin,
                    valueLabel: _prefs.margin.round().toString(),
                    min: 0,
                    max: 48,
                    divisions: 24,
                    onChanged: _prefs.setMargin,
                  ),
                  SettingsTile.switchTile(
                    leading: Icons.format_indent_increase_rounded,
                    title: const Text('首行缩进'),
                    description: const Text('每段开头空两格'),
                    initialValue: _prefs.indent,
                    onToggle: (value) => _prefs.setIndent(value ?? !_prefs.indent),
                  ),
                ],
              ),
              SettingsSection(
                title: const Text('字体'),
                tiles: [
                  SettingsRadioSection<String>(
                    groupValue: _prefs.fontFamily.id,
                    onChanged: (value) {
                      if (value != null) _prefs.setFontFamily(value);
                    },
                    tiles: [
                      for (final option in NovelFontFamilyOption.values)
                        // 类型参数必须写在类名上：命名构造函数不能带类型参数
                        // （SettingsTile.radioTile<String> 是编译错误）。
                        SettingsTile<String>.radioTile(
                          leading: option == NovelFontFamilyOption.system
                              ? Icons.smartphone_rounded
                              : Icons.font_download_rounded,
                          title: Text(option.label),
                          radioValue: option.id,
                        ),
                    ],
                  ),
                ],
                bottomInfo: const Text('「宋体」使用系统衬线字库，长篇阅读更省力'),
              ),
              SettingsSection(
                title: const Text('背景'),
                tiles: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: Wrap(
                      spacing: 16,
                      runSpacing: 16,
                      children: [
                        for (final option in NovelThemePreset.values)
                          GestureDetector(
                            onTap: () => _prefs.setTheme(option.id),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 56,
                                  height: 56,
                                  decoration: BoxDecoration(
                                    color: option.background,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: preset.id == option.id
                                          ? Theme.of(context)
                                              .colorScheme
                                              .primary
                                          : option.secondary
                                              .withValues(alpha: 0.35),
                                      width: preset.id == option.id ? 2.5 : 1,
                                    ),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    '文',
                                    style: TextStyle(
                                      color: option.text,
                                      fontSize: 18,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  option.label,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              SettingsSection(
                title: const Text('重置'),
                tiles: [
                  SettingsTile(
                    leading: Icons.restart_alt_rounded,
                    title: const Text('恢复默认外观'),
                    description: const Text('字号、行距、边距、字体、背景'),
                    onPressed: (_) => _prefs.resetAppearance(),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
