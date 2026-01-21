//
//  CLSViewController.swift
//  Healthsign
//
//  Created by Zhifu Ge on 2021-05-24.
//  Copyright © 2021 Zhifu Ge. All rights reserved.
//

import UIKit
import SwiftUI
import Combine

final class CLSViewController: UIViewController {
    private let store: Store = .shared
    private let timerViewModel: TimerViewModel
    private let stream: StreamType
    private let rate: SamplingHz
    private let timeLimit: TimeInterval

    private var subscriptions = Set<AnyCancellable>()
    private let chart1: PulseChartView
    private let chart2: PulseChartView
    private let chart3: PulseChartView
    private let chart4: PulseChartView
    var readingCompletion: ((Result<MonitoringData.MonitoringCLSReading, Store.Reason>) -> ())?
    var abortCompletion: (() -> Void)?

    let irLabel = UILabel()
    let rdLabel = UILabel()
    let spo2Label = UILabel()
    let hrPLXLabel = UILabel()
    private weak var titleValueLabel: UILabel?

    private var processingOverlay: UIView?
    private var liveLogTimer: Timer?

    private let chartTitleLabelCache = NSMapTable<UIView, UILabel>(keyOptions: .weakMemory, valueOptions: .weakMemory)

    private func showProcessingOverlay(_ text: String = "Processing Results…") {
        let overlay = UIView(frame: view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.3)

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .headline)

        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        overlay.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor)
        ])

        view.addSubview(overlay)
        view.isUserInteractionEnabled = false
        processingOverlay = overlay
    }

    private func hideProcessingOverlay() {
        view.isUserInteractionEnabled = true
        processingOverlay?.removeFromSuperview()
        processingOverlay = nil
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    init(stream: StreamType, rate: SamplingHz, timeLimit: TimeInterval) {
        self.stream = stream
        self.rate = rate
        self.timeLimit = timeLimit
        let hotStart = Store.shared.currentStream == stream
        self.timerViewModel = TimerViewModel(length: hotStart ? timeLimit : 5)
        let chartRate: SamplingHz = Store.shared.transmitThousandHzEnabled
        ? (stream == .CLS ? .hz200 : .hz100)
        : rate

        self.chart1 = PulseChartView(
            color: stream == .CLS ? .yellow : .systemBlue,
            title: stream == .CLS ? "BACK YLW DC" : "MIDDLE IR DC",
            sampleRate: chartRate,
            chartType: "DC",
            streamName: stream.name
        )
        self.chart2 = PulseChartView(
            color: stream == .CLS ? .systemYellow : .red,
            title: stream == .CLS ? "FRONT YLW DC" : "MIDDLE RED DC",
            sampleRate: chartRate,
            chartType: "DC",
            streamName: stream.name
        )
        self.chart3 = PulseChartView(
            color: stream == .CLS ? .yellow : .systemBlue,
            title: stream == .CLS ? "BACK YLW AC" : "MIDDLE IR AC",
            sampleRate: chartRate,
            chartType: "AC",
            streamName: stream.name
        )
        self.chart4 = PulseChartView(
            color: stream == .CLS ? .systemYellow : .red,
            title: stream == .CLS ? "FRONT YLW AC" : "MIDDLE RED AC",
            sampleRate: chartRate,
            chartType: "AC",
            streamName: stream.name
        )
        super.init(nibName: nil, bundle: nil)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupViews()
        setupBindings()
        navigationController?.navigationBar.prefersLargeTitles = false
        setStyledTitle()

        let abortBarButtonItem = UIBarButtonItem(title: "Abort", style: .plain, target: self, action: #selector(abort))
        navigationItem.rightBarButtonItem = abortBarButtonItem
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        switch stream {
        case .PLX:
            store.realTimeSpo2 = 0
            store.realTimePlxHR = 0
            store.Current_IR_AC_Amplitude = 0
            store.Current_RD_AC_Amplitude = 0
            self.titleValueLabel?.text = "SpO\u{2082}: 0 %  •  PR: 0 BPM"
            self.setChartTitle("MIDDLE IR AC", value: 0, in: self.chart3)
            self.setChartTitle("MIDDLE RED AC", value: 0, in: self.chart4)
        case .CLS:
            store.Current_BKY_AC_Amplitude = 0
            store.Current_FRY_AC_Amplitude = 0
            self.setChartTitle("BACK YLW AC", value: 0, in: self.chart3)
            self.setChartTitle("FRONT YLW AC", value: 0, in: self.chart4)
        default:
            break
        }
        if store.currentStream == stream {
            timerViewModel.reset(length: self.timeLimit)
        } else {
            timerViewModel.reset(length: 5)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if store.currentStream != stream {
            store.monitorCLS(stream: stream)
        }
        self.logGainsAndBrightness("CLSVC START (\(self.stream.name))")

        timerViewModel.startTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopLiveLogTimer()
        hideProcessingOverlay()
    }

    @objc private func abort() {
        stopLiveLogTimer()
        hideProcessingOverlay()
        abortCompletion?()
        dismiss(animated: true, completion: nil)
    }

    private func setStyledTitle() {
        let parts = titleParts(for: stream)

        let titleLabel = UILabel()
        if stream == .PLX {
            titleLabel.text = "SpO\u{2082}: -- %  •  PR: —BPM"
        } else {
            titleLabel.text = parts.text
        }
        self.titleValueLabel = titleLabel
        titleLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = parts.tint
        titleLabel.accessibilityTraits = .header

        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.tintColor = parts.tint
        iv.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        if let symbolName = parts.symbolName, let img = UIImage(systemName: symbolName) {
            iv.image = img
        }
        iv.setContentHuggingPriority(.required, for: .horizontal)
        iv.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [iv, titleLabel])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center

        iv.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iv.widthAnchor.constraint(equalToConstant: 20),
            iv.heightAnchor.constraint(equalToConstant: 20)
        ])

        navigationItem.titleView = stack
    }

    private func titleParts(for stream: StreamType) -> (text: String, tint: UIColor, symbolName: String?) {
        let healthSignColor = UIColor(red: 85/255.0, green: 138/255.0, blue: 152/255.0, alpha: 1.0)
        switch stream {
        case .CLS:
            return ("NIBP", healthSignColor, "gauge.with.needle")
        case .PLX:
            return ("SpO\u{2082}", healthSignColor, "drop.degreesign")
        default:
            return (stream.name, healthSignColor, "circle.fill")
        }
    }
    // MARK: - Debug logging (brightness & gain)
    private func logGainsAndBrightness(_ tag: String) {
        guard let r = store.clsFeatureResult else {
            return
        }
        let g = r.gainControl
        let l = r.ledBrightness

        let ch1Gain = Int(((g.grn1 + g.ylw) / 2.0).rounded()) // BKY / IR
        let ch2Gain = Int(((g.grn2 + g.grn3) / 2.0).rounded()) // FRY / RED

        //print("🔎 \(tag) — GAINS  |  NIBP: BKY(CH1)=\(ch1Gain)  FRY(CH2)=\(ch2Gain)  ||  SpO₂: IR(CH1)=\(ch1Gain)  RED(CH2)=\(ch2Gain)")
    }
    // MARK: - Live periodic logging during measurement
    private func startLiveLogTimer() {
        stopLiveLogTimer()
        liveLogTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.logGainsAndBrightness("CLSVC LIVE (\(self.stream.name))")
        }
    }

    private func stopLiveLogTimer() {
        liveLogTimer?.invalidate()
        liveLogTimer = nil
    }
}

extension CLSViewController {
    private func setupViews() {
        view.backgroundColor = .systemBackground

        let chartStack = SettingsKey.enableDCPlotsValue ? UIStackView(arrangedSubviews: [chart1, chart2, chart3, chart4]) : UIStackView(arrangedSubviews: [chart3, chart4])
        chartStack.axis = .vertical
        chartStack.distribution = .fillEqually
        chartStack.spacing = 0
        chartStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chartStack)

        let timerController = UIHostingController(rootView: TimerView(viewModel: timerViewModel))
        addChild(timerController)
        timerController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(timerController.view)
        NSLayoutConstraint.activate([
            chartStack.topAnchor.constraint(equalToSystemSpacingBelow: view.safeAreaLayoutGuide.topAnchor, multiplier: 1),
            chartStack.leadingAnchor.constraint(equalToSystemSpacingAfter: view.leadingAnchor, multiplier: 1),
            view.trailingAnchor.constraint(equalToSystemSpacingAfter: chartStack.trailingAnchor, multiplier: 1),
            timerController.view.topAnchor.constraint(equalTo: chartStack.bottomAnchor),
            timerController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: timerController.view.trailingAnchor),
            view.safeAreaLayoutGuide.bottomAnchor.constraint(equalTo: timerController.view.bottomAnchor)
        ])

        timerController.didMove(toParent: self)
    }

    private func findLabel(in view: UIView, matchingPrefix prefix: String) -> UILabel? {
        if let l = view as? UILabel, let t = l.text, t.hasPrefix(prefix) { return l }
        for sub in view.subviews {
            if let found = findLabel(in: sub, matchingPrefix: prefix) { return found }
        }
        return nil
    }

    private func resolveTitleLabel(for base: String, in chart: UIView) -> UILabel? {
        if let cached = chartTitleLabelCache.object(forKey: chart) { return cached }
        let found = findLabel(in: chart, matchingPrefix: base)
        if let found { chartTitleLabelCache.setObject(found, forKey: chart) }
        return found
    }

    private func setChartTitle(_ base: String, value: Double, in chart: UIView) {
        let intValue = Int(value.rounded())
        guard let title = resolveTitleLabel(for: base, in: chart) else { return }
        title.text = "\(base): \(intValue)\(base.contains(" AC") ? " mV" : "")"
    }

    private func setChartTitle(_ base: String, value: Int, in chart: UIView) {
        setChartTitle(base, value: Double(value), in: chart)
    }

    private func setChartTitle(_ base: String, value: Float, in chart: UIView) {
        setChartTitle(base, value: Double(value), in: chart)
    }

    private func setChartTitle(_ base: String, value: CGFloat, in chart: UIView) {
        setChartTitle(base, value: Double(value), in: chart)
    }
}

extension CLSViewController {
    private func setupBindings() {
        store.sample
            .sink { [weak self] newSample in
                self?.chart1.setNewSample(newSample.G1)
                self?.chart2.setNewSample(newSample.YL)
                self?.chart3.setNewSample(newSample.G2)
                self?.chart4.setNewSample(newSample.G3)
            }
            .store(in: &subscriptions)
        store.clsFirstReading
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.logGainsAndBrightness("CLSVC MEASUREMENT BEGIN (\(self.stream.name))")
                self.timerViewModel.reset(length: self.timeLimit)
                self.startLiveLogTimer()
            }
            .store(in: &subscriptions)
        store.clsReadingsDone
            .sink { [weak self] readings in
                guard let self = self else { return }

                self.logGainsAndBrightness("CLSVC END (\(self.stream.name))")
                self.stopLiveLogTimer()

                self.showProcessingOverlay("Processing Results…")
                let reading = MonitoringData.MonitoringCLSReading(
                    stream: self.stream,
                    sampleRate: self.rate,
                    clsDuration: self.stream.duration,
                    raw: readings
                )
                self.readingCompletion?(.success(reading))
            }
            .store(in: &subscriptions)
        store.clsReadingsError
            .sink { [weak self] reason in
                self?.stopLiveLogTimer()
                self?.hideProcessingOverlay()
                self?.readingCompletion?(.failure(reason))
            }
            .store(in: &subscriptions)

        if stream == .PLX {
            Publishers.CombineLatest(store.$realTimeSpo2, store.$realTimePlxHR)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] spo2, hr in
                    self?.titleValueLabel?.text = "SpO\u{2082}: \(spo2) %  •  PR: \(Int(hr.rounded())) BPM"
                }
                .store(in: &subscriptions)

            store.$Current_IR_AC_Amplitude
                .receive(on: DispatchQueue.main)
                .sink { [weak self] v in
                    guard let self = self else { return }
                    self.setChartTitle("MIDDLE IR AC", value: v, in: self.chart3)
                }
                .store(in: &subscriptions)

            store.$Current_RD_AC_Amplitude
                .receive(on: DispatchQueue.main)
                .sink { [weak self] v in
                    guard let self = self else { return }
                    self.setChartTitle("MIDDLE RED AC", value: v, in: self.chart4)
                }
                .store(in: &subscriptions)
        }
        if stream == .CLS {
            store.$Current_BKY_AC_Amplitude
                .receive(on: DispatchQueue.main)
                .sink { [weak self] v in
                    guard let self = self else { return }
                    self.setChartTitle("BACK YLW AC", value: v, in: self.chart3)
                }
                .store(in: &subscriptions)

            store.$Current_FRY_AC_Amplitude
                .receive(on: DispatchQueue.main)
                .sink { [weak self] v in
                    guard let self = self else { return }
                    self.setChartTitle("FRONT YLW AC", value: v, in: self.chart4)
                }
                .store(in: &subscriptions)
        }
    }
}
