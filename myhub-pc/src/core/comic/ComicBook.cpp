#include "ComicBook.h"

#include "core/storage/StoragePath.h"
#include "core/utils/AppLogger.h"
#include "core/utils/MediaType.h"

#include <QMetaObject>
#include <QPointer>
#include <QSet>
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
    // 在途回调由 QPointer + 请求 id 丢弃；这里把列页与解页两条线一起关掉
    cancel();
}

bool ComicBook::isComicArchivePath(const QString &path)
{
    return MediaType::isComicArchive(StoragePath::extension(path));
}

void ComicBook::setPageOrder(const QStringList &names)
{
    m_pageOrder = names;
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
            applyPageOrder();
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
                self->applyPageOrder();
                self->finishOpen(error);
            },
            Qt::QueuedConnection);
    });
}

void ComicBook::readPage(int index, PageCallback cb)
{
    const quint64 requestId = ++m_pageRequestSerial;
    m_pageCallbacks.emplace(requestId, std::move(cb));

    if (index < 0 || index >= pageCount()) {
        finishPage(requestId, QByteArray(),
                   StorageError(StorageError::InvalidPath, QStringLiteral("页码超出范围")));
        return;
    }

    if (!m_localPath.isEmpty()) {
        readPageLocalAsync(index, requestId);
        return;
    }

    if (m_zip == nullptr) {
        finishPage(requestId, QByteArray(),
                   StorageError(StorageError::InvalidPath, QStringLiteral("文件不可读")));
        return;
    }

    m_zip->readEntry(m_pages.at(index), [this, requestId](QByteArray data, StorageError error) {
        // 每个请求自带 id：并发预取时谁先回来都只投递给自己的调用方，互不顶掉
        finishPage(requestId, std::move(data), error);
    });
}

void ComicBook::readPageLocalAsync(int index, quint64 requestId)
{
    const QPointer<ComicBook> self(this);
    const QString path = m_localPath;
    const QString name = m_archiveEntries.value(index).name;

    // 每次解页各开一份归档句柄（libarchive 是顺序读，共享句柄反而要加锁）
    QtConcurrent::run([self, path, name, requestId]() {
        QByteArray bytes;
        const StorageError error = ArchiveReader::readEntry(path, name, &bytes);
        if (self.isNull()) {
            return;
        }
        QMetaObject::invokeMethod(
            self.data(),
            [self, requestId, bytes = std::move(bytes), error]() mutable {
                if (self.isNull()) {
                    return;
                }
                self->finishPage(requestId, std::move(bytes), error);
            },
            Qt::QueuedConnection);
    });
}

void ComicBook::cancel()
{
    ++m_openSerial;
    m_openCallback = nullptr;
    // 在途解页请求全部作废：回调没了，`finishPage` 拿到空壳直接丢弃
    m_pageCallbacks.clear();
    if (m_zip != nullptr) {
        m_zip->cancel();
    }
}

void ComicBook::applyPageOrder()
{
    if (m_pageOrder.isEmpty() || m_names.isEmpty()) {
        return;
    }

    QHash<QString, int> exact;
    QHash<QString, int> folded;
    exact.reserve(m_names.size());
    folded.reserve(m_names.size());
    for (int i = 0; i < m_names.size(); ++i) {
        exact.insert(m_names.at(i), i);
        folded.insert(m_names.at(i).toLower(), i);
    }

    const QStringList oldNames = m_names;
    QStringList names;
    QVector<ZipEntry> zipPages;
    QVector<ArchiveEntry> archivePages;
    QSet<int> taken;
    names.reserve(qMin(oldNames.size(), static_cast<int>(m_pageOrder.size())));
    for (const QString &name : std::as_const(m_pageOrder)) {
        int index = exact.value(name, -1);
        if (index < 0) {
            index = folded.value(name.toLower(), -1);
        }
        if (index < 0 || taken.contains(index)) {
            continue;
        }
        taken.insert(index);
        names.append(oldNames.at(index));
        if (index < m_pages.size()) {
            zipPages.append(m_pages.at(index));
        }
        if (index < m_archiveEntries.size()) {
            archivePages.append(m_archiveEntries.at(index));
        }
    }

    // 一个都对不上：宁可页序不理想，也不能把整本书开成空的
    if (names.isEmpty()) {
        MH_WARN(ComicReader, QStringLiteral("指定的页序与归档条目对不上，退回条目名排序"));
        return;
    }

    m_names = names;
    m_pages = zipPages;
    m_archiveEntries = archivePages;
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

void ComicBook::finishPage(quint64 requestId, QByteArray bytes, const StorageError &error)
{
    PageCallback cb = m_pageCallbacks.take(requestId);
    if (!cb) {
        return; // 已取消（关书 / 换书）：这一页的结果没人要了
    }
    cb(std::move(bytes), error);
}

} // namespace myhub
