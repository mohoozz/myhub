import Foundation

/// 自然排序（数字感知）："第2话" < "第10话"（《需求分析文档》§5.2 Core/Utils）
extension String {
    /// 自然序比较（本地化、数字感知、忽略大小写）
    func naturalCompare(_ other: String) -> ComparisonResult {
        localizedStandardCompare(other)
    }
}

extension Sequence where Element == String {
    /// 自然序排序
    func naturalSorted() -> [String] {
        sorted { $0.naturalCompare($1) == .orderedAscending }
    }
}
