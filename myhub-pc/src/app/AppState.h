#pragma once

#include <QObject>
#include <QQmlEngine>

class QJSEngine;

namespace myhub {

/**
 * 启动编排（§2.2.4 启动流程）。
 *
 * 顺序：日志与崩溃捕获 → 打开/迁移数据库 → 预载 Store → 连接源探测 → 缓存兜底。
 *
 * 纪律：**依赖数据库的 Store 必须等数据库就绪后再装载**，
 * 否则冷启动读到空列表（§8.3 PC-403 的已知坑）。
 */
class AppState : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(Phase phase READ phase NOTIFY phaseChanged)
    Q_PROPERTY(bool ready READ isReady NOTIFY phaseChanged)
    Q_PROPERTY(QString statusText READ statusText NOTIFY phaseChanged)
    Q_PROPERTY(QString version READ version CONSTANT)
    Q_PROPERTY(bool hasCrashReport READ hasCrashReport NOTIFY phaseChanged)

public:
    enum Phase
    {
        Starting = 0,
        OpeningDatabase,
        LoadingStores,
        ProbingConnections,
        Ready,
        Failed,
    };
    Q_ENUM(Phase)

    /**
     * 进程内唯一实例。
     *
     * **必须**由 main() 与 QML 共用同一个对象：`QML_SINGLETON` 若不给 create()，
     * 引擎会用自己的默认构造再 new 一个，于是 main() 里 bootstrap 的那个
     * phase 一路 Ready，QML 看到的那个却永远停在 Starting ——
     * 表现为启动 Loading 永不消失（§14.4 不得长白屏）。
     */
    static AppState &instance();

    /**
     * QML 单例工厂：交回 main() 引导的那个实例。
     *
     * 注意：构造函数**不能**有默认实参、也不能是默认可构造的。Qt 的
     * `singletonConstructionMode()` 先看 `is_default_constructible`，
     * 命中就直接 `new T` 而**绕过** create()（见 qqmlprivate.h），
     * 于是 QML 会拿到另一个实例、phase 永远停在 Starting —— 启动 Loading
     * 永不消失（§14.4 不得长白屏）。
     */
    static AppState *create(QQmlEngine *engine, QJSEngine *scriptEngine);

    explicit AppState(QObject *parent);

    /// 由 main() 在 QML 引擎装载前调用（同步完成日志/数据库），
    /// 其余耗时步骤在事件循环启动后异步进行
    void bootstrap();

    Phase phase() const { return m_phase; }
    bool isReady() const { return m_phase == Ready; }
    QString statusText() const;
    QString version() const;
    bool hasCrashReport() const { return m_hasCrashReport; }

    /// 设置 → 关于：读取 / 清空崩溃报告
    Q_INVOKABLE QString crashReport() const;
    Q_INVOKABLE void clearCrashReport();

    /// 设置 → 关于：日志尾部
    Q_INVOKABLE QStringList logTail(int lines = 300) const;
    Q_INVOKABLE void clearLogs();

    /// 退出前的收尾（持久化 + 关闭数据库）
    Q_INVOKABLE void shutdown();

signals:
    void phaseChanged();
    void bootFailed(const QString &reason);

private:
    void setPhase(Phase p);
    void continueBoot();

    Phase m_phase = Starting;
    bool m_hasCrashReport = false;
};

} // namespace myhub
