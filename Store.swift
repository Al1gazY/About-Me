//Original
//  Store.swift
//  Healthsign
//
//  Created by Zhifu Ge on 2020-12-31.
//  Copyright © 2020 Zhifu Ge. All rights reserved.
//

import Foundation
import UIKit
import Combine
import CoreBluetooth
import SwiftUI

final class Store: ObservableObject {
    @Published var selectedUsername: String = UserDefaults.standard.string(forKey: "selectedUsername") ?? "" {
        didSet { UserDefaults.standard.set(selectedUsername, forKey: "selectedUsername") }
    }
    @Published var calibrationFlag: Bool = false
    @Published var calibrationUsername: String = ""
    @Published var omronSystolic: Int = 0
    @Published var omronDiastolic: Int = 0
    @Published var activeAutoStream: StreamType? = nil

    @AppStorage("proceedWithoutCalibrationEnabled") var proceedWithoutCalibration: Bool = true

    private var debugNIBPBuffer: [CLSReading] = []
    @Published var debugNIBPAdjustingEnabled: Bool = false
    private var debugNIBPAdjustTimer: AnyCancellable?
    private var debugNIBPAdjustTick: Int = 0

    public var realTimeNibpDCAchieved = 0

    private var debugSpO2Buffer: [CLSReading] = []
    @Published var debugSpO2AdjustingEnabled: Bool = false
    private var debugSpO2AdjustTimer: AnyCancellable?
    private var debugSpO2AdjustTick: Int = 0

    private func resetWaveformsForNewRun() {
        timestamp = 0
        lastIndexRaw = 0
        lastIndexFiltered = 0
        filtered.removeAll(keepingCapacity: false)
        raw.removeAll(keepingCapacity: false)

        resetChart.send(())
    }

    @Published var calibrationStep: Int = {
        let selectedUsername = UserDefaults.standard.string(forKey: "selectedUsername") ?? ""
        return UserDefaults.standard.integer(forKey: "calibrationStep_\(selectedUsername)")
    }() {
        didSet {
            let selectedUsername = UserDefaults.standard.string(forKey: "selectedUsername") ?? ""
            UserDefaults.standard.set(calibrationStep, forKey: "calibrationStep_\(selectedUsername)")
        }
    }
    @Published var Current_IR_AC_Amplitude = 0
    @Published var Current_RD_AC_Amplitude = 0
    @Published var Current_BKY_AC_Amplitude = 0
    @Published var Current_FRY_AC_Amplitude = 0

    @Published var previous_IR_AC_Amplitude = 0
    @Published var previous_RD_AC_Amplitude = 0
    @Published var previous_BKY_AC_Amplitude = 0
    @Published var previous_FRY_AC_Amplitude = 0

    /*RR variable*/
    private var AC1timeTops = [Double]()
    private var AC2timeTops = [Double]()
    private var AC1timeBtms = [Double]()
    private var AC2timeBtms = [Double]()

    @Published var realTimeRR = 0
    /*RR Ends*/

    static let shared = Store()

    public var subscriptions = Set<AnyCancellable>()
    private var timerSubscription: AnyCancellable?
    private var monitoringTimerSubscription: AnyCancellable?

    private let bluetoothManager: BluetoothManager
    private var peripheralLastSeen: [UUID: Date] = [:]

    @Published var transmitEnabled: Bool = UserDefaults.standard.bool(forKey: DefaultsKeys.transmitEnabled) {
        didSet { UserDefaults.standard.set(transmitEnabled, forKey: DefaultsKeys.transmitEnabled) }
    }
    @Published var transmitThousandHzEnabled: Bool = UserDefaults.standard.bool(forKey: DefaultsKeys.transmitThousandHzEnabled) {
        didSet { UserDefaults.standard.set(transmitThousandHzEnabled, forKey: DefaultsKeys.transmitThousandHzEnabled) }
    }

    @Published var clsFeatureResult: CLSFeatureResult?
    @Published var userDisplaYEmail: String = ""
    @Published var isAdjusting: Bool = false
    @Published var spo2AutoSnapshot: SpO2AutoSnapshot? = nil
    @Published var nibpAutoSnapshot: NIBPAutoSnapshot? = nil

    @Published var autoSliderEnabled: Bool = UserDefaults.standard.bool(forKey: Store.DefaultsKeys.autoSliderEnabled) {
        didSet {
            UserDefaults.standard.set(autoSliderEnabled, forKey: Store.DefaultsKeys.autoSliderEnabled)
            if autoSliderEnabled {
                activeAutoStream = .PLX
                buffer0.removeAll(keepingCapacity: false)
                buffer1.removeAll(keepingCapacity: false)
                buffer2.removeAll(keepingCapacity: false)
                buffer3.removeAll(keepingCapacity: false)
                realTimeIteration = 0
            } else if activeAutoStream == .PLX {
                activeAutoStream = nil
                restoreSpO2TimerIfSaved()
                buffer0.removeAll(keepingCapacity: false)
                buffer1.removeAll(keepingCapacity: false)
                buffer2.removeAll(keepingCapacity: false)
                buffer3.removeAll(keepingCapacity: false)
                realTimeIteration = 0
            }
        }
    }

    @Published var autoNibpSliderEnabled: Bool = UserDefaults.standard.bool(forKey: Store.DefaultsKeys.autoNibpSliderEnabled) {
        didSet {
            UserDefaults.standard.set(autoNibpSliderEnabled, forKey: Store.DefaultsKeys.autoNibpSliderEnabled)
            if autoNibpSliderEnabled {
                activeAutoStream = .CLS
                nibpAutoSnapshot = nil
            } else if activeAutoStream == .CLS {
                activeAutoStream = nil
                restoreNibpTimerIfSaved()
            }
        }
    }


    private let windowSize = 140
    private let stepSize = 100
    private var lastIndexRaw = 0

    /* Real Time Spo2 Calculation*/
    private var buffer0 = [Double]()
    private var buffer1 = [Double]()
    private var buffer2 = [Double]()
    private var buffer3 = [Double]()
    private var realTimeIteration: Int = 0
    private var realTimeSliderIteration: Int = 0

    @Published var realTimeSpo2: Int = 0
    @Published var realTimePlxHR: Double = 0.0
    @Published var realTimeClsHR: Double = 0.0
    /* End Real Time Spo2 Calculation*/

    public var currentStream: StreamType?
    public var currentStreamType: String { currentStream?.name ?? "CLS" }

    public var realTimeDCAchieved = 0
    private var realTimeACAchieved = 0
    private var realTimeACAchievedFirstTime = 0
    private var waitTimeCounter = 0
    private var waitTimeFlag = 0

    @Published var raw: [CLSReading] = [] {
        didSet {
            guard !raw.isEmpty, raw.count % stepSize == 0 else {
                updateCharts(); return
            }
            autoreleasepool {
                let start = lastIndexRaw
                let end = lastIndexRaw + windowSize
                guard end < raw.count else { return }

                let autoActive = (autoSliderEnabled || autoNibpSliderEnabled)
                spo2Iteration = autoActive ? (spo2Iteration + 1) : 1

                realTimeSliderIteration += 1

                /* Real Time SpO₂ Calculation counter (disabled during AutoSlider tuning) */
                if !autoNibpSliderEnabled && !autoSliderEnabled {
                    realTimeIteration += 1
                }
                /* End Real Time SpO₂ Calculation counter */

                let segment = Array(raw[start..<end])
                let filtered = filter(segment)
                let trimmed = filtered[19 ..< 119]
                self.filtered.append(contentsOf: trimmed)
                lastIndexRaw += stepSize
                updateCharts()
            }
        }
    }

    private var lastIndexFiltered = 0
    private var filtered: [(Double, Double, Double, Double)] = []
    private var usesRealTimeDSP: Bool = false
    private var timestamp: Double = 0.0

    private var spo2Iteration: Int = 0
    public var tempVar: Int  = 0
    public var Achieved_Desired_Values_for_the_first_time: Int = 0
    public var Achieved_Desired_Values: Int = 0

    private var runToken = UUID()

    let sample = PassthroughSubject<(G1: (Double, Double), YL: (Double, Double), G2: (Double, Double), G3: (Double, Double)), Never>()
    let resetChart = PassthroughSubject<Void, Never>()
    let startMonitoring = PassthroughSubject<Void, Never>()
    let clsFirstReading = PassthroughSubject<Void, Never>()
    let clsReadingsDone = PassthroughSubject<[CLSReading], Never>()
    let clsReadingsError = PassthroughSubject<Reason, Never>()
    let tempReadingsDone = PassthroughSubject<([Double], [Double]), Never>()
    let configSuccess = PassthroughSubject<StreamType, Never>()

    @Published var measuredTmps: [Double] = []
    @Published var reportedTmps: [Double] = []
    @Published var currentTmp: Double?
    @Published var currentMeasuredTempC: Double?
    @Published var currentReportedTempC: Double?
    @Published var temperatureUnit: TemperatureUnit = .celsius
    @Published var deviceInfo: Set<DeviceInfoItem> = []
    @Published var batteryInfo: BatteryInfo?
    @Published var currentPeripheral: CBPeripheral?
    @Published var peripherals: [CBPeripheral] = []
    @Published var peripheralIDNameMapping: [String: String] = (UserDefaults.standard.object(forKey: SettingsKey.peripheralIDNameMapping) as? [String: String]) ?? [:]

    @Published var automaticMonitoring: Bool = false {
        didSet {
            UIApplication.shared.isIdleTimerDisabled = automaticMonitoring
            if automaticMonitoring {
                startMonitoring.send()
            } else {
                timerSubscription?.cancel()
                timerSubscription = nil
                stopMonitoring()
            }
        }
    }

    public struct DefaultsKeys {
        static let tempEnabled = "tempEnabled"
        static let unlTemp = "unlTemp"
        static let nibpEnabled = "nibpEnabled"
        static let unlNibp = "unlNibp"
        static let spo2Enabled = "spo2Enabled"
        static let unlSpo2 = "unlSpo2"
        static let transmitEnabled = SettingsKey.streamPackets
        static let transmitThousandHzEnabled = SettingsKey.streamThousandHz

        static let originalAnalyzeDataState = "originalAnalyzeDataState"
        static let autoSliderEnabled = "autoSliderEnabled"
        static let autoNibpSliderEnabled = "autoNibpSliderEnabled"
        static let viewConfigurationProcess = "viewConfigurationProcess"
        static let automaticLED = "automaticLED"
        static let analyzeDataEnabled = "analyzeDataEnabled"
    }

    @AppStorage(DefaultsKeys.tempEnabled) var tempEnabled: Bool = true
    @AppStorage(DefaultsKeys.nibpEnabled) var nibpEnabled: Bool = true
    @AppStorage(DefaultsKeys.spo2Enabled) var spo2Enabled: Bool = true
    @AppStorage(DefaultsKeys.unlTemp) var unlTemp: Bool = false
    @AppStorage(DefaultsKeys.unlNibp) var unlNibp: Bool = false
    @AppStorage(DefaultsKeys.unlSpo2) var unlSpo2: Bool = false

    var spo2GainCh1: Double { get { UserDefaults.standard.object(forKey: "spo2GainCh1") as? Double ?? 127 }
        set { UserDefaults.standard.set(newValue, forKey: "spo2GainCh1") } }
    var spo2GainCh2: Double { get { UserDefaults.standard.object(forKey: "spo2GainCh2") as? Double ?? 127 }
        set { UserDefaults.standard.set(newValue, forKey: "spo2GainCh2") } }
    var nibpGainCh1: Double { get { UserDefaults.standard.object(forKey: "nibpGainCh1") as? Double ?? 127 }
        set { UserDefaults.standard.set(newValue, forKey: "nibpGainCh1") } }
    var nibpGainCh2: Double { get { UserDefaults.standard.object(forKey: "nibpGainCh2") as? Double ?? 127 }
        set { UserDefaults.standard.set(newValue, forKey: "nibpGainCh2") } }

    private init() {
        bluetoothManager = BluetoothManager()
        bluetoothManager.delegate = self
        bluetoothManager.scanForPeripherals()

        Timer.publish(every: 5, tolerance: 2, on: .main, in: .default, options: nil)
            .autoconnect()
            .sink { [weak self] _ in
                self?.pruneStalePeripherals()
            }
            .store(in: &subscriptions)

        $peripheralIDNameMapping
            .sink { mapping in
                UserDefaults.standard.setValue(mapping, forKey: SettingsKey.peripheralIDNameMapping) }
            .store(in: &subscriptions)

        updateSettings()
    }
    private func pruneStalePeripherals() {
        let timeout: TimeInterval = 4
        let now = Date()

        peripherals.removeAll { peripheral in
            if peripheral.state == .connected { return false }
            guard let last = peripheralLastSeen[peripheral.identifier] else {
                return true
            }
            return now.timeIntervalSince(last) > timeout
        }

        let remainingIDs = Set(peripherals.map { $0.identifier })
        peripheralLastSeen = peripheralLastSeen.filter { remainingIDs.contains($0.key) }

        if let current = currentPeripheral, !peripherals.contains(current) {
            currentPeripheral = nil
            batteryInfo = nil
            deviceInfo = []
            clsFeatureResult = nil
            UserDefaults.standard.removeObject(forKey: SettingsKey.currentPeripheralUUID)
        }
    }

    private func updateSettings() {
        DispatchQueue.main.async {
            self.usesRealTimeDSP = UserDefaults.standard.bool(forKey: SettingsKey.realTimeDSP)
            let usesFahrenheit = UserDefaults.standard.bool(forKey: SettingsKey.temperatureUnitUsesFahrenheit)
            self.temperatureUnit = usesFahrenheit ? .fahrenheit : .celsius
        }
    }

    // MARK: - Real-time DSP toggle (Filter Waveforms)
    func setFilterWaveforms(_ enabled: Bool) {
        DispatchQueue.main.async {
            self.usesRealTimeDSP = enabled
            UserDefaults.standard.set(enabled, forKey: SettingsKey.realTimeDSP)
        }
    }

    private func updateCharts() {
        guard lastIndexFiltered < filtered.count else { return }

        sample.send((
            (timestamp, filtered[lastIndexFiltered].0),
            (timestamp, filtered[lastIndexFiltered].1),
            (timestamp, filtered[lastIndexFiltered].2),
            (timestamp, filtered[lastIndexFiltered].3)
        ))

        let effectiveHz: SamplingHz
        if transmitThousandHzEnabled {
            effectiveHz = (currentStream == .CLS) ? .hz200 : .hz100   // NIBP→200, SpO₂→100
        } else {
            effectiveHz = (currentStream == .CLS) ? .hz250 : .hz100   // NIBP→250, SpO₂→100
        }

        timestamp = ((timestamp + effectiveHz.decimalValue) * effectiveHz.roundValue).rounded() / effectiveHz.roundValue
        lastIndexFiltered += 1
    }
    private func updateSettingsInDatabase(grn1: UInt8, ylw: UInt8, grn2: UInt8, grn3: UInt8, save: Bool, led: Bool, gain: Bool) {
        var updated = self.clsFeatureResult

        if led {
            updated?.ledBrightness.grn1 = Double(grn1)
            updated?.ledBrightness.ylw  = Double(ylw)
            updated?.ledBrightness.grn2 = Double(grn2)
            updated?.ledBrightness.grn3 = Double(grn3)
        }

        if gain {
            updated?.gainControl.grn1 = Double(grn1)
            updated?.gainControl.ylw  = Double(ylw)
            updated?.gainControl.grn2 = Double(grn2)
            updated?.gainControl.grn3 = Double(grn3)
        }

        self.clsFeatureResult = updated
    }

    private func u8(_ x: Double) -> UInt8 { UInt8(max(0, min(255, round(x)))) }

    func commitCurrentAutoSettings(for stream: StreamType) {
        if let active = activeAutoStream, active != stream {
            print("🔒 Ignoring commit for \(stream) (activeAutoStream=\(active))")
            return
        }
        guard let current = self.clsFeatureResult else { return }

        let g = current.gainControl
        let l = current.ledBrightness

        let ch1Pair = UInt8(((g.grn1 + g.ylw) / 2.0).rounded())
        let ch2Pair = UInt8(((g.grn2 + g.grn3) / 2.0).rounded())

        switch stream {
        case .PLX:
            // SpO₂: CH1 == IR (pair grn1/ylw), CH2 == RED (pair grn2/grn3)
            self.spo2GainCh1 = Double(ch1Pair)
            self.spo2GainCh2 = Double(ch2Pair)
            //print("💾 Persisting SpO₂ (pair) — IR(CH1): \(ch1Pair)  RED(CH2): \(ch2Pair)")

        case .CLS:
            // NIBP: CH1 == BKY (pair grn1/ylw), CH2 == FRY (pair grn2/grn3)
            self.nibpGainCh1 = Double(ch1Pair)
            self.nibpGainCh2 = Double(ch2Pair)
            //print("💾 Persisting NIBP (pair) — BKY(CH1): \(ch1Pair)  FRY(CH2): \(ch2Pair)")

        default:
            break
        }

        setClsGainControl(
            auto: false,
            grn1: ch1Pair, ylw: ch1Pair,
            grn2: ch2Pair, grn3: ch2Pair,
            save: false
        ) { _ in
            self.setClsBrightness(
                auto: false,
                grn1: self.u8(l.grn1), ylw: self.u8(l.ylw),
                grn2: self.u8(l.grn2), grn3: self.u8(l.grn3),
                save: false
            ) { _ in
                self.getClSFeatureValues { _ in }
            }
        }
    }

    private func pairedGainsFromDefaults(for stream: StreamType) -> (UInt8, UInt8) {
        let d = UserDefaults.standard
        func u8Or(_ key: String, _ fallback: Double) -> UInt8 {
            if let v = d.object(forKey: key) as? Double { return u8(v) }
            return u8(fallback)
        }

        if stream == .PLX {
            let ch1 = u8Or("spo2GainCh1", self.spo2GainCh1) // IR  -> (grn1, ylw)
            let ch2 = u8Or("spo2GainCh2", self.spo2GainCh2) // RED -> (grn2, grn3)
            return (ch1, ch2)
        } else {
            let ch1 = u8Or("nibpGainCh1", self.nibpGainCh1) // BKY -> (grn1, ylw)
            let ch2 = u8Or("nibpGainCh2", self.nibpGainCh2) // FRY -> (grn2, grn3)
            return (ch1, ch2)
        }
    }

    func applyManualChannelGains(for stream: StreamType, save: Bool = false) {
        let (ch1, ch2) = pairedGainsFromDefaults(for: stream)

        if let r = clsFeatureResult {
            let g = r.gainControl
            let same =
            Int(g.grn1) == Int(ch1) &&
            Int(g.ylw ) == Int(ch1) &&
            Int(g.grn2) == Int(ch2) &&
            Int(g.grn3) == Int(ch2)
            if same {
                //print("↩️ applyManualChannelGains(\(stream.name)) skipped — already at CH1=\(ch1), CH2=\(ch2)")
                return
            }
        }

        //print("📤 applyManualChannelGains(\(stream.name)) → CH1=\(ch1) (grn1/ylw)  CH2=\(ch2) (grn2/grn3)")
        writePairGains(for: stream, ch1: ch1, ch2: ch2, save: save)
    }

}

// MARK: - Timer Restoration Helpers
extension Store {
    func restoreSpO2TimerIfSaved() {
        let saved = UserDefaults.standard.double(forKey: SettingsKey.savedCls2TimerForAuto)
        if saved > 0 {
            UserDefaults.standard.set(saved, forKey: SettingsKey.cls2TimerLimit)
            UserDefaults.standard.removeObject(forKey: SettingsKey.savedCls2TimerForAuto)
        }
    }

    func restoreNibpTimerIfSaved() {
        let saved = UserDefaults.standard.double(forKey: SettingsKey.savedCls1TimerForAuto)
        if saved > 0 {
            UserDefaults.standard.set(saved, forKey: SettingsKey.cls1TimerLimit)
            UserDefaults.standard.removeObject(forKey: SettingsKey.savedCls1TimerForAuto)
        }
    }
}

extension Store {
    var temperatureValueString: String {
        guard let currentTmp = currentTmp else { return "..." }
        switch temperatureUnit {
        case .celsius:    return String(format: "%.1f", currentTmp)
        case .fahrenheit: return String(format: "%.1f", currentTmp * 9.0 / 5.0 + 32.0)
        }
    }
    var temperatureReportedValueString: String { temperatureValueString(for: currentReportedTempC) }
    var temperatureMeasuredValueString: String { temperatureValueString(for: currentMeasuredTempC) }

    func temperatureValueString(for tmp: Double?) -> String {
        guard let tmp = tmp else { return "..." }
        switch temperatureUnit {
        case .celsius:    return String(format: "%.1f", tmp)
        case .fahrenheit: return String(format: "%.1f", tmp * 9.0 / 5.0 + 32.0)
        }
    }

    var temperatureUnitString: String { temperatureUnit.description }
}

extension Store {
    struct TempCalDeviceDTO: Codable {
        var name: String
        var applyCalibration: Bool
        var a: Double
        var b: Double
    }

    func currentTempCalibration() -> (enabled: Bool, a: Double, b: Double)? {
        guard
            let json = UserDefaults.standard.string(forKey: "tempDevicesStore"),
            let data = json.data(using: .utf8),
            let list = try? JSONDecoder().decode([TempCalDeviceDTO].self, from: data),
            !list.isEmpty
        else { return nil }

        let idxStored = UserDefaults.standard.integer(forKey: "selectedTempIndex")
        let idx = max(0, min(idxStored, list.count - 1))
        let dev = list[idx]
        return (enabled: dev.applyCalibration, a: dev.a, b: dev.b)
    }

    func applyTempCalibrationIfEnabled(to rawCelsius: Double) -> Double {
        guard let cal = currentTempCalibration(), cal.enabled else { return rawCelsius }
        return cal.a * rawCelsius + cal.b
    }
}
extension Store {
    struct SpO2AutoSnapshot: Equatable {
        var iteration: Int
        var status: String
        var irDC: Double
        var rdDC: Double
        var irAC: Int
        var rdAC: Int
        var irBrightness: Int
        var rdBrightness: Int
        var irGain: Int
        var rdGain: Int
    }
}

extension Store {
    struct NIBPAutoSnapshot: Equatable {
        var iteration: Int
        var status: String
        var bkyDC: Double
        var fryDC: Double
        var bkyAC: Int
        var fryAC: Int
        var bkyBrightness: Int
        var fryBrightness: Int
        var bkyGain: Int
        var fryGain: Int
    }
}

extension Store {
    func debugNIBPAdjusting(_ isActive: Bool, input: [CLSReading] = []) {
        if isActive {
            print("START debugNIBPAdjusting")
            debugNIBPAdjustingEnabled = true
            debugNIBPAdjustTick = 0
            debugNIBPBuffer.removeAll(keepingCapacity: false)
            realTimeNibpDCAchieved = 0

            debugNIBPAdjustTimer?.cancel()
            debugNIBPAdjustTimer = nil

            debugNIBPAdjustTimer = Timer
                .publish(every: 1.0, tolerance: 0.2, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    guard let self = self else { return }
                    guard self.debugNIBPAdjustingEnabled else { return }

                    if !input.isEmpty {
                        self.debugNIBPAdjustingStep(input)
                    } else {
                        self.debugNIBPAdjustingStepFromDebugBuffer()
                    }
                }

        } else {
            print("END debugNIBPAdjusting")
            debugNIBPAdjustingEnabled = false
            debugNIBPAdjustTimer?.cancel()
            debugNIBPAdjustTimer = nil
            debugNIBPBuffer.removeAll(keepingCapacity: false)

            resetWaveformsForNewRun()
        }
    }

    private func debugNIBPAdjustingStepFromDebugBuffer() {
        guard !debugNIBPBuffer.isEmpty else { return }
        debugNIBPAdjustingStep(debugNIBPBuffer)
    }

    private func debugNIBPAdjustingStep(_ input: [CLSReading]) {
        debugNIBPAdjustTick += 1
        print("NIBP debug tick =", debugNIBPAdjustTick, "buffer =", input.count)

        var dc1 = [Double](); dc1.reserveCapacity(input.count) // BKY DC
        var dc2 = [Double](); dc2.reserveCapacity(input.count) // FRY DC
        var ac1 = [Double](); ac1.reserveCapacity(input.count)
        var ac2 = [Double](); ac2.reserveCapacity(input.count)

        for e in input {
            dc1.append(e.DC1)
            dc2.append(e.DC2)
            ac1.append(e.AC1)
            ac2.append(e.AC2)
        }

        let range = 19 ..< min(119, dc1.count)
        guard range.lowerBound < range.upperBound else { return }

        let BKY_DC_max = dc1[range].max() ?? 0.0
        let FRY_DC_max = dc2[range].max() ?? 0.0

        //ABD Algos

        _ = (BKY_DC_max, FRY_DC_max, ac1, ac2)
    }
    func debugSpO2Adjusting(_ isActive: Bool, input: [CLSReading] = []) {
            if isActive {
                print("START debugSpO2Adjusting")

                realTimeDCAchieved = 0
                waitTimeFlag = 0
                waitTimeCounter = 0

                debugSpO2AdjustingEnabled = true
                debugSpO2AdjustTick = 0
                debugSpO2Buffer.removeAll(keepingCapacity: false)

                debugSpO2AdjustTimer?.cancel()
                debugSpO2AdjustTimer = nil

                debugSpO2AdjustTimer = Timer
                    .publish(every: 1.0, tolerance: 0.2, on: .main, in: .common)
                    .autoconnect()
                    .sink { [weak self] _ in
                        guard let self = self else { return }
                        guard self.debugSpO2AdjustingEnabled else { return }

                        if !input.isEmpty {
                            self.debugSpO2AdjustingStep(input)
                        } else {
                            self.debugSpO2AdjustingStepFromDebugBuffer()
                        }
                    }

            } else {
                print("END debugSpO2Adjusting")
                debugSpO2AdjustingEnabled = false
                debugSpO2AdjustTimer?.cancel()
                debugSpO2AdjustTimer = nil
                debugSpO2Buffer.removeAll(keepingCapacity: false)

                resetWaveformsForNewRun()
            }
        }

    private func debugSpO2AdjustingStepFromDebugBuffer() {
        guard !debugSpO2Buffer.isEmpty else { return }
        debugSpO2AdjustingStep(debugSpO2Buffer)
    }

    private func debugSpO2AdjustingStep(_ input: [CLSReading]) {
        debugSpO2AdjustTick += 1
        print("debug tick =", debugSpO2AdjustTick, "buffer =", input.count)

        var input0 = [Double](); input0.reserveCapacity(input.count)
        var input1 = [Double](); input1.reserveCapacity(input.count)
        var input2 = [Double](); input2.reserveCapacity(input.count)
        var input3 = [Double](); input3.reserveCapacity(input.count)

        for e in input {
            input0.append(e.DC1)
            input1.append(e.DC2)
            input2.append(e.AC1)
            input3.append(e.AC2)
        }

        let brightnessIR  = clsFeatureResult?.ledBrightness.grn2 ?? 127.0
        let brightnessRED = clsFeatureResult?.ledBrightness.ylw  ?? 127.0
        let acGainIR  = spo2GainCh1
        let acGainRED = spo2GainCh2

        // ABD Algos
        _ = (brightnessIR, brightnessRED, acGainIR, acGainRED, input0, input1, input2, input3)
        var BrightnessFlag = 0
        if ((debugSpO2AdjustTick == 2 || debugSpO2AdjustTick == 4 || debugSpO2AdjustTick == 6 || debugSpO2AdjustTick == 8  || debugSpO2AdjustTick == 10 || debugSpO2AdjustTick == 12 || debugSpO2AdjustTick == 14 || debugSpO2AdjustTick == 16) && realTimeDCAchieved == 0) {
            // New Code
            let brightnessIR = clsFeatureResult?.ledBrightness.grn2 ?? 127.0
            let brightnessRED = clsFeatureResult?.ledBrightness.ylw ?? 127.0
            let bkYLWSliderValue: Double = Double(Store.shared.clsFeatureResult?.ledBrightness.grn1 ?? 127.0)
            let frYLWSliderValue: Double = Double(Store.shared.clsFeatureResult?.ledBrightness.grn3 ?? 127.0)
            //let meanredDCComp = mean(y: buffer1)
            //let meanirDCComp = mean(y: buffer0)
            let RD_DC_Array_max: Double = input1[19 ..< 119].max() ?? 0.0
            let IR_DC_Array_max: Double = input0[19 ..< 119].max() ?? 0.0

            var updatedBrightnessIR = brightnessIR
            var updatedBrightnessRD = brightnessRED

            print("realTimeIteration", self.realTimeIteration)
            print("IR_DC_Array_max: ", IR_DC_Array_max)
            print("RD_DC_Array_max: ", RD_DC_Array_max)

            /* *********************PI************************* */
            // USER SETTINGS
            let targetDC: Double = 2.6
            //var brightness: Int = 120          // 0–255
            let Kp: Double = 20.0              // tune
            let Ki: Double = 0.5               // tune

            // INTERNAL STATE
            var integral: Double = 0.0
            var integralRed: Double = 0.0
            if((IR_DC_Array_max < 2.4 || IR_DC_Array_max > 2.7)) {
                // Error
                let error = targetDC - IR_DC_Array_max

                // Integral update (fixed step, no dt)
                integral += error


                // Anti-windup
                if integral > 30 { integral = 30 }
                if integral < -30 { integral = -30 }

                // PI output
                let output = Kp * error + Ki * integral

                // Adjust brightness
                updatedBrightnessIR += Double(Int(output))

                // Clamp to 0–255
                if updatedBrightnessIR < 0 { updatedBrightnessIR = 0 }
                if updatedBrightnessIR > 255 { updatedBrightnessIR = 255 }

                // Send to device / update slider
                BrightnessFlag = 1
            }

            if(RD_DC_Array_max < 2.5 || RD_DC_Array_max > 2.8) {
                let errorRed = targetDC - RD_DC_Array_max

                integralRed += errorRed

                if integralRed > 30 { integralRed = 30 }
                if integralRed < -30 { integralRed = -30 }

                let outputRed = Kp * errorRed + Ki * integralRed

                updatedBrightnessRD += Double(Int(outputRed))

                if updatedBrightnessRD < 0 { updatedBrightnessRD = 0 }
                if updatedBrightnessRD > 255 { updatedBrightnessRD = 255 }

                BrightnessFlag = 1
            }


            /* **********************PI Ends************************ */
            if (BrightnessFlag == 1) {
                setClsBrightness(auto: false, grn1: UInt8(bkYLWSliderValue), ylw: UInt8(updatedBrightnessRD), grn2: UInt8(updatedBrightnessIR), grn3: UInt8(frYLWSliderValue), save: true) { error in
                    if let error = error {
                        // Handle the error
                        print("Error: \(error.localizedDescription)")
                    } else {
                        // Success case
                        print("Line 693: IR Brightness settings changed successfully set to ", updatedBrightnessIR)
                        print("Line 694: RD Brightness settings changed successfully set to ", updatedBrightnessRD)
                    }
                }
            }
            else {
                print("realTimeDCAchieved")
                realTimeDCAchieved = 1
                waitTimeFlag = 1
            }
        }

    }


    private func filter(_ input: [CLSReading]) -> [(Double, Double, Double, Double)] {
        return autoreleasepool {
            var input0 = [Double](); input0.reserveCapacity(input.count)
            var input1 = [Double](); input1.reserveCapacity(input.count)
            var input2 = [Double](); input2.reserveCapacity(input.count)
            var input3 = [Double](); input3.reserveCapacity(input.count)

            for e in input {
                input0.append(e.DC1)
                input1.append(e.DC2)
                input2.append(e.AC1)
                input3.append(e.AC2)
            }

            let algoAC1 = input2.filter { !$0.isNaN }
            let algoAC2 = input3.filter { !$0.isNaN }
            let maAC1 = movingAverage(input: algoAC1, windowS: 25)
            let maAC2 = movingAverage(input: algoAC2, windowS: 25)

            /* Real Time CLS amplitude and RR Calculation (disabled during AutoSlider tuning) */
            if currentStream == .CLS && !autoNibpSliderEnabled {
                if (realTimeIteration <= 10) {
                    buffer0.append(contentsOf: input0[19 ..< 119])
                    buffer1.append(contentsOf: input1[19 ..< 119])
                    buffer2.append(contentsOf: input2[19 ..< 119])
                    buffer3.append(contentsOf: input3[19 ..< 119])
                }

                if (realTimeIteration == 10) {

                    previous_BKY_AC_Amplitude = Current_BKY_AC_Amplitude
                    previous_FRY_AC_Amplitude = Current_FRY_AC_Amplitude

                    (Current_BKY_AC_Amplitude, Current_FRY_AC_Amplitude, AC1timeTops, AC2timeTops, AC1timeBtms, AC2timeBtms) = CalculateAmplitude(realTimeSampFreq: 200.0, AC1: buffer2, AC2: buffer3, ac1_prev_amp: previous_BKY_AC_Amplitude, ac2_prev_amp: previous_FRY_AC_Amplitude)

                    print("previous_BKY_AC_Amplitude: ", Current_BKY_AC_Amplitude)
                    print("previous_FRY_AC_Amplitude: ", Current_FRY_AC_Amplitude)

                    /*CLS Respiration Calculations*/
                    /* let (CLSt1, CLSpp1) = generateIntervalTimeSeries(ppTopTimes: AC1timeTops)
                     let CLSrsp1 = getNewResp(times: CLSt1, intervals: CLSpp1, resampF: 10.0)

                     let (CLSt2, CLSpp2) = generateIntervalTimeSeries(ppTopTimes: AC2timeTops)
                     let CLSrsp2 = getNewResp(times: CLSt2, intervals: CLSpp2, resampF: 10.0)

                     realTimeRR = Int(round((CLSrsp1 + CLSrsp2) / 2))

                     if(realTimeRR > 0) {
                     print("RealTime CLS RR: ", realTimeRR)
                     }*/
                    /*CLS Respiration Calculations*/

                    /*Calculate Real Time HR*/
                    (realTimeClsHR, _) = getHRAndHRV(AC1timeTops: AC1timeTops, AC1timeBtms: AC1timeBtms, AC2timeTops: AC2timeTops, AC2timeBtms: AC2timeBtms)

                    if(realTimeClsHR > 0) {
                        print("RealTime CLS HR: ", Int(round(realTimeClsHR)))
                    }
                    /*Calculate Real Time HR End*/

                    realTimeIteration = 6
                    buffer0.removeFirst(400)
                    buffer1.removeFirst(400)
                    buffer2.removeFirst(400)
                    buffer3.removeFirst(400)
                }
            }

            /* Real Time Spo2 Calculation (disabled during AutoSlider tuning) */
            if currentStream == .PLX && !autoSliderEnabled {
                var BrightnessFlag = 0
                if (realTimeIteration <= 8) {
                    buffer0.append(contentsOf: input0[19 ..< 119])
                    buffer1.append(contentsOf: input1[19 ..< 119])
                    buffer2.append(contentsOf: input2[19 ..< 119])
                    buffer3.append(contentsOf: input3[19 ..< 119])

                    if ((realTimeIteration == 1 || realTimeIteration == 5 || realTimeIteration == 8) && realTimeDCAchieved == 0) {
                        // New Code
                        let brightnessIR = clsFeatureResult?.ledBrightness.grn2 ?? 127.0
                        let brightnessRED = clsFeatureResult?.ledBrightness.ylw ?? 127.0
                        let bkYLWSliderValue: Double = Double(Store.shared.clsFeatureResult?.ledBrightness.grn1 ?? 127.0)
                        let frYLWSliderValue: Double = Double(Store.shared.clsFeatureResult?.ledBrightness.grn3 ?? 127.0)
                        //let meanredDCComp = mean(y: buffer1)
                        //let meanirDCComp = mean(y: buffer0)
                        let RD_DC_Array_max: Double = input1[19 ..< 119].max() ?? 0.0
                        let IR_DC_Array_max: Double = input0[19 ..< 119].max() ?? 0.0

                        var updatedBrightnessIR = brightnessIR
                        var updatedBrightnessRD = brightnessRED

                        print("realTimeIteration", self.realTimeIteration)
                        print("IR_DC_Array_max: ", IR_DC_Array_max)
                        print("RD_DC_Array_max: ", RD_DC_Array_max)

                        /* *********************PI************************* */
                        // USER SETTINGS
                        let targetDC: Double = 2.6
                        //var brightness: Int = 120          // 0–255
                        let Kp: Double = 20.0              // tune
                        let Ki: Double = 0.5               // tune

                        // INTERNAL STATE
                        var integral: Double = 0.0
                        var integralRed: Double = 0.0
                        if((IR_DC_Array_max < 2.4 || IR_DC_Array_max > 2.7)) {
                            // Error
                            let error = targetDC - IR_DC_Array_max

                            // Integral update (fixed step, no dt)
                            integral += error


                            // Anti-windup
                            if integral > 30 { integral = 30 }
                            if integral < -30 { integral = -30 }

                            // PI output
                            let output = Kp * error + Ki * integral

                            // Adjust brightness
                            updatedBrightnessIR += Double(Int(output))

                            // Clamp to 0–255
                            if updatedBrightnessIR < 0 { updatedBrightnessIR = 0 }
                            if updatedBrightnessIR > 255 { updatedBrightnessIR = 255 }

                            // Send to device / update slider
                            BrightnessFlag = 1
                        }

                        if(RD_DC_Array_max < 2.5 || RD_DC_Array_max > 2.8) {
                            let errorRed = targetDC - RD_DC_Array_max

                            integralRed += errorRed

                            if integralRed > 30 { integralRed = 30 }
                            if integralRed < -30 { integralRed = -30 }

                            let outputRed = Kp * errorRed + Ki * integralRed

                            updatedBrightnessRD += Double(Int(outputRed))

                            if updatedBrightnessRD < 0 { updatedBrightnessRD = 0 }
                            if updatedBrightnessRD > 255 { updatedBrightnessRD = 255 }

                            BrightnessFlag = 1
                        }


                        /* **********************PI Ends************************ */
                        if (BrightnessFlag == 1) {
                            setClsBrightness(auto: false, grn1: UInt8(bkYLWSliderValue), ylw: UInt8(updatedBrightnessRD), grn2: UInt8(updatedBrightnessIR), grn3: UInt8(frYLWSliderValue), save: true) { error in
                                if let error = error {
                                    // Handle the error
                                    print("Error: \(error.localizedDescription)")
                                } else {
                                    // Success case
                                    print("Line 693: IR Brightness settings changed successfully set to ", updatedBrightnessIR)
                                    print("Line 694: RD Brightness settings changed successfully set to ", updatedBrightnessRD)
                                }
                            }
                        }
                        else {
                            realTimeDCAchieved = 1
                            waitTimeFlag = 1
                        }
                    }

                    if(waitTimeFlag == 1) {
                        if(realTimeIteration == 1) {
                            waitTimeCounter = waitTimeCounter + 11
                        }
                        else{
                            waitTimeCounter = waitTimeCounter + 1
                        }
                    }

                    //self.spo2GainCh1 = spo2GainCh1 + 1.0
                    //self.spo2GainCh2 = spo2GainCh2 + 1.0

                    //print("Updated_IR_Gain: ", self.spo2GainCh1)
                    //print("Updated_RD_Gain: ", self.spo2GainCh2)
                }

                if (realTimeIteration == 8) {
                    let brightnessIR = clsFeatureResult?.ledBrightness.grn2 ?? 127.0
                    let brightnessRED = clsFeatureResult?.ledBrightness.ylw ?? 127.0
                    var acGainIR = self.spo2GainCh1
                    var acGainRED = self.spo2GainCh2
                    print("Current_IR_Gain: ", acGainIR)
                    print("Current_RD_Gain: ", acGainRED)

                    (realTimeSpo2, realTimePlxHR) = computeRealTimeSpo2(
                        realTimeSampFreq: 100.0,
                        DC1: buffer0, DC2: buffer1, AC1: buffer2, AC2: buffer3,
                        brightnessIR: brightnessIR, brightnessRED: brightnessRED,
                        acGainIR: acGainIR, acGainRED: acGainRED
                    )
                    previous_IR_AC_Amplitude = Current_IR_AC_Amplitude
                    previous_RD_AC_Amplitude = Current_RD_AC_Amplitude

                    (Current_IR_AC_Amplitude, Current_RD_AC_Amplitude, AC1timeTops, AC2timeTops, AC1timeBtms, AC2timeBtms) = CalculateAmplitude(realTimeSampFreq: 100.0, AC1: buffer2, AC2: buffer3, ac1_prev_amp: previous_IR_AC_Amplitude, ac2_prev_amp: previous_RD_AC_Amplitude)

                    print("Current_IR_AC_Amplitude: ", Current_IR_AC_Amplitude)
                    print("Current_RD_AC_Amplitude: ", Current_RD_AC_Amplitude)

                    /* **************START**************** */
                    let RD_DC_Array_max: Double = input1[19 ..< 119].max() ?? 0.0
                    let IR_DC_Array_max: Double = input0[19 ..< 119].max() ?? 0.0
                    print("WaitTimeCounter: ", waitTimeCounter)
                    if ((IR_DC_Array_max > 2.4 || IR_DC_Array_max < 2.7) && (RD_DC_Array_max > 2.5 || RD_DC_Array_max < 2.8) && waitTimeCounter >= 10) {
                        if (Current_IR_AC_Amplitude > Current_RD_AC_Amplitude ) {
                            if ((Current_IR_AC_Amplitude < 125 || Current_IR_AC_Amplitude > 300) && realTimeACAchieved == 0) {
                                realTimeACAchievedFirstTime = 0

                                if (Current_IR_AC_Amplitude < 125) {
                                    acGainIR += 20
                                }
                                else if(Current_IR_AC_Amplitude > 300) {
                                    acGainIR -= 20
                                }

                                if acGainIR < 0 { acGainIR = 0 }
                                if acGainIR > 255 { acGainIR = 255 }

                                writePairGains(
                                    for: .PLX,
                                    ch1: UInt8(acGainIR),
                                    ch2: UInt8(acGainIR)
                                )

                                self.spo2GainCh1 = acGainIR
                                self.spo2GainCh2 = acGainIR
                                print("Updated_IR_Gain: ", self.spo2GainCh1)
                                print("Updated_RD_Gain: ", self.spo2GainCh2)
                            }
                            else {
                                if(realTimeACAchievedFirstTime == 0) {
                                    realTimeACAchievedFirstTime = 1
                                }
                                else
                                {
                                    realTimeACAchieved = 1
                                }
                            }
                        }
                        else {
                            if ((Current_RD_AC_Amplitude < 125 || Current_RD_AC_Amplitude > 300) && realTimeACAchieved == 0) {
                                realTimeACAchievedFirstTime = 0

                                if (Current_RD_AC_Amplitude < 125) {
                                    acGainRED += 20
                                }
                                else if(Current_RD_AC_Amplitude > 300) {
                                    acGainRED -= 20
                                }

                                if acGainRED < 0 { acGainRED = 0 }
                                if acGainRED > 255 { acGainRED = 255 }

                                writePairGains(
                                    for: .PLX,
                                    ch1: UInt8(acGainRED),
                                    ch2: UInt8(acGainRED)
                                )

                                self.spo2GainCh1 = acGainRED
                                self.spo2GainCh2 = acGainRED
                                print("Updated_IR_Gain: ", self.spo2GainCh1)
                                print("Updated_RD_Gain: ", self.spo2GainCh2)
                            }
                            else {
                                if(realTimeACAchievedFirstTime == 0) {
                                    realTimeACAchievedFirstTime = 1
                                }
                                else
                                {
                                    realTimeACAchieved = 1
                                }
                            }
                        }
                    }

                    /* ***********END************ */


                    /*PLX Respiration Calculations*/
                    /*let (CLSt1, CLSpp1) = generateIntervalTimeSeries(ppTopTimes: AC1timeTops)
                     let CLSrsp1 = getNewResp(times: CLSt1, intervals: CLSpp1, resampF: 10.0)

                     let (CLSt2, CLSpp2) = generateIntervalTimeSeries(ppTopTimes: AC2timeTops)
                     let CLSrsp2 = getNewResp(times: CLSt2, intervals: CLSpp2, resampF: 10.0)

                     realTimeRR = Int(round((CLSrsp1 + CLSrsp2) / 2))

                     if(realTimeRR > 0) {
                     print("RealTime PLX RR: ", realTimeRR)
                     }*/
                    /*PLX Respiration Calculations*/

                    if(realTimeSpo2 > 0) {
                        print("RealTime SpO2: ", realTimeSpo2)
                        print("RealTime PLX HR: ", Int(round(realTimePlxHR)))
                    }

                    realTimeIteration = 2
                    buffer0.removeFirst(600)
                    buffer1.removeFirst(600)
                    buffer2.removeFirst(600)
                    buffer3.removeFirst(600)
                }
            }
            /* End Real Time Spo2 Calculation */

            if autoSliderEnabled && currentStream == .PLX {
                spo2AutoSlider(
                    Iteration: spo2Iteration,
                    IR_DC_Array: input0,
                    RD_DC_Array: input1,
                    IR_AC_Array: maAC1,
                    RD_AC_Array: maAC2,
                    IR_RAW_AC_Array: input2,
                    RD_RAW_AC_Array: input3
                )
            }
            if autoNibpSliderEnabled && currentStream == .CLS {
                nibpAutoSlider(
                    Iteration: spo2Iteration,
                    BKY_DC_Array: input0,
                    FRY_DC_Array: input1,
                    BKY_AC_Array: maAC1,
                    FRY_AC_Array: maAC2,
                    BKY_RAW_AC_Array: input2,
                    FRY_RAW_AC_Array: input3
                )
            }

            let useFilteredForUI = (usesRealTimeDSP ?? false) && (clsFeatureResult != nil)
            if !useFilteredForUI { return input.map { ($0.DC1, $0.DC2, $0.AC1, $0.AC2) } }

            var out = [(Double, Double, Double, Double)]()
            out.reserveCapacity(maAC1.count)
            for i in 0..<maAC1.count {
                out.append((input0[i], input1[i], -maAC1[i], -maAC2[i]))
            }
            return out
        }
    }
}

extension Store {
    func monitorTemp(duration: TimeInterval) {
        bluetoothManager.setTemperatureCharacteristic(notifying: true)
        monitoringTimerSubscription = Timer.publish(every: duration, tolerance: nil, on: .main, in: .default, options: nil)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else {
                    self?.monitoringTimerSubscription?.cancel()
                    self?.monitoringTimerSubscription = nil
                    return
                }
                let measuredTmps = self.measuredTmps
                let reportedTmps = self.reportedTmps
                self.stopMonitoring()
                self.tempReadingsDone.send((measuredTmps, reportedTmps))
                if self.automaticMonitoring { self.scheduleNextAutoRun() }
            }
    }

    func monitorCLS(stream: StreamType) {
        let sampleRate: SamplingHz
        if stream == .CLS {
            sampleRate = .hz250
        } else if stream == .PLX {
            sampleRate = .hz100
        } else {
            sampleRate = clsFeatureResult?.sampleRate ?? .hz100
        }

        bluetoothManager.setClsStream(stream, sampleRate: sampleRate, save: false) { [weak self] error in
            guard let self = self, error == nil else {
                self?.stopMonitoring()
                self?.clsReadingsError.send(.timeout)
                if let self = self, self.automaticMonitoring { self.scheduleNextAutoRun() }
                return
            }

            self.currentStream = stream
            let runID = UUID()
            self.runToken = runID

            if !((stream == .PLX && self.autoSliderEnabled) || (stream == .CLS && self.autoNibpSliderEnabled)) {
                self.applyManualChannelGains(for: stream, save: false)
            }
            self.bluetoothManager.setClsCharacteristic(notifying: true)

            if !(self.isAdjusting) {
                self.monitoringTimerSubscription?.cancel()
                self.monitoringTimerSubscription = nil
                self.monitoringTimerSubscription = Timer.publish(every: 5, tolerance: nil, on: .main, in: .default, options: nil)
                    .autoconnect()
                    .sink { [weak self] _ in
                        guard let self = self else { return }
                        guard self.runToken == runID else { return }
                        if self.isAdjusting { return }
                        if (stream == .CLS && self.autoNibpSliderEnabled) || (stream == .PLX && self.autoSliderEnabled) { return }

                        self.stopMonitoring()
                        self.clsReadingsError.send(.timeout)
                        if self.automaticMonitoring { self.scheduleNextAutoRun() }
                    }
            } else {
                self.monitoringTimerSubscription?.cancel()
                self.monitoringTimerSubscription = nil
            }
        }
    }

    private func startCLSMonitoring(stream: StreamType) {
        let runID = self.runToken
        let duration = stream.duration

        monitoringTimerSubscription?.cancel()
        monitoringTimerSubscription = nil

        monitoringTimerSubscription = Timer.publish(every: duration, tolerance: nil, on: .main, in: .default, options: nil)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else {
                    self?.stopMonitoring()
                    return
                }
                guard self.runToken == runID else { return }

                let raw = self.raw
                self.stopMonitoring()
                let autoForStream = (stream == .PLX && self.autoSliderEnabled) || (stream == .CLS && self.autoNibpSliderEnabled)
                if autoForStream, self.clsFeatureResult != nil {
                    self.commitCurrentAutoSettings(for: stream)
                }
                self.clsReadingsDone.send(raw)
                if stream == .PLX {
                    if self.autoSliderEnabled {
                        self.autoSliderEnabled = false
                    }
                    self.unlSpo2 = false
                    self.restoreSpO2TimerIfSaved()
                }
                if stream == .CLS {
                    if self.autoNibpSliderEnabled {
                        self.autoNibpSliderEnabled = false
                    }
                    self.unlNibp = false
                    self.restoreNibpTimerIfSaved()
                }
                if self.automaticMonitoring { self.scheduleNextAutoRun() }
            }
    }

    func stopMonitoring() {
        let streamAtStop = self.currentStream
        let wasAuto = (autoSliderEnabled || autoNibpSliderEnabled)

        runToken = UUID()
        isAdjusting = false

        bluetoothManager.setTemperatureCharacteristic(notifying: false)
        bluetoothManager.setClsCharacteristic(notifying: false)
        bluetoothManager.stopClsStream()

        monitoringTimerSubscription?.cancel()
        monitoringTimerSubscription = nil
        spo2AutoSnapshot = nil
        nibpAutoSnapshot = nil

        if !automaticMonitoring {
            timerSubscription?.cancel()
            timerSubscription = nil
        }


        if let lastStream = streamAtStop, !wasAuto {
            applyManualChannelGains(for: lastStream, save: false)
        }

        resetData()
        tempVar = 0
        spo2Iteration = 0
        realTimeIteration = 0
        realTimeDCAchieved = 0
        realTimeACAchieved = 0
        realTimeACAchievedFirstTime = 0
        realTimeNibpDCAchieved = 0
        waitTimeFlag = 0
        waitTimeCounter = 0
    }

    private func resetData() {
        print("resetData")
        raw.removeAll(keepingCapacity: false)
        filtered.removeAll(keepingCapacity: false)
        measuredTmps.removeAll(keepingCapacity: false)
        reportedTmps.removeAll(keepingCapacity: false)
        currentStream = nil
        lastIndexRaw = 0
        lastIndexFiltered = 0
        timestamp = 0
        /* Real Time Spo2 Calculation*/
        buffer0.removeAll(keepingCapacity: false)
        buffer1.removeAll(keepingCapacity: false)
        buffer2.removeAll(keepingCapacity: false)
        buffer3.removeAll(keepingCapacity: false)
        /* Real Time Spo2 Calculation*/
    }
}

extension Store: BluetoothManagerDelegate {
    func getCurrentPeripheral() -> CBPeripheral? { currentPeripheral }

    func addPeripheral(_ peripheral: CBPeripheral) {
        // Filter out non-Healthsign devices
        guard let name = peripheral.name else { return }

        // Allow original MCLSWB or the new mclttm devices
        if !name.hasPrefix("MCLSWB-") && !name.localizedCaseInsensitiveContains("mclttm") {
             return
        }

        // Update last-seen timestamp on every advertisement
        peripheralLastSeen[peripheral.identifier] = Date()

        // Only add to the list once
        if !peripherals.contains(peripheral) {
            if let currentPeripheralUUID = UserDefaults.standard.string(forKey: SettingsKey.currentPeripheralUUID),
               currentPeripheralUUID == peripheral.identifier.uuidString {
                connect(with: peripheral)
            }
            peripherals.append(peripheral)
        }
    }

    func removePeripheral(_ peripheral: CBPeripheral) {
        peripheralLastSeen[peripheral.identifier] = nil

        guard let index = peripherals.firstIndex(of: peripheral) else { return }
        peripherals.remove(at: index)

        if currentPeripheral == peripheral {
            currentPeripheral = nil
            batteryInfo = nil
            deviceInfo = []
            clsFeatureResult = nil
            UserDefaults.standard.removeObject(forKey: SettingsKey.currentPeripheralUUID)
        }
    }

    func writePairGains(for stream: StreamType, ch1: UInt8, ch2: UInt8, save: Bool = false) {
        setClsGainControl(
            auto: false,
            grn1: ch1, ylw: ch1,
            grn2: ch2, grn3: ch2,
            save: false
        ) { _ in
            self.getClSFeatureValues { _ in }
        }
    }

    func update(_ result: CLSFeatureResult) {
        clsFeatureResult = result
        let g = result.gainControl
        let l = result.ledBrightness
        //print("📥 Device reported gains → grn1: \(Int(g.grn1))  ylw: \(Int(g.ylw))  grn2: \(Int(g.grn2))  grn3: \(Int(g.grn3))")
        //print("📥 NATIVE Device reported LED brightness → Back YLW: \(Int(l.grn1)) Front YLW: \(Int(l.grn3)) IR: \(Int(l.grn2)) RED: \(Int(l.ylw))  ")
    }

    func append(measuredTmp: Double, reportedTmp: Double) {
        measuredTmps.append(measuredTmp)
        reportedTmps.append(reportedTmp)
        currentMeasuredTempC = measuredTmp
        currentReportedTempC = reportedTmp
        currentTmp = reportedTmp
    }

    func append(reading: CLSReading) {
        guard let stream = currentStream else { return }

        if isAdjusting {
            if debugSpO2AdjustingEnabled && stream == .PLX && !autoSliderEnabled {
                debugSpO2Buffer.append(reading)
                if debugSpO2Buffer.count > windowSize {
                    debugSpO2Buffer.removeFirst(debugSpO2Buffer.count - windowSize)
                }
                return
            }

            if debugNIBPAdjustingEnabled && stream == .CLS && !autoNibpSliderEnabled {
                debugNIBPBuffer.append(reading)
                if debugNIBPBuffer.count > windowSize {
                    debugNIBPBuffer.removeFirst(debugNIBPBuffer.count - windowSize)
                }
                return
            }

            let ok = (autoSliderEnabled && stream == .PLX) || (autoNibpSliderEnabled && stream == .CLS)
            guard ok else { return }
        }

        if raw.isEmpty {
            print("did see empty raw for stream \(stream)")
            resetChart.send(())
            clsFirstReading.send()
            if !isAdjusting { startCLSMonitoring(stream: stream) }
        }
        raw.append(reading)
    }


    func insert(deviceInfo item: DeviceInfoItem) {
        self.deviceInfo.insert(item)
    }
    func append(batteryInfo: BatteryInfo) { self.batteryInfo = batteryInfo }
    func stopThreshold() { clsReadingsError.send(.aclThreshold) }
}

extension Store {
    func displayName(for peripheral: CBPeripheral) -> (name: String, connected: Bool) {
        let uuid = peripheral.identifier.uuidString
        let name = peripheralIDNameMapping[uuid] ?? peripheral.name ?? uuid.components(separatedBy: "-").first ?? uuid
        return (name, uuid == currentPeripheral?.identifier.uuidString)
    }

    func setDisplayName(_ newName: String, for peripheral: CBPeripheral) {
        peripheralIDNameMapping[peripheral.identifier.uuidString] = newName
    }

    func connect(with peripheral: CBPeripheral) {
        currentPeripheral.map(bluetoothManager.disconnect(peripheral:))
        currentPeripheral = peripheral
        UserDefaults.standard.setValue(peripheral.identifier.uuidString, forKey: SettingsKey.currentPeripheralUUID)
        bluetoothManager.connect(peripheral: peripheral)
    }

    func disconnect(from peripheral: CBPeripheral) {
        bluetoothManager.disconnect(peripheral: peripheral)
        if currentPeripheral == peripheral {
            currentPeripheral = nil
            UserDefaults.standard.removeObject(forKey: SettingsKey.currentPeripheralUUID)
            batteryInfo = nil
            deviceInfo = []
            clsFeatureResult = nil
        }
    }

    func getClSFeatureValues(completion: @escaping(Error?) -> ()) {
        bluetoothManager.getCLSFeatureValue(completion: completion)
    }

    func saveCLSFeatureValue(completion: @escaping(Error?) -> ()) {
        bluetoothManager.saveCLSFeatureValue(completion: completion)
    }

    func setClsStream(_ stream: StreamType, sampleRate: SamplingHz, save: Bool, completion: @escaping(Error?) -> ()) {
        bluetoothManager.setClsStream(stream, sampleRate: sampleRate, save: save, completion: completion)
    }

    func setClsBrightness(auto: Bool, grn1: UInt8, ylw: UInt8, grn2: UInt8, grn3: UInt8, save: Bool, completion: @escaping(Error?) -> ()) {
        bluetoothManager.setClsBrightness(auto: auto, grn1: grn1, ylw: ylw, grn2: grn2, grn3: grn3, save: save, completion: completion)
        updateSettingsInDatabase(grn1: grn1, ylw: ylw, grn2: grn2, grn3: grn3, save: save, led: true, gain: false)
    }

    func setClsGainControl(auto: Bool, grn1: UInt8, ylw: UInt8, grn2: UInt8, grn3: UInt8, save: Bool, completion: @escaping(Error?) -> ()) {
        bluetoothManager.setClsGainControl(auto: auto, grn1: grn1, ylw: ylw, grn2: grn2, grn3: grn3, save: save, completion: completion)
        updateSettingsInDatabase(grn1: grn1, ylw: ylw, grn2: grn2, grn3: grn3, save: save, led: false, gain: true)
    }
}

extension Store {
    enum Reason: Error { case timeout, aclThreshold }
}

extension Store.Reason {
    var title: String {
        switch self { case .timeout: return "Failed"; case .aclThreshold: return "Alert" }
    }
    var description: String {
        switch self {
        case .timeout: return "Failed to get readings"
        case .aclThreshold: return "Measurement aborted due to excessive motion. Please sit calmly and try again."
        }
    }
}

extension Store {
    func scheduleNextAutoRun() {
        timerSubscription?.cancel()
        timerSubscription = nil

        let minutes = UserDefaults.standard.double(forKey: SettingsKey.automaticMonitoringInterval)
        let seconds = max(1.0, minutes * 60.0)

        timerSubscription = Timer.publish(every: seconds, tolerance: 1.0, on: .main, in: .default, options: nil)
            .autoconnect()
            .prefix(1)
            .sink { [weak self] _ in
                guard let self = self, self.automaticMonitoring else { return }
                self.startMonitoring.send()
            }
    }
}

extension Store {
    func finishSpO2Early() {
        DispatchQueue.main.async {
            let rawSnapshot = self.raw
            let wasAuto = self.autoSliderEnabled

            self.stopMonitoring()

            if wasAuto, self.clsFeatureResult != nil {
                self.commitCurrentAutoSettings(for: .PLX)
                self.autoSliderEnabled = false
                self.unlSpo2 = false
                self.restoreSpO2TimerIfSaved()
                if self.automaticMonitoring { self.scheduleNextAutoRun() }
                return
            }

            self.clsReadingsDone.send(rawSnapshot)
            self.unlSpo2 = false
            self.restoreSpO2TimerIfSaved()
            if self.automaticMonitoring { self.scheduleNextAutoRun() }
        }
    }

    func finishNIBPEarly() {
        DispatchQueue.main.async {
            let rawSnapshot = self.raw
            let wasAuto = self.autoNibpSliderEnabled

            self.stopMonitoring()

            if wasAuto, self.clsFeatureResult != nil {
                self.commitCurrentAutoSettings(for: .CLS)
                self.autoNibpSliderEnabled = false
                self.unlNibp = false
                self.restoreNibpTimerIfSaved()
                if self.automaticMonitoring { self.scheduleNextAutoRun() }
                return
            }

            self.clsReadingsDone.send(rawSnapshot)
            self.unlNibp = false
            self.restoreNibpTimerIfSaved()
            if self.automaticMonitoring { self.scheduleNextAutoRun() }
        }
    }
}

extension Store {
    func notifyConfigSuccess(stream: StreamType) {
        monitoringTimerSubscription?.cancel()
        monitoringTimerSubscription = nil
        isAdjusting = false
        runToken = UUID()
        commitCurrentAutoSettings(for: stream)
        configSuccess.send(stream)
    }
}


extension Store {
    func startTempStream() {
        bluetoothManager.setTemperatureCharacteristic(notifying: true)
    }

    func stopTempStream() {
        bluetoothManager.setTemperatureCharacteristic(notifying: false)
    }

    func finishTempRunAndStop() {
        let measured = self.measuredTmps
        let reported = self.reportedTmps
        stopTempStream()
        tempReadingsDone.send((measured, reported))
        if self.automaticMonitoring { self.scheduleNextAutoRun() }
    }
}
