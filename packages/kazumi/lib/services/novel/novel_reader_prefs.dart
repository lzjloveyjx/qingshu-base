import 'package:flutter/material.dart';

import 'package:kazumi/services/storage/storage.dart';

/// 阅读器的背景配色。
///
/// 为什么不用主题色（colorScheme）推导：阅读页要的是**低刺激、长时间不累**
/// 的纸面效果，而应用主题是给卡片/按钮设计的，它的 surface 在深色模式下
/// 是灰蓝而不是纯黑，长时间读会发灰。所以这里给一组固定的纸面预设，
/// 每套都是「底色 + 正文色」成对出现，避免文字对比度靠猜。
class NovelThemePreset {
  const NovelThemePreset({
    required this.id,
    required this.label,
    required this.background,
    required this.text,
    required this.secondary,
    required this.isDark,
  });

  final String id;
  final String label;
  final Color background;

  /// 正文颜色。
  final Color text;

  /// 章节名、页码、分割线这类次要文字。
  final Color secondary;

  final bool isDark;

  static const NovelThemePreset paper = NovelThemePreset(
    id: 'paper',
    label: '米黄',
    background: Color(0xFFF6F0E2),
    text: Color(0xFF2E2A24),
    secondary: Color(0xFF8A8172),
    isDark: false,
  );

  static const NovelThemePreset white = NovelThemePreset(
    id: 'white',
    label: '白纸',
    background: Color(0xFFFFFFFF),
    text: Color(0xFF1A1A1A),
    secondary: Color(0xFF8C8C8C),
    isDark: false,
  );

  static const NovelThemePreset green = NovelThemePreset(
    id: 'green',
    label: '护眼',
    background: Color(0xFFCCE8CF),
    text: Color(0xFF1F3325),
    secondary: Color(0xFF5E7A66),
    isDark: false,
  );

  static const NovelThemePreset night = NovelThemePreset(
    id: 'night',
    label: '夜间',
    background: Color(0xFF1B1B1B),
    text: Color(0xFFC8C8C8),
    secondary: Color(0xFF7A7A7A),
    isDark: true,
  );

  static const NovelThemePreset black = NovelThemePreset(
    id: 'black',
    label: '纯黑',
    background: Color(0xFF000000),
    text: Color(0xFFAFAFAF),
    secondary: Color(0xFF6A6A6A),
    isDark: true,
  );

  static const List<NovelThemePreset> values = [
    paper,
    white,
    green,
    night,
    black,
  ];

  static NovelThemePreset byId(String id) {
    for (final preset in values) {
      if (preset.id == id) return preset;
    }
    return paper;
  }
}

/// 正文字体族。
///
/// 值直接用 Flutter 的通用族名，交给系统去映射：Android 上 'serif' 落到
/// Noto Serif CJK（宋体味，长篇最舒服），'sans-serif' 落到 Noto Sans CJK。
/// 不写死具体字体文件，是因为中文衬线字重全的字库动辄十几 MB，
/// 为了一个阅读页把包撑大不值得。
class NovelFontFamilyOption {
  const NovelFontFamilyOption({
    required this.id,
    required this.label,
    required this.family,
  });

  final String id;
  final String label;

  /// null = 跟随应用字体（Kazumi 自带 MI Sans）。
  final String? family;

  static const NovelFontFamilyOption system = NovelFontFamilyOption(
    id: 'system',
    label: '系统',
    family: null,
  );
  static const NovelFontFamilyOption serif = NovelFontFamilyOption(
    id: 'serif',
    label: '宋体',
    family: 'serif',
  );
  static const NovelFontFamilyOption sans = NovelFontFamilyOption(
    id: 'sans',
    label: '黑体',
    family: 'sans-serif',
  );

  static const List<NovelFontFamilyOption> values = [system, serif, sans];

  static NovelFontFamilyOption byId(String id) {
    for (final option in values) {
      if (option.id == id) return option;
    }
    return system;
  }
}

/// 阅读器偏好：字号、行距、边距、字体、背景、首行缩进。
///
/// 做成 ChangeNotifier 单例（注册在 coreModule）：阅读页和设置页看的是
/// 同一份状态，改完立刻两边都变，不用各自维护副本。
///
/// 读写全部走 GStorage 的 setting box（同步读、异步写）。写失败不抛错 ——
/// 一次偏好没存上不该让阅读中断。
class NovelReaderPrefs extends ChangeNotifier {
  /// 是否已经从 Hive 读过一次。
  ///
  /// 不用「构造函数里读一次」：这个单例是懒创建的，理论上可能在 GStorage.init()
  /// 之前被 inject 到（比如以后有人从启动流程早期就用它）。那样读会抛错、
  /// 落到默认值，而且**再也不会重读** —— 用户上次调的字号就白设了。
  /// 所以改成「第一次被访问时读，读失败下次还试」。
  bool _loaded = false;

  void _ensureLoaded() {
    if (_loaded) return;
    try {
      _read();
      _loaded = true;
    } catch (_) {
      // box 还没打开（极早期调用）时保持默认值，下次访问再试
    }
  }

  double _fontSize = 18;
  double _lineHeight = 1.8;
  double _margin = 20;
  String _fontFamilyId = 'system';
  String _themeId = 'paper';
  bool _indent = true;
  String _pageMode = 'paged';
  String _pageAnimation = 'curl';
  String _ttsVoiceId = 'xiao_ya';
  String _ttsEnginePackage = '';
  String _ttsEngineVoice = '';
  double _ttsRate = 0.5;
  double _ttsPitch = 1.0;
  bool _ttsAutoNext = true;

  double get fontSize {
    _ensureLoaded();
    return _fontSize;
  }

  double get lineHeight {
    _ensureLoaded();
    return _lineHeight;
  }

  double get margin {
    _ensureLoaded();
    return _margin;
  }

  bool get indent {
    _ensureLoaded();
    return _indent;
  }

  /// true = 翻页阅读，false = 上下滚动。
  bool get pagedMode {
    _ensureLoaded();
    return _pageMode == 'paged';
  }

  /// 翻页动画：slide / none。
  ///
  /// 曾经的 'curl'（仿真卷页）已移除：它需要在外层再挂一套拖拽手势，
  /// 而 PageView 的 Scrollable 会先赢下手势竞技场，导致手指拖不动、
  /// 页面也不翻。保留一个永远卡死的效果不如不给。旧值 'curl' 读到时会
  /// 落到默认分支，等价于 'slide'。
  String get pageAnimation {
    _ensureLoaded();
    return _pageAnimation;
  }

  /// 朗读音色 id。运行时通过 TtsVoice.byId 转成音色对象。
  String get ttsVoiceId {
    _ensureLoaded();
    return _ttsVoiceId;
  }

  /// 系统 TTS 引擎包名（空 = 系统默认）。装了 MultiTTS 时填它的包名。
  String get ttsEnginePackage {
    _ensureLoaded();
    return _ttsEnginePackage;
  }

  /// 引擎内的音色名（空 = 引擎默认）。
  String get ttsEngineVoice {
    _ensureLoaded();
    return _ttsEngineVoice;
  }

  double get ttsRate {
    _ensureLoaded();
    return _ttsRate;
  }

  double get ttsPitch {
    _ensureLoaded();
    return _ttsPitch;
  }

  /// 一章读完自动读下一章。
  bool get ttsAutoNext {
    _ensureLoaded();
    return _ttsAutoNext;
  }
  NovelFontFamilyOption get fontFamily {
    _ensureLoaded();
    return NovelFontFamilyOption.byId(_fontFamilyId);
  }

  NovelThemePreset get theme {
    _ensureLoaded();
    return NovelThemePreset.byId(_themeId);
  }

  /// 正文样式。字重刻意用 w400 而不是主题的 bodyLarge —— 中文正文加粗一点
  /// 就显脏，长读会累。
  TextStyle get textStyle => TextStyle(
        fontSize: fontSize,
        height: lineHeight,
        color: theme.text,
        fontWeight: FontWeight.w400,
        fontFamily: fontFamily.family,
      );

  TextStyle get titleStyle => TextStyle(
        fontSize: fontSize + 3,
        height: 1.4,
        color: theme.text,
        fontWeight: FontWeight.w600,
        fontFamily: fontFamily.family,
      );

  TextStyle get captionStyle => TextStyle(
        fontSize: (fontSize - 4).clamp(10, 20).toDouble(),
        color: theme.secondary,
        fontFamily: fontFamily.family,
      );

  void _read() {
    _fontSize = GStorage.getSetting(SettingsKeys.novelFontSize);
    _lineHeight = GStorage.getSetting(SettingsKeys.novelLineHeight);
    _margin = GStorage.getSetting(SettingsKeys.novelMargin);
    _fontFamilyId = GStorage.getSetting(SettingsKeys.novelFontFamily);
    _themeId = GStorage.getSetting(SettingsKeys.novelTheme);
    _indent = GStorage.getSetting(SettingsKeys.novelIndent);
  }

  void setFontSize(double value) {
    _ensureLoaded();
    final next = value.clamp(12.0, 34.0).toDouble();
    if (next == _fontSize) return;
    _fontSize = next;
    GStorage.putSetting(SettingsKeys.novelFontSize, next);
    notifyListeners();
  }

  void setLineHeight(double value) {
    _ensureLoaded();
    final next = value.clamp(1.2, 2.6).toDouble();
    if (next == _lineHeight) return;
    _lineHeight = next;
    GStorage.putSetting(SettingsKeys.novelLineHeight, next);
    notifyListeners();
  }

  void setMargin(double value) {
    _ensureLoaded();
    final next = value.clamp(0.0, 48.0).toDouble();
    if (next == _margin) return;
    _margin = next;
    GStorage.putSetting(SettingsKeys.novelMargin, next);
    notifyListeners();
  }

  void setFontFamily(String id) {
    _ensureLoaded();
    if (id == _fontFamilyId) return;
    _fontFamilyId = id;
    GStorage.putSetting(SettingsKeys.novelFontFamily, id);
    notifyListeners();
  }

  void setTheme(String id) {
    _ensureLoaded();
    if (id == _themeId) return;
    _themeId = id;
    GStorage.putSetting(SettingsKeys.novelTheme, id);
    notifyListeners();
  }

  void setIndent(bool value) {
    _ensureLoaded();
    if (value == _indent) return;
    _indent = value;
    GStorage.putSetting(SettingsKeys.novelIndent, value);
    notifyListeners();
  }

  void setPagedMode(bool value) {
    _ensureLoaded();
    final next = value ? 'paged' : 'scroll';
    if (next == _pageMode) return;
    _pageMode = next;
    GStorage.putSetting(SettingsKeys.novelPageMode, next);
    notifyListeners();
  }

  void setPageAnimation(String value) {
    _ensureLoaded();
    if (value == _pageAnimation) return;
    _pageAnimation = value;
    GStorage.putSetting(SettingsKeys.novelPageAnimation, value);
    notifyListeners();
  }

  void setTtsVoice(String id) {
    _ensureLoaded();
    if (id == _ttsVoiceId) return;
    _ttsVoiceId = id;
    GStorage.putSetting(SettingsKeys.novelTtsVoice, id);
    notifyListeners();
  }

  void setTtsEnginePackage(String value) {
    _ensureLoaded();
    if (value == _ttsEnginePackage) return;
    _ttsEnginePackage = value;
    GStorage.putSetting(SettingsKeys.novelTtsEnginePackage, value);
    notifyListeners();
  }

  void setTtsEngineVoice(String value) {
    _ensureLoaded();
    if (value == _ttsEngineVoice) return;
    _ttsEngineVoice = value;
    GStorage.putSetting(SettingsKeys.novelTtsEngineVoice, value);
    notifyListeners();
  }

  void setTtsRate(double value) {
    _ensureLoaded();
    final next = value.clamp(0.2, 1.0).toDouble();
    if (next == _ttsRate) return;
    _ttsRate = next;
    GStorage.putSetting(SettingsKeys.novelTtsRate, next);
    notifyListeners();
  }

  void setTtsPitch(double value) {
    _ensureLoaded();
    final next = value.clamp(0.5, 2.0).toDouble();
    if (next == _ttsPitch) return;
    _ttsPitch = next;
    GStorage.putSetting(SettingsKeys.novelTtsPitch, next);
    notifyListeners();
  }

  void setTtsAutoNext(bool value) {
    _ensureLoaded();
    if (value == _ttsAutoNext) return;
    _ttsAutoNext = value;
    GStorage.putSetting(SettingsKeys.novelTtsAutoNext, value);
    notifyListeners();
  }

  /// 恢复默认外观（不含阅读进度）。
  void resetAppearance() {
    _loaded = true;
    _fontSize = 18;
    _lineHeight = 1.8;
    _margin = 20;
    _fontFamilyId = 'system';
    _themeId = 'paper';
    _indent = true;
    _pageMode = 'paged';
    GStorage.putSetting(SettingsKeys.novelFontSize, _fontSize);
    GStorage.putSetting(SettingsKeys.novelLineHeight, _lineHeight);
    GStorage.putSetting(SettingsKeys.novelMargin, _margin);
    GStorage.putSetting(SettingsKeys.novelFontFamily, _fontFamilyId);
    GStorage.putSetting(SettingsKeys.novelTheme, _themeId);
    GStorage.putSetting(SettingsKeys.novelIndent, _indent);
    GStorage.putSetting(SettingsKeys.novelPageMode, _pageMode);
    notifyListeners();
  }
}
