//
//  HomeViewController.swift
//  Healthsign
//
//  Created by Zhifu Ge on 2021-05-23.
//  Copyright © 2021 Zhifu Ge. All rights reserved.
//

import UIKit
import Combine
import FirebaseAuth

final class HomeViewController: UIViewController {
    // MARK: - Properties
    private var uid: String {
        Auth.auth().currentUser?.uid ?? ""
    }

    private let store: Store = .shared
    private var subscriptions = Set<AnyCancellable>()
    private lazy var measurementNavigationController: UINavigationController = {
        let nav = UINavigationController()
        nav.modalPresentationStyle = .fullScreen
        return nav
    }()

    private let errorLabel: UILabel = { label in
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .systemRed
        label.numberOfLines = 0
        label.text = "Healthsign smart wristband not connected. Make sure that the wristband is charged, switched on, and in range. Check Bluetooth connection under Peripherals in the Settings tab. Read user manual for more information."
        return label
    }(UILabel())

    private var hasAnyCalibrationUser: Bool {
        guard let json = UserDefaults.standard.string(forKey: "savedUsernames"),
              let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data)
        else { return false }
        return !arr.isEmpty
    }
    private var toggleStack: UIStackView?
    private var contentStackBottomConstraint: NSLayoutConstraint?

    private let toggleLabel: UILabel = { label in
        label.font = .preferredFont(forTextStyle: .body)
        label.text = "Measure"
        return label
    }(UILabel())

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            let isLandscape = size.width > size.height
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            self.contentStackBottomConstraint?.constant = isPad ? -60 : (isLandscape ? 0 : -60)
            self.view.layoutIfNeeded()
        })
    }

    enum State {
        case stopped
        case started
    }

    // MARK: - Measure Sequence support
    private enum Modality: String {
        case temp = "Temperature"
        case nibp = "NIBP"
        case spo2 = "SpO2"
    }

    private let sequenceKey = "measurementSequence"
    private var sequenceQueue: [Modality] = []
    private var currentStepIndex: Int = 0

    private var stagedTempReading = MonitoringData.MonitoringTemperatureReading(measuredTmps: [0], reportedTmps: [0], duration: 0)
    private var stagedCLSReading = MonitoringData.MonitoringCLSReading(stream: .CLS, sampleRate: .hz250, clsDuration: 0, raw: [])
    private var stagedPLXReading = MonitoringData.MonitoringCLSReading(stream: .PLX, sampleRate: .hz100, clsDuration: 0, raw: [])

    private func loadSequenceOrder() -> [Modality] {
        let defaults = ["Temperature", "NIBP", "SpO2"]
        let json = UserDefaults.standard.string(forKey: sequenceKey) ?? ""
        let names: [String]
        if let data = json.data(using: .utf8),
           let arr = try? JSONDecoder().decode([String].self, from: data),
           !arr.isEmpty {
            names = arr
        } else {
            names = defaults
        }
        let mapped: [Modality] = names.compactMap { Modality(rawValue: $0) }
        return mapped.isEmpty ? [.spo2, .temp, .nibp] : mapped
    }

    private func enabledFiltered(_ modalities: [Modality]) -> [Modality] {
        modalities.filter { mod in
            switch mod {
            case .temp: return store.tempEnabled
            case .nibp: return store.nibpEnabled
            case .spo2: return store.spo2Enabled
            }
        }
    }

    private func runNextStepOrFinish() {
        guard currentStepIndex < sequenceQueue.count else {
            showResult(tempReading: stagedTempReading,
                       clsReading: stagedCLSReading,
                       plxReading: stagedPLXReading)
            return
        }

        let step = sequenceQueue[currentStepIndex]
        switch step {
        case .temp:
            adjustingTemp()
        case .nibp:
            adjustingCLS(tempReading: stagedTempReading)
        case .spo2:
            adjustingPLX(tempReading: stagedTempReading, clsReading: stagedCLSReading)
        }
    }


    private var dummyCLSReading: MonitoringData.MonitoringCLSReading {
        MonitoringData.MonitoringCLSReading(
            stream: .CLS,
            sampleRate: .hz250,
            clsDuration: 0,
            raw: []
        )
    }

    private var dummyPLXReading: MonitoringData.MonitoringCLSReading {
        MonitoringData.MonitoringCLSReading(
            stream: .PLX,
            sampleRate: .hz100,
            clsDuration: 0,
            raw: []
        )
    }

    // MARK: - Lifecycle Methods
    override func viewDidLoad() {
        super.viewDidLoad()

        setupView()
        setupBindings()
        updateToggleLabelText()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let selectedUsername = UserDefaults.standard.string(forKey: "selectedUsername") ?? ""
        let calibrationStep = UserDefaults.standard.integer(forKey: "calibrationStep_\(selectedUsername)")
        store.calibrationStep = calibrationStep
    }

    // MARK: - UI Updates
    private var state: State = .stopped {
        didSet {
            switch state {
            case .stopped:
                updateToggleLabelText()
            case .started:
                toggleLabel.text = "Stop"
                startMeasuring()
            }
        }
    }

    private func currentConfigureLabel() -> String {
        let nibpOn = store.autoNibpSliderEnabled
        let spo2On = store.autoSliderEnabled
        switch (nibpOn, spo2On) {
        case (true, false):  return "Configure NIBP"
        case (false, true):  return "Configure SpO\u{2082}"
        case (true, true):   return "Configure NIBP & SpO\u{2082}"
        default:             return "Measure"
        }
    }

    private func updateToggleLabelText() {
        guard state == .stopped else { return }
        toggleLabel.text = currentConfigureLabel()
    }

    // MARK: - Action Methods
    @objc private func toggle() {
        if !(store.autoSliderEnabled || store.autoNibpSliderEnabled),
           store.nibpEnabled,
           !store.proceedWithoutCalibration,
           (store.calibrationStep < 4
            || (UserDefaults.standard.string(forKey: "selectedUsername") ?? "").isEmpty
            || !hasAnyCalibrationUser)
        {
            let alertController = UIAlertController(
                title: "Calibration Required",
                message: "Please complete NIBP calibration before measuring (or enable “Proceed Without Calibration” in Settings).",
                preferredStyle: .alert
            )
            alertController.addAction(UIAlertAction(title: "OK", style: .default))
            present(alertController, animated: true)
            return
        }
        if !store.tempEnabled && !store.nibpEnabled && !store.spo2Enabled && !store.autoSliderEnabled && !store.autoNibpSliderEnabled {
            let alertController = UIAlertController(title: "Warning", message: "\nAll monitoring is currently disabled. Please enable at least one of the following in Settings: Temperature Monitoring, NIBP Monitoring, SpO\u{2082} Monitoring", preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: "OK", style: .default))
            self.present(alertController, animated: true, completion: nil)
        } else {
            switch state {
            case .stopped:
                state = .started
            case .started:
                stopMeasuring()
            }
        }
    }
}

extension HomeViewController {
    // MARK: - Setup Methods
    private func setupView() {
        view.backgroundColor = .systemBackground

        let logoImageView = UIImageView(image: UIImage(named: "logo-with-text"))
        logoImageView.contentMode = .scaleAspectFit

        let productImageSize: CGFloat = 100
        let productImageContainer = UIView()
        productImageContainer.layer.borderWidth = 1
        productImageContainer.layer.borderColor = UIColor.secondaryLabel.cgColor
        productImageContainer.layer.cornerRadius = productImageSize / 2
        productImageContainer.layer.masksToBounds = true
        productImageContainer.translatesAutoresizingMaskIntoConstraints = false

        let productImageView = UIImageView(image: UIImage(named: "product"))
        productImageView.contentMode = .scaleAspectFit
        productImageView.translatesAutoresizingMaskIntoConstraints = false

        productImageContainer.addSubview(productImageView)
        view.addSubview(productImageContainer)

        NSLayoutConstraint.activate([
            productImageContainer.widthAnchor.constraint(equalToConstant: productImageSize),
            productImageContainer.heightAnchor.constraint(equalTo: productImageContainer.widthAnchor, multiplier: 1),

            productImageView.widthAnchor.constraint(equalToConstant: productImageSize),
            productImageView.heightAnchor.constraint(equalTo: productImageView.widthAnchor, multiplier: 1),
            productImageView.centerXAnchor.constraint(equalTo: productImageContainer.centerXAnchor, constant: 5),
            productImageView.centerYAnchor.constraint(equalTo: productImageContainer.centerYAnchor, constant: 5)
        ])

        let productNameLabel = UILabel()
        productNameLabel.textColor = UIColor.secondaryLabel
        productNameLabel.font = .preferredFont(forTextStyle: .headline)
        productNameLabel.text = "Smart Wristband"
        productNameLabel.textAlignment = .center

        let productStack = UIStackView(arrangedSubviews: [productImageContainer, productNameLabel])
        productStack.axis = .vertical
        productStack.alignment = .center
        productStack.spacing = 8

        let toggleImageView = UIImageView(image: UIImage(systemName: "power"))
        toggleLabel.textColor = view.tintColor

        let toggleStack = UIStackView(arrangedSubviews: [toggleImageView, toggleLabel])
        self.toggleStack = toggleStack
        toggleStack.axis = .vertical
        toggleStack.spacing = 10
        toggleStack.alignment = .center
        toggleStack.isUserInteractionEnabled = true
        toggleStack.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggle)))
        toggleStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toggleImageView.widthAnchor.constraint(equalToConstant: 70),
            toggleImageView.heightAnchor.constraint(equalTo: toggleImageView.widthAnchor, multiplier: 1)
        ])

        let contentStack = UIStackView(
            arrangedSubviews: [
                logoImageView,
                productStack,
                toggleStack,
                errorLabel
            ]
        )
        contentStack.axis = .vertical
        contentStack.alignment = .center
        contentStack.distribution = .equalCentering
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentStack)

        contentStackBottomConstraint = contentStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -60)
        contentStackBottomConstraint?.isActive = true

        NSLayoutConstraint.activate([
            logoImageView.widthAnchor.constraint(equalTo: contentStack.widthAnchor, multiplier: 0.6),
            logoImageView.heightAnchor.constraint(equalToConstant: 50),

            contentStack.leadingAnchor.constraint(equalToSystemSpacingAfter: view.safeAreaLayoutGuide.leadingAnchor, multiplier: 1),
            contentStack.topAnchor.constraint(equalToSystemSpacingBelow: view.safeAreaLayoutGuide.topAnchor, multiplier: 1),
            view.safeAreaLayoutGuide.trailingAnchor.constraint(equalToSystemSpacingAfter: contentStack.trailingAnchor, multiplier: 1),
        ])
    }

    private func setupBindings() {
        store.$currentPeripheral
            .map { $0 != nil }
            .sink { [weak self] connected in
                guard let self = self else { return }
                self.errorLabel.isHidden = connected
                self.toggleStack?.isHidden = !connected

                guard !connected else { return}
                switch self.state {
                case .started:
                    if self.measurementNavigationController.presentingViewController is RootViewController {
                        self.showAlert(reason: .timeout)
                    }
                case .stopped:
                    break
                }
            }
            .store(in: &subscriptions)

        store.startMonitoring
            .sink { [weak self] in
                self?.startMeasuring()
            }
            .store(in: &subscriptions)

        store.$autoSliderEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self = self else { return }
                if self.state == .stopped {
                    self.updateToggleLabelText()
                }
            }
            .store(in: &subscriptions)

        store.$autoNibpSliderEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self = self else { return }
                if self.state == .stopped {
                    self.updateToggleLabelText()
                }
            }
            .store(in: &subscriptions)

        store.configSuccess
            .receive(on: RunLoop.main)
            .sink { [weak self] stream in
                self?.handleConfigSuccess(stream)
            }
            .store(in: &subscriptions)
    }
}

extension HomeViewController {
    // MARK: - Measurement Start/End
    private func startMeasuring() {
        if store.autoSliderEnabled {
            if !store.spo2Enabled { store.spo2Enabled = true }
            adjustingPLXForAuto()
            return
        }

        if store.autoNibpSliderEnabled {
            if !store.nibpEnabled { store.nibpEnabled = true }
            adjustingCLSForAuto()
            return
        }

        let order = loadSequenceOrder()
        sequenceQueue = enabledFiltered(order)
        currentStepIndex = 0
        stagedTempReading = MonitoringData.MonitoringTemperatureReading(measuredTmps: [0], reportedTmps: [0], duration: 0)
        stagedCLSReading = dummyCLSReading
        stagedPLXReading = dummyPLXReading

        guard !sequenceQueue.isEmpty else {
            let alertController = UIAlertController(title: "Warning", message: "\nAll monitoring is currently disabled. Please enable at least one of the following in Settings: Temperature Monitoring, NIBP Monitoring, SpO\u{2082} Monitoring", preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: "OK", style: .default))
            self.present(alertController, animated: true, completion: nil)
            return
        }

        runNextStepOrFinish()
    }

    private func stopMeasuring() {
        state = .stopped
        store.stopMonitoring()
        sequenceQueue.removeAll()
        currentStepIndex = 0
    }
}

extension HomeViewController {
    // MARK: - Measurement Methods
    private func push(_ vc: UIViewController) {
        measurementNavigationController.setViewControllers([vc], animated: true)
        if measurementNavigationController.presentingViewController == nil {
            present(measurementNavigationController, animated: true)
        }
    }

    private func adjustingTemp() {
        let adjustingScreen = AdjustingScreenViewController(state: .HTS, duration: 4) { isAborted in
            if isAborted {
                self.stopMeasuring()
            } else {
                self.measureTemperature()
            }
        }
        push(adjustingScreen)
    }

    private func measureTemperature() {
        let htsVC = HTSViewController(duration: UserDefaults.standard.double(forKey: SettingsKey.htsTimerLimit))
        htsVC.readingCompletion = { [weak self] reading in
            guard let self = self else { return }
            self.stagedTempReading = reading
            self.currentStepIndex += 1
            self.runNextStepOrFinish()
        }
        htsVC.abortCompletion = { [weak self] in
            self?.stopMeasuring()
        }
        push(htsVC)
    }

    private func adjustingCLS(tempReading: MonitoringData.MonitoringTemperatureReading) {
        let adjustingScreen = AdjustingScreenViewController(state: .CLS, duration: 8) { isAborted in
            if isAborted {
                self.stopMeasuring()
            } else {
                self.measureCLS(tempReading: tempReading)
            }
        }
        push(adjustingScreen)
    }

    private func measureCLS(tempReading: MonitoringData.MonitoringTemperatureReading) {
        let sampleRate: SamplingHz = .hz250
        let normalDuration = UserDefaults.standard.double(forKey: SettingsKey.cls1TimerLimit)

        let clsVC = CLSViewController(stream: .CLS, rate: sampleRate, timeLimit: normalDuration)
        clsVC.readingCompletion = { [weak self] (result: Result<MonitoringData.MonitoringCLSReading, Store.Reason>) in
            guard let self = self else { return }
            switch result {
            case .success(let reading):
                self.stagedTempReading = tempReading
                self.stagedCLSReading = reading
                self.currentStepIndex += 1
                self.runNextStepOrFinish()
            case .failure(let error):
                print(error.localizedDescription)
                self.showAlert(reason: error)
            }
        }

        clsVC.abortCompletion = { [weak self] in
            self?.stopMeasuring()
            self?.measurementNavigationController.dismiss(animated: true, completion: nil)
        }

        measurementNavigationController.setViewControllers([clsVC], animated: true)
    }

    private func adjustingPLX(tempReading: MonitoringData.MonitoringTemperatureReading, clsReading: MonitoringData.MonitoringCLSReading) {
        let adjustingScreen = AdjustingScreenViewController(state: .PLX, duration: 16) { isAborted in
            if isAborted {
                self.stopMeasuring()
            } else {
                self.measurePLX(tempReading: tempReading, clsReading: clsReading)
            }
        }
        push(adjustingScreen)
    }

    private func measurePLX(tempReading: MonitoringData.MonitoringTemperatureReading, clsReading: MonitoringData.MonitoringCLSReading) {
        let sampleRate: SamplingHz = .hz100
        let normalDuration = UserDefaults.standard.double(forKey: SettingsKey.cls2TimerLimit)

        let clsVC = CLSViewController(stream: .PLX, rate: sampleRate, timeLimit: normalDuration)
        clsVC.readingCompletion = { [weak self] (result: Result<MonitoringData.MonitoringCLSReading, Store.Reason>) in
            guard let self = self else { return }
            switch result {
            case .success(let reading):
                self.stagedTempReading = tempReading
                self.stagedCLSReading = clsReading
                self.stagedPLXReading = reading
                self.currentStepIndex += 1
                self.runNextStepOrFinish()
            case .failure(let error):
                print(error.localizedDescription)
                self.showAlert(reason: error)
            }
        }

        clsVC.abortCompletion = { [weak self] in
            self?.stopMeasuring()
            self?.measurementNavigationController.dismiss(animated: true, completion: nil)
        }

        measurementNavigationController.setViewControllers([clsVC], animated: true)
    }

    private func adjustingPLXForAuto() {
        let duration: TimeInterval = 140
        let adjustingScreen = AdjustingScreenViewController(state: .PLX, duration: duration) { [weak self] isAborted in
            guard let self = self else { return }
            if isAborted {
                self.store.autoSliderEnabled = true
                self.store.unlSpo2 = false
                self.store.stopMonitoring()
            } else {
                if self.store.autoSliderEnabled {
                    self.store.finishSpO2Early()
                } else {
                    self.store.stopMonitoring()
                }
            }
            self.state = .stopped
            self.measurementNavigationController.dismiss(animated: true, completion: nil)
        }
        push(adjustingScreen)
    }

    private func adjustingCLSForAuto() {
        let duration: TimeInterval = 140
        let adjustingScreen = AdjustingScreenViewController(state: .CLS, duration: duration) { [weak self] isAborted in
            guard let self = self else { return }
            if isAborted {
                self.store.autoNibpSliderEnabled = true
                self.store.unlNibp = false
                self.store.stopMonitoring()
            } else {
                if self.store.autoNibpSliderEnabled {
                    self.store.finishNIBPEarly()
                } else {
                    self.store.stopMonitoring()
                }
            }
            self.state = .stopped
            self.measurementNavigationController.dismiss(animated: true, completion: nil)
        }
        push(adjustingScreen)
    }

    // MARK: - Result Methods
    private func showResult(tempReading: MonitoringData.MonitoringTemperatureReading, clsReading: MonitoringData.MonitoringCLSReading, plxReading: MonitoringData.MonitoringCLSReading) {
        state = .stopped
        getMeasurementResult(
            tempReading: tempReading,
            clsReading: clsReading,
            plxReading: plxReading,
            clsFeatureResult: store.clsFeatureResult,
            batteryInfo: store.batteryInfo,
            deviceInfo: store.deviceInfo
        ) { [weak self] data in
            guard let self = self else { return }
            FirebaseService.shared.uploadData(data: data)
            let resultsVC = ResultsViewController(
                uid: self.uid,
                history: data.history,
                rawCLSData: clsReading.rawCLSData,
                rawPLXData: plxReading.rawCLSData,
                exportType: .pdf
            ) { [weak self] in
                self?.dismiss(animated: true, completion: nil)
            }
            self.push(resultsVC)
        }
    }

    private func getMeasurementResult(
        tempReading: MonitoringData.MonitoringTemperatureReading,
        clsReading: MonitoringData.MonitoringCLSReading,
        plxReading: MonitoringData.MonitoringCLSReading,
        clsFeatureResult: CLSFeatureResult?,
        batteryInfo: BatteryInfo?,
        deviceInfo: Set<DeviceInfoItem>,
        completion: @escaping (MonitoringData) -> Void
    ) {
        LogManager.log.debug("getMeasurementResult")
        if SettingsKey.dataAnalysisValue {
            DataFunctions.analyze(
                rawCls: clsReading.raw,
                rawPlx: plxReading.raw,
                reportedTmps: tempReading.reportedTmps,
                sampleRate: clsReading.sampleRate,
                clsFeatureResult: clsFeatureResult
            ) { result in
                completion(
                    MonitoringData(
                        temp: tempReading,
                        cls: clsReading,
                        plx: plxReading,
                        clsFeatureResult: clsFeatureResult,
                        batteryInfo: batteryInfo,
                        deviceInfo: deviceInfo,
                        result: result
                    )
                )
            }
        } else {
            let result = AnalyzeResult(hr: 0, rr: 0, spO2: 0, sysBP: 0, diaBP: 0, temp: 0.0, hrv: 0, pwv: 0, meanPTT: 0, SDPTT: 0, clsActivity: 0, plxActivity: 0)
            completion(
                MonitoringData(
                    temp: tempReading,
                    cls: clsReading,
                    plx: plxReading,
                    clsFeatureResult: clsFeatureResult,
                    batteryInfo: batteryInfo,
                    deviceInfo: deviceInfo,
                    result: result
                )
            )
        }
    }
}

extension HomeViewController {
    // MARK: - Failure Handling
    private func showAlert(reason: Store.Reason) {
        stopMeasuring()
        measurementNavigationController.dismiss(animated: false)
        let alertVC = UIAlertController(
            title: reason.title,
            message: reason.description,
            preferredStyle: .alert
        )
        alertVC.addAction(UIAlertAction(title: "Ok", style: .default))
        present(alertVC, animated: true)
    }
}

extension HomeViewController {
    // MARK: - Configuration Success Handling
    private func handleConfigSuccess(_ stream: StreamType) {
        state = .stopped
        store.stopMonitoring()

        switch stream {
        case .PLX:
            if store.autoSliderEnabled { store.autoSliderEnabled = false }
            store.unlSpo2 = false
            store.restoreSpO2TimerIfSaved()
            store.applyManualChannelGains(for: .PLX, save: false)   // <— keep device on SpO₂ pair
        case .CLS:
            if store.autoNibpSliderEnabled { store.autoNibpSliderEnabled = false }
            store.unlNibp = false
            store.restoreNibpTimerIfSaved()
            store.applyManualChannelGains(for: .CLS, save: false)   // <— keep device on NIBP pair
        default:
            break
        }

        if measurementNavigationController.presentingViewController is RootViewController {
            measurementNavigationController.dismiss(animated: true) { [weak self] in
                self?.presentConfigSuccessAlert(for: stream)
            }
        } else {
            presentConfigSuccessAlert(for: stream)
        }
    }

    private func presentConfigSuccessAlert(for stream: StreamType) {
        let title = "Configuration Successful"
        let message: String
        switch stream {
        case .PLX: message = "SpO\u{2082} auto-configuration completed successfully."
        case .CLS: message = "NIBP auto-configuration completed successfully."
        default:    message = "Configuration completed successfully."
        }

        let alertVC = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alertVC.addAction(UIAlertAction(title: "OK", style: .default))
        present(alertVC, animated: true)
    }
}
