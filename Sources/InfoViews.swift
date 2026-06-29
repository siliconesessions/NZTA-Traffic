import SwiftUI

// First-run onboarding shown once (gated by @AppStorage in ContentView).
struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    let onFinish: (_ enableAutoRefresh: Bool) -> Void
    @State private var enableAutoRefresh = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to NZTA Traffic")
                .font(.largeTitle.weight(.semibold))
            Text("Live New Zealand traffic — cameras, road events, VMS signs, travel times, and a map.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Label("Switch sections with the tabs or ⌘1–6.", systemImage: "square.grid.2x2")
                Label("Filter by region, highway (e.g. SH1), or search (⌘F). ⌘E clears filters.", systemImage: "line.3.horizontal.decrease.circle")
                Label("⌘R refreshes the data. Open Help (⌘?) any time.", systemImage: "arrow.clockwise")
            }
            .font(.callout)

            Toggle("Auto-refresh data while the app is open", isOn: $enableAutoRefresh)
                .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Get Started") {
                    onFinish(enableAutoRefresh)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 520)
    }
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AboutSection(title: "About This App") {
                    Text("NZTA Traffic is a native macOS app for monitoring live traffic cameras, road events, and Variable Message Signs across New Zealand. It is designed as a quiet desktop view of operational traffic information, with shared filters and a map view for spatial context.")
                }

                AboutSection(title: "What It Shows") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("Traffic camera thumbnails and full-size camera previews.")
                        BulletText("Road events, including closures, delays, location details, comments, routes, dates, and available metadata.")
                        BulletText("Variable Message Sign content, including travel-time messages and signs that currently have no displayed message.")
                        BulletText("A switchable map layer for cameras, road events, and VMS signs.")
                    }
                }

                AboutSection(title: "Data Sources") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("Traffic Cameras: trafficnz.info/service/traffic/rest/4/cameras/all")
                        BulletText("Road Events: trafficnz.info/service/traffic/rest/4/events/all/10")
                        BulletText("VMS Signs: trafficnz.info/service/traffic/rest/4/signs/vms/all")
                    }
                }

                AboutSection(title: "Updates and Privacy") {
                    Text("The app fetches live data directly with URLSession and refreshes only when you open the app, press Refresh, or enable auto-refresh. It does not collect analytics, create user accounts, or send personal data to an app backend. Map display uses Apple MapKit.")
                }

                AboutSection(title: "Data Notes") {
                    Text("Traffic information can lag behind roadside conditions, camera images can be temporarily unavailable, and some map positions are approximate when the source feed provides line geometry instead of a single point. Use official road signage and instructions when travelling.")
                }

                AboutSection(title: "Attribution") {
                    Text("Traffic and travel information is provided by Waka Kotahi NZ Transport Agency and participating regional councils. This app is an independent viewer for that public data.")
                }

                AboutSection(title: "Help") {
                    Text("Open Help > NZTA Traffic Help from the macOS menu bar for detailed guidance on filters, tabs, map layers, refresh behavior, and troubleshooting.")
                }
            }
            .font(.body)
            .foregroundStyle(.primary)
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}

struct AppHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NZTA Traffic Help")
                        .font(.largeTitle.weight(.semibold))
                    Text("A guide to using the macOS traffic viewer for cameras, road events, VMS signs, and map layers.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                AboutSection(title: "Purpose") {
                    Text("NZTA Traffic is an information viewer for live traffic data. It is not a navigation system or official travel instruction source. Always follow current road signs, authority instructions, and the conditions in front of you.")
                }

                AboutSection(title: "Shared Controls") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("Region limits cameras, road events, VMS signs, and map layers to the selected region.")
                        BulletText("Highway searches route, journey, way, and location fields such as SH1 or SH16.")
                        BulletText("Search matches names, locations, descriptions, event comments, regions, and VMS message text where available.")
                        BulletText("Refresh reloads all live data sources and refreshes camera image cache tokens.")
                        BulletText("Auto-refresh reloads data every 30 to 600 seconds while enabled.")
                    }
                }

                AboutSection(title: "Traffic Cameras") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("The camera tab shows thumbnails, names, region, route or direction metadata, and offline or maintenance status.")
                        BulletText("Click a camera card, or a camera pin on the map, to open the full-size camera preview.")
                        BulletText("If an image is unavailable, the source camera may be offline, under maintenance, slow to update, or temporarily unavailable.")
                    }
                }

                AboutSection(title: "Road Events") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("Events are sorted by severity so closures and delays appear before lower-impact items.")
                        BulletText("Event cards can include location, impact, comments, alternative routes, dates, source, supplier, and status metadata.")
                        BulletText("Map event pins use red for closures, orange for delays, yellow for caution, and gray for other or unknown impact.")
                        BulletText("Some map positions are approximate because the source feed can provide line geometry rather than a single point.")
                    }
                }

                AboutSection(title: "VMS Signs") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("VMS cards show the current sign message and the source update time when supplied.")
                        BulletText("Message formatting tokens are cleaned up before display, so travel-time rows show readable destinations and values.")
                        BulletText("Signs with no active message display as No message.")
                        BulletText("On the map, blue VMS pins have an active message and gray VMS pins have no active message.")
                    }
                }

                AboutSection(title: "Map") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("Use the map layer control to switch between Cameras, Road Events, and VMS Signs.")
                        BulletText("The shared Region, Highway, and Search filters apply to the active map layer.")
                        BulletText("Mapped shows the number of filtered items with usable coordinates.")
                        BulletText("Without coordinates shows filtered items that cannot be placed on the map.")
                        BulletText("Reset Map returns the map to the initial New Zealand view.")
                    }
                }

                AboutSection(title: "Troubleshooting") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("If a section is empty, clear filters first, then press Refresh.")
                        BulletText("If a section shows an error banner, that live source failed while other loaded sections may still be usable.")
                        BulletText("If a camera preview is stale or missing, press Refresh and check whether the camera is marked offline or maintenance.")
                        BulletText("If a road event is not mapped, the live event may not include usable geometry or coordinates.")
                        BulletText("If macOS blocks the app on first launch, Control-click the app, choose Open, and confirm the prompt.")
                    }
                }

                AboutSection(title: "Data and Privacy") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("Traffic data is requested directly from the NZTA Traffic and Travel REST API v4.")
                        BulletText("The map uses Apple MapKit.")
                        BulletText("The app does not include analytics, accounts, tracking, or an app-specific backend.")
                        BulletText("Last Updated means the app completed a refresh. It does not mean every source item changed at that time.")
                    }
                }
            }
            .font(.body)
            .foregroundStyle(.primary)
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .frame(minWidth: 640, minHeight: 520)
    }
}

struct AboutSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.title3.weight(.semibold))
            content
                .foregroundStyle(.secondary)
                .lineSpacing(3)
        }
    }
}

struct BulletText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .frame(width: 5, height: 5)
                .foregroundStyle(.secondary)
            Text(text)
        }
    }
}

