//
//  FormView.swift
//  Healthsign
//
//  Created by Aligazy Kismetov on 13.10.2024.
//  Copyright © 2024 Zhifu Ge. All rights reserved.
//

import SwiftUI

// MARK: - Main Controls block (auto monitoring, temp/NIBP/SpO2 + ControlsFormView)

struct FormView: View {
    @ObservedObject var store = Store.shared
    @State private var sliderUsed: Bool = false

    @AppStorage(SettingsKey.htsTimerLimit) var htsTimerLimit: Double = 5
    @AppStorage(SettingsKey.cls1TimerLimit) var cls1TimerLimit: Double = 25
    @AppStorage(SettingsKey.cls2TimerLimit) var cls2TimerLimit: Double = 25
    @AppStorage(SettingsKey.temperatureUnitUsesFahrenheit) var usesFahrenheit = true
    @AppStorage(SettingsKey.automaticMonitoringInterval) var automaticMonitoringInterval: Double = 5

    @State private var originalHtsTimerLimit: Double = 15
    @State private var originalClsTimerLimit: Double = 22

    // Preserve user-selected timers when Auto Sliders are toggled
    @State private var savedCls1TimerForAuto: Double? = nil
    @State private var savedCls2TimerForAuto: Double? = nil

    @Binding var pulseWaveAGCGRN1: Double
    @Binding var pulseWaveAGCYLW: Double
    @Binding var pulseWaveAGCGRN2: Double
    @Binding var pulseWaveAGCGRN3: Double

    @AppStorage("spo2LatchRatio") var spo2ratioControl: Double = 1.0

    @Binding var brightnessCalculations: Bool
    @Binding var allowPulseWaveAGC: Bool
    @Binding var automaticBrightnessCtrl: Bool
    @Binding var brightnessCtrlGRN1: Double
    @Binding var brightnessCtrlYLW: Double
    @Binding var brightnessCtrlGRN2: Double
    @Binding var brightnessCtrlGRN3: Double
    @Binding var disableSaveButton: Bool

    // MARK: - Measure Sequence persistence & state
    @AppStorage("measurementSequence") private var measurementSequenceStore: String = ""
    @State private var measurementItems: [String] = ["SpO2", "Temperature", "NIBP"]

    // Allowed order items (must match asset names)
    private let defaultSequence: [String] = ["Temperature", "NIBP", "SpO2"]

    // Map measurement items to SF Symbols (system icons)
    private func systemIcon(for item: String) -> String {
        switch item {
        case "SpO2":
            return "drop.degreesign"
        case "Temperature":
            return "thermometer.medium"
        case "NIBP":
           return "gauge.with.needle"
        default:
            return "square"
        }
    }

    // Tint color for each measurement (to make the list easy to scan)
    private func iconColor(for item: String) -> Color {
        switch item {
        case "SpO2":
            return .red       // oxygen / pulse wave
        case "Temperature":
            return .teal     // heat
        case "NIBP":
            return .yellow       // blood pressure
        default:
            return .secondary
        }
    }

    // Display label for items (e.g., show small 2 for SpO₂)
    private func displayName(for item: String) -> String {
        if item == "SpO2" { return "SpO\u{2082}" }
        return item
    }

    private func loadSequence() {
        guard !measurementSequenceStore.isEmpty,
              let data = measurementSequenceStore.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            measurementItems = defaultSequence
            return
        }
        let allowed = Set(defaultSequence)
        // keep only allowed & unique, preserve order
        let filtered = arr.filter { allowed.contains($0) }
        let unique = filtered.reduce(into: [String]()) { acc, v in if !acc.contains(v) { acc.append(v) } }
        measurementItems = unique.count == 3 ? unique : defaultSequence
    }

    private func saveSequence() {
        if let data = try? JSONEncoder().encode(measurementItems),
           let json = String(data: data, encoding: .utf8) {
            measurementSequenceStore = json
        }
    }

    var body: some View {
        Group {
            // Automatic Monitoring
            Section(header: Text("AUTOMATIC MONITORING")) {
                VStack {
                    HStack {
                        Toggle(isOn: $store.automaticMonitoring) {
                            Text("Enabled")
                        }
                    }
                    .padding(.bottom, 12)

                    HStack {
                        Stepper(
                            "Every \(automaticMonitoringInterval, specifier: "%.0f") minutes",
                            value: $automaticMonitoringInterval,
                            in: 1 ... 60,
                            step: 1,
                            onEditingChanged: { editing in
                                if !editing, store.automaticMonitoring {
                                    Store.shared.scheduleNextAutoRun()
                                }
                            }
                        )
                    }
                }
            }
            .disabled(store.currentPeripheral == nil || store.peripherals.isEmpty)

            // Data settings (sampling + analysis toggles etc.)
            ToggleFormView(disableSaveButton: $disableSaveButton)

            // Measure Sequence (drag to reorder)
            Section(header: Text("MEASUREMENT SEQUENCE")) {
                // Colorful, easy-to-scan rows with clear order badges
                ForEach(Array(measurementItems.enumerated()), id: \.element) { idx, item in
                    HStack(spacing: 12) {
                        Image(systemName: systemIcon(for: item))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(iconColor(for: item))
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName(for: item))
                                .font(.body)
                        }
                        Spacer()

                        // Numbered badge shows current position (1, 2, 3)
                        ZStack {
                            Circle()
                                .stroke(Color.white, lineWidth: 1)
                            Text("\(idx + 1)")
                                .font(.caption.bold())
                                .foregroundColor(iconColor(for: item))
                        }
                        .frame(width: 24, height: 24)
                    }
                    .contentShape(Rectangle())
                }
                .onMove { indices, newOffset in
                    measurementItems.move(fromOffsets: indices, toOffset: newOffset)
                    saveSequence()
                }

                Text("Push and drag vertically to set run order. Only enabled streams will run.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .environment(\.editMode, .constant(.active))

            // Temperature Monitoring
            Section(header: Text("TEMPERATURE MONITORING")) {
                VStack {
                    HStack {
                        Toggle(isOn: $store.tempEnabled) { Text("Enabled") }
                            .onChange(of: store.tempEnabled) { isEnabled in
                                if !isEnabled { store.unlTemp = false }
                            }
                    }
                    .padding(.bottom, 8)

                    // Unlimited
                    HStack {
                        Toggle(isOn: $store.unlTemp) {
                            Text("Unlimited Monitoring")
                        }
                        .onChange(of: store.unlTemp) { newValue in
                            if newValue {
                                originalHtsTimerLimit = htsTimerLimit
                                htsTimerLimit = Double.infinity
                                store.nibpEnabled = false
                                store.spo2Enabled = false
                                store.tempEnabled = true
                            } else {
                                htsTimerLimit = originalHtsTimerLimit
                            }
                        }
                    }
                    .padding(.bottom, 8)

                    HStack {
                        Text("Temperature Unit")
                        Spacer()
                        Picker("Temperature Unit", selection: $usesFahrenheit) {
                            Text(TemperatureUnit.celsius.description).tag(false)
                            Text(TemperatureUnit.fahrenheit.description).tag(true)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 100)
                        .onChange(of: usesFahrenheit) { newValue in
                            store.temperatureUnit = newValue ? .fahrenheit : .celsius
                        }
                    }
                    .padding(.bottom, 10)

                    HStack {
                        Text("Monitoring Time (s)")
                        Spacer()
                        Text("\(htsTimerLimit, specifier: "%2.0f")")
                    }
                    Slider(
                        value: $htsTimerLimit,
                        in: 5 ... 15,
                        step: 1,
                        minimumValueLabel: Text("5"),
                        maximumValueLabel: Text("15")
                    ) { Text("Temperature Timer Limit") }
                    .disabled(store.unlTemp)
                    .onChange(of: htsTimerLimit) { _ in
                        sliderUsed = true
                        disableSaveButton = false
                    }
                }
            }
            .disabled(store.unlNibp || store.unlSpo2)

            // NIBP Monitoring
            Section(header: Text("NIBP MONITORING")) {
                VStack {
                    HStack {
                        Toggle(isOn: $store.nibpEnabled) { Text("Enabled") }
                            .onChange(of: store.nibpEnabled) { isEnabled in
                                if store.transmitThousandHzEnabled {
                                    updateSamplingRate(to: true)
                                }
                                if !isEnabled {
                                    store.unlNibp = false
                                    store.autoNibpSliderEnabled = false
                                }
                            }
                    }
                    .padding(.bottom, 8)

                    HStack {
                        Toggle(isOn: $store.unlNibp) {
                            Text("Unlimited Monitoring")
                        }
                        .onChange(of: store.unlNibp) { newValue in
                            if newValue {
                                originalClsTimerLimit = cls1TimerLimit
                                cls1TimerLimit = Double.infinity
                                store.nibpEnabled = true
                                store.spo2Enabled = false
                                store.tempEnabled = false
                            } else {
                                cls1TimerLimit = originalClsTimerLimit
                            }
                        }
                    }
                    .padding(.bottom, 8)

                    HStack {
                        Text("Monitoring Time (s)")
                        Spacer()
                        Text("\(store.autoNibpSliderEnabled ? 140.0 : cls1TimerLimit, specifier: "%2.0f")")
                    }
                    Slider(
                        value: $cls1TimerLimit,
                        in: 15 ... 60,
                        step: 1,
                        minimumValueLabel: Text("15"),
                        maximumValueLabel: Text("60")
                    ) { Text("FIRST PULSE WAVE TIMER LIMIT") }
                    .disabled(store.unlNibp || store.autoNibpSliderEnabled)
                    .onChange(of: cls1TimerLimit) { _ in
                        sliderUsed = true
                        disableSaveButton = false
                    }

                    Divider().padding(.vertical, 4)

                    Toggle("Auto Slider Tuning", isOn: $store.autoNibpSliderEnabled)
                        .disabled(store.currentPeripheral == nil || store.peripherals.isEmpty)
                        .onChange(of: store.autoNibpSliderEnabled) { enabled in
                            if enabled {
                                // Persist current user timer and switch to 120s during auto-config
                                UserDefaults.standard.set(cls1TimerLimit, forKey: SettingsKey.savedCls1TimerForAuto)
                                savedCls1TimerForAuto = cls1TimerLimit
                                cls1TimerLimit = 140

                                if store.autoSliderEnabled { store.autoSliderEnabled = false }
                                automaticBrightnessCtrl = false
                                if !store.nibpEnabled { store.nibpEnabled = true }
                                store.unlNibp = false
                                disableSaveButton = false
                            } else {
                                // Restore from in-memory snapshot, then persisted fallback
                                if let saved = savedCls1TimerForAuto {
                                    cls1TimerLimit = saved
                                } else {
                                    let saved = UserDefaults.standard.double(forKey: SettingsKey.savedCls1TimerForAuto)
                                    if saved > 0 { cls1TimerLimit = saved }
                                }
                                UserDefaults.standard.removeObject(forKey: SettingsKey.savedCls1TimerForAuto)
                                savedCls1TimerForAuto = nil
                                store.unlNibp = false
                                disableSaveButton = false
                            }
                        }
                }
            }
            .disabled(store.unlTemp || store.unlSpo2)

            // SpO2 Monitoring
            Section(
                header: Text("SpO\u{2082} MONITORING")
            ) {
                VStack {
                    HStack {
                        Toggle(isOn: $store.spo2Enabled) { Text("Enabled") }
                            .onChange(of: store.spo2Enabled) { isEnabled in
                                if !isEnabled {
                                    store.unlSpo2 = false
                                    store.autoSliderEnabled = false
                                    updateSamplingRate(to: true)
                                }
                            }
                    }
                    .padding(.bottom, 8)

                    HStack {
                        Toggle(isOn: $store.unlSpo2) {
                            Text("Unlimited Monitoring")
                        }
                        .onChange(of: store.unlSpo2) { newValue in
                            if newValue {
                                originalClsTimerLimit = cls2TimerLimit
                                cls2TimerLimit = Double.infinity
                                store.nibpEnabled = false
                                store.spo2Enabled = true
                                store.tempEnabled = false
                            } else {
                                cls2TimerLimit = originalClsTimerLimit
                            }
                        }
                    }
                    .padding(.bottom, 8)

                    HStack {
                        Text("Monitoring Time (s)")
                        Spacer()
                        Text("\(store.autoSliderEnabled ? 140.0 : cls2TimerLimit, specifier: "%2.0f")")
                    }
                    Slider(
                        value: $cls2TimerLimit,
                        in: 15 ... 60,
                        step: 1,
                        minimumValueLabel: Text("15"),
                        maximumValueLabel: Text("60")
                    ) { Text("Second PULSE WAVE TIMER LIMIT") }
                    .disabled(store.unlSpo2 || store.autoSliderEnabled)
                    .onChange(of: cls2TimerLimit) { _ in
                        sliderUsed = true
                        disableSaveButton = false
                    }

                    Divider().padding(.vertical, 4)

                    Toggle("Auto Slider Tuning", isOn: $store.autoSliderEnabled)
                        .disabled(store.currentPeripheral == nil || store.peripherals.isEmpty)
                        .onChange(of: store.autoSliderEnabled) { enabled in
                            if enabled {
                                // Persist current user timer and switch to 120s during auto-config
                                UserDefaults.standard.set(cls2TimerLimit, forKey: SettingsKey.savedCls2TimerForAuto)
                                savedCls2TimerForAuto = cls2TimerLimit
                                cls2TimerLimit = 140

                                if store.autoNibpSliderEnabled { store.autoNibpSliderEnabled = false }
                                automaticBrightnessCtrl = false
                                if !store.spo2Enabled { store.spo2Enabled = true }
                                store.unlSpo2 = false
                                disableSaveButton = false
                            } else {
                                // Restore from in-memory snapshot, then persisted fallback
                                if let saved = savedCls2TimerForAuto {
                                    cls2TimerLimit = saved
                                } else {
                                    let saved = UserDefaults.standard.double(forKey: SettingsKey.savedCls2TimerForAuto)
                                    if saved > 0 { cls2TimerLimit = saved }
                                }
                                UserDefaults.standard.removeObject(forKey: SettingsKey.savedCls2TimerForAuto)
                                savedCls2TimerForAuto = nil
                                store.unlSpo2 = false
                                disableSaveButton = false
                            }
                        }
                }
            }
            .textCase(nil)
            .disabled(store.unlTemp || store.unlNibp)

            // Device controls (AGC + Brightness + ratio) – lives in your existing ControlsFormView
            ControlsFormView(
                pulseWaveAGCGRN1: $pulseWaveAGCGRN1,
                pulseWaveAGCYLW:  $pulseWaveAGCYLW,
                pulseWaveAGCGRN2: $pulseWaveAGCGRN2,
                pulseWaveAGCGRN3: $pulseWaveAGCGRN3,
                brightnessCtrlGRN1: $brightnessCtrlGRN1,
                brightnessCtrlYLW:  $brightnessCtrlYLW,
                brightnessCtrlGRN2: $brightnessCtrlGRN2,
                brightnessCtrlGRN3: $brightnessCtrlGRN3,
                disableSaveButton: $disableSaveButton,
                spo2ratioControl: $spo2ratioControl,
                brightnessCalculations: $brightnessCalculations,
                allowPulseWaveAGC: $allowPulseWaveAGC,
                automaticBrightnessCtrl: $automaticBrightnessCtrl
            )
            .onAppear {
                if store.autoNibpSliderEnabled {
                    let saved = UserDefaults.standard.double(forKey: SettingsKey.savedCls1TimerForAuto)
                    if saved <= 0 { UserDefaults.standard.set(cls1TimerLimit, forKey: SettingsKey.savedCls1TimerForAuto) }
                    cls1TimerLimit = 140
                }
                if store.autoSliderEnabled {
                    let saved2 = UserDefaults.standard.double(forKey: SettingsKey.savedCls2TimerForAuto)
                    if saved2 <= 0 { UserDefaults.standard.set(cls2TimerLimit, forKey: SettingsKey.savedCls2TimerForAuto) }
                    cls2TimerLimit = 140
                }
            }
        }
        .onAppear { loadSequence() }
    }

    private func updateSamplingRate(to newValue: Bool) {
        disableSaveButton = false
        let rate: SamplingHz = newValue ? .hz250 : .hz100
        if !store.peripherals.isEmpty {
            Store.shared.setClsStream(.CLS, sampleRate: rate, save: false) { _ in }
            Store.shared.getClSFeatureValues { _ in }
        }
    }
}

// MARK: - Data settings top block

struct ToggleFormView: View {
    @Binding var disableSaveButton: Bool

    @AppStorage(SettingsKey.realTimeDSP) var usesRealTimeDSP: Bool = true
    @AppStorage(SettingsKey.dataAnalysis) var allowDataAnalysis: Bool = true
    @AppStorage(SettingsKey.enableAlerts) var enableAlerts: Bool = true
    @AppStorage(SettingsKey.enableDCPlots) var enableDCPlots = true
    @AppStorage(SettingsKey.enableDelayWaveforms) var enableDelayWaveforms = false
    @AppStorage(SettingsKey.htsTimerLimit) var htsTimerLimit: Double = 10

    @AppStorage("motionDetectionEnabled") var motionDetectionEnabled: Bool = false
    @AppStorage("aclThreshold") var aclThreshold: String = "2250"

    @ObservedObject var store = Store.shared
    @State private var showStreamPacketsAlert = false
    @State private var showThousandHzFirmwareAlert = false
    @State private var originalAnalyzeDataState: Bool = false

    var body: some View {
        Section(header: Text("DATA SETTINGS")) {
            Toggle(isOn: $usesRealTimeDSP) { Text("Filter Waveforms") }
                .onChange(of: usesRealTimeDSP) { newValue in
                    Store.shared.setFilterWaveforms(newValue)
                }
                .onAppear {
                    // Ensure Store mirrors persisted value on first render
                    Store.shared.setFilterWaveforms(usesRealTimeDSP)
                }

            Toggle(isOn: $enableDCPlots) { Text("Enable DC Plots") }
            Toggle(isOn: $enableAlerts) { Text("Enable Health Alerts") }

            // Analyze Data (disabled when streaming arbitrary packets)
            Toggle(isOn: analyzeDataBinding) { Text("Analyze Data") }
                .disabled(store.transmitEnabled)

            Toggle("Stream Packets", isOn: streamPacketsBinding)
                .onChange(of: streamPacketsBinding.wrappedValue) { isOn in
                    if isOn {
                        // Stream Packets proof-mode: force Thousand Hz OFF so toggle is usable
                        store.transmitThousandHzEnabled = false
                    }
                }
                .alert(isPresented: $showStreamPacketsAlert) {
                    Alert(
                        title: Text("Warning"),
                        message: Text("""
                        \nThis mode will stream any arbitrary packets sent via the RT in the background.\n
                        All charting and analysis will be disabled.\n
                        You can export the collected packets from Dash Pro or directly from Firebase.
                        """),
                        dismissButton: .default(Text("OK"))
                    )
                }
            // Stream 1000 Hz Packets (requires special firmware)
//            Toggle("Stream 1000 Hz Packets", isOn: thousandHzBinding)
//                .alert(isPresented: $showThousandHzFirmwareAlert) {
//                    Alert(
//                        title: Text("Warning"),
//                        message: Text("""
//                        \nThis mode will only work with the 1000 Hz Firmware.\n
//                        DC charting and analysis will be disabled.\n
//                        You can export the collected packets from Dash Pro or directly from Firebase.
//                        """),
//                        dismissButton: .default(Text("OK"))
//                    )
//                }

            Toggle("Motion Detection", isOn: $motionDetectionEnabled)
            if motionDetectionEnabled {
                HStack {
                    Text("ACL Threshold")
                    Spacer()
                    CustomTextField(
                        placeholder: "Enter ACL Threshold",
                        text: $aclThreshold,
                        keyType: .decimalPad
                    )
                }
            }
        }
    }

    // MARK: - Clean bindings & handlers
    private var analyzeDataBinding: Binding<Bool> {
        Binding(
            get: { allowDataAnalysis },
            set: { newValue in
                // Prevent toggling while streaming; mirror the original behavior
                if !store.transmitEnabled {
                    allowDataAnalysis = newValue
                    disableSaveButton = false
                }
            }
        )
    }

    private var streamPacketsBinding: Binding<Bool> {
        Binding(
            get: { store.transmitEnabled },
            set: { newValue in
                handleStreamPacketsToggle(newValue)
            }
        )
    }

    private var thousandHzBinding: Binding<Bool> {
        Binding(
            get: { store.transmitThousandHzEnabled },
            set: { newValue in
                handleThousandHzToggle(newValue)
            }
        )
    }

    private func handleStreamPacketsToggle(_ newValue: Bool) {
        if newValue {
            showStreamPacketsAlert = true
            originalAnalyzeDataState = allowDataAnalysis
            UserDefaults.standard.set(allowDataAnalysis, forKey: Store.DefaultsKeys.originalAnalyzeDataState)
            allowDataAnalysis = false
        } else {
            allowDataAnalysis = UserDefaults.standard.bool(forKey: Store.DefaultsKeys.originalAnalyzeDataState)
        }
        store.transmitEnabled = newValue
        store.transmitThousandHzEnabled = false
        disableSaveButton = false
    }

    private func handleThousandHzToggle(_ newValue: Bool) {
        if newValue {
            showThousandHzFirmwareAlert = true
            // Keep NIBP at 250 Hz if active
            if store.nibpEnabled { updateSamplingRate(to: true) }
        }
        store.transmitEnabled = false
        store.transmitThousandHzEnabled = newValue
        disableSaveButton = false
    }

    private func updateSamplingRate(to newValue: Bool) {
        disableSaveButton = false
        let rate: SamplingHz = newValue ? .hz250 : .hz100
        if !store.peripherals.isEmpty {
            Store.shared.setClsStream(.CLS, sampleRate: rate, save: false) { _ in }
            Store.shared.getClSFeatureValues { _ in }
        }
    }
}
