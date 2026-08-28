import Foundation

actor RateLimiter {
    struct WaitReservation: Sendable {
        let waitTime: TimeInterval
        let isProviderCooldown: Bool
    }

    private var lastRequestTime: Date = .distantPast
    private var providerCooldownUntil: Date = .distantPast
    private var consecutiveRateLimitCount: Int = 0

    func reserveWait(minimumInterval: TimeInterval, now: Date = Date()) -> WaitReservation {
        let intervalReadyAt = lastRequestTime.addingTimeInterval(minimumInterval)
        let nextRequestTime = max(intervalReadyAt, providerCooldownUntil)
        let computedWait = max(0, nextRequestTime.timeIntervalSince(now))
        let isProviderCooldown = providerCooldownUntil > now && providerCooldownUntil >= intervalReadyAt

        if computedWait > 0 {
            lastRequestTime = nextRequestTime
            return WaitReservation(waitTime: computedWait, isProviderCooldown: isProviderCooldown)
        }

        lastRequestTime = now
        return WaitReservation(waitTime: 0, isProviderCooldown: false)
    }

    func registerRateLimit(statusCode: Int, now: Date = Date()) -> TimeInterval {
        consecutiveRateLimitCount += 1
        let cooldownDuration = cooldownDuration(forStatusCode: statusCode, consecutiveRateLimitCount: consecutiveRateLimitCount)
        let cooldownUntil = now.addingTimeInterval(cooldownDuration)
        if cooldownUntil > providerCooldownUntil {
            providerCooldownUntil = cooldownUntil
        }
        return cooldownDuration
    }

    func registerSuccess(now: Date = Date()) {
        consecutiveRateLimitCount = 0
        if providerCooldownUntil < now {
            providerCooldownUntil = .distantPast
        }
        lastRequestTime = max(lastRequestTime, now)
    }

    func cooldownDuration(forStatusCode statusCode: Int, consecutiveRateLimitCount: Int) -> TimeInterval {
        let baseDuration: TimeInterval
        switch statusCode {
        case 429: baseDuration = 20
        case 421: baseDuration = 10
        default: return 0
        }
        let escalationMultiplier = min(max(consecutiveRateLimitCount - 1, 0), 3)
        return baseDuration * Double(1 + escalationMultiplier)
    }
}
