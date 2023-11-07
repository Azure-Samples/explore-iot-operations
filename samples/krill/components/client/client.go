// Package client contains all MQTT client interfaces and implementations.
// It defines several client implementations, including MQTT v3 and v5 compatible clients
// as well as mocking clients for testing.
package client

import (
	"context"
	"fmt"
	"time"

	"github.com/iot-for-all/device-simulation/components/registry"
	"github.com/iot-for-all/device-simulation/components/site"
	"github.com/iot-for-all/device-simulation/lib/logger"

	mqtt "github.com/eclipse/paho.mqtt.golang"
)

// PublisherSubscriber is the composite interface which represents the capabilities of a full featured client.
// These include publishing, subscribing and unsubscribing, and connecting and disconnecting from the broker.
type PublisherSubscriber interface {
	Publisher
	Subscriber
	BrokerConnection
	site.Site
	GetName() string
}

// Publisher is an interface whose implementation should include the observable functionality (see registry package),
// as well as the ability to publish a message on a given topic.
type Publisher interface {
	Publish(topic string, qos byte, messagesRetained bool, data []byte) error
	ConnectionNotifier
	registry.Observable
}

// Subscriber is an interface whose implementation should be able to subscribe and unsubscribe from particular topics.
// It also includes the connection notifier functionality.
type Subscriber interface {
	Subscribe(topic string, qos byte, onReceived func([]byte)) error
	Unsubscribe(topic string) error
	ConnectionNotifier
}

// ConnectionNotifier is an interface whose implementation should be able to close a channel upon a successful
// MQTT broker connection and close another channel upon a successful broker disconnection.
type ConnectionNotifier interface {
	Connected() chan struct{}
	Disconnected() chan struct{}
}

// BrokerConnection is an interface whose implementation should be able to connect and disconnect from an MQTT broker.
type BrokerConnection interface {
	Connect() error
	Disconnect() error
}

// Client implements the ConnectionNotifier interface and serves as base functionality which can be included via
// composition in PublisherSubscriber implementations.
type Client struct {
	ctx          context.Context
	onDisconnect chan struct{}
	onConnect    chan struct{}
	registry.Observable
	broker registry.Observable
	site.Site
	Name   string
	Logger logger.Logger
	Debug  logger.Logger
	Trace  logger.Logger
}

// New creates a new Client, given a context.
func New(
	ctx context.Context,
	mon registry.Observable,
	broker registry.Observable,
	ste site.Site,
	options ...func(*Client),
) *Client {
	cli := &Client{
		onConnect:    make(chan struct{}),
		onDisconnect: make(chan struct{}),
		broker:       broker,
		Site:         ste,
		Observable:   mon,
		ctx:          ctx,
		Logger:       &logger.NoopLogger{},
	}

	for _, option := range options {
		option(cli)
	}

	cli.Debug = cli.Logger.Level(logger.Debug)
	cli.Trace = cli.Logger.Level(logger.Trace)

	return cli
}

// Connected returns the onConnect channel.
func (client *Client) Connected() chan struct{} {
	return client.onConnect
}

// Disconnected returns the onDisconnect channel.
func (client *Client) Disconnected() chan struct{} {
	return client.onDisconnect
}

func (client *Client) GetName() string {
	return client.Name
}

// Observe will pass a float64 value to be observed by the client monitor and the broker monitor.
func (client *Client) Observe(value float64) {
	client.Observable.Observe(value)
	client.broker.Observe(value)
	client.Site.Observe(value)
}

// Clientv3 is a full PublisherSubscriber implementation which follows the MQTTv3 client protocol.
type Clientv3 struct {
	conn mqtt.Client
	Client
}

// NewClientv3 creates a Clientv3, given a paho mqttv3 connection and an underlying client.
func NewClientv3(
	conn mqtt.Client,
	cli Client,
) *Clientv3 {
	return &Clientv3{
		conn:   conn,
		Client: cli,
	}
}

// Connect establishes a connection with an MQTT v3 compatible broker.
// It will block until the connection has succeeded or failed, and return an error if failed.
// It will also close the onConnect channel upon completion.
func (client *Clientv3) Connect() error {
	client.Debug.Printf("attempting new connection with broker")

	token := client.conn.Connect()

	select {
	case <-client.ctx.Done():
		client.Debug.Printf("connection to broker was interrupted by context cancellation")
		return nil
	case <-token.Done():
	}

	err := token.Error()
	if err != nil {
		client.Logger.Level(logger.Error).With("error", err.Error()).Printf("an error occurred when connection to the broker")
		return err
	}

	client.Debug.Printf("connection succeeded")

	close(client.onConnect)

	return nil
}

// Disconnect will disconnect from a connected MQTT broker.
// It will also close the onDisconnect channel upon completion.
func (client *Clientv3) Disconnect() error {
	client.Debug.Printf("attempting to disconnect from broker")
	client.conn.Disconnect(0)
	close(client.onDisconnect)
	return nil
}

// Publish will publish a message on a given topic to a connected MQTT broker.
// It will block until the message publish has succeeded or failed, and return an error if failed.
func (client *Clientv3) Publish(
	topic string,
	qos byte,
	messagesRetained bool,
	data []byte,
) error {

	client.Trace.With("topic", topic).With("qos", fmt.Sprintf("%b", qos)).Printf("publishing new message")

	token := client.conn.Publish(topic, qos, messagesRetained, data)

	select {
	case <-client.ctx.Done():
		client.Debug.With("topic", topic).With("qos", fmt.Sprintf("%b", qos)).Printf("message publish cancelled due to context cancellation")
		return nil
	case <-token.Done():
		return token.Error()
	}
}

// Subscribe will subscribe to a given topic on a connected MQTT broker.
// An onReceived function will be registered and called any time a message is received from said broker.
func (client *Clientv3) Subscribe(
	topic string,
	qos byte,
	onReceived func([]byte),
) error {
	client.Debug.With("topic", topic).With("qos", fmt.Sprintf("%b", qos)).Printf("attempting new subscription")

	token := client.conn.Subscribe(
		topic,
		qos,
		func(_ mqtt.Client, m mqtt.Message) {
			client.Trace.With("topic", topic).With("qos", fmt.Sprintf("%b", qos)).Printf("message received from broker")
			onReceived(m.Payload())
		},
	)

	select {
	case <-client.ctx.Done():
		client.Debug.With("topic", topic).With("qos", fmt.Sprintf("%b", qos)).Printf("subscription cancelled due to context cancellation")
		return nil
	case <-token.Done():
		return token.Error()
	}
}

// Unsubscribe will unsubscribe from a given topic of a connected MQTT broker.
func (client *Clientv3) Unsubscribe(topic string) error {
	client.Debug.With("topic", topic).Printf("attempting to unsubscribe")

	token := client.conn.Unsubscribe(topic)

	select {
	case <-client.ctx.Done():
		return nil
	case <-token.Done():
		return token.Error()
	}
}

// MockClient is a PublisherSubscriber implementation used for testing purposes.
// It has callbacks which can be configured in tests to mock out client behaviors.
type MockClient struct {
	OnDisconnect  chan struct{}
	OnConnect     chan struct{}
	OnSubscribe   func(topic string, qos byte, onReceived func([]byte)) error
	OnUnsubscribe func(topic string) error
	OnPublish     func(topic string, qos byte, messagesRetained bool, data []byte) error
	OnGetName     func() string
	OnRender      func() string
	registry.Observable
}

func (client *MockClient) GetName() string {
	return client.OnGetName()
}

func (client *MockClient) Render() string {
	return client.OnRender()
}

// Subscribe calls the mock client's OnSubscribe function, passing along its provided parameters.
func (client *MockClient) Subscribe(
	topic string,
	qos byte,
	onReceived func([]byte),
) error {
	return client.OnSubscribe(topic, qos, onReceived)
}

// Publish calls the mock client's OnPublish function, passing along its provided parameters.
func (client *MockClient) Publish(
	topic string,
	qos byte,
	messagesRetained bool,
	data []byte,
) error {
	return client.OnPublish(topic, qos, messagesRetained, data)
}

// Unsubscribe calls the mock client's OnUnsubscribe function, passing along its provided parameters.
func (client *MockClient) Unsubscribe(topic string) error {
	return client.OnUnsubscribe(topic)
}

// Connect closes the mock client's OnConnect channel.
func (client *MockClient) Connect() error {
	close(client.OnConnect)
	return nil
}

// Disconnect closes the mock client's OnDisconnect channel.
func (client *MockClient) Disconnect() error {
	close(client.OnDisconnect)
	return nil
}

// Connected returns the mock client's OnConnect channel.
func (client *MockClient) Connected() chan struct{} {
	return client.OnConnect
}

// Disconnected returns the mock client's OnDisconnect channel.
func (client *MockClient) Disconnected() chan struct{} {
	return client.OnDisconnect
}

type MockV3Conn struct {
	mqtt.Client
	OnConnect     func() mqtt.Token
	OnDisconnect  func(quiesce uint)
	OnPublish     func(topic string, qos byte, retained bool, payload interface{}) mqtt.Token
	OnSubscribe   func(topic string, qos byte, callback mqtt.MessageHandler) mqtt.Token
	OnUnsubscribe func(topics ...string) mqtt.Token
}

func (mock *MockV3Conn) Connect() mqtt.Token {
	return mock.OnConnect()
}

func (mock *MockV3Conn) Disconnect(quiesce uint) {
	mock.OnDisconnect(quiesce)
}

func (mock *MockV3Conn) Publish(topic string, qos byte, retained bool, payload interface{}) mqtt.Token {
	return mock.OnPublish(topic, qos, retained, payload)
}

func (mock *MockV3Conn) Subscribe(topic string, qos byte, callback mqtt.MessageHandler) mqtt.Token {
	return mock.OnSubscribe(topic, qos, callback)
}

func (mock *MockV3Conn) Unsubscribe(topics ...string) mqtt.Token {
	return mock.OnUnsubscribe(topics...)
}

type MockToken struct {
	mqtt.Token
	OnWait        func() bool
	OnWaitTimeout func(time.Duration) bool
	OnDone        func() <-chan struct{}
	OnError       func() error
}

func (mock *MockToken) Wait() bool {
	return mock.OnWait()
}

func (mock *MockToken) WaitTimeout(t time.Duration) bool {
	return mock.OnWaitTimeout(t)
}

func (mock *MockToken) Done() <-chan struct{} {
	return mock.OnDone()
}

func (mock *MockToken) Error() error {
	return mock.OnError()
}