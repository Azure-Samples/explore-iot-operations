"""
Edge Historian - Azure IoT Operations MQTT Message Historian
Subscribes to all MQTT topics and stores messages in PostgreSQL.
Provides HTTP API for querying historical data.
"""

import os
import sys
import json
import yaml
import time
import ssl
import logging
import threading
import signal
import re
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, Dict, Any, List

import paho.mqtt.client as mqtt
import psycopg2
from psycopg2 import pool
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse
import uvicorn

# =============================================================================
# Configuration
# =============================================================================

def load_config() -> Dict[str, Any]:
    """Load configuration from YAML file with environment variable overrides."""
    config_path = os.getenv('CONFIG_PATH', 'config.yaml')
    
    # Load YAML config
    if Path(config_path).exists():
        with open(config_path, 'r') as f:
            config = yaml.safe_load(f)
    else:
        # Default configuration if file doesn't exist
        config = {
            'mqtt': {
                'broker': 'aio-broker.azure-iot-operations.svc.cluster.local',
                'port': 18883,
                'topic': '#',
                'auth_method': 'K8S-SAT',
                'qos': 0,
                'keepalive': 60,
                'reconnect_delay': 5,
                'protocol_version': 5,
                'sat_token_path': '/var/run/secrets/tokens/broker-sat',
                'sat_audience': 'aio-internal',
                'client_id_prefix': 'historian'
            },
            'database': {
                'host': 'localhost',
                'port': 5432,
                'name': 'mqtt_historian',
                'user': 'historian',
                'password': '',
                'pool_size': 5,
                'pool_max_overflow': 10,
                'connection_timeout': 30
            },
            'http': {'host': '0.0.0.0', 'port': 8080, 'cors_enabled': False},
            'retention': {'hours': 24, 'cleanup_interval_seconds': 3600},
            'logging': {'level': 'INFO', 'format': 'json'}
        }
    
    # Environment variable overrides
    config['mqtt']['broker'] = os.getenv('MQTT_BROKER', config['mqtt']['broker'])
    config['mqtt']['port'] = int(os.getenv('MQTT_PORT', config['mqtt']['port']))
    config['mqtt']['auth_method'] = os.getenv('MQTT_AUTH_METHOD', config['mqtt']['auth_method'])
    config['mqtt']['sat_token_path'] = os.getenv('SAT_TOKEN_PATH', config['mqtt']['sat_token_path'])
    
    # Allow disabling MQTT for local testing
    config['mqtt']['enabled'] = os.getenv('MQTT_ENABLED', 'true').lower() in ('true', '1', 'yes')
    
    config['database']['host'] = os.getenv('POSTGRES_HOST', config['database']['host'])
    config['database']['port'] = int(os.getenv('POSTGRES_PORT', config['database']['port']))
    config['database']['name'] = os.getenv('POSTGRES_DB', config['database']['name'])
    config['database']['user'] = os.getenv('POSTGRES_USER', config['database']['user'])
    config['database']['password'] = os.getenv('POSTGRES_PASSWORD', config['database']['password'])
    
    config['logging']['level'] = os.getenv('LOG_LEVEL', config['logging']['level'])
    
    return config

# =============================================================================
# Logging Setup
# =============================================================================

def setup_logging(config: Dict[str, Any]):
    """Configure logging based on configuration."""
    log_level = getattr(logging, config['logging']['level'].upper(), logging.INFO)
    
    if config['logging']['format'] == 'json':
        logging.basicConfig(
            level=log_level,
            format='{"timestamp":"%(asctime)s","level":"%(levelname)s","message":"%(message)s"}',
            datefmt='%Y-%m-%dT%H:%M:%S'
        )
    else:
        logging.basicConfig(
            level=log_level,
            format='[%(asctime)s] %(levelname)s: %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S'
        )

logger = logging.getLogger(__name__)

# =============================================================================
# Utility Functions
# =============================================================================

def sanitize_string(text: str) -> str:
    """Replace special/unicode characters with underscores to prevent encoding issues.
    
    Keeps only ASCII alphanumeric, spaces, basic punctuation, and common symbols.
    """
    # Define allowed characters: alphanumeric, spaces, and basic punctuation
    # This regex keeps letters, numbers, spaces, and common safe punctuation
    allowed_pattern = r'[^a-zA-Z0-9\s\.\-_,:/\(\)\[\]{}@]'
    
    # Replace any character not in the allowed set with underscore
    sanitized = re.sub(allowed_pattern, '_', text)
    
    return sanitized

def sanitize_json_strings(obj: Any) -> Any:
    """Recursively sanitize all string values in a JSON-compatible object."""
    if isinstance(obj, str):
        return sanitize_string(obj)
    elif isinstance(obj, dict):
        return {sanitize_string(k) if isinstance(k, str) else k: 
                sanitize_json_strings(v) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [sanitize_json_strings(item) for item in obj]
    else:
        return obj

# =============================================================================
# Database Manager
# =============================================================================

class DatabaseManager:
    """Manages PostgreSQL connection pool and operations."""
    
    def __init__(self, config: Dict[str, Any]):
        self.config = config
        self.pool: Optional[pool.SimpleConnectionPool] = None
        self.stats = {
            'messages_stored': 0,
            'messages_cleaned': 0,
            'errors': 0
        }
        
    def initialize(self):
        """Initialize database connection pool and schema."""
        db_config = self.config['database']
        
        logger.info(f"Connecting to PostgreSQL at {db_config['host']}:{db_config['port']}")
        logger.info(f"Target database: {db_config['name']}")
        
        # Wait for PostgreSQL server to be ready and ensure database exists
        max_retries = 30
        for attempt in range(max_retries):
            try:
                # First, verify PostgreSQL server is accessible by connecting to postgres database
                test_conn = psycopg2.connect(
                    host=db_config['host'],
                    port=db_config['port'],
                    database='postgres',  # Connect to default postgres database first
                    user=db_config['user'],
                    password=db_config['password'],
                    connect_timeout=5
                )
                test_conn.autocommit = True
                
                # Check if target database exists, create if not
                with test_conn.cursor() as cursor:
                    cursor.execute("SELECT 1 FROM pg_database WHERE datname = %s", (db_config['name'],))
                    if not cursor.fetchone():
                        logger.info(f"Database '{db_config['name']}' does not exist, creating...")
                        cursor.execute(f"CREATE DATABASE {db_config['name']}")
                        logger.info(f"✓ Database '{db_config['name']}' created")
                    else:
                        logger.info(f"✓ Database '{db_config['name']}' exists")
                
                test_conn.close()
                
                # Now create connection pool to target database
                self.pool = pool.SimpleConnectionPool(
                    1,
                    db_config['pool_size'],
                    host=db_config['host'],
                    port=db_config['port'],
                    database=db_config['name'],
                    user=db_config['user'],
                    password=db_config['password'],
                    connect_timeout=db_config['connection_timeout']
                )
                
                logger.info("✓ Database connection pool created")
                
                # Initialize schema
                self._initialize_schema()
                return
                
            except psycopg2.OperationalError as e:
                if attempt < max_retries - 1:
                    logger.warning(f"Database not ready (attempt {attempt + 1}/{max_retries}): {e}, retrying...")
                    time.sleep(2)
                else:
                    logger.error(f"Failed to connect to database after {max_retries} attempts: {e}")
                    raise
    
    def _initialize_schema(self):
        """Initialize database schema from schema.sql."""
        schema_path = Path('schema.sql')
        if not schema_path.exists():
            logger.warning("schema.sql not found, skipping schema initialization")
            return
        
        conn = self.pool.getconn()
        try:
            with conn.cursor() as cursor:
                with open(schema_path, 'r') as f:
                    # Execute schema creation (excluding \d command)
                    schema_sql = f.read()
                    # Remove psql meta-commands
                    schema_sql = '\n'.join([line for line in schema_sql.split('\n') 
                                           if not line.strip().startswith('\\')])
                    cursor.execute(schema_sql)
                conn.commit()
                logger.info("✓ Database schema initialized")
        except Exception as e:
            logger.warning(f"Schema initialization warning (may already exist): {e}")
            conn.rollback()
        finally:
            self.pool.putconn(conn)
    
    def store_message(self, topic: str, payload: Any, qos: int):
        """Store MQTT message in database."""
        conn = self.pool.getconn()
        try:
            with conn.cursor() as cursor:
                # Parse payload if it's JSON
                if isinstance(payload, bytes):
                    try:
                        payload_json = json.loads(payload.decode('utf-8'))
                    except (json.JSONDecodeError, UnicodeDecodeError):
                        payload_json = {"raw": payload.decode('utf-8', errors='ignore')}
                elif isinstance(payload, str):
                    try:
                        payload_json = json.loads(payload)
                    except json.JSONDecodeError:
                        payload_json = {"raw": payload}
                else:
                    payload_json = payload
                
                # Sanitize all string values to prevent unicode escape issues
                payload_json = sanitize_json_strings(payload_json)
                
                # Extract timestamp from payload if available
                msg_timestamp = payload_json.get('timestamp', datetime.utcnow().isoformat() + 'Z')
                
                cursor.execute(
                    """INSERT INTO mqtt_history (timestamp, topic, payload, qos) 
                       VALUES (%s, %s, %s, %s)""",
                    (msg_timestamp, topic, json.dumps(payload_json), qos)
                )
                conn.commit()
                self.stats['messages_stored'] += 1
                
                # Log summary every 100 messages
                if self.stats['messages_stored'] % 100 == 0:
                    logger.info(f"Stored {self.stats['messages_stored']} messages")
                    
        except Exception as e:
            logger.error(f"Error storing message: {e}")
            self.stats['errors'] += 1
            conn.rollback()
        finally:
            self.pool.putconn(conn)
    
    def get_last_value(self, topic: str) -> Optional[Dict[str, Any]]:
        """Get last known value for a topic."""
        conn = self.pool.getconn()
        try:
            with conn.cursor() as cursor:
                cursor.execute(
                    """SELECT timestamp, topic, payload, received_at 
                       FROM mqtt_history 
                       WHERE topic = %s 
                       ORDER BY timestamp DESC 
                       LIMIT 1""",
                    (topic,)
                )
                row = cursor.fetchone()
                if row:
                    return {
                        'timestamp': row[0].isoformat(),
                        'topic': row[1],
                        'payload': row[2],
                        'received_at': row[3].isoformat()
                    }
                return None
        finally:
            self.pool.putconn(conn)
    
    def query_messages(self, topic: Optional[str] = None, machine_id: Optional[str] = None,
                      start_time: Optional[datetime] = None, end_time: Optional[datetime] = None,
                      limit: int = 100) -> List[Dict[str, Any]]:
        """Query messages with filters."""
        conn = self.pool.getconn()
        try:
            with conn.cursor() as cursor:
                query = "SELECT timestamp, topic, payload, received_at FROM mqtt_history WHERE 1=1"
                params = []
                
                if topic:
                    query += " AND topic = %s"
                    params.append(topic)
                
                if machine_id:
                    query += " AND machine_id = %s"
                    params.append(machine_id)
                
                if start_time:
                    query += " AND timestamp >= %s"
                    params.append(start_time)
                
                if end_time:
                    query += " AND timestamp <= %s"
                    params.append(end_time)
                
                query += " ORDER BY timestamp DESC LIMIT %s"
                params.append(limit)
                
                cursor.execute(query, params)
                results = []
                for row in cursor.fetchall():
                    results.append({
                        'timestamp': row[0].isoformat(),
                        'topic': row[1],
                        'payload': row[2],
                        'received_at': row[3].isoformat()
                    })
                return results
        finally:
            self.pool.putconn(conn)
    
    def get_stats(self) -> Dict[str, Any]:
        """Get database statistics."""
        conn = self.pool.getconn()
        try:
            with conn.cursor() as cursor:
                cursor.execute("""
                    SELECT 
                        COUNT(*) as total_messages,
                        COUNT(DISTINCT topic) as unique_topics,
                        MIN(timestamp) as oldest_message,
                        MAX(timestamp) as newest_message
                    FROM mqtt_history
                """)
                row = cursor.fetchone()
                
                cursor.execute("SELECT pg_database_size(current_database()) / (1024*1024) as size_mb")
                size_row = cursor.fetchone()
                
                return {
                    'total_messages': row[0] if row else 0,
                    'unique_topics': row[1] if row else 0,
                    'oldest_message': row[2].isoformat() if row and row[2] else None,
                    'newest_message': row[3].isoformat() if row and row[3] else None,
                    'database_size_mb': float(size_row[0]) if size_row else 0,
                    'messages_stored_session': self.stats['messages_stored'],
                    'errors': self.stats['errors']
                }
        finally:
            self.pool.putconn(conn)
    
    def cleanup_old_messages(self, retention_hours: int):
        """Delete messages older than retention period."""
        conn = self.pool.getconn()
        try:
            with conn.cursor() as cursor:
                cutoff_time = datetime.utcnow() - timedelta(hours=retention_hours)
                cursor.execute(
                    "DELETE FROM mqtt_history WHERE timestamp < %s",
                    (cutoff_time,)
                )
                deleted = cursor.rowcount
                conn.commit()
                self.stats['messages_cleaned'] += deleted
                if deleted > 0:
                    logger.info(f"✓ Cleaned up {deleted} messages older than {retention_hours} hours")
                return deleted
        except Exception as e:
            logger.error(f"Error during cleanup: {e}")
            conn.rollback()
            return 0
        finally:
            self.pool.putconn(conn)
    
    def close(self):
        """Close database connection pool."""
        if self.pool:
            self.pool.closeall()
            logger.info("Database connection pool closed")

# =============================================================================
# MQTT Subscriber
# =============================================================================

class MQTTSubscriber:
    """MQTT subscriber for Azure IoT Operations broker."""
    
    def __init__(self, config: Dict[str, Any], db_manager: DatabaseManager):
        self.config = config
        self.db_manager = db_manager
        self.client: Optional[mqtt.Client] = None
        self.connected = threading.Event()
        self.should_stop = threading.Event()
        self.connect_properties: Optional[mqtt.Properties] = None
        
    def initialize(self):
        """Initialize MQTT client with K8S-SAT authentication."""
        mqtt_config = self.config['mqtt']
        
        # Create MQTT v5 client
        client_id = f"{mqtt_config['client_id_prefix']}-{os.getpid()}"
        self.client = mqtt.Client(
            client_id=client_id,
            protocol=mqtt.MQTTv5
        )
        
        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect
        self.client.on_message = self._on_message
        
        # Configure K8S-SAT authentication
        if mqtt_config['auth_method'] == 'K8S-SAT':
            self._setup_sat_auth()
        else:
            logger.info("MQTT authentication disabled (local testing mode)")
        
        # Configure TLS (required for AIO broker, optional for local testing)
        if mqtt_config['port'] == 18883 or mqtt_config.get('use_tls', False):
            self.client.tls_set(cert_reqs=ssl.CERT_NONE)
        
        logger.info(f"MQTT client initialized with ID: {client_id}")
    
    def _setup_sat_auth(self):
        """Configure ServiceAccountToken authentication."""
        mqtt_config = self.config['mqtt']
        token_path = Path(mqtt_config['sat_token_path'])
        
        # Skip SAT auth if token doesn't exist (local testing)
        if not token_path.exists():
            if mqtt_config['auth_method'] == 'K8S-SAT':
                logger.warning(f"SAT token not found at {token_path}, skipping authentication")
                logger.warning("For local testing, use MQTT_AUTH_METHOD=none")
            return
        
        token = token_path.read_text().strip()
        logger.info(f"✓ Read SAT token from {token_path} ({len(token)} chars)")
        
        # Set up MQTT v5 enhanced authentication
        self.connect_properties = mqtt.Properties(mqtt.PacketTypes.CONNECT)
        self.connect_properties.AuthenticationMethod = 'K8S-SAT'
        self.connect_properties.AuthenticationData = token.encode('utf-8')
    
    def _on_connect(self, client, userdata, flags, reason_code, properties):
        """Callback when connected to broker."""
        if hasattr(reason_code, 'value'):
            rc = reason_code.value
        else:
            rc = reason_code
        
        if rc == 0:
            mqtt_config = self.config['mqtt']
            logger.info(f"✓ Connected to MQTT broker at {mqtt_config['broker']}:{mqtt_config['port']}")
            
            # Subscribe to all topics
            topic = mqtt_config['topic']
            qos = mqtt_config['qos']
            client.subscribe(topic, qos=qos)
            logger.info(f"✓ Subscribed to topic: {topic} (QoS {qos})")
            
            self.connected.set()
        else:
            # Decode MQTT v5 reason codes
            reason_names = {
                128: "Unspecified error",
                129: "Malformed Packet",
                130: "Protocol Error",
                131: "Implementation specific error",
                132: "Unsupported Protocol Version",
                133: "Client Identifier not valid",
                134: "Bad User Name or Password / Not authorized",
                135: "Not authorized",
                136: "Server unavailable",
                137: "Server busy",
                138: "Banned",
                140: "Bad authentication method",
                144: "Topic Name invalid",
                149: "Packet too large",
                151: "Quota exceeded",
                153: "Payload format invalid",
                154: "Retain not supported",
                155: "QoS not supported",
                156: "Use another server",
                157: "Server moved",
                159: "Connection rate exceeded"
            }
            reason_msg = reason_names.get(rc, f"Unknown error code {rc}")
            logger.error(f"✗ Connection failed with code {rc}: {reason_msg}")
            if rc == 134:
                logger.error("  → Check: Is mqtt-client service account authorized in BrokerAuthorization?")
                logger.error("  → Check: Is SAT token mounted at /var/run/secrets/tokens/broker-sat?")
                logger.error("  → Check: Does audience match 'aio-internal'?")
            self.connected.clear()
    
    def _on_disconnect(self, client, userdata, reason_code, properties=None):
        """Callback when disconnected from broker."""
        if hasattr(reason_code, 'value'):
            rc = reason_code.value
        else:
            rc = reason_code
        
        self.connected.clear()
        if rc != 0:
            logger.warning(f"! Unexpected disconnect: code {rc}")
    
    def _on_message(self, client, userdata, msg):
        """Callback when message received."""
        try:
            # Store message in database
            self.db_manager.store_message(msg.topic, msg.payload, msg.qos)
        except Exception as e:
            logger.error(f"Error processing message from {msg.topic}: {e}")
    
    def connect(self):
        """Connect to MQTT broker."""
        mqtt_config = self.config['mqtt']
        logger.info(f"Connecting to MQTT broker at {mqtt_config['broker']}:{mqtt_config['port']}...")
        
        self.client.connect(
            mqtt_config['broker'],
            mqtt_config['port'],
            mqtt_config['keepalive'],
            properties=self.connect_properties
        )
        
        # Start network loop
        self.client.loop_start()
        
        # Wait for connection
        if self.connected.wait(timeout=30):
            logger.info("✓ MQTT connection established")
        else:
            raise TimeoutError("Failed to connect to MQTT broker within 30 seconds")
    
    def disconnect(self):
        """Disconnect from MQTT broker."""
        self.should_stop.set()
        if self.client:
            self.client.loop_stop()
            self.client.disconnect()
            logger.info("MQTT client disconnected")

# =============================================================================
# HTTP API (FastAPI)
# =============================================================================

app = FastAPI(
    title="Edge Historian API",
    description="MQTT message historian for Azure IoT Operations",
    version="1.0.0"
)

# Global references (initialized in main)
db_manager: Optional[DatabaseManager] = None
mqtt_subscriber: Optional[MQTTSubscriber] = None
app_config: Dict[str, Any] = {}

@app.get("/health")
async def health_check():
    """Health check endpoint for Kubernetes."""
    mqtt_connected = mqtt_subscriber.connected.is_set() if mqtt_subscriber else False
    db_connected = db_manager.pool is not None if db_manager else False
    
    stats = db_manager.get_stats() if db_manager else {}
    
    return {
        "status": "healthy" if (mqtt_connected and db_connected) else "degraded",
        "mqtt_connected": mqtt_connected,
        "db_connected": db_connected,
        "messages_stored": stats.get('messages_stored_session', 0),
        "timestamp": datetime.utcnow().isoformat() + 'Z'
    }

@app.get("/api/v1/last-value/{topic:path}")
async def get_last_value(topic: str):
    """Get last known value for a specific topic."""
    if not db_manager:
        raise HTTPException(status_code=503, detail="Database not initialized")
    
    result = db_manager.get_last_value(topic)
    if result:
        return result
    else:
        raise HTTPException(status_code=404, detail=f"No messages found for topic: {topic}")

@app.get("/api/v1/query")
async def query_messages(
    topic: Optional[str] = None,
    machine_id: Optional[str] = None,
    limit: int = Query(100, ge=1, le=1000)
):
    """Query historical messages with filters."""
    if not db_manager:
        raise HTTPException(status_code=503, detail="Database not initialized")
    
    results = db_manager.query_messages(
        topic=topic,
        machine_id=machine_id,
        limit=limit
    )
    
    return {
        "results": results,
        "count": len(results)
    }

@app.get("/api/v1/stats")
async def get_statistics():
    """Get database statistics."""
    if not db_manager:
        raise HTTPException(status_code=503, detail="Database not initialized")
    
    return db_manager.get_stats()

# =============================================================================
# Cleanup Task
# =============================================================================

def cleanup_task(config: Dict[str, Any], db_mgr: DatabaseManager, stop_event: threading.Event):
    """Background task to cleanup old messages."""
    retention_hours = config['retention']['hours']
    interval = config['retention']['cleanup_interval_seconds']
    
    logger.info(f"Cleanup task started (retention: {retention_hours}h, interval: {interval}s)")
    
    while not stop_event.is_set():
        try:
            # Sleep in short intervals to allow quick shutdown
            for _ in range(interval):
                if stop_event.is_set():
                    break
                time.sleep(1)
            
            if not stop_event.is_set():
                db_mgr.cleanup_old_messages(retention_hours)
                
        except Exception as e:
            logger.error(f"Error in cleanup task: {e}")
    
    logger.info("Cleanup task stopped")

# =============================================================================
# Main Application
# =============================================================================

def signal_handler(signum, frame):
    """Handle shutdown signals."""
    logger.info(f"Received signal {signum}, initiating shutdown...")
    global stop_event
    stop_event.set()

def main():
    """Main application entry point."""
    global db_manager, mqtt_subscriber, app_config, stop_event
    
    # Load configuration
    app_config = load_config()
    setup_logging(app_config)
    
    logger.info("=" * 70)
    logger.info("Edge Historian - Azure IoT Operations MQTT Message Historian")
    logger.info("=" * 70)
    
    # Signal handlers
    stop_event = threading.Event()
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    try:
        # Initialize database
        logger.info("\n[1/3] Initializing database...")
        db_manager = DatabaseManager(app_config)
        db_manager.initialize()
        
        # Initialize MQTT (can be disabled for local testing)
        if app_config['mqtt'].get('enabled', True):
            logger.info("\n[2/3] Initializing MQTT subscriber...")
            mqtt_subscriber = MQTTSubscriber(app_config, db_manager)
            mqtt_subscriber.initialize()
            mqtt_subscriber.connect()
        else:
            logger.warning("\n[2/3] MQTT subscriber DISABLED (local testing mode)")
            logger.warning("Set MQTT_ENABLED=true to enable MQTT")
        
        # Start cleanup task
        logger.info("\n[3/3] Starting cleanup task...")
        cleanup_thread = threading.Thread(
            target=cleanup_task,
            args=(app_config, db_manager, stop_event),
            daemon=True
        )
        cleanup_thread.start()
        
        # Start HTTP API
        logger.info("\n✓ All systems initialized")
        logger.info(f"✓ HTTP API starting on {app_config['http']['host']}:{app_config['http']['port']}")
        logger.info("=" * 70)
        
        # Run FastAPI with uvicorn
        uvicorn.run(
            app,
            host=app_config['http']['host'],
            port=app_config['http']['port'],
            log_level=app_config['logging']['level'].lower()
        )
        
    except KeyboardInterrupt:
        logger.info("\nShutdown initiated by user")
    except Exception as e:
        logger.error(f"Fatal error: {e}", exc_info=True)
        sys.exit(1)
    finally:
        # Cleanup
        logger.info("\nShutting down...")
        stop_event.set()
        
        if mqtt_subscriber:
            mqtt_subscriber.disconnect()
        
        if db_manager:
            db_manager.close()
        
        logger.info("Shutdown complete")

if __name__ == "__main__":
    main()
