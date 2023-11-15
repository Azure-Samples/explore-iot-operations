// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// package registry contains the implementation of the monitor and observer components as well as other functionality related to configurable metrics and observability.
package registry

import "sync"

// Observable is an interface whose implementation should be able to observe a float64 value.
type Observable interface {
	Observe(value float64)
}

// Observable is an interface whose implementation should be able to observe a float64 value.
type CancellableObservable interface {
	Observable
	Cancel()
}

// Registry is an interface whose implementation should be able to register and deregister observables.
type Registry interface {
	Register(Observable) int
	Deregister(int)
}

type ObservableRegistry interface {
	Observable
	Registry
}

// ObserverRegistry is an implementation of both Registry and Observable.
type ObserverRegistry struct {
	observables map[int]Observable
	mu          sync.RWMutex
	next        int
}

// NewRegistry will create an ObserverRegistry.
func NewRegistry() *ObserverRegistry {
	return &ObserverRegistry{
		observables: make(map[int]Observable),
	}
}

// Register will add an observable to the registry's map, returning an identifier for that observable.
func (registry *ObserverRegistry) Register(observable Observable) int {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	next := registry.next
	registry.observables[next] = observable
	registry.next++
	return next
}

// Deregister will remove an observable from the registry's map, given an identifier for that observable.
func (registry *ObserverRegistry) Deregister(identifier int) {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	delete(registry.observables, identifier)
}

// Observe will call the observe function for all currently registered observables.
func (registry *ObserverRegistry) Observe(val float64) {
	registry.mu.RLock()
	defer registry.mu.RUnlock()
	for _, observer := range registry.observables {
		observer.Observe(val)
	}
}

type NoopRegistry struct{}

func (reg *NoopRegistry) Register(Observable) int {
	return 0
}

func (reg *NoopRegistry) Deregister(int) {}

func (reg *NoopRegistry) Observe(value float64) {}

type MockRegistry struct {
	OnRegister   func(Observable) int
	OnDeregister func(int)
	OnObserve    func(float64)
}

func (reg *MockRegistry) Register(o Observable) int {
	return reg.OnRegister(o)
}

func (reg *MockRegistry) Deregister(i int) {
	reg.OnDeregister(i)
}

func (reg *MockRegistry) Observe(f float64) {
	reg.OnObserve(f)
}

type MockObservable struct {
	OnObserve func(val float64)
	OnCancel  func()
}

func (obs *MockObservable) Observe(val float64) {
	obs.OnObserve(val)
}

func (obs *MockObservable) Cancel() {
	obs.OnCancel()
}
