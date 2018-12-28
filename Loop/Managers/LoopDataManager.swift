//
//  LoopDataManager.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 3/12/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit


final class LoopDataManager {
    enum LoopUpdateContext: Int {
        case bolus
        case carbs
        case glucose
        case preferences
        case tempBasal
    }

    static let LoopUpdateContextKey = "com.loudnate.Loop.LoopDataManager.LoopUpdateContext"

    let carbStore: CarbStore

    let doseStore: DoseStore

    let glucoseStore: GlucoseStore

    weak var delegate: LoopDataManagerDelegate?
    
    private let standardCorrectionEffectDuration = TimeInterval.minutes(60.0)
    
    private let integralRC: IntegralRetrospectiveCorrection
    
    private let standardRC: StandardRetrospectiveCorrection

    private let logger: CategoryLogger
    
    var suggestedCarbCorrection: Int?

    // References to registered notification center observers
    private var notificationObservers: [Any] = []

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // Make overall retrospective effect available for display to the user
    var totalRetrospectiveCorrection: HKQuantity?
    
    /* dm61 wip parameter estimation
    typealias Effects = (date: Date, discrepancy: Double, insulinEffect: Double, carbEffect: Double)
    // array of effects used in parameter estimation calculations
    var pastEffectsForEstimation: [Effects]
    */

    init(
        lastLoopCompleted: Date?,
        lastTempBasal: DoseEntry?,
        basalRateSchedule: BasalRateSchedule? = UserDefaults.appGroup.basalRateSchedule,
        carbRatioSchedule: CarbRatioSchedule? = UserDefaults.appGroup.carbRatioSchedule,
        insulinModelSettings: InsulinModelSettings? = UserDefaults.appGroup.insulinModelSettings,
        insulinSensitivitySchedule: InsulinSensitivitySchedule? = UserDefaults.appGroup.insulinSensitivitySchedule,
        settings: LoopSettings = UserDefaults.appGroup.loopSettings ?? LoopSettings()
    ) {
        self.logger = DiagnosticLogger.shared.forCategory("LoopDataManager")
        self.lockedLastLoopCompleted = Locked(lastLoopCompleted)
        self.lastTempBasal = lastTempBasal
        self.settings = settings

        let healthStore = HKHealthStore()
        let cacheStore = PersistenceController.controllerInAppGroupDirectory()

        carbStore = CarbStore(
            healthStore: healthStore,
            cacheStore: cacheStore,
            defaultAbsorptionTimes: (
                fast: TimeInterval(hours: 2),
                medium: TimeInterval(hours: 3),
                slow: TimeInterval(hours: 4)
            ),
            carbRatioSchedule: carbRatioSchedule,
            insulinSensitivitySchedule: insulinSensitivitySchedule
        )
        
        totalRetrospectiveCorrection = nil
        
        doseStore = DoseStore(
            healthStore: healthStore,
            cacheStore: cacheStore,
            insulinModel: insulinModelSettings?.model,
            basalProfile: basalRateSchedule,
            insulinSensitivitySchedule: insulinSensitivitySchedule
        )

        glucoseStore = GlucoseStore(healthStore: healthStore, cacheStore: cacheStore, cacheLength: .hours(24))

        integralRC = IntegralRetrospectiveCorrection(standardCorrectionEffectDuration)
        
        standardRC = StandardRetrospectiveCorrection(standardCorrectionEffectDuration)
        
        // dm61 wip parameter estimation
        // self.pastEffectsForEstimation = []
        
        cacheStore.delegate = self

        // Observe changes
        notificationObservers = [
            NotificationCenter.default.addObserver(
                forName: .CarbEntriesDidUpdate,
                object: carbStore,
                queue: nil
            ) { (note) -> Void in
                self.dataAccessQueue.async {
                    self.logger.info("Received notification of carb entries updating")

                    self.carbEffect = nil
                    self.carbsOnBoard = nil
                    self.notify(forChange: .carbs)
                }
            },
            NotificationCenter.default.addObserver(
                forName: .GlucoseSamplesDidChange,
                object: glucoseStore,
                queue: nil
            ) { (note) in
                self.dataAccessQueue.async {
                    self.logger.info("Received notification of glucose samples changing")

                    self.glucoseMomentumEffect = nil

                    self.notify(forChange: .glucose)
                }
            }
        ]
    }

    /// Loop-related settings
    ///
    /// These are not thread-safe.
    var settings: LoopSettings {
        didSet {
            UserDefaults.appGroup.loopSettings = settings
            suggestedCarbCorrection = nil
            notify(forChange: .preferences)
            AnalyticsManager.shared.didChangeLoopSettings(from: oldValue, to: settings)
        }
    }

    // MARK: - Calculation state

    fileprivate let dataAccessQueue: DispatchQueue = DispatchQueue(label: "com.loudnate.Naterade.LoopDataManager.dataAccessQueue", qos: .utility)

    private var carbEffect: [GlucoseEffect]? {
        didSet {
            predictedGlucose = nil

            // Carb data may be back-dated, so re-calculate the retrospective glucose.
            retrospectiveGlucoseDiscrepancies = nil
        }
    }
    private var insulinEffect: [GlucoseEffect]? {
        didSet {
            predictedGlucose = nil
        }
    }
    private var glucoseMomentumEffect: [GlucoseEffect]? {
        didSet {
            predictedGlucose = nil
        }
    }
    private var retrospectiveGlucoseEffect: [GlucoseEffect] = [] {
        didSet {
            predictedGlucose = nil
        }
    }

    private var retrospectiveGlucoseDiscrepancies: [GlucoseEffect]? {
        didSet {
            retrospectiveGlucoseDiscrepanciesSummed = retrospectiveGlucoseDiscrepancies?.combinedSums(of: settings.retrospectiveCorrectionGroupingInterval * 1.01)
        }
    }
    private var retrospectiveGlucoseDiscrepanciesSummed: [GlucoseChange]?

    private var zeroTempEffect: [GlucoseEffect] = []
    
    fileprivate var predictedGlucose: [GlucoseValue]? {
        didSet {
            recommendedTempBasal = nil
            recommendedBolus = nil
            recommendedSuperBolus = nil
        }
    }

    fileprivate var recommendedTempBasal: (recommendation: TempBasalRecommendation, date: Date)?
    fileprivate var recommendedBolus: (recommendation: BolusRecommendation, date: Date)?
    fileprivate var recommendedSuperBolus: (recommendation: BolusRecommendation, date: Date)?

    fileprivate var carbsOnBoard: CarbValue?

    fileprivate var lastTempBasal: DoseEntry?
    fileprivate var lastRequestedBolus: (units: Double, date: Date)?

    /// The last date at which a loop completed, from prediction to dose (if dosing is enabled)
    var lastLoopCompleted: Date? {
        get {
            return lockedLastLoopCompleted.value
        }
        set {
            lockedLastLoopCompleted.value = newValue

            NotificationManager.clearLoopNotRunningNotifications()
            NotificationManager.scheduleLoopNotRunningNotifications()
            AnalyticsManager.shared.loopDidSucceed()
            self.suggestedCarbCorrection = nil
        }
    }
    private let lockedLastLoopCompleted: Locked<Date?>

    fileprivate var lastLoopError: Error? {
        didSet {
            if lastLoopError != nil {
                AnalyticsManager.shared.loopDidError()
            }
        }
    }

    /// A timeline of average velocity of glucose change counteracting predicted insulin effects
    fileprivate var insulinCounteractionEffects: [GlucoseEffectVelocity] = [] {
        didSet {
            carbEffect = nil
            carbsOnBoard = nil
        }
    }

    // MARK: - Background task management

    private var backgroundTask: UIBackgroundTaskIdentifier = UIBackgroundTaskInvalid

    private func startBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PersistenceController save") {
            self.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != UIBackgroundTaskInvalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = UIBackgroundTaskInvalid
        }
    }
}

// MARK: Background task management
extension LoopDataManager: PersistenceControllerDelegate {
    func persistenceControllerWillSave(_ controller: PersistenceController) {
        startBackgroundTask()
    }

    func persistenceControllerDidSave(_ controller: PersistenceController, error: PersistenceController.PersistenceControllerError?) {
        endBackgroundTask()
    }
}

// MARK: - Preferences
extension LoopDataManager {

    /// The daily schedule of basal insulin rates
    var basalRateSchedule: BasalRateSchedule? {
        get {
            return doseStore.basalProfile
        }
        set {
            doseStore.basalProfile = newValue
            UserDefaults.appGroup.basalRateSchedule = newValue
            notify(forChange: .preferences)

            if let newValue = newValue, let oldValue = doseStore.basalProfile, newValue.items != oldValue.items {
                AnalyticsManager.shared.didChangeBasalRateSchedule()
            }
        }
    }

    /// The daily schedule of carbs-to-insulin ratios
    /// This is measured in grams/Unit
    var carbRatioSchedule: CarbRatioSchedule? {
        get {
            return carbStore.carbRatioSchedule
        }
        set {
            carbStore.carbRatioSchedule = newValue
            UserDefaults.appGroup.carbRatioSchedule = newValue

            // Invalidate cached effects based on this schedule
            carbEffect = nil
            carbsOnBoard = nil

            notify(forChange: .preferences)
        }
    }

    /// The length of time insulin has an effect on blood glucose
    var insulinModelSettings: InsulinModelSettings? {
        get {
            guard let model = doseStore.insulinModel else {
                return nil
            }

            return InsulinModelSettings(model: model)
        }
        set {
            doseStore.insulinModel = newValue?.model
            UserDefaults.appGroup.insulinModelSettings = newValue

            self.dataAccessQueue.async {
                // Invalidate cached effects based on this schedule
                self.insulinEffect = nil

                self.notify(forChange: .preferences)
            }

            AnalyticsManager.shared.didChangeInsulinModel()
        }
    }

    /// The daily schedule of insulin sensitivity (also known as ISF)
    /// This is measured in <blood glucose>/Unit
    var insulinSensitivitySchedule: InsulinSensitivitySchedule? {
        get {
            return carbStore.insulinSensitivitySchedule
        }
        set {
            carbStore.insulinSensitivitySchedule = newValue
            doseStore.insulinSensitivitySchedule = newValue

            UserDefaults.appGroup.insulinSensitivitySchedule = newValue

            dataAccessQueue.async {
                // Invalidate cached effects based on this schedule
                self.carbEffect = nil
                self.carbsOnBoard = nil
                self.insulinEffect = nil

                self.notify(forChange: .preferences)
            }
        }
    }

    /// Sets a new time zone for a the schedule-based settings
    ///
    /// - Parameter timeZone: The time zone
    func setScheduleTimeZone(_ timeZone: TimeZone) {
        if timeZone != basalRateSchedule?.timeZone {
            AnalyticsManager.shared.punpTimeZoneDidChange()
            basalRateSchedule?.timeZone = timeZone
        }

        if timeZone != carbRatioSchedule?.timeZone {
            AnalyticsManager.shared.punpTimeZoneDidChange()
            carbRatioSchedule?.timeZone = timeZone
        }

        if timeZone != insulinSensitivitySchedule?.timeZone {
            AnalyticsManager.shared.punpTimeZoneDidChange()
            insulinSensitivitySchedule?.timeZone = timeZone
        }

        if timeZone != settings.glucoseTargetRangeSchedule?.timeZone {
            settings.glucoseTargetRangeSchedule?.timeZone = timeZone
        }
    }

    /// All the HealthKit types to be read and shared by stores
    private var sampleTypes: Set<HKSampleType> {
        return Set([
            glucoseStore.sampleType,
            carbStore.sampleType,
            doseStore.sampleType,
        ].compactMap { $0 })
    }

    /// True if any stores require HealthKit authorization
    var authorizationRequired: Bool {
        return glucoseStore.authorizationRequired ||
               carbStore.authorizationRequired ||
               doseStore.authorizationRequired
    }

    /// True if the user has explicitly denied access to any stores' HealthKit types
    private var sharingDenied: Bool {
        return glucoseStore.sharingDenied ||
               carbStore.sharingDenied ||
               doseStore.sharingDenied
    }

    func authorize(_ completion: @escaping () -> Void) {
        // Authorize all types at once for simplicity
        carbStore.healthStore.requestAuthorization(toShare: sampleTypes, read: sampleTypes) { (success, error) in
            if success {
                // Call the individual authorization methods to trigger query creation
                self.carbStore.authorize({ _ in })
                self.doseStore.insulinDeliveryStore.authorize({ _ in })
                self.glucoseStore.authorize({ _ in })
            }

            completion()
        }
    }
}


// MARK: - Intake
extension LoopDataManager {
    /// Adds and stores glucose data
    ///
    /// - Parameters:
    ///   - samples: The new glucose samples to store
    ///   - completion: A closure called once upon completion
    ///   - result: The stored glucose values
    func addGlucose(
        _ samples: [NewGlucoseSample],
        completion: ((_ result: Result<[GlucoseValue]>) -> Void)? = nil
    ) {
        glucoseStore.addGlucose(samples) { (result) in
            self.dataAccessQueue.async {
                switch result {
                case .success(let samples):
                    if let endDate = samples.sorted(by: { $0.startDate < $1.startDate }).first?.startDate {
                        // Prune back any counteraction effects for recomputation
                        self.insulinCounteractionEffects = self.insulinCounteractionEffects.filter { $0.endDate < endDate }
                    }

                    completion?(.success(samples))
                case .failure(let error):
                    completion?(.failure(error))
                }
            }
        }
    }

    /// Adds and stores carb data, and recommends a bolus if needed
    ///
    /// - Parameters:
    ///   - carbEntry: The new carb value
    ///   - completion: A closure called once upon completion
    ///   - result: The bolus recommendation
    func addCarbEntryAndRecommendBolus(_ carbEntry: NewCarbEntry, replacing replacingEntry: StoredCarbEntry? = nil, completion: @escaping (_ result: Result<BolusRecommendation?>) -> Void) {
        let addCompletion: (CarbStoreResult<StoredCarbEntry>) -> Void = { (result) in
            self.dataAccessQueue.async {
                switch result {
                case .success:
                    // Remove the active pre-meal target override
                    self.settings.glucoseTargetRangeSchedule?.clearOverride(matching: .preMeal)

                    self.carbEffect = nil
                    self.carbsOnBoard = nil

                    do {
                        try self.update()

                        completion(.success(self.recommendedBolus?.recommendation))
                    } catch let error {
                        completion(.failure(error))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }

        if let replacingEntry = replacingEntry {
            carbStore.replaceCarbEntry(replacingEntry, withEntry: carbEntry, completion: addCompletion)
        } else {
            carbStore.addCarbEntry(carbEntry, completion: addCompletion)
        }
    }

    /// Adds a bolus requested of the pump, but not confirmed.
    ///
    /// - Parameters:
    ///   - units: The bolus amount, in units
    ///   - date: The date the bolus was requested
    func addRequestedBolus(units: Double, at date: Date, completion: (() -> Void)?) {
        dataAccessQueue.async {
            self.lastRequestedBolus = (units: units, date: date)
            self.notify(forChange: .bolus)

            completion?()
        }
    }

    /// Adds a bolus enacted by the pump, but not fully delivered.
    ///
    /// - Parameters:
    ///   - units: The bolus amount, in units
    ///   - date: The date the bolus was enacted
    func addConfirmedBolus(units: Double, at date: Date, completion: (() -> Void)?) {
        self.doseStore.addPendingPumpEvent(.enactedBolus(units: units, at: date)) {
            self.dataAccessQueue.async {
                self.lastRequestedBolus = nil
                self.insulinEffect = nil
                self.notify(forChange: .bolus)

                completion?()
            }
        }
    }

    /// Adds and stores new pump events
    ///
    /// - Parameters:
    ///   - events: The pump events to add
    ///   - completion: A closure called once upon completion
    ///   - error: An error explaining why the events could not be saved.
    func addPumpEvents(_ events: [NewPumpEvent], completion: @escaping (_ error: DoseStore.DoseStoreError?) -> Void) {
        doseStore.addPumpEvents(events) { (error) in
            self.dataAccessQueue.async {
                if error == nil {
                    self.insulinEffect = nil
                    // Expire any bolus values now represented in the insulin data
                    // dm61 wip: this is not a realiable approach to expiring a recent bolus, it may lead to temporarily double-counting
                    if let bolusDate = self.lastRequestedBolus?.date, bolusDate.timeIntervalSinceNow < TimeInterval(minutes: -5) {
                        self.lastRequestedBolus = nil
                    }
                }

                completion(error)
            }
        }
    }

    /// Adds and stores a pump reservoir volume
    ///
    /// - Parameters:
    ///   - units: The reservoir volume, in units
    ///   - date: The date of the volume reading
    ///   - completion: A closure called once upon completion
    ///   - result: The current state of the reservoir values:
    ///       - newValue: The new stored value
    ///       - lastValue: The previous new stored value
    ///       - areStoredValuesContinuous: Whether the current recent state of the stored reservoir data is considered continuous and reliable for deriving insulin effects after addition of this new value.
    func addReservoirValue(_ units: Double, at date: Date, completion: @escaping (_ result: Result<(newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool)>) -> Void) {
        doseStore.addReservoirValue(units, at: date) { (newValue, previousValue, areStoredValuesContinuous, error) in
            if let error = error {
                completion(.failure(error))
            } else if let newValue = newValue {
                self.dataAccessQueue.async {
                    self.insulinEffect = nil
                    // Expire any bolus values now represented in the insulin data
                    // wip this may not be a reliable way of expiring bolus
                    if areStoredValuesContinuous, let bolusDate = self.lastRequestedBolus?.date, bolusDate.timeIntervalSinceNow < TimeInterval(minutes: -5) {
                        self.lastRequestedBolus = nil
                    }

                    if let newDoseStartDate = previousValue?.startDate {
                        // Prune back any counteraction effects for recomputation, after the effect delay
                        self.insulinCounteractionEffects = self.insulinCounteractionEffects.filterDateRange(nil, newDoseStartDate.addingTimeInterval(.minutes(10)))
                    }

                    completion(.success((
                        newValue: newValue,
                        lastValue: previousValue,
                        areStoredValuesContinuous: areStoredValuesContinuous
                    )))
                }
            } else {
                assertionFailure()
            }
        }
    }

    // Actions

    func enactRecommendedTempBasal(_ completion: @escaping (_ error: Error?) -> Void) {
        dataAccessQueue.async {
            self.setRecommendedTempBasal(completion)
        }
    }

    /// Runs the "loop"
    ///
    /// Executes an analysis of the current data, and recommends an adjustment to the current
    /// temporary basal rate.
    func loop() {
        self.dataAccessQueue.async {
            NotificationCenter.default.post(name: .LoopRunning, object: self)

            self.lastLoopError = nil

            do {
                try self.update()

                if self.settings.dosingEnabled {
                    self.setRecommendedTempBasal { (error) -> Void in
                        self.lastLoopError = error

                        if let error = error {
                            self.logger.error(error)
                        } else {
                            self.lastLoopCompleted = Date()
                        }
                        self.notify(forChange: .tempBasal)
                    }

                    // Delay the notification until we know the result of the temp basal
                    return
                } else {
                    self.lastLoopCompleted = Date()
                }
            } catch let error {
                self.lastLoopError = error
            }

            self.notify(forChange: .tempBasal)
        }
    }

    /// - Throws:
    ///     - LoopError.configurationError
    ///     - LoopError.glucoseTooOld
    ///     - LoopError.missingDataError
    ///     - LoopError.pumpDataTooOld
    fileprivate func update() throws {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        let updateGroup = DispatchGroup()
        
        // Fetch glucose effects as far back as we want to make retroactive analysis
        var latestGlucoseDate: Date?
        updateGroup.enter()
        glucoseStore.getCachedGlucoseSamples(start: Date(timeIntervalSinceNow: -settings.recencyInterval)) { (values) in
            latestGlucoseDate = values.last?.startDate
            updateGroup.leave()
        }
        _ = updateGroup.wait(timeout: .distantFuture)

        guard let lastGlucoseDate = latestGlucoseDate else {
            throw LoopError.missingDataError(.glucose)
        }

        let retrospectiveStart = lastGlucoseDate.addingTimeInterval(-settings.retrospectiveCorrectionIntegrationInterval)

        let earliestEffectDate = Date(timeIntervalSinceNow: .hours(-24))
        let nextEffectDate = insulinCounteractionEffects.last?.endDate ?? earliestEffectDate
        
        if glucoseMomentumEffect == nil {
            updateGroup.enter()
            glucoseStore.getRecentMomentumEffect { (effects) -> Void in
                self.glucoseMomentumEffect = effects
                updateGroup.leave()
            }
        }

        if insulinEffect == nil {
            updateGroup.enter()
            doseStore.getGlucoseEffects(start: nextEffectDate) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.logger.error(error)
                    self.insulinEffect = nil
                case .success(let effects):
                    self.insulinEffect = effects
                }

                updateGroup.leave()
            }
        }

        _ = updateGroup.wait(timeout: .distantFuture)

        if nextEffectDate < lastGlucoseDate, let insulinEffect = insulinEffect {
            updateGroup.enter()
            self.logger.debug("Fetching counteraction effects after \(nextEffectDate)")
            glucoseStore.getCounteractionEffects(start: nextEffectDate, to: insulinEffect) { (velocities) in
                self.insulinCounteractionEffects.append(contentsOf: velocities)
                self.insulinCounteractionEffects = self.insulinCounteractionEffects.filterDateRange(earliestEffectDate, nil)

                updateGroup.leave()
            }

            _ = updateGroup.wait(timeout: .distantFuture)
        }

        if carbEffect == nil {
            updateGroup.enter()
            carbStore.getGlucoseEffects(
                start: retrospectiveStart,
                effectVelocities: settings.dynamicCarbAbsorptionEnabled ? insulinCounteractionEffects : nil
            ) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.logger.error(error)
                    self.carbEffect = nil
                case .success(let effects):
                    self.carbEffect = effects
                }

                updateGroup.leave()
            }
        }

        if carbsOnBoard == nil {
            updateGroup.enter()
            carbStore.carbsOnBoard(at: Date(), effectVelocities: settings.dynamicCarbAbsorptionEnabled ? insulinCounteractionEffects : nil) { (result) in
                switch result {
                case .failure:
                    // Failure is expected when there is no carb data
                    self.carbsOnBoard = nil
                case .success(let value):
                    self.carbsOnBoard = value
                }
                updateGroup.leave()
            }
        }
        
        _ = updateGroup.wait(timeout: .distantFuture)

        if retrospectiveGlucoseDiscrepancies == nil {
            do {
                try updateRetrospectiveGlucoseEffect()
            } catch let error {
                logger.error(error)
            }
        }
        
        do {
            try updateZeroTempEffect()
        } catch let error {
            logger.error(error)
        }        
        
        if predictedGlucose == nil {
            do {
                try updatePredictedGlucoseAndRecommendedBasalAndBolus()
            } catch let error {
                logger.error(error)

                throw error
            }
        }
        
        // carb correction recommendation, do only if data has been updated
        if suggestedCarbCorrection == nil {
            try updateCarbCorrection()
        }

    }
    
    
/* dm61 wip, insert parameter estimation from my-parameter-estimation-wip
    func effectsForParameterEstimation() {
        
        self.pastEffectsForEstimation = []
        let updateGroup = DispatchGroup()
        let glucoseUnit = HKUnit.milligramsPerDeciliter // do all calcs in mg/dL
        let estimationHours: Double = 24.0
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium
        dateFormatter.locale = Locale(identifier: "en_US")
        
        NSLog("myLoop ****************************************************************************")
        NSLog("myLoop %@", dateFormatter.string(from: Date()))
        
        // Fetch glucose values
        var latestGlucoseDate: Date?
        var glucoseValues: [StoredGlucoseSample]?
        updateGroup.enter()
        glucoseStore.getCachedGlucoseSamples(start: Date(timeIntervalSinceNow: TimeInterval(hours: -estimationHours))) { (values) in
            glucoseValues = values
            latestGlucoseDate = values.last?.startDate
            updateGroup.leave()
        }
        _ = updateGroup.wait(timeout: .distantFuture)
        
        guard let lastGlucoseDate = latestGlucoseDate else {
            NSLog("myLoop: *** No past glucose samples found ***")
            return
        }
        
        NSLog("myLoop: +++ %d past glucose values +++", glucoseValues!.count)
        
        let estimationStart = lastGlucoseDate.addingTimeInterval(TimeInterval(hours: -estimationHours))
        
        // find insulin effects over estimationHours
        var pastInsulinEffects: [GlucoseEffect] = []
        updateGroup.enter()
        self.doseStore.getGlucoseEffects(start: estimationStart) { (result) -> Void in
            switch result {
            case .failure(let error):
                self.logger.error(error)
                NSLog("myLoop: *** Could not get past insulin effects ***")
            case .success(let effects):
                pastInsulinEffects = effects
            }
            updateGroup.leave()
        }
        _ = updateGroup.wait(timeout: .distantFuture)
        if pastInsulinEffects.count == 0 {
            NSLog("myLoop: XXX Past insulin effects not available XXX")
            return
        } else {
            NSLog("myLoop: +++ %d past insulin effects +++", pastInsulinEffects.count)
        }
        
        // find update carb effects over estimationHours
        var pastCarbEffects: [GlucoseEffect] = []
        updateGroup.enter()
        self.carbStore.getGlucoseEffects(
            start: estimationStart,
            effectVelocities: self.settings.dynamicCarbAbsorptionEnabled ? self.insulinCounteractionEffects : nil
        ) { (result) -> Void in
            switch result {
            case .failure(let error):
                self.logger.error(error)
                NSLog("myLoop: *** Could not get past carb effects ***")
            case .success(let effects):
                pastCarbEffects = effects
            }
            updateGroup.leave()
        }
        _ = updateGroup.wait(timeout: .distantFuture)
        if pastCarbEffects.count == 0 {
            NSLog("myLoop: XXX Past carb effects not available XXX")
            return
        } else {
            NSLog("myLoop: +++ %d past carb effects +++", pastCarbEffects.count)
        }
        
        // construct array of past 30-min glucose changes
        var pastGlucoseChanges: [GlucoseChange] = []
        for glucoseSample in glucoseValues! {
            var sampleRetrospectiveGlucoseChange: GlucoseChange? = nil
            let sampleGlucoseChangeEnd = glucoseSample.startDate
            let sampleGlucoseChangeStart = sampleGlucoseChangeEnd.addingTimeInterval(TimeInterval(minutes: -30))
            updateGroup.enter()
            self.glucoseStore.getGlucoseChange(start: sampleGlucoseChangeStart, end: sampleGlucoseChangeEnd) { (change) in
                sampleRetrospectiveGlucoseChange = change
                updateGroup.leave()
            }
            
            _ = updateGroup.wait(timeout: .distantFuture)
            
            if let change = sampleRetrospectiveGlucoseChange {
                pastGlucoseChanges.append(change)
            }
        }
        if pastGlucoseChanges.count == 0 {
            NSLog("myLoop: XXX Array of past BG changes not initialized XXX")
            return
        } else {
            NSLog("myLoop: +++ %d past glucose changes +++", pastGlucoseChanges.count)
        }
        
        // compute effects for past retrospective glucose changes
        for change in pastGlucoseChanges {
            let startDate = change.start.startDate
            let endDate = change.end.endDate
            let retrospectionTimeInterval = change.end.endDate.timeIntervalSince(change.start.endDate).minutes
            if retrospectionTimeInterval < 6 {
                continue // too few retrospective glucose values, erroneous insulin and carb effects, skip
            }
            let retrospectionScale = 30.0 / retrospectionTimeInterval
            
            // current BG sample
            let sampleBG = change.end.quantity.doubleValue(for: glucoseUnit) // mg/dL
            
            // average delta BG over retrospection interval
            let deltaBG = retrospectionScale * (change.end.quantity.doubleValue(for: glucoseUnit) -
                change.start.quantity.doubleValue(for: glucoseUnit))// mg/dL
            
            // discrepancy
            let pastRetrospectivePrediction = LoopMath.predictGlucose(startingAt: change.start, effects:
                pastCarbEffects.filterDateRange(startDate, endDate), pastInsulinEffects.filterDateRange(startDate, endDate))
            guard let predictedGlucose = pastRetrospectivePrediction.last else {
                continue // unable to predict glucose for this change
            }
            let discrepancy = retrospectionScale * (change.end.quantity.doubleValue(for: glucoseUnit) - predictedGlucose.quantity.doubleValue(for: glucoseUnit)) // mg/dL
            
            // carb effect
            let pastRetrospectiveCarbEffect = LoopMath.predictGlucose(startingAt: change.start, effects:
                pastCarbEffects.filterDateRange(startDate, endDate))
            guard let predictedCarbOnlyGlucose = pastRetrospectiveCarbEffect.last else {
                continue // unable to determine carb effect for this change
            }
            let carbEffect = retrospectionScale * (-change.start.quantity.doubleValue(for: glucoseUnit) + predictedCarbOnlyGlucose.quantity.doubleValue(for: glucoseUnit))
            
            // insulin effect
            let pastRetrospectiveInsulinEffect = LoopMath.predictGlucose(startingAt: change.start, effects:
                pastInsulinEffects.filterDateRange(startDate, endDate))
            guard let predictedInsulinOnlyGlucose = pastRetrospectiveInsulinEffect.last else {
                continue // unable to determine insulin effect for this change
            }
            let insulinEffect = retrospectionScale * (-change.start.quantity.doubleValue(for: glucoseUnit) + predictedInsulinOnlyGlucose.quantity.doubleValue(for: glucoseUnit))
            
            self.pastEffectsForEstimation.append((date: endDate, discrepancy: discrepancy, insulinEffect: insulinEffect, carbEffect: carbEffect))
            
            NSLog("myLoopPE: %@, %4.0f, %4.2f, %4.2f, %4.2f, %4.2f", dateFormatter.string(from: endDate), sampleBG, deltaBG, insulinEffect, carbEffect, discrepancy)
            
        }
        
    }
*/
    
    private func notify(forChange context: LoopUpdateContext) {
        NotificationCenter.default.post(name: .LoopDataUpdated,
            object: self,
            userInfo: [
                type(of: self).LoopUpdateContextKey: context.rawValue
            ]
        )
    }

    /// Computes amount of insulin from boluses that have been issued and not confirmed, and
    /// remaining insulin delivery from temporary basal rate adjustments above scheduled rate
    /// that are still in progress.
    ///
    /// - Returns: The amount of pending insulin, in units
    /// - Throws: LoopError.configurationError
    private func getPendingInsulin() throws -> Double {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let basalRates = basalRateSchedule else {
            throw LoopError.configurationError(.basalRateSchedule)
        }

        let pendingTempBasalInsulin: Double
        let date = Date()

        if let lastTempBasal = lastTempBasal, lastTempBasal.endDate > date {
            let normalBasalRate = basalRates.value(at: date)
            let remainingTime = lastTempBasal.endDate.timeIntervalSince(date)
            let remainingUnits = (lastTempBasal.unitsPerHour - normalBasalRate) * remainingTime.hours

            pendingTempBasalInsulin = max(0, remainingUnits)
        } else {
            pendingTempBasalInsulin = 0
        }

        let pendingBolusAmount: Double = lastRequestedBolus?.units ?? 0

        // All outstanding potential insulin delivery
        return pendingTempBasalInsulin + pendingBolusAmount
    }

    /// - Throws: LoopError.missingDataError
    fileprivate func predictGlucose(using inputs: PredictionInputEffect) throws -> [GlucoseValue] {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let model = insulinModelSettings?.model else {
            throw LoopError.configurationError(.insulinModel)
        }

        guard let glucose = self.glucoseStore.latestGlucose else {
            throw LoopError.missingDataError(.glucose)
        }

        var momentum: [GlucoseEffect] = []
        var effects: [[GlucoseEffect]] = []

        if inputs.contains(.carbs), let carbEffect = self.carbEffect {
            effects.append(carbEffect)
        }

        if inputs.contains(.insulin), let insulinEffect = self.insulinEffect {
            effects.append(insulinEffect)
        }

        if inputs.contains(.momentum), let momentumEffect = self.glucoseMomentumEffect {
            momentum = momentumEffect
        }

        if inputs.contains(.retrospection) {
            effects.append(self.retrospectiveGlucoseEffect)
        }
        
        if inputs.contains(.zeroTemp) {
            effects.append(self.zeroTempEffect)
        }

        var prediction = LoopMath.predictGlucose(startingAt: glucose, momentum: momentum, effects: effects)

        // Dosing requires prediction entries at least as long as the insulin model duration.
        // If our prediction is shorter than that, then extend it here.
        let finalDate = glucose.startDate.addingTimeInterval(model.effectDuration)
        if let last = prediction.last, last.startDate < finalDate {
            prediction.append(PredictedGlucoseValue(startDate: finalDate, quantity: last.quantity))
        }

        return prediction
    }
    
    /// Generates a correction effect based on how large the discrepancy is between the current glucose and its model predicted value. If integral retrospective correction is enabled, the retrospective correction effect is based on a timeline of past discrepancies.
    ///
    /// - Throws: LoopError.missingDataError
    private func updateRetrospectiveGlucoseEffect() throws {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        // Get carb effects, otherwise clear effect and throw error
        guard let carbEffects = self.carbEffect else {
            retrospectiveGlucoseDiscrepancies = nil
            retrospectiveGlucoseEffect = []
            totalRetrospectiveCorrection = nil
            throw LoopError.missingDataError(.carbEffect)
        }
        
        // Get most recent glucose, otherwise clear effect and throw error
        guard let glucose = self.glucoseStore.latestGlucose else {
            retrospectiveGlucoseEffect = []
            totalRetrospectiveCorrection = nil
            throw LoopError.missingDataError(.glucose)
        }

        // Get timeline of glucose discrepancies
        retrospectiveGlucoseDiscrepancies = insulinCounteractionEffects.subtracting(carbEffects, withUniformInterval: carbStore.delta)
        
        // Calculate retrospective correction
        if settings.integralRetrospectiveCorrectionEnabled {
            // Integral retrospective correction, if enabled
            retrospectiveGlucoseEffect = integralRC.updateRetrospectiveCorrectionEffect(glucose, retrospectiveGlucoseDiscrepanciesSummed)
            totalRetrospectiveCorrection = integralRC.totalGlucoseCorrectionEffect
        } else {
            // Standard retrospective correction
            retrospectiveGlucoseEffect = standardRC.updateRetrospectiveCorrectionEffect(glucose, retrospectiveGlucoseDiscrepanciesSummed)
            totalRetrospectiveCorrection = standardRC.totalGlucoseCorrectionEffect
        }
    }
    
    // carb correction recommendation, do only if settings are available
    private func updateCarbCorrection() throws {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        
        // Get settings, otherwise throw error
        guard
            let insulinActionDuration = insulinModelSettings?.model.effectDuration,
            let suspendThreshold = settings.suspendThreshold?.quantity.doubleValue(for: .milligramsPerDeciliter),
            let sensitivity = insulinSensitivitySchedule?.averageValue(),
            let carbRatio = carbRatioSchedule?.averageValue()
            else {
                self.suggestedCarbCorrection = nil
                throw LoopError.invalidData(details: "Settings not available, updateCarbCorrection failed")
        }
        
        guard let latestGlucose = glucoseStore.latestGlucose else {
            throw LoopError.missingDataError(.glucose)
        }
        
        guard let pumpStatusDate = doseStore.lastReservoirValue?.startDate else {
            throw LoopError.missingDataError(.reservoir)
        }
        
        let startDate = Date()
        
        guard startDate.timeIntervalSince(latestGlucose.startDate) <= settings.recencyInterval else {
            throw LoopError.glucoseTooOld(date: latestGlucose.startDate)
        }
        
        guard startDate.timeIntervalSince(pumpStatusDate) <= settings.recencyInterval else {
            throw LoopError.pumpDataTooOld(date: pumpStatusDate)
        }
        
        guard glucoseMomentumEffect != nil else {
            throw LoopError.missingDataError(.momentumEffect)
        }
        
        guard carbEffect != nil else {
            throw LoopError.missingDataError(.carbEffect)
        }
        
        guard insulinEffect != nil else {
            throw LoopError.missingDataError(.insulinEffect)
        }
        
        guard zeroTempEffect != [] else {
            throw LoopError.invalidData(details: "zeroTempEffect not available, updateCarbCorrection failed")
        }
        
        guard lastRequestedBolus == nil else {
            throw LoopError.invalidData(details: "pending bolus, skip updateCarbCorrection")
        }
        
        let carbCorrectionAbsorptionTime: TimeInterval = carbStore.defaultAbsorptionTimes.fast * carbStore.absorptionTimeOverrun
        let carbCorrectionThreshold: Int = 4 // do not bother with carb correction notifications below this value
        let carbCorrectionFactor: Double = 1.1 // increase correction carbs by 10% to avoid repeated notifications in case the user accepts the recommendation as is
        let carbCorrectionSkipInterval: TimeInterval = 0.5 * carbCorrectionAbsorptionTime // ignore dips below suspend threshold within the initial skip interval
        var effectsIncludingZeroTemping = settings.enabledEffects
        effectsIncludingZeroTemping.insert(.zeroTemp) // include effect of zero temping
        do {
            let predictedGlucoseForCarbCorrection = try predictGlucose(using: effectsIncludingZeroTemping)
            if let currentDate = predictedGlucoseForCarbCorrection.first?.startDate {
                let startDate = currentDate.addingTimeInterval(carbCorrectionSkipInterval)
                let endDate = currentDate.addingTimeInterval(insulinActionDuration)
                let predictedLowGlucose = predictedGlucoseForCarbCorrection.filter{ $0.startDate >= startDate && $0.startDate <= endDate && $0.quantity.doubleValue(for: .milligramsPerDeciliter) < suspendThreshold}
                if predictedLowGlucose.count > 0 {
                    var carbCorrection = 0
                    for glucose in predictedLowGlucose {
                        let glucoseTime = glucose.startDate.timeIntervalSince(currentDate)
                        let anticipatedAbsorbedFraction = min(1.0, glucoseTime.minutes / carbCorrectionAbsorptionTime.minutes)
                        let requiredCorrection = (( suspendThreshold - glucose.quantity.doubleValue(for: .milligramsPerDeciliter)) / anticipatedAbsorbedFraction) * carbRatio / sensitivity
                        let requiredCorrectionRounded = Int(ceil(carbCorrectionFactor * requiredCorrection))
                        if requiredCorrectionRounded > carbCorrection {
                            carbCorrection = requiredCorrectionRounded
                        }
                    }
                    suggestedCarbCorrection = carbCorrection
                    if carbCorrection >= carbCorrectionThreshold {
                        if let lowGlucose = predictedGlucoseForCarbCorrection.first( where:
                            {$0.quantity.doubleValue(for: .milligramsPerDeciliter) < suspendThreshold} ) {
                            let timeToLow = lowGlucose.startDate.timeIntervalSince(currentDate)
                            NotificationManager.sendCarbCorrectionNotification(carbCorrection, timeToLow)
                        } else {
                            NotificationManager.sendCarbCorrectionNotification(carbCorrection, nil)
                        }
                    } else {
                        NotificationManager.sendCarbCorrectionNotificationBadge(carbCorrection)
                    }
                } else {
                    suggestedCarbCorrection = 0
                    NotificationManager.clearCarbCorrectionNotification()
                }
            }
        } catch {
            throw LoopError.invalidData(details: "predictedGlucose failed, updateCarbCorrection failed")
        }
        return
    }
    
    /// Generates a glucose prediction effect of zero temping over duration of insulin action starting at current date
    ///
    /// - Throws: LoopError.configurationError
    private func updateZeroTempEffect() throws {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        
        // Get settings, otherwise clear effect and throw error
        guard
            let insulinModel = insulinModelSettings?.model,
            let insulinSensitivity = insulinSensitivitySchedule,
            let basalRateSchedule = basalRateSchedule
        else {
            zeroTempEffect = []
            throw LoopError.configurationError(.generalSettings)
        }
        
        let insulinActionDuration = insulinModel.effectDuration
        
        // use the new LoopKit method tempBasalGlucoseEffects to generate zero temp effects
        let startZeroTempDose = Date()
        let endZeroTempDose = startZeroTempDose.addingTimeInterval(insulinActionDuration)
        let zeroTemp = DoseEntry(type: .tempBasal, startDate: startZeroTempDose, endDate: endZeroTempDose, value: 0.0, unit: DoseUnit.unitsPerHour)
        zeroTempEffect = zeroTemp.tempBasalGlucoseEffects(insulinModel: insulinModel, insulinSensitivity: insulinSensitivity, basalRateSchedule: basalRateSchedule).filterDateRange(startZeroTempDose, endZeroTempDose)
        
    }


    /// Runs the glucose prediction on the latest effect data.
    ///
    /// - Throws:
    ///     - LoopError.configurationError
    ///     - LoopError.glucoseTooOld
    ///     - LoopError.missingDataError
    ///     - LoopError.pumpDataTooOld
    private func updatePredictedGlucoseAndRecommendedBasalAndBolus() throws {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let glucose = glucoseStore.latestGlucose else {
            self.predictedGlucose = nil
            throw LoopError.missingDataError(.glucose)
        }

        guard let pumpStatusDate = doseStore.lastReservoirValue?.startDate else {
            self.predictedGlucose = nil
            throw LoopError.missingDataError(.reservoir)
        }

        let startDate = Date()

        guard startDate.timeIntervalSince(glucose.startDate) <= settings.recencyInterval else {
            self.predictedGlucose = nil
            throw LoopError.glucoseTooOld(date: glucose.startDate)
        }

        guard startDate.timeIntervalSince(pumpStatusDate) <= settings.recencyInterval else {
            self.predictedGlucose = nil
            throw LoopError.pumpDataTooOld(date: pumpStatusDate)
        }

        guard glucoseMomentumEffect != nil else {
            self.predictedGlucose = nil
            throw LoopError.missingDataError(.momentumEffect)
        }

        guard carbEffect != nil else {
            self.predictedGlucose = nil
            throw LoopError.missingDataError(.carbEffect)
        }

        guard insulinEffect != nil else {
            self.predictedGlucose = nil
            throw LoopError.missingDataError(.insulinEffect)
        }

        let predictedGlucose = try predictGlucose(using: settings.enabledEffects)
        self.predictedGlucose = predictedGlucose

        guard let
            maxBasal = settings.maximumBasalRatePerHour,
            let glucoseTargetRange = settings.glucoseTargetRangeSchedule,
            let insulinSensitivity = insulinSensitivitySchedule,
            let basalRates = basalRateSchedule,
            let maxBolus = settings.maximumBolus,
            let model = insulinModelSettings?.model
        else {
            throw LoopError.configurationError(.generalSettings)
        }
        
        guard lastRequestedBolus == nil
        else {
            // Don't recommend changes if a bolus was just requested.
            // Sending additional pump commands is not going to be
            // successful in any case.
            recommendedBolus = nil
            recommendedTempBasal = nil
            recommendedSuperBolus = nil
            return
        }
        
        let tempBasal = predictedGlucose.recommendedTempBasal(
            to: glucoseTargetRange,
            suspendThreshold: settings.suspendThreshold?.quantity,
            sensitivity: insulinSensitivity,
            model: model,
            basalRates: basalRates,
            maxBasalRate: maxBasal,
            lastTempBasal: lastTempBasal
        )
        
        if let temp = tempBasal {
            recommendedTempBasal = (recommendation: temp, date: startDate)
        } else {
            recommendedTempBasal = nil
        }

        let pendingInsulin = try self.getPendingInsulin()

        let recommendation = predictedGlucose.recommendedBolus(
            to: glucoseTargetRange,
            suspendThreshold: settings.suspendThreshold?.quantity,
            sensitivity: insulinSensitivity,
            model: model,
            pendingInsulin: pendingInsulin,
            maxBolus: maxBolus
        )
        recommendedBolus = (recommendation: recommendation, date: startDate)
        
        // wip super bolus recommendation
        // offer super bolus only if initial or final glucose are above target
        if let firstGlucose = predictedGlucose.first, let lastGlucose = predictedGlucose.last {
            if firstGlucose.quantity > glucoseTargetRange.maxQuantity(at: firstGlucose.startDate) || lastGlucose.quantity > glucoseTargetRange.maxQuantity(at: lastGlucose.startDate) {
                
                var effectsIncludingZeroTemping = settings.enabledEffects
                effectsIncludingZeroTemping.insert(.zeroTemp)
                // remove positive retrospective correction
                if let correction = totalRetrospectiveCorrection?.doubleValue(for: .milligramsPerDeciliter) {
                    if correction > 0.0 {
                        effectsIncludingZeroTemping.remove(.retrospection)
                    }
                }
                let predictedGlucoseWithZeroTemp = try predictGlucose(using: effectsIncludingZeroTemping)
                let maximumSuperBolus = predictedGlucoseWithZeroTemp.recommendedBolus(
                    to: glucoseTargetRange,
                    suspendThreshold: settings.suspendThreshold?.quantity,
                    sensitivity: insulinSensitivity,
                    model: model,
                    pendingInsulin: pendingInsulin,
                    maxBolus: maxBolus
                )
                let superBolusAggressiveness = 0.75
                let superBolusAmount = recommendation.amount + max(superBolusAggressiveness * (maximumSuperBolus.amount - recommendation.amount), 0.0)
                let superBolus: BolusRecommendation = BolusRecommendation(amount: superBolusAmount, pendingInsulin: maximumSuperBolus.pendingInsulin)
                recommendedSuperBolus = (recommendation: superBolus, date: startDate)
                
            } else {
                recommendedSuperBolus = recommendedBolus
            }
        }
        
    }

    /// *This method should only be called from the `dataAccessQueue`*
    private func setRecommendedTempBasal(_ completion: @escaping (_ error: Error?) -> Void) {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let recommendedTempBasal = self.recommendedTempBasal else {
            completion(nil)
            return
        }

        guard abs(recommendedTempBasal.date.timeIntervalSinceNow) < TimeInterval(minutes: 5) else {
            completion(LoopError.recommendationExpired(date: recommendedTempBasal.date))
            return
        }

        delegate?.loopDataManager(self, didRecommendBasalChange: recommendedTempBasal) { (result) in
            self.dataAccessQueue.async {
                switch result {
                case .success(let basal):
                    self.lastTempBasal = basal
                    self.recommendedTempBasal = nil

                    completion(nil)
                case .failure(let error):
                    completion(error)
                }
            }
        }
    }
}

/// Describes retrospective correction interface
protocol RetrospectiveCorrection {
    /// Standard effect duration, nominally set to 60 min
    var standardEffectDuration: TimeInterval { get }
    
    /// Overall retrospective correction effect
    var totalGlucoseCorrectionEffect: HKQuantity? { get }
    
    /**
     Calculates overall correction effect based on timeline of discrepancies, and updates glucoseCorrectionEffect
     
     - Parameters:
        - glucose: Most recent glucose
        - retrospectiveGlucoseDiscrepanciesSummed: Timeline of past discepancies
     
     - Returns:
        - retrospectiveGlucoseEffect: Glucose correction effects
     */
    func updateRetrospectiveCorrectionEffect(_ glucose: GlucoseValue, _ retrospectiveGlucoseDiscrepanciesSummed: [GlucoseChange]?) -> [GlucoseEffect]
}

/// Describes a view into the loop state
protocol LoopState {
    /// The last-calculated carbs on board
    var carbsOnBoard: CarbValue? { get }

    /// An error in the current state of the loop, or one that happened during the last attempt to loop.
    var error: Error? { get }

    /// A timeline of average velocity of glucose change counteracting predicted insulin effects
    var insulinCounteractionEffects: [GlucoseEffectVelocity] { get }

    /// The last set temp basal
    var lastTempBasal: DoseEntry? { get }

    /// The calculated timeline of predicted glucose values
    var predictedGlucose: [GlucoseValue]? { get }

    /// The recommended temp basal based on predicted glucose
    var recommendedTempBasal: (recommendation: TempBasalRecommendation, date: Date)? { get }

    var recommendedBolus: (recommendation: BolusRecommendation, date: Date)? { get }
    
    var recommendedSuperBolus: (recommendation: BolusRecommendation, date: Date)? { get }

    /// The difference in predicted vs actual glucose over a recent period
    var retrospectiveGlucoseDiscrepancies: [GlucoseChange]? { get }

    /// Calculates a new prediction from the current data using the specified effect inputs
    ///
    /// This method is intended for visualization purposes only, not dosing calculation. No validation of input data is done.
    ///
    /// - Parameter inputs: The effect inputs to include
    /// - Returns: An timeline of predicted glucose values
    /// - Throws: LoopError.missingDataError if prediction cannot be computed
    func predictGlucose(using inputs: PredictionInputEffect) throws -> [GlucoseValue]
}


extension LoopDataManager {
    private struct LoopStateView: LoopState {
        private let loopDataManager: LoopDataManager
        private let updateError: Error?

        init(loopDataManager: LoopDataManager, updateError: Error?) {
            self.loopDataManager = loopDataManager
            self.updateError = updateError
        }

        var carbsOnBoard: CarbValue? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.carbsOnBoard
        }

        var error: Error? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return updateError ?? loopDataManager.lastLoopError
        }

        var insulinCounteractionEffects: [GlucoseEffectVelocity] {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.insulinCounteractionEffects
        }

        var lastTempBasal: DoseEntry? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.lastTempBasal
        }

        var predictedGlucose: [GlucoseValue]? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.predictedGlucose
        }

        var recommendedTempBasal: (recommendation: TempBasalRecommendation, date: Date)? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.recommendedTempBasal
        }
        
        var recommendedBolus: (recommendation: BolusRecommendation, date: Date)? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.recommendedBolus
        }
        
        var recommendedSuperBolus: (recommendation: BolusRecommendation, date: Date)? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.recommendedSuperBolus
        }

        var retrospectiveGlucoseDiscrepancies: [GlucoseChange]? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.retrospectiveGlucoseDiscrepanciesSummed
        }

        func predictGlucose(using inputs: PredictionInputEffect) throws -> [GlucoseValue] {
            return try loopDataManager.predictGlucose(using: inputs)
        }
    }

    /// Executes a closure with access to the current state of the loop.
    ///
    /// This operation is performed asynchronously and the closure will be executed on an arbitrary background queue.
    ///
    /// - Parameter handler: A closure called when the state is ready
    /// - Parameter manager: The loop manager
    /// - Parameter state: The current state of the manager. This is invalid to access outside of the closure.
    func getLoopState(_ handler: @escaping (_ manager: LoopDataManager, _ state: LoopState) -> Void) {
        dataAccessQueue.async {
            var updateError: Error?

            do {
                try self.update()
            } catch let error {
                updateError = error
            }

            handler(self, LoopStateView(loopDataManager: self, updateError: updateError))
        }
    }
}


extension LoopDataManager {
    /// Generates a diagnostic report about the current state
    ///
    /// This operation is performed asynchronously and the completion will be executed on an arbitrary background queue.
    ///
    /// - parameter completion: A closure called once the report has been generated. The closure takes a single argument of the report string.
    func generateDiagnosticReport(_ completion: @escaping (_ report: String) -> Void) {
        getLoopState { (manager, state) in

            var entries: [String] = [
                "## LoopDataManager",
                "settings: \(String(reflecting: manager.settings))",

                "insulinCounteractionEffects: [",
                "* GlucoseEffectVelocity(start, end, mg/dL/min)",
                manager.insulinCounteractionEffects.reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.endDate), \(entry.quantity.doubleValue(for: GlucoseEffectVelocity.unit))\n")
                }),
                "]",

                "insulinEffect: [",
                "* GlucoseEffect(start, mg/dL)",
                (manager.insulinEffect ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",

                "carbEffect: [",
                "* GlucoseEffect(start, mg/dL)",
                (manager.carbEffect ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",

                "predictedGlucose: [",
                "* PredictedGlucoseValue(start, mg/dL)",
                (state.predictedGlucose ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",

                "retrospectiveGlucoseDiscrepancies: [",
                "* GlucoseEffect(start, mg/dL)",
                (manager.retrospectiveGlucoseDiscrepancies ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",

                "retrospectiveGlucoseDiscrepanciesSummed: [",
                "* GlucoseChange(start, end, mg/dL)",
                (manager.retrospectiveGlucoseDiscrepanciesSummed ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.endDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",

                "glucoseMomentumEffect: \(manager.glucoseMomentumEffect ?? [])",
                "",
                "retrospectiveGlucoseEffect: \(manager.retrospectiveGlucoseEffect)",
                "",
                "zeroTempEffect: \(manager.zeroTempEffect)",
                "",
                "recommendedTempBasal: \(String(describing: state.recommendedTempBasal))",
                "recommendedBolus: \(String(describing: state.recommendedBolus))",
                "lastBolus: \(String(describing: manager.lastRequestedBolus))",
                "lastLoopCompleted: \(String(describing: manager.lastLoopCompleted))",
                "lastTempBasal: \(String(describing: state.lastTempBasal))",
                "carbsOnBoard: \(String(describing: state.carbsOnBoard))",
                "error: \(String(describing: state.error))",
                "",
                "cacheStore: \(String(reflecting: self.glucoseStore.cacheStore))",
                "",
            ]

            self.integralRC.generateDiagnosticReport { (report) in
                entries.append(report)
                entries.append("")
            }

            self.glucoseStore.generateDiagnosticReport { (report) in
                entries.append(report)
                entries.append("")

                self.carbStore.generateDiagnosticReport { (report) in
                    entries.append(report)
                    entries.append("")

                    self.doseStore.generateDiagnosticReport { (report) in
                        entries.append(report)
                        entries.append("")

                        completion(entries.joined(separator: "\n"))
                    }
                }
            }
        }
    }
}


extension Notification.Name {
    static let LoopDataUpdated = Notification.Name(rawValue:  "com.loudnate.Naterade.notification.LoopDataUpdated")

    static let LoopRunning = Notification.Name(rawValue: "com.loudnate.Naterade.notification.LoopRunning")
}


protocol LoopDataManagerDelegate: class {

    /// Informs the delegate that an immediate basal change is recommended
    ///
    /// - Parameters:
    ///   - manager: The manager
    ///   - basal: The new recommended basal
    ///   - completion: A closure called once on completion
    ///   - result: The enacted basal
    func loopDataManager(_ manager: LoopDataManager, didRecommendBasalChange basal: (recommendation: TempBasalRecommendation, date: Date), completion: @escaping (_ result: Result<DoseEntry>) -> Void) -> Void
}
