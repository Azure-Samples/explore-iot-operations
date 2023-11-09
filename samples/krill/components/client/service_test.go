package client

import (
	"context"
	"net"
	"testing"

	"github.com/iot-for-all/device-simulation/components/broker"
	"github.com/iot-for-all/device-simulation/components/registry"
	"github.com/iot-for-all/device-simulation/components/site"
	"github.com/iot-for-all/device-simulation/lib/component"
	"github.com/iot-for-all/device-simulation/lib/dialer"
	"github.com/stretchr/testify/require"

	mqttv5 "github.com/eclipse/paho.golang/paho"
	mqttv3 "github.com/eclipse/paho.mqtt.golang"
)

const (
	MockID         = "MockID"
	MockRegistryID = "MockRegistryID"
	MockBrokerID   = "MockBrokerID"
	MockSiteID     = "MockSiteID"
	MockEndpoint   = "MockEndpoint"
	MockSite       = "MockSite"
	MockName       = "MockName"
	MockPassword   = "MockPassword"
	MockUsername   = "MockUsername"
	MockType       = "MockType"
	MockError      = "MockError"
)

func TestStore(t *testing.T) {
	store := NewStore()
	_, ok := store.(*component.Memstore[PublisherSubscriber, component.ID])
	require.True(t, ok)
}

func TestServiceClientV5(t *testing.T) {

	ctx := context.Background()

	service := NewService(ctx, &component.MockStore[PublisherSubscriber, component.ID]{
		OnCreate: func(entity PublisherSubscriber, identifier component.ID) error {
			require.Equal(t, MockID, string(identifier))
			return nil
		},
	}, &component.MockStore[registry.ObservableRegistry, component.ID]{
		OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
			require.Equal(t, MockRegistryID, string(identifier))
			return &registry.MockRegistry{}, nil
		},
	}, &component.MockStore[broker.Source, component.ID]{
		OnGet: func(identifier component.ID) (broker.Source, error) {
			require.Equal(t, MockBrokerID, string(identifier))
			return &broker.MockBroker{
				OnEndpoint: func() string {
					return MockEndpoint
				},
			}, nil
		},
	}, &component.MockStore[site.Site, component.ID]{
		OnGet: func(identifier component.ID) (site.Site, error) {
			require.Equal(t, MockSiteID, string(identifier))
			return &site.MockSite{
				OnRender: func() string {
					return MockSite
				},
			}, nil
		},
	}, func(s *Service) {
		s.Dialer = &dialer.MockDialer{
			OnDial: func(network, address string) (net.Conn, error) {
				return &dialer.NoopConn{}, nil
			},
		}
		s.CreateV5Conn = func(conn *mqttv5.Client) V5Conn {
			return &MockV5Wrapper{
				OnConnect: func(ctx context.Context, cp *mqttv5.Connect) (*mqttv5.Connack, error) {
					return nil, nil
				},
			}
		}
	})

	err := service.Create(MockID, &Component{
		RegistryID: MockRegistryID,
		BrokerID:   MockBrokerID,
		SiteID:     MockSiteID,
		Type:       V5,
	})
	require.NoError(t, err)
}

func TestServiceClientV3(t *testing.T) {

	ctx := context.Background()

	service := NewService(ctx, &component.MockStore[PublisherSubscriber, component.ID]{
		OnCreate: func(entity PublisherSubscriber, identifier component.ID) error {
			require.Equal(t, MockID, string(identifier))
			return nil
		},
	}, &component.MockStore[registry.ObservableRegistry, component.ID]{
		OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
			require.Equal(t, MockRegistryID, string(identifier))
			return &registry.MockRegistry{}, nil
		},
	}, &component.MockStore[broker.Source, component.ID]{
		OnGet: func(identifier component.ID) (broker.Source, error) {
			require.Equal(t, MockBrokerID, string(identifier))
			return &broker.MockBroker{
				OnEndpoint: func() string {
					return MockEndpoint
				},
			}, nil
		},
	}, &component.MockStore[site.Site, component.ID]{
		OnGet: func(identifier component.ID) (site.Site, error) {
			require.Equal(t, MockSiteID, string(identifier))
			return &site.MockSite{
				OnRender: func() string {
					return MockSite
				},
			}, nil
		},
	}, func(s *Service) {
		s.CreateV3Conn = func(o *mqttv3.ClientOptions) mqttv3.Client {
			require.Equal(t, MockEndpoint, o.Servers[0].Host)
			require.Equal(t, MockName, o.ClientID)
			require.Equal(t, MockPassword, o.Password)
			require.Equal(t, MockUsername, o.Username)
			require.True(t, o.CleanSession)
			return &MockV3Conn{
				OnConnect: func() mqttv3.Token {
					return &MockToken{
						OnDone: func() <-chan struct{} {
							c := make(chan struct{})
							close(c)
							return c
						}, OnError: func() error {
							return nil
						},
					}
				},
			}
		}
	})

	err := service.Create(MockID, &Component{
		RegistryID:        MockRegistryID,
		BrokerID:          MockBrokerID,
		SiteID:            MockSiteID,
		Name:              MockName,
		Password:          MockPassword,
		Username:          MockUsername,
		ConnectionRetries: 0,
		Type:              V3,
	})
	require.NoError(t, err)
}

func TestServiceInvalidClientType(t *testing.T) {

	ctx := context.Background()

	service := NewService(ctx, &component.MockStore[PublisherSubscriber, component.ID]{
		OnCreate: func(entity PublisherSubscriber, identifier component.ID) error {
			return nil
		},
	}, &component.MockStore[registry.ObservableRegistry, component.ID]{
		OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
			return &registry.MockRegistry{}, nil
		},
	}, &component.MockStore[broker.Source, component.ID]{
		OnGet: func(identifier component.ID) (broker.Source, error) {
			return &broker.MockBroker{
				OnEndpoint: func() string {
					return MockEndpoint
				},
			}, nil
		},
	}, &component.MockStore[site.Site, component.ID]{
		OnGet: func(identifier component.ID) (site.Site, error) {
			return &site.MockSite{
				OnRender: func() string {
					return MockSite
				},
			}, nil
		},
	})

	err := service.Create(MockID, &Component{
		RegistryID:        MockRegistryID,
		BrokerID:          MockBrokerID,
		SiteID:            MockSiteID,
		Name:              MockName,
		Password:          MockPassword,
		Username:          MockUsername,
		ConnectionRetries: 0,
		Type:              MockType,
	})
	require.Equal(t, &UnknownClientTypeError{
		name: MockType,
	}, err)
}

func TestServiceClientV3ConnectionError(t *testing.T) {

	ctx := context.Background()

	service := NewService(ctx, &component.MockStore[PublisherSubscriber, component.ID]{
		OnCreate: func(entity PublisherSubscriber, identifier component.ID) error {
			return nil
		},
	}, &component.MockStore[registry.ObservableRegistry, component.ID]{
		OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
			return &registry.MockRegistry{}, nil
		},
	}, &component.MockStore[broker.Source, component.ID]{
		OnGet: func(identifier component.ID) (broker.Source, error) {
			return &broker.MockBroker{
				OnEndpoint: func() string {
					return MockEndpoint
				},
			}, nil
		},
	}, &component.MockStore[site.Site, component.ID]{
		OnGet: func(identifier component.ID) (site.Site, error) {
			return &site.MockSite{
				OnRender: func() string {
					return MockSite
				},
			}, nil
		},
	}, func(s *Service) {
		s.CreateV3Conn = func(o *mqttv3.ClientOptions) mqttv3.Client {
			return &MockV3Conn{
				OnConnect: func() mqttv3.Token {
					return &MockToken{
						OnDone: func() <-chan struct{} {
							c := make(chan struct{})
							close(c)
							return c
						}, OnError: func() error {
							return &component.MockError{
								OnError: func() string {
									return ""
								},
							}
						},
					}
				},
			}
		}
	})

	err := service.Create(MockID, &Component{
		Type: V3,
	})
	_, ok := err.(*component.MockError)
	require.True(t, ok)
}

func TestServiceClientV5DialError(t *testing.T) {

	ctx := context.Background()

	service := NewService(ctx, &component.MockStore[PublisherSubscriber, component.ID]{
		OnCreate: func(entity PublisherSubscriber, identifier component.ID) error {
			return nil
		},
	}, &component.MockStore[registry.ObservableRegistry, component.ID]{
		OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
			return &registry.MockRegistry{}, nil
		},
	}, &component.MockStore[broker.Source, component.ID]{
		OnGet: func(identifier component.ID) (broker.Source, error) {
			return &broker.MockBroker{
				OnEndpoint: func() string {
					return MockEndpoint
				},
			}, nil
		},
	}, &component.MockStore[site.Site, component.ID]{
		OnGet: func(identifier component.ID) (site.Site, error) {
			return &site.MockSite{
				OnRender: func() string {
					return MockSite
				},
			}, nil
		},
	}, func(s *Service) {
		s.Dialer = &dialer.MockDialer{
			OnDial: func(network, address string) (net.Conn, error) {
				return nil, &component.MockError{}
			},
		}
	})

	err := service.Create(MockID, &Component{
		Type: V5,
	})
	require.Equal(t, &BrokerConnectionError{
		id:       MockID,
		err:      &component.MockError{},
		endpoint: MockEndpoint,
	}, err)
}

func TestServiceRegistryStoreGetError(t *testing.T) {

	ctx := context.Background()

	service := NewService(ctx, nil, &component.MockStore[registry.ObservableRegistry, component.ID]{
		OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
			return nil, &component.MockError{}
		},
	}, nil, nil)

	err := service.Create(MockID, &Component{
		Type: V5,
	})
	require.Equal(t, &component.MockError{}, err)
}

func TestServiceBrokerError(t *testing.T) {

	ctx := context.Background()

	service := NewService(ctx, nil, &component.MockStore[registry.ObservableRegistry, component.ID]{
		OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
			return nil, nil
		},
	}, &component.MockStore[broker.Source, component.ID]{
		OnGet: func(identifier component.ID) (broker.Source, error) {
			return nil, &component.MockError{}
		},
	}, nil)

	err := service.Create(MockID, &Component{
		Type: V5,
	})
	require.Equal(t, &component.MockError{}, err)
}

func TestServiceSiteErrorRegistryNotFound(t *testing.T) {

	ctx := context.Background()

	service := NewService(ctx, nil, &component.MockStore[registry.ObservableRegistry, component.ID]{
		OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
			return nil, &component.NotFoundError{}
		},
	}, &component.MockStore[broker.Source, component.ID]{
		OnGet: func(identifier component.ID) (broker.Source, error) {
			return nil, nil
		},
	}, &component.MockStore[site.Site, component.ID]{
		OnGet: func(identifier component.ID) (site.Site, error) {
			return nil, &component.MockError{}
		},
	})

	err := service.Create(MockID, &Component{
		Type: V5,
	})
	require.Equal(t, &component.MockError{}, err)
}

func TestBrokerConnectionError(t *testing.T) {

	expectedError := `mqtt client with id=MockID could not connect to MQTT broker at endpoint MockEndpoint: "MockError"`

	err := &BrokerConnectionError{
		id:       MockID,
		endpoint: MockEndpoint,
		err: &component.MockError{
			OnError: func() string {
				return MockError
			},
		},
	}

	require.Equal(t, expectedError, err.Error())
}

func TestUnknownClientTypeError(t *testing.T) {

	expectedError := "no such MockName type for mqtt client component"

	err := &UnknownClientTypeError{
		name: MockName,
	}

	require.Equal(t, expectedError, err.Error())
}