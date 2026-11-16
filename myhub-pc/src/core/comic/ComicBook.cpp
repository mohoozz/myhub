#include "ComicBook.h"

#include "core/storage/StoragePath.h"
#include "core/utils/MediaType.h"

#include <QMetaObject>
#include <QPointer>
#include <QtConcurrent/QtConcurrent>

namespace myhub {

ComicBook::ComicBook(RangeSource *source, QObject *parent)
    : QObject(parent)
    , m_source(source)
{
    if (m_source != nullptr) {
        m_zip = std::make_unique<RangeZipReader>(m_source);
    }
}

ComicBook::ComicBook(const QString &localFilePath, QObject *parent)
    : QObject(parent)
    , m_localPath(localFilePath)
{}

ComicBook::~ComicBook()
{
    // 在途回调由 serial 与 QPointer 双重丢弃；这里只是把两条串行线一起关掉
    cancel();
}

bool ComicBook::isComicArchivePath(const QString &path)
{
    return MediaType::isComicArchive(StoragePath::extension(path));
}

void ComicBook::open(OpenCallback cb)
{
    m_openCallback = std::move(cb);
    const quint64 serial = ++m_openSerial;

    if (!m_localPath.isEmpty()) {
        openLocalAsync();
        return;
    }

    if (m_zip == nullptr) {
        finishOpen(StorageError(StorageError::InvalidPath, QStringLiteral("文件不可读")));
        return;
    }

    m_zip->open([this, serial](QVector<ZipEntry> entries, StorageError error) {
        if (serial != m_openSerial) {
            return;
        }
        if (error.isNull()) {
            const QVector<int> indexes = RangeZipReader::imageEntryIndexes(entries);
            m_pages.clear();
            m_names.clear();
            m_pages.reserve(indexes.size());
            m_names.reserve(indexes.size());
            for (int index : indexes) {
                m_pages.append(entries.at(index));
                m_names.append(entries.at(index).name);
            }
            if (m_pages.isEmpty()) {
                error = StorageError(StorageError::InvalidResponse,
                                     QStringLiteral("压缩包里没有图片页，不是漫画文件"));
            }
        }
        finishOpen(error);
    });
}

void ComicBook::openLocalAsync()
{
    const quint64 serial = m_openSerial;
    const QPointer<ComicBook> self(this);
    const QString path = m_localPath;

    // rar 的目录只能顺序解出来，整包在手也可能要几百毫秒，不能压在 GUI 线程
    QtConcurrent::run([self, path, serial]() {
        QVector<ArchiveEntry> entries;
        StorageError error = ArchiveReader::listEntries(path, &entries);

        QVector<ArchiveEntry> pages;
        if (error.isNull()) {
            const QVector<int> indexes = ArchiveReader::pageIndexes(entries);
            pages.reserve(indexes.size());
            for (int index : indexes) {
                pages.append(entries.at(index));
            }
            if (pages.isEmpty()) {
                error = StorageError(StorageError::InvalidResponse,
                                     QStringLiteral("压缩包里没有图片页，不是漫画文件"));
            }
        }

        if (self.isNull()) {
            return;
        }
        QMetaObject::invokeMethod(
            self.data(),
            [self, serial, pages, error]() mutable {
                if (self.isNull() || serial != self->m_openSerial) {
                    return;
                }
                self->m_archiveEntries = pages;
                self->m_pages.clear();
                self->m_names.clear();
                self->m_names.reserve(pages.size());
                for (const ArchiveEntry &entry : pages) {
                    self->m_names.append(entry.name);
                }
                self->finishOpen(error);
            },
            Qt::QueuedConnection);
    });
}

void ComicBook::readPage(int index, PageCallback cb)
{
    m_pageCallback = std::move(cb);
    const quint64 serial = ++m_pageSerial;

    if (index < 0 || index >= pageCount()) {
        finishPage(QByteArray(),
                   StorageError(StorageError::InvalidPath, QStringLiteral("页码超出范围")));
        return;
    }

    if (!m_localPath.isEmpty()) {
        readPageLocalAsync(index, serial);
        return;
    }

    if (m_zip == nullptr) {
        finishPage(QByteArray(),
                   StorageError(StorageError::InvalidPath, QStringLiteral("文件不可读")));
        return;
    }

    m_zip->readEntry(m_pages.at(index), [this, serial](QByteArray data, StorageError error) {
        // 翻页很快：旧页的结果不能盖掉新页（QML 只会看最后一次请求的回调）
        if (serial != m_pageSerial) {
            return;
        }
        finishPage(std::move(data), error);
    });
}

void ComicBook::readPageLocalAsync(int index, quint64 serial)
{
    const QPointer<ComicBook> self(this);
    const QString path = m_localPath;
    const QString name = m_archiveEntries.value(index).name;

    QtConcurrent::run([self, path, name, serial]() {
        QByteArray bytes;
        const StorageError error = ArchiveReader::readEntry(path, name, &bytes);
        if (self.isNull()) {
            return;
        }
        QMetaObject::invokeMethod(
            self.data(),
            [self, serial, bytes = std::move(bytes), error]() mutable {
                if (self.isNull() || serial != self->m_pageSerial) {
                    return;
                }
                self->finishPage(std::move(bytes), error);
            },
            Qt::QueuedConnection);
    });
}

void ComicBook::cancel()
{
    ++m_openSerial;
    ++m_pageSerial;
    m_openCallback = nullptr;
    m_pageCallback = nullptr;
    if (m_zip != nullptr) {
        m_zip->cancel();
    }
}

void ComicBook::finishOpen(const StorageError &error)
{
    OpenCallback cb = std::move(m_openCallback);
    m_openCallback = nullptr;
    if (!cb) {
        return;
    }
    if (error.isNull()) {
        cb(m_names, StorageError());
    } else {
        cb(QStringList(), error);
    }
}

void ComicBook::finishPage(QByteArray bytes, const StorageError &error)
{
    PageCallback cb = std::move(m_pageCallback);
    m_pageCallback = nullptr;
    if (!cb) {
        return;
    }
    cb(std::move(bytes), error);
}

} // namespace myhub
