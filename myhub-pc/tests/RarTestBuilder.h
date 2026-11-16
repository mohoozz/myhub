#pragma once

// 手搓「只存储、不压缩」的最小 RAR4 归档（仅测试用）。
//
// 为什么不放二进制样本：rar 是私有格式，仓库里塞一个 .cbr 既不好审也不好维护；
// 而 RAR4 的头部格式是公开的，store（method 0x30）法只要求字段正确，
// 正好用来验证「libarchive 能不能读我们喂的 rar」这一层。

#include <QByteArray>
#include <QFile>
#include <QString>
#include <QVector>

#include <zlib.h>

namespace rartest {

inline void putU16(QByteArray &out, quint16 value)
{
    out.append(static_cast<char>(value & 0xFF));
    out.append(static_cast<char>((value >> 8) & 0xFF));
}

inline void putU32(QByteArray &out, quint32 value)
{
    for (int i = 0; i < 4; ++i) {
        out.append(static_cast<char>((value >> (8 * i)) & 0xFF));
    }
}

inline quint32 crcOf(const QByteArray &data)
{
    return static_cast<quint32>(crc32(crc32(0L, Z_NULL, 0),
                                      reinterpret_cast<const Bytef *>(data.constData()),
                                      static_cast<uInt>(data.size())));
}

/// RAR4 的 HEAD_CRC 是「本块 HEAD_TYPE 起到底」的 CRC32 低 16 位，且按大端写
inline void putHeadCrc(QByteArray &block)
{
    const quint16 crc = static_cast<quint16>(crcOf(block) & 0xFFFF);
    block.prepend(static_cast<char>((crc >> 8) & 0xFF));
    block.prepend(static_cast<char>(crc & 0xFF));
}

class RarBuilder
{
public:
    void add(const QString &name, const QByteArray &data)
    {
        Item item;
        item.name = name;
        item.data = data;
        m_items.append(item);
    }

    QByteArray build() const
    {
        QByteArray out;
        out.append(QByteArrayLiteral("Rar!\x1a\x07\x00"), 7);

        QByteArray main;
        main.append(static_cast<char>(0x73)); // HEAD_TYPE = MAIN_HEAD
        putU16(main, 0x0000);                 // HEAD_FLAGS
        putU16(main, 13);                     // HEAD_SIZE
        putU16(main, 0);                      // RESERVED1
        putU32(main, 0);                      // RESERVED2
        putHeadCrc(main);
        out.append(main);

        for (const Item &item : m_items) {
            const QByteArray name = item.name.toUtf8();
            const quint32 crc = crcOf(item.data);

            QByteArray head;
            head.append(static_cast<char>(0x74)); // HEAD_TYPE = FILE_HEAD
            putU16(head, 0x8000);                 // HEAD_FLAGS：长块（后面跟数据）
            putU16(head, static_cast<quint16>(32 + name.size()));
            putU32(head, static_cast<quint32>(item.data.size())); // PACK_SIZE
            putU32(head, static_cast<quint32>(item.data.size())); // UNP_SIZE
            head.append(static_cast<char>(2));                    // HOST_OS = Win32
            putU32(head, crc);                                    // FILE_CRC
            putU32(head, 0x4A3B5C21);                             // FTIME（DOS 时间）
            head.append(static_cast<char>(20));                   // UNP_VER 2.0
            head.append(static_cast<char>(0x30));                 // METHOD = store
            putU16(head, static_cast<quint16>(name.size()));
            putU32(head, 0x20); // ATTR：普通文件
            head.append(name);
            putHeadCrc(head);

            out.append(head);
            out.append(item.data);
        }

        // 结束块：少了它 libarchive 会在读下一块头部时抱怨「意外结束」
        QByteArray end;
        end.append(static_cast<char>(0x7b)); // HEAD_TYPE = ENDARC
        putU16(end, 0x4000);                 // HEAD_FLAGS
        putU16(end, 7);                      // HEAD_SIZE
        putHeadCrc(end);
        out.append(end);
        return out;
    }

private:
    struct Item
    {
        QString name;
        QByteArray data;
    };
    QVector<Item> m_items;
};

/// 一页「图片」的占位字节（内容不重要，只要求能原样往返）
inline QByteArray pageBytes(int size, int seed = 13)
{
    QByteArray data;
    data.resize(size);
    for (int i = 0; i < size; ++i) {
        data[i] = static_cast<char>((i * seed + 7) & 0xFF);
    }
    return data;
}

/// 把归档写到 `dir` 下，返回真实路径；失败返回空串
inline QString writeArchive(const QString &dir, const QByteArray &bytes,
                            const QString &fileName = QStringLiteral("vol1.cbr"))
{
    const QString path = dir + QLatin1Char('/') + fileName;
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly)) {
        return QString();
    }
    file.write(bytes);
    file.close();
    return path;
}

} // namespace rartest
