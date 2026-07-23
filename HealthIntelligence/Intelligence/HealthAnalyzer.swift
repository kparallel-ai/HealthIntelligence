//
//  HealthAnalyzer.swift
//  HealthIntelligence
//
//  Deterministic analysis of health data. Produces facts (a resting heart
//  rate is X% above baseline), not conclusions ("you are stressed").
//
//  Named "Strain" rather than "Stress" deliberately: Garmin syncs a limited
//  subset of its data into Apple Health, and HRV is not reliably part of
//  that subset. Without HRV, autonomic/psychological stress can't be
//  estimated responsibly — "strain" (how physiologically taxed the user
//  appears from heart rate and activity load alone) is what the available
//  data can actually support.
//
//  Strain has a real scoring model: a TRIMP (Training Impulse) calculation
//  over non-workout heart-rate samples — see TRIMPStrainCalculator.swift for
//  the full derivation. Deliberately no HRV. Sleep and Activity still only
//  have the output shapes and a couple of unambiguously-correct calculations
//  (averages, percentage deviation from a personal baseline); their scoring
//  models — sleep fragmentation, trend detection, recent load — are future
//  work and should slot into the `analyze...` functions below without
//  changing their signatures.
//

import Foundation

// MARK: - Analysis outputs

struct StrainAnalysis {
    // Resting heart rate vs. the user's rolling personal baseline. A simple
    // factual comparison, independent of the TRIMP score below (which uses
    // the baseline directly, not today's RHR — see TRIMPStrainCalculator).
    let restingHeartRate: Double?
    let baselineRestingHeartRate: Double?
    let percentageDeviationFromBaseline: Double?

    // Workouts in the analysis window. Their heart-rate samples are
    // excluded from the TRIMP calculation below — elevated HR during a
    // workout is expected physical workload, not the sustained
    // resting-state strain this score targets.
    let workouts: [Workout]

    // TRIMP-based cardiovascular Strain Score (Banister model), 0...100.
    let strain: StrainScoreResult
}

struct SleepAnalysis {
    let session: SleepSession?
    let totalTimeAsleep: TimeInterval?
    let totalTimeInBed: TimeInterval?
    let stageBreakdown: [SleepStage: TimeInterval]

    // Future: duration/fragmentation/stage-distribution relative to the
    // user's personal baseline, not fixed sleep-hygiene targets.
}

struct ActivityAnalysis {
    let totalStepsToday: Double
    let totalActiveEnergyToday: Double
    let baselineAverageDailySteps: Double?
    let percentageDeviationFromBaseline: Double?

    // Future: incorporate active-energy baseline and exercise minutes into
    // a combined activeness measure, not steps alone.
}

// MARK: - Analyzer

struct HealthAnalyzer {
    func analyzeStrain(
        todayRestingHeartRate: HealthMetricSample?,
        baselineRestingHeartRateSamples: [HealthMetricSample],
        todayHeartRateSamples: [HealthMetricSample],
        todayWorkouts: [Workout],
        age: Int?,
        biologicalSex: BiologicalSex,
        measuredMaximumHeartRate: Double?,
        strainCalculator: TRIMPStrainCalculator = TRIMPStrainCalculator()
    ) -> StrainAnalysis {
        let baseline = Self.average(baselineRestingHeartRateSamples.map(\.value))
        let today = todayRestingHeartRate?.value

        let nonWorkoutSamples = todayHeartRateSamples.filter { sample in
            !todayWorkouts.contains { $0.contains(sample.startDate) }
        }

        let strainResult = strainCalculator.calculate(
            heartRateSamples: nonWorkoutSamples,
            restingHeartRateBaseline: baseline,
            age: age,
            sex: biologicalSex,
            measuredMaximumHeartRate: measuredMaximumHeartRate
        )

        return StrainAnalysis(
            restingHeartRate: today,
            baselineRestingHeartRate: baseline,
            percentageDeviationFromBaseline: Self.percentageDeviation(value: today, from: baseline),
            workouts: todayWorkouts,
            strain: strainResult
        )
    }

    func analyzeSleep(mostRecentSession: SleepSession?) -> SleepAnalysis {
        guard let session = mostRecentSession else {
            return SleepAnalysis(session: nil, totalTimeAsleep: nil, totalTimeInBed: nil, stageBreakdown: [:])
        }

        var breakdown: [SleepStage: TimeInterval] = [:]
        for stage in SleepStage.allCases {
            let duration = session.totalDuration(for: stage)
            if duration > 0 { breakdown[stage] = duration }
        }

        return SleepAnalysis(
            session: session,
            totalTimeAsleep: session.totalTimeAsleep,
            totalTimeInBed: session.timeSpan,
            stageBreakdown: breakdown
        )
    }

    func analyzeActivity(
        todaySteps: [HealthMetricSample],
        todayActiveEnergy: [HealthMetricSample],
        baselineDailySteps: [Double]
    ) -> ActivityAnalysis {
        let totalSteps = todaySteps.reduce(0) { $0 + $1.value }
        let totalActiveEnergy = todayActiveEnergy.reduce(0) { $0 + $1.value }
        let baseline = Self.average(baselineDailySteps)

        return ActivityAnalysis(
            totalStepsToday: totalSteps,
            totalActiveEnergyToday: totalActiveEnergy,
            baselineAverageDailySteps: baseline,
            percentageDeviationFromBaseline: Self.percentageDeviation(value: totalSteps, from: baseline)
        )
    }

    // MARK: - Shared math

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func percentageDeviation(value: Double?, from baseline: Double?) -> Double? {
        guard let value, let baseline, baseline != 0 else { return nil }
        return ((value - baseline) / baseline) * 100
    }
}
