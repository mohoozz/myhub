import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:myhub_flutter/features/browser/browser_provider.dart';

/// PC 端 Chrome 风格标签栏（F-601 13.4）。
///
/// * 标签项：favicon / 加载转圈 + 标题 + 关闭按钮；
/// * 新建（+）/ 关闭 / 切换，中键关闭；
/// * 右键标签弹出菜单：关闭其他、关闭全部。
class TabStrip extends StatelessWidget {
  const TabStrip({
    super.key,
    required this.tabs,
    required this.activeId,
    required this.onSelect,
    required this.onClose,
    required this.onNew,
    required this.onCloseOthers,
    required this.onCloseAll,
  });

  final List<BrowserTabState> tabs;
  final int activeId;
  final void Function(int id) onSelect;
  final void Function(int id) onClose;
  final VoidCallback onNew;
  final void Function(int id) onCloseOthers;
  final VoidCallback onCloseAll;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      height: 34,
      color: colorScheme.surfaceContainerLowest,
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: tabs.length,
              itemBuilder: (context, index) {
                final tab = tabs[index];
                return _TabItem(
                  tab: tab,
                  active: tab.id == activeId,
                  onSelect: () => onSelect(tab.id),
                  onClose: () => onClose(tab.id),
                  onCloseOthers: () => onCloseOthers(tab.id),
                  onCloseAll: onCloseAll,
                );
              },
            ),
          ),
          IconButton(
            onPressed: onNew,
            icon: const Icon(LucideIcons.plus),
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            tooltip: '新建标签页 (Ctrl+T)',
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.tab,
    required this.active,
    required this.onSelect,
    required this.onClose,
    required this.onCloseOthers,
    required this.onCloseAll,
  });

  final BrowserTabState tab;
  final bool active;
  final VoidCallback onSelect;
  final VoidCallback onClose;
  final VoidCallback onCloseOthers;
  final VoidCallback onCloseAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final title = tab.isNewTab
        ? '新标签页'
        : (tab.title.isEmpty ? tab.host : tab.title);

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4, left: 2),
      child: Listener(
        onPointerDown: (event) {
          // 中键关闭标签
          if (event.buttons == kMiddleMouseButton) {
            onClose();
          }
        },
        child: GestureDetector(
          onTap: onSelect,
          onSecondaryTapUp: (details) =>
              _showContextMenu(context, details.globalPosition),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              width: 190,
              constraints: const BoxConstraints(maxWidth: 190),
              decoration: BoxDecoration(
                color: active ? colorScheme.surface : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: active
                    ? Border.all(color: colorScheme.outlineVariant)
                    : null,
              ),
              child: Row(
                children: [
                  const SizedBox(width: 10),
                  _TabIcon(tab: tab),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: active
                            ? colorScheme.onSurface
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  _CloseButton(onClose: onClose, active: active),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showContextMenu(BuildContext context, Offset position) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        const PopupMenuItem<String>(
          value: 'close_others',
          child: Text('关闭其他标签页'),
        ),
        const PopupMenuItem<String>(value: 'close_all', child: Text('关闭全部标签页')),
      ],
    ).then((value) {
      switch (value) {
        case 'close_others':
          onCloseOthers();
        case 'close_all':
          onCloseAll();
      }
    });
  }
}

/// favicon / 加载转圈 / 无痕标识。
class _TabIcon extends StatelessWidget {
  const _TabIcon({required this.tab});

  final BrowserTabState tab;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (tab.loading) {
      return SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: colorScheme.primary,
        ),
      );
    }
    if (tab.incognito) {
      return Icon(
        LucideIcons.eyeOff,
        size: 14,
        color: colorScheme.onSurfaceVariant,
      );
    }
    if (tab.faviconUrl.isNotEmpty) {
      return Image.network(
        tab.faviconUrl,
        width: 14,
        height: 14,
        errorBuilder: (_, __, ___) => _fallbackGlobe(colorScheme),
      );
    }
    return _fallbackGlobe(colorScheme);
  }

  Widget _fallbackGlobe(ColorScheme colorScheme) =>
      Icon(LucideIcons.globe, size: 14, color: colorScheme.onSurfaceVariant);
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onClose, required this.active});

  final VoidCallback onClose;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onClose,
      customBorder: const CircleBorder(),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Icon(
          LucideIcons.x,
          size: 12,
          color: active ? colorScheme.onSurface : colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
