import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/api/api_exception.dart';
import 'package:myhub_flutter/core/settings/server_config_provider.dart';
import 'package:myhub_flutter/features/auth/providers/auth_provider.dart';
import 'package:myhub_flutter/shared/utils/top_snack_bar.dart';

/// Login page: logo title + credentials form.
/// 登录成功后更新全局认证状态，由路由守卫自动跳转。
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _loading = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// 弹出服务器地址配置对话框（外网 + 内网双地址），保存后自动判断内外网。
  Future<void> _configureServer() async {
    final config = ref.read(serverConfigProvider);
    final wanController = TextEditingController(text: config.wanUrl);
    final lanController = TextEditingController(text: config.lanUrl);
    final saved = await showDialog<({String wan, String lan})>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('服务器配置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '请输入服务器主机地址（含协议与端口），外网必填，内网可选：',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: wanController,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '外网地址',
                hintText: 'http://example.com:8080',
                prefixIcon: Icon(LucideIcons.server),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: lanController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '内网地址（可选）',
                hintText: 'http://192.168.1.100:8080',
                prefixIcon: Icon(LucideIcons.home),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(
              (wan: wanController.text, lan: lanController.text),
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    wanController.dispose();
    lanController.dispose();
    if (saved == null || saved.wan.trim().isEmpty) return;
    await ref.read(serverConfigProvider.notifier).setUrls(
      wanUrl: saved.wan,
      lanUrl: saved.lan,
    );
    // 保存后立即自动判断内网/外网
    await ref.read(serverConfigProvider.notifier).autoDetect();
    if (mounted) showTopSnackBar(context, '服务器配置已更新');
  }

  Future<void> _login() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      _showError('请输入用户名和密码');
      return;
    }

    setState(() => _loading = true);
    try {
      await ref.read(authProvider).login(username, password);
      // 无需手动跳转：路由守卫监听到状态变化后自动重定向
    } on ApiException catch (e) {
      _showError(e.message);
    } catch (_) {
      _showError('登录失败，请稍后重试');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    showTopSnackBar(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  LucideIcons.library,
                  size: 56,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 12),
                Text(
                  'myhub',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _usernameController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: '用户名',
                    prefixIcon: Icon(LucideIcons.user),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  onSubmitted: (_) => _login(),
                  decoration: InputDecoration(
                    labelText: '密码',
                    prefixIcon: const Icon(LucideIcons.lock),
                    suffixIcon: IconButton(
                      tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                      icon: Icon(
                        _obscurePassword ? LucideIcons.eye : LucideIcons.eyeOff,
                        size: 18,
                      ),
                      onPressed: () => setState(
                        () => _obscurePassword = !_obscurePassword,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // 服务器地址配置入口：点击修改连接的服务端 IP
                Material(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    onTap: _configureServer,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            LucideIcons.server,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  ref.watch(serverConfigProvider).activeNetwork ==
                                          'lan'
                                      ? '服务器（当前内网）'
                                      : '服务器（当前外网）',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                Text(
                                  ref.watch(apiBaseUrlProvider),
                                  style: theme.textTheme.bodySmall,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          Text(
                            '修改',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _loading ? null : _login,
                  icon: _loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(LucideIcons.logIn),
                  label: Text(_loading ? '登录中…' : '登录'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
