#include <QtTest>

#include "core/storage/WebDAVAdapter.h"

using namespace myhub;

/**
 * PROPFIND 解析单测。
 *
 * 重点验证 iOS 实战经验中的关键纪律：
 * **异常响应严禁被当作「空目录」**（PC-708 / §14.9）。
 */
class TestWebDAVParse : public QObject
{
    Q_OBJECT
private slots:
    void parsesNormalListing();
    void skipsSelfEntry();
    void rejectsHtmlErrorPage();
    void rejectsEmptyBody();
    void rejectsTruncatedXml();
    void acceptsTrulyEmptyDirectory();
    void stripsRootPrefix();
    void decodesPercentEncodedNames();
};

void TestWebDAVParse::parsesNormalListing()
{
    const QByteArray xml = R"(<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/movies/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/movies/a.mkv</D:href>
    <D:propstat><D:prop>
      <D:resourcetype/>
      <D:getcontentlength>1234</D:getcontentlength>
    </D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/movies/sub/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
</D:multistatus>)";

    const ListResult r = WebDAVAdapter::parsePropfind(xml, "/movies", "/dav");
    QVERIFY(r.ok());
    QCOMPARE(r.value.size(), 2); // 自身条目被跳过

    QCOMPARE(r.value.at(0).name, QStringLiteral("a.mkv"));
    QCOMPARE(r.value.at(0).path, QStringLiteral("/movies/a.mkv"));
    QCOMPARE(r.value.at(0).isDir, false);
    QCOMPARE(r.value.at(0).size, 1234);
    QCOMPARE(r.value.at(0).ext, QStringLiteral("mkv"));

    QCOMPARE(r.value.at(1).name, QStringLiteral("sub"));
    QCOMPARE(r.value.at(1).isDir, true);
}

void TestWebDAVParse::skipsSelfEntry()
{
    const QByteArray xml = R"(<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/movies/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
</D:multistatus>)";

    const ListResult r = WebDAVAdapter::parsePropfind(xml, "/movies", QString());
    QVERIFY(r.ok());
    QVERIFY(r.value.isEmpty());
}

void TestWebDAVParse::rejectsHtmlErrorPage()
{
    // 最典型的坑：反代返回 HTML 错误页，若当成空目录会把用户文件「弄丢」
    const QByteArray html = "<!DOCTYPE html><html><head><title>502 Bad Gateway</title></head>"
                            "<body><h1>502 Bad Gateway</h1></body></html>";

    const ListResult r = WebDAVAdapter::parsePropfind(html, "/movies", QString());
    QVERIFY(!r.ok());
    QCOMPARE(r.error.kind(), StorageError::InvalidResponse);
    QVERIFY(r.value.isEmpty());
}

void TestWebDAVParse::rejectsEmptyBody()
{
    const ListResult r = WebDAVAdapter::parsePropfind(QByteArray(), "/movies", QString());
    QVERIFY(!r.ok());
    QCOMPARE(r.error.kind(), StorageError::InvalidResponse);
}

void TestWebDAVParse::rejectsTruncatedXml()
{
    const QByteArray xml = R"(<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/movies/a.mkv</D:href>)";

    const ListResult r = WebDAVAdapter::parsePropfind(xml, "/movies", QString());
    QVERIFY(!r.ok());
    QCOMPARE(r.error.kind(), StorageError::InvalidResponse);
}

void TestWebDAVParse::acceptsTrulyEmptyDirectory()
{
    // 合法的空目录：只有自身条目，必须成功返回空列表（而非报错）
    const QByteArray xml = R"(<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/empty/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
</D:multistatus>)";

    const ListResult r = WebDAVAdapter::parsePropfind(xml, "/empty", QString());
    QVERIFY(r.ok());
    QVERIFY(r.value.isEmpty());
}

void TestWebDAVParse::stripsRootPrefix()
{
    const QByteArray xml = R"(<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/remote.php/dav/files/user/docs/a.txt</D:href>
    <D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat>
  </D:response>
</D:multistatus>)";

    const ListResult r = WebDAVAdapter::parsePropfind(xml, "/docs", "/remote.php/dav/files/user");
    QVERIFY(r.ok());
    QCOMPARE(r.value.size(), 1);
    QCOMPARE(r.value.at(0).path, QStringLiteral("/docs/a.txt"));
}

void TestWebDAVParse::decodesPercentEncodedNames()
{
    const QByteArray xml = R"(<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/%E6%B5%8B%E8%AF%95/%E6%96%87%E4%BB%B6.txt</D:href>
    <D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat>
  </D:response>
</D:multistatus>)";

    const ListResult r = WebDAVAdapter::parsePropfind(xml, "/测试", QString());
    QVERIFY(r.ok());
    QCOMPARE(r.value.size(), 1);
    QCOMPARE(r.value.at(0).name, QStringLiteral("文件.txt"));
}

QTEST_APPLESS_MAIN(TestWebDAVParse)
#include "tst_webdavparse.moc"
