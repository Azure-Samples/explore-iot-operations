package limiter

import (
	"context"
	"time"
)

type Starter interface {
	Start(context.Context)
}

type Stopper interface {
	Stop()
}

type Limiter[T any] interface {
	Starter
	Stopper
	InputOutput[T]
}

type InputOutput[T any] interface {
	Input() chan<- T
	Output() <-chan T
}

type TimedLimiter[T any] struct {
	done   chan struct{}
	input  chan T
	output chan T
	Limit  int
	Period time.Duration
}

func NewTimedLimiter[T any](
	options ...func(*TimedLimiter[T]),
) *TimedLimiter[T] {
	limiter := &TimedLimiter[T]{
		input:  make(chan T),
		output: make(chan T),
		done:   make(chan struct{}),
		Limit:  1,
		Period: time.Second,
	}

	for _, option := range options {
		option(limiter)
	}

	return limiter
}

func (limiter *TimedLimiter[T]) Start(ctx context.Context) {
	defer close(limiter.output)
	ticker := time.NewTicker(limiter.Period / time.Duration(limiter.Limit))
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			next, ok := <-limiter.input
			if !ok {
				return
			}
			select {
			case limiter.output <- next:
			case <-ctx.Done():
				return
			}
		case <-ctx.Done():
			return
		case <-limiter.done:
			return
		}
	}
}

func (limiter *TimedLimiter[T]) Stop() {
	close(limiter.done)
}

func (limiter *TimedLimiter[T]) Input() chan<- T {
	return limiter.input
}

func (limiter *TimedLimiter[T]) Output() <-chan T {
	return limiter.output
}

type NoopLimiter[T any] struct {
	C chan T
}

func (limiter *NoopLimiter[T]) Start(ctx context.Context) {
	<-ctx.Done()
}

func (limiter *NoopLimiter[T]) Input() chan<- T {
	return limiter.C
}

func (limiter *NoopLimiter[T]) Output() <-chan T {
	return limiter.C
}

func (limiter *NoopLimiter[T]) Stop() {}

type MockLimiter[T any] struct {
	Starter
	OnInput  func() chan<- T
	OnOutput func() <-chan T
}

func (limiter *MockLimiter[T]) Input() chan<- T {
	return limiter.OnInput()
}

func (limiter *MockLimiter[T]) Output() <-chan T {
	return limiter.OnOutput()
}

func (limiter *MockLimiter[T]) Stop() {}