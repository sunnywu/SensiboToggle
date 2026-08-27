import SwiftUI

/// View component that displays the current AC state with loading indicators.
public struct ACStateDisplay: View {
    let ac: AirCon
    let isLoading: Bool
    
    public init(ac: AirCon, isLoading: Bool = false) {
        self.ac = ac
        self.isLoading = isLoading
    }
    
    public var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(ac.displayName)
                    .font(.headline)
                    .lineLimit(1)
                
                if let room = ac.room {
                    Text(room)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 20, height: 20)
                } else {
                    HStack {
                        Image(systemName: ac.symbol)
                            .foregroundColor(ac.on ? .orange : .blue)
                        Text(ac.temperatureDisplay)
                            .font(.subheadline)
                    }
                }
            }
            
            Spacer()
            
            // Show current on/off state in a toggle
            Image(systemName: ac.symbol)
                .foregroundColor(ac.on ? .orange : .blue)
        }
        .padding(.vertical, 8)
    }
}

struct ACStateDisplay_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ACStateDisplay(ac: AirCon(id: "test1", name: "Living Room", room: "Living Room", on: true, temperature: 22.0))
                .previewDisplayName("On with Temperature")
            
            ACStateDisplay(ac: AirCon(id: "test2", name: "Bedroom", room: "Bedroom", on: false, temperature: nil))
                .previewDisplayName("Off")
            
            ACStateDisplay(ac: AirCon(id: "test3", name: "", room: "Kitchen", on: true, temperature: 24.0), isLoading: true)
                .previewDisplayName("Loading")
        }
        .padding()
    }
}