import Foundation

// Entry point for the standalone test executable (see run_tests.sh). Top-level
// code runs on the main actor, like the store the async tests exercise.
let runner = TestRunner()
runModelTests(runner)
runEventFilterTests(runner)
runJourneyGeometryTests(runner)
runIdentityTests(runner)
await runRefreshPolicyTests(runner)
await runNetworkTests(runner)
await runStoreTests(runner)
await runViewLogicTests(runner)
exit(runner.finish())
