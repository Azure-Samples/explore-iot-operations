// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package environment

import "sync"

type Environment interface {
	Env() map[string]any
	Set(string, any)
}

type MapEnvironment struct {
	env map[string]any
	mu  sync.RWMutex
}

func New() *MapEnvironment {
	return &MapEnvironment{
		env: make(map[string]any),
	}
}

func (env *MapEnvironment) Env() map[string]any {
	env.mu.RLock()
	defer env.mu.RUnlock()

	return env.env
}

func (env *MapEnvironment) Set(s string, a any) {
	env.mu.Lock()
	defer env.mu.Unlock()

	env.env[s] = a
}

type MockEnvironment struct {
	OnEnv func() map[string]any
	OnSet func(string, any)
}

func (environment *MockEnvironment) Env() map[string]any {
	return environment.OnEnv()
}

func (environment *MockEnvironment) Set(s string, a any) {
	environment.OnSet(s, a)
}
