// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package component

import (
	"sync"
)

type StoreOption[E any, I comparable] func(*Memstore[E, I])

type Memstore[E any, I comparable] struct {
	memory map[I]E
	mu     *sync.RWMutex
}

func New[E any, I comparable]() *Memstore[E, I] {
	store := &Memstore[E, I]{
		memory: make(map[I]E),
		mu:     &sync.RWMutex{},
	}

	return store
}

func (memstore *Memstore[E, I]) Create(entity E, identifier I) error {

	memstore.mu.Lock()
	memstore.memory[identifier] = entity
	memstore.mu.Unlock()

	return nil
}

func (memstore *Memstore[E, I]) Get(identifier I) (E, error) {
	var entity E

	memstore.mu.RLock()
	entity, ok := memstore.memory[identifier]
	memstore.mu.RUnlock()

	if ok {
		return entity, nil
	}
	return entity, &NotFoundError{}
}

func (memstore *Memstore[E, I]) Check(identifier I) error {
	memstore.mu.RLock()
	_, ok := memstore.memory[identifier]
	memstore.mu.RUnlock()

	if ok {
		return nil
	}
	return &NotFoundError{}
}

func (memstore *Memstore[E, I]) Delete(identifier I) error {

	memstore.mu.Lock()
	delete(memstore.memory, identifier)
	memstore.mu.Unlock()
	return nil
}

func (memstore *Memstore[E, I]) List() ([]I, error) {
	keys := make([]I, len(memstore.memory))

	index := 0

	memstore.mu.RLock()
	for k := range memstore.memory {
		keys[index] = k
		index++
	}
	memstore.mu.RUnlock()

	return keys, nil
}
