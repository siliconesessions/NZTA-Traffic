import SwiftUI

// First-run onboarding shown once (gated by @AppStorage in ContentView).
struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    let onFinish: (_ enableAutoRefresh: Bool) -> Void
    @State private var enableAutoRefresh = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to NZ Traffic")
                .font(.largeTitle.weight(.semibold))
            Text("Live New Zealand traffic — cameras, road events, VMS signs, travel times, and a map.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Label("Switch sections in the sidebar or with ⌘1–6.", systemImage: "square.grid.2x2")
                Label("Filter by region, highway (e.g. SH1), or search (⌘F) in the toolbar. ⌘E clears filters.", systemImage: "line.3.horizontal.decrease.circle")
                Label("⌘R refreshes the data. Open Help (⌘?) any time.", systemImage: "arrow.clockwise")
            }
            .font(.callout)

            Toggle("Refresh data automatically (every 2 minutes — change it in Settings)", isOn: $enableAutoRefresh)
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
                    Text("NZ Traffic is a native macOS app for monitoring live traffic cameras, road events, and Variable Message Signs across New Zealand. It is designed as a quiet desktop view of operational traffic information, with shared filters and a map view for spatial context.")
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
                        BulletText("Traffic Cameras: trafficnz.info/service/traffic/rest/5/cameras/all")
                        BulletText("Road Events: trafficnz.info/service/traffic/rest/5/events/all/10")
                        BulletText("VMS Signs: trafficnz.info/service/traffic/rest/5/signs/vms/all")
                    }
                }

                AboutSection(title: "Updates and Privacy") {
                    Text("The app fetches live data directly with URLSession and refreshes only when you open the app, press Refresh, or enable auto-refresh. It does not collect analytics, create user accounts, or send personal data to an app backend. Map display uses Apple MapKit.")
                }

                AboutSection(title: "Data Notes") {
                    Text("Traffic information can lag behind roadside conditions, camera images can be temporarily unavailable, and some map positions are approximate when the source feed provides line geometry instead of a single point. Use official road signage and instructions when travelling.")
                }

                AboutSection(title: "Attribution") {
                    Text("Traffic and travel information is provided by NZ Transport Agency Waka Kotahi (NZTA) and participating regional councils, under CC BY 4.0. NZ Traffic is an independent viewer for that public data and is not affiliated with or endorsed by NZTA.")
                }

                AboutSection(title: "Help") {
                    Text("Open Help > NZ Traffic Help from the macOS menu bar for detailed guidance on filters, tabs, map layers, refresh behavior, and troubleshooting.")
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
                    Text("NZ Traffic Help")
                        .font(.largeTitle.weight(.semibold))
                    Text("A guide to using the macOS traffic viewer for cameras, road events, VMS signs, and map layers.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                AboutSection(title: "Purpose") {
                    Text("NZ Traffic is an information viewer for live traffic data. It is not a navigation system or official travel instruction source. Always follow current road signs, authority instructions, and the conditions in front of you.")
                }

                AboutSection(title: "Shared Controls") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("Region, Highway, Search, Clear Filters, Refresh and Auto-refresh are in the toolbar; the toolbar's middle says when the data last updated. The sidebar shows how many items each section has.")
                        BulletText("Region limits cameras, road events, VMS signs, travel times, and every map layer to the selected region. EV chargers are placed in a region by their location; the Auckland congestion layer only has Auckland motorways.")
                        BulletText("Highway matches whole state highways: SH1, SH 1, State Highway 1, 01N and 1 all mean State Highway 1 — not SH10–SH18 or spurs such as SH1B (type SH1B for those). Items at a junction match both highways. Other text, such as CNC, matches whole words in route names.")
                        BulletText("Search matches names, locations, descriptions, event comments, regions, and VMS message text where available. Macrons are optional: otaki finds Ōtaki.")
                        BulletText("Each tab's own chips (camera status, event impact, flow) count as filters too: the Clear Filters button turns orange and its tooltip lists what they hide, and it (⌘E) resets them along with Region, Highway and Search.")
                        BulletText("Refresh (⌘R) reloads every live source and fetches fresh camera images. Each section updates as soon as its data arrives; Travel Times takes NZTA 15–20 seconds, so it finishes on its own.")
                        BulletText("Auto-refresh reloads everything, including the camera images on screen, every 1 to 10 minutes. It keeps going with the window closed, so the menu bar and Dock badge stay current, and slows down (to at most every 15 minutes) while NZ Traffic is in the background with no window showing.")
                    }
                }

                AboutSection(title: "Traffic Cameras") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("The camera tab shows each camera's latest image, name, region, route or direction metadata, and offline or maintenance status. If the latest image can't load, an older still from NZTA may be shown instead, marked Not live.")
                        BulletText("Click a camera card, or a camera pin on the map, to open the full-size camera preview.")
                        BulletText("If an image is unavailable, the source camera may be offline, under maintenance, slow to update, or temporarily unavailable.")
                    }
                }

                AboutSection(title: "Road Events") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("Events in force now are listed first, by severity (closures, then delays, caution and other), followed by Upcoming (scheduled) events.")
                        BulletText("Resolved events stay in the NZTA feed for about a day. They are hidden unless you turn on Resolved in the Road Events filter bar or in Settings.")
                        BulletText("The Dock badge and the menu bar count active road closures only — not upcoming or resolved ones. A “?” after the Dock count means it comes from saved data rather than the latest fetch.")
                        BulletText("Event cards can include location, impact, comments, alternative routes, restrictions, dates, source, and status metadata.")
                        BulletText("Map event pins use red for active closures, orange for delays, yellow for caution, purple for upcoming events, and gray for other impacts or resolved events.")
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
                        BulletText("Use the map layer control to switch between Cameras, Road Events, VMS Signs, traffic Flow, travel time (TIM) signs, EV chargers and Auckland Congestion (Congestion). The layer's own filters sit in the row underneath.")
                        BulletText("The shared Region, Highway, and Search filters apply to every map layer.")
                        BulletText("Flow colours each journey leg by its own traffic, and the flow chips filter leg by leg. The two directions of a road are drawn side by side, and slower traffic is always drawn on top.")
                        BulletText("Grouped pins show how many items they hold, ringed in the colour of the most notable one — an events group is red only when it contains a closure. Click a group to zoom in.")
                        BulletText("Gray travel time sign pins are blank right now; Hide blank boards leaves them off the map.")
                        BulletText("Mapped shows the number of filtered items with usable coordinates.")
                        BulletText("Off-map shows filtered items that cannot be placed on the map.")
                        BulletText("Reset Map returns the map to the initial New Zealand view.")
                    }
                }

                AboutSection(title: "Troubleshooting") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("If a section is empty, clear filters first, then press Refresh.")
                        BulletText("If a section shows an error banner, that live source failed while other loaded sections may still be usable.")
                        BulletText("When NZTA can’t be reached, or the Mac is offline, the app shows the data it saved last time and says how old it is. It reloads by itself when the connection comes back.")
                        BulletText("If saved data looks wrong, choose Clear Offline Cache in Settings or the Help menu to delete it and reload.")
                        BulletText("If a camera preview is stale or missing, press Refresh and check whether the camera is marked offline or maintenance.")
                        BulletText("If a road event is not mapped, the live event may not include usable geometry or coordinates.")
                        BulletText("If macOS blocks the app on first launch, Control-click the app, choose Open, and confirm the prompt.")
                    }
                }

                AboutSection(title: "Data and Privacy") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("Traffic data is requested directly from the NZTA Traffic and Travel REST API v5, falling back to the documented v4 if v5 stops answering.")
                        BulletText("The map uses Apple MapKit.")
                        BulletText("The app does not include analytics, accounts, tracking, or an app-specific backend.")
                        BulletText("Updated shows when data last arrived from NZTA. It doesn’t move while fetches are failing, and turns orange after 10 minutes. It does not mean every source item changed at that time.")
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

