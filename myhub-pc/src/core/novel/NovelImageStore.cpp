#include "NovelImageStore.h"

#include "../cache/CachePartition.h"
#include "../cache/CacheStore.h"
#include "../utils/AppLogger.h"
#include "../utils/AppPaths.h"

#include <QCryptographicHash>
#include <QFileInfo>
#include <QRegularExpression>
#include <QSaveFile>

namespace myhub {

namespace {

/// 目录 key / 条目哈希的长度：12 个十六进制字符，撞车概率可以忽略
constexpr int kKeyChars = 12;
constexpr int kFingerprintChars = 8;

QString hashOf(const QString &text, int chars)
{
    return QString::fromLatin1(
               QCryptographicHash::hash(text.toUtf8(), QCryptographicHash::Sha1).toHex())
        .left(chars);
}

QString bookKey(const QString &connectionId, const QString &path)
{
    return hashOf(connectionId + QLatin1Char('\n') + path, kKeyChars);
}

QString fingerprintKey(qint64 fileSize, qint64 modTimeMs)
{
    return hashOf(QStringLiteral("%1:%2").arg(fileSize).arg(modTimeMs), kFingerprintChars);
}

/// 扩展名原样保留：图片加载靠它判格式（内容嗅探在解码那层做兜底）
QString suffixOf(const QString &entry)
{
    QString suffix = QFileInfo(entry).suffix().toLower();
    suffix.remove(QRegularExpression(QStringLiteral("[^a-z0-9]")));
    if (suffix.isEmpty() || suffix.size() > 5) {
        return QStringLiteral("img");
    }
    return suffix;
}

} // namespace

QString NovelImageStore::partitionDir()
{
    return CachePartitions::path(QString::fromLatin1(CacheDirs::NovelImages));
}

QString NovelImageStore::pathFor(const QString &connectionId, const QString &path, qint64 fileSize,
                                 qint64 modTimeMs, const QString &entry)
{
    const QString dir = partitionDir();
    AppPaths::ensureDir(dir);
    // 文件名 = 书 key - 指纹 - 条目哈希.扩展名。三层都不可省：
    // 书的 key 防串书，指纹防「文件换了还读旧图」，条目哈希防一章多图互相覆盖
    const QString name = QStringLiteral("%1-%2-%3.%4")
                             .arg(bookKey(connectionId, path), fingerprintKey(fileSize, modTimeMs),
                                  hashOf(entry, kKeyChars), suffixOf(entry));
    return dir + QLatin1Char('/') + name;
}

bool NovelImageStore::save(const QString &filePath, const QByteArray &bytes)
{
    if (bytes.isEmpty()) {
        return false;
    }
    AppPaths::ensureDir(QFileInfo(filePath).absolutePath());
    QSaveFile file(filePath);
    if (!file.open(QIODevice::WriteOnly)) {
        MH_WARN(Cache, QStringLiteral("插图快照打不开：%1").arg(filePath));
        return false;
    }
    file.write(bytes);
    if (!file.commit()) {
        MH_WARN(Cache, QStringLiteral("插图快照写不进去：%1").arg(filePath));
        return false;
    }
    return true;
}

void NovelImageStore::touch(const QString &filePath)
{
    CacheStore::touch(filePath);
}

} // namespace myhub
