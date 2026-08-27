import SwiftUI

/// Toggle component that implements optimistic UI updates for immediate user feedback.
public struct OptimisticToggle: View {
    let ac: AirCon
    let onToggle: (Bool) async -> Void
    @State private var isAnimating = false
    
    public init(ac: AirCon, onToggle: @escaping (Bool) async -> Void) {
        self.ac = ac
        self.onToggle = onToggle
    }
    
    public var body: some View {
        Toggle(isOn: Binding<Bool>(get: { ac.on }, set: { newValue in
            // Optimistic update - immediate UI feedback
            Task {
                await onToggle(newValue)
            }
        })) {
            Image(systemName: ac.symbol)
                .foregroundColor(ac.on ? .orange : .blue)
                .scaleEffect(isAnimating ? 1.2 : 1.0)
                .animation(.easeInOut(duration: 0.2), value: isAnimating)
        }
        .toggleStyle(SwitchToggleStyle(tint: .orange))
        .onTapGesture {
            withAnimation {
                isAnimating = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    isAnimating = false
                }
            }
        }
    }
}

struct OptimisticToggle_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            OptimisticToggle(ac: AirCon(id: "test1", name: "Living Room", room: "Living Room", on: true, temperature: 22.0)) { _ in }
                .previewDisplayName("On")
            
            OptimisticToggle(ac: AirCon(id: "test2", name: "Bedroom", room: "Bedroom", on: false, temperature: nil)) { _ in }
                .previewDisplayName("Off")
        }
        .padding()
    }
}