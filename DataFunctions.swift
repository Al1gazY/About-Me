import Foundation

struct DataFunctions {
    // Reported Tmps
    static func reportedTmp(for measuredTmp: Double) -> Double {
        let targetTmp = 36.5

        if (measuredTmp <= 26.2 || measuredTmp >= targetTmp){
            return measuredTmp + 0.2
        } else {
            return 0.2 * measuredTmp + 0.8 * targetTmp + 0.3
        }
    }


    static func analyze(
        rawCls: [CLSReading],
        rawPlx: [CLSReading],
        reportedTmps: [Double],
        sampleRate: SamplingHz,
        clsFeatureResult: CLSFeatureResult?,
        completion: @escaping (AnalyzeResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var didSendResult = false
            var clsDC1: [Double] = []
            var clsDC2: [Double] = []
            var clsAC1: [Double] = []
            var clsAC2: [Double] = []
            var clsHEXString: [String] = []
            var clsAclReading: [CLSReading.AclReading] = []

            var plxDC1: [Double] = []
            var plxDC2: [Double] = []
            var plxAC1: [Double] = []
            var plxAC2: [Double] = []
            var plxHEXString: [String] = []
            var plxAclReading: [CLSReading.AclReading] = []

            var effectiveCLSSampleRate = 1000
            if (sampleRate.rawValue == 100) {
                effectiveCLSSampleRate = 500
            }

            var effectivePLXSampleRate = 200
            if (sampleRate.rawValue == 100) {
                effectivePLXSampleRate = 100
            }

            let clsSampleCountLimit = effectiveCLSSampleRate * 30
            for e in rawCls.suffix(clsSampleCountLimit) {
                clsDC1.append(e.DC1)
                clsDC2.append(e.DC2)
                clsAC1.append(e.AC1)
                clsAC2.append(e.AC2)
                clsHEXString.append(e.rtPacket)
                if let aclReading = e.aclReading {
                    clsAclReading.append(aclReading)
                }
            }

            let plxSampleCountLimit = effectivePLXSampleRate * 30
            for e in rawPlx.suffix(plxSampleCountLimit) {
                plxDC1.append(e.DC1)
                plxDC2.append(e.DC2)
                plxAC1.append(e.AC1)
                plxAC2.append(e.AC2)
                plxHEXString.append(e.rtPacket)
                if let aclReading = e.aclReading {
                    plxAclReading.append(aclReading)
                }
            }

            var clsLossPct: Double? = nil
            var plxLossPct: Double? = nil

            // (1) SAMPLING FREQUENCY INFO
            let incomingCLSSampF = Double(effectiveCLSSampleRate)
            let incomingPLXSampF = Double(effectivePLXSampleRate)
            // (1) SAMPLING FREQUENCY INFO

            // (2) CLS & PLX SAMPLE COUNT
            let nRawCLS = clsDC1.count
            let nRawPLX = plxDC1.count
            // (2) CLS & PLX SAMPLE COUNT

            // (3) SLIDER INFO
            let backYLWBrightness = clsFeatureResult?.ledBrightness.grn1 // backYLWBrightness
            // print("FINAL SLIDER VALUE GRN1 =", backYLWBrightness ?? 0.0)
            let frontYLWBrightness = clsFeatureResult?.ledBrightness.grn3 // frontYLWBrightness
            let middleGRNBrightness = clsFeatureResult?.ledBrightness.grn2  // middleGRNBrightness
            let middleYLWBrightness = clsFeatureResult?.ledBrightness.ylw // middleYLWBrightness
            let gainNIBPChannel1 = Store.shared.nibpGainCh1
            let gainNIBPChannel2 = Store.shared.nibpGainCh2
            let gainSPO2Channel1 = Store.shared.spo2GainCh1
            let gainSPO2Channel2 = Store.shared.spo2GainCh2
            // (3) SLIDER INFO

            // (4) DECLARE DEFAULT PARAMETER VALUES
            var meanPTT = 0.0
            var SDPTT = 0.0
            var PWV = 0.0
            var heartRate = Int(0.0)
            var HRV = Int(0.0)
            var diastolic = Int(0.0)
            var systolic = Int(0.0)
            var SpO2 = Int(0.0)
            var respiration = Int(0.0)
            var tempValue = 0.0 // °F
            var clsActivityLevel = "N/A"
            var plxActivityLevel = "N/A"
            var clsActivity = 0.0
            var plxActivity = 0.0
            // (4) DECLARE DEFAULT PARAMETER VALUES

            // (5) ANALYSIS PARAMETERS
            let analyzeButtonState = 1 // 0 => Analyze Data Button = OFF, 1 => Analyze Data Button = ON
            let incomingCLSDataDuration = Double(nRawCLS)/incomingCLSSampF // Seconds
            let incomingPLXDataDuration = Double(nRawPLX)/incomingPLXSampF // Seconds
            let thresholdTime = 1.0 // Data duration in seconds threshold
            // (5) ANALYSIS PARAMETERS

            // (6) PERFORM ANALYSIS
            if (analyzeButtonState == 1 && incomingCLSDataDuration > thresholdTime && incomingPLXDataDuration > thresholdTime) { // PROCEED: ANALYZE DATA...
                let clsAnalyze = CLSAnalyze(incomingSampF: incomingCLSSampF, backYLWBrightness: backYLWBrightness ?? 0.0, frontYLWBrightness: frontYLWBrightness ?? 0.0, gainChannel1: gainNIBPChannel1 ?? 0.0, gainChannel2: gainNIBPChannel2 ?? 0.0, clsHEXString: clsHEXString)
              //  let features2D  = clsAnalyze.features2D   // <-- NEW
                meanPTT = clsAnalyze.meanPTT
                SDPTT = clsAnalyze.SDPTT
                PWV = clsAnalyze.PWV
                diastolic = clsAnalyze.diastolic
                systolic = clsAnalyze.systolic
                clsActivityLevel = clsAnalyze.clsActivityLevel
                clsActivity = clsAnalyze.clsActivity
                let clsHR = clsAnalyze.clsHR
                let clsHRV = clsAnalyze.clsHRV
                let RRclsArray = clsAnalyze.RRclsArray
                let plxAnalyze = PLXAnalyze(incomingSampF: incomingPLXSampF, middleYLWBrightness: middleYLWBrightness ?? 0.0, middleGRNBrightness: middleGRNBrightness ?? 0.0, gainChannel1: gainSPO2Channel1 ?? 0.0, gainChannel2: gainSPO2Channel2 ?? 0.0, plxHEXString: plxHEXString)
                SpO2 = plxAnalyze.SpO2
                plxActivityLevel = plxAnalyze.plxActivityLevel
                plxActivity = plxAnalyze.plxActivity
                let plxHR = plxAnalyze.plxHR
                let plxHRV = plxAnalyze.plxHRV
                let RRplxArray = plxAnalyze.RRplxArray
                clsLossPct = clsAnalyze.packetLossPct
                plxLossPct = plxAnalyze.packetLossPct
                // (6) PERFORM ANALYSIS

                // (7) CALCULATE HR
                var newHRArray = [Double] ()
                var newHRVArray = [Double] ()
                let HRArray = [clsHR, plxHR]
                let HRVArray = [clsHRV, plxHRV]
                for i in 0..<HRArray.count {
                    if (HRArray[i] > 0.0) {
                        newHRArray.append(HRArray[i])
                    }
                    if (HRVArray[i] > 0.0) {
                        newHRVArray.append(HRVArray[i])
                    }
                }
                if(newHRArray.count >= 1) {
                    heartRate = Int(round(mean(y: newHRArray))) // Average of all HRs
                }
                if (newHRVArray.count >= 1) {
                    HRV = Int(round(mean(y: newHRVArray))) // Average of all HRs
                }
                // (7) CALCULATE HR

                // (8) CALCULATE RR
                var newRRArray = [Double] ()
                let RRArray = RRclsArray + RRplxArray
                for i in 0..<RRArray.count {
                    if (RRArray[i] > 0.0) {
                        newRRArray.append(RRArray[i])
                    }
                }
                if (newRRArray.count >= 1) {
                    respiration = Int(round(mean(y: newRRArray))) // Average of all RRs
                }
                // (8) CALCULATE RR

                // (9) GET ACTUAL TEMP FROM DEVICE
                tempValue = 99.4 // °F
                let tempArray0 = Array(reportedTmps.suffix(10)) // Last 10 temp values
                tempValue = round(mean(y: tempArray0)*Double(tempArray0.count))/Double(tempArray0.count) // Round
                // (9) GET ACTUAL TEMP FROM DEVICE

                // provisional result (no predicted BP yet)
                if !didSendResult {
                    didSendResult = true
                    let provisional = AnalyzeResult(
                        hr: heartRate, rr: respiration, spO2: SpO2,
                        sysBP: systolic, diaBP: diastolic,
                        temp: tempValue, hrv: HRV,
                        pwv: round(PWV*10)/10,
                        meanPTT: meanPTT, SDPTT: SDPTT,
                        clsActivity: clsActivity, plxActivity: plxActivity,
                        predictedSysBP: [systolic], predictedDiaBP: [diastolic],
                        clsPacketLoss: clsLossPct.map { String(format: "%.1f %%", $0) },
                        plxPacketLoss: plxLossPct.map { String(format: "%.1f %%", $0) }
                    )
                    DispatchQueue.main.async { completion(provisional) }
                }

                // fetch predicted BP asynchronously; UI will update via Notification

            }

            else if (analyzeButtonState == 1 && incomingCLSDataDuration > thresholdTime) { // PROCEED: ANALYZE DATA...

                // (10)  PERFORM ANALYSIS
                let clsAnalyze = CLSAnalyze(incomingSampF: incomingCLSSampF, backYLWBrightness: backYLWBrightness ?? 0.0, frontYLWBrightness: frontYLWBrightness ?? 0.0, gainChannel1: gainNIBPChannel1 ?? 0.0, gainChannel2: gainNIBPChannel2 ?? 0.0, clsHEXString: clsHEXString)
                clsLossPct = clsAnalyze.packetLossPct
                meanPTT = clsAnalyze.meanPTT
                SDPTT = clsAnalyze.SDPTT
                PWV = clsAnalyze.PWV
               // let features2D  = clsAnalyze.features2D   // <-- NEW

                diastolic = clsAnalyze.diastolic
                systolic = clsAnalyze.systolic
                clsActivityLevel = clsAnalyze.clsActivityLevel
                clsActivity = clsAnalyze.clsActivity
                let clsHR = clsAnalyze.clsHR
                let clsHRV = clsAnalyze.clsHRV
                let RRclsArray = clsAnalyze.RRclsArray
                heartRate = Int(clsHR)
                HRV = Int(clsHRV)
                var newRRArray = [Double] ()
                let RRArray = RRclsArray
                for i in 0..<RRArray.count {
                    if (RRArray[i] > 0.0) {
                        newRRArray.append(RRArray[i])
                    }
                }
                if (newRRArray.count >= 1) {
                    respiration = Int(round(mean(y: newRRArray))) // Average of all RRs
                }
                tempValue = TempAnalyze(reportedTmps: reportedTmps)
                // (10)  PERFORM ANALYSIS

                // provisional result (no predicted BP yet)
                if !didSendResult {
                    didSendResult = true
                    let provisional = AnalyzeResult(
                        hr: heartRate, rr: respiration, spO2: SpO2,
                        sysBP: systolic, diaBP: diastolic,
                        temp: tempValue, hrv: HRV,
                        pwv: round(PWV*10)/10,
                        meanPTT: meanPTT, SDPTT: SDPTT,
                        clsActivity: clsActivity, plxActivity: plxActivity,
                        predictedSysBP: [systolic], predictedDiaBP: [diastolic]
                        , clsPacketLoss: clsLossPct.map { String(format: "%.1f %%", $0) }
                        , plxPacketLoss: plxLossPct.map { String(format: "%.1f %%", $0) }
                    )
                    DispatchQueue.main.async { completion(provisional) }
                }

                // fetch predicted BP asynchronously; UI will update via Notification


            }

            else if (analyzeButtonState == 1 && incomingPLXDataDuration > thresholdTime) { // PROCEED: ANALYZE DATA...

                // (11)  PERFORM ANALYSIS
                let plxAnalyze = PLXAnalyze(incomingSampF: incomingPLXSampF, middleYLWBrightness: middleYLWBrightness ?? 0.0, middleGRNBrightness: middleGRNBrightness ?? 0.0, gainChannel1: gainSPO2Channel1 ?? 0.0, gainChannel2: gainSPO2Channel2 ?? 0.0, plxHEXString: plxHEXString)
                plxLossPct = plxAnalyze.packetLossPct
                SpO2 = plxAnalyze.SpO2
                plxActivityLevel = plxAnalyze.plxActivityLevel
                plxActivity = plxAnalyze.plxActivity
                let plxHR = plxAnalyze.plxHR
                let plxHRV = plxAnalyze.plxHRV
                let RRplxArray = plxAnalyze.RRplxArray
                heartRate = Int(plxHR)
                HRV = Int(plxHRV)
                var newRRArray = [Double] ()
                let RRArray = RRplxArray
                for i in 0..<RRArray.count {
                    if (RRArray[i] > 0.0) {
                        newRRArray.append(RRArray[i])
                    }
                }
                if (newRRArray.count >= 1) {
                    respiration = Int(round(mean(y: newRRArray))) // Average of all RRs
                }
                tempValue = TempAnalyze(reportedTmps: reportedTmps)
            } else { // DON'T ANALYZE CLS OR PLX
                // DO NOTHING !
                tempValue = TempAnalyze(reportedTmps: reportedTmps)
            }
            // (11) PERFORM ANALYSIS

            // (12) GENERATE HEALTH ALERTS
            let alertsButton = 1 // 0 is OFF, 1 is ON
            var hrRedColorCode = 0 // 0 means red color is OFF, 1 means red color is ON
            var rrRedColorCode = 0 // 0 means red color is OFF, 1 means red color is ON
            var nibpRedColorCode = 0 // 0 means red color is OFF, 1 means red color is ON
            var spo2RedColorCode = 0 // 0 means red color is OFF, 1 means red color is ON
            var tempRedColorCode = 0 // 0 means red color is OFF, 1 means red color is ON
            let lowerHRThreshold = 60 // BPM
            let upperHRThreshold = 100 // BPM
            let lowerRRThreshold = 8 // BRPM
            let upperRRThreshold = 20 // BRPM
            let systolicThreshold = 140 // mmHg
            let diastolicThreshold = 90 // mmHg
            let spo2Threshold = 94 // %
            let temperatureThreshold = 37.0 // °C

            if (alertsButton == 1) {
                if(heartRate > 0 && (heartRate > upperHRThreshold || heartRate < lowerHRThreshold)) {
                    hrRedColorCode = 1
                }
                if(respiration > 0 && (respiration > upperRRThreshold || respiration < lowerRRThreshold)) {
                    rrRedColorCode = 1
                }
                if((systolic > 0 && diastolic > 0) && (systolic > systolicThreshold || diastolic > diastolicThreshold)) {
                    nibpRedColorCode = 1
                }
                if(SpO2 > 0 && SpO2 < spo2Threshold) {
                    spo2RedColorCode = 1
                }
                if(tempValue > 0 && tempValue > temperatureThreshold) {
                    tempRedColorCode = 1
                }
            } else {
                // Generate No Alerts !
            }
            // (12) GENERATE HEALTH ALERTS

            // (13) PRINT / DISPLAY MAIN RESULTS WITH HEALTH ALERTS
            print(" ")
            print("Heart Rate =", heartRate, "BPM, Heart Rate Red Color Code =", hrRedColorCode)
            print(" ")
            print("Respiration Rate =", respiration, "BRPM, Respiration Rate Red Color Code =", rrRedColorCode)
            print(" ")
            print("SpO2 =", SpO2, "%, SpO2 Red Color Code =", spo2RedColorCode)
            print(" ")
            print("NIBP =", systolic, "/", diastolic, "mmHg, NIBP Red Color Code =", nibpRedColorCode)
            print(" ")
            print("Temperature =", tempValue, "°F, Temperature Red Color Code =", tempRedColorCode)
            print(" ")
            // (13) PRINT / DISPLAY MAIN RESULTS WITH HEALTH ALERTS

            // (14) PRINT / DISPLAY OTHER RESULTS
            print("HRV =", HRV, "ms")
            print(" ")
            print("PWV =", PWV, "m/s")
            print(" ")
            print("PTT =", meanPTT, "±", SDPTT, "ms")
            print(" ")
            print("CLS Activity =", clsActivityLevel)
            print(" ")
            print("PLX Activity =", plxActivityLevel)
            print(" ")
            // (14) PRINT / DISPLAY OTHER RESULTS

            // (15) RETURN RESULTS
            if !didSendResult {
                let result = AnalyzeResult(
                    hr: heartRate,
                    rr: respiration,
                    spO2: SpO2,
                    sysBP: systolic,
                    diaBP: diastolic,
                    temp: tempValue,
                    hrv: HRV,
                    pwv: round(PWV*10)/10,
                    meanPTT: meanPTT,
                    SDPTT: SDPTT,
                    clsActivity: clsActivity,
                    plxActivity: plxActivity
                    , clsPacketLoss: clsLossPct.map { String(format: "%.1f %%", $0) }
                    , plxPacketLoss: plxLossPct.map { String(format: "%.1f %%", $0) }
                )
                DispatchQueue.main.async {
                    completion(result)
                }
            }
        }
    }

}
