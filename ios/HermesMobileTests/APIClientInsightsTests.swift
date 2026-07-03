import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientInsightsTests: APIClientTestCase {
    func testInsightsRequestBuildsDaysQueryAndDecodesServerAnalytics() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/insights")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["days"], "30")

            return apiTestJSONResponse("""
            {
              "period_days": 30,
              "total_sessions": 3,
              "total_messages": 12,
              "total_input_tokens": 1200,
              "total_output_tokens": 450,
              "total_tokens": 1650,
              "total_cost": 0.0323,
              "total_cache_read_tokens": 900,
              "total_cache_hit_percent": 87.5,
              "models": [
                {
                  "model": "gpt-5.5",
                  "sessions": 3,
                  "input_tokens": 1200,
                  "output_tokens": 450,
                  "total_tokens": 1650,
                  "cost": 0.0323,
                  "cache_hit_percent": 87.5,
                  "cache_read_tokens": 900,
                  "session_share": 100,
                  "token_share": 100,
                  "cost_share": 100
                }
              ],
              "daily_tokens": [
                {
                  "date": "2026-05-21",
                  "input_tokens": 1200,
                  "output_tokens": 450,
                  "sessions": 3,
                  "cost": 0.0323
                }
              ],
              "activity_by_day": [
                { "day": "Thu", "sessions": 3 }
              ],
              "activity_by_hour": [
                { "hour": 14, "sessions": 3 }
              ]
            }
            """, for: request)
        }

        let response = try await client.insights(days: 30)

        XCTAssertEqual(response.periodDays, 30)
        XCTAssertEqual(response.totalSessions, 3)
        XCTAssertEqual(response.totalMessages, 12)
        XCTAssertEqual(response.totalInputTokens, 1_200)
        XCTAssertEqual(response.totalOutputTokens, 450)
        XCTAssertEqual(response.totalTokens, 1_650)
        XCTAssertEqual(try XCTUnwrap(response.totalCost), 0.0323, accuracy: 0.0001)
        XCTAssertEqual(response.totalCacheReadTokens, 900)
        XCTAssertEqual(try XCTUnwrap(response.totalCacheHitPercent), 87.5, accuracy: 0.0001)
        XCTAssertEqual(response.models?.first?.model, "gpt-5.5")
        XCTAssertEqual(try XCTUnwrap(response.models?.first?.cacheHitPercent), 87.5, accuracy: 0.0001)
        XCTAssertEqual(response.models?.first?.costShare, 100)
        XCTAssertEqual(response.dailyTokens?.first?.date, "2026-05-21")
        XCTAssertEqual(response.activityByDay?.first?.day, "Thu")
        XCTAssertEqual(response.activityByHour?.first?.hour, 14)
    }

    func testInsightsResponseToleratesMissingArraysAndLossyCounts() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(
            InsightsResponse.self,
            from: Data("""
            {
              "period_days": "30",
              "total_sessions": "4",
              "total_cost": "$1.25",
              "models": "not an array",
              "daily_tokens": null,
              "activity_by_day": { "unexpected": true }
            }
            """.utf8)
        )

        XCTAssertEqual(response.periodDays, 30)
        XCTAssertEqual(response.totalSessions, 4)
        XCTAssertEqual(try XCTUnwrap(response.totalCost), 1.25, accuracy: 0.0001)
        XCTAssertNil(response.totalCacheReadTokens)
        XCTAssertNil(response.totalCacheHitPercent)
        XCTAssertNil(response.models)
        XCTAssertNil(response.dailyTokens)
        XCTAssertNil(response.activityByDay)
        XCTAssertNil(response.activityByHour)
    }

    func testInsightsResponseDecodesLossyCacheEfficiencyFields() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(
            InsightsResponse.self,
            from: Data("""
            {
              "total_cache_read_tokens": "900",
              "total_cache_hit_percent": "87.5",
              "models": [
                { "model": "gpt-5.5", "cache_hit_percent": 12 }
              ]
            }
            """.utf8)
        )

        XCTAssertEqual(response.totalCacheReadTokens, 900)
        XCTAssertEqual(try XCTUnwrap(response.totalCacheHitPercent), 87.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(response.models?.first?.cacheHitPercent), 12, accuracy: 0.0001)
    }

    func testInsightsFormattedPercentUsesAtMostOneFractionDigit() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(insightsFormattedPercent(87.5, locale: locale), "87.5%")
        XCTAssertEqual(insightsFormattedPercent(12, locale: locale), "12%")
        XCTAssertEqual(insightsFormattedPercent(0.19, locale: locale), "0.2%")
    }
}
