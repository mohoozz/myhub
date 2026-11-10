// S4 预研：本地 HTTP 测试服务
//
// 为什么不用外网页面：
//   浏览器探针要判定「标签保活」「下载接管」「UA 覆盖」等行为，任何一项都依赖
//   页面可控。外网站点随时改版、需要网络、且无法让服务端回显收到的 User-Agent。
//   故用 QTcpServer 起一个只监听 127.0.0.1 的最小 HTTP 服务，页面与响应完全确定。
//
// 提供的路由：
//   /tab1 /tab2 /tab3  三个不同底色的页面，各带一个 100ms 自增的 JS 计数器
//                      （用于判定「隐藏后页面是否仍在运行」）
//   /ua                把 navigator.userAgent 写进 document.title
//   /fav.png           16x16 PNG 图标（用于 favicon 判定）
//   /download          带 Content-Disposition: attachment 的二进制文件（下载接管）

#pragma once

#include <QByteArray>
#include <QHash>
#include <QImage>
#include <QObject>
#include <QString>
#include <QTcpServer>
#include <QTcpSocket>

class TestServer : public QTcpServer
{
    Q_OBJECT

public:
    explicit TestServer(QObject *parent = nullptr);

    // 下载文件的确定内容：128 KiB，第 i 字节 = (i*31+7) & 0xFF
    static QByteArray makeDownloadBody();

    // 服务端实际收到的 User-Agent（按路径记录最后一次）
    QString userAgentFor(const QString &path) const { return m_ua.value(path); }
    int requestCount(const QString &path) const { return m_reqs.value(path); }

private:
    void onNewConnection();
    void respond(QTcpSocket *sock, const QByteArray &request);

    QByteArray m_favicon;                 // 启动时生成一次
    QHash<QString, QString> m_ua;
    QHash<QString, int> m_reqs;
};
