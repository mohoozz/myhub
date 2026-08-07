/// Compile-time environment configuration.
///
/// Override values with `--dart-define`, e.g.
/// `flutter run --dart-define=API_BASE_URL=https://api.example.com`.
abstract final class Env {
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://192.168.0.103:8080',
  );
}
