import 'package:intl/intl.dart';

/// 字节数格式化：B/KB/MB/GB。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024.0;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

/// 修改时间格式化：yyyy-MM-dd HH:mm。
String formatModTime(DateTime? time) {
  if (time == null) return '-';
  return DateFormat('yyyy-MM-dd HH:mm').format(time.toLocal());
}

/// 相对时间格式化：刚刚 / n 分钟前 / n 小时前 / n 天前 / yyyy-MM-dd。
String formatRelativeTime(DateTime? time) {
  if (time == null) return '-';
  final local = time.toLocal();
  final diff = DateTime.now().difference(local);
  if (diff.isNegative || diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  return DateFormat('yyyy-MM-dd').format(local);
}

/// 播放时长格式化：mm:ss（超过 1 小时为 h:mm:ss）。
String formatPlaybackTime(Duration d) {
  final total = d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
