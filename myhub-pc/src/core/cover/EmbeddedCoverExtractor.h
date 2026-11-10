#pragma once

#include <QByteArray>
#include <QString>

namespace myhub {

/**
 * 内嵌封面提取（PC-702）。
 *
 * 定位：**纯字节解析**，不依赖 QtGui，因此可以放在 core 库并被 QTest 直接覆盖。
 * 图片解码 / 缩放 / 落盘由 CoverService 负责。
 *
 * 支持的容器（都是「封面藏在文件头或文件尾」的元数据，无需整文件）：
 *   - MP3 ID3v2.2 / 2.3 / 2.4 的 `APIC`（v2.2 为 `PIC`）帧
 *   - FLAC 元数据块 `PICTURE`（type 6）
 *   - MP4 / M4A / M4V / MOV 的 `moov.udta.meta.ilst.covr`
 *
 * 远程源只需 2 段 Range 读取（头 2MB + 尾 4MB）即可命中绝大多数文件，
 * 这与 iOS 端 CoverService 的「免整文件下载」策略一致。
 */
class EmbeddedCoverExtractor
{
public:
    /// 头部片段上限
    static constexpr qint64 kHeadBytes = 2 * 1024 * 1024;
    /// 尾部片段上限
    static constexpr qint64 kTailBytes = 4 * 1024 * 1024;

    /// 头部片段应读取的长度（文件未知时按上限读）
    static qint64 headLength(qint64 fileSize);

    /// 尾部片段起始偏移；返回 0 表示尾部已被头部完全覆盖，无需单独读取
    static qint64 tailOffset(qint64 fileSize);

    /// 该扩展名是否值得尝试内嵌封面
    static bool supports(const QString &ext);

    /**
     * 提取内嵌封面的原始图片字节。
     *
     * @param ext 小写扩展名（不含 '.'）
     * @param fileSize 文件总长；<= 0 表示未知（此时只用 head）
     * @param head 文件头部片段，从偏移 0 开始
     * @param tail 文件尾部片段，从 tailOffset(fileSize) 开始；可为空
     * @return 原始图片字节；空表示无封面或无法解析
     */
    static QByteArray extract(const QString &ext, qint64 fileSize, const QByteArray &head,
                              const QByteArray &tail = QByteArray());
};

} // namespace myhub
