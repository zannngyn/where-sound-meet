import WhereSoundMeetCore
import SwiftUI

/// "fx" button in a source card header; opens the effect chain editor.
struct EffectsButton: View {
    @Binding var effects: EffectSettings
    let sourceName: String
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: "slider.horizontal.3")
                Text(effects.anyEnabled ? "fx \(effects.enabledCount)" : "fx").font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(effects.anyEnabled ? Theme.teal : Color(white: 0.9), in: Capsule())
            .foregroundStyle(effects.anyEnabled ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Effects for \(sourceName)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            EffectsPopover(effects: $effects, sourceName: sourceName)
        }
    }
}

struct EffectsPopover: View {
    @Binding var effects: EffectSettings
    let sourceName: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Effects · \(sourceName)").font(.headline)
                    Spacer()
                    Button("Reset All") { effects = EffectSettings() }.disabled(!effects.anyEnabled && effects == EffectSettings())
                }
                Text("Signal flows top to bottom.").font(.caption).foregroundStyle(Theme.textSecondary)

                section("High Pass", $effects.highPass.enabled) {
                    param("Cutoff", $effects.highPass.cutoff, 10...2000, "Hz", log: true)
                }
                section("Low Pass", $effects.lowPass.enabled) {
                    param("Cutoff", $effects.lowPass.cutoff, 1000...20000, "Hz", log: true)
                }
                section("Noise Gate", $effects.gate.enabled) {
                    param("Threshold", $effects.gate.threshold, -80...0, "dB")
                    param("Ratio", $effects.gate.ratio, 1...50, ":1")
                }
                section("10-Band EQ", $effects.eq.enabled) {
                    EQView(eq: $effects.eq)
                }
                section("Compressor", $effects.compressor.enabled) {
                    param("Threshold", $effects.compressor.threshold, -40...20, "dB")
                    param("Head Room", $effects.compressor.headRoom, 0.1...40, "dB")
                    param("Attack", $effects.compressor.attack, 0.0001...0.2, "s", decimals: 3)
                    param("Release", $effects.compressor.release, 0.01...3, "s", decimals: 2)
                    param("Make-up Gain", $effects.compressor.makeupGain, -40...40, "dB")
                }
                section("Echo", $effects.echo.enabled) {
                    param("Time", $effects.echo.time, 0...2, "s", decimals: 2)
                    param("Feedback", $effects.echo.feedback, -100...100, "%")
                    param("Mix", $effects.echo.mix, 0...100, "%")
                }
                section("Reverb", $effects.reverb.enabled) {
                    Picker("Room", selection: $effects.reverb.room) {
                        ForEach(ReverbSettings.Room.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    param("Mix", $effects.reverb.mix, 0...100, "%")
                }
                section("Limiter", $effects.limiter.enabled) {
                    param("Pre-Gain", $effects.limiter.preGain, -40...40, "dB")
                }
            }
            .padding(16)
        }
        .frame(width: 380, height: 560)
    }

    private func section<C: View>(_ title: String, _ enabled: Binding<Bool>, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: enabled) { Text(title).font(.subheadline.weight(.semibold)) }
                .toggleStyle(.switch).tint(Theme.teal)
            if enabled.wrappedValue {
                content().padding(.leading, 4)
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.cardBorder))
    }

    private func param(_ label: String, _ value: Binding<Float>, _ range: ClosedRange<Float>, _ unit: String,
                       log: Bool = false, decimals: Int = 0) -> some View {
        HStack {
            Text(label).font(.callout).frame(width: 96, alignment: .leading)
            if log {
                Slider(value: Binding(get: { Double(log2(value.wrappedValue)) },
                                      set: { value.wrappedValue = Float(pow(2, $0)) }),
                       in: Double(log2(range.lowerBound))...Double(log2(range.upperBound)))
            } else {
                Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Float($0) }),
                       in: Double(range.lowerBound)...Double(range.upperBound))
            }
            Text(String(format: "%.\(decimals)f %@", value.wrappedValue, unit))
                .font(.callout).monospacedDigit().frame(width: 72, alignment: .trailing)
        }
        .tint(Theme.teal)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

struct EQView: View {
    @Binding var eq: EQSettings

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Preset").font(.callout)
                Picker("Preset", selection: Binding<EQSettings.Preset?>(
                    get: { EQSettings.Preset.allCases.first { $0.gains == eq.gains } },
                    set: { if let p = $0 { eq.gains = p.gains } })) {
                    Text("Custom").tag(EQSettings.Preset?.none)
                    ForEach(EQSettings.Preset.allCases, id: \.self) { Text($0.rawValue).tag(EQSettings.Preset?.some($0)) }
                }
                .labelsHidden()
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<10, id: \.self) { i in
                    VStack(spacing: 2) {
                        Text(String(format: "%+.0f", eq.gains[i])).font(.system(size: 9)).monospacedDigit()
                        Slider(value: Binding(get: { Double(eq.gains[i]) }, set: { eq.gains[i] = Float($0) }), in: -12...12)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 24, height: 110)
                            .accessibilityLabel("\(bandLabel(i)) gain")
                        Text(bandLabel(i)).font(.system(size: 9))
                    }
                }
            }
            .tint(Theme.teal)
        }
    }

    private func bandLabel(_ i: Int) -> String {
        let f = EQSettings.frequencies[i]
        return f >= 1000 ? String(format: "%.0fk", f / 1000) : String(format: "%.0f", f)
    }
}
