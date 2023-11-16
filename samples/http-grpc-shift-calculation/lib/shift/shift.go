package shift

import "time"

type ShiftCalculator struct {
	Shifts        int
	CycleDuration time.Duration
	InitialTime   time.Time
}

func NewShiftCalculator(
	options ...func(*ShiftCalculator),
) *ShiftCalculator {
	calculator := &ShiftCalculator{
		Shifts:        3,
		CycleDuration: time.Hour * 24,
		InitialTime:   time.Date(2000, time.January, 1, 0, 0, 0, 0, time.UTC),
	}

	for _, option := range options {
		option(calculator)
	}

	return calculator
}

func (calculator *ShiftCalculator) Calculate(currentTime time.Time) (int, int) {
	sinceInitialTime := currentTime.Sub(calculator.InitialTime)

	return int(sinceInitialTime / calculator.CycleDuration), int(sinceInitialTime/(calculator.CycleDuration/time.Duration(calculator.Shifts))) % calculator.Shifts
}
