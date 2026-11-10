#pragma once

#include <QString>

namespace myhub {

/**
 * 内外网判定启发式（PC-101）。
 *
 * 「测试成功提示区分内网可达 / 外网可达」要求能判断一个地址是否指向内网：
 *   - 私有 IP 段（10/8、172.16/12、192.168/16、127/8、169.254/16）
 *   - localhost
 *   - .local / .lan 域名后缀
 *   - 无点主机名（单段主机名，如 "nas"）
 */
class NetworkHeuristics
{
public:
    enum Scope
    {
        Unknown = 0,
        Internal, ///< 内网可达
        External, ///< 外网可达
    };

    /// 判断 URL 或主机名是否指向内网
    static bool isPrivateHost(const QString &hostOrUrl);

    /// 由 URL 推断作用域
    static Scope scopeOf(const QString &url);

    static QString scopeName(Scope s);

    /// 面向用户的提示文案（「内网可达」/「外网可达」）
    static QString scopeDisplayText(Scope s);

    /// 从 URL 中取主机名（容错：允许不带 scheme）
    static QString hostOf(const QString &url);
};

} // namespace myhub
