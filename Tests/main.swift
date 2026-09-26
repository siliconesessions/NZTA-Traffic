import Foundation

// Entry point for the standalone test executable (see run_tests.sh).
let runner = TestRunner()
runModelTests(runner)
runEventFilterTests(runner)
runJourneyGeometryTests(runner)
runIdentityTests(runner)
exit(runner.finish())
