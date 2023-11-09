package observer

import (
	"github.com/explore-iot-ops/samples/krill/components/provider"
	"github.com/explore-iot-ops/samples/krill/components/registry"
	"github.com/explore-iot-ops/samples/krill/lib/component"
)

type Store component.Store[*Observer, component.ID]

type Component struct {
	RegistryID component.ID
	ProviderID component.ID
	Label      string
}

type Service struct {
	Store
	registryStore registry.Store
	providerStore provider.Store
}

func NewStore() Store {
	return component.New[*Observer, component.ID]()
}

func NewService(store Store, registryStore registry.Store, providerStore provider.Store) *Service {
	return &Service{
		Store:         store,
		registryStore: registryStore,
		providerStore: providerStore,
	}
}

func (service *Service) Create(id component.ID, c *Component) error {
	reg, err := service.registryStore.Get(c.RegistryID)
	if err != nil {
		return err
	}

	prov, err := service.providerStore.Get(c.ProviderID)
	if err != nil {
		return err
	}

	obs, err := prov.With(c.Label)
	if err != nil {
		return err
	}

	return service.Store.Create(NewObserver(obs, reg), id)
}
