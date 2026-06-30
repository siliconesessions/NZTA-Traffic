import CoreLocation
import Foundation

func runModelTests(_ t: TestRunner) {
    testLossyInt(t)
    testLossyDouble(t)
    testValidatedCoordinate(t)
    testWKTParsing(t)
    testVMSMessage(t)
    testTrafficDate(t)
    testCameraMatching(t)
    testEventFields(t)
}

// B2 — Double->Int conversion must never trap on out-of-range / non-finite.
private func testLossyInt(_ t: TestRunner) {
    t.group("decodeLossyInt")
    t.equal(decodeModel(TrafficCamera.self, #"{"id":"a","sortOrder":7}"#, t)?.sortOrder, 7, "integer passes through")
    t.equal(decodeModel(TrafficCamera.self, #"{"id":"b","sortOrder":"42"}"#, t)?.sortOrder, 42, "numeric string parses")
    // 1e20 overflows Int; old code trapped, new code returns nil.
    t.equal(decodeModel(TrafficCamera.self, #"{"id":"c","sortOrder":1e20}"#, t)?.sortOrder, nil, "overflow double -> nil (no trap)")
    t.equal(decodeModel(TrafficCamera.self, #"{"id":"d","sortOrder":"oops"}"#, t)?.sortOrder, nil, "non-numeric string -> nil")
}

// B4 — non-finite doubles must be rejected.
private func testLossyDouble(_ t: TestRunner) {
    t.group("decodeLossyDouble")
    let nanCam = decodeModel(TrafficCamera.self, #"{"id":"e","latitude":"NaN","longitude":174.0}"#, t)
    t.equal(nanCam?.latitude, nil, "NaN string latitude -> nil")
    t.check(nanCam?.mapCoordinate == nil, "NaN latitude yields no map coordinate")

    let infCam = decodeModel(TrafficCamera.self, #"{"id":"f","latitude":"Infinity","longitude":174.0}"#, t)
    t.equal(infCam?.latitude, nil, "Infinity string latitude -> nil")

    let goodCam = decodeModel(TrafficCamera.self, #"{"id":"g","latitude":-41.25,"longitude":174.81}"#, t)
    t.nearlyEqual(goodCam?.latitude, -41.25, "valid latitude parses")
    t.check(goodCam?.mapCoordinate != nil, "valid coordinates yield a map coordinate")
}

private func testValidatedCoordinate(_ t: TestRunner) {
    t.group("validatedCoordinate")
    t.check(validatedCoordinate(latitude: -41.3, longitude: 174.8) != nil, "valid NZ coordinate accepted")
    t.check(validatedCoordinate(latitude: 0, longitude: 0) == nil, "(0,0) rejected")
    t.check(validatedCoordinate(latitude: 91, longitude: 174) == nil, "latitude out of range rejected")
    t.check(validatedCoordinate(latitude: -41, longitude: 200) == nil, "longitude out of range rejected")
    t.check(validatedCoordinate(latitude: .nan, longitude: 174) == nil, "NaN rejected")
    t.check(validatedCoordinate(latitude: nil, longitude: 174) == nil, "nil rejected")
}

private func testWKTParsing(_ t: TestRunner) {
    t.group("WKT parsing")
    let point = coordinateFromWKTGeometry("POINT (174.76 -41.28)")
    t.nearlyEqual(point?.latitude, -41.28, "POINT latitude (2nd token)")
    t.nearlyEqual(point?.longitude, 174.76, "POINT longitude (1st token)")
    t.check(coordinateFromWKTGeometry(nil) == nil, "nil geometry -> nil")
    t.check(coordinateFromWKTGeometry("not wkt") == nil, "garbage geometry -> nil")

    let line = parseWKTLineStringCoords("LINESTRING (174.0 -41.0, 175.0 -42.0)")
    t.equal(line.latitudes.count, 2, "linestring yields 2 points")
    t.equal(line.longitudes.count, 2, "linestring longitudes count")
    if line.latitudes.count == 2 {
        t.nearlyEqual(line.latitudes[0], -41.0, "first latitude")
        t.nearlyEqual(line.longitudes[1], 175.0, "second longitude")
    }
}

private func testVMSMessage(_ t: TestRunner) {
    t.group("formatVMSMessage")
    let formatted = formatVMSMessage("[nl]DRIVE[nl]SAFELY[jp]")
    t.check(!formatted.contains("["), "display-control tokens stripped")
    t.check(formatted.contains("DRIVE") && formatted.contains("SAFELY"), "message text preserved")
    t.equal(formatVMSMessage(nil), "No message", "nil -> No message")
    t.equal(formatVMSMessage(""), "No message", "empty -> No message")
    t.equal(formatVMSMessage("  [jp]  "), "No message", "tokens-only -> No message")
}

// B1 — date parsing/formatting is pinned to NZ time and stays robust.
private func testTrafficDate(_ t: TestRunner) {
    t.group("formatTrafficDate")
    // 2026-06-15 midnight at +12:00 (NZST) is NZ wall-clock 15 June.
    let display = formatTrafficDate("2026-06-15T00:00:00+12:00")
    t.check(display?.contains("15 Jun") == true, "ISO date formats to NZ day/month (got \(display ?? "nil"))")
    t.equal(formatTrafficDate(nil), nil, "nil -> nil")
    t.equal(formatTrafficDate("garbage"), "garbage", "unparseable string returned as-is")
}

// Surfaced RoadEvent fields the app already downloads: planned flag,
// directLineDistance landmarks, and the eventIsland filter predicate.
private func testEventFields(_ t: TestRunner) {
    t.group("RoadEvent surfaced fields")
    let json = #"{"id":"e1","eventDescription":"Slip","planned":false,"eventIsland":"South Island","directLineDistance1":"1.20 km north of Rapahoe","directLineDistance2":"4.23 km north of Dunollie","directLineDistance3":"4.84 km north of Runanga"}"#
    guard let event = decodeModel(RoadEvent.self, json, t) else { return }
    t.equal(event.directLineDistance1, "1.20 km north of Rapahoe", "directLineDistance1 decodes")
    t.equal(event.directLineDistance2, "4.23 km north of Dunollie", "directLineDistance2 decodes")
    t.equal(event.directLineDistance3, "4.84 km north of Runanga", "directLineDistance3 decodes")
    t.equal(event.nearestLandmark, "1.20 km north of Rapahoe", "nearestLandmark is the closest landmark")
    t.equal(event.planned, false, "planned bool decodes false")
    t.check(!event.isPlanned, "isPlanned is false for an incident")
    t.equal(event.eventIsland, "South Island", "eventIsland decodes")

    let plannedJson = #"{"id":"e2","eventDescription":"Roadworks","planned":true}"#
    guard let planned = decodeModel(RoadEvent.self, plannedJson, t) else { return }
    t.equal(planned.planned, true, "planned bool decodes true")
    t.check(planned.isPlanned, "isPlanned is true for planned works")
    t.check(planned.nearestLandmark == nil, "no directLineDistance -> nil nearestLandmark")

    // Missing planned flag is treated as an unplanned incident.
    let noFlagJson = #"{"id":"e3","eventDescription":"Crash"}"#
    let noFlag = decodeModel(RoadEvent.self, noFlagJson, t)
    t.equal(noFlag?.planned, nil, "absent planned -> nil")
    t.check(noFlag?.isPlanned == false, "absent planned reads as incident")

    // rest/5 carriageway direction fields.
    let dirJson = #"{"id":"e4","eventDescription":"Slip","direction":"Southbound","travelDirection":"ONE_DIRECTION"}"#
    guard let dir = decodeModel(RoadEvent.self, dirJson, t) else { return }
    t.equal(dir.direction, "Southbound", "direction decodes")
    t.equal(dir.travelDirection, "ONE_DIRECTION", "travelDirection decodes")
    t.equal(dir.directionText, "Southbound", "directionText prefers human-readable direction")

    let bothJson = #"{"id":"e5","eventDescription":"Roadworks","direction":"Both Directions","travelDirection":"BOTH_DIRECTIONS"}"#
    t.equal(decodeModel(RoadEvent.self, bothJson, t)?.directionText, "Both Directions", "directionText reads Both Directions")

    // Falls back to a tidied travelDirection token when `direction` is absent.
    let fallbackJson = #"{"id":"e6","eventDescription":"Crash","travelDirection":"BOTH_DIRECTIONS"}"#
    t.equal(decodeModel(RoadEvent.self, fallbackJson, t)?.directionText, "Both Directions", "directionText tidies travelDirection fallback")

    let noDirJson = #"{"id":"e7","eventDescription":"Crash"}"#
    t.check(decodeModel(RoadEvent.self, noDirJson, t)?.directionText == nil, "absent direction -> nil directionText")

    t.check(EventIslandFilter.all.matches("North Island"), "all matches any island")
    t.check(EventIslandFilter.all.matches(nil), "all matches nil island")
    t.check(EventIslandFilter.south.matches("South Island"), "south matches South Island")
    t.check(!EventIslandFilter.south.matches("North Island"), "south excludes North Island")
    t.check(EventIslandFilter.north.matches("North Island"), "north matches North Island")
    t.check(!EventIslandFilter.north.matches(nil), "north excludes nil island")
}

private func testCameraMatching(_ t: TestRunner) {
    t.group("camera matches()")
    let json = #"{"id":"123","name":"Ngauranga Gorge","highway":"SH1","latitude":-41.25,"longitude":174.81,"region":{"id":"1","name":"Wellington"}}"#
    guard let cam = decodeModel(TrafficCamera.self, json, t) else { return }
    t.check(cam.matches(region: "", highway: "", search: ""), "no filters matches everything")
    t.check(cam.matches(region: "wellington", highway: "", search: ""), "region is case-insensitive")
    t.check(!cam.matches(region: "Otago", highway: "", search: ""), "wrong region excluded")
    t.check(cam.matches(region: "", highway: "sh1", search: ""), "highway haystack matches lowercased")
    t.check(cam.matches(region: "", highway: "", search: "ngauranga"), "search matches name substring")
    t.check(!cam.matches(region: "", highway: "", search: "zzz"), "non-matching search excluded")
}
