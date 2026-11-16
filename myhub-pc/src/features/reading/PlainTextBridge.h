#pragma once

#include <QAbstractListModel>
#include <QQmlEngine>
#include <QString>
#include <QStringList>

#include <memory>

namespace myhub {

class PlainTextDocument;
class RangeSource;
class StorageAdapter;

/**
 * 纯文本阅读器的 QML 门面（PC-210，第 4 条阅读路由）。
 *
 * 与小说阅读器的分工：
 *   - 小说阅读器（`Novel`）：建索引、分章、记进度，读「书」
 *   - 本文档门面（`Plain`）：不建索引、不落库、不记进度，读「文件」
 *
 * 为什么要有这条路由：txt 打开就走的场景里，绝大多数只是想看几眼（日志、配置、
 * 随手下载的片段）。为它们跑一遍全量分章索引既慢又脏（索引表要清理），
 * 而「需要章节和进度」的读者可以从右键菜单转到小说阅读器。
 *
 * 懒加载模型：每个 row 是一块**整行对齐**的正文（默认 64KB —— 一块要能一次排版完，
 * 太大 QML 的 TextArea 会卡在首帧）。QML 侧用
 * `ListView`，滚到底部由 `canFetchMore` / `fetchMore` 自动续读；
 * `find()` 找不到时会顺着这条路径继续读文件，直到命中或到文件尾（有预算上限）。
 *
 * 与 `PlainTextDocument` 的分界：后者只懂「字节 → 块」，本文档门面持有模型、
 * 查找状态与 QML 属性。
 */
class PlainTextBridge : public QAbstractListModel
{
    Q_OBJECT
    QML_NAMED_ELEMENT(Plain)
    QML_SINGLETON

    /// 有书在手（含加载中）—— QML 据此决定是否显示阅读器
    Q_PROPERTY(bool active READ active NOTIFY activeChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(QString title READ title NOTIFY bookChanged)
    /// 连接源与路径：QML 转到小说阅读器时要原样递过去
    Q_PROPERTY(QString connectionId READ connectionId NOTIFY bookChanged)
    Q_PROPERTY(QString path READ path NOTIFY bookChanged)
    Q_PROPERTY(QString encodingName READ encodingName NOTIFY bookChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY errorTextChanged)
    Q_PROPERTY(qint64 fileSize READ fileSize NOTIFY bookChanged)
    Q_PROPERTY(qint64 loadedBytes READ loadedBytes NOTIFY progressChanged)
    Q_PROPERTY(double percent READ percent NOTIFY progressChanged)
    Q_PROPERTY(bool atEnd READ atEnd NOTIFY progressChanged)
    Q_PROPERTY(bool searching READ searching NOTIFY searchingChanged)
    Q_PROPERTY(QString findText READ findText NOTIFY findTextChanged)
    /// 当前命中所在的 row（-1 = 没有命中）；QML 用它定位与高亮
    Q_PROPERTY(int hitRow READ hitRow NOTIFY hitRowChanged)

public:
    enum Roles
    {
        TextRole = Qt::UserRole + 1,
    };
    Q_ENUM(Roles)

    static PlainTextBridge *instance();
    static PlainTextBridge *create(QQmlEngine *, QJSEngine *);

    explicit PlainTextBridge(QObject *parent = nullptr);
    ~PlainTextBridge() override;

    // ---- QAbstractListModel ----
    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;
    bool canFetchMore(const QModelIndex &parent) const override;
    void fetchMore(const QModelIndex &parent) override;

    bool active() const { return !m_path.isEmpty(); }
    bool loading() const { return m_loading; }
    QString title() const { return m_title; }
    QString connectionId() const { return m_connectionId; }
    QString path() const { return m_path; }
    QString encodingName() const { return m_encodingName; }
    QString errorText() const { return m_errorText; }
    qint64 fileSize() const { return m_fileSize; }
    qint64 loadedBytes() const { return m_loadedBytes; }
    double percent() const;
    bool atEnd() const { return m_atEnd; }
    bool searching() const { return m_searching; }
    QString findText() const { return m_needle; }
    int hitRow() const { return m_hitRow; }

    /// 打开一个文本文件（连接源 + 路径）。会先关掉上一份
    Q_INVOKABLE void open(const QString &connectionId, const QString &path);
    Q_INVOKABLE void close();
    /// QML 在「滚到底但还没到文件尾」时催一批（fetchMore 之外的显式入口）
    Q_INVOKABLE void loadMore();

    /// 从头查找（找不到就继续往后读文件，直到命中或用完预算）
    Q_INVOKABLE void find(const QString &text);
    /// 从上一处命中之后继续找
    Q_INVOKABLE void findNext();
    Q_INVOKABLE void clearFind();

    /**
     * 命中段的富文本（带高亮底色），非命中 row 返回空串。
     * QML 侧：空串就用纯文本，非空就切 `RichText`。
     */
    Q_INVOKABLE QString highlighted(int row) const;

signals:
    void activeChanged();
    void loadingChanged();
    void bookChanged();
    void errorTextChanged();
    void progressChanged();
    void searchingChanged();
    void findTextChanged();
    void hitRowChanged();
    /// 找到一处命中（QML 滚动到该 row）
    void found(int row);
    /// 一次查找结束；found = 是否命中
    void findFinished(bool found);

private:
    void reset();
    void requestChunk();
    void onChunkReady(const QString &text, const QString &errorMessage);
    void appendChunk(const QString &text);
    void setErrorText(const QString &text);
    void setLoading(bool loading);
    /// 在已加载的块里找，返回命中的 row 或 -1
    int locateLoaded(int fromRow) const;
    void setHit(int row);
    void startSearch();
    void finishSearch(bool found);

    /// 声明顺序即析构逆序：source 必须先于 doc 存活（doc 只持裸指针）
    std::unique_ptr<RangeSource> m_sourceOwner;
    std::unique_ptr<PlainTextDocument> m_doc;

    /// 每次 open/close 自增：异步回调靠它判断「结果是不是上一本书的」
    int m_serial = 0;

    QString m_connectionId;
    QString m_path;
    QString m_title;
    QString m_encodingName;
    QString m_errorText;
    qint64 m_fileSize = 0;
    qint64 m_loadedBytes = 0;
    bool m_loading = false;
    bool m_atEnd = false;

    QStringList m_chunks;
    bool m_inflight = false;
    /// 还愿意自动续读几块（QML 滚到底时给 2，批量预读用）
    int m_fetchAhead = 0;

    QString m_needle;
    bool m_searching = false;
    int m_hitRow = -1;
    /// 一次查找最多再读多少块（64KB * 64 ≈ 4MB），防止一次点查找就读完整个网盘
    int m_searchBudget = 0;
};

} // namespace myhub
