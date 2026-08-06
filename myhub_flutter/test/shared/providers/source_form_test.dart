import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:myhub_flutter/core/models/source.dart';
import 'package:myhub_flutter/shared/providers/source_provider.dart';

void main() {
  group('SourceFormData.toPayload', () {
    test('本地路径源', () {
      const form = SourceFormData(
        name: '本地媒体',
        type: SourceType.local,
        mountPoint: r'D:\Media',
      );
      final payload = form.toPayload();
      expect(payload['type'], 'local');
      expect(payload['mount_point'], r'D:\Media');
      expect(payload['config_json'], '');
      expect(payload['enabled'], isTrue);
    });

    test('WebDAV 路径源 config_json 组装', () {
      const form = SourceFormData(
        name: 'NAS',
        type: SourceType.webdav,
        mountPoint: '/media',
        webdavUrl: 'https://nas.example.com:5006',
        webdavLanUrl: 'http://192.168.1.10:5006',
        webdavUsername: 'user',
        webdavPassword: 'pass',
      );
      final payload = form.toPayload();
      expect(payload['type'], 'webdav');
      expect(payload['mount_point'], '/media');
      final cfg = jsonDecode(payload['config_json'] as String);
      expect(cfg['url'], 'https://nas.example.com:5006');
      expect(cfg['lan_url'], 'http://192.168.1.10:5006');
      expect(cfg['username'], 'user');
      expect(cfg['password'], 'pass');
    });

    test('WebDAV 内网地址为空时不写入 lan_url', () {
      const form = SourceFormData(
        name: 'NAS',
        type: SourceType.webdav,
        webdavUrl: 'https://nas.example.com:5006',
      );
      final cfg =
          jsonDecode(form.toPayload()['config_json'] as String)
              as Map<String, dynamic>;
      expect(cfg.containsKey('lan_url'), isFalse);
    });

    test('编辑停用状态保留', () {
      const form = SourceFormData(
        name: 'x',
        type: SourceType.local,
        mountPoint: '/m',
        enabled: false,
      );
      expect(form.toPayload()['enabled'], isFalse);
    });
  });

  group('Source 模型枚举', () {
    test('枚举名与后端 type 值一致', () {
      expect(SourceType.local.name, 'local');
      expect(SourceType.webdav.name, 'webdav');
      expect(SourceType.openlist.name, 'openlist');
    });
  });
}
