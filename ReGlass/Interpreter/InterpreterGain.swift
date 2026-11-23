import Foundation

/// Real-time 6-channel STFT MVDR mouth-null beamformer (`N = 256, hop = 128`, sqrt-Hann WOLA) and 3-band own-voice
/// detector for the glasses' outward live-translation microphone (s0 message 6100, 16 kHz, mode `0x305`).
///
/// The wearer's mouth sits at a fixed near-field geometry relative to the 6 frame microphones (ch2 and ch4 arrive
/// 30–60 µs late and 2.4–3.2 dB quieter than ch0, with 0.90–0.98 inter-channel coherence below 2 kHz). Across bins
/// 2...64 (125–4000 Hz), the MVDR filter nulls the wearer's mouth by ~10 dB while preserving far-field speech at unit
/// gain; above 4 kHz (where codec phase coherence drops), ch0 passes through directly so high-frequency hiss isn't
/// amplified. Comparing the beamformed power against ch0 across 600–1200, 1200–2400 and 2400–4000 Hz detects when the
/// wearer is speaking (`r < -7 dB`, `snr > 15 dB`) so `InterpreterGain` can freeze its automatic gain instead of
/// ducking on the wearer's voice.
///
/// The weights are fixed. They were calibrated once, offline, on one wearer with these glasses; other wearers (another
/// head, another fit) may get less benefit from the mouth null.
struct InterpreterSixChannelSelector {
    static let channelCount = 6
    private static let fftSize = 256
    private static let hopSize = 128
    private static let bins = fftSize / 2 + 1
    private static let activeBins = 65 // 0...64 (0–4000 Hz at 16 kHz)
    private static let hangHops = 15   // 120 ms at 8 ms per hop

    private static let window: [Double] = (0..<fftSize).map {
        sqrt(0.5 - 0.5 * cos(2.0 * Double.pi * Double($0) / Double(fftSize)))
    }
    private static let cosTable: [Double] = (0..<(fftSize / 2)).map {
        cos(-2.0 * Double.pi * Double($0) / Double(fftSize))
    }
    private static let sinTable: [Double] = (0..<(fftSize / 2)).map {
        sin(-2.0 * Double.pi * Double($0) / Double(fftSize))
    }
    private static let bitRev: [Int] = (0..<fftSize).map { i in
        var r = 0, x = i
        for _ in 0..<8 { r = (r << 1) | (x & 1); x >>= 1 }
        return r
    }

    /// Pre-calibrated MVDR mouth-null weights `W[k][c]` for bins `k = 0...64` (`65 * 6 = 390` entries),
    /// with δ = 0.01 and unit-gain steering toward the far-field speaker. Calibrated once, offline, on one wearer
    /// (see above).
    private static let wRe: [Double] = [
        1.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000,
        1.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000,
        -0.036671, -1.244983, 2.512486, -0.055829, 0.809641, -1.343772,
        -0.362004, -0.870364, 2.635732, -0.500313, 1.349694, -1.277470,
        -0.923846, -0.200675, 1.372635, -1.055574, 1.981196, -0.207720,
        -0.797600, 0.048216, 0.822251, -0.939307, 1.725225, -0.103097,
        -0.384183, -0.337392, 1.376459, -0.376011, 0.660072, -0.431700,
        -0.355221, -0.481927, 1.573782, -0.273033, 0.637284, -0.522228,
        -0.475127, -0.323913, 1.554570, -0.689241, 1.232286, -0.356266,
        -0.769238, -0.612395, 1.721119, -0.396151, 1.764993, -0.707191,
        -0.784490, -0.408572, 1.203928, -0.462001, 1.501768, -0.341917,
        -0.339640, -0.421936, 0.695932, -0.085595, 0.613925, -0.120800,
        -0.029290, -0.360483, 0.422303, -0.074926, 0.756756, 0.081100,
        -0.131748, -0.283224, 0.500917, -0.308824, 0.845004, -0.005500,
        -0.387495, -0.135240, 9.26506e-01, -0.153442, 0.626586, -0.262690,
        -0.296482, 0.027065, 0.651434, 0.368390, -0.095181, -0.457778,
        -0.091739, 0.282393, 0.906343, -0.030946, 0.030207, -0.696692,
        -0.067654, -0.255884, 1.030430, -0.053160, 0.497644, -0.258127,
        0.010139, -0.494193, 0.891755, -0.024762, 0.505263, -0.089345,
        -0.172542, -0.306627, 0.737916, -0.171318, 0.579459, -0.163305,
        -0.113267, 0.075918, 0.427912, -0.389987, 0.359994, -0.379591,
        -0.206662, 0.111761, 0.836973, -0.282692, 0.541715, -0.670470,
        -0.224421, 0.011064, 0.300405, -0.063741, 0.467983, -0.102936,
        -0.160183, -0.032678, 0.180705, -0.039185, 0.186965, 0.113226,
        -0.147036, -0.322900, 0.360273, -0.002045, 0.495067, 0.156622,
        -0.176586, -0.237741, 0.251042, 0.030839, 0.423962, 0.155999,
        -0.062198, -0.168232, 0.273430, -0.052346, 0.383893, 0.009001,
        -0.119490, -0.030625, 0.091776, -0.022376, 0.290420, -0.005611,
        -0.189378, -0.031050, 0.399389, -0.065699, 0.411181, -0.009316,
        -0.101150, 0.016203, 0.173736, -0.031064, 0.334152, -0.064712,
        -0.049891, 0.086777, 0.152652, 0.012557, 0.150589, -0.193752,
        -0.010661, 0.013142, 0.045098, -0.015775, 0.050710, -0.026680,
        -0.004929, 0.031083, 0.047731, 0.000984, -0.046503, -0.068719,
        -0.033913, 0.001016, -0.001560, 0.000265, 0.025410, 0.022967,
        0.039790, 0.002385, 0.087525, -0.018962, -0.062343, 0.015746,
        -0.153110, 0.024994, 0.324173, 0.082619, -0.076989, -0.116426,
        -0.106080, -0.068014, 0.241618, 0.037041, -0.036114, -0.063361,
        -0.084250, -0.005445, 0.181816, 0.021372, -0.017103, -0.091471,
        -0.092956, 0.068855, 0.179098, 0.015769, -0.046870, -0.059824,
        -0.063277, 0.035974, 0.082125, 0.029430, -0.027386, -0.038756,
        -0.010255, -0.017678, 0.016489, 0.003621, -0.001706, 0.007791,
        0.013270, 0.000747, -0.015638, -0.008120, 0.004865, 0.002112,
        0.059230, 0.000270, -0.054055, -0.030288, 0.010150, 0.007686,
        0.103644, 0.011554, -0.067481, -0.066713, -0.007624, 0.046377,
        0.111441, 0.014132, -0.094733, -0.126212, 0.016467, 0.067589,
        0.128391, 0.005523, -0.147825, -0.114023, 0.044831, 0.090517,
        0.177742, 0.004559, -0.137321, -0.113227, 0.035559, 0.079654,
        0.251197, 0.048100, -0.282906, -0.143297, 0.061311, 0.130784,
        0.376076, 0.110928, -0.434805, -0.231699, 0.024652, 0.136286,
        0.364908, 0.014927, -0.317981, -0.229713, 0.061608, 0.078276,
        0.116519, -0.060337, -0.154994, -0.049942, 0.005647, 0.206512,
        0.071886, -0.033823, -0.023614, 0.038615, 0.017565, 0.250003,
        0.506876, 0.111255, -0.303818, -0.073195, -0.196744, 0.030614,
        0.492263, 0.123657, -0.255843, -0.229676, -0.330331, 0.190244,
        0.678227, 0.126804, -0.234679, -0.407077, 0.235118, -0.026932,
        0.424837, 0.249792, 0.067301, -0.309478, -0.596050, -0.146276,
        0.171958, 0.128756, -0.125795, -0.044290, -0.377818, -0.003122,
        0.074765, 0.068550, 0.078244, -0.044281, -0.063772, -0.031297,
        -0.014446, 0.043601, 0.040248, -0.051334, -0.044698, 0.040647,
        -0.034779, -0.020486, 0.043640, 0.007230, 0.016563, 0.044139,
        -0.012282, -0.042864, -0.013387, -0.029744, -0.036135, 0.043892,
        0.074268, 0.083303, -0.108821, -0.067782, -0.081196, -0.076355,
        0.074888, 0.021706, -0.072834, -0.050519, -0.088123, -0.043071,
        0.024306, 0.022934, -0.042782, -0.009402, -0.008718, -0.002206,
        0.015990, 0.056841, -0.014772, 0.008029, -0.073526, -0.027634,
    ]

    private static let wIm: [Double] = [
        0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000,
        0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000,
        0.629922, -0.025984, 0.610630, -0.356005, -0.243622, -0.693024,
        0.578933, 0.480258, 0.100716, -0.972653, 0.008722, -0.374945,
        0.052429, 0.620881, -0.204478, -1.032109, 0.594772, -0.233717,
        0.547132, 0.168072, 0.330462, -0.457752, -0.116659, -0.741308,
        0.989209, -0.367443, 1.173971, -0.275082, -0.461722, -1.298955,
        0.951555, -0.055259, 1.083707, -0.544064, -0.556766, -1.140304,
        0.546659, 0.109850, 0.402842, -1.068805, 0.435731, -0.663957,
        0.923317, -0.227534, 0.559829, -0.718762, 0.154801, -1.253002,
        0.817514, -0.137403, 0.573375, -0.456276, -0.209868, -1.248936,
        0.488579, 0.080038, 0.169870, 0.061630, -0.656766, -0.821382,
        0.213629, -0.216157, 0.813293, -0.185532, -0.072451, -0.850649,
        0.040614, -0.177312, 0.497173, -0.465648, 0.703291, -0.530645,
        0.263855, 0.228951, 0.451736, -0.746882, 0.481066, -0.878379,
        0.478805, -0.094587, 0.187286, -0.447853, -0.124574, -0.253888,
        0.580840, -0.086233, 0.383162, -0.535088, -0.190076, -0.464868,
        0.224836, -0.070941, 0.663351, -0.733539, 0.208382, -0.582543,
        0.207605, 0.327606, 0.302827, -0.409545, 0.072611, -0.843177,
        0.155052, 0.479635, 0.248474, -0.246989, -0.332480, -0.750413,
        0.413869, 0.387187, 0.079332, -0.118698, -0.564158, -0.610154,
        0.559514, 0.473507, 0.034950, -0.698943, -0.367651, -0.685095,
        0.063086, 0.357509, -0.008706, -0.373960, -0.109207, -0.422873,
        0.070382, 0.162425, -0.104133, -0.213549, -0.040315, -0.152028,
        0.134808, 0.144253, -0.200701, -0.358142, -0.011440, -0.024071,
        0.051744, 0.053364, -0.253529, -0.190593, 0.141971, 0.025840,
        0.127927, 0.130617, -0.184116, -0.265080, 0.140337, -0.139953,
        0.039249, 0.068875, 0.054238, -0.051807, -0.036214, -0.231400,
        0.147110, -0.068339, 0.144599, -0.352076, 0.167602, -0.311667,
        -0.018302, 0.016106, 0.093365, -0.100182, 0.131530, -0.256961,
        0.020188, -0.026048, 0.156004, -0.045287, -0.017304, -0.231950,
        0.006900, -0.002549, 0.059995, -0.011052, -0.020023, -0.080067,
        0.038340, 0.017835, 0.039699, 0.012387, -0.096079, -0.073320,
        0.004686, 0.044740, 0.020790, 0.025963, -0.060697, -0.080717,
        -0.001804, -0.078354, -0.031823, -0.075422, 0.173063, 0.094231,
        0.154444, -0.054503, -0.058231, -0.189295, 0.080081, -0.052450,
        0.152628, -0.017591, -0.096566, -0.131466, -0.004273, -0.028709,
        0.137400, -0.012333, -0.083383, -0.116973, -0.003949, -0.039150,
        0.055527, 0.003794, -0.066102, -0.075302, 0.000091, -0.031389,
        0.049259, 0.008179, -0.030714, -0.034103, -0.006142, -0.022140,
        0.034358, -0.007357, -0.030177, -0.031365, 0.021918, 0.004218,
        -0.009607, 0.009124, 0.010648, 0.010606, -0.002877, -0.005380,
        -0.019841, 0.017016, 0.031611, 0.034888, -0.009505, -0.017182,
        -0.033227, 0.032929, 0.039751, 0.052341, 0.018210, -0.012543,
        -0.011792, -0.016358, 0.064486, 0.069657, 0.007323, 0.000056,
        -0.034552, -0.006795, 0.094041, 0.053971, 0.015411, -0.011847,
        -0.042053, -0.021046, 0.111958, 0.074450, 0.027815, -0.020531,
        -0.008583, -0.062279, 0.248894, 0.054412, 0.052236, -0.035441,
        -0.004323, 0.027435, 0.229286, 0.218979, 0.067120, -0.158349,
        0.031152, -0.075126, 0.169002, 0.037227, 0.008232, 0.105537,
        -0.046501, -0.120791, 0.227068, 0.116739, 0.016985, 0.066339,
        -0.048243, -0.114355, 0.179282, -0.055390, 0.293953, 0.030753,
        -0.025301, 0.045346, 0.206892, 0.109160, 0.411746, 0.038588,
        -0.059811, 0.070063, 0.147817, 0.133954, 0.498419, 0.007827,
        -0.015470, -0.071177, -0.025425, -0.113688, 0.389220, -0.105132,
        -0.267013, 0.080781, 0.169593, 0.285028, -0.049975, 0.321147,
        -0.036127, -0.095849, 0.224600, 0.166978, 0.154305, 0.254504,
        -0.016685, -0.226226, 0.011712, 0.031142, 0.164798, 0.186808,
        -0.021545, -0.140246, -0.063119, 0.057846, 0.177640, 0.133689,
        -0.021267, -0.122071, -0.051818, 0.051322, 0.124688, 0.122184,
        0.011504, -0.107346, -0.061704, 0.057367, 0.068219, 0.096513,
        0.084084, -0.087442, -0.130373, -0.028590, 0.239223, 0.151693,
        0.044965, -0.092421, -0.116470, -0.008486, 0.150446, 0.117993,
        0.011245, -0.073531, -0.022776, 0.016147, 0.120436, 0.064897,
        0.000353, -0.030391, -0.004260, 0.022725, 0.132383, 0.064133,
    ]

    // Streaming STFT / WOLA buffers (`N = 256, hop = 128`).
    private var inputHistory = [[Double]](repeating: [Double](repeating: 0, count: fftSize - hopSize), count: channelCount)
    private var pendingInput = [[Double]](repeating: [], count: channelCount)
    private var olaBuffer = [Double](repeating: 0, count: fftSize)
    private var olaNorm = [Double](repeating: 0, count: fftSize)

    // 3-band own-voice detector state (600–1200, 1200–2400, 2400–4000 Hz; bins 10..<19, 19..<38, 38..<64).
    private var p0Smooth = 0.0
    private var floorPower = Double.greatestFiniteMagnitude
    private var bandP0 = [Double](repeating: 0, count: 3)
    private var bandPy = [Double](repeating: 0, count: 3)
    private var hangRemaining = 0

    /// Processes a 6-channel 16 kHz packet through the MVDR mouth-null beamformer and returns the beamformed 16 kHz
    /// mono samples along with `isOwnVoice` (true while the wearer is speaking, including a 120 ms hangover so
    /// `InterpreterGain` keeps its gain frozen across syllabic dips).
    mutating func beamform(_ channels: [[Int16]]) -> (samples: [Int16], isOwnVoice: Bool) {
        guard let first = channels.first, !first.isEmpty else { return ([], false) }
        let nChannels = min(channels.count, Self.channelCount)
        guard nChannels == Self.channelCount else { return (first, false) }
        let count = channels.prefix(Self.channelCount).map(\.count).min() ?? 0
        guard count > 0 else { return ([], false) }

        for c in 0..<Self.channelCount {
            let ch = channels[c]
            for i in 0..<count {
                pendingInput[c].append(Double(ch[i]) / 32_768.0)
            }
        }

        var out: [Int16] = []
        out.reserveCapacity(count)
        var ownVoiceActive = hangRemaining > 0

        var xRe = [[Double]](repeating: [Double](repeating: 0, count: Self.bins), count: Self.channelCount)
        var xIm = [[Double]](repeating: [Double](repeating: 0, count: Self.bins), count: Self.channelCount)
        var fftRe = [Double](repeating: 0, count: Self.fftSize)
        var fftIm = [Double](repeating: 0, count: Self.fftSize)

        var consumed = 0
        while pendingInput[0].count - consumed >= Self.hopSize {
            // 1. Forward 256-point windowed FFT for each of the 6 microphone channels.
            for c in 0..<Self.channelCount {
                let hist = inputHistory[c]
                let pend = pendingInput[c]
                for i in 0..<(Self.fftSize - Self.hopSize) {
                    fftRe[i] = hist[i] * Self.window[i]
                    fftIm[i] = 0
                }
                for i in 0..<Self.hopSize {
                    let idx = Self.fftSize - Self.hopSize + i
                    fftRe[idx] = pend[consumed + i] * Self.window[idx]
                    fftIm[idx] = 0
                }
                inputHistory[c] = Array(pend[consumed..<(consumed + Self.hopSize)])
                Self.fft(&fftRe, &fftIm, inverse: false)
                for k in 0..<Self.bins {
                    xRe[c][k] = fftRe[k]
                    xIm[c][k] = fftIm[k]
                }
            }
            consumed += Self.hopSize

            // 2. Apply MVDR mouth-null weights `y[k] = sum_c conj(W[k][c]) * X[c][k]` for bins 0...64; ch0 above 4 kHz.
            var yRe = [Double](repeating: 0, count: Self.bins)
            var yIm = [Double](repeating: 0, count: Self.bins)
            for k in 0..<Self.activeBins {
                let base = k * Self.channelCount
                var sumRe = 0.0
                var sumIm = 0.0
                for c in 0..<Self.channelCount {
                    let wr = Self.wRe[base + c]
                    let wi = Self.wIm[base + c]
                    let xr = xRe[c][k]
                    let xi = xIm[c][k]
                    // conj(wr + i*wi) * (xr + i*xi) = (wr*xr + wi*xi) + i*(wr*xi - wi*xr)
                    sumRe += wr * xr + wi * xi
                    sumIm += wr * xi - wi * xr
                }
                yRe[k] = sumRe
                yIm[k] = sumIm
            }
            for k in Self.activeBins..<Self.bins {
                yRe[k] = xRe[0][k]
                yIm[k] = xIm[0][k]
            }

            // 3. 3-band own-voice detector (600–1200, 1200–2400, 2400–4000 Hz) + broadband 300–4000 Hz SNR check.
            var p0Broad = 0.0
            for k in 5..<64 {
                p0Broad += xRe[0][k] * xRe[0][k] + xIm[0][k] * xIm[0][k]
            }
            let alpha = 0.75
            p0Smooth = alpha * p0Smooth + (1.0 - alpha) * p0Broad
            floorPower = min(max(floorPower * 1.0028, 1e-14), max(p0Smooth, 1e-14))
            let snrDB = 10.0 * log10(max(p0Smooth / floorPower, 1e-30))

            let bands = [(10, 19), (19, 38), (38, 64)]
            var ratioSumDB = 0.0
            for (bi, (lo, hi)) in bands.enumerated() {
                var b0 = 0.0
                var by = 0.0
                for k in lo..<hi {
                    b0 += xRe[0][k] * xRe[0][k] + xIm[0][k] * xIm[0][k]
                    by += yRe[k] * yRe[k] + yIm[k] * yIm[k]
                }
                bandP0[bi] = alpha * bandP0[bi] + (1.0 - alpha) * b0
                bandPy[bi] = alpha * bandPy[bi] + (1.0 - alpha) * by
                ratioSumDB += 10.0 * log10(max(bandPy[bi], 1e-30) / max(bandP0[bi], 1e-30))
            }
            let meanNullDB = ratioSumDB / 3.0
            if snrDB > 15.0 && meanNullDB < -7.0 {
                hangRemaining = Self.hangHops
                ownVoiceActive = true
            } else if hangRemaining > 0 {
                hangRemaining -= 1
                ownVoiceActive = true
            }

            // 4. Inverse 256-point FFT and WOLA synthesis for one 128-sample hop.
            for k in 0..<Self.bins {
                fftRe[k] = yRe[k]
                fftIm[k] = yIm[k]
            }
            for k in 1..<(Self.fftSize / 2) {
                fftRe[Self.fftSize - k] = yRe[k]
                fftIm[Self.fftSize - k] = -yIm[k]
            }
            Self.fft(&fftRe, &fftIm, inverse: true)
            for i in 0..<Self.fftSize {
                let w = Self.window[i]
                olaBuffer[i] += fftRe[i] * w
                olaNorm[i] += w * w
            }
            for i in 0..<Self.hopSize {
                let norm = olaNorm[i]
                let sample = norm > 1e-6 ? (olaBuffer[i] / norm) : 0.0
                let scaled = max(-32_768.0, min(32_767.0, (sample * 32_768.0).rounded()))
                out.append(Int16(scaled))
            }
            for i in 0..<(Self.fftSize - Self.hopSize) {
                olaBuffer[i] = olaBuffer[i + Self.hopSize]
                olaNorm[i] = olaNorm[i + Self.hopSize]
            }
            for i in (Self.fftSize - Self.hopSize)..<Self.fftSize {
                olaBuffer[i] = 0
                olaNorm[i] = 0
            }
        }
        if consumed > 0 {
            for c in 0..<Self.channelCount {
                pendingInput[c].removeFirst(consumed)
            }
        }
        return (out, ownVoiceActive)
    }

    private static func fft(_ re: inout [Double], _ im: inout [Double], inverse: Bool) {
        let n = fftSize
        for i in 0..<n {
            let j = bitRev[i]
            if j > i {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }
        var size = 2
        while size <= n {
            let half = size / 2
            let step = n / size
            var start = 0
            while start < n {
                var k = 0
                for j in start..<(start + half) {
                    let wr = cosTable[k]
                    let wi = inverse ? -sinTable[k] : sinTable[k]
                    let tr = re[j + half] * wr - im[j + half] * wi
                    let ti = re[j + half] * wi + im[j + half] * wr
                    re[j + half] = re[j] - tr
                    im[j + half] = im[j] - ti
                    re[j] += tr
                    im[j] += ti
                    k += step
                }
                start += size
            }
            size <<= 1
        }
        if inverse {
            let scale = 1.0 / Double(n)
            for i in 0..<n {
                re[i] *= scale
                im[i] *= scale
            }
        }
    }
}

/// The glasses' microphone made loud enough for the interpreter. Two uses:
/// - **The glasses' assistant microphone** (the held reply, up to `maxGainDB`): one channel tuned to the wearer's
///   mouth (firmware capture type 0: `16000, 1, 0x105`; their own live translation uses type 1, `16000, 6, 0x305`),
///   so a person a metre in front came in at −67 to −75 dB in tests. That's below `LiveTranscriber`'s speech
///   detector (−58 dB) and too quiet for ElevenLabs to hear more than a few words.
/// - **The six microphones, beamformed** (up to `outwardMicMaxGainDB`): the gain holds still while the own-voice
///   detector says the wearer is speaking (`freezeGain`).
///
/// Per 20 ms frame: a high-pass at 120 Hz (rumble would otherwise take the gain), then gain toward a peak of −3 dB,
/// quick to come down on a loud frame and slower to go back up, and a soft limiter (`tanh`).
struct InterpreterGain {
    static let maxGainDB = 50.0
    static let outwardMicMaxGainDB = 24.0
    private static let frame = 320
    private static let targetPeak = 0.7 * 32_768
    private static let envelopeDecay = exp(-0.02 / 1.0)
    private static let highPassAlpha: Double = {
        let rc = 1 / (2 * Double.pi * 120)
        let dt = 1.0 / 16_000
        return rc / (rc + dt)
    }()

    private let maxGain: Double
    private var previousIn = 0.0
    private var previousOut = 0.0
    private var envelope = 1.0
    private var gain = 1.0
    private var pending: [Double] = []

    init(maxGainDB: Double = InterpreterGain.maxGainDB) {
        self.maxGain = pow(10, maxGainDB / 20)
    }

    /// 16 kHz mono in, the same out (whole 20 ms frames; the remainder waits for the next call).
    /// When `freezeGain` is true (the 6-channel own-voice detector flagged the wearer speaking), the envelope and gain
    /// stay frozen so the wearer's louder voice doesn't duck the gain for the far-field speaker.
    mutating func process(_ samples: [Int16], freezeGain: Bool = false) -> [Int16] {
        for sample in samples {
            let x = Double(sample)
            previousOut = Self.highPassAlpha * (previousOut + x - previousIn)
            previousIn = x
            pending.append(previousOut)
        }
        var out: [Int16] = []
        out.reserveCapacity(pending.count)
        var start = 0
        while pending.count - start >= Self.frame {
            let frame = pending[start..<(start + Self.frame)]
            start += Self.frame
            if !freezeGain {
                let peak = frame.reduce(0) { max($0, abs($1)) }
                envelope = max(peak, envelope * Self.envelopeDecay, 8)
                let wanted = min(maxGain, Self.targetPeak / envelope)
                if wanted < gain {
                    gain = wanted
                } else if peak > 24 {
                    // Only ramp gain upward when there is signal above the digital noise floor.
                    gain += (wanted - gain) * 0.1
                }
            }
            for x in frame {
                out.append(Int16(32_767 * tanh(x * gain / 32_767)))
            }
        }
        pending.removeFirst(start)
        return out
    }
}
