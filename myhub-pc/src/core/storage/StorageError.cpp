#include "StorageError.h"

#include <QObject>
#include <utility>

namespace myhub {

StorageError::StorageError(Kind kind, QString message, int httpStatus)
    : m_kind(kind)
    , m_message(std::move(message))
    , m_httpStatus(httpStatus)
{}

bool StorageError::isRouteRecoverable() const
{
    switch (m_kind) {
    case Offline:
    case InvalidResponse:
        return true;
    case Http:
        // 仅网关类 5xx 允许触发回退；4xx 属业务错误，切换地址无济于事
        return m_httpStatus >= 500 && m_httpStatus <= 599;
    case Underlying:
        return true;
    default:
        return false;
    }
}

bool StorageError::isTransient() const
{
    if (m_kind == Offline || m_kind == InvalidResponse)
        return true;
    if (m_kind != Http)
        return false;
    // 423 Locked / 409 Conflict / 429 Too Many Requests / 5xx
    return m_httpStatus == 423 || m_httpStatus == 409 || m_httpStatus == 429
        || (m_httpStatus >= 500 && m_httpStatus <= 599);
}

QString StorageError::userMessage() const
{
    switch (m_kind) {
    case None:
        return QString();
    case InvalidPath:
        return QObject::tr("路径无效");
    case InvalidConfig:
        return QObject::tr("连接配置不完整");
    case NotFound:
        return QObject::tr("文件或目录不存在");
    case Http:
        if (m_httpStatus == 423)
            return QObject::tr("文件被占用（HTTP 423），建议稍后重试");
        if (m_httpStatus == 507)
            return QObject::tr("服务器存储空间不足（HTTP 507）");
        if (m_httpStatus >= 500)
            return QObject::tr("服务器错误（HTTP %1），建议稍后重试").arg(m_httpStatus);
        return QObject::tr("请求失败（HTTP %1）%2")
            .arg(m_httpStatus)
            .arg(m_message.isEmpty() ? QString() : QStringLiteral("：") + m_message);
    case AuthenticationFailed:
        return QObject::tr("账号或密码不正确");
    case UnsupportedProtocol:
        return QObject::tr("暂不支持该协议");
    case InvalidResponse:
        return QObject::tr("服务器返回了无法解析的响应%1")
            .arg(m_message.isEmpty() ? QString() : QStringLiteral("：") + m_message);
    case Offline:
        return QObject::tr("网络不可达%1")
            .arg(m_message.isEmpty() ? QString() : QStringLiteral("：") + m_message);
    case Cancelled:
        return QObject::tr("操作已取消");
    case Underlying:
        break;
    }
    return m_message.isEmpty() ? QObject::tr("未知错误") : m_message;
}

StorageError StorageError::fromHttpStatus(int status, const QString &context)
{
    if (status == 401 || status == 403)
        return StorageError(AuthenticationFailed, context, status);
    if (status == 404)
        return StorageError(NotFound, context, status);
    return StorageError(Http, context, status);
}

} // namespace myhub
