import Foundation

public struct AmpWorkspaceBalance: Codable, Equatable, Sendable {
    public let name: String
    public let remaining: Double

    public init(name: String, remaining: Double) {
        self.name = name
        self.remaining = remaining
    }
}

public struct AmpSubscriptionUsage: Equatable, Sendable {
    public let plan: String
    public let otherUsedPercent: Double
    public let orbUsedPercent: Double?
    public let resetsAt: Date
    public let resetDescription: String
    public let agentRemaining: Double?
    public let agentLimit: Double?
    public let periodStart: Date?
    public let orbHoursRemaining: Double?
    public let orbHoursLimit: Double?

    public init(
        plan: String,
        otherUsedPercent: Double,
        orbUsedPercent: Double?,
        resetsAt: Date,
        resetDescription: String,
        agentRemaining: Double? = nil,
        agentLimit: Double? = nil,
        periodStart: Date? = nil,
        orbHoursRemaining: Double? = nil,
        orbHoursLimit: Double? = nil)
    {
        self.plan = plan
        self.otherUsedPercent = otherUsedPercent
        self.orbUsedPercent = orbUsedPercent
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.agentRemaining = agentRemaining
        self.agentLimit = agentLimit
        self.periodStart = periodStart
        self.orbHoursRemaining = orbHoursRemaining
        self.orbHoursLimit = orbHoursLimit
    }
}

public struct AmpUsageSnapshot: Sendable {
    public let freeQuota: Double?
    public let freeUsed: Double?
    public let hourlyReplenishment: Double?
    public let windowHours: Double?
    public let individualCredits: Double?
    public let workspaceBalances: [AmpWorkspaceBalance]
    public let accountEmail: String?
    public let accountOrganization: String?
    public let updatedAt: Date
    public let freeResetDescription: String?
    public let subscription: AmpSubscriptionUsage?

    public init(
        freeQuota: Double?,
        freeUsed: Double?,
        hourlyReplenishment: Double?,
        windowHours: Double?,
        individualCredits: Double? = nil,
        workspaceBalances: [AmpWorkspaceBalance] = [],
        accountEmail: String? = nil,
        accountOrganization: String? = nil,
        updatedAt: Date,
        freeResetDescription: String? = nil,
        subscription: AmpSubscriptionUsage? = nil)
    {
        self.freeQuota = freeQuota
        self.freeUsed = freeUsed
        self.hourlyReplenishment = hourlyReplenishment
        self.windowHours = windowHours
        self.individualCredits = individualCredits
        self.workspaceBalances = workspaceBalances
        self.accountEmail = accountEmail
        self.accountOrganization = accountOrganization
        self.updatedAt = updatedAt
        self.freeResetDescription = freeResetDescription
        self.subscription = subscription
    }
}

extension AmpUsageSnapshot {
    public func toUsageSnapshot(now: Date = Date()) -> UsageSnapshot {
        let freeWindow: RateWindow? = if let freeQuota, let freeUsed {
            {
                let quota = max(0, freeQuota)
                let used = max(0, freeUsed)
                let percent = quota > 0 ? min(100, (used / quota) * 100) : 0
                let windowMinutes: Int? = if let hours = self.windowHours, hours > 0 {
                    Int((hours * 60).rounded())
                } else {
                    nil
                }
                let resetsAt: Date? = {
                    if self.freeResetDescription == "resets daily" {
                        return Self.nextFreeTierReset(after: now)
                    }
                    guard quota > 0, let hourlyReplenishment, hourlyReplenishment > 0 else { return nil }
                    return now.addingTimeInterval(max(0, used / hourlyReplenishment * 3600))
                }()
                return RateWindow(
                    usedPercent: percent,
                    windowMinutes: windowMinutes,
                    resetsAt: resetsAt,
                    resetDescription: self.freeResetDescription)
            }()
        } else {
            nil
        }

        let subscriptionWindowMinutes = self.subscription.flatMap { usage -> Int? in
            if let start = usage.periodStart {
                return Int(usage.resetsAt.timeIntervalSince(start) / 60)
            }
            // Preserve legacy calendar-month pacing, but do not invent a Tier period when dates are missing.
            guard usage.agentRemaining == nil else { return nil }
            return ProviderPaceCapability.calendarMonthResetWindow.resolvedResetWindowForPace(RateWindow(
                usedPercent: usage.otherUsedPercent,
                windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
                resetsAt: usage.resetsAt,
                resetDescription: usage.resetDescription)).windowMinutes
        }
        let subscriptionPrimary = self.subscription.map { usage in
            RateWindow(
                usedPercent: usage.otherUsedPercent,
                windowMinutes: subscriptionWindowMinutes,
                resetsAt: usage.resetsAt,
                resetDescription: usage.resetDescription)
        }
        let subscriptionSecondary = self.subscription.flatMap { usage -> RateWindow? in
            guard let orbUsedPercent = usage.orbUsedPercent else { return nil }
            return RateWindow(
                usedPercent: orbUsedPercent,
                windowMinutes: subscriptionWindowMinutes,
                resetsAt: usage.resetsAt,
                resetDescription: usage.resetDescription)
        }
        let primary = subscriptionPrimary ?? freeWindow
        let extraRateWindows: [NamedRateWindow]? = if self.subscription != nil, let freeWindow {
            [NamedRateWindow(id: "amp-free", title: "Amp Free", window: freeWindow)]
        } else {
            nil
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .amp,
            accountEmail: self.accountEmail,
            accountOrganization: self.accountOrganization,
            loginMethod: self.subscription?.plan ?? (primary == nil ? "Amp" : "Amp Free"))

        var detailRows: [ProviderDetailSection.Row] = []
        if let remaining = self.subscription?.agentRemaining, let limit = self.subscription?.agentLimit {
            detailRows.append(.makeRow(
                label: "Agent credits",
                value: "\(UsageFormatter.usdString(remaining)) of \(UsageFormatter.usdString(limit)) remaining"))
        }
        if let individualCredits = self.individualCredits {
            detailRows.append(.makeRow(
                label: "Individual credits",
                value: UsageFormatter.usdString(individualCredits)))
        }
        detailRows.append(contentsOf: self.workspaceBalances.map {
            .makeRow(label: "Workspace \($0.name)", value: UsageFormatter.usdString($0.remaining))
        })

        var details: [ProviderDetailSection] = detailRows.isEmpty ? [] : [.makeSection(
            title: "Credits",
            rows: detailRows)]
        if let remaining = self.subscription?.orbHoursRemaining, let limit = self.subscription?.orbHoursLimit {
            let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
            details.append(.makeSection(title: "Orb allowance", rows: [.makeRow(
                label: "a1.small-equivalent hours",
                value: "\(remaining.formatted(format)) of \(limit.formatted(format)) remaining")]))
        }

        return UsageSnapshot(
            primary: primary,
            secondary: subscriptionSecondary,
            tertiary: nil,
            extraRateWindows: extraRateWindows,
            providerCost: nil,
            details: details,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private static func nextFreeTierReset(after date: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(identifier: "America/New_York") else { return nil }
        calendar.timeZone = timeZone
        return calendar.nextDate(
            after: date,
            matching: DateComponents(hour: 20),
            matchingPolicy: .nextTime)
    }
}
