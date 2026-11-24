import 'package:flutter/material.dart';

import 'package:kazumi/services/novel/novel_tts_controller.dart';

/// 听书控制面板（底部弹出）。
///
/// 参考番茄阅读 / novel-sound 的听书条：不是只有一个播放键，而是把「现在
/// 读到哪、还有多少、多快、往前往后」都摆出来 —— 听书时用户多半不看屏幕，
/// 偶尔摸一下要能立刻知道进度、能跳到下一段。
///
/// 为什么不做成常驻浮条：阅读页正文已经占满屏幕，常驻条会挡住最后一行。
/// 底部弹层是「用完就走」的，更符合摸一下继续听的动作。
class ListeningSheet extends StatefulWidget {
  const ListeningSheet({
    super.key,
    required this.state,
    required this.sentenceIndex,
    required this.sentenceCount,
    required this.sentenceText,
    required this.chapterTitle,
    required this.speed,
    required this.onToggle,
    required this.onPrevious,
    required this.onNext,
    required this.onSeekSentence,
    required this.onSpeedChanged,
    required this.onClose,
    required this.accent,
    required this.textColor,
    required this.secondaryColor,
    required this.background,
  });

  final TtsPlaybackState state;
  final int sentenceIndex;
  final int sentenceCount;

  /// 当前正在读的那句（给用户确认「确实是这里」）。
  final String sentenceText;
  final String chapterTitle;
  final double speed;

  final Future<void> Function() onToggle;
  final Future<void> Function() onPrevious;
  final Future<void> Function() onNext;
  final Future<void> Function(int index) onSeekSentence;
  final Future<void> Function(double speed) onSpeedChanged;
  final VoidCallback onClose;

  final Color accent;
  final Color textColor;
  final Color secondaryColor;
  final Color background;

  @override
  State<ListeningSheet> createState() => _ListeningSheetState();
}

class _ListeningSheetState extends State<ListeningSheet> {
  /// 拖动进度时的本地预览值；null = 跟随真实进度。
  double? _drag;

  bool get _playing => widget.state == TtsPlaybackState.speaking;
  bool get _active => widget.state != TtsPlaybackState.idle;

  @override
  Widget build(BuildContext context) {
    final total = widget.sentenceCount <= 0 ? 1 : widget.sentenceCount;
    final progress =
        ((widget.sentenceIndex + 1) / total).clamp(0.0, 1.0);
    final shown = _drag ?? progress;

    return Container(
      decoration: BoxDecoration(
        color: widget.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: widget.secondaryColor.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Icon(Icons.headphones, size: 18, color: widget.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.chapterTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        color: widget.textColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '${widget.sentenceIndex + 1} / ${widget.sentenceCount} 句',
                    style: TextStyle(fontSize: 11, color: widget.secondaryColor),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // 当前句：让用户确认「确实读到这里」。
              if (widget.sentenceText.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: widget.secondaryColor.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    widget.sentenceText,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: widget.textColor.withValues(alpha: 0.85),
                    ),
                  ),
                ),
              const SizedBox(height: 6),

              // 进度条：拖动时只改预览，松手才真的跳句 —— 逐帧跳句会把
              // 系统 TTS 的 speak/stop 打爆。
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                  activeTrackColor: widget.accent,
                  inactiveTrackColor: widget.secondaryColor.withValues(alpha: 0.25),
                  thumbColor: widget.accent,
                ),
                child: Slider(
                  value: shown.toDouble(),
                  onChanged: (v) => setState(() => _drag = v),
                  onChangeEnd: (v) {
                    final target =
                        (v * widget.sentenceCount).floor().clamp(
                              0,
                              widget.sentenceCount - 1,
                            );
                    setState(() => _drag = null);
                    widget.onSeekSentence(target);
                  },
                ),
              ),

              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    iconSize: 30,
                    tooltip: '上一句',
                    onPressed: _active ? () => widget.onPrevious() : null,
                    icon: Icon(Icons.skip_previous, color: widget.textColor),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filled(
                    iconSize: 38,
                    tooltip: _playing ? '暂停' : '继续',
                    onPressed: widget.onToggle,
                    icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                  ),
                  const SizedBox(width: 10),
                  IconButton(
                    iconSize: 30,
                    tooltip: '下一句',
                    onPressed: _active ? () => widget.onNext() : null,
                    icon: Icon(Icons.skip_next, color: widget.textColor),
                  ),
                ],
              ),
              const SizedBox(height: 4),

              // 倍速：系统 TTS 的 setSpeechRate 语义，1.0 正常。
              Row(
                children: [
                  Text('语速',
                      style: TextStyle(fontSize: 12, color: widget.secondaryColor)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final s in const [0.7, 1.0, 1.3, 1.6, 2.0])
                          ChoiceChip(
                            label: Text('${s}x', style: const TextStyle(fontSize: 12)),
                            selected: (widget.speed - s).abs() < 0.05,
                            onSelected: (_) => widget.onSpeedChanged(s),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: widget.onClose,
                child: Text('收起', style: TextStyle(color: widget.secondaryColor)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
