"""
Message generation module for Spaceship Factory Simulation.
Manages all message types, structures, and cadence based on YAML configuration.
"""

import random
import yaml
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Any, Optional


class FactoryMessageGenerator:
    """Generates realistic factory telemetry messages based on configuration."""
    
    def __init__(self, config_path: str = "message_structure.yaml"):
        """Initialize the message generator with configuration."""
        self.config = self._load_config(config_path)
        self.global_config = self.config.get('global', {})
        self.message_types = self.config.get('message_types', {})
        
        # State tracking for machines
        self.machine_states = {}
        self.part_counters = {}
        self.assembly_counters = {}
        self.order_counter = 0
        self.pending_orders = []  # Track orders for dispatch
        
        # Initialize machine instances
        self._initialize_machines()
        
    def _load_config(self, config_path: str) -> Dict:
        """Load YAML configuration file."""
        config_file = Path(config_path)
        if not config_file.exists():
            raise FileNotFoundError(f"Configuration file not found: {config_path}")
        
        with open(config_file, 'r') as f:
            return yaml.safe_load(f)
    
    def _initialize_machines(self):
        """Initialize state for all machines based on configuration."""
        machine_counts = self.global_config.get('machine_counts', {})
        
        # Initialize CNC machines
        for i in range(1, machine_counts.get('cnc', 0) + 1):
            machine_id = f"CNC-{i:02d}"
            self.machine_states[machine_id] = {
                'type': 'cnc_machine',
                'status': 'idle',
                'current_part': None,
                'part_count': 0
            }
        
        # Initialize 3D printers
        for i in range(1, machine_counts.get('printer_3d', 0) + 1):
            machine_id = f"3DP-{i:02d}"
            self.machine_states[machine_id] = {
                'type': 'printer_3d',
                'status': 'idle',
                'current_part': None,
                'progress': 0.0,
                'part_count': 0
            }
        
        # Initialize welding stations
        for i in range(1, machine_counts.get('welding', 0) + 1):
            machine_id = f"WELD-{i:02d}"
            self.machine_states[machine_id] = {
                'type': 'welding',
                'status': 'idle',
                'current_assembly': None,
                'assembly_count': 0
            }
        
        # Initialize painting booths
        for i in range(1, machine_counts.get('painting', 0) + 1):
            machine_id = f"PAINT-{i:02d}"
            self.machine_states[machine_id] = {
                'type': 'painting',
                'status': 'idle',
                'part_count': 0
            }
        
        # Initialize testing rigs
        for i in range(1, machine_counts.get('testing', 0) + 1):
            machine_id = f"TEST-{i:02d}"
            self.machine_states[machine_id] = {
                'type': 'testing',
                'status': 'idle',
                'test_count': 0
            }
    
    def _weighted_choice(self, distribution: Dict[str, float]) -> str:
        """Select a value based on weighted distribution."""
        choices = list(distribution.keys())
        weights = list(distribution.values())
        return random.choices(choices, weights=weights, k=1)[0]
    
    def _get_station_id(self, machine_type: str, machine_num: int) -> str:
        """Generate station ID based on machine type and number."""
        config = self.message_types.get(machine_type, {})
        pattern = config.get('station_pattern', 'STATION-{station}')
        
        if '{line}' in pattern:
            lines = config.get('lines', [1])
            line = lines[(machine_num - 1) % len(lines)]
            return pattern.format(line=line)
        elif '{station}' in pattern:
            stations = config.get('stations', [1])
            station = stations[(machine_num - 1) % len(stations)]
            return pattern.format(station=station)
        
        return f"STATION-{machine_num}"
    
    def generate_cnc_message(self, machine_id: str) -> Dict[str, Any]:
        """Generate CNC machine telemetry message."""
        config = self.message_types['cnc_machine']
        state = self.machine_states[machine_id]
        
        # Update status
        status = self._weighted_choice(config['status_distribution'])
        state['status'] = status
        
        message = {
            'timestamp': datetime.utcnow().isoformat() + 'Z',
            'machine_id': machine_id,
            'station_id': self._get_station_id('cnc_machine', int(machine_id.split('-')[1])),
            'status': status
        }
        
        # If running, generate part information
        if status == 'running':
            if state['current_part'] is None:
                # Start new part
                state['part_count'] += 1
                part_type = random.choice(config['part_types'])
                state['current_part'] = {
                    'type': part_type,
                    'id': f"{part_type[:2].upper()}-{state['part_count']}"
                }
            
            part = state['current_part']
            cycle_time = random.uniform(*config['cycle_time_range'])
            quality = self._weighted_choice(config['quality_distribution'])
            
            message.update({
                'part_type': part['type'],
                'part_id': part['id'],
                'cycle_time': round(cycle_time, 1),
                'quality': quality
            })
            
            # Complete the part
            state['current_part'] = None
        else:
            message.update({
                'part_type': None,
                'part_id': None,
                'cycle_time': None,
                'quality': None
            })
        
        return message
    
    def generate_3d_printer_message(self, machine_id: str) -> Dict[str, Any]:
        """Generate 3D printer telemetry message."""
        config = self.message_types['printer_3d']
        state = self.machine_states[machine_id]
        
        # Update status
        status = self._weighted_choice(config['status_distribution'])
        state['status'] = status
        
        message = {
            'timestamp': datetime.utcnow().isoformat() + 'Z',
            'machine_id': machine_id,
            'station_id': self._get_station_id('printer_3d', int(machine_id.split('-')[1])),
            'status': status
        }
        
        # If running, track progress
        if status == 'running':
            if state['current_part'] is None:
                # Start new print
                state['part_count'] += 1
                part_type = random.choice(config['part_types'])
                state['current_part'] = {
                    'type': part_type,
                    'id': f"{part_type[:2].upper()}-{state['part_count']}"
                }
                state['progress'] = 0.0
            
            part = state['current_part']
            
            # Update progress
            state['progress'] = min(1.0, state['progress'] + config.get('progress_increment', 0.05))
            
            # Determine quality if completed
            quality = None
            if state['progress'] >= 1.0:
                quality = self._weighted_choice(config['quality_distribution'])
                state['current_part'] = None
                state['progress'] = 0.0
            
            message.update({
                'part_type': part['type'],
                'part_id': part['id'],
                'progress': round(state['progress'], 2),
                'quality': quality
            })
        else:
            message.update({
                'part_type': None,
                'part_id': None,
                'progress': 0.0,
                'quality': None
            })
        
        return message
    
    def generate_welding_message(self, machine_id: str) -> Dict[str, Any]:
        """Generate welding station telemetry message."""
        config = self.message_types['welding']
        state = self.machine_states[machine_id]
        
        # Update status
        status = self._weighted_choice(config['status_distribution'])
        state['status'] = status
        
        message = {
            'timestamp': datetime.utcnow().isoformat() + 'Z',
            'machine_id': machine_id,
            'station_id': self._get_station_id('welding', int(machine_id.split('-')[1])),
            'status': status
        }
        
        # Generate assembly info
        if status == 'running':
            state['assembly_count'] += 1
            assembly_type = random.choice(config['assembly_types'])
            assembly_id = f"A-{state['assembly_count']}"
            cycle_time = random.uniform(*config['cycle_time_range'])
            quality = self._weighted_choice(config['quality_distribution'])
            
            message.update({
                'assembly_id': assembly_id,
                'assembly_type': assembly_type,
                'last_cycle_time': round(cycle_time, 1),
                'quality': quality
            })
        else:
            # Show last completed assembly when idle
            message.update({
                'assembly_id': f"A-{state['assembly_count']}" if state['assembly_count'] > 0 else None,
                'assembly_type': None,
                'last_cycle_time': None,
                'quality': None
            })
        
        return message
    
    def generate_painting_message(self, machine_id: str) -> Dict[str, Any]:
        """Generate painting booth telemetry message."""
        config = self.message_types['painting']
        state = self.machine_states[machine_id]
        
        # Update status
        status = self._weighted_choice(config['status_distribution'])
        state['status'] = status
        
        message = {
            'timestamp': datetime.utcnow().isoformat() + 'Z',
            'machine_id': machine_id,
            'station_id': self._get_station_id('painting', int(machine_id.split('-')[1])),
            'status': status
        }
        
        # Generate paint job info
        if status == 'running':
            state['part_count'] += 1
            part_id = f"Frame-{state['part_count']}"
            color = random.choice(config['colors'])
            cycle_time = random.uniform(*config['cycle_time_range'])
            quality = self._weighted_choice(config['quality_distribution'])
            
            message.update({
                'part_id': part_id,
                'color': color,
                'cycle_time': round(cycle_time, 1),
                'quality': quality
            })
        else:
            message.update({
                'part_id': None,
                'color': None,
                'cycle_time': None,
                'quality': None
            })
        
        return message
    
    def generate_testing_message(self, machine_id: str) -> Dict[str, Any]:
        """Generate testing rig telemetry message."""
        config = self.message_types['testing']
        state = self.machine_states[machine_id]
        
        # Update status
        status = self._weighted_choice(config['status_distribution'])
        state['status'] = status
        
        message = {
            'timestamp': datetime.utcnow().isoformat() + 'Z',
            'machine_id': machine_id,
            'station_id': self._get_station_id('testing', int(machine_id.split('-')[1])),
            'status': status
        }
        
        # Generate test results
        if status == 'testing':
            state['test_count'] += 1
            target_type = random.choice(config['target_types'])
            
            if target_type == 'FullSpaceship':
                target_id = f"Spaceship-{state['test_count']}"
            else:
                target_id = f"{target_type}-{state['test_count']}"
            
            test_result = self._weighted_choice(config['test_distribution'])
            issues_found = 0
            if test_result == 'fail':
                issues_found = random.randint(*config['issues_range'])
            
            message.update({
                'target_id': target_id,
                'target_type': target_type,
                'test_result': test_result,
                'issues_found': issues_found
            })
        else:
            message.update({
                'target_id': None,
                'target_type': None,
                'test_result': None,
                'issues_found': 0
            })
        
        return message
    
    def generate_customer_order(self) -> Optional[Dict[str, Any]]:
        """Generate customer order event."""
        config = self.message_types['customer_order']
        
        # Check if we should generate an order based on hourly rate
        orders_per_hour = config.get('orders_per_hour', 2)
        base_interval = self.global_config.get('base_interval', 1.0)
        probability = (orders_per_hour / 3600.0) * base_interval
        
        if random.random() > probability:
            return None
        
        self.order_counter += 1
        order_id = f"ORD-{self.order_counter:04d}"
        
        # Generate order items
        num_items = random.randint(1, 3)
        items = []
        
        for _ in range(num_items):
            product_type = random.choice(config['product_types'])
            quantity_range = config['quantity_ranges'].get(product_type, [1, 1])
            quantity = random.randint(*quantity_range)
            
            items.append({
                'product_type': product_type,
                'quantity': quantity
            })
        
        # Store order for potential dispatch
        self.pending_orders.append(order_id)
        
        return {
            'timestamp': datetime.utcnow().isoformat() + 'Z',
            'event_type': 'order_placed',
            'order_id': order_id,
            'items': items
        }
    
    def generate_dispatch(self) -> Optional[Dict[str, Any]]:
        """Generate dispatch event."""
        config = self.message_types['dispatch']
        
        # Check if we have pending orders
        if not self.pending_orders:
            return None
        
        # Check if we should generate a dispatch based on hourly rate
        dispatches_per_hour = config.get('dispatches_per_hour', 1.5)
        base_interval = self.global_config.get('base_interval', 1.0)
        probability = (dispatches_per_hour / 3600.0) * base_interval
        
        if random.random() > probability:
            return None
        
        # Dispatch the oldest order
        order_id = self.pending_orders.pop(0)
        
        return {
            'timestamp': datetime.utcnow().isoformat() + 'Z',
            'event_type': 'order_dispatched',
            'order_id': order_id,
            'destination': random.choice(config['destinations']),
            'carrier': random.choice(config['carriers'])
        }
    
    def generate_messages(self) -> List[Dict[str, Any]]:
        """Generate all messages for the current interval."""
        messages = []
        
        # Generate machine telemetry
        for machine_id, state in self.machine_states.items():
            machine_type = state['type']
            
            if not self.message_types.get(machine_type, {}).get('enabled', False):
                continue
            
            # Check frequency weight to determine if we generate a message
            frequency_weight = self.message_types[machine_type].get('frequency_weight', 1)
            if random.random() > (frequency_weight / 10.0):
                continue
            
            # Generate appropriate message type
            if machine_type == 'cnc_machine':
                messages.append(self.generate_cnc_message(machine_id))
            elif machine_type == 'printer_3d':
                messages.append(self.generate_3d_printer_message(machine_id))
            elif machine_type == 'welding':
                messages.append(self.generate_welding_message(machine_id))
            elif machine_type == 'painting':
                messages.append(self.generate_painting_message(machine_id))
            elif machine_type == 'testing':
                messages.append(self.generate_testing_message(machine_id))
        
        # Generate customer order (if applicable)
        if self.message_types.get('customer_order', {}).get('enabled', False):
            order_msg = self.generate_customer_order()
            if order_msg:
                messages.append(order_msg)
        
        # Generate dispatch event (if applicable)
        if self.message_types.get('dispatch', {}).get('enabled', False):
            dispatch_msg = self.generate_dispatch()
            if dispatch_msg:
                messages.append(dispatch_msg)
        
        return messages
    
    def get_base_interval(self) -> float:
        """Get the base interval for message generation."""
        return self.global_config.get('base_interval', 1.0)
