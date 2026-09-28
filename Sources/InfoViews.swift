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
                    Text("NZ Traffic is a native macOS app for live New Zealand traffic information: traffic cameras, road events, Variable Message Signs (VMS), travel times and a map. It is designed as a quiet desktop view of operational traffic data, with shared filters, a menu bar summary and a Dock badge for active road closures.")
                }
                whatItShows
                AboutSection(title: "Data Sources") {
                    DataSourcesList()
                }
                AboutSection(title: "Updates and Privacy") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("NZ Traffic fetches data directly from the hosts above with URLSession when it starts, when you press Refresh (in the toolbar or the menu bar), and on the auto-refresh schedule if it's turned on. Camera images come from trafficnz.info, and the map uses Apple MapKit.")
                        BulletText(AppCredits.offlineCacheNote)
                        BulletText("Your settings and watchlist are kept in the app's preferences on this Mac. There are no analytics, accounts, tracking or app backend, and nothing about you is sent anywhere.")
                    }
                }
                AboutSection(title: "Data Notes") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText(AppCredits.notableEventsNotice)
                        BulletText("Traffic information can lag behind roadside conditions, camera images can be temporarily unavailable, and some map positions are approximate when a feed gives a line rather than a single point. Always follow official road signs and instructions when travelling.")
                    }
                }
                attribution
                AboutSection(title: "Help") {
                    Text("Choose Help › NZ Traffic Help (⌘?) for guidance on filters, each section, map layers, the watchlist, refresh behaviour, keyboard shortcuts and troubleshooting.")
                }
            }
            .font(.body)
            .foregroundStyle(.primary)
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    private var whatItShows: some View {
        AboutSection(title: "What It Shows") {
            VStack(alignment: .leading, spacing: 8) {
                BulletText("Traffic Cameras: the latest image from each camera, with a full-size preview.")
                BulletText("Road Events: closures, delays and caution notices in force now, then upcoming ones, with location, comments, detours, restrictions and dates.")
                BulletText("VMS Signs: what the roadside electronic message signs are showing.")
                BulletText("Travel Times: NZTA's highway journeys (travel time, free-flow time and delay per direction), the roadside travel time boards, and Auckland motorway congestion.")
                BulletText("Map: cameras, road events, VMS signs, traffic flow, travel time signs, EV chargers and Auckland congestion, one layer at a time.")
                BulletText("A watchlist of highways, cameras and journeys, with optional notifications about new closures on watched roads.")
            }
        }
    }

    private var attribution: some View {
        AboutSection(title: "Attribution and Licences") {
            VStack(alignment: .leading, spacing: 8) {
                BulletText(AppCredits.attribution)
                BulletText(AppCredits.evAttribution)
                BulletText(AppCredits.notAffiliated)
                HStack(spacing: 16) {
                    if let licence = URL(string: AppCredits.licenceURL) {
                        Link("CC BY 4.0 licence", destination: licence)
                    }
                    if let terms = URL(string: AppCredits.termsURL) {
                        Link("NZTA data terms of use", destination: terms)
                    }
                    if let project = URL(string: AppIdentity.projectURL) {
                        Link("Project on GitHub", destination: project)
                    }
                }
                .font(.callout)
            }
        }
    }
}

// Every feed the app reads, generated from TrafficAPIService so it can't
// drift from the requests: "Road events — trafficnz.info/… (JSON)".
struct DataSourcesList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(TrafficAPIService.dataSources, id: \.self) { source in
                BulletText("\(source.title): \(source.displayURL) (\(source.format))")
            }
            BulletText("If an NZTA traffic address stops answering on REST v5, NZ Traffic tries the documented REST v4 instead.")
        }
        .textSelection(.enabled)
    }
}

// The macOS 15+ Gatekeeper steps for the ad-hoc signed download.
struct GatekeeperSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(AppCredits.gatekeeperSteps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                    Text(step)
                }
            }
            Text("Or, in Terminal: \(AppCredits.quarantineCommand)")
                .textSelection(.enabled)
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
                    Text("A guide to the traffic cameras, road events, VMS signs, travel times and map in NZ Traffic.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                AboutSection(title: "Purpose") {
                    Text("NZ Traffic is an information viewer for live traffic data. It is not a navigation system or an official source of travel instructions. Always follow current road signs, authority instructions, and the conditions in front of you.")
                }

                sharedControls
                cameraSection
                eventSection
                watchlistSection
                travelTimeSection
                vmsSection
                mapSection
                menuBarSection
                keyboardSection
                troubleshootingSection
                privacySection
            }
            .font(.body)
            .foregroundStyle(.primary)
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .frame(minWidth: 640, minHeight: 520)
    }

    private var sharedControls: some View {
        AboutSection(title: "Shared Controls") {
            VStack(alignment: .leading, spacing: 8) {
                BulletText("Region, Highway, Search, Clear Filters, Refresh and Auto-refresh are in the toolbar; the toolbar's middle says when the data last updated. The sidebar shows how many items each section has.")
                BulletText("Region limits cameras, road events, VMS signs, travel times, and every map layer to the selected region. EV chargers are placed in a region by their location; the Auckland congestion layer only has Auckland motorways.")
                BulletText("Highway matches whole state highways: SH1, SH 1, State Highway 1, 01N and 1 all mean State Highway 1 — not SH10–SH18 or spurs such as SH1B (type SH1B for those). Items at a junction match both highways. Other text, such as CNC, matches whole words in route names.")
                BulletText("Search matches names, locations, descriptions, event comments, regions, and VMS message text where available. Macrons and apostrophes are optional: otaki finds Ōtaki and hawkes bay finds Hawke’s Bay.")
                BulletText("Each tab's own chips (camera status, event impact, flow) count as filters too: the Clear Filters button turns orange and its tooltip lists what they hide, and it (⌘E) resets them along with Region, Highway and Search.")
                BulletText("Refresh (⌘R) reloads every live source and fetches fresh camera images. Each section updates as soon as its data arrives; Travel Times takes NZTA 15–20 seconds, so it finishes on its own. A section whose source fails shows an error banner with Retry.")
                BulletText("Auto-refresh reloads everything, including the camera images on screen, every 1 to 10 minutes (set it in the toolbar's Auto-refresh menu or in Settings, ⌘,). It keeps going with the window closed, so the menu bar and Dock badge stay current, and slows down (to at most every 15 minutes) while NZ Traffic is in the background with no window showing.")
            }
        }
    }

    private var cameraSection: some View {
        AboutSection(title: "Traffic Cameras") {
            VStack(alignment: .leading, spacing: 8) {
                BulletText("The camera tab shows each camera's latest image, name, region, route or direction, and offline or maintenance status. If the latest image can't load, an older still from NZTA may be shown instead, marked Not live.")
                BulletText("Click a camera card, or a camera pin on the map, to open the larger preview; Open full image opens the image in your browser.")
                BulletText("If an image is unavailable, the camera may be offline, under maintenance, slow to update, or temporarily unavailable.")
            }
        }
    }

    private var eventSection: some View {
        AboutSection(title: "Road Events") {
            VStack(alignment: .leading, spacing: 8) {
                BulletText(AppCredits.notableEventsNotice)
                BulletText("Events in force now are listed first, by severity (closures, then delays, caution and other), followed by Upcoming (scheduled) events.")
                BulletText("Resolved events stay in the NZTA feed for about a day. They are hidden unless you turn on Resolved in the Road Events filter bar or Show resolved road events in Settings.")
                BulletText("Event cards can include direction, location, impact, comments, alternative routes, restrictions, dates, and status.")
                BulletText("Map event pins are red for active closures, orange for delays, yellow for caution, purple for upcoming events, and grey for other impacts or resolved events, each with its own glyph.")
                BulletText("With VoiceOver, the Closures and Delays rotors jump between the closures and delays in force now.")
            }
        }
    }

    private var watchlistSection: some View {
        AboutSection(title: "Watchlist and Notifications") {
            VStack(alignment: .leading, spacing: 8) {
                BulletText("Click the star on a camera or journey card to watch it. Control-click a camera, event or journey card to watch (or stop watching) the highways it's on. Settings lists everything you watch, and you can add a highway there.")
                BulletText("Watching a highway covers every camera, road event and journey on it, whichever way the feeds write it (SH1, State Highway 1, 01N).")
                BulletText("The Watching chip in the Cameras, Road Events and Travel Times filter bars shows only what you watch. Events on watched roads are marked Watching, and the menu bar counts the active closures on them.")
                BulletText("Turn on “Notify me about new closures on watched roads” in Settings to get a notification when a new road closure appears on a watched highway or journey. It's checked after every refresh, with the window open or closed; closures already in force when NZ Traffic starts aren't announced. Click a notification to open Road Events.")
            }
        }
    }

    private var travelTimeSection: some View {
        AboutSection(title: "Travel Times") {
            VStack(alignment: .leading, spacing: 8) {
                BulletText("Journeys shows NZTA's highway journeys, one line per direction (labelled by where it runs from and to) with its travel time, free-flow time and delay. The flow chips (Free Flow to No Data) filter by how busy the road is.")
                BulletText("Boards shows the roadside travel time signs as they read now, grouped by region. A line such as “VIA SH20 R12” above the times is the route the times are for. Boards showing nothing are listed separately under blank boards.")
                BulletText("At the top of Journeys, Auckland Motorways (click to expand) lists the Auckland congestion feed as text, motorway by motorway.")
            }
        }
    }

    private var vmsSection: some View {
        AboutSection(title: "VMS Signs") {
            VStack(alignment: .leading, spacing: 8) {
                BulletText("VMS cards show the sign's current message and, when supplied, when it was last updated.")
                BulletText("The feeds' display-control codes are cleaned up before display, so travel time rows show readable destinations and times.")
                BulletText("Signs with no active message are hidden by default; turn off “Hide signs with no active message” in the VMS filter bar, or the matching setting in Settings, to show them.")
                BulletText("On the map, blue VMS pins have an active message and grey pins have none.")
            }
        }
    }

    private var mapSection: some View {
        AboutSection(title: "Map") {
            VStack(alignment: .leading, spacing: 8) {
                BulletText("The layer control switches between Cameras, Events (road events), VMS, Flow (journey traffic flow), TIM (travel time signs), EV (EV chargers) and Congestion (Auckland motorways). The layer's own filters sit in the row underneath, and the legend explains its colours and glyphs.")
                BulletText("The shared Region, Highway and Search filters apply to every map layer.")
                BulletText("Flow colours each journey leg by its own traffic, and the flow chips filter leg by leg. The two directions of a road are drawn side by side, and slower traffic is always drawn on top.")
                BulletText("Every pin has a glyph as well as a colour: closures, delays, caution, upcoming and resolved events, and online, offline and maintenance cameras each have their own. With Differentiate Without Colour on, Flow and Congestion lines are also drawn wider and more solid the worse the traffic.")
                BulletText("Pins that would overlap are grouped at every zoom. A group shows how many items it holds, ringed in the colour (and marked with the glyph) of the most notable one — an events group is red only when it contains a closure. Click a group to zoom in; items at the same spot are listed to choose from instead. Control-click a group to list its items at any zoom.")
                BulletText("Grey travel time sign pins are blank right now; Hide blank boards leaves them off the map.")
                BulletText("EV charger pins are purple for DC fast charging and teal for AC, counting only connectors that may be working. A grey pin with a crossed-out bolt is out of service: none of its connectors is reported working and at least one is reported down. Chargers whose status isn't reported are shown normally, marked Status not reported.")
                BulletText("“N mapped” counts the filtered items that have a position; “N off-map” counts those that can't be placed (the feed gave no usable coordinates). Some positions are approximate when a feed gives a line rather than a point.")
                BulletText("The viewfinder button zooms to the layer's filtered results; the scope button (Show All of New Zealand) returns to the whole country.")
            }
        }
    }

    private var menuBarSection: some View {
        AboutSection(title: "Menu Bar and Dock") {
            VStack(alignment: .leading, spacing: 8) {
                BulletText("The car icon in the menu bar shows camera, road event, VMS and journey counts, active closures (and those on roads you watch), and when the data last updated. It has Refresh Now, Open NZ Traffic and Quit.")
                BulletText("Closing the window doesn't quit NZ Traffic: it keeps refreshing in the menu bar. Reopen the window from the menu bar, the Dock or the Window menu.")
                BulletText("The Dock badge counts active road closures only — not upcoming or resolved ones. A “?” after the count, or “(saved data)” in the menu bar, means it comes from saved data rather than the latest fetch.")
            }
        }
    }

    private var keyboardSection: some View {
        AboutSection(title: "Keyboard Shortcuts") {
            VStack(alignment: .leading, spacing: 8) {
                BulletText("⌘1 to ⌘6: Traffic Cameras, Road Events, VMS Signs, Travel Times, Map, About.")
                BulletText("⌘F: search. ⌘E: clear all filters. ⌘R: refresh now.")
                BulletText("⌘,: Settings. ⌘?: this Help window.")
                BulletText("In a list of cards, the arrow keys move between cards. On a camera, Return or Space opens the preview and Esc closes it.")
            }
        }
    }

    private var troubleshootingSection: some View {
        AboutSection(title: "Troubleshooting") {
            VStack(alignment: .leading, spacing: 8) {
                BulletText("If a section is empty, clear filters first (⌘E), then press Refresh.")
                BulletText("If a section shows an error banner, that source failed while the other sections may still be usable. Retry tries it again.")
                BulletText("When NZTA can’t be reached, or the Mac is offline, the app shows the data it saved last time and says how old it is. It reloads by itself when the connection comes back.")
                BulletText("If saved data looks wrong, choose Clear Offline Cache in Settings or the Help menu to delete it and reload.")
                BulletText("If a camera preview is stale or missing, press Refresh and check whether the camera is marked offline or maintenance.")
                BulletText("To report a problem, choose Help › Export Diagnostics… and attach the text file. It has counts, data status, recent errors, offline cache details, preferences and the app and macOS versions — no personal data.")
                VStack(alignment: .leading, spacing: 8) {
                    Text("If macOS won't open NZ Traffic after you download it (the app is ad-hoc signed, not notarized):")
                    GatekeeperSteps()
                        .padding(.leading, 13)
                }
            }
        }
    }

    private var privacySection: some View {
        AboutSection(title: "Data and Privacy") {
            VStack(alignment: .leading, spacing: 8) {
                Text("NZ Traffic contacts only these data sources, plus Apple MapKit for the map:")
                DataSourcesList()
                BulletText(AppCredits.offlineCacheNote)
                BulletText("The app has no analytics, accounts, tracking or app backend.")
                BulletText("Updated shows when data last arrived from NZTA. It doesn’t move while fetches are failing, and turns orange after 10 minutes. It doesn't mean every item changed at that time.")
                BulletText(AppCredits.attribution)
                BulletText(AppCredits.evAttribution)
                BulletText(AppCredits.notAffiliated)
            }
        }
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

