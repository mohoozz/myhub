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
