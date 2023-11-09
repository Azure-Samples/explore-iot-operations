package dialer

import (
	"net"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

const (
	MockString  = "MockString"
	MockNetwork = "MockNetwork"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestMockConn(t *testing.T) {
	conn := &MockConn{
		OnRead: func(b []byte) (int, error) {
			return 0, nil
		},
		OnWrite: func(b []byte) (int, error) {
			return 0, nil
		},
		OnClose: func() error {
			return nil
		},
		OnLocalAddr: func() net.Addr {
			return nil
		},
		OnRemoteAddr: func() net.Addr {
			return nil
		},
		OnSetDeadline: func(t time.Time) error {
			return nil
		},
		OnSetReadDeadline: func(t time.Time) error {
			return nil
		},
		OnSetWriteDeadline: func(t time.Time) error {
			return nil
		},
	}

	require.NoError(t, conn.Close())
	require.NoError(t, conn.SetDeadline(time.Now()))
	require.NoError(t, conn.SetReadDeadline(time.Now()))
	require.NoError(t, conn.SetWriteDeadline(time.Now()))

	_, err := conn.Read(nil)
	require.NoError(t, err)

	_, err = conn.Write(nil)
	require.NoError(t, err)

	require.Nil(t, conn.LocalAddr())
	require.Nil(t, conn.RemoteAddr())
}

func TestMockAddr(t *testing.T) {
	addr := &MockAddr{
		OnNetwork: func() string {
			return MockNetwork
		}, OnString: func() string {
			return MockString
		},
	}

	require.Equal(t, MockString, addr.String())
	require.Equal(t, MockNetwork, addr.Network())
}

func TestNoopConn(t *testing.T) {
	conn := &NoopConn{}

	require.NoError(t, conn.Close())
	require.NoError(t, conn.SetDeadline(time.Now()))
	require.NoError(t, conn.SetReadDeadline(time.Now()))
	require.NoError(t, conn.SetWriteDeadline(time.Now()))

	_, err := conn.Read(nil)
	require.NoError(t, err)

	_, err = conn.Write(nil)
	require.NoError(t, err)

	require.Equal(t, &NoopAddr{}, conn.LocalAddr())
	require.Equal(t, &NoopAddr{}, conn.RemoteAddr())
}

func TestNoopAddr(t *testing.T) {
	addr := &NoopAddr{}

	require.Equal(t, "", addr.String())
	require.Equal(t, "", addr.Network())
}

func TestNetDialer(t *testing.T) {
	dialer := New(func(nd *NetDialer) {
		nd.OnDial = func(network, address string) (net.Conn, error) {
			return nil, nil
		}
	})

	_, err := dialer.Dial("", "")
	require.NoError(t, err)
}

func TestMockDialer(t *testing.T) {
	dialer := &MockDialer{
		OnDial: func(network, address string) (net.Conn, error) {
			return nil, nil
		},
	}

	_, err := dialer.Dial("", "")
	require.NoError(t, err)
}