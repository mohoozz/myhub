# QmlModule.cmake —— QML 模块定义
#
# 以 include() 方式在顶层展开（而非 add_subdirectory），
# 保证与 qt_add_executable(MyHub) 处于同一目录作用域：
# AUTOMOC 的 metatypes 收集与 qmltyperegistrar 依赖同目录的 autogen 产物。

# pragma Singleton 的文件必须显式标记，
# 否则运行期报 "Type is not a singleton"
set_source_files_properties(
    qml/theme/Colors.qml
    qml/theme/AppTheme.qml
    qml/theme/Motion.qml
    qml/theme/Icons.qml
    qml/player/PlayerStage.qml
    PROPERTIES QT_QML_SINGLETON_TYPE TRUE
)


qt_add_qml_module(MyHub
    URI MyHub
    VERSION 1.0
    QML_FILES
        qml/Main.qml

        qml/theme/Colors.qml
        qml/theme/AppTheme.qml
        qml/theme/Motion.qml
        qml/theme/Icons.qml

        qml/components/AppIcon.qml
        qml/components/CellPressHighlight.qml
        qml/components/ConfirmDialog.qml
        qml/components/CoverImage.qml
        qml/components/EmptyState.qml
        qml/components/FilePropertiesDialog.qml
        qml/components/FolderPickerDialog.qml
        qml/components/GlassPanel.qml
        qml/components/InputDialog.qml
        qml/components/LaunchLoading.qml
        qml/components/PopupMenu.qml
        qml/components/PlayingBars.qml
        qml/components/PrimaryButton.qml
        qml/components/ProgressRing.qml
        qml/components/RevealHalo.qml
        qml/components/SearchField.qml
        qml/components/SelectionTick.qml
        qml/components/StatusDot.qml
        qml/components/TextField.qml
        qml/components/TextEditorDialog.qml
        qml/components/ToolbarButton.qml
        qml/components/TransferBanner.qml

        qml/shell/RootShell.qml
        qml/shell/Sidebar.qml
        qml/shell/SidebarItem.qml

        qml/browse/BrowseHome.qml
        qml/browse/BrowseDirectory.qml
        qml/browse/ConnectionCard.qml
        qml/browse/FileGridCell.qml
        qml/browse/FileListRow.qml
        qml/browse/FileTypeIcon.qml

        qml/favorites/FavoritesHome.qml

        qml/reading/ReadingHome.qml
        qml/reading/ReadingGridCell.qml
        qml/reading/ReadingListRow.qml

        qml/settings/SettingsHome.qml
        qml/settings/ConnectionListView.qml
        qml/settings/ConnectionFormView.qml
        qml/settings/TrashSection.qml

        qml/player/PlayerView.qml
        qml/player/PlayerStage.qml
        qml/player/MiniPlayerBar.qml
        qml/player/PlayerSurface.qml
        qml/player/PlayerVideoLayer.qml
        qml/player/PlayerTopBar.qml
        qml/player/PlayerControlBar.qml
        qml/player/PlayerProgressBar.qml
        qml/player/PlayerCapsule.qml
        qml/player/PlayerButton.qml
        qml/player/AudioCoverView.qml
        qml/player/FloatingPlayerOverlay.qml

        qml/placeholder/ModulePlaceholder.qml
    RESOURCES
        resources/icons/app.svg
)
