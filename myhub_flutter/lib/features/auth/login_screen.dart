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
    final saved = await showDialog<({String wan, String lan})>(
      context: context,
      // 对话框作为独立 StatefulWidget 持有自己的 TextEditingController：
      // 若在 showDialog 返回后立刻 dispose 局部控制器，退场动画期间的
      // TextField 仍会引用已释放的 controller，触发
      // "TextEditingController used after being disposed"。
      builder: (_) => _ServerConfigDialog(
        wanUrl: config.wanUrl,
        lanUrl: config.lanUrl,
      ),
    );
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

/// 服务器地址配置对话框：自身持有 [TextEditingController]，生命周期与
/// 对话框路由绑定（State 存活到退场动画结束），避免退场期间使用已
/// dispose 的 controller。
class _ServerConfigDialog extends StatefulWidget {
  const _ServerConfigDialog({required this.wanUrl, required this.lanUrl});

  final String wanUrl;
  final String lanUrl;

  @override
  State<_ServerConfigDialog> createState() => _ServerConfigDialogState();
}

class _ServerConfigDialogState extends State<_ServerConfigDialog> {
  late final TextEditingController _wanController = TextEditingController(
    text: widget.wanUrl,
  );
  late final TextEditingController _lanController = TextEditingController(
    text: widget.lanUrl,
  );

  @override
  void dispose() {
    _wanController.dispose();
    _lanController.dispose();
    super.dispose();
  }

  void _save() {
    Navigator.of(context).pop(
      (wan: _wanController.text, lan: _lanController.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
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
            controller: _wanController,
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
            controller: _lanController,
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
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
