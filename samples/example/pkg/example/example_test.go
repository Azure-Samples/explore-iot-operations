package example

import "testing"

// Every package must have a test file and must meet a minimum test coverage to be merged into the toolbox.
func TestMain(m *testing.M) {
	m.Run()
}
