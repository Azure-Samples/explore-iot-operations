package ewma

import (
	"fmt"
	"math"

	"github.com/explore-iot-ops/lib/logger"
)

type EWMASeries interface {
	Next(observation float64) (float64, bool)
}

type EWMA struct {
	Lambda float64
	L      int
}

func New(options ...func(*EWMA)) *EWMA {
	ewma := &EWMA{
		L:      3,
		Lambda: 0.25,
	}

	for _, option := range options {
		option(ewma)
	}

	return ewma
}

func (ewma *EWMA) EWMA(observation float64, previous float64) float64 {
	return ewma.Lambda*observation + (1-ewma.Lambda)*previous
}

func (ewma *EWMA) ControlLimit(i int, stdDeviation float64) float64 {
	return float64(ewma.L) *
		stdDeviation *
		math.Sqrt(
			(ewma.Lambda/(2.0-ewma.Lambda))*
				(1-math.Pow(
					(1.0-ewma.Lambda),
					float64(2*i),
				)),
		)
}

func (ewma *EWMA) SquareSum(observation, previousSum, mean, previousMean float64) float64 {
	return previousSum + (observation-previousMean)*(observation-mean)
}

func (ewma *EWMA) SampleStdDeviation(i int, squareSum float64) float64 {
	return math.Sqrt(squareSum / (float64(i) - 1))
}

func (ewma *EWMA) Mean(i int, observation, previousMean float64) float64 {
	return (observation-previousMean)/float64(i) + previousMean
}

// Implemented per the control limits of section 9.7 of https://math.montana.edu/jobo/st528/documents/chap9d.pdf.
type EWMADynamicControlSeries struct {
	ewma      *EWMA
	iteration int
	current   float64
	squareSum float64
	mean      float64

	Logger logger.Logger
}

func NewDynamicControlSeries(ewma *EWMA, options ...func(*EWMADynamicControlSeries)) *EWMADynamicControlSeries {
	series := &EWMADynamicControlSeries{
		ewma:   ewma,
		Logger: &logger.NoopLogger{},
	}

	for _, option := range options {
		option(series)
	}

	return series
}

func (series *EWMADynamicControlSeries) Next(observation float64) (float64, bool) {
	series.iteration++
	series.Logger.With("iteration", fmt.Sprintf("%d", series.iteration)).Printf("next iteration")

	series.current = series.ewma.EWMA(observation, series.current)
	series.Logger.With("ewma", fmt.Sprintf("%0.2f", series.current)).Printf("calculated new ewma value")

	nextMean := series.ewma.Mean(series.iteration, observation, series.mean)
	series.Logger.With("mean", fmt.Sprintf("%0.2f", nextMean)).Printf("calculated new mean")

	series.squareSum = series.ewma.SquareSum(observation, series.squareSum, nextMean, series.mean)
	series.Logger.With("sum_of_squares", fmt.Sprintf("%0.2f", series.squareSum)).Printf("calculated new sum of squares")

	series.mean = nextMean
	control := series.ewma.ControlLimit(series.iteration, series.ewma.SampleStdDeviation(series.iteration, series.squareSum))
	series.Logger.With("control_limit", fmt.Sprintf("%0.2f", control)).Printf("calculated control limit")

	if series.current > series.mean+control || series.current < series.mean-control {
		series.Logger.Printf("detected anomaly")
		return series.current, true
	}

	return series.current, false
}

// Implemented per the control limits specified in https://en.wikipedia.org/wiki/EWMA_chart.
type EstimatedControlSeries struct {
	ewma      *EWMA
	iteration int
	current   float64

	T float64
	S float64
	N float64

	Logger logger.Logger
}

func NewEstimatedControlSeries(ewma *EWMA, options ...func(*EstimatedControlSeries)) *EstimatedControlSeries {
	series := &EstimatedControlSeries{
		ewma:   ewma,
		Logger: &logger.NoopLogger{},
	}

	for _, option := range options {
		option(series)
	}

	return series
}

func (series *EstimatedControlSeries) Next(observation float64) (float64, bool) {
	series.iteration++
	series.Logger.With("iteration", fmt.Sprintf("%d", series.iteration)).Printf("next iteration")

	series.current = series.ewma.EWMA(observation, series.current)
	series.Logger.With("ewma", fmt.Sprintf("%0.2f", series.current)).Printf("calculated next ewma value")

	control := series.ewma.ControlLimit(series.iteration, series.S/math.Sqrt(float64(series.N)))
	series.Logger.With("control_limit", fmt.Sprintf("%0.2f", control)).Printf("calculated control limit")

	if series.current > series.T+control || series.current < series.T-control {
		series.Logger.Printf("detected anomaly")
		return series.current, true
	}

	return series.current, false
}
