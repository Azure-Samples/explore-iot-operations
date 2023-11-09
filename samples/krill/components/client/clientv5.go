package client

import (
	"context"
	"fmt"

	"github.com/eclipse/paho.golang/paho"
	"github.com/iot-for-all/device-simulation/lib/logger"
)

// Clientv5 is a full PublisherSubscriber implementation which follows the MQTTv5 client protocol.
type Clientv5 struct {
	conn V5Conn
	Client
}

// NewClientv5 creates a Clientv5, given a V5Conn wrapper (wrapper around paho v5 connection) and an underlying client.
func NewClientv5(
	conn V5Conn,
	cli Client,
) *Clientv5 {
	return &Clientv5{
		conn:   conn,
		Client: cli,
	}
}

// Connect establishes a connection with an MQTT v5 compatible broker.
// It will also close the onConnect channel if the connection succeeds.
func (client *Clientv5) Connect() error {
	client.Debug.Printf("attempting new connection with broker")

	_, err := client.conn.Connect(client.ctx, &paho.Connect{
		KeepAlive:  5,
		CleanStart: true,
	})
	if err != nil {
		client.Logger.Level(logger.Error).With("error", err.Error()).Printf("an error occurred when connecting to the broker")
		return err
	}
	close(client.onConnect)
	return err
}

// Disconnect will disconnect from a connected MQTT broker.
// It will also close the onDisconnect channel upon completion.
func (client *Clientv5) Disconnect() error {
	client.Debug.Printf("attempting to disconnect from broker")
	err := client.conn.Disconnect(&paho.Disconnect{})
	if err != nil {
		client.Logger.Level(logger.Error).With("error", err.Error()).Printf("an error occurred when disconnecting from the broker")
		return err
	}
	close(client.onDisconnect)
	return nil
}

// Publish will publish a message on a given topic to a connected MQTT broker.
// It will block until the message publish has succeeded or failed, and return an error if failed.
func (client *Clientv5) Publish(
	topic string,
	qos byte,
	messagesRetained bool,
	data []byte,
) error {
	client.Trace.With("topic", topic).With("qos", fmt.Sprintf("%b", qos)).Printf("publishing new message")
	_, err := client.conn.Publish(client.ctx, &paho.Publish{
		QoS:     qos,
		Retain:  messagesRetained,
		Topic:   topic,
		Payload: data,
	})
	if err != nil {
		client.Logger.Level(logger.Error).With("error", err.Error()).With("topic", topic).With("qos", fmt.Sprintf("%b", qos)).Printf("message publish failed")
		return err
	}

	return nil
}

// Subscribe will subscribe to a given topic on a connected MQTT broker.
// An onReceived function will be registered and called any time a message is received from said broker.
func (client *Clientv5) Subscribe(
	topic string,
	qos byte,
	onReceived func([]byte),
) error {
	client.Debug.With("topic", topic).With("qos", fmt.Sprintf("%b", qos)).Printf("attempting new subscription")

	_, err := client.conn.Subscribe(client.ctx, &paho.Subscribe{
		Subscriptions: map[string]paho.SubscribeOptions{
			topic: {
				QoS: qos,
			},
		},
	})
	if err != nil {
		client.Logger.Level(logger.Error).With("error", err.Error()).With("topic", topic).With("qos", fmt.Sprintf("%b", qos)).Printf("failed to subscribe to the broker")
		return err
	}

	client.conn.RegisterHandler(topic, func(p *paho.Publish) {
		client.Trace.With("topic", topic).With("qos", fmt.Sprintf("%b", qos)).Printf("message received from broker")
		onReceived(p.Payload)
	})

	return nil
}

// Unsubscribe will unsubscribe from a given topic of a connected MQTT broker.
func (client *Clientv5) Unsubscribe(topic string) error {
	client.Debug.With("topic", topic).Printf("attempting to unsubscribe")

	client.conn.UnregisterHandler(topic)

	_, err := client.conn.Unsubscribe(client.ctx, &paho.Unsubscribe{
		Topics: []string{topic},
	})
	if err != nil {
		client.Logger.Level(logger.Error).With("error", err.Error()).With("topic", topic).Printf("failed to unsubscribe from the broker")
		return err
	}

	return nil
}

// V5Conn is an interface whose implementation should be a wrapper around the paho v5 client functionality.
// The purpose of the interface and wrapper is for testing/mocking purposes, and the paho v5 client is difficult
// to mock due to the underlying TCP connection it depends on.
type V5Conn interface {
	Connect(ctx context.Context, cp *paho.Connect) (*paho.Connack, error)
	Disconnect(d *paho.Disconnect) error
	Publish(ctx context.Context, p *paho.Publish) (*paho.PublishResponse, error)
	Subscribe(ctx context.Context, s *paho.Subscribe) (*paho.Suback, error)
	Unsubscribe(
		ctx context.Context,
		u *paho.Unsubscribe,
	) (*paho.Unsuback, error)
	RegisterHandler(string, paho.MessageHandler)
	UnregisterHandler(string)
}

// V5Wrapper is an implementation of V5Conn which wraps the functionality of the paho v5 client.
type V5Wrapper struct {
	conn *paho.Client
}

// NewV5Wrapper creates a new V5Wrapper given a paho v5 client.
func NewV5Wrapper(conn *paho.Client) V5Conn {
	return &V5Wrapper{
		conn: conn,
	}
}

// Connect sets the clientID in the paho connect packet cp equal to the ID of the paho client.
// It then calls the paho client's connect function, passing along its parameters.
func (wrapper *V5Wrapper) Connect(
	ctx context.Context,
	cp *paho.Connect,
) (*paho.Connack, error) {
	cp.ClientID = wrapper.conn.ClientID
	return wrapper.conn.Connect(ctx, cp)
}

// Disconnect calls the paho client's disconnect function, passing along its disconnect packet parameter.
func (wrapper *V5Wrapper) Disconnect(d *paho.Disconnect) error {
	return wrapper.conn.Disconnect(d)
}

// Publish calls the paho client's publish function, passing through its context and publish packet parameters.
func (wrapper *V5Wrapper) Publish(
	ctx context.Context,
	p *paho.Publish,
) (*paho.PublishResponse, error) {
	return wrapper.conn.Publish(ctx, p)
}

// Subscribe calls the paho client's subscribe function, passing through its context and subscribe packet parameters.
func (wrapper *V5Wrapper) Subscribe(
	ctx context.Context,
	s *paho.Subscribe,
) (*paho.Suback, error) {
	return wrapper.conn.Subscribe(ctx, s)
}

// Unsubscribe calls the paho client's unsubscribe function, passing through its context and unsubscribe packet parameters.
func (wrapper *V5Wrapper) Unsubscribe(
	ctx context.Context,
	u *paho.Unsubscribe,
) (*paho.Unsuback, error) {
	return wrapper.conn.Unsubscribe(ctx, u)
}

// RegisterHandler calls the paho client's register handler function, passing through a provided topic, and a message handler.
func (wrapper *V5Wrapper) RegisterHandler(topic string, p paho.MessageHandler) {
	wrapper.conn.Router.RegisterHandler(topic, p)
}

// UnregisterHandler calls the paho client's unregister handler function, passing through a provided topic.
func (wrapper *V5Wrapper) UnregisterHandler(topic string) {
	wrapper.conn.Router.UnregisterHandler(topic)
}

// MockV5Wrapper is a mocking struct designed for testing.
// It implements the V5Conn interface.
type MockV5Wrapper struct {
	OnConnect           func(ctx context.Context, cp *paho.Connect) (*paho.Connack, error)
	OnDisconnect        func(d *paho.Disconnect) error
	OnPublish           func(ctx context.Context, p *paho.Publish) (*paho.PublishResponse, error)
	OnSubscribe         func(ctx context.Context, s *paho.Subscribe) (*paho.Suback, error)
	OnUnsubscribe       func(ctx context.Context, u *paho.Unsubscribe) (*paho.Unsuback, error)
	OnRegisterHandler   func(string, paho.MessageHandler)
	OnUnregisterHandler func(string)
}

// Connect calls the OnConnect function, passing through its parameters.
func (wrapper *MockV5Wrapper) Connect(
	ctx context.Context,
	cp *paho.Connect,
) (*paho.Connack, error) {
	return wrapper.OnConnect(ctx, cp)
}

// Connect calls the OnDisconnect function, passing through its parameters.
func (wrapper *MockV5Wrapper) Disconnect(d *paho.Disconnect) error {
	return wrapper.OnDisconnect(d)
}

// Publish calls the OnPublish function, passing through its parameters.
func (wrapper *MockV5Wrapper) Publish(
	ctx context.Context,
	p *paho.Publish,
) (*paho.PublishResponse, error) {
	return wrapper.OnPublish(ctx, p)
}

// Subscribe calls the OnSubscribe function, passing through its parameters.
func (wrapper *MockV5Wrapper) Subscribe(
	ctx context.Context,
	s *paho.Subscribe,
) (*paho.Suback, error) {
	return wrapper.OnSubscribe(ctx, s)
}

// Unsubscribe calls the OnUnsubscribe function, passing through its parameters.
func (wrapper *MockV5Wrapper) Unsubscribe(
	ctx context.Context,
	u *paho.Unsubscribe,
) (*paho.Unsuback, error) {
	return wrapper.OnUnsubscribe(ctx, u)
}

// RegisterHandler calls the OnRegisterHandler function, passing through its parameters.
func (wrapper *MockV5Wrapper) RegisterHandler(s string, p paho.MessageHandler) {
	wrapper.OnRegisterHandler(s, p)
}

// UnregisterHandler calls the OnUnregisterHandler function, passing through its parameters.
func (wrapper *MockV5Wrapper) UnregisterHandler(s string) {
	wrapper.OnUnregisterHandler(s)
}
