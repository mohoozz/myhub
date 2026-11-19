#include "features/reading/BundledFonts.h"

#include "core/utils/AppLogger.h"
#include "core/utils/AppPaths.h"

#include <QDir>
#include <QFontDatabase>
#include <QHash>

namespace myhub {
namespace BundledFonts {
namespace {

QHash<int, QStringList> &registry()
{
    static QHash<int, QStringList> groups;
    return groups;
}

QString groupTag(Group group)
{
    return group == Group::Serif ? QStringLiteral("serif") : QStringLiteral("sans");
}

} // namespace

QString dropInDir(Group group)
{
    return QDir(AppPaths::dataDir()).filePath(QStringLiteral("fonts/") + groupTag(group));
}

QStringList registerFontDir(const QString &dirPath, Group group)
{
    const QDir dir(dirPath);
    if (!dir.exists()) {
        return {};
    }

    QStringList &registered = registry()[static_cast<int>(group)];
    QStringList added;
    const QStringList names = dir.entryList({QStringLiteral("*.ttf"), QStringLiteral("*.otf"),
                                             QStringLiteral("*.ttc"), QStringLiteral("*.otc")},
                                            QDir::Files, QDir::Name);
    for (const QString &name : names) {
        const QString path = dir.filePath(name);
        const int id = QFontDatabase::addApplicationFont(path);
        if (id < 0) {
            // 坏字体/权限问题都只降级：正文还有系统字体兜底
            MH_WARN(NovelIndex, QStringLiteral("字体注册失败：%1").arg(path));
            continue;
        }

        // 同一个族名可能被 name 表里的多条记录报出来，去重后再用
        QStringList families;
        for (const QString &family : QFontDatabase::applicationFontFamilies(id)) {
            if (!families.contains(family)) {
                families.append(family);
            }
        }
        if (families.isEmpty()) {
            MH_WARN(NovelIndex, QStringLiteral("字体没有族名，已忽略：%1").arg(path));
            continue;
        }
        for (const QString &family : families) {
            if (!registered.contains(family)) {
                registered.append(family);
            }
            if (!added.contains(family)) {
                added.append(family);
            }
        }
        MH_INFO(
            NovelIndex,
            QStringLiteral("字体已注册：%1 → %2").arg(name, families.join(QStringLiteral(", "))));
    }
    return added;
}

void initialize()
{
    static bool done = false;
    if (done) {
        return;
    }
    done = true;

    // 顺序即优先级：qrc 随程序发布、跨平台一致；投递目录给用户留后门
    registerFontDir(QStringLiteral(":/fonts/sans"), Group::Sans);
    registerFontDir(QStringLiteral(":/fonts/serif"), Group::Serif);
    registerFontDir(dropInDir(Group::Sans), Group::Sans);
    registerFontDir(dropInDir(Group::Serif), Group::Serif);

    const QStringList serif = families(Group::Serif);
    if (!serif.isEmpty()) {
        MH_INFO(NovelIndex,
                QStringLiteral("内置宋体已就绪：%1").arg(serif.join(QStringLiteral(", "))));
    }
}

QStringList families(Group group)
{
    return registry().value(static_cast<int>(group));
}

QStringList serifFamilies()
{
    return families(Group::Serif);
}

QStringList sansFamilies()
{
    return families(Group::Sans);
}

} // namespace BundledFonts
} // namespace myhub
