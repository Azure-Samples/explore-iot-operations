-- Edge Historian Database Schema
-- PostgreSQL schema for MQTT message history storage

-- Drop existing objects if they exist (for clean reinstalls)
DROP TABLE IF EXISTS mqtt_history CASCADE;

-- Main history table
CREATE TABLE mqtt_history (
    id BIGSERIAL PRIMARY KEY,
    timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    topic TEXT NOT NULL,
    payload JSONB NOT NULL,
    qos INTEGER DEFAULT 0,
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- Extracted fields for faster queries (optional optimization)
    machine_id TEXT GENERATED ALWAYS AS (payload->>'machine_id') STORED,
    status TEXT GENERATED ALWAYS AS (payload->>'status') STORED
);

-- Index for fast topic lookups (most common query pattern)
CREATE INDEX idx_topic_timestamp ON mqtt_history(topic, timestamp DESC);

-- Index for timestamp-based queries and cleanup
CREATE INDEX idx_timestamp ON mqtt_history(timestamp DESC);

-- Index for machine-specific queries (common pattern for factory data)
CREATE INDEX idx_machine_timestamp ON mqtt_history(machine_id, timestamp DESC) 
WHERE machine_id IS NOT NULL;

-- Index for JSONB queries (for complex payload searches)
CREATE INDEX idx_payload_gin ON mqtt_history USING GIN(payload);

-- Grant permissions (if using specific user, adjust as needed)
-- GRANT ALL PRIVILEGES ON TABLE mqtt_history TO historian;
-- GRANT USAGE, SELECT ON SEQUENCE mqtt_history_id_seq TO historian;

-- Display table info
\d mqtt_history
