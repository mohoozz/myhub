// 浏览页状态角标（§3.1）：进度摘要 → 模型角色
//
// 覆盖两件事：
//   · 目录加载后，文件行能读到 percent / finished，目录行必须是「无进度」
//   · 播放/阅读写入进度后，行状态要就地刷新（不必重进目录）
//
// 用真实 sqlite（临时目录，走与生产相同的迁移路径）+ 本地适配器，不依赖 UI。

#include "core/database/AppDatabase.h"
#include "core/history/ProgressRepository.h"
#include "core/preferences/AppSettings.h"
#include "core/storage/StorageAdapterFactory.h"
#include "core/utils/AppPaths.h"
#include "features/browse/BrowseDirectoryModel.h"
#include "features/connections/ConnectionStore.h"

#include <QDir>
#include <QFile>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QtTest>

using namespace myhub;

namespace {

ProgressRecord videoRecord(const QString &connectionId, const QString &path, double percent)
{
    ProgressRecord record;
    record.connectionId = connectionId;
    record.path = path;
    record.mediaType = QStringLiteral("video");
    record.title = QStringLiteral("ep01");
    record.progress.insert(QStringLiteral("positionMs"), qint64(percent * 120000));
    record.progress.insert(QStringLiteral("durationMs"), qint64(120000));
    record.percent = percent;
    return record;
}

} // namespace

class TestBrowseStatus : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void init();
    void cleanup();

    void progressRolesFollowRepository();
    void progressRolesUpdateLive();

private:
    QTemporaryDir m_dbDir;
    QTemporaryDir m_root;
    QString m_connectionId = QStringLiteral("conn-status-test");
};

void TestBrowseStatus::initTestCase()
{
    QCoreApplication::setApplicationName(
        QStringLiteral("MyHubBrowseStatusTest-%1").arg(QCoreApplication::applicationPid()));
    QStandardPaths::setTestModeEnabled(true);
    AppPaths::initializeAll();
    AppSettings::instance().initialize();

    QVERIFY(m_dbDir.isValid());
    QVERIFY(AppDatabase::instance().open(m_dbDir.filePath(QStringLiteral("myhub.sqlite"))));

    // 目录内容：一个视频 + 一个子目录（目录不该出现状态角标）
    QVERIFY(m_root.isValid());
    QFile video(m_root.filePath(QStringLiteral("ep01.mkv")));
    QVERIFY(video.open(QIODevice::WriteOnly));
    video.write("x");
    video.close();
    QVERIFY(QDir(m_root.path()).mkdir(QStringLiteral("Season 2")));

    ConnectionRecord record;
    record.id = m_connectionId;
    record.name = QStringLiteral("临时目录");
    record.type = ConnectionType::Local;
    record.config.insert(QStringLiteral("path"), m_root.path());
    QVERIFY(ConnectionStore::instance().upsert(record));
}

void TestBrowseStatus::init()
{
    QVERIFY(AppDatabase::instance().execute(QStringLiteral("DELETE FROM readingProgress")));
}

void TestBrowseStatus::cleanup()
{
    QVERIFY(AppDatabase::instance().execute(QStringLiteral("DELETE FROM readingProgress")));
}

void TestBrowseStatus::progressRolesFollowRepository()
{
    QVERIFY(ProgressRepository::instance().upsert(
        videoRecord(m_connectionId, QStringLiteral("/ep01.mkv"), 0.25)));

    BrowseDirectoryModel model;
    model.setConnectionId(m_connectionId);
    QTRY_VERIFY2_WITH_TIMEOUT(
        model.state() == BrowseDirectoryModel::Ready,
        qPrintable(
            QStringLiteral("state=%1 error=%2").arg(int(model.state())).arg(model.errorText())),
        5000);
    QTRY_VERIFY_WITH_TIMEOUT(model.rowCount() >= 2, 5000);

    const int videoRow = model.indexOfPath(QStringLiteral("/ep01.mkv"));
    QVERIFY(videoRow >= 0);
    QCOMPARE(
        model.data(model.index(videoRow, 0), BrowseDirectoryModel::ProgressPercentRole).toDouble(),
        0.25);
    QCOMPARE(
        model.data(model.index(videoRow, 0), BrowseDirectoryModel::ProgressFinishedRole).toBool(),
        false);

    const int dirRow = model.indexOfPath(QStringLiteral("/Season 2"));
    QVERIFY(dirRow >= 0);
    // 目录不显示状态指示（§3.1）
    QCOMPARE(
        model.data(model.index(dirRow, 0), BrowseDirectoryModel::ProgressPercentRole).toDouble(),
        -1.0);
    QCOMPARE(
        model.data(model.index(dirRow, 0), BrowseDirectoryModel::ProgressFinishedRole).toBool(),
        false);

    // 没有记录的文件同样是 -1（不画环）
    QVERIFY(AppDatabase::instance().execute(QStringLiteral("DELETE FROM readingProgress")));
}

void TestBrowseStatus::progressRolesUpdateLive()
{
    BrowseDirectoryModel model;
    model.setConnectionId(m_connectionId);
    QTRY_VERIFY_WITH_TIMEOUT(model.state() == BrowseDirectoryModel::Ready, 5000);
    const int row = model.indexOfPath(QStringLiteral("/ep01.mkv"));
    QVERIFY(row >= 0);

    // 起播前：没有角标
    QCOMPARE(model.data(model.index(row, 0), BrowseDirectoryModel::ProgressPercentRole).toDouble(),
             -1.0);

    // 播放器写入进度（浏览页正开着）→ 行状态必须就地刷新
    QVERIFY(ProgressRepository::instance().upsert(
        videoRecord(m_connectionId, QStringLiteral("/ep01.mkv"), 0.6)));
    QCOMPARE(model.data(model.index(row, 0), BrowseDirectoryModel::ProgressPercentRole).toDouble(),
             0.6);

    ProgressRecord answered = videoRecord(m_connectionId, QStringLiteral("/ep01.mkv"), 1.0);
    answered.finished = true;
    QVERIFY(ProgressRepository::instance().upsert(answered));
    QCOMPARE(model.data(model.index(row, 0), BrowseDirectoryModel::ProgressFinishedRole).toBool(),
             true);

    // 记录被删（如「清除记录」）→ 角标收回
    QVERIFY(ProgressRepository::instance().remove(m_connectionId, QStringLiteral("/ep01.mkv")));
    QCOMPARE(model.data(model.index(row, 0), BrowseDirectoryModel::ProgressPercentRole).toDouble(),
             -1.0);
}

QTEST_GUILESS_MAIN(TestBrowseStatus)
#include "tst_browsestatus.moc"
