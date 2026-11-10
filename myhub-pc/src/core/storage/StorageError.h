#pragma once

#include <QString>

namespace myhub {

/**
 * 统一存储错误（与 iOS 端 StorageError 同构，见需求文档 §4.4）。
 *
 * InvalidResponse / Offline 两类对「网络自愈与内外网路由」（PC-708）至关重要：
 * 只有连接类/网关类错误才允许触发地址回退，业务错误（404/409/鉴权）不得触发。
 */
class StorageError
{
public:
    enum Kind
    {
        None = 0,
        InvalidPath,
        InvalidConfig,
        NotFound,
        Http, ///< 带 HTTP 状态码的业务错误
        AuthenticationFailed,
        UnsupportedProtocol,
        InvalidResponse, ///< 响应无法解析（如 PROPFIND 拿不到 multistatus）
        Offline,         ///< 无网络 / 连不上 / DNS 失败 / 超时
        Cancelled,
        Underlying, ///< 其它底层错误
    };

    StorageError() = default;
    StorageError(Kind kind, QString message, int httpStatus = 0);

    Kind kind() const { return m_kind; }
    QString message() const { return m_message; }
    int httpStatus() const { return m_httpStatus; }

    bool isNull() const { return m_kind == None; }

    /**
     * 是否属于「连接类 / 网关类」错误。
     * 仅此类错误允许触发内外网地址回退或清除锁定（PC-708 失败自愈）。
     * 404 / 409 / 鉴权失败等业务错误返回 false。
     */
    bool isRouteRecoverable() const;

    /// 是否为可退避重试的瞬时错误（HTTP 423/409/429/5xx、超时、中断）——用于删除占用重试
    bool isTransient() const;

    /// 面向用户的中文描述（含具体原因，满足「失败提示携带具体原因」要求）
    QString userMessage() const;

    static StorageError fromHttpStatus(int status, const QString &context = QString());

private:
    Kind m_kind = None;
    QString m_message;
    int m_httpStatus = 0;
};

} // namespace myhub
