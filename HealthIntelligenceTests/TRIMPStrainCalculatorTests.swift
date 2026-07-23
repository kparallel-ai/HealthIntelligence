//
//  TRIMPStrainCalculatorTests.swift
//  HealthIntelligenceTests
//
//  Coverage for the TRIMP-based Strain Score: resting/near-zero, a bounded
//  single-workout range, the high end approaching the 0-100 ceiling, and the
//  explicit edge cases from the spec (missing RHR, gappy data, bad HRmax).
//

import XCTest
@testable import HealthIntelligence

final class TRIMPStrainCalculatorTests: XCTestCase {
    private let calculator = TRIMPStrainCalculator()
    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(at date: Date, bpm: Double) -> HealthMetricSample {
        HealthMetricSample(
            type: .heartRate,
            value: bpm,
            startDate: date,
            endDate: date,
            source: HealthSource(name: "Test", bundleIdentifier: "com.test.source")
        )
    }

    /// Evenly spaced constant-HR samples — a simple way to simulate a
    /// sustained period (resting, a workout, or an all-day exertion level)
    /// without needing real device data.
    private func constantHeartRateSamples(bpm: Double, count: Int, intervalMinutes: Double) -> [HealthMetricSample] {
        (0..<count).map { i in
            sample(at: referenceDate.addingTimeInterval(Double(i) * intervalMinutes * 60), bpm: bpm)
        }
    }

    // MARK: - Resting day

    func test_restingDay_producesNearZeroStrain() {
        // 24 hours of HR essentially at RHR — nothing for TRIMP to accumulate.
        let samples = constantHeartRateSamples(bpm: 60, count: 48, intervalMinutes: 30)

        let result = calculator.calculate(
            heartRateSamples: samples,
            restingHeartRateBaseline: 60,
            age: 30,
            sex: .male,
            measuredMaximumHeartRate: 190
        )

        XCTAssertEqual(result.strainScore, 0, accuracy: 0.05)
        XCTAssertEqual(result.totalTRIMP, 0, accuracy: 0.01)
        XCTAssertEqual(result.confidence, .normal)
    }

    // MARK: - Single hard workout

    func test_singleHardWorkout_producesStrainInExpectedRange() {
        // ~60 minutes at ~85% heart-rate reserve — a hard, but not
        // all-day, effort. In the real pipeline this HR data would be
        // excluded from the non-workout signal by HealthAnalyzer; here
        // we're testing the calculator's math directly against a
        // representative sustained-high-HRR profile.
        let samples = constantHeartRateSamples(bpm: 171, count: 61, intervalMinutes: 1)

        let result = calculator.calculate(
            heartRateSamples: samples,
            restingHeartRateBaseline: 60,
            age: 30,
            sex: .male,
            measuredMaximumHeartRate: 190
        )

        // Equivalent to the 10-16 range on the original 0-21 scale, rescaled
        // to 0-100.
        let expectedRange = (10.0 / 21 * 100)...(16.0 / 21 * 100)
        XCTAssertTrue(
            expectedRange.contains(result.strainScore),
            "Expected a hard ~60min workout to land in \(expectedRange), got \(result.strainScore)"
        )
        XCTAssertEqual(result.confidence, .normal)

        // With HRR essentially constant at ~85%, nearly all the counted
        // duration should land in the top zone.
        let topZoneMinutes = result.zoneBreakdownMinutes[.zone80to100] ?? 0
        XCTAssertEqual(topZoneMinutes, 60, accuracy: 1)
    }

    // MARK: - All-day high exertion

    func test_allDayHighExertion_approachesCeiling() {
        // 16 hours at ~46% HRR — sustaining 70%+ HRR for a full day isn't
        // physiologically realistic, but a long day of hard, continuous
        // physical activity (e.g. manual labor, a long hike) at this level
        // is. Should push the bounded score close to its 100 ceiling without
        // reaching it (the compression is asymptotic).
        let samples = constantHeartRateSamples(bpm: 120, count: 960, intervalMinutes: 1)

        let result = calculator.calculate(
            heartRateSamples: samples,
            restingHeartRateBaseline: 60,
            age: 30,
            sex: .male,
            measuredMaximumHeartRate: 190
        )

        // Equivalent to the (19, 21) bounds on the original 0-21 scale.
        XCTAssertGreaterThan(result.strainScore, 19.0 / 21 * 100)
        XCTAssertLessThan(result.strainScore, 100)
    }

    // MARK: - Missing RHR baseline

    func test_missingRestingHeartRateBaseline_fallsBackAndFlagsLowConfidence() {
        let samples = constantHeartRateSamples(bpm: 100, count: 10, intervalMinutes: 5)

        let result = calculator.calculate(
            heartRateSamples: samples,
            restingHeartRateBaseline: nil,
            age: 30,
            sex: .male,
            measuredMaximumHeartRate: 190
        )

        XCTAssertEqual(result.confidence, .low)
        XCTAssertEqual(result.restingHeartRateUsed, calculator.defaultRestingHeartRate)
    }

    func test_missingAgeAndMeasuredMaxHeartRate_fallsBackAndFlagsLowConfidence() {
        let samples = constantHeartRateSamples(bpm: 100, count: 10, intervalMinutes: 5)

        let result = calculator.calculate(
            heartRateSamples: samples,
            restingHeartRateBaseline: 60,
            age: nil,
            sex: .male,
            measuredMaximumHeartRate: nil
        )

        XCTAssertEqual(result.confidence, .low)
        XCTAssertEqual(
            result.heartRateMaximumUsed,
            208 - (0.7 * Double(calculator.defaultAgeAssumption)),
            accuracy: 0.01
        )
    }

    // MARK: - Gappy data

    func test_gappyData_capsDurationAcrossLargeGaps() {
        // Two samples 3 hours apart. Without capping, the second sample
        // would be credited with 180 minutes of elevated HR from a single
        // reading; the cap should limit it to `maxSampleDurationMinutes`.
        let first = sample(at: referenceDate, bpm: 150)
        let second = sample(at: referenceDate.addingTimeInterval(3 * 60 * 60), bpm: 150)

        let result = calculator.calculate(
            heartRateSamples: [first, second],
            restingHeartRateBaseline: 60,
            age: 30,
            sex: .male,
            measuredMaximumHeartRate: 190
        )

        let hrrFraction = (150.0 - 60) / (190.0 - 60) // 0.6923...
        let expectedTRIMP = calculator.maxSampleDurationMinutes * hrrFraction * 0.64 * exp(1.92 * hrrFraction)

        XCTAssertEqual(result.totalTRIMP, expectedTRIMP, accuracy: 0.01)

        // Sanity check that this is indeed much less than the uncapped
        // (180-minute) contribution would have been.
        let uncappedTRIMP = 180.0 * hrrFraction * 0.64 * exp(1.92 * hrrFraction)
        XCTAssertLessThan(result.totalTRIMP, uncappedTRIMP / 10)
    }

    // MARK: - Invalid HRmax

    func test_maxHeartRateAtOrBelowRestingHeartRate_rejectsRatherThanCrashing() {
        let samples = constantHeartRateSamples(bpm: 100, count: 5, intervalMinutes: 1)

        let result = calculator.calculate(
            heartRateSamples: samples,
            restingHeartRateBaseline: 60,
            age: 30,
            sex: .male,
            measuredMaximumHeartRate: 55 // invalid: below RHR
        )

        XCTAssertEqual(result.strainScore, 0)
        XCTAssertEqual(result.totalTRIMP, 0)
        XCTAssertEqual(result.confidence, .low)
    }

    // MARK: - Sex-based exponent constant

    func test_maleAndFemaleConstantsProduceDifferentTRIMPForSameSamples() {
        let samples = constantHeartRateSamples(bpm: 150, count: 21, intervalMinutes: 1)

        let maleResult = calculator.calculate(
            heartRateSamples: samples,
            restingHeartRateBaseline: 60,
            age: 30,
            sex: .male,
            measuredMaximumHeartRate: 190
        )
        let femaleResult = calculator.calculate(
            heartRateSamples: samples,
            restingHeartRateBaseline: 60,
            age: 30,
            sex: .female,
            measuredMaximumHeartRate: 190
        )

        // Male's k (1.92) > female's k (1.67), so for the same HRR > 0 the
        // exponential weighting — and therefore total TRIMP — should be larger.
        XCTAssertGreaterThan(maleResult.totalTRIMP, femaleResult.totalTRIMP)
    }
}
