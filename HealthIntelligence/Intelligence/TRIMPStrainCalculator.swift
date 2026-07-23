//
//  TRIMPStrainCalculator.swift
//  HealthIntelligence
//
//  Cardiovascular Strain Score based on Banister's TRIMP (Training Impulse)
//  model, applied to non-workout heart-rate samples. Pure, deterministic
//  math over already-fetched data — no HealthKit dependency, so it's
//  directly unit-testable in isolation from HealthAnalyzer.
//
//  Scoring window: whatever range of samples the caller passes in. The app
//  currently passes today's samples (local midnight to now) — see
//  HealthAnalyzer.analyzeStrain — so the score should be read as "today so
//  far," not a rolling 24h window.
//

import Foundation

// MARK: - Inputs

enum StrainConfidence: Equatable, Sendable {
    case normal
    /// RHR baseline and/or max HR had to fall back to a default rather than
    /// a real measurement — the score is directionally useful but shouldn't
    /// be presented as precise.
    case low
}

/// The five HRR-fraction bands used for the zone breakdown (Step 5's
/// "user-facing zone chart" ask). Boundaries are inclusive of their lower
/// bound; the top zone also includes 1.0 exactly.
enum HeartRateZone: CaseIterable, Hashable, Sendable {
    case zone0to20
    case zone20to40
    case zone40to60
    case zone60to80
    case zone80to100

    static func containing(_ hrrFraction: Double) -> HeartRateZone {
        switch hrrFraction {
        case ..<0.2: .zone0to20
        case ..<0.4: .zone20to40
        case ..<0.6: .zone40to60
        case ..<0.8: .zone60to80
        default: .zone80to100
        }
    }
}

// MARK: - Output

struct StrainScoreResult: Sendable {
    /// 0...100, rounded to 1 decimal place.
    let strainScore: Double
    /// The raw summed TRIMP value before Step 5's compression — useful for
    /// debugging and for recalibrating `scalingConstant` against reference
    /// days.
    let totalTRIMP: Double
    let confidence: StrainConfidence
    /// Minutes of (capped) sample duration attributed to each HRR zone.
    let zoneBreakdownMinutes: [HeartRateZone: Double]
    /// The max HR actually used (measured override or age-based estimate).
    let heartRateMaximumUsed: Double
    /// The resting HR actually used (the passed-in baseline, or the default).
    let restingHeartRateUsed: Double
}

// MARK: - Calculator

struct TRIMPStrainCalculator {
    /// Scaling constant for Step 5's compression into the bounded 0–100
    /// scale. A tunable starting point, not a validated constant — expose
    /// it (rather than hardcoding it inline) so it can be recalibrated
    /// against real reference days to match subjective "hard day" intensity
    /// and max effort approaching 100.
    var scalingConstant: Double = 0.0055

    /// The upper bound of the compressed score. Exposed as a parameter
    /// (rather than hardcoded) for the same reason as `scalingConstant` —
    /// easy to retune or change scales later without touching the math.
    var scoreCeiling: Double = 100

    /// Per-sample duration is capped at this many minutes so a gap in data
    /// (watch removed, sync failure, etc.) doesn't get counted as sustained
    /// elevated-HR time.
    var maxSampleDurationMinutes: Double = 5

    /// Used only when no RHR baseline is available at all.
    var defaultRestingHeartRate: Double = 60

    /// Used only when no age and no measured max HR are available at all —
    /// a generic adult midpoint, not a personalized estimate.
    var defaultAgeAssumption: Int = 35

    init() {}

    /// - Parameters:
    ///   - heartRateSamples: Non-workout heart-rate samples for the scoring
    ///     window. Excluding workout samples is the caller's responsibility
    ///     (see HealthAnalyzer.analyzeStrain) — elevated HR during exercise
    ///     is expected physical workload, not the signal this score targets.
    ///   - restingHeartRateBaseline: The user's rolling personal RHR
    ///     baseline (not necessarily today's RHR — see file header).
    ///   - age: Whole years, from HealthKit characteristic data.
    ///   - sex: Selects the Banister exponent constant.
    ///   - measuredMaximumHeartRate: A directly known max HR, if ever
    ///     available, in preference to the age-based estimate.
    func calculate(
        heartRateSamples: [HealthMetricSample],
        restingHeartRateBaseline: Double?,
        age: Int?,
        sex: BiologicalSex,
        measuredMaximumHeartRate: Double?
    ) -> StrainScoreResult {
        var confidence: StrainConfidence = .normal

        // Step "0" (edge case) — missing RHR baseline.
        let restingHeartRate: Double
        if let restingHeartRateBaseline {
            restingHeartRate = restingHeartRateBaseline
        } else {
            restingHeartRate = defaultRestingHeartRate
            confidence = .low
        }

        // Step 1 — determine HRmax.
        let heartRateMaximum: Double
        if let measuredMaximumHeartRate {
            heartRateMaximum = measuredMaximumHeartRate
        } else {
            let assumedAge = age ?? defaultAgeAssumption
            if age == nil { confidence = .low }
            heartRateMaximum = 208 - (0.7 * Double(assumedAge))
        }

        let reserve = heartRateMaximum - restingHeartRate
        guard reserve > 0 else {
            // HRmax <= RHR: bad data. Reject rather than divide by a
            // zero/negative denominator — report zero strain, flagged low
            // confidence, instead of a nonsensical or crashing calculation.
            return StrainScoreResult(
                strainScore: 0,
                totalTRIMP: 0,
                confidence: .low,
                zoneBreakdownMinutes: Self.emptyZoneBreakdown(),
                heartRateMaximumUsed: heartRateMaximum,
                restingHeartRateUsed: restingHeartRate
            )
        }

        let k = Self.banisterConstant(for: sex)
        let sortedSamples = heartRateSamples.sorted { $0.startDate < $1.startDate }

        var totalTRIMP = 0.0
        var zoneMinutes = Self.emptyZoneBreakdown()
        var previousDate: Date?

        for sample in sortedSamples {
            // Step 3's duration term — time since the previous sample,
            // capped so gaps in data can't inflate the score. The first
            // sample in the window has no preceding sample to measure a
            // gap from, so it contributes zero duration rather than an
            // assumed one.
            let durationMinutes: Double
            if let previousDate {
                let deltaMinutes = sample.startDate.timeIntervalSince(previousDate) / 60
                durationMinutes = min(max(deltaMinutes, 0), maxSampleDurationMinutes)
            } else {
                durationMinutes = 0
            }
            previousDate = sample.startDate

            // Step 2 — HRR fraction, clamped so HR under the resting
            // reference (or over HRmax) can't push it outside [0, 1].
            let hrrFraction = min(max((sample.value - restingHeartRate) / reserve, 0), 1)

            // Step 3 — Banister exponential weighting.
            totalTRIMP += durationMinutes * hrrFraction * 0.64 * exp(k * hrrFraction)

            let zone = HeartRateZone.containing(hrrFraction)
            zoneMinutes[zone, default: 0] += durationMinutes
        }

        // Step 5 — compress to the bounded 0–100 scale.
        let strainScore = scoreCeiling * (1 - exp(-scalingConstant * totalTRIMP))

        return StrainScoreResult(
            strainScore: (strainScore * 10).rounded() / 10,
            totalTRIMP: totalTRIMP,
            confidence: confidence,
            zoneBreakdownMinutes: zoneMinutes,
            heartRateMaximumUsed: heartRateMaximum,
            restingHeartRateUsed: restingHeartRate
        )
    }

    private static func banisterConstant(for sex: BiologicalSex) -> Double {
        switch sex {
        case .male: 1.92
        case .female: 1.67
        case .unspecified: (1.92 + 1.67) / 2
        }
    }

    private static func emptyZoneBreakdown() -> [HeartRateZone: Double] {
        Dictionary(uniqueKeysWithValues: HeartRateZone.allCases.map { ($0, 0) })
    }
}
