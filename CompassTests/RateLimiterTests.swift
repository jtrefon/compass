import XCTest
@testable import Compass

final class RateLimiterTests: XCTestCase {
    func testReserveWaitReturnsZeroWhenNoRecentRequest() async {
        let limiter = RateLimiter()
        let reservation = await limiter.reserveWait(minimumInterval: 1.0, now: Date())
        XCTAssertEqual(reservation.waitTime, 0)
        XCTAssertFalse(reservation.isProviderCooldown)
    }

    func testReserveWaitReturnsIntervalWhenRequestWithinCooldown() async {
        let limiter = RateLimiter()
        let now = Date()
        _ = await limiter.reserveWait(minimumInterval: 1.0, now: now)
        let reservation = await limiter.reserveWait(minimumInterval: 1.0, now: now.addingTimeInterval(0.3))
        XCTAssertGreaterThan(reservation.waitTime, 0.5)
        XCTAssertFalse(reservation.isProviderCooldown)
    }

    func testReserveWaitReturnsZeroWhenIntervalElapsed() async {
        let limiter = RateLimiter()
        let now = Date()
        _ = await limiter.reserveWait(minimumInterval: 0.5, now: now)
        let reservation = await limiter.reserveWait(minimumInterval: 0.5, now: now.addingTimeInterval(1.0))
        XCTAssertEqual(reservation.waitTime, 0)
        XCTAssertFalse(reservation.isProviderCooldown)
    }

    func testRegisterRateLimitActivatesProviderCooldown() async {
        let limiter = RateLimiter()
        let now = Date()
        let duration = await limiter.registerRateLimit(statusCode: 429, now: now)
        XCTAssertEqual(duration, 20)
        let reservation = await limiter.reserveWait(minimumInterval: 0, now: now.addingTimeInterval(5))
        XCTAssertGreaterThan(reservation.waitTime, 0)
        XCTAssertTrue(reservation.isProviderCooldown)
    }

    func testRegisterSuccessResetsCooldown() async {
        let limiter = RateLimiter()
        let now = Date()
        _ = await limiter.registerRateLimit(statusCode: 429, now: now)
        await limiter.registerSuccess(now: now.addingTimeInterval(25))
        let reservation = await limiter.reserveWait(minimumInterval: 0, now: now.addingTimeInterval(25))
        XCTAssertEqual(reservation.waitTime, 0)
        XCTAssertFalse(reservation.isProviderCooldown)
    }

    func testConsecutiveRateLimitsEscalateDuration() async {
        let limiter = RateLimiter()
        let now = Date()
        let d1 = await limiter.registerRateLimit(statusCode: 429, now: now)
        let d2 = await limiter.registerRateLimit(statusCode: 429, now: now.addingTimeInterval(30))
        let d3 = await limiter.registerRateLimit(statusCode: 429, now: now.addingTimeInterval(70))
        let d4 = await limiter.registerRateLimit(statusCode: 429, now: now.addingTimeInterval(120))
        let d5 = await limiter.registerRateLimit(statusCode: 429, now: now.addingTimeInterval(200))
        XCTAssertEqual(d1, 20)
        XCTAssertEqual(d2, 40)
        XCTAssertEqual(d3, 60)
        XCTAssertEqual(d4, 80)
        XCTAssertEqual(d5, 80)  // capped at 4x base
    }

    func testRateLimit421GetsShorterCooldown() async {
        let limiter = RateLimiter()
        let now = Date()
        let duration = await limiter.registerRateLimit(statusCode: 421, now: now)
        XCTAssertEqual(duration, 10)
    }

    func testNonRateLimitStatusCodesReturnZero() async {
        let limiter = RateLimiter()
        let now = Date()
        let duration = await limiter.registerRateLimit(statusCode: 500, now: now)
        XCTAssertEqual(duration, 0)
    }

    func testCooldownDurationComputation() async {
        let limiter = RateLimiter()
        let d1 = await limiter.cooldownDuration(forStatusCode: 429, consecutiveRateLimitCount: 1)
        let d2 = await limiter.cooldownDuration(forStatusCode: 429, consecutiveRateLimitCount: 2)
        let d3 = await limiter.cooldownDuration(forStatusCode: 429, consecutiveRateLimitCount: 4)
        let d4 = await limiter.cooldownDuration(forStatusCode: 429, consecutiveRateLimitCount: 10)
        XCTAssertEqual(d1, 20)
        XCTAssertEqual(d2, 40)
        XCTAssertEqual(d3, 80)
        XCTAssertEqual(d4, 80)  // capped at 4x
    }
}
