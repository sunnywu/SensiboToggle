import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: ACController
    
    var body: some View {
        NavigationView {
            Group {
                if !controller.isReady && controller.error == nil {
                    ProgressView("Loading devices...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = controller.error {
                    Text("Error: \(error)")
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(controller.acs) { ac in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: ac.symbol)
                                    .foregroundColor(ac.on ? .orange : .blue)
                                Text(ac.displayName)
                                    .font(.headline)
                                
                                Spacer()
                                
                                if let temp = ac.temperature {
                                    Text("\(Int(temp))°")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("-")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            // Toggle switch
                            HStack {
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { ac.on },
                                    set: { _ in self.controller.toggle(ac.id) }
                                ))
                                .labelsHidden()
                                .tint(ac.on ? .orange : .blue)
                                .accessibilityIdentifier("toggle.\(ac.id)")
                                .disabled(self.controller.pending.contains(ac.id))
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .listStyle(PlainListStyle())
                }
            }
            .navigationTitle("Sensibo")
        }
        .task {
            if !self.controller.isReady {
                _ = await self.controller.load()
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        let controller = ACController(client: MockSensiboClient(seed: []))
        return ContentView(controller: controller)
    }
}
