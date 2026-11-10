#include <QtTest>

#include "core/storage/StorageError.h"

using namespace myhub;

/**
 * 验证 PC-708 的核心纪律：
 * 只有连接类 / 网关类错误才允许触发路由回退，
 * 404 / 409 / 鉴权等业务错误**不得**触发。
 */
class TestStorageError : public QObject
{
    Q_OBJECT
private slots:
    void routeRecoverable_data();
    void routeRecoverable();
    void transient_data();
    void transient();
    void fromHttpStatus();
    void userMessageMentionsCause();
};

void TestStorageError::routeRecoverable_data()
{
    QTest::addColumn<StorageError>("error");
    QTest::addColumn<bool>("recoverable");

    QTest::newRow("offline") << StorageError(StorageError::Offline, "timeout") << true;
    QTest::newRow("invalid response")
        << StorageError(StorageError::InvalidResponse, "no multistatus") << true;
    QTest::newRow("http 500") << StorageError(StorageError::Http, "server error", 500) << true;
    QTest::newRow("http 502") << StorageError(StorageError::Http, "bad gateway", 502) << true;

    // 以下均为业务错误，切换地址无济于事
    QTest::newRow("not found") << StorageError(StorageError::NotFound, "missing") << false;
    QTest::newRow("http 404") << StorageError(StorageError::Http, "not found", 404) << false;
    QTest::newRow("http 409") << StorageError(StorageError::Http, "conflict", 409) << false;
    QTest::newRow("auth failed") << StorageError(StorageError::AuthenticationFailed, "401")
                                 << false;
    QTest::newRow("invalid config")
        << StorageError(StorageError::InvalidConfig, "empty url") << false;
    QTest::newRow("cancelled") << StorageError(StorageError::Cancelled, "user") << false;
    QTest::newRow("none") << StorageError() << false;
}

void TestStorageError::routeRecoverable()
{
    QFETCH(StorageError, error);
    QFETCH(bool, recoverable);
    QCOMPARE(error.isRouteRecoverable(), recoverable);
}

void TestStorageError::transient_data()
{
    QTest::addColumn<StorageError>("error");
    QTest::addColumn<bool>("transient");

    // 删除占用重试覆盖 423/409/429/5xx
    QTest::newRow("http 423 locked") << StorageError(StorageError::Http, "locked", 423) << true;
    QTest::newRow("http 409") << StorageError(StorageError::Http, "conflict", 409) << true;
    QTest::newRow("http 429") << StorageError(StorageError::Http, "too many", 429) << true;
    QTest::newRow("http 503") << StorageError(StorageError::Http, "unavailable", 503) << true;
    QTest::newRow("offline") << StorageError(StorageError::Offline, "timeout") << true;

    QTest::newRow("http 404") << StorageError(StorageError::Http, "missing", 404) << false;
    QTest::newRow("auth") << StorageError(StorageError::AuthenticationFailed, "") << false;
}

void TestStorageError::transient()
{
    QFETCH(StorageError, error);
    QFETCH(bool, transient);
    QCOMPARE(error.isTransient(), transient);
}

void TestStorageError::fromHttpStatus()
{
    QCOMPARE(StorageError::fromHttpStatus(401).kind(), StorageError::AuthenticationFailed);
    QCOMPARE(StorageError::fromHttpStatus(403).kind(), StorageError::AuthenticationFailed);
    QCOMPARE(StorageError::fromHttpStatus(404).kind(), StorageError::NotFound);
    QCOMPARE(StorageError::fromHttpStatus(500).kind(), StorageError::Http);
    QCOMPARE(StorageError::fromHttpStatus(500).httpStatus(), 500);
}

void TestStorageError::userMessageMentionsCause()
{
    // 「失败提示必须携带具体原因」（§3.3）
    const StorageError locked(StorageError::Http, "locked", 423);
    QVERIFY(locked.userMessage().contains(QStringLiteral("423")));
    QVERIFY(!locked.userMessage().isEmpty());

    QVERIFY(StorageError().userMessage().isEmpty());
}

QTEST_APPLESS_MAIN(TestStorageError)
#include "tst_storageerror.moc"
