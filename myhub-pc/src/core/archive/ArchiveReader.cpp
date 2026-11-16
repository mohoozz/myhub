#include "ArchiveReader.h"

#include "core/archive/PageOrder.h"
#include "core/storage/StoragePath.h"

#include <QFile>
#include <QFileInfo>

#include <archive.h>
#include <archive_entry.h>

#include <cerrno>

namespace myhub {

namespace {

/// libarchive 的回调式打开：路径由 QFile 解析，避免 Windows 上 ANSI 代码页吃掉中文名
struct FileSource
{
    QFile file;
    QByteArray buffer;
};

la_ssize_t readCallback(struct archive *, void *clientData, const void **buffer)
{
    auto *src = static_cast<FileSource *>(clientData);
    constexpr qint64 kChunk = qint64(256) * 1024;
    src->buffer = src->file.read(kChunk);
    if (src->buffer.isEmpty()) {
        *buffer = nullptr;
        return 0; // 0 = EOF；真正的读错误交给 next_header 报
    }
    *buffer = src->buffer.constData();
    return static_cast<la_ssize_t>(src->buffer.size());
}

la_int64_t skipCallback(struct archive *, void *clientData, la_int64_t request)
{
    auto *src = static_cast<FileSource *>(clientData);
    if (request <= 0) {
        return 0;
    }
    const qint64 start = src->file.pos();
    const qint64 end = src->file.size();
    // 跳过不能越过文件尾：真越界了就只能跳到末尾，让上层看到 EOF
    const qint64 target = qMin(start + request, end);
    if (target <= start || !src->file.seek(target)) {
        return 0;
    }
    return target - start;
}

la_int64_t seekCallback(struct archive *, void *clientData, la_int64_t offset, int whence)
{
    auto *src = static_cast<FileSource *>(clientData);
    qint64 base = 0;
    if (whence == SEEK_CUR) {
        base = src->file.pos();
    } else if (whence == SEEK_END) {
        base = src->file.size();
    }
    const qint64 target = base + offset;
    if (target < 0 || !src->file.seek(target)) {
        return ARCHIVE_FATAL;
    }
    return target;
}

int closeCallback(struct archive *, void *clientData)
{
    auto *src = static_cast<FileSource *>(clientData);
    src->file.close();
    return ARCHIVE_OK;
}

StorageError archiveError(struct archive *handle, const QString &context)
{
    const char *raw = archive_error_string(handle);
    QString detail = raw != nullptr ? QString::fromUtf8(raw) : QString();
    if (detail.isEmpty()) {
        detail = QStringLiteral("未知原因");
    }
    if (archive_errno(handle) == ENOENT) {
        return StorageError(StorageError::NotFound, context);
    }
    return StorageError(StorageError::InvalidResponse,
                        context.isEmpty() ? detail : QStringLiteral("%1：%2").arg(context, detail));
}

/// 打开归档并挂上回调；失败返回 nullptr 并填充 `error`
archive *openArchive(const QString &filePath, std::shared_ptr<FileSource> *source,
                     StorageError *error)
{
    auto src = std::make_shared<FileSource>();
    src->file.setFileName(filePath);
    if (!src->file.open(QIODevice::ReadOnly)) {
        *error =
            StorageError(StorageError::NotFound, QStringLiteral("压缩包打不开：%1").arg(filePath));
        return nullptr;
    }

    archive *handle = archive_read_new();
    archive_read_support_filter_all(handle);
    archive_read_support_format_all(handle);
    archive_read_set_callback_data(handle, src.get());
    archive_read_set_read_callback(handle, readCallback);
    archive_read_set_skip_callback(handle, skipCallback);
    archive_read_set_seek_callback(handle, seekCallback);
    archive_read_set_close_callback(handle, closeCallback);

    if (archive_read_open1(handle) != ARCHIVE_OK) {
        *error = StorageError(StorageError::InvalidResponse,
                              QStringLiteral("不是可识别的压缩包：%1")
                                  .arg(QString::fromUtf8(archive_error_string(handle) != nullptr
                                                             ? archive_error_string(handle)
                                                             : "格式不支持")));
        archive_read_free(handle);
        return nullptr;
    }
    *source = src;
    return handle;
}

/// 条目名取 UTF-8 优先，退回本地编码（老 rar 存的是 ANSI）
QString nameOfEntry(struct archive_entry *entry)
{
    const char *utf8 = archive_entry_pathname_utf8(entry);
    if (utf8 != nullptr && *utf8 != '\0') {
        return QString::fromUtf8(utf8);
    }
    const char *raw = archive_entry_pathname(entry);
    if (raw == nullptr) {
        return QString();
    }
    QString asUtf8 = QString::fromUtf8(raw);
    if (!asUtf8.contains(QChar(QChar::ReplacementCharacter))) {
        return asUtf8;
    }
    return QString::fromLocal8Bit(raw);
}

bool isEncrypted(struct archive_entry *entry)
{
    return archive_entry_is_encrypted(entry) == 1;
}

} // namespace

StorageError ArchiveReader::listEntries(const QString &filePath, QVector<ArchiveEntry> *entries)
{
    if (entries == nullptr) {
        return StorageError(StorageError::InvalidPath, QStringLiteral("输出参数为空"));
    }
    entries->clear();
    if (!QFileInfo::exists(filePath)) {
        return StorageError(StorageError::NotFound, QStringLiteral("文件不存在：%1").arg(filePath));
    }

    std::shared_ptr<FileSource> source;
    StorageError error;
    archive *handle = openArchive(filePath, &source, &error);
    if (handle == nullptr) {
        return error;
    }

    struct archive_entry *entry = nullptr;
    int count = 0;
    bool encrypted = false;
    while (true) {
        const int rc = archive_read_next_header(handle, &entry);
        if (rc == ARCHIVE_EOF) {
            break;
        }
        if (rc < ARCHIVE_WARN) {
            error = archiveError(handle, QStringLiteral("读取压缩包目录失败"));
            break;
        }
        if (++count > kMaxEntries) {
            error = StorageError(StorageError::InvalidResponse,
                                 QStringLiteral("压缩包条目数异常（超过 %1）").arg(kMaxEntries));
            break;
        }

        ArchiveEntry item;
        item.name = nameOfEntry(entry);
        const qint64 size = archive_entry_size(entry);
        item.size = size > 0 ? size : 0;
        // libarchive 对目录给的是不带 '/' 的名字，这里补上统一判定
        if (item.name.endsWith(QLatin1Char('/')) || archive_entry_filetype(entry) == AE_IFDIR) {
            if (!item.name.endsWith(QLatin1Char('/'))) {
                item.name += QLatin1Char('/');
            }
        } else if (isEncrypted(entry)) {
            encrypted = true;
        }
        if (!item.name.isEmpty()) {
            entries->append(item);
        }
    }

    archive_read_free(handle);
    source->file.close();

    if (error.isNull() && encrypted) {
        return StorageError(StorageError::UnsupportedProtocol,
                            QStringLiteral("这个压缩包有密码，暂不支持加密的漫画"));
    }
    return error;
}

StorageError ArchiveReader::readEntry(const QString &filePath, const QString &entryName,
                                      QByteArray *out)
{
    if (out == nullptr) {
        return StorageError(StorageError::InvalidPath, QStringLiteral("输出参数为空"));
    }
    out->clear();

    std::shared_ptr<FileSource> source;
    StorageError error;
    archive *handle = openArchive(filePath, &source, &error);
    if (handle == nullptr) {
        return error;
    }

    struct archive_entry *entry = nullptr;
    bool found = false;
    while (archive_read_next_header(handle, &entry) != ARCHIVE_EOF) {
        if (nameOfEntry(entry) == entryName) {
            found = true;
            break;
        }
        archive_read_data_skip(handle);
    }

    if (!found) {
        archive_read_free(handle);
        source->file.close();
        return StorageError(StorageError::InvalidResponse,
                            QStringLiteral("压缩包里找不到这一页：%1").arg(entryName));
    }
    if (isEncrypted(entry)) {
        archive_read_free(handle);
        source->file.close();
        return StorageError(StorageError::UnsupportedProtocol,
                            QStringLiteral("这一页是加密的，暂不支持"));
    }

    QByteArray data;
    QByteArray chunk(qsizetype(64) * 1024, Qt::Uninitialized);
    while (true) {
        const la_ssize_t read = archive_read_data(handle, chunk.data(), chunk.size());
        if (read == 0) {
            break;
        }
        if (read < 0) {
            error = archiveError(handle, QStringLiteral("解压这一页失败"));
            break;
        }
        if (data.size() + read > kMaxEntryBytes) {
            error = StorageError(StorageError::InvalidResponse,
                                 QStringLiteral("这一页解压后过大（超过 64MB）"));
            break;
        }
        data.append(chunk.constData(), static_cast<int>(read));
    }

    archive_read_free(handle);
    source->file.close();

    if (!error.isNull()) {
        return error;
    }
    *out = std::move(data);
    return StorageError();
}

QVector<int> ArchiveReader::pageIndexes(const QVector<ArchiveEntry> &entries)
{
    QStringList names;
    names.reserve(entries.size());
    for (const ArchiveEntry &entry : entries) {
        names.append(entry.name);
    }
    return pageorder::sortedPageIndexes(names);
}

bool ArchiveReader::isRarPath(const QString &path)
{
    const QString ext = StoragePath::extension(path).toLower();
    return ext == QLatin1String("rar") || ext == QLatin1String("cbr");
}

} // namespace myhub
