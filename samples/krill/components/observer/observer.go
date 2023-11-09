package observer

import (
	"github.com/explore-iot-ops/samples/krill/components/registry"
)

// Observer is an implementation of the CancellableObservable interface and serves as the observer component in the simulation framework.
type Observer struct {
	observable registry.CancellableObservable
	ID         int
	registry   registry.Registry
}

// NewObserver creates an observer given an observable and a registry.
// It will register the observer with the registry when called.
func NewObserver(
	observable registry.CancellableObservable,
	registry registry.Registry,
) *Observer {
	observer := &Observer{
		observable: observable,
		registry:   registry,
	}

	observer.ID = observer.registry.Register(observer)

	return observer
}

// Observe will call the observable's observe function, passing through its observed value.
func (observer *Observer) Observe(val float64) {
	observer.observable.Observe(val)
}

// Cancel will deregister the observable from the registry and then cancel the observable.
func (observer *Observer) Cancel() {
	observer.registry.Deregister(observer.ID)
	observer.observable.Cancel()
}

type NoopObservable struct{}

func (*NoopObservable) Observe(val float64) {}

type MockObserver struct {
	OnObserve func(val float64)
	OnCancel  func()
}

func (obs *MockObserver) Observe(val float64) {
	obs.OnObserve(val)
}

func (obs *MockObserver) Cancel() {
	obs.OnCancel()
}
