import 'package:flutter/material.dart';

/// EPUB 章节富文本原子（自建轻量渲染，TODO 6.2）。
///
/// 为什么不引入 flutter_widget_from_html：翻页模式依赖 TextPainter
/// 测量分页，HTML→Widget 树的方案无法分页；文本原子序列既可保留
/// 内联样式，又能用 TextPainter 精确分页（图片为固定尺寸占位符）。
sealed class RichAtom {
  const RichAtom();

  /// 在排版文本流中占用的字符数（图片为 \uFFFC 占位符 1 字符）。
  int get charLength;
}

/// 文本 run。
class TextAtom extends RichAtom {
  const TextAtom(this.text, this.style);

  final String text;
  final TextStyle style;

  @override
  int get charLength => text.length;
}

/// 内联图片。
class ImgAtom extends RichAtom {
  const ImgAtom(this.resourceId);

  /// 图片在 EPUB 内的完整路径（经 GET /api/reader/epub/resource?id= 加载）。
  final String resourceId;

  @override
  int get charLength => 1;
}

/// 原子序列 → InlineSpan（图片为固定尺寸盒，内容由 [imageBuilder] 填充）。
List<InlineSpan> buildRichSpans(
  List<RichAtom> atoms, {
  required double imgWidth,
  required double imgHeight,
  required Widget Function(ImgAtom atom) imageBuilder,
}) {
  return [
    for (final a in atoms)
      if (a is TextAtom)
        TextSpan(text: a.text, style: a.style)
      else if (a is ImgAtom)
        WidgetSpan(
          alignment: PlaceholderAlignment.bottom,
          child: SizedBox(
            width: imgWidth,
            height: imgHeight,
            child: imageBuilder(a),
          ),
        ),
  ];
}

/// 原子序列的完整排版文本（图片为 \uFFFC 占位符）。
String richAtomsText(List<RichAtom> atoms) {
  final buf = StringBuffer();
  for (final a in atoms) {
    buf.write(a is TextAtom ? a.text : '\uFFFC');
  }
  return buf.toString();
}

/// 按排版字符区间 [start, end) 切分原子序列。
List<RichAtom> sliceRichAtoms(List<RichAtom> atoms, int start, int end) {
  final out = <RichAtom>[];
  var offset = 0;
  for (final a in atoms) {
    final aStart = offset;
    final aEnd = offset + a.charLength;
    offset = aEnd;
    if (aEnd <= start) continue;
    if (aStart >= end) break;
    if (a is ImgAtom) {
      out.add(a);
      continue;
    }
    final t = a as TextAtom;
    final s = (start - aStart).clamp(0, t.text.length);
    final e = (end - aStart).clamp(0, t.text.length);
    if (e > s) {
      out.add(TextAtom(t.text.substring(s, e), t.style));
    }
  }
  return out;
}

/// 将章节内相对 href 解析为 EPUB 内完整路径（与后端 resolveHref 对齐）。
String resolveEpubHref(String chapterHref, String href) {
  var h = href;
  final hash = h.indexOf('#');
  if (hash >= 0) {
    h = h.substring(0, hash);
  }
  if (h.isEmpty) return '';
  final slash = chapterHref.lastIndexOf('/');
  final baseDir = slash < 0 ? '' : chapterHref.substring(0, slash);
  final parts = <String>[
    if (baseDir.isNotEmpty) ...baseDir.split('/'),
  ];
  for (final seg in h.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(seg);
  }
  return parts.join('/');
}

/// EPUB 章节 XHTML 轻量解析器：标签栈 + 内联样式继承。
///
/// 支持 b/strong、i/em、u、s/del、sup/sub、code、a、blockquote、h1-h6
/// 等内联样式；块级标签转为段落换行；img 解析为图片原子；
/// script/style/head/svg/nav/rt/rp 等标签跳过整个子树。
class EpubHtmlParser {
  EpubHtmlParser({required this.baseStyle, required this.chapterHref});

  /// 基础文本样式（阅读器字号/行距/颜色）。
  final TextStyle baseStyle;

  /// 当前章节在 EPUB 内的路径（img src 相对它解析）。
  final String chapterHref;

  /// 跳过子树的标签。
  static const Set<String> _skipTags = {
    'script', 'style', 'head', 'title', 'meta', 'link',
    'svg', 'nav', 'rt', 'rp',
  };

  /// 边界处产生换行的块级标签。
  static const Set<String> _blockTags = {
    'p', 'div', 'section', 'article', 'header', 'footer', 'ul', 'ol', 'li',
    'blockquote', 'pre', 'table', 'tr', 'figure', 'figcaption', 'hr',
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  };

  /// 标题字号倍率。
  static const Map<String, double> _headingScale = {
    'h1': 1.5,
    'h2': 1.35,
    'h3': 1.25,
    'h4': 1.15,
    'h5': 1.1,
    'h6': 1.05,
  };

  List<RichAtom> parse(String html) {
    final atoms = <RichAtom>[];
    final textBuf = StringBuffer();
    var style = baseStyle;
    final styleStack = <TextStyle>[];
    final styleTagStack = <String>[];
    final skipStack = <String>[];

    void flushText() {
      if (textBuf.isEmpty) return;
      // HTML 空白折叠
      final collapsed = textBuf.toString().replaceAll(RegExp(r'\s+'), ' ');
      textBuf.clear();
      if (collapsed.isEmpty) return;
      atoms.add(TextAtom(collapsed, style));
    }

    void newline() {
      flushText();
      atoms.add(TextAtom('\n', baseStyle));
    }

    var i = 0;
    final n = html.length;
    while (i < n) {
      final lt = html.indexOf('<', i);
      if (lt < 0) {
        textBuf.write(_decodeEntities(html.substring(i)));
        break;
      }
      if (lt > i) {
        textBuf.write(_decodeEntities(html.substring(i, lt)));
      }
      // 注释与声明
      if (html.startsWith('<!--', lt)) {
        final end = html.indexOf('-->', lt + 4);
        i = end < 0 ? n : end + 3;
        continue;
      }
      if (html.startsWith('<?', lt) || html.startsWith('<!', lt)) {
        final end = html.indexOf('>', lt + 2);
        i = end < 0 ? n : end + 1;
        continue;
      }
      final gt = html.indexOf('>', lt + 1);
      if (gt < 0) break;
      final tagContent = html.substring(lt + 1, gt);
      i = gt + 1;

      final isClose = tagContent.startsWith('/');
      final selfClosing = tagContent.endsWith('/');
      var name = tagContent
          .replaceAll('/', ' ')
          .trim()
          .split(RegExp(r'\s'))
          .first
          .toLowerCase();
      // 去命名空间前缀（xhtml:p 等）
      final colon = name.indexOf(':');
      if (colon >= 0) {
        name = name.substring(colon + 1);
      }
      if (name.isEmpty) continue;

      // 跳过子树模式
      if (skipStack.isNotEmpty) {
        if (!isClose && !selfClosing && name == skipStack.last) {
          skipStack.add(name);
        } else if (isClose && name == skipStack.last) {
          skipStack.removeLast();
        }
        continue;
      }
      if (!isClose && !selfClosing && _skipTags.contains(name)) {
        if (name == 'script' || name == 'style') {
          // CSS/JS 内容可能含 '>'，直接跳到闭合标签
          final lower = html.toLowerCase();
          final closeIdx = lower.indexOf('</$name', i);
          if (closeIdx < 0) {
            i = n;
          } else {
            final closeGt = html.indexOf('>', closeIdx);
            i = closeGt < 0 ? n : closeGt + 1;
          }
        } else {
          skipStack.add(name);
        }
        continue;
      }

      if (isClose) {
        if (styleTagStack.isNotEmpty && styleTagStack.last == name) {
          styleTagStack.removeLast();
          style = styleStack.removeLast();
        }
        if (_blockTags.contains(name)) {
          newline();
        }
        continue;
      }

      // 内联样式标签
      final newStyle = _applyTag(style, name);
      if (newStyle != null) {
        styleStack.add(style);
        styleTagStack.add(name);
        style = newStyle;
      }

      if (name == 'br') {
        newline();
        continue;
      }
      if (_blockTags.contains(name)) {
        newline();
        if (name == 'li') {
          flushText();
          atoms.add(TextAtom('• ', style));
        }
        continue;
      }
      if (name == 'img' || name == 'image') {
        flushText();
        final src = _attrOf(tagContent, 'src') ?? _attrOf(tagContent, 'href');
        if (src != null && src.trim().isNotEmpty) {
          final id = resolveEpubHref(chapterHref, src.trim());
          if (id.isNotEmpty) {
            atoms.add(ImgAtom(id));
          }
        }
      }
    }
    flushText();
    return _normalize(atoms);
  }

  /// 标签 → 内联样式（null = 非样式标签）。
  TextStyle? _applyTag(TextStyle style, String tag) {
    switch (tag) {
      case 'b':
      case 'strong':
        return style.copyWith(fontWeight: FontWeight.bold);
      case 'i':
      case 'em':
        return style.copyWith(fontStyle: FontStyle.italic);
      case 'u':
      case 'ins':
        return style.copyWith(decoration: TextDecoration.underline);
      case 's':
      case 'del':
      case 'strike':
        return style.copyWith(decoration: TextDecoration.lineThrough);
      case 'sup':
      case 'sub':
        return style.copyWith(fontSize: (style.fontSize ?? 16) * 0.75);
      case 'code':
      case 'tt':
      case 'kbd':
        return style.copyWith(fontFamily: 'monospace');
      case 'a':
        return style.copyWith(decoration: TextDecoration.underline);
      case 'blockquote':
        return style.copyWith(color: style.color?.withValues(alpha: 0.7));
      default:
        final scale = _headingScale[tag];
        if (scale != null) {
          return style.copyWith(
            fontSize: (style.fontSize ?? 16) * scale,
            fontWeight: FontWeight.bold,
          );
        }
        return null;
    }
  }

  static String? _attrOf(String tagContent, String attr) {
    final m = RegExp('$attr\\s*=\\s*"([^"]*)"').firstMatch(tagContent) ??
        RegExp("$attr\\s*=\\s*'([^']*)'").firstMatch(tagContent);
    return m?.group(1);
  }

  /// HTML 实体解码（&amp; 必须最后处理，避免二次解码）。
  static String _decodeEntities(String s) {
    if (!s.contains('&')) return s;
    return s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAllMapped(
          RegExp(r'&#x([0-9a-fA-F]+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
        )
        .replaceAllMapped(
          RegExp(r'&#(\d+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!)),
        )
        .replaceAll('&amp;', '&');
  }

  /// 后处理：合并相邻同样式文本、规范化换行、去首尾空白。
  static List<RichAtom> _normalize(List<RichAtom> atoms) {
    final merged = <RichAtom>[];
    for (final a in atoms) {
      if (a is TextAtom && merged.isNotEmpty && merged.last is TextAtom) {
        final last = merged.last as TextAtom;
        if (last.style == a.style) {
          merged[merged.length - 1] =
              TextAtom(last.text + a.text, last.style);
          continue;
        }
      }
      merged.add(a);
    }
    final out = <RichAtom>[
      for (final a in merged)
        if (a is TextAtom)
          TextAtom(
            a.text
                .replaceAll(RegExp(r'[ \t]*\n[ \t]*'), '\n')
                .replaceAll(RegExp(r'\n{3,}'), '\n\n'),
            a.style,
          )
        else
          a,
    ];
    bool blank(RichAtom a) => a is TextAtom && a.text.trim().isEmpty;
    while (out.isNotEmpty && blank(out.first)) {
      out.removeAt(0);
    }
    while (out.isNotEmpty && blank(out.last)) {
      out.removeLast();
    }
    if (out.isNotEmpty && out.first is TextAtom) {
      final f = out.first as TextAtom;
      out[0] = TextAtom(f.text.trimLeft(), f.style);
    }
    if (out.isNotEmpty && out.last is TextAtom) {
      final l = out.last as TextAtom;
      out[out.length - 1] = TextAtom(l.text.trimRight(), l.style);
    }
    return out;
  }
}
