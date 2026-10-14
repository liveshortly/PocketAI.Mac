import PocketUI
import SwiftUI

/// 02-design-system.md §6.2: `Settings` scene (⌘,) with tabs General,
/// Models, Server, Devices, Agents, Privacy. Tab bodies are placeholders
/// until their owning L6 cards land - this proves the scene itself and
/// its keyboard shortcut exist.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Text("General").tabItem { Label("General", systemImage: "gearshape") }
            Text("Models").tabItem { Label("Models", systemImage: "cpu") }
            Text("Server").tabItem { Label("Server", systemImage: "server.rack") }
            Text("Devices").tabItem { Label("Devices", systemImage: "iphone") }
            Text("Agents").tabItem { Label("Agents", systemImage: "wand.and.stars") }
            Text("Privacy").tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 480, height: 320)
        .font(.pocket(.body))
    }
}
