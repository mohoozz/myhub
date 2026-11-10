#pragma once

#include <QDateTime>
#include <QString>

namespace myhub {

/**
 * 播放器截图落盘位置（§4.3「截图 / 截取当前帧」）。
 *
 * 之所以单独抽出来：文件名要处理三大类坑，且都必须能脱离播放器单测
 *  1. 标题里带 Windows 非法字符（`/ \ : * ? " < > |`）与控制字符 —— 直接拿来拼路径会写失败；
 *  2. 同一秒连按两次不能互相覆盖 —— 重名自动加 `-2`、`-3`…；
 *  3. 标题可能为空（远端条目解析不出名字）—— 退回 `screenshot`，不能生成 `.png` 这种隐藏文件。
 *
 * 定位在 myhub_core（只依赖 QtCore），因此只用 QStandardPaths，不碰 QGuiApplication。
 */
class ScreenshotPath
{
public:
    /// 默认保存目录：`图片/MyHub`；系统取不到「图片」时退回 `应用数据目录/screenshots`
    static QString defaultDirectory();

    /// 净化标题：非法字符与控制字符换成 `_`，合并连续空白；清空后退回 `screenshot`
    static QString sanitizeTitle(const QString &title);

    /**
     * 生成目标文件路径（**不创建目录**，由调用方负责 mkpath）。
     *
     * 形如 `<dir>/<标题>_2026-11-10_18-52-30.png`；同名已存在时依次追加 `-2`、`-3`…
     * @param now 显式传入当前时间，便于单测断言
     */
    static QString build(const QString &directory, const QString &title, const QDateTime &now);
};

} // namespace myhub
