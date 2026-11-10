#pragma once

#include <QString>

namespace myhub {

/**
 * 系统凭据库（PC-002 / §4.1）。
 *
 * Windows: Credential Manager（wincred.h）
 * macOS:   Keychain（Security.framework，.mm 实现）
 *
 * key 约定 `conn.<id>`，与 iOS 端一致。
 * 纪律：凭据**持久保存，不因会话过期被清空**，仅删除连接源时才清除（§2.4 PC-101）。
 */
class CredentialStore
{
public:
    /// 保存密码；返回是否成功
    static bool save(const QString &key, const QString &password);

    /// 读取密码；不存在返回空字符串
    static QString load(const QString &key);

    /// 删除凭据（仅在删除连接源时调用）
    static bool remove(const QString &key);

    static bool contains(const QString &key);

    /// 连接源对应的 key
    static QString connectionKey(const QString &connectionId)
    {
        return QStringLiteral("conn.") + connectionId;
    }
};

} // namespace myhub
