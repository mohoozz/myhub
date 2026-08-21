import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 地址栏提交回调（已解析为可导航 URL 或搜索词）。
typedef AddressBarOnSubmit = void Function(String input);

/// 浏览器地址栏（F-601）。
///
/// * URL 智能识别：合法 URL 直接导航，非 URL 输入走默认搜索引擎（13.5 前
///   暂用 Bing 兜底，13.8 接入设置页可配置项）；
/// * 非编辑态显示当前页域名 + 安全图标（HTTPS 锁 / HTTP 警示）；
/// * 聚焦全选编辑、Enter 提交、Esc 取消恢复。
class AddressBar extends StatefulWidget {
  const AddressBar({
    super.key,
    required this.url,
    required this.onSubmit,
    required this.focusNode,
  });

  /// 当前页 URL（'' 表示新建标签）。
  final String url;

  /// 用户提交输入。
  final AddressBarOnSubmit onSubmit;

  /// 外部可控焦点（供 Ctrl+L 聚焦地址栏）。
  final FocusNode focusNode;

  @override
  State<AddressBar> createState() => _AddressBarState();
}

class _AddressBarState extends State<AddressBar> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void didUpdateWidget(covariant AddressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 非编辑态时，外部 URL 变化同步回显完整 URL。
    if (!widget.focusNode.hasFocus && widget.url != oldWidget.url) {
      _controller.text = widget.url;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _host => Uri.tryParse(widget.url)?.host ?? '';

  /// 提交输入：URL 智能识别 → 交给上层导航。
  void _submit() {
    final input = _controller.text.trim();
    if (input.isEmpty) return;
    widget.onSubmit(input);
    widget.focusNode.unfocus();
  }

  /// Esc 取消编辑：恢复为当前页 URL（或清空，新建标签）。
  void _cancel() {
    _controller.text = widget.url;
    widget.focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final focused = widget.focusNode.hasFocus;

    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: colorScheme.brightness == Brightness.dark
            ? const Color(0xFF1A1A1A)
            : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outline),
      ),
      child: Row(
        children: [
          _SecurityIcon(url: widget.url),
          const SizedBox(width: 6),
          Expanded(
            child: focused || _controller.text.isNotEmpty
                ? Focus(
                    onKeyEvent: (node, event) {
                      // Esc 取消编辑、恢复显示
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.escape) {
                        _cancel();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      controller: _controller,
                      focusNode: widget.focusNode,
                      textInputAction: TextInputAction.go,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurface,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: '搜索或输入网址',
                        hintStyle: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                        contentPadding: EdgeInsets.zero,
                      ),
                      // 聚焦时全选，便于直接覆盖输入
                      onTap: () {
                        if (_controller.selection.isCollapsed &&
                            _controller.text.isNotEmpty) {
                          _controller.selection = TextSelection(
                            baseOffset: 0,
                            extentOffset: _controller.text.length,
                          );
                        }
                      },
                      onSubmitted: (_) => _submit(),
                    ),
                  )
                : _buildDomainLabel(theme, colorScheme),
          ),
        ],
      ),
    );
  }

  /// 非编辑态：显示域名（或"新建标签页"提示）。
  Widget _buildDomainLabel(ThemeData theme, ColorScheme colorScheme) {
    final label = _host.isEmpty ? '新建标签页' : _host;
    return GestureDetector(
      onTap: () {
        // 点击进入编辑态：回填完整 URL 并全选
        _controller.text = widget.url;
        widget.focusNode.requestFocus();
      },
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: _host.isEmpty
                ? colorScheme.onSurfaceVariant
                : colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

/// 将用户输入解析为可导航的 URL：合法 URL 原样返回，否则构造搜索 URL。
///
/// * 含 `://` → 视为 URL 原样返回；
/// * `localhost` / IP 地址（可带端口/路径）→ 补全 `http://`；
/// * 形如 `example.com/path`（含点、无空格）→ 补全 `https://`；
/// * 其余 → 走默认搜索引擎（[searchUrlTemplate]，缺省 Bing）。
String resolveNavigationUrl(
  String input, {
  String searchUrlTemplate = 'https://www.bing.com/search?q={query}',
}) {
  final raw = input.trim();
  if (raw.isEmpty) return raw;

  // 已含 scheme
  if (raw.contains('://')) return raw;

  // 本地/内网常见短地址：localhost、127.0.0.1、IP:port
  final looksLikeHost = RegExp(
    r'^(localhost|(\d{1,3}\.){3}\d{1,3})(:\d+)?(/.*)?$',
    caseSensitive: false,
  ).hasMatch(raw);
  if (looksLikeHost) return 'http://$raw';

  // 形如 example.com 或 www.example.com（含点且无空格）
  if (raw.contains('.') && !raw.contains(' ')) {
    return 'https://$raw';
  }

  // 其余视为搜索词
  final encoded = Uri.encodeComponent(raw);
  if (searchUrlTemplate.contains('{query}')) {
    return searchUrlTemplate.replaceAll('{query}', encoded);
  }
  if (searchUrlTemplate.contains('%s')) {
    return searchUrlTemplate.replaceAll('%s', encoded);
  }
  return '$searchUrlTemplate$encoded';
}

/// 安全图标：HTTPS 锁形 / HTTP 警示；起始页不显示。
class _SecurityIcon extends StatelessWidget {
  const _SecurityIcon({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (url.startsWith('https://')) {
      return Icon(LucideIcons.lock, size: 12, color: colorScheme.primary);
    }
    if (url.startsWith('http://')) {
      return Icon(
        LucideIcons.alertTriangle,
        size: 12,
        color: colorScheme.error,
      );
    }
    return const SizedBox.shrink();
  }
}
