//
//  HealthKitService.swift
//  HealthIntelligence
//
//  The boundary between HealthKit and the rest of the app. Everything here
//  speaks HKObjectType/HKSample; everything it returns speaks HealthModels.
//  No analysis happens in this file.
//

import Foundation
import HealthKit

enum HealthKitServiceError: LocalizedError {
    case notAvailable
    case dataTypeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            "Health data is not available on this device."
        case .dataTypeUnavailable(let name):
            "\(name) is not available through HealthKit on this device."
        }
    }
}

final class HealthKitService {
    private let healthStore = HKHealthStore()

    var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// Requests read access for every metric the app currently uses.
    ///
    /// Important HealthKit constraint: for *read-only* types, HealthKit
    /// deliberately does not reveal whether the user granted or denied
    /// access (this is a privacy feature, not a bug) — `authorizationStatus`
    /// only tells the truth for share/write types. As a result this method
    /// can only tell you the *request* completed, not whether any given
    /// type is actually readable. Callers must treat "no samples returned"
    /// as ambiguous between "denied" and "genuinely no data."
    func requestAuthorization() async throws {
        guard isHealthDataAvailable else { throw HealthKitServiceError.notAvailable }

        // Explicitly typed as [HKObjectType?] so HKObjectType.workoutType()
        // (non-optional) and the forIdentifier: lookups (optional) unify
        // into one array without fragile literal-inference surprises.
        let candidateTypes: [HKObjectType?] = [
            HKObjectType.quantityType(forIdentifier: .heartRate),
            HKObjectType.quantityType(forIdentifier: .restingHeartRate),
            HKObjectType.quantityType(forIdentifier: .stepCount),
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
            HKObjectType.quantityType(forIdentifier: .basalEnergyBurned),
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
            HKObjectType.characteristicType(forIdentifier: .dateOfBirth),
            HKObjectType.characteristicType(forIdentifier: .biologicalSex),
            HKObjectType.workoutType(),
        ]
        let readTypes = Set(candidateTypes.compactMap { $0 })

        _ = try await healthStore.requestAuthorization(toShare: [], read: readTypes)
    }

    // MARK: - Quantity samples

    func heartRateSamples(from start: Date, to end: Date) async throws -> [HealthMetricSample] {
        try await quantitySamples(
            identifier: .heartRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            metricType: .heartRate,
            start: start,
            end: end
        )
    }

    func restingHeartRateSamples(from start: Date, to end: Date) async throws -> [HealthMetricSample] {
        try await quantitySamples(
            identifier: .restingHeartRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            metricType: .restingHeartRate,
            start: start,
            end: end
        )
    }

    func stepSamples(from start: Date, to end: Date) async throws -> [HealthMetricSample] {
        try await quantitySamples(
            identifier: .stepCount,
            unit: .count(),
            metricType: .steps,
            start: start,
            end: end
        )
    }

    func activeEnergySamples(from start: Date, to end: Date) async throws -> [HealthMetricSample] {
        try await quantitySamples(
            identifier: .activeEnergyBurned,
            unit: .kilocalorie(),
            metricType: .activeEnergyBurned,
            start: start,
            end: end
        )
    }

    func basalEnergySamples(from start: Date, to end: Date) async throws -> [HealthMetricSample] {
        try await quantitySamples(
            identifier: .basalEnergyBurned,
            unit: .kilocalorie(),
            metricType: .basalEnergyBurned,
            start: start,
            end: end
        )
    }

    private func quantitySamples(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        metricType: HealthMetricType,
        start: Date,
        end: Date
    ) async throws -> [HealthMetricSample] {
        guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else {
            throw HealthKitServiceError.dataTypeUnavailable(metricType.displayName)
        }

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: quantityType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )

        let samples = try await descriptor.result(for: healthStore)
        return samples.map { sample in
            HealthMetricSample(
                type: metricType,
                value: sample.quantity.doubleValue(for: unit),
                startDate: sample.startDate,
                endDate: sample.endDate,
                source: HealthSource(sample: sample)
            )
        }
    }

    // MARK: - Sleep

    /// Fetches sleep-stage segments in the given range and groups them into
    /// sessions. Segments less than an hour apart are treated as the same
    /// night's sleep; this is a heuristic, not something HealthKit tells us
    /// directly, and may need tuning once tested against real Garmin data
    /// (multiple sources can write overlapping or gapped segments for one
    /// night).
    func sleepSessions(from start: Date, to end: Date) async throws -> [SleepSession] {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthKitServiceError.dataTypeUnavailable("Sleep")
        }

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: sleepType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )

        let samples = try await descriptor.result(for: healthStore)
        let segments = samples.compactMap { sample -> SleepStageSegment? in
            guard let stage = SleepStage(categoryValue: sample.value) else { return nil }
            return SleepStageSegment(
                stage: stage,
                startDate: sample.startDate,
                endDate: sample.endDate,
                source: HealthSource(sample: sample)
            )
        }

        return Self.groupIntoSessions(segments)
    }

    private static func groupIntoSessions(_ segments: [SleepStageSegment]) -> [SleepSession] {
        guard !segments.isEmpty else { return [] }

        let gapThreshold: TimeInterval = 60 * 60
        let sorted = segments.sorted { $0.startDate < $1.startDate }

        var sessions: [[SleepStageSegment]] = []
        var current: [SleepStageSegment] = [sorted[0]]

        for segment in sorted.dropFirst() {
            if let lastEnd = current.last?.endDate,
                segment.startDate.timeIntervalSince(lastEnd) <= gapThreshold {
                current.append(segment)
            } else {
                sessions.append(current)
                current = [segment]
            }
        }
        sessions.append(current)

        return sessions.map { SleepSession(segments: $0) }
    }

    // MARK: - Workouts

    /// Fetches workouts in the given range so the analyzer can exclude their
    /// heart-rate samples from the non-exercise strain signal.
    func workouts(from start: Date, to end: Date) async throws -> [Workout] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )

        let samples = try await descriptor.result(for: healthStore)
        let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)

        return samples.map { workout in
            Workout(
                activityName: workout.workoutActivityType.displayName,
                startDate: workout.startDate,
                endDate: workout.endDate,
                totalActiveEnergyBurned: energyType.flatMap {
                    workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .kilocalorie())
                },
                source: HealthSource(sample: workout)
            )
        }
    }

    // MARK: - Characteristic data

    /// The user's age in whole years, from HealthKit's characteristic data
    /// (date of birth, set in the Health app's profile). `nil` if
    /// unavailable or unauthorized — callers should treat that as "estimate
    /// max heart rate conservatively," not crash or guess silently.
    func age() -> Int? {
        guard let birthDateComponents = try? healthStore.dateOfBirthComponents(),
            let birthYear = birthDateComponents.year else { return nil }

        let age = Calendar.current.component(.year, from: Date()) - birthYear
        return age > 0 ? age : nil
    }

    /// The user's biological sex from HealthKit's characteristic data (set
    /// in the Health app's profile). Used only to select the Banister TRIMP
    /// exponent constant in the Strain calculation.
    func biologicalSex() -> BiologicalSex {
        guard let sex = try? healthStore.biologicalSex().biologicalSex else { return .unspecified }
        switch sex {
        case .male: return .male
        case .female: return .female
        case .other, .notSet: return .unspecified
        @unknown default: return .unspecified
        }
    }
}

// MARK: - HealthKit -> app model conversions

private extension HealthSource {
    init(sample: HKSample) {
        self.init(
            name: sample.sourceRevision.source.name,
            bundleIdentifier: sample.sourceRevision.source.bundleIdentifier
        )
    }
}

private extension SleepStage {
    init?(categoryValue: Int) {
        guard let value = HKCategoryValueSleepAnalysis(rawValue: categoryValue) else { return nil }
        switch value {
        case .inBed: self = .inBed
        case .awake: self = .awake
        case .asleepCore: self = .core
        case .asleepDeep: self = .deep
        case .asleepREM: self = .rem
        case .asleepUnspecified: self = .unspecified
        @unknown default: self = .unspecified
        }
    }
}

private extension HKWorkoutActivityType {
    /// A short, readable label for common activity types. HealthKit doesn't
    /// provide one itself, and the identifier list spans 100+ cases across
    /// OS versions — this covers the common ones and falls back to a
    /// generic label for the rest, including whatever Garmin's HealthKit
    /// writer maps its own activity types to (not publicly documented).
    var displayName: String {
        switch self {
        case .running: "Running"
        case .walking: "Walking"
        case .cycling: "Cycling"
        case .swimming: "Swimming"
        case .hiking: "Hiking"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "Strength Training"
        case .yoga: "Yoga"
        case .coreTraining: "Core Training"
        case .elliptical: "Elliptical"
        case .rowing: "Rowing"
        case .stairClimbing: "Stair Climbing"
        case .highIntensityIntervalTraining: "HIIT"
        default: "Workout"
        }
    }
}
