#if os(macOS)
import CodexProxyCore
import Foundation

enum OverviewTab: String, CaseIterable, Identifiable {
    case runtime
    case traffic
    case recentActivity

    var id: String { self.rawValue }

    var symbolName: String {
        switch self {
        case .runtime:
            return "waveform.path.ecg"
        case .traffic:
            return "chart.bar.xaxis"
        case .recentActivity:
            return "clock.arrow.circlepath"
        }
    }
}

enum OverviewNumberFormat {
    static func abbreviated(_ value: Int64) -> String {
        let absoluteValue = Double(value.magnitude)
        guard absoluteValue >= 1_000 else {
            return "\(value)"
        }

        let suffixes = ["", "k", "m", "b"]
        let divisors: [Double] = [1, 1_000, 1_000_000, 1_000_000_000]
        var index = min(suffixes.count - 1, divisors.lastIndex(where: { absoluteValue >= $0 }) ?? 0)
        var scaled = absoluteValue / divisors[index]
        var rounded = (scaled * 10).rounded() / 10

        if rounded >= 1_000, index < suffixes.count - 1 {
            index += 1
            scaled = absoluteValue / divisors[index]
            rounded = (scaled * 10).rounded() / 10
        }

        let sign = value < 0 ? "-" : ""
        return sign + self.trimmed(rounded) + suffixes[index]
    }

    static func full(_ value: Int64) -> String {
        self.fullNumberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func trimmed(_ value: Double) -> String {
        if value.rounded() == value {
            return "\(Int64(value))"
        }

        let formatted = String(format: "%.1f", value)
        return formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) : formatted
    }

    private static let fullNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}

struct OverviewNaturalTokenCard: Identifiable, Equatable {
    let id: String
    let title: String
    let requestCount: Int64
    let totalTokens: Int64
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheHitTokens: Int64
    let cacheMissTokens: Int64
}

struct OverviewRecentWeekOption: Identifiable, Equatable {
    let offset: Int
    let title: String
    let rangeText: String
    let startDate: Date
    let endDate: Date

    var id: Int { self.offset }
}

struct OverviewTrafficTrendPoint: Identifiable, Equatable {
    let bucketStart: Int64
    let date: Date
    let xAxisPrimaryLabel: String
    let xAxisSecondaryLabel: String
    let title: String
    let detailText: String
    let totalTokens: Int64?
    let inputTokens: Int64?
    let outputTokens: Int64?
    let cacheHitTokens: Int64?
    let cacheMissTokens: Int64?
    let requestCount: Int64?
    let isFuture: Bool

    var id: Int64 { self.bucketStart }
}

private enum OverviewDateFormatting {
    static func rangeText(
        start: Date,
        end: Date,
        languageMode: DesktopLanguageMode
    ) -> String {
        "\(self.shortDateText(start, languageMode: languageMode)) - \(self.shortDateText(end, languageMode: languageMode))"
    }

    static func shortDateText(
        _ date: Date,
        languageMode: DesktopLanguageMode
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.locale = self.locale(for: languageMode)
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    static func compactRangeText(
        start: Date,
        end: Date,
        languageMode: DesktopLanguageMode
    ) -> String {
        "\(self.shortDateText(start, languageMode: languageMode))-\(self.shortDateText(end, languageMode: languageMode))"
    }

    static func weekdayText(
        _ date: Date,
        languageMode: DesktopLanguageMode
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.locale = self.locale(for: languageMode)
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: date)
    }

    private static func locale(for languageMode: DesktopLanguageMode) -> Locale {
        switch languageMode {
        case .system:
            return .autoupdatingCurrent
        case .zhHans:
            return Locale(identifier: "zh_Hans_CN")
        case .english:
            return Locale(identifier: "en_US")
        }
    }
}

@MainActor
extension DesktopAppModel {
    func overviewTabTitle(_ tab: OverviewTab) -> String {
        switch tab {
        case .runtime:
            return self.text(.sectionRuntime)
        case .traffic:
            return self.text(.sectionTraffic)
        case .recentActivity:
            return self.text(.sectionLatestActivity)
        }
    }

    var overviewNaturalTokenCards: [OverviewNaturalTokenCard] {
        [
            self.overviewNaturalTokenCard(
                id: "today",
                title: self.text(.optionToday),
                usage: self.stats.naturalTokenUsage.today
            ),
            self.overviewNaturalTokenCard(
                id: "week",
                title: self.text(.optionThisWeek),
                usage: self.stats.naturalTokenUsage.week
            ),
            self.overviewNaturalTokenCard(
                id: "month",
                title: self.text(.optionThisMonth),
                usage: self.stats.naturalTokenUsage.month
            ),
        ]
    }

    var overviewRecentWeekOptions: [OverviewRecentWeekOption] {
        self.overviewRecentWeekOptions(now: Date(), calendar: .current)
    }

    func overviewRecentWeekOptions(
        now: Date,
        calendar: Calendar
    ) -> [OverviewRecentWeekOption] {
        let currentWeekStart = self.overviewStartOfMondayWeek(for: now, calendar: calendar)
        return (0..<4).compactMap { offset in
            guard let startDate = calendar.date(byAdding: .day, value: -(offset * 7), to: currentWeekStart),
                  let endDate = calendar.date(byAdding: .day, value: 6, to: startDate)
            else {
                return nil
            }
            return OverviewRecentWeekOption(
                offset: offset,
                title: self.overviewRecentWeekTitle(offset: offset),
                rangeText: OverviewDateFormatting.rangeText(
                    start: startDate,
                    end: endDate,
                    languageMode: self.preferences.languageMode
                ),
                startDate: startDate,
                endDate: endDate
            )
        }
    }

    var overviewSelectedRecentWeekOption: OverviewRecentWeekOption {
        self.overviewSelectedRecentWeekOption(now: Date(), calendar: .current)
    }

    func overviewSelectedRecentWeekOption(
        now: Date,
        calendar: Calendar
    ) -> OverviewRecentWeekOption {
        let clampedOffset = min(max(self.selectedOverviewTrafficWeekOffset, 0), 3)
        let options = self.overviewRecentWeekOptions(now: now, calendar: calendar)
        return options.first(where: { $0.offset == clampedOffset }) ?? options[0]
    }

    var overviewSelectedDailyTrendPoints: [OverviewTrafficTrendPoint] {
        self.overviewSelectedDailyTrendPoints(now: Date(), calendar: .current)
    }

    func overviewSelectedDailyTrendPoints(
        now: Date,
        calendar: Calendar
    ) -> [OverviewTrafficTrendPoint] {
        let todayStart = calendar.startOfDay(for: now)
        let buckets = Dictionary(
            uniqueKeysWithValues: self.stats.naturalTokenUsage.dailyTrend.map { ($0.bucketStart, $0) }
        )
        let selectedWeek = self.overviewSelectedRecentWeekOption(now: now, calendar: calendar)

        return (0..<7).compactMap { index in
            guard let dayDate = calendar.date(byAdding: .day, value: index, to: selectedWeek.startDate) else {
                return nil
            }

            let bucketStart = Int64(dayDate.timeIntervalSince1970)
            let bucket = buckets[bucketStart]
            let isFuture = dayDate > todayStart
            let inputTokens = isFuture ? nil : (bucket?.inputTokens ?? 0)
            let outputTokens = isFuture ? nil : (bucket?.outputTokens ?? 0)

            return OverviewTrafficTrendPoint(
                bucketStart: bucketStart,
                date: dayDate,
                xAxisPrimaryLabel: OverviewDateFormatting.weekdayText(dayDate, languageMode: self.preferences.languageMode),
                xAxisSecondaryLabel: OverviewDateFormatting.shortDateText(dayDate, languageMode: self.preferences.languageMode),
                title: OverviewDateFormatting.shortDateText(dayDate, languageMode: self.preferences.languageMode),
                detailText: OverviewDateFormatting.weekdayText(dayDate, languageMode: self.preferences.languageMode),
                totalTokens: self.combineOverviewTokenValues(inputTokens: inputTokens, outputTokens: outputTokens),
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheHitTokens: isFuture ? nil : (bucket?.cacheHitTokens ?? 0),
                cacheMissTokens: isFuture ? nil : (bucket?.cacheMissTokens ?? 0),
                requestCount: isFuture ? nil : (bucket?.requestCount ?? 0),
                isFuture: isFuture
            )
        }
    }

    var overviewWeeklyTrendPoints: [OverviewTrafficTrendPoint] {
        self.overviewWeeklyTrendPoints(now: Date(), calendar: .current)
    }

    func overviewWeeklyTrendPoints(
        now: Date,
        calendar: Calendar
    ) -> [OverviewTrafficTrendPoint] {
        let buckets = Dictionary(
            uniqueKeysWithValues: self.stats.naturalTokenUsage.weeklyTrend.map { ($0.bucketStart, $0) }
        )
        let currentWeekStart = self.overviewStartOfMondayWeek(for: now, calendar: calendar)

        return stride(from: 3, through: 0, by: -1).compactMap { offset in
            guard let startDate = calendar.date(byAdding: .day, value: -(offset * 7), to: currentWeekStart),
                  let endDate = calendar.date(byAdding: .day, value: 6, to: startDate)
            else {
                return nil
            }

            let bucketStart = Int64(startDate.timeIntervalSince1970)
            let bucket = buckets[bucketStart]
            let inputTokens = bucket?.inputTokens ?? 0
            let outputTokens = bucket?.outputTokens ?? 0
            return OverviewTrafficTrendPoint(
                bucketStart: bucketStart,
                date: startDate,
                xAxisPrimaryLabel: self.overviewRecentWeekTitle(offset: offset),
                xAxisSecondaryLabel: OverviewDateFormatting.compactRangeText(
                    start: startDate,
                    end: endDate,
                    languageMode: self.preferences.languageMode
                ),
                title: self.overviewRecentWeekTitle(offset: offset),
                detailText: OverviewDateFormatting.rangeText(
                    start: startDate,
                    end: endDate,
                    languageMode: self.preferences.languageMode
                ),
                totalTokens: self.combineOverviewTokenValues(inputTokens: inputTokens, outputTokens: outputTokens),
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheHitTokens: bucket?.cacheHitTokens ?? 0,
                cacheMissTokens: bucket?.cacheMissTokens ?? 0,
                requestCount: bucket?.requestCount ?? 0,
                isFuture: false
            )
        }
    }

    var overviewHasTrafficTrendData: Bool {
        self.stats.naturalTokenUsage.dailyTrend.contains { bucket in
            bucket.requestCount > 0 || bucket.inputTokens > 0 || bucket.outputTokens > 0 || bucket.cacheHitTokens > 0 || bucket.cacheMissTokens > 0
        } || self.stats.naturalTokenUsage.weeklyTrend.contains { bucket in
            bucket.requestCount > 0 || bucket.inputTokens > 0 || bucket.outputTokens > 0 || bucket.cacheHitTokens > 0 || bucket.cacheMissTokens > 0
        }
    }

    var overviewRecentFourWeeksRangeText: String {
        self.overviewRecentFourWeeksRangeText(now: Date(), calendar: .current)
    }

    func overviewRecentFourWeeksRangeText(
        now: Date,
        calendar: Calendar
    ) -> String {
        let options = self.overviewRecentWeekOptions(now: now, calendar: calendar)
        guard let oldest = options.last else { return "" }
        return OverviewDateFormatting.rangeText(
            start: oldest.startDate,
            end: options[0].endDate,
            languageMode: self.preferences.languageMode
        )
    }

    func overviewTooltipTokenText(_ value: Int64?) -> String {
        guard let value else { return self.text(.statusNoData) }
        return OverviewNumberFormat.abbreviated(value)
    }

    func overviewTooltipRequestCountText(_ value: Int64?) -> String {
        guard let value else { return self.text(.statusNoData) }
        return OverviewNumberFormat.full(value)
    }

    func overviewTrendPoint(
        for plotX: CGFloat,
        plotWidth: CGFloat,
        points: [OverviewTrafficTrendPoint]
    ) -> OverviewTrafficTrendPoint? {
        guard let index = self.overviewTrendPointIndex(for: plotX, plotWidth: plotWidth, pointCount: points.count) else {
            return nil
        }
        return points[index]
    }

    func overviewTrendPointIndex(
        for plotX: CGFloat,
        plotWidth: CGFloat,
        pointCount: Int
    ) -> Int? {
        guard plotWidth > 0, pointCount > 0 else { return nil }
        guard pointCount > 1 else { return 0 }

        let clampedX = min(max(plotX, 0), plotWidth)
        let step = plotWidth / CGFloat(pointCount - 1)
        guard step > 0 else { return nil }

        let rawIndex = Int((clampedX / step).rounded())
        return min(max(rawIndex, 0), pointCount - 1)
    }

    func overviewHoverBucketStart(
        current: Int64?,
        plotX: CGFloat?,
        plotWidth: CGFloat,
        points: [OverviewTrafficTrendPoint]
    ) -> Int64? {
        guard let plotX else { return nil }
        let nextBucketStart = self.overviewTrendPoint(
            for: plotX,
            plotWidth: plotWidth,
            points: points
        )?.bucketStart
        return nextBucketStart == current ? current : nextBucketStart
    }

    func overviewTrendPointXPosition(
        at index: Int,
        plotWidth: CGFloat,
        pointCount: Int
    ) -> CGFloat? {
        guard plotWidth > 0, pointCount > 0, index >= 0, index < pointCount else {
            return nil
        }
        guard pointCount > 1 else { return plotWidth / 2 }
        return (CGFloat(index) / CGFloat(pointCount - 1)) * plotWidth
    }

    private func overviewNaturalTokenCard(
        id: String,
        title: String,
        usage: AdminStatsSummary.NaturalRangeTokenUsage
    ) -> OverviewNaturalTokenCard {
        OverviewNaturalTokenCard(
            id: id,
            title: title,
            requestCount: usage.requestCount,
            totalTokens: usage.inputTokens + usage.outputTokens,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheHitTokens: usage.cacheHitTokens,
            cacheMissTokens: usage.cacheMissTokens
        )
    }

    private func combineOverviewTokenValues(
        inputTokens: Int64?,
        outputTokens: Int64?
    ) -> Int64? {
        guard let inputTokens, let outputTokens else { return nil }
        return inputTokens + outputTokens
    }

    private func overviewRecentWeekTitle(offset: Int) -> String {
        switch offset {
        case 0:
            return self.text(.optionThisWeek)
        case 1:
            return self.text(.optionLastWeek)
        case 2:
            return self.text(.optionTwoWeeksAgo)
        default:
            return self.text(.optionThreeWeeksAgo)
        }
    }

    private func overviewStartOfMondayWeek(
        for date: Date,
        calendar: Calendar
    ) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let offset = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -offset, to: startOfDay) ?? startOfDay
    }
}
#endif
