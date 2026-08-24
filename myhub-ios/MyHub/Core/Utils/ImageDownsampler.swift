import Foundation
import UIKit
import ImageIO

/// 图片下采样（ImageIO）：封面缩略图按目标像素解码，避免原图全量解码占内存
enum ImageDownsampler {
    /// 从 Data 解码并限制最大边长
    static func downsample(data: Data, maxPixel: CGFloat = 512) -> UIImage? {
        let options: CFDictionary = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumbnailOptions: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: image)
    }
}
