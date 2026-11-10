#include "CredentialStore.h"
#include "../utils/AppLogger.h"

#ifdef Q_OS_WIN
#include <windows.h>
#include <wincred.h>
#endif

#include <QCoreApplication>

namespace myhub {

namespace {

/// 凭据目标名加前缀，避免与其它应用冲突
QString targetName(const QString &key)
{
    return QStringLiteral("MyHub:") + key;
}

} // namespace

#ifdef Q_OS_WIN

bool CredentialStore::save(const QString &key, const QString &password)
{
    const QString target = targetName(key);
    const QByteArray blob = password.toUtf8();

    CREDENTIALW cred = {};
    cred.Type = CRED_TYPE_GENERIC;
    // CREDENTIALW 的字段是 non-const 指针，但 CredWriteW 只读不写，
    // 这里用 const_cast 是 Win32 API 的既定契约，不是真的要去改 const 对象
    cred.TargetName = const_cast<LPWSTR>(reinterpret_cast<LPCWSTR>(target.utf16())); // NOLINT
    cred.CredentialBlobSize = static_cast<DWORD>(blob.size());
    cred.CredentialBlob = reinterpret_cast<LPBYTE>(const_cast<char *>(blob.constData())); // NOLINT
    // LOCAL_MACHINE：仅本机可用，不随漫游配置文件同步，符合「数据全本地」原则
    cred.Persist = CRED_PERSIST_LOCAL_MACHINE;

    if (!CredWriteW(&cred, 0)) {
        MH_WARN(App,
                QStringLiteral("CredWrite failed for %1 (error %2)").arg(key).arg(GetLastError()));
        return false;
    }
    return true;
}

QString CredentialStore::load(const QString &key)
{
    const QString target = targetName(key);
    PCREDENTIALW cred = nullptr;

    if (!CredReadW(reinterpret_cast<LPCWSTR>(target.utf16()), CRED_TYPE_GENERIC, 0, &cred)) {
        return {};
    }

    QString result;
    if (cred->CredentialBlob && cred->CredentialBlobSize > 0) {
        result = QString::fromUtf8(reinterpret_cast<const char *>(cred->CredentialBlob),
                                   static_cast<int>(cred->CredentialBlobSize));
    }
    CredFree(cred);
    return result;
}

bool CredentialStore::remove(const QString &key)
{
    const QString target = targetName(key);
    if (!CredDeleteW(reinterpret_cast<LPCWSTR>(target.utf16()), CRED_TYPE_GENERIC, 0)) {
        const DWORD err = GetLastError();
        if (err != ERROR_NOT_FOUND)
            MH_WARN(App, QStringLiteral("CredDelete failed for %1 (error %2)").arg(key).arg(err));
        return false;
    }
    return true;
}

bool CredentialStore::contains(const QString &key)
{
    const QString target = targetName(key);
    PCREDENTIALW cred = nullptr;
    if (!CredReadW(reinterpret_cast<LPCWSTR>(target.utf16()), CRED_TYPE_GENERIC, 0, &cred)) {
        return false;
    }
    CredFree(cred);
    return true;
}

#elif defined(Q_OS_MACOS)

// macOS 实现见 src/platform/macos/Keychain.mm（Security.framework）
// 这里仅作声明占位，实际符号由 .mm 提供。

#else

// 其它平台：未实现，明确失败而非静默成功
bool CredentialStore::save(const QString &, const QString &)
{
    return false;
}
QString CredentialStore::load(const QString &)
{
    return {};
}
bool CredentialStore::remove(const QString &)
{
    return false;
}
bool CredentialStore::contains(const QString &)
{
    return false;
}

#endif

} // namespace myhub
