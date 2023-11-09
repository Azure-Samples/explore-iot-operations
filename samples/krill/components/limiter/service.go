package limiter

import (
	"context"
	"time"

	"github.com/iot-for-all/device-simulation/lib/component"
)

type Store component.Store[Limiter[struct{}], component.ID]

type Component struct {
	Limit         int
	PeriodSeconds int
}

type Service struct {
	Store
	ctx context.Context
}

func NewStore() Store {
	return component.New[Limiter[struct{}], component.ID]()
}

func NewService(ctx context.Context, store Store) *Service {
	return &Service{
		Store: store,
		ctx:   ctx,
	}
}

func (service *Service) Create(id component.ID, c *Component) error {
	if c.Limit < 1 {
		return &InvalidLimitError{
			value: c.Limit,
		}
	}

	if c.PeriodSeconds < 1 {
		return &InvalidPeriodSecondsError{
			value: c.PeriodSeconds,
		}
	}

	lim := NewTimedLimiter(func(tl *TimedLimiter[struct{}]) {
		tl.Limit = c.Limit
		tl.Period = time.Duration(c.PeriodSeconds) * time.Second
	})
	go lim.Start(service.ctx)

	return service.Store.Create(lim, id)
}
