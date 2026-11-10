#pragma once

#include <QString>

namespace myhub {

/**
 * 崩溃捕获（PC-707）。
 *
 * 捕获原生信号（SIGSEGV / SIGABRT / SIGFPE / SIGILL）与未处理 C++ 异常，
 * 写入 `crash.log`。
 *
 * 实现纪律：信号处理函数内只能调用 async-signal-safe 的操作，
 * 因此落盘使用 write(2) 级别的原始写入，不碰 Qt 的内存分配。
 */
class CrashReporter
{
public:
    /// 安装信号与 terminate 处理器
    static void install();

    /// crash.log 完整路径
    static QString crashLogPath();

    /// 是否存在上次运行留下的崩溃记录（启动时可提示用户）
    static bool hasPendingReport();

    /// 读取崩溃记录内容
    static QString readReport();

    /// 清除崩溃记录
    static void clearReport();
};

} // namespace myhub
