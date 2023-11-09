package client

import (
	"context"
	"net"
	"testing"

	mqttv5 "github.com/eclipse/paho.golang/paho"
	mqtt "github.com/eclipse/paho.mqtt.golang"
	"github.com/iot-for-all/device-simulation/components/site"
	"github.com/iot-for-all/device-simulation/lib/errors"
	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

var (
	exampleTopic = "example"
)

func TestMockClient(t *testing.T) {

	client := &MockClient{
		OnDisconnect: make(chan struct{}),
		OnConnect:    make(chan struct{}),
		OnSubscribe: func(topic string, qos byte, onReceived func([]byte)) error {
			require.Equal(t, exampleTopic, topic)
			return nil
		}, OnUnsubscribe: func(topic string) error {
			require.Equal(t, exampleTopic, topic)
			return nil
		}, OnPublish: func(topic string, qos byte, messagesRetained bool, data []byte) error {
			require.Equal(t, exampleTopic, topic)
			return nil
		},
	}

	go func() {
		require.NoError(t, client.Connect())
	}()
	go func() {
		require.NoError(t, client.Disconnect())
	}()

	<-client.Connected()
	<-client.Disconnected()

	require.NoError(t, client.Publish(exampleTopic, 0, false, nil))
	require.NoError(t, client.Subscribe(exampleTopic, 0, func([]byte) {}))
	require.NoError(t, client.Unsubscribe(exampleTopic))
}

type MockMQTTToken struct {
	mqtt.Token
	done chan struct{}
	err  error
}

func (token *MockMQTTToken) Done() <-chan struct{} {
	return token.done
}

func (token *MockMQTTToken) Error() error {
	return token.err
}

type MockObserver struct {
	onObserve func(float64)
}

func (observer *MockObserver) Observe(value float64) {
	observer.onObserve(value)
}

type MockMessageHandler struct {
	OnPayload func() []byte
	mqtt.Message
}

func (handler *MockMessageHandler) Payload() []byte {
	return handler.OnPayload()
}

func TestClientv3NoErrorsNoCancellations(t *testing.T) {

	ctx := context.Background()
	mon := &MockObserver{}
	broker := &MockObserver{}
	onConnect := make(chan struct{})
	onPublish := make(chan struct{})
	onSub := make(chan struct{})
	onUnsub := make(chan struct{})
	sendSubscription := make(chan struct{})
	client := NewClientv3(&MockV3Conn{
		OnConnect: func() mqtt.Token {
			return &MockMQTTToken{
				done: onConnect,
				err:  nil,
			}
		}, OnDisconnect: func(quiesce uint) {

		}, OnPublish: func(topic string, qos byte, retained bool, payload interface{}) mqtt.Token {
			require.Equal(t, exampleTopic, topic)
			return &MockMQTTToken{
				done: onPublish,
				err:  nil,
			}
		}, OnSubscribe: func(topic string, qos byte, callback mqtt.MessageHandler) mqtt.Token {
			go func() {
				<-sendSubscription
				callback(nil, &MockMessageHandler{
					OnPayload: func() []byte {
						return nil
					},
				})
			}()
			require.Equal(t, exampleTopic, topic)
			return &MockMQTTToken{
				done: onSub,
				err:  nil,
			}
		}, OnUnsubscribe: func(topics ...string) mqtt.Token {
			require.Equal(t, exampleTopic, topics[0])
			return &MockMQTTToken{
				done: onUnsub,
				err:  nil,
			}
		},
	}, *New(ctx, mon, broker, &site.MockSite{
		OnRender: func() string {
			return ""
		},
	}))

	go func() {
		close(onConnect)
	}()

	go func() {
		close(onPublish)
	}()

	go func() {
		close(onSub)
	}()

	go func() {
		close(onUnsub)
	}()

	require.NoError(t, client.Connect())

	<-client.Connected()

	require.NoError(t, client.Subscribe(exampleTopic, 0, func([]byte) {}))

	subscriptionReceived := make(chan struct{})

	require.NoError(t, client.Subscribe(exampleTopic, 0, func([]byte) {
		close(subscriptionReceived)
	}))

	require.NoError(t, client.Publish(exampleTopic, 0, false, nil))

	go func() {
		require.NoError(t, client.Disconnect())
	}()

	<-client.Disconnected()

	go func() {
		close(sendSubscription)
	}()

	<-subscriptionReceived
}

func TestClientv3WithContextCancellations(t *testing.T) {

	ctx, cancel := context.WithCancel(context.Background())
	mon := &MockObserver{}
	broker := &MockObserver{}
	onConnect := make(chan struct{})
	onPublish := make(chan struct{})
	onSub := make(chan struct{})
	onUnsub := make(chan struct{})
	client := NewClientv3(&MockV3Conn{
		OnConnect: func() mqtt.Token {
			return &MockMQTTToken{
				done: onConnect,
				err:  errors.Mock{},
			}
		}, OnDisconnect: func(quiesce uint) {

		}, OnPublish: func(topic string, qos byte, retained bool, payload interface{}) mqtt.Token {
			require.Equal(t, exampleTopic, topic)
			return &MockMQTTToken{
				done: onPublish,
				err:  errors.Mock{},
			}
		}, OnSubscribe: func(topic string, qos byte, callback mqtt.MessageHandler) mqtt.Token {
			require.Equal(t, exampleTopic, topic)
			return &MockMQTTToken{
				done: onSub,
				err:  errors.Mock{},
			}
		}, OnUnsubscribe: func(topics ...string) mqtt.Token {
			require.Equal(t, exampleTopic, topics[0])
			return &MockMQTTToken{
				done: onUnsub,
				err:  errors.Mock{},
			}
		},
	}, *New(ctx, mon, broker, &site.MockSite{
		OnRender: func() string {
			return ""
		},
	}))

	go func() {
		cancel()
	}()

	require.NoError(t, client.Connect())

	notConnected := make(chan struct{})

	select {
	case <-client.Connected():
	default:
		close(notConnected)
	}

	<-notConnected

	require.NoError(t, client.Subscribe(exampleTopic, 0, func([]byte) {
	}))

	require.NoError(t, client.Unsubscribe(exampleTopic))

	require.NoError(t, client.Publish(exampleTopic, 0, false, nil))

	go func() {
		require.NoError(t, client.Disconnect())
	}()

	notDisconnected := make(chan struct{})

	select {
	case <-client.Connected():
	default:
		close(notDisconnected)
	}

	<-notDisconnected
}

func TestClientv3WithMockObserver(t *testing.T) {
	observed := 101.101
	mon := &MockObserver{
		onObserve: func(f float64) {
			require.Equal(t, observed, f)
		},
	}
	broker := &MockObserver{
		onObserve: func(f float64) {
			require.Equal(t, observed, f)
		},
	}
	site := &site.MockSite{
		Observable: &MockObserver{
			onObserve: func(f float64) {
				require.Equal(t, observed, f)
			},
		},
		OnRender: func() string {
			return ""
		},
	}
	client := NewClientv3(nil, *New(context.Background(), mon, broker, site))
	client.Observe(observed)
}

func TestClientv3WithConnectionTokenError(t *testing.T) {
	mon := &MockObserver{}
	broker := &MockObserver{}
	onConnect := make(chan struct{})
	client := NewClientv3(&MockV3Conn{
		OnConnect: func() mqtt.Token {
			return &MockMQTTToken{
				done: onConnect,
				err:  errors.Mock{},
			}
		},
	}, *New(context.Background(), mon, broker, &site.MockSite{
		OnRender: func() string {
			return ""
		},
	}))
	go func() {
		close(onConnect)
	}()
	require.Equal(t, errors.Mock{}, client.Connect())

	notConnected := make(chan struct{})

	select {
	case <-client.Connected():
	default:
		close(notConnected)
	}

	<-notConnected
}

func TestClientv3WithUnsubscribeTokenError(t *testing.T) {
	mon := &MockObserver{}
	broker := &MockObserver{}
	onUnsub := make(chan struct{})
	client := NewClientv3(&MockV3Conn{
		OnUnsubscribe: func(topics ...string) mqtt.Token {
			return &MockMQTTToken{
				done: onUnsub,
				err:  errors.Mock{},
			}
		},
	}, *New(context.Background(), mon, broker, &site.MockSite{
		OnRender: func() string {
			return ""
		},
	}))
	go func() {
		close(onUnsub)
	}()
	require.Equal(t, errors.Mock{}, client.Unsubscribe(""))
}

type MockConn struct {
	net.Conn
}

func TestClientv5ConnectAndDisconnect(t *testing.T) {
	ctx := context.Background()
	mon := &MockObserver{}
	broker := &MockObserver{}

	client := NewClientv5(&MockV5Wrapper{
		OnConnect: func(ctx context.Context, cp *mqttv5.Connect) (*mqttv5.Connack, error) {
			return nil, nil
		},
		OnDisconnect: func(d *mqttv5.Disconnect) error {
			return nil
		},
	}, *New(ctx, mon, broker, &site.MockSite{
		OnRender: func() string {
			return ""
		},
	}))

	require.NoError(t, client.Connect())

	<-client.Connected()

	require.NoError(t, client.Disconnect())

	<-client.Disconnected()
}

func TestClientv5ConnectError(t *testing.T) {
	ctx := context.Background()
	mon := &MockObserver{}
	broker := &MockObserver{}

	client := NewClientv5(&MockV5Wrapper{
		OnConnect: func(ctx context.Context, cp *mqttv5.Connect) (*mqttv5.Connack, error) {
			return nil, errors.Mock{}
		},
	}, *New(ctx, mon, broker, &site.MockSite{
		OnRender: func() string {
			return ""
		},
	}))

	require.Equal(t, errors.Mock{}, client.Connect())
}

func TestClientv5DisconnectError(t *testing.T) {
	ctx := context.Background()
	mon := &MockObserver{}
	broker := &MockObserver{}

	client := NewClientv5(&MockV5Wrapper{
		OnDisconnect: func(d *mqttv5.Disconnect) error {
			return errors.Mock{}
		},
	}, *New(ctx, mon, broker, &site.MockSite{
		OnRender: func() string {
			return ""
		},
	}))

	require.Equal(t, errors.Mock{}, client.Disconnect())
}

func TestClientv5Publish(t *testing.T) {
	ctx := context.Background()
	mon := &MockObserver{}
	broker := &MockObserver{}

	client := NewClientv5(&MockV5Wrapper{
		OnPublish: func(ctx context.Context, p *mqttv5.Publish) (*mqttv5.PublishResponse, error) {
			return nil, errors.Mock{}
		},
	}, *New(ctx, mon, broker, &site.MockSite{
		OnRender: func() string {
			return ""
		},
	}))

	require.Equal(t, errors.Mock{}, client.Publish("", 0, false, nil))
}

func TestClientv5Subscribe(t *testing.T) {
	ctx := context.Background()
	mon := &MockObserver{}
	broker := &MockObserver{}

	client := NewClientv5(&MockV5Wrapper{
		OnSubscribe: func(ctx context.Context, s *mqttv5.Subscribe) (*mqttv5.Suback, error) {
			return nil, nil
		}, OnRegisterHandler: func(s string, mh mqttv5.MessageHandler) {},
	}, *New(ctx, mon, broker, &site.MockSite{
		OnRender: func() string {
			return ""
		},
	}))

	require.NoError(t, client.Subscribe("", 0, func([]byte) {}))
}

func TestClientv5SubscribeError(t *testing.T) {
	ctx := context.Background()
	mon := &MockObserver{}
	broker := &MockObserver{}

	client := NewClientv5(&MockV5Wrapper{
		OnSubscribe: func(ctx context.Context, s *mqttv5.Subscribe) (*mqttv5.Suback, error) {
			return nil, errors.Mock{}
		},
	}, *New(ctx, mon, broker, &site.MockSite{
		OnRender: func() string {
			return ""
		},
	}))

	require.Equal(t, errors.Mock{}, client.Subscribe("", 0, func([]byte) {}))
}

func TestClientv5Unsubscribe(t *testing.T) {
	ctx := context.Background()
	mon := &MockObserver{}
	broker := &MockObserver{}

	client := NewClientv5(&MockV5Wrapper{
		OnUnsubscribe: func(ctx context.Context, u *mqttv5.Unsubscribe) (*mqttv5.Unsuback, error) {
			return nil, nil
		},
		OnUnregisterHandler: func(string) {},
	}, *New(ctx, mon, broker, &site.MockSite{
		OnRender: func() string {
			return ""
		},
	}))

	require.NoError(t, client.Unsubscribe(""))
}

func TestClientv5UnsubscribeError(t *testing.T) {
	ctx := context.Background()
	mon := &MockObserver{}
	broker := &MockObserver{}

	client := NewClientv5(&MockV5Wrapper{
		OnUnsubscribe: func(ctx context.Context, u *mqttv5.Unsubscribe) (*mqttv5.Unsuback, error) {
			return nil, errors.Mock{}
		}, OnUnregisterHandler: func(s string) {},
	}, *New(ctx, mon, broker, &site.MockSite{
		OnRender: func() string {
			return ""
		},
	}))

	require.Equal(t, errors.Mock{}, client.Unsubscribe(""))
}

func TestMockClientv5Wrapper(t *testing.T) {
	client := &MockV5Wrapper{
		OnConnect: func(ctx context.Context, cp *mqttv5.Connect) (*mqttv5.Connack, error) {
			return nil, nil
		},
		OnDisconnect: func(d *mqttv5.Disconnect) error {
			return nil
		},
		OnPublish: func(ctx context.Context, p *mqttv5.Publish) (*mqttv5.PublishResponse, error) {
			return nil, nil
		},
		OnSubscribe: func(ctx context.Context, s *mqttv5.Subscribe) (*mqttv5.Suback, error) {
			return nil, nil
		},
		OnUnsubscribe: func(ctx context.Context, u *mqttv5.Unsubscribe) (*mqttv5.Unsuback, error) {
			return nil, nil
		},
		OnRegisterHandler: func(string, mqttv5.MessageHandler) {
		},
		OnUnregisterHandler: func(string) {
		},
	}

	_, err := client.Connect(context.TODO(), nil)
	require.NoError(t, err)
	_, err = client.Publish(context.TODO(), nil)
	require.NoError(t, err)
	_, err = client.Subscribe(context.TODO(), nil)
	require.NoError(t, err)
	_, err = client.Unsubscribe(context.TODO(), nil)
	require.NoError(t, err)
	require.NoError(t, client.Disconnect(nil))
	client.RegisterHandler("", nil)
	client.UnregisterHandler("")

}