package ewma

import "math"

type EMWA struct {
	Lambda float64
	L      int
}

func New(options ...func(*EMWA)) *EMWA {
	emwa := &EMWA{
		L:      3,
		Lambda: 0.25,
	}

	for _, option := range options {
		option(emwa)
	}

	return emwa
}

func (emwa *EMWA) EMWA(observation float64, previous float64) float64 {
	return emwa.Lambda*observation + (1-emwa.Lambda)*previous
}

func (emwa *EMWA) ControlLimit(i int, stdDeviation float64) float64 {
	return float64(emwa.L) *
		stdDeviation *
		math.Sqrt(
			(emwa.Lambda/(2.0-emwa.Lambda))*
				(1-math.Pow(
					(1.0-emwa.Lambda),
					float64(2*i),
				)),
		)
}

func (emwa *EMWA) SquareSum(observation, previousSum, mean, previousMean float64) float64 {
	return previousSum + (observation-previousMean)*(observation-mean)
}

func (emwa *EMWA) SampleStdDeviation(i int, squareSum float64) float64 {
	return math.Sqrt(squareSum / (float64(i) - 1))
}

func (emwa *EMWA) Mean(i int, observation, previousMean float64) float64 {
	return (observation-previousMean)/float64(i) + previousMean
}

// Implemented per the control limits of section 9.7 of https://math.montana.edu/jobo/st528/documents/chap9d.pdf.
type EMWADynamicControlSeries struct {
	emwa      *EMWA
	iteration int
	current   float64
	squareSum float64
	mean      float64
}

func NewDynamicControlSeries(emwa *EMWA) *EMWADynamicControlSeries {
	return &EMWADynamicControlSeries{
		emwa: emwa,
	}
}

func (series *EMWADynamicControlSeries) Next(observation float64) bool {
	series.iteration++
	series.current = series.emwa.EMWA(observation, series.current)
	nextMean := series.emwa.Mean(series.iteration, observation, series.mean)
	series.squareSum = series.emwa.SquareSum(observation, series.squareSum, nextMean, series.mean)
	series.mean = nextMean
	control := series.emwa.ControlLimit(series.iteration, series.emwa.SampleStdDeviation(series.iteration, series.squareSum))

	if series.current > series.mean+control || series.current < series.mean-control {
		return false
	}

	return true
}

// Implemented per the control limits specified in https://en.wikipedia.org/wiki/EWMA_chart.
type EstimatedControlSeries struct {
	emwa      *EMWA
	iteration int
	current   float64

	T float64
	S float64
}

func NewEstimatedControlSeries(emwa *EMWA, options ...func(*EstimatedControlSeries)) *EstimatedControlSeries {
	series := &EstimatedControlSeries{}

	for _, option := range options {
		option(series)
	}

	return series
}

func (series *EstimatedControlSeries) Next(observation float64) (float64, bool) {
	series.iteration++
	series.current = series.emwa.EMWA(observation, series.current)
	control := series.emwa.ControlLimit(series.iteration, series.S/math.Sqrt(float64(series.iteration)))

	if series.current > series.S+control || series.current < series.S-control {
		return false
	}

	return true
}
