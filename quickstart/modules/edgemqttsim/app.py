"""
Edge MQTT Simulator - Azure IoT Operations MQTT Client
Simulates an industrial facility with multiple machine types.
Sends realistic telemetry to Azure IoT Operations MQTT Broker using K8S-SAT authentication.
"""

import paho.mqtt.client as mqtt
import time
import os
import json
import queue
import threading
import ssl
from datetime import datetime
from pathlib import Path
from messages import FactoryMessageGenerator

# MQTT Configuration from environment variables
MQTT_BROKER = os.environ.get('MQTT_BROKER', 'localhost')
MQTT_PORT = int(os.environ.get('MQTT_PORT', '18883'))  # Default AIO MQTT port
MQTT_TOPIC_PREFIX = os.environ.get('MQTT_TOPIC_PREFIX', 'factory')
MQTT_CLIENT_ID = os.environ.get('MQTT_CLIENT_ID', f'factory-sim-{os.getpid()}')

# ServiceAccountToken authentication settings
AUTH_METHOD = os.environ.get('MQTT_AUTH_METHOD', 'K8S-SAT')  # Default to SAT
SAT_TOKEN_PATH = os.environ.get('SAT_TOKEN_PATH', '/var/run/secrets/tokens/broker-sat')

# Message generator configuration
MESSAGE_CONFIG_PATH = os.environ.get('MESSAGE_CONFIG_PATH', 'message_structure.yaml')

# Global connection state
is_connected = threading.Event()
message_queue = queue.Queue(maxsize=1000)  # Buffer up to 1000 messages

# Statistics
stats = {
    'messages_sent': 0,
    'messages_failed': 0,
    'messages_queued': 0,
    'start_time': datetime.utcnow()
}
stats_lock = threading.Lock()


def get_sat_token():
    """Read the ServiceAccountToken from the mounted volume."""
    try:
        token_path = Path(SAT_TOKEN_PATH)
        if token_path.exists():
            token = token_path.read_text().strip()
            print(f"[OK] Read SAT token from {SAT_TOKEN_PATH} ({len(token)} chars)")
            return token
        else:
            print(f"[ERROR] SAT token file not found at {SAT_TOKEN_PATH}")
            return None
    except Exception as e:
        print(f"[ERROR] Error reading SAT token: {e}")
        return None


def on_connect(client, userdata, flags, reason_code, properties=None):
    """Called when the client connects to the broker. MQTT v5 includes properties parameter."""
    # For MQTT v5, reason_code is a ReasonCodes object
    if hasattr(reason_code, 'value'):
        rc = reason_code.value  # Extract the numeric value from ReasonCodes
    else:
        rc = reason_code  # Fall back to numeric value for MQTT v3

    # MQTT v5 CONNACK Reason Codes
    connack_codes = {
        0: "Success",
        1: "Connection refused - unacceptable protocol version",
        2: "Connection refused - identifier rejected", 
        3: "Connection refused - server unavailable",
        4: "Connection refused - bad username or password",
        5: "Connection refused - not authorized",
        128: "Unspecified error",
        129: "Malformed packet",
        130: "Protocol error",
        131: "Implementation specific error",
        132: "Unsupported protocol version",
        133: "Client identifier not valid",
        134: "Bad username or password",
        135: "Not authorized",
        136: "Server unavailable",
        137: "Server busy",
        138: "Banned",
        140: "Bad authentication method",
        144: "Topic name invalid",
        149: "Packet too large",
        151: "Quota exceeded",
        153: "Payload format invalid",
        155: "Retain not supported",
        156: "QoS not supported",
        157: "Use another server",
        158: "Server moved",
        159: "Connection rate exceeded"
    }
    
    if rc == 0:
        print(f"✓ Connected successfully to MQTT broker at {MQTT_BROKER}:{MQTT_PORT}")
        if properties:
            print(f"  Connection properties: {properties}")
        is_connected.set()
    else:
        error_message = connack_codes.get(rc, f"Unknown CONNACK error (code: {rc})")
        print(f"✗ Failed to connect: {error_message}")
        print(f"  CONNACK reason code: {rc}")
        if properties:
            print(f"  Error properties: {properties}")
        is_connected.clear()


def on_disconnect(client, userdata, reason_code, properties=None):
    """Called when the client disconnects from the broker. MQTT v5 includes properties parameter."""
    is_connected.clear()
    
    # Handle MQTT v5 ReasonCodes object
    if hasattr(reason_code, 'value'):
        rc = reason_code.value
    else:
        rc = reason_code
    
    # MQTT v5 DISCONNECT Reason Codes
    disconnect_codes = {
        0: "Normal disconnection",
        4: "Disconnect with will message",
        128: "Unspecified error",
        129: "Malformed packet",
        130: "Protocol error",
        131: "Implementation specific error",
        135: "Not authorized",
        137: "Server busy",
        139: "Server shutting down",
        141: "Keep alive timeout",
        142: "Session taken over",
        143: "Topic filter invalid",
        144: "Topic name invalid",
        147: "Receive maximum exceeded",
        148: "Topic alias invalid",
        149: "Packet too large",
        150: "Message rate too high",
        151: "Quota exceeded",
        152: "Administrative action",
        153: "Payload format invalid",
        154: "Retain not supported",
        155: "QoS not supported",
        156: "Use another server",
        157: "Server moved",
        158: "Shared subscriptions not supported",
        159: "Connection rate exceeded",
        160: "Maximum connect time",
        161: "Subscription identifiers not supported",
        162: "Wildcard subscriptions not supported"
    }
        
    if rc != 0:
        error_message = disconnect_codes.get(rc, f"Unknown DISCONNECT reason (code: {rc})")
        print(f"! Unexpected disconnection: {error_message} (Code: {rc})")
        if properties:
            print(f"  Disconnect properties: {properties}")
    else:
        print("Disconnected successfully")


def on_publish(client, userdata, mid, properties=None):
    """Called when a message has been published to the broker."""
    with stats_lock:
        stats['messages_sent'] += 1


def get_topic_for_message(message: dict) -> str:
    """Determine the appropriate MQTT topic based on message type."""
    # Route based on message content
    if 'event_type' in message:
        event_type = message['event_type']
        if event_type == 'order_placed':
            return f"{MQTT_TOPIC_PREFIX}/orders"
        elif event_type == 'order_dispatched':
            return f"{MQTT_TOPIC_PREFIX}/dispatch"
    
    # Route based on machine type
    if 'machine_id' in message:
        machine_id = message['machine_id']
        if machine_id.startswith('CNC-'):
            return f"{MQTT_TOPIC_PREFIX}/cnc"
        elif machine_id.startswith('3DP-'):
            return f"{MQTT_TOPIC_PREFIX}/3dprinter"
        elif machine_id.startswith('WELD-'):
            return f"{MQTT_TOPIC_PREFIX}/welding"
        elif machine_id.startswith('PAINT-'):
            return f"{MQTT_TOPIC_PREFIX}/painting"
        elif machine_id.startswith('TEST-'):
            return f"{MQTT_TOPIC_PREFIX}/testing"
    
    # Default topic
    return f"{MQTT_TOPIC_PREFIX}/telemetry"


def process_message_queue(client):
    """Process messages from the queue and publish to broker."""
    while True:
        try:
            message = message_queue.get(timeout=1.0)  # Wait up to 1 second for a message
            if is_connected.is_set():
                topic = get_topic_for_message(message)
                payload = json.dumps(message)
                
                try:
                    result = client.publish(topic, payload, qos=1)
                    result.wait_for_publish(timeout=5.0)
                    
                    # Log based on message type
                    if 'machine_id' in message:
                        print(f"  → {message['machine_id']}: {message.get('status', 'unknown')} [{topic}]")
                    elif 'event_type' in message:
                        print(f"  → {message['event_type']}: {message.get('order_id', 'unknown')} [{topic}]")
                    
                except Exception as e:
                    print(f"✗ Error publishing message: {e}")
                    with stats_lock:
                        stats['messages_failed'] += 1
                    # Put message back in queue for retry
                    try:
                        message_queue.put_nowait(message)
                    except queue.Full:
                        print("  Queue full, message dropped")
            else:
                # If not connected, put message back in queue
                try:
                    message_queue.put_nowait(message)
                except queue.Full:
                    print("  Queue full while disconnected, message dropped")
                    with stats_lock:
                        stats['messages_failed'] += 1
                time.sleep(1)  # Wait before retrying
                
        except queue.Empty:
            continue  # No messages to process
        except Exception as e:
            print(f"✗ Error in message processor: {e}")
            time.sleep(1)


def print_statistics():
    """Print periodic statistics."""
    while True:
        time.sleep(30)  # Print stats every 30 seconds
        with stats_lock:
            uptime = (datetime.utcnow() - stats['start_time']).total_seconds()
            rate = stats['messages_sent'] / uptime if uptime > 0 else 0
            
            print("\n" + "=" * 60)
            print(f"📊 Statistics (Uptime: {uptime:.0f}s)")
            print(f"   Messages Sent: {stats['messages_sent']}")
            print(f"   Messages Failed: {stats['messages_failed']}")
            print(f"   Queue Depth: {message_queue.qsize()}")
            print(f"   Message Rate: {rate:.2f} msg/sec")
            print("=" * 60 + "\n")


def main():
    print("=" * 70)
    print("🏭 Edge MQTT Simulator - Azure IoT Operations")
    print(f"   Authentication Method: {AUTH_METHOD}")
    print("=" * 70)
    
    # Initialize message generator
    print("\n📋 Initializing message generator...")
    try:
        generator = FactoryMessageGenerator(MESSAGE_CONFIG_PATH)
        base_interval = generator.get_base_interval()
        print(f"✓ Message generator initialized (interval: {base_interval}s)")
        print(f"  Machines configured: {len(generator.machine_states)}")
    except Exception as e:
        print(f"✗ Error initializing message generator: {e}")
        return
    
    # Create MQTT client
    print("\n🔌 Initializing MQTT client...")
    client = mqtt.Client(
        client_id=MQTT_CLIENT_ID,
        protocol=mqtt.MQTTv5,
        transport="tcp"
    )
    
    # Configure TLS for encrypted connection
    print("🔒 Setting up TLS connection...")
    client.tls_set(
        ca_certs=None,  # Don't verify server cert (self-signed in cluster)
        cert_reqs=ssl.CERT_NONE,
        tls_version=ssl.PROTOCOL_TLS_CLIENT,
        ciphers=None
    )
    client.tls_insecure_set(True)
    print("✓ TLS configured (encrypted connection, no server verification)")
    
    # Configure authentication
    connect_properties = None
    
    if AUTH_METHOD == 'K8S-SAT':
        print("\n🔑 Configuring ServiceAccountToken (K8S-SAT) authentication...")
        token = get_sat_token()
        if not token:
            print("✗ Cannot connect without SAT token")
            return
        
        connect_properties = mqtt.Properties(mqtt.PacketTypes.CONNECT)
        connect_properties.AuthenticationMethod = 'K8S-SAT'
        connect_properties.AuthenticationData = token.encode('utf-8')
        
        print("✓ K8S-SAT authentication configured")
        print(f"  Token length: {len(token)} characters")
    else:
        print(f"\n⚠ Warning: Unknown authentication method '{AUTH_METHOD}'")
    
    # Set callbacks
    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_publish = on_publish
    
    # Enable automatic reconnection
    client.reconnect_delay_set(min_delay=1, max_delay=60)
    
    # Start message processing thread
    print("\n🧵 Starting message processor thread...")
    message_processor = threading.Thread(
        target=process_message_queue,
        args=(client,),
        daemon=True
    )
    message_processor.start()
    
    # Start statistics thread
    stats_thread = threading.Thread(
        target=print_statistics,
        daemon=True
    )
    stats_thread.start()
    
    # Connect to broker
    print(f"\n🌐 Connecting to MQTT broker {MQTT_BROKER}:{MQTT_PORT}...")
    try:
        client.connect(MQTT_BROKER, MQTT_PORT, keepalive=60, properties=connect_properties)
        client.loop_start()  # Start network loop in separate thread
        
        print("⏳ Waiting for connection to establish...")
        time.sleep(2)
        
    except Exception as e:
        print(f"✗ Error connecting to MQTT broker: {e}")
        return

    # Main message generation loop
    print(f"\n{'=' * 70}")
    print(f"🏭 Factory simulation started")
    print(f"   Topic Prefix: {MQTT_TOPIC_PREFIX}")
    print(f"   Base Interval: {base_interval}s")
    print(f"{'=' * 70}\n")
    
    message_batch = 0
    last_connect_attempt = time.time()  # Initial connect was just made
    reconnect_backoff = 30  # Seconds before first reconnect retry
    try:
        while True:
            # Wait for connection
            if not is_connected.is_set():
                now = time.time()
                if now - last_connect_attempt >= reconnect_backoff:
                    last_connect_attempt = now
                    print(f"🔄 Connection lost — reconnecting with fresh SAT token...")
                    try:
                        if AUTH_METHOD == 'K8S-SAT':
                            token = get_sat_token()
                            if token:
                                fresh_props = mqtt.Properties(mqtt.PacketTypes.CONNECT)
                                fresh_props.AuthenticationMethod = 'K8S-SAT'
                                fresh_props.AuthenticationData = token.encode('utf-8')
                                client.connect(MQTT_BROKER, MQTT_PORT, keepalive=60, properties=fresh_props)
                            else:
                                print("✗ SAT token unavailable, will retry...")
                        else:
                            client.reconnect()
                    except Exception as e:
                        print(f"✗ Reconnect attempt failed: {e}")
                    reconnect_backoff = min(reconnect_backoff * 2, 120)
                else:
                    print("⏳ Waiting for connection before generating messages...")
                time.sleep(1)
                continue

            # Successful connection — reset backoff
            reconnect_backoff = 30
            
            message_batch += 1
            
            # Generate messages for this interval
            messages = generator.generate_messages()
            
            if messages:
                print(f"\n📦 Batch {message_batch}: Generated {len(messages)} messages")
                
                # Queue messages for publishing
                for message in messages:
                    try:
                        message_queue.put_nowait(message)
                        with stats_lock:
                            stats['messages_queued'] += 1
                    except queue.Full:
                        print("  ⚠ Queue full - dropping message")
                        with stats_lock:
                            stats['messages_failed'] += 1
            
            # Wait for next interval
            time.sleep(base_interval)
            
    except KeyboardInterrupt:
        print("\n\n🛑 Shutting down...")
    finally:
        # Print final statistics
        with stats_lock:
            print("\n" + "=" * 70)
            print("📊 Final Statistics")
            print(f"   Total Messages Sent: {stats['messages_sent']}")
            print(f"   Total Messages Failed: {stats['messages_failed']}")
            print(f"   Total Messages Queued: {stats['messages_queued']}")
            uptime = (datetime.utcnow() - stats['start_time']).total_seconds()
            print(f"   Total Uptime: {uptime:.0f}s")
            print("=" * 70)
        
        client.loop_stop()
        client.disconnect()
        print("✓ Disconnected from MQTT broker")


if __name__ == '__main__':
    main()
