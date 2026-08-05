package model

// All 返回全部数据模型，用于 GORM AutoMigrate 自动建表。
// 新增模型时在此追加即可。
func All() []interface{} {
	return []interface{}{
		&User{},
		&Source{},
		&TrashItem{},
		&Favorite{},
		&ReadingProgress{},
		&NovelIndex{},
		&FeedSubscription{},
		&FeedItem{},
		&FeedCursor{},
		&WatchLater{},
		&FeedFetchLog{},
		&AppConfig{},
	}
}
