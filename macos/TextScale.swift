// iPad apps on a Mac are drawn at 77%, so text looks small. All of the app's fonts go
// through the replacements below and are scaled by one factor.
// Tune without rebuilding: defaults write com.petrovich.cinepub CinepubTextScale -float 1.3
import SwiftUI

private let textScale: CGFloat = {
    let value = UserDefaults.standard.double(forKey: "CinepubTextScale")
    return value > 0 ? value : 1.3
}()

// 2 for fonts made by the enlarged seasons/episodes code (see interpose.m), else 1.
@_silgen_name("cinepub_font_zoom") private func fontZoom() -> Double

private func scaled(_ size: CGFloat) -> CGFloat { size * textScale * fontZoom() }

// Text styles don't follow Dynamic Type on a Mac, so each one becomes its iOS (Large) size, scaled.
private func style(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: scaled(size), weight: weight)
}

@_silgen_name("cinepub_font_largeTitle") public func cinepubLargeTitle() -> Font { style(34) }
@_silgen_name("cinepub_font_title") public func cinepubTitle() -> Font { style(28) }
@_silgen_name("cinepub_font_title2") public func cinepubTitle2() -> Font { style(22) }
@_silgen_name("cinepub_font_title3") public func cinepubTitle3() -> Font { style(20) }
@_silgen_name("cinepub_font_headline") public func cinepubHeadline() -> Font { style(17, .semibold) }
@_silgen_name("cinepub_font_body") public func cinepubBody() -> Font { style(17) }
@_silgen_name("cinepub_font_callout") public func cinepubCallout() -> Font { style(16) }
@_silgen_name("cinepub_font_subheadline") public func cinepubSubheadline() -> Font { style(15) }
@_silgen_name("cinepub_font_footnote") public func cinepubFootnote() -> Font { style(13) }
@_silgen_name("cinepub_font_caption") public func cinepubCaption() -> Font { style(12) }
@_silgen_name("cinepub_font_caption2") public func cinepubCaption2() -> Font { style(11) }

// Same signatures (and so the same ABI) as both SwiftUI.Font.system(size:weight:design:) overloads.
@_silgen_name("cinepub_font_system")
public func cinepubFontSystem(size: CGFloat, weight: Font.Weight, design: Font.Design) -> Font {
    .system(size: scaled(size), weight: weight, design: design)
}

@_silgen_name("cinepub_font_system_optional")
public func cinepubFontSystemOptional(size: CGFloat, weight: Font.Weight?, design: Font.Design?) -> Font {
    .system(size: scaled(size), weight: weight, design: design)
}
