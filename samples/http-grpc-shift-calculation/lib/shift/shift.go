package shift

import "time"

type ShiftCalculator struct {
	Shifts        int
	CycleDuration time.Duration
	InitialTime   time.Time
}

func (calculator *ShiftCalculator) Calculate(currentTime time.Time) (int, int) {
	sinceInitialTime := currentTime.Sub(calculator.InitialTime)

	return int(sinceInitialTime / calculator.CycleDuration), int(sinceInitialTime/(calculator.CycleDuration/time.Duration(calculator.Shifts))) % calculator.Shifts
}
