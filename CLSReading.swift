import Foundation


struct CLSReading {
    struct AclReading {
        let x: Double
        let y: Double
        let z: Double

        var R: Double {
            let x2 = pow(Double(x), 2)
            let y2 = pow(Double(y), 2)
            let z2 = pow(Double(z), 2)

            let R = sqrt(x2 + y2 + z2)
            return R
        }
    }

    let DC1: Double
    let DC2: Double
    let AC1: Double
    let AC2: Double
    let pktID: UInt16
    let rtPacket: String
    let aclReading: AclReading?
}

extension CLSReading {
    init?(_ clsData: Data,
          transmitEnabled: Bool,
          transmitThousandHzEnabled: Bool,
          currentStream: StreamType) {

        let string = String(data: clsData, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let string = string {
            print("ADRIANSTR = ", string)
        }

        // 1. Try Legacy Logic first: Look for markers ("W", "Z", "x") in ASCII string
        if let string = string, (string.contains("W") || string.contains("Z") || string.contains("x")) {
             // Fall through to existing legacy parsing logic below
        } else {
             // 2. TableTop (Adrian STR) / Standard BLE Logic: Parse raw Data bytes
             // The device might send raw binary, or a hex string.
             // If 'string' conversion failed OR no legacy markers found, try treating as TableTop format.

             // Check if it's potentially an ASCII Hex String (per documentation "This is the string you will receive...")
             var dataToParse: Data = clsData
             var isHexString = false

             if let str = string {
                 let cleanString = str.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
                 if !cleanString.isEmpty && cleanString.allSatisfy({ $0.isHexDigit }) && cleanString.count % 2 == 0 {
                     // It looks like a valid hex string. Convert back to Data bytes.
                     var hexData = Data()
                     var temp = ""
                     for char in cleanString {
                         temp.append(char)
                         if temp.count == 2 {
                             if let byte = UInt8(temp, radix: 16) {
                                 hexData.append(byte)
                             }
                             temp = ""
                         }
                     }
                     if !hexData.isEmpty {
                         dataToParse = hexData
                         isHexString = true
                     }
                 }
             }

             // Now parse 'dataToParse' as BPS/ICP structure (IEEE 11073-20601 SFloat)
             // Minimum length: 3 bytes (Flags + SFloat) for ICP
             if dataToParse.count >= 3 {
                 func parseSFloat(_ value: UInt16) -> Double {
                     var exponent = Int((value & 0xF000) >> 12)
                     if exponent >= 8 { exponent -= 16 }

                     var mantissa = Int(value & 0x0FFF)
                     if mantissa >= 2048 { mantissa -= 4096 }

                     if mantissa == 2047 { return Double.infinity }
                     if mantissa == -2048 { return Double.nan }

                     return Double(mantissa) * pow(10.0, Double(exponent))
                 }

                 var extractedPressure: Double = 0.0
                 let flags = dataToParse[0]
                 let units = (flags & 0x01) == 0 ? "mmHg" : "kPa"

                 // Heuristic: BPS Notification is usually longer (>= 7 bytes)
                 if dataToParse.count >= 7 {
                     let sysRaw = UInt16(dataToParse[1]) | (UInt16(dataToParse[2]) << 8)
                     let diaRaw = UInt16(dataToParse[3]) | (UInt16(dataToParse[4]) << 8)
                     let meanRaw = UInt16(dataToParse[5]) | (UInt16(dataToParse[6]) << 8)

                     let sys = parseSFloat(sysRaw)
                     let dia = parseSFloat(diaRaw)
                     let mean = parseSFloat(meanRaw)

                     var output = "BPS Notification: Sys: \(sys) \(units), Dia: \(dia) \(units), Mean: \(mean) \(units)"

                     var offset = 7
                     if (flags & 0x02) != 0 { offset += 7 } // Timestamp
                     if (flags & 0x04) != 0 { // Pulse Rate
                         if dataToParse.count >= offset + 2 {
                             let pulseRaw = UInt16(dataToParse[offset]) | (UInt16(dataToParse[offset+1]) << 8)
                             let pulse = parseSFloat(pulseRaw)
                             output += ", Pulse: \(pulse) bpm"
                             offset += 2
                         }
                     }
                     if (flags & 0x08) != 0 { offset += 1 } // User ID
                     if (flags & 0x10) != 0 { // Status
                         if dataToParse.count >= offset + 2 {
                             let status = UInt16(dataToParse[offset]) | (UInt16(dataToParse[offset+1]) << 8)
                             output += ", Status: 0x\(String(format:"%04X", status))"
                             offset += 2
                         }
                     }
                     print(output)
                 }
                 // ICP Indication (shorter, typically 3-5 bytes)
                 else {
                     let icpRaw = UInt16(dataToParse[1]) | (UInt16(dataToParse[2]) << 8)
                     let icp = parseSFloat(icpRaw)
                     extractedPressure = icp
                     print("ICP Indication: Cuff Pressure: \(icp) \(units)")
                 }

                 // Populate DC channels with pressure to visualize on graph
                 self = CLSReading(
                    DC1: extractedPressure,
                    DC2: extractedPressure,
                    AC1: 0,
                    AC2: 0,
                    pktID: 0,
                    rtPacket: string ?? dataToParse.hexEncodedString(),
                    aclReading: nil
                 )
                 return
             }
        }

        // --- Legacy Logic Continuation ---
        guard let string = string else { return nil }

        let neg_num = -0.9000549349935909
        let pktID: UInt16
        let DC1: Double
        let DC2: Double
        let AC1: Double
        let AC2: Double
        var aclReading: AclReading?


        if transmitEnabled {


             pktID = 1
             DC1 = 1.0
             DC2 = 1.0
             AC1 = 1.0
             AC2 = 1.0

            //1000
        } else if (transmitThousandHzEnabled) {
            // i need variabe to identify the current stream
            if currentStream == .CLS {

                //print("I AM IN CLS:")
                //print("CURRENT STR INSIDE PLX:", currentStreamType ?? nil)
                //************ 1000 Hz CLS (BLE 200 HZ) Code ************
                let segments = string.components(separatedBy: CharacterSet(charactersIn: "WZ"))

                let voltageSegment = segments[0]

                pktID = UInt16(String(voltageSegment.prefix(4)), radix: 16) ?? 65535 // First 4 chars

                let component1 = String(voltageSegment.dropFirst(4).prefix(4)) // Next 4 chars
                let component2 = String(voltageSegment.dropFirst(8).prefix(4)) // Next 4 chars after the first 8
                //print("Component 1 :", component1)
                //print("Component 2 :", component2)
                let components = [component1, component2]
                let max = Double(Int("3FFF", radix: 16)!)
                var voltages = components
                    .compactMap { UInt16($0, radix: 16) }
                    .map { Int16(bitPattern: $0) }
                    .map(Double.init)
                    .map { ($0 / max) * 3.6 }



                if (voltages[0] == neg_num) {
                    voltages[0] = Double.nan
                }

                if (voltages[1] == neg_num) {
                    voltages[1] = Double.nan
                }
                AC1 = voltages[0]
                AC2 = voltages[1]
                //print("AC1:", AC1)
                //print("AC2:", AC2)

                if segments.count == 2 {
                    let aclDCSegment = segments[1]

                    if aclDCSegment.contains("x") { // Found ACL x, y, z
                        let acl = aclDCSegment.components(separatedBy: "x")
                            .compactMap { UInt16($0, radix: 16) }
                            .map { Int16(bitPattern: $0) }
                            .map(Double.init)

                        if acl.count == 3 {
                            aclReading = .init(x: acl[0], y: acl[1], z: acl[2])
                        }

                        DC1 = Double.nan
                        DC2 = Double.nan

                    } else { // found W (DC1, DC2)
                        let d1 = String(aclDCSegment.prefix(4))
                        let d2 = String(aclDCSegment.dropFirst(4).prefix(4))
                        let dcComponents = [d1, d2]
                        var dcReading = dcComponents
                            .compactMap { UInt16($0, radix: 16) }
                            .map { Int16(bitPattern: $0) }
                            .map(Double.init)
                            .map { ($0 / max) * 3.6 }

                        if (dcReading[0] == neg_num) {
                            dcReading[0] = Double.nan
                        }

                        if (dcReading[1] == neg_num) {
                            dcReading[1] = Double.nan
                        }
                        DC1 = dcReading[0]
                        DC2 = dcReading[1]
                    }
                }
                else {
                    DC1 = Double.nan
                    DC2 = Double.nan
                }
                //print("DC1:", DC1)
                //print("DC2:", DC2)
                //************ 1000 Hz CLS (BLE 200 HZ) Code ************
            }  else if currentStream == .PLX {

                //print("I AM IN PLX:")
                // Look for Z (ACL)
                let segments = string.components(separatedBy: CharacterSet(charactersIn: "Z"))

                // Voltage segment
                let voltageSegment = segments[0]

                pktID = UInt16(String(voltageSegment.prefix(4)), radix: 16) ?? 65535 // First 4 chars (PKD ID)

                let c1 = String(voltageSegment.dropFirst(4).prefix(4)) // Next 4 chars (DC1)
                let c2 = String(voltageSegment.dropFirst(8).prefix(4)) // Next 4 chars after the first 8 (DC2)
                let c3 = String(voltageSegment.dropFirst(12).prefix(4)) // Next 4 chars after the first 12 (AC1)
                let c4 = String(voltageSegment.dropFirst(16).prefix(4)) // Next 4 chars after the first 16 (AC2)

                let max = Double(Int("3FFF", radix: 16)!)

                let components =  [c1, c2, c3, c4]

                var voltages = components
                    .compactMap { UInt16($0, radix: 16) }
                    .map { Int16(bitPattern: $0) }
                    .map(Double.init)
                    .map { ($0 / max) * 3.6 }

                // TODO: Comment voltage 0 and 2 for simulator
                if (voltages[0] == neg_num) {
                    voltages[0] = Double.nan
                }

                if (voltages[1] == neg_num) {
                    voltages[1] = Double.nan
                }

                if (voltages[2] == neg_num) {
                    voltages[2] = Double.nan
                }

                if (voltages[3] == neg_num) {
                    voltages[3] = Double.nan
                }

                DC1 = voltages[0]
                DC2 = voltages[1]
                AC1 = voltages[2]
                AC2 = voltages[3]



                if segments.count == 2 {
                    let aclSegment = segments[1]
                    if aclSegment.contains("x") {
                        let acl = aclSegment.components(separatedBy: "x")
                            .compactMap { UInt16($0, radix: 16) }
                            .map { Int16(bitPattern: $0) }
                            .map(Double.init)

                        if acl.count == 3 {
                            aclReading = .init(x: acl[0], y: acl[1], z: acl[2])
                        }
                    }
                }

                //plx
            } else {
                //print("I AM IN NIL:")
                pktID = 1
                DC1 = 1.0
                DC2 = 1.0
                AC1 = 1.0
                AC2 = 1.0
            }


        } else {

            let segments = string.components(separatedBy: CharacterSet(charactersIn: "Z"))

            let voltageSegment = segments[0]

            let components = voltageSegment.components(separatedBy: "x")
            guard components.count >= 5 else { return nil }

            pktID = UInt16(components[0], radix: 16) ?? 65535

            let max = Double(Int("3FFF", radix: 16)!)
            var voltages = components
                .dropFirst()
                .dropLast()
                .prefix(4)
                .compactMap { UInt16($0, radix: 16) }
                .map { Int16(bitPattern: $0) }
                .map(Double.init)
                .map { ($0 / max) * 3.6 }


            // TODO: Comment voltage 0 and 2 for simulator
            if (voltages[0] == neg_num) {
                voltages[0] = Double.nan
            }

            if (voltages[1] == neg_num) {
                voltages[1] = Double.nan
            }

            if (voltages[2] == neg_num) {
                voltages[2] = Double.nan
            }

            if (voltages[3] == neg_num) {
                voltages[3] = Double.nan
            }

            DC1 = voltages[0]
            DC2 = voltages[1]
            AC1 = voltages[2]
            AC2 = voltages[3]

            if segments.count == 2 {
                let aclSegment = segments[1]

                if aclSegment.contains("x") {
                    let acl = aclSegment.components(separatedBy: "x")
                        .compactMap { UInt16($0, radix: 16) }
                        .map { Int16(bitPattern: $0) }
                        .map(Double.init)

                    if acl.count == 3 {
                        aclReading = .init(x: acl[0], y: acl[1], z: acl[2])
                    }
                }
            }
        }

        self = CLSReading(
            DC1: DC1,
            DC2: DC2,
            AC1: AC1,
            AC2: AC2,
            pktID: pktID,
            rtPacket: string,
            aclReading: aclReading
        )
    }
}

extension CLSReading {
    var reading: String {
        "\(pktID)\t\(DC1)\t\(DC2)\t\(AC1)\t\(AC2)\t\(rtPacket)"
    }
}
