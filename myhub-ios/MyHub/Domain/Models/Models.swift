import Foundation

// 领域模型：
// - 数据库记录（GRDB）位于 Core/Database/Records/（Connection / Favorite /
//   ReadingProgress / NovelIndex / Bookmark / BrowserHistory / BrowserShortcut /
//   DownloadTask / FeedItem）
// - 存储条目 FileEntry 位于 Core/Storage/StorageAdapter.swift
// - 播放器 UI 层 PlayableItem 位于 Player/UI/PlayerPresenter.swift
// 后续跨层共享的纯领域类型在此补充。
