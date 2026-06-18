#!/usr/bin/env python3
"""
ARM Template Generator for Spaceship Factory Assets
Creates ARM templates for Azure IoT Operations Device Registry namespace assets
"""
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

class SpaceshipFactoryARMGenerator:
    """Generates ARM templates for spaceship factory assets"""
    
    def __init__(self, resource_group: str, instance_name: str):
        self.resource_group = resource_group
        self.instance_name = instance_name
        self.device_name = "spaceship-factory-device"
        self.endpoint_name = "spaceship-factory-endpoint"
        
        # Get the current directory for output
        self.output_dir = Path(__file__).parent / "arm_templates"
        self.output_dir.mkdir(exist_ok=True)
        
    def _find_azure_cli(self) -> Optional[str]:
        """Find Azure CLI executable path."""
        possible_paths = [
            r"C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd",
            r"C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin\az.cmd",
            "az.cmd",
            "az"
        ]
        
        for path in possible_paths:
            try:
                result = subprocess.run(
                    [path, "--version"], 
                    capture_output=True, 
                    text=True, 
                    check=True
                )
                if result.returncode == 0:
                    return path
            except (subprocess.SubprocessError, FileNotFoundError):
                continue
        return None

    def _load_asset_definitions(self) -> Dict[str, Any]:
        """Define asset configurations based on message structure."""
        return {
            "cnc_machines": {
                "asset_type": "cnc-machine",
                "count": 5,
                "description": "CNC Machine for precision part manufacturing",
                "data_points": [
                    {"source": "machine_id", "name": "machine_identifier", "description": "Unique machine ID"},
                    {"source": "status", "name": "machine_status", "description": "Current operational status"},
                    {"source": "cycle_time", "name": "operation_cycle_time", "description": "Manufacturing cycle time (seconds)"},
                    {"source": "quality", "name": "part_quality", "description": "Quality assessment of manufactured part"},
                    {"source": "part_type", "name": "manufactured_part_type", "description": "Type of part being manufactured"},
                    {"source": "part_id", "name": "part_identifier", "description": "Unique part identifier"},
                    {"source": "station_id", "name": "station_location", "description": "Manufacturing station ID"}
                ],
                "dataset": {
                    "name": "cnc_telemetry",
                    "topic": "azure-iot-operations/data/cnc-machines",
                    "sampling_interval": 1000,
                    "queue_size": 1
                }
            },
            "3d_printers": {
                "asset_type": "printer-3d",
                "count": 8,
                "description": "3D Printer for additive manufacturing",
                "data_points": [
                    {"source": "machine_id", "name": "machine_identifier", "description": "Unique machine ID"},
                    {"source": "status", "name": "machine_status", "description": "Current operational status"},
                    {"source": "progress", "name": "print_progress", "description": "Print completion percentage"},
                    {"source": "quality", "name": "part_quality", "description": "Quality assessment of printed part"},
                    {"source": "part_type", "name": "printed_part_type", "description": "Type of part being printed"},
                    {"source": "part_id", "name": "part_identifier", "description": "Unique part identifier"},
                    {"source": "station_id", "name": "station_location", "description": "3D printer station ID"}
                ],
                "dataset": {
                    "name": "3dprinter_telemetry",
                    "topic": "azure-iot-operations/data/3d-printers",
                    "sampling_interval": 1000,
                    "queue_size": 1
                }
            },
            "welding_stations": {
                "asset_type": "welding",
                "count": 4,
                "description": "Welding Station for assembly operations",
                "data_points": [
                    {"source": "machine_id", "name": "machine_identifier", "description": "Unique machine ID"},
                    {"source": "status", "name": "machine_status", "description": "Current operational status"},
                    {"source": "last_cycle_time", "name": "weld_cycle_time", "description": "Last welding cycle time (seconds)"},
                    {"source": "quality", "name": "weld_quality", "description": "Weld quality assessment"},
                    {"source": "assembly_type", "name": "assembly_type", "description": "Type of assembly being welded"},
                    {"source": "assembly_id", "name": "assembly_identifier", "description": "Unique assembly identifier"},
                    {"source": "station_id", "name": "station_location", "description": "Welding station ID"}
                ],
                "dataset": {
                    "name": "welding_telemetry",
                    "topic": "azure-iot-operations/data/welding-stations",
                    "sampling_interval": 1000,
                    "queue_size": 1
                }
            },
            "painting_booths": {
                "asset_type": "painting",
                "count": 3,
                "description": "Painting Booth for surface finishing",
                "data_points": [
                    {"source": "machine_id", "name": "machine_identifier", "description": "Unique machine ID"},
                    {"source": "status", "name": "machine_status", "description": "Current operational status"},
                    {"source": "cycle_time", "name": "paint_cycle_time", "description": "Paint cycle time (seconds)"},
                    {"source": "quality", "name": "paint_quality", "description": "Paint quality assessment"},
                    {"source": "color", "name": "paint_color", "description": "Paint color applied"},
                    {"source": "part_id", "name": "part_identifier", "description": "Unique part identifier"},
                    {"source": "station_id", "name": "station_location", "description": "Painting booth ID"}
                ],
                "dataset": {
                    "name": "painting_telemetry",
                    "topic": "azure-iot-operations/data/painting-booths",
                    "sampling_interval": 1000,
                    "queue_size": 1
                }
            },
            "testing_rigs": {
                "asset_type": "testing",
                "count": 2,
                "description": "Testing Rig for quality assurance",
                "data_points": [
                    {"source": "machine_id", "name": "machine_identifier", "description": "Unique machine ID"},
                    {"source": "status", "name": "machine_status", "description": "Current operational status"},
                    {"source": "test_result", "name": "test_result", "description": "Test outcome (pass/fail)"},
                    {"source": "issues_found", "name": "defect_count", "description": "Number of issues found"},
                    {"source": "target_type", "name": "test_target_type", "description": "Type of item being tested"},
                    {"source": "target_id", "name": "target_identifier", "description": "Unique target identifier"},
                    {"source": "station_id", "name": "station_location", "description": "Testing station ID"}
                ],
                "dataset": {
                    "name": "testing_telemetry",
                    "topic": "azure-iot-operations/data/testing-rigs",
                    "sampling_interval": 1000,
                    "queue_size": 1
                }
            }
        }

    def create_arm_template_base(self) -> Dict[str, Any]:
        """Create the base ARM template structure."""
        return {
            "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
            "contentVersion": "1.0.0.0",
            "metadata": {
                "description": "ARM template for Spaceship Factory Asset deployment",
                "generatedOn": str(datetime.now(timezone.utc)),
            },
            "parameters": {
                "namespaceName": {
                    "type": "string",
                    "defaultValue": self.instance_name,
                    "metadata": {"description": "Name of the Device Registry namespace"}
                },
                "deviceName": {
                    "type": "string",
                    "defaultValue": self.device_name,
                    "metadata": {"description": "Name of the device to reference"}
                },
                "endpointName": {
                    "type": "string", 
                    "defaultValue": self.endpoint_name,
                    "metadata": {"description": "Name of the endpoint on the device"}
                },
                "location": {
                    "type": "string",
                    "defaultValue": "[resourceGroup().location]",
                    "metadata": {"description": "Location for all resources"}
                },
                "customLocationId": {
                    "type": "string",
                    "metadata": {"description": "The resource ID of the custom location"}
                }
            },
            "resources": []
        }

    def create_asset_resource(self, asset_name: str, asset_config: Dict[str, Any]) -> Dict[str, Any]:
        """Create a single asset resource definition."""
        
        # Create data points array
        data_points_array = []
        for data_point in asset_config["data_points"]:
            data_point_def = {
                "name": data_point["name"],
                "dataSource": data_point["source"],
                "dataPointConfiguration": json.dumps({
                    "publishingInterval": asset_config["dataset"]["sampling_interval"],
                    "queueSize": asset_config["dataset"]["queue_size"]
                }, separators=(",", ":"))
            }
            data_points_array.append(data_point_def)

        # Create the asset resource
        resource = {
            "type": "Microsoft.DeviceRegistry/namespaces/assets",
            "apiVersion": "2025-10-01",
            "name": f"[concat(parameters('namespaceName'), '/', '{asset_name}')]",
            "location": "[parameters('location')]",
            "extendedLocation": {
                "type": "CustomLocation",
                "name": "[parameters('customLocationId')]"
            },
            "properties": {
                "deviceRef": {
                    "deviceName": "[parameters('deviceName')]",
                    "endpointName": "[parameters('endpointName')]"
                },
                "enabled": True,
                "externalAssetId": asset_name,
                "displayName": asset_name,
                "description": asset_config["description"],
                "attributes": {
                    "assetType": asset_config["asset_type"],
                    "dataPointCount": str(len(data_points_array)),
                    "generatedOn": str(datetime.now(timezone.utc))
                },
                "datasets": [
                    {
                        "name": asset_config["dataset"]["name"],
                        "datasetConfiguration": json.dumps({
                            "publishingInterval": asset_config["dataset"]["sampling_interval"],
                            "queueSize": asset_config["dataset"]["queue_size"]
                        }, separators=(",", ":")),
                        "dataPoints": data_points_array,
                        "destinations": [
                            {
                                "target": "Mqtt",
                                "configuration": {
                                    "qos": "Qos1",
                                    "retain": "Never",
                                    "topic": asset_config["dataset"]["topic"],
                                    "ttl": 3600
                                }
                            }
                        ]
                    }
                ]
            }
        }
        
        return resource

    def generate_template(self) -> str:
        """Generate ARM template for all spaceship factory assets."""
        print("🚀 Generating ARM template for Spaceship Factory Assets...")
        
        # Load asset definitions
        asset_definitions = self._load_asset_definitions()
        
        # Create base template
        template = self.create_arm_template_base()
        
        # Generate all assets
        total_assets = 0
        for asset_type, config in asset_definitions.items():
            for i in range(1, config["count"] + 1):
                asset_name = f"spaceship-factory-{asset_type.replace('_', '-')}-{i:02d}"
                asset_resource = self.create_asset_resource(asset_name, config)
                template["resources"].append(asset_resource)
                total_assets += 1
                print(f"  ✅ Added asset definition: {asset_name}")
        
        # Update metadata
        template["metadata"]["assetCount"] = total_assets
        
        # Save template
        template_file = self.output_dir / "spaceship_factory_assets.json"
        with open(template_file, 'w', encoding='utf-8') as f:
            json.dump(template, f, indent=2)
        
        print(f"✅ Generated ARM template: {template_file}")
        print(f"📊 Total assets defined: {total_assets}")
        
        return str(template_file)

    def get_custom_location_id(self) -> Optional[str]:
        """Get the custom location ID from an existing asset."""
        az_cmd = self._find_azure_cli()
        if not az_cmd:
            return None
            
        try:
            # Try to get from any existing asset using generic Azure CLI
            result = subprocess.run([
                az_cmd, "resource", "list",
                "--resource-group", self.resource_group,
                "--resource-type", "Microsoft.DeviceRegistry/namespaces/assets",
                "--query", "[0].extendedLocation.name",
                "--output", "tsv"
            ], capture_output=True, text=True, check=True)
            
            custom_location_id = result.stdout.strip()
            if custom_location_id and custom_location_id != "None":
                return custom_location_id
                
        except subprocess.CalledProcessError:
            pass
                
        return None

    def deploy_template(self, template_file: str) -> bool:
        """Deploy the ARM template using Azure CLI."""
        print(f"\n🚀 Deploying ARM template: {template_file}")
        
        # Find Azure CLI
        az_cmd = self._find_azure_cli()
        if not az_cmd:
            print("❌ Azure CLI not found")
            return False
            
        # Get custom location ID
        custom_location_id = self.get_custom_location_id()
        if not custom_location_id:
            print("❌ Could not determine custom location ID")
            return False
            
        print(f"✅ Using custom location: {custom_location_id}")
        
        # Create deployment command
        deployment_name = f"spaceship-factory-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
        deploy_cmd = [
            az_cmd, "deployment", "group", "create",
            "--resource-group", self.resource_group,
            "--name", deployment_name,
            "--template-file", template_file,
            "--parameters", f"customLocationId={custom_location_id}",
            "--mode", "Incremental"
        ]
        
        try:
            print(f"Running deployment: {deployment_name}")
            result = subprocess.run(
                deploy_cmd,
                capture_output=True,
                text=True,
                check=True
            )
            
            print("✅ ARM template deployed successfully!")
            return True
            
        except subprocess.CalledProcessError as e:
            print(f"❌ Deployment failed: {e}")
            if e.stderr:
                print(f"Error details: {e.stderr}")
            return False

    def create_and_deploy_assets(self) -> bool:
        """Generate ARM template and deploy assets."""
        try:
            # Generate ARM template
            template_file = self.generate_template()
            
            # Deploy template
            success = self.deploy_template(template_file)
            
            if success:
                print("\n🎉 All spaceship factory assets created successfully!")
                print(f"📁 ARM template saved: {template_file}")
                return True
            else:
                print("\n❌ Asset deployment failed")
                return False
                
        except Exception as e:
            print(f"❌ Error: {e}")
            return False

def main():
    """Main entry point."""
    import sys
    
    if len(sys.argv) != 3:
        print("Usage: python arm_asset_creation.py <resource_group> <instance_name>")
        print("Example: python arm_asset_creation.py 'IoT-Operations-Work-Edge-bel-aio' 'bel-aio-work-cluster-aio'")
        sys.exit(1)
    
    resource_group = sys.argv[1]
    instance_name = sys.argv[2]
    
    # Create and deploy assets
    generator = SpaceshipFactoryARMGenerator(resource_group, instance_name)
    success = generator.create_and_deploy_assets()
    
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()