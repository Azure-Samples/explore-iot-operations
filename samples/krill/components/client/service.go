package client

import (
	"context"

	"github.com/iot-for-all/device-simulation/components/broker"
	"github.com/iot-for-all/device-simulation/components/observer"
	"github.com/iot-for-all/device-simulation/components/registry"
	"github.com/iot-for-all/device-simulation/components/site"
	"github.com/iot-for-all/device-simulation/lib/component"
	"github.com/iot-for-all/device-simulation/lib/dialer"
	"github.com/iot-for-all/device-simulation/lib/logger"

	mqttv5 "github.com/eclipse/paho.golang/paho"
	mqttv3 "github.com/eclipse/paho.mqtt.golang"
)

type Store component.Store[PublisherSubscriber, component.ID]

type Type string

const (
	V3 Type = "v3"
	V5 Type = "v5"
)

type Component struct {
	RegistryID        component.ID
	BrokerID          component.ID
	SiteID            component.ID
	Name              string
	Password          string
	Username          string
	ConnectionRetries int
	Type              Type
}

type Service struct {
	Store
	registryStore registry.Store
	brokerStore   broker.Store
	siteStore     site.Store
	Dialer        dialer.Dialer
	Logger        logger.Logger
	CreateV5Conn  func(conn *mqttv5.Client) V5Conn
	CreateV3Conn  func(o *mqttv3.ClientOptions) mqttv3.Client
	ctx           context.Context
}

func NewStore() Store {
	return component.New[PublisherSubscriber, component.ID]()
}

func NewService(
	ctx context.Context,
	store Store,
	registryStore registry.Store,
	brokerStore broker.Store,
	siteStore site.Store,
	options ...func(*Service),
) *Service {
	service := &Service{
		Store:         store,
		registryStore: registryStore,
		brokerStore:   brokerStore,
		siteStore:     siteStore,
		Dialer:        dialer.New(),
		Logger:        &logger.NoopLogger{},
		CreateV5Conn:  NewV5Wrapper,
		CreateV3Conn:  mqttv3.NewClient,
		ctx:           ctx,
	}

	for _, option := range options {
		option(service)
	}

	return service
}

func (service *Service) Create(id component.ID, c *Component) error {
	var reg registry.Observable
	reg, err := service.registryStore.Get(c.RegistryID)
	if err != nil {
		_, ok := err.(*component.NotFoundError)
		if !ok {
			return err
		}
		reg = &observer.NoopObservable{}
	}

	brkr, err := service.brokerStore.Get(c.BrokerID)
	if err != nil {
		return err
	}

	ste, err := service.siteStore.Get(c.SiteID)
	if err != nil {
		return err
	}

	base := New(service.ctx, reg, brkr, ste, func(cli *Client) {
		cli.Name = c.Name
		cli.Logger = service.Logger.With("name", c.Name).With("site", ste.Render()).With("mqtt_version", string(c.Type)).With("broker_endpoint", brkr.Endpoint())
	})
	var cli PublisherSubscriber
	switch c.Type {
	case V5:
		conn, err := service.Dialer.Dial("tcp", brkr.Endpoint())
		if err != nil {
			return &BrokerConnectionError{
				id:       string(id),
				endpoint: brkr.Endpoint(),
				err:      err,
			}
		}

		pcli := mqttv5.NewClient(mqttv5.ClientConfig{
			Router:   mqttv5.NewStandardRouter(),
			Conn:     conn,
			ClientID: c.Name,
		})

		cli = NewClientv5(service.CreateV5Conn(pcli), *base)
	case V3:
		opt := mqttv3.NewClientOptions()
		opt.AddBroker(brkr.Endpoint())
		opt.SetClientID(c.Name)
		opt.SetUsername(c.Username)
		opt.SetPassword(c.Password)
		opt.SetCleanSession(true)

		cli = NewClientv3(service.CreateV3Conn(opt), *base)
	default:
		return &UnknownClientTypeError{
			name: string(c.Type),
		}
	}

	err = cli.Connect()
	if err != nil {
		return err
	}

	return service.Store.Create(cli, id)
}
