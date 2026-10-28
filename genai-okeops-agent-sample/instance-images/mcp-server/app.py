# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
#!/usr/bin/env python3
"""
OCI Instance MCP Server

A Model Context Protocol server for creating and managing Oracle Cloud Infrastructure instances.
"""

import os
import json
import ssl
import logging
import subprocess
import base64
from typing import Any, Dict, List, Optional
from dotenv import load_dotenv
import oci
import oci.generative_ai_agent_runtime
#from mcp.server.fastmcp import FastMCP
from fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
import random
import smtplib
from email.message import EmailMessage
import time
from datetime import datetime, timezone
from starlette.responses import JSONResponse
# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

load_dotenv()
__project__ = os.getenv("MCP_PROJECT_NAME", "oracle.oci-instance-mcp-server")
__version__ = os.getenv("MCP_VERSION", "0.1.0")

try:
    signer = oci.auth.signers.get_resource_principals_signer()
    config = {}
    logger.info("Using OCI Resource Principal for authentication")
except Exception:
    profile_name = os.getenv("OCI_CLI_PROFILE", "DEFAULT")
    config = oci.config.from_file(profile_name=profile_name)
    signer = None
    logger.info("Using OCI config profile %s for authentication", profile_name)

CLIENT_AUTH = {"signer": signer} if signer else {}

# Global variables to store OCI clients and config (STATIC)
compute_client = oci.core.ComputeClient(config, **CLIENT_AUTH)
storage_client = oci.core.BlockstorageClient(config, **CLIENT_AUTH)
identity_client = oci.identity.IdentityClient(config, **CLIENT_AUTH)
network_client = oci.core.VirtualNetworkClient(config, **CLIENT_AUTH)
os_mgmt_client = oci.os_management_hub.ManagedInstanceClient(config, **CLIENT_AUTH)
monitoring_client = oci.monitoring.MonitoringClient(config, **CLIENT_AUTH)
compute_instance_agent_client = oci.compute_instance_agent.ComputeInstanceAgentClient(config, **CLIENT_AUTH)
agent_runtime_client = oci.generative_ai_agent_runtime.GenerativeAiAgentRuntimeClient(config, **CLIENT_AUTH)
vulnerability_scanning_client = oci.vulnerability_scanning.VulnerabilityScanningClient(config, **CLIENT_AUTH)
osmh_client = oci.os_management_hub.ManagedInstanceClient(config, **CLIENT_AUTH)
ce_client = oci.container_engine.ContainerEngineClient(config=config, **CLIENT_AUTH)
work_requests_client = oci.work_requests.WorkRequestClient(config=config, **CLIENT_AUTH)
agent_endpoint_id = os.getenv("AGENT_ENDPOINT_ID")
SMTP_HOST = os.getenv("SMTP_HOST")
SMTP_SENDER = os.getenv("SMTP_SENDER")
SMTP_USERNAME = os.getenv("SMTP_USERNAME")
SMTP_PASSWORD = os.getenv("SMTP_PASSWORD")
tenancy_id = os.getenv("OCI_TENANCY_ID")

mcp = FastMCP(name=__project__)


def _work_request_result(response, resource_key: str, resource_id: str):
    return {
        "status": "success",
        resource_key: resource_id,
        "work_request_id": response.headers.get("opc-work-request-id"),
    }


@mcp.tool()
def list_compartments():
    """
    List all compartments in the tenancy.

    Args:
        None.

    Returns:
        dict: A dictionary containing the status and a list of compartments if successful.
        str: An error message if the operation fails.
    """
    if not identity_client:
        return {"status": "error", "message": "OCI not configured. Please run configure_oci first."}
    
    try:
        response = identity_client.list_compartments(
            compartment_id=tenancy_id,
            compartment_id_in_subtree=True
        )
        
        compartments = []
        for compartment in response.data:
            compartments.append({
                "id": compartment.id,
                "name": compartment.name,
                "description": compartment.description,
                "lifecycle_state": compartment.lifecycle_state
            })
        
        return {"status": "success", "compartments": compartments}
    except Exception as e:
        return f"Error listing compartments: {str(e)}"

@mcp.tool()
def list_availability_domains(compartment_id: str):
    """
    List availability domains in a compartment.

    Args:
        compartment_id (str): The OCID of the compartment.
    
    Returns:
        dict: A dictionary containing the status and a list of availability domains if successful.
        str: An error message if the operation fails.
    """
    if not identity_client:
        return {"status": "error", "message": "OCI not configured. Please run configure_oci first."}
    
    try:
        response = identity_client.list_availability_domains(
            compartment_id=compartment_id
        )
        
        domains = []
        for domain in response.data:
            domains.append({
                "name": domain.name,
                "id": domain.id,
                "compartment_id": domain.compartment_id
            })
        
        return {"status": "success", "availability_domains": domains}
    except Exception as e:
        return f"Error listing availability domains: {str(e)}"

@mcp.tool()
def list_subnets(compartment_id: str):
    """
    List subnets in a compartment.

    Args:
        compartment_id (str): The OCID of the compartment.
    
    Returns:
        dict: A dictionary containing the status and a list of subnets if successful.
        str: An error message if the operation fails.
    """
    if not network_client:
        return {"status": "error", "message": "OCI not configured. Please run configure_oci first."}
    
    try:
        response = network_client.list_subnets(
            compartment_id=compartment_id
        )
        
        subnets = []
        for subnet in response.data:
            subnets.append({
                "id": subnet.id,
                "display_name": subnet.display_name,
                "cidr_block": subnet.cidr_block,
                "vcn_id": subnet.vcn_id,
                "availability_domain": subnet.availability_domain,
                "lifecycle_state": subnet.lifecycle_state
            })
        
        return {"status": "success", "subnets": subnets}
    except Exception as e:
        return f"Error listing subnets: {str(e)}"


@mcp.tool()
def list_images(compartment_id: str, operating_system: Optional[str] = None):
    """
    List available images in a compartment.

    Args:
        compartment_id (str): The OCID of the compartment.
        operating_system (str, optional): The operating system to filter images.
    
    Returns:
        dict: A dictionary containing the status and a list of images if successful.
        str: An error message if the operation fails.
    """
    if not compute_client:
        return {"status": "error", "message": "OCI not configured. Please run configure_oci first."}
    
    try:
        list_args = {"compartment_id": compartment_id}
        if operating_system:
            list_args["operating_system"] = operating_system
        
        response = compute_client.list_images(**list_args)
        
        images = []
        for image in response.data:
            images.append({
                "id": image.id,
                "display_name": image.display_name,
                "operating_system": image.operating_system,
                "operating_system_version": image.operating_system_version,
                "lifecycle_state": image.lifecycle_state,
                "size_in_mbs": image.size_in_mbs
            })
        
        return {"status": "success", "images": images}
    except Exception as e:
        return f"Error listing images: {str(e)}"


@mcp.tool()
def list_shapes(compartment_id: str):
    """
    List available compute shapes in a compartment.

    Args:
        compartment_id (str): The OCID of the compartment.
    
    Returns:
        dict: A dictionary containing the status and a list of shapes if successful.
        str: An error message if the operation fails.
    """
    if not compute_client:
        return {"status": "error", "message": "OCI not configured. Please run configure_oci first."}
    
    try:
        response = compute_client.list_shapes(
            compartment_id=compartment_id
        )
        
        shapes = []
        for shape in response.data:
            shape_info = {
                "shape": shape.shape,
                "ocpus": getattr(shape, "ocpus", None),
                "memory_in_gbs": getattr(shape, "memory_in_gbs", None),
                "processor_description": getattr(shape, "processor_description", None)
            }
            if hasattr(shape, 'ocpu_options') and shape.ocpu_options:
                shape_info["flexible_ocpus"] = {
                    "min": getattr(shape.ocpu_options, "min", None),
                    "max": getattr(shape.ocpu_options, "max", None)
                }
            if hasattr(shape, 'memory_options') and shape.memory_options:
                mem_opts = shape.memory_options
                shape_info["flexible_memory"] = {}
                if hasattr(mem_opts, "min_in_gbs"):
                    shape_info["flexible_memory"]["min_in_gbs"] = mem_opts.min_in_gbs
                if hasattr(mem_opts, "max_in_gbs"):
                    shape_info["flexible_memory"]["max_in_gbs"] = mem_opts.max_in_gbs
                if hasattr(mem_opts, "default_per_ocpu_in_gbs"):
                    shape_info["flexible_memory"]["default_per_ocpu_in_gbs"] = mem_opts.default_per_ocpu_in_gbs
            shapes.append(shape_info)
        
        return {"status": "success", "shapes": shapes}
    except Exception as e:
        return f"Error listing shapes: {str(e)}"


@mcp.tool()
def create_instance(
    compartment_id: str,
    availability_domain: str,
    display_name: str,
    shape: str,
    subnet_id: str,
    image_id: str,
    ssh_public_key: Optional[str] = os.getenv("DEFAULT_SSH_PUBLIC_KEY"),
    user_data: Optional[str] = None,
    ocpus: float = 1.0,
    memory_in_gbs: float = 6.0,
    boot_volume_size_in_gbs: int = 50,
    assign_public_ip: bool = True
):
    """
    Launch a new OCI compute instance with VNIC creation.

    Args:
        compartment_id (str): The OCID of the compartment.
        availability_domain (str): The availability domain.
        display_name (str): The display name for the instance.
        shape (str): The shape of the instance.
        subnet_id (str): The OCID of the subnet.
        image_id (str): The OCID of the image.
        ssh_public_key (str, optional): The SSH public key.
        user_data (str, optional): Cloud-init user data script.
        ocpus (float, optional): Number of OCPUs.
        memory_in_gbs (float, optional): Memory in GBs.
        boot_volume_size_in_gbs (int, optional): Boot volume size in GBs.
        assign_public_ip (bool, optional): Assign a public IP.
    
    Returns:
        dict: A dictionary containing the status and instance details if successful.
        str: An error message if the operation fails.
    """
    try:
        # Check subnet's prohibit_public_ip_on_vnic property
        subnet = network_client.get_subnet(subnet_id).data
        if hasattr(subnet, "prohibit_public_ip_on_vnic") and subnet.prohibit_public_ip_on_vnic:
            assign_public_ip = False
        # Create VNIC details
        vnic_details = oci.core.models.CreateVnicDetails(
            subnet_id=subnet_id,
            assign_public_ip=assign_public_ip,
            display_name=f"{display_name}-vnic"
        )
        # Build launch instance details
        launch_details = oci.core.models.LaunchInstanceDetails(
            availability_domain=availability_domain,
            compartment_id=compartment_id,
            display_name=display_name,
            shape=shape,
            create_vnic_details=vnic_details,
            subnet_id=subnet_id,
            source_details=oci.core.models.InstanceSourceViaImageDetails(
                source_type="image",
                image_id=image_id,
                boot_volume_size_in_gbs=boot_volume_size_in_gbs
            )
        )
        # Add shape config for flexible shapes
        if "Flex" in shape:
            launch_details.shape_config = oci.core.models.LaunchInstanceShapeConfigDetails(
                ocpus=ocpus,
                memory_in_gbs=memory_in_gbs
            )
        # Build metadata
        metadata = {}
        if ssh_public_key:
            metadata["ssh_authorized_keys"] = ssh_public_key
        if user_data:
            
            clean = user_data.replace("&#10;", "\n").replace("&#13;", "\r")

            # Ensure #cloud-config exists
            stripped = clean.lstrip()
            if not stripped.startswith("#cloud-config"):
                clean = "#cloud-config\n" + clean

            # Encode for OCI metadata
            metadata["user_data"] = base64.b64encode(clean.encode()).decode()
        if metadata:
            launch_details.metadata = metadata
        response = compute_client.launch_instance(launch_details)
        instance_info = {
            "id": response.data.id,
            "display_name": response.data.display_name,
            "lifecycle_state": response.data.lifecycle_state,
            "availability_domain": response.data.availability_domain,
            "compartment_id": response.data.compartment_id,
            "shape": response.data.shape,
            "time_created": response.data.time_created.isoformat()
        }
        result = {
            "status": "success",
            "message": "Instance launched successfully!",
            "instance": instance_info
        }
        return result
    except Exception as e:
        return f"Error launching instance: {str(e)}"


@mcp.tool()
def list_instances(compartment_id: str):
    """
    List all instances in a compartment with Instance ID, display name, lifecycle state, availability domain, shape, and time created.

    Args:
        compartment_id (str): The OCID of the compartment.
    
    Returns:
        dict: A dictionary containing the status and a list of instances if successful.
        str: An error message if the operation fails.
    """
    if not compute_client:
        return {"status": "error", "message": "OCI not configured. Please run configure_oci first."}
    
    try:
        response = compute_client.list_instances(
            compartment_id=compartment_id
        )
        
        instances = []
        for instance in response.data:
            instances.append({
                "id": instance.id,
                "display_name": instance.display_name,
                "lifecycle_state": instance.lifecycle_state,
                "availability_domain": instance.availability_domain,
                "shape": instance.shape,
                "time_created": instance.time_created.isoformat()
            })
        
        return {"status": "success", "instances": instances}
    except Exception as e:
        return f"Error listing instances: {str(e)}"



def get_instance(instance_id: str):
    """Get details of a specific instance using its Instance ID"""
    if not compute_client:
        return {"status": "error", "message": "OCI not configured. Please run configure_oci first."}
    
    try:
        response = compute_client.get_instance(instance_id=instance_id)
        instance = response.data
        # Try to get OCPU and memory info from shape_config or instance
        ocpus = None
        memory_in_gbs = None
        if hasattr(instance, "shape_config") and instance.shape_config:
            ocpus = getattr(instance.shape_config, "ocpus", None)
            memory_in_gbs = getattr(instance.shape_config, "memory_in_gbs", None)
        elif hasattr(instance, "ocpus"):
            ocpus = getattr(instance, "ocpus", None)
        elif hasattr(instance, "memory_in_gbs"):
            memory_in_gbs = getattr(instance, "memory_in_gbs", None)
        # Try to get instance agent id
        agent_id = getattr(instance, "instance_agent_id", None)
        instance_info = {
            "id": instance.id,
            "display_name": instance.display_name,
            "lifecycle_state": instance.lifecycle_state,
            "availability_domain": instance.availability_domain,
            "compartment_id": instance.compartment_id,
            "shape": instance.shape,
            "region": instance.region,
            "time_created": instance.time_created.isoformat(),
            "image_id": instance.image_id if hasattr(instance, 'image_id') else None,
            "metadata": instance.metadata if hasattr(instance, 'metadata') else {},
            "ocpus": ocpus,
            "memory_in_gbs": memory_in_gbs,
            "instance_agent_id": agent_id
        }
        return {"status": "success", "instance": instance_info}
    except Exception as e:
        return f"Error getting instance: {str(e)}"

@mcp.tool()
def terminate_instance(instance_id: str, preserve_boot_volume: bool = False):
    """
    Terminate an OCI instance using its Instance ID. Optionally preserve the boot volume.

    Args:
        instance_id (str): The OCID of the instance.
        preserve_boot_volume (bool, optional): Preserve the boot volume.
    
    Returns:
        dict: A dictionary containing the status and termination details if successful.
        str: An error message if the operation fails.
    """
    if not compute_client:
        return {"status": "error", "message": "OCI not configured. Please run configure_oci first."}
    
    try:
        response = compute_client.terminate_instance(
            instance_id=instance_id,
            preserve_boot_volume=preserve_boot_volume
        )
        
        return {
            "status": "success",
            "message": f"Instance {instance_id} termination initiated. Boot volume {'preserved' if preserve_boot_volume else 'will be deleted'}."
        }
    except Exception as e:
        return f"Error terminating instance: {str(e)}"


@mcp.tool()
def resize_instance(instance_id: str, ocpus: float, memory_in_gbs: float):
    """
    Change the CPU and memory (shape config) of a flexible instance. Instance automatically stopped by this. Do not need stop tool

    Args:
        instance_id (str): The OCID of the instance.
        ocpus (float): Number of OCPUs.
        memory_in_gbs (float): Memory in GBs.
    
    Returns:
        dict: A dictionary containing the status and resize details if successful.
        str: An error message if the operation fails.
    """
    if not compute_client:
        return {"status": "error", "message": "OCI not configured."}
    try:
        details = oci.core.models.UpdateInstanceDetails(
            shape_config=oci.core.models.UpdateInstanceShapeConfigDetails(
                ocpus=ocpus,
                memory_in_gbs=memory_in_gbs
            )
        )
        response = compute_client.update_instance(instance_id, details)
        return {"status": "success", "message": "Instance resize initiated.", "instance_id": instance_id}
    except Exception as e:
        return f"Error resizing instance: {str(e)}"

@mcp.tool()
def stop_instance(instance_id: str, force: bool = False):
    """
    Stop an OCI instance (soft or hard) using its Instance ID.

    Args:
        instance_id (str): The OCID of the instance.
        force (bool, optional): If True, perform a hard stop. If False, perform a soft stop.
    
    Returns:
        dict: A dictionary containing the status and stop details if successful.
        str: An error message if the operation fails.
    """
    if not compute_client:
        return {"status": "error", "message": "OCI not configured."}
    try:
        response = compute_client.instance_action(instance_id, action="SOFTSTOP" if not force else "STOP")
        return {"status": "success", "message": f"Instance {instance_id} stop initiated."}
    except Exception as e:
        return f"Error stopping instance: {str(e)}"

@mcp.tool()
def attach_block_volume(instance_id: str, volume_id: str, device: Optional[str] = None):
    """
    Attach a block volume to an instance. For this operation you must specify the instance ID and volume ID.

    Args:
        instance_id (str): The ID of the instance.
        volume_id (str): The ID of the volume.
        device (str, optional): The device name to expose to the instance.
    
    Returns:
        dict: A dictionary containing the status and attachment details if successful.
        str: An error message if the operation fails.
    """
    try:
        attach_details = oci.core.models.AttachParavirtualizedVolumeDetails(
            instance_id=instance_id,
            volume_id=volume_id,
            device=device
        )
        response = compute_client.attach_volume(attach_details)
        return {"status": "success", "message": "Block volume attach initiated.", "attachment_id": response.data.id}
    except Exception as e:
        return f"Error attaching block volume: {str(e)}"



def attach_vnic(instance_id: str, subnet_id: str, assign_public_ip: bool = False, display_name: Optional[str] = None):
    """
    Attach an additional VNIC to an instance using its Instance ID, subnet ID, and optional parameters.

    Args:
        instance_id (str): The OCID of the instance.
        subnet_id (str): The OCID of the subnet.
        assign_public_ip (bool, optional): Assign a public IP.
        display_name (str, optional): The display
    
    Returns:
        dict: A dictionary containing the status and VNIC attachment details if successful.
        str: An error message if the operation fails.
    """
    try:
        vnic_details = oci.core.models.CreateVnicDetails(
            subnet_id=subnet_id,
            assign_public_ip=assign_public_ip,
            display_name=display_name
        )
        attach_details = oci.core.models.AttachVnicDetails(
            instance_id=instance_id,
            create_vnic_details=vnic_details
        )
        response = compute_client.attach_vnic(attach_details)
        return {"status": "success", "message": "VNIC attach initiated.", "vnic_attachment_id": response.data.id}
    except Exception as e:
        return f"Error attaching VNIC: {str(e)}"

@mcp.tool()
def get_compartment_id_by_name(name: str):
    """
    Get the OCID of a compartment by its name.

    Args:
        name (str): The name of the compartment.
    
    Returns:
        dict: A dictionary containing the status and compartment ID if successful.
        str: An error message if the operation fails.
    """
    if not identity_client:
        return {"status": "error", "message": "OCI not configured. Please run configure_oci first."}
    try:
        response = identity_client.list_compartments(
            compartment_id=tenancy_id,
            compartment_id_in_subtree=True
        )
        for compartment in response.data:
            if compartment.name == name:
                return {"status": "success", "compartment_id": compartment.id}
        return {"status": "error", "message": f"Compartment with name '{name}' not found."}
    except Exception as e:
        return f"Error searching for compartment: {str(e)}"


@mcp.tool()
def get_image_id_by_name(compartment_id: str, display_name: str, operating_system: Optional[str] = None):
    """
    Get the OCID of an image by its display name in a compartment (case-insensitive, trimmed, substring match).

    Args:
        compartment_id (str): The OCID of the compartment.
        display_name (str): The display name of the image.
        operating_system (str, optional): The operating system to filter images.
    
    Returns:
        dict: A dictionary containing the status and image ID if successful.
        str: An error message if the operation fails.
    """
    if not compute_client:
        return {"status": "error", "message": "OCI not configured. Please run configure_oci first."}
    try:
        list_args = {"compartment_id": compartment_id}
        if operating_system:
            list_args["operating_system"] = operating_system
        
        response = compute_client.list_images(**list_args)
        normalized_input = display_name.strip().lower()
        # First, try exact match
        for image in response.data:
            if image.display_name and image.display_name.strip().lower() == normalized_input:
                return {"status": "success", "image_id": image.id}
        # If not found, try substring match
        for image in response.data:
            if image.display_name and normalized_input in image.display_name.strip().lower():
                return {"status": "success", "image_id": image.id}
        # If still not found, return available image names for guidance
        available_images = [img.display_name for img in response.data if img.display_name]
        return {
            "status": "error",
            "message": f"Image with display name containing '{display_name}' not found.",
            "available_images": available_images
        }
    except Exception as e:
        return f"Error searching for image: {str(e)}"

@mcp.tool()
def get_subnet_id_by_name(compartment_id: str, display_name: str):
    """
    Get the subnet ID by its name in a compartment.

    Args:
        compartment_id (str): The OCID of the compartment.
        display_name (str): The display name of the subnet.
    
    Returns:
        dict: A dictionary containing the status and subnet ID if successful.
        str: An error message if the operation fails.
    """
    if not network_client:
        return {"status": "error", "message": "OCI not configured. Please run configure_oci first."}
    try:
        response = network_client.list_subnets(compartment_id=compartment_id)
        normalized_input = display_name.strip().lower()
        # First, try exact match
        for subnet in response.data:
            if subnet.display_name and subnet.display_name.strip().lower() == normalized_input:
                return {"status": "success", "subnet_id": subnet.id}
        # If not found, try substring match
        for subnet in response.data:
            if subnet.display_name and normalized_input in subnet.display_name.strip().lower():
                return {"status": "success", "subnet_id": subnet.id}
        # If still not found, return available subnet names for guidance
        available_subnets = [subnet.display_name for subnet in response.data if subnet.display_name]
        return {
            "status": "error",
            "message": f"Subnet with display name containing '{display_name}' not found.",
            "available_subnets": available_subnets
        }
    except Exception as e:
        return f"Error searching for subnet: {str(e)}"

@mcp.tool()
def create_block_volume(
    compartment_id: str,
    availability_domain: str,
    size_in_gbs: int,
    display_name: str = None
):
    """
    Create a new block volume in the specified compartment and availability domain.

    Args:
        compartment_id (str): The OCID of the compartment where the volume will be created.
        availability_domain (str): The availability domain where the volume will be created.
        display_name (str, optional): The display name for the block volume.
        size_in_gbs (int): The size of the block volume in GBs.
        
    Returns:
        dict: A dictionary containing the status, message, and volume ID if successful.
        str: An error message if the operation fails.
    """
    try:
        if not display_name:
            prefixes = ["Vol", "Disk", "Data", "Store", "OCI"]
            random_suffix = random.randint(1000, 9999)
            display_name = f"{random.choice(prefixes)}-{random_suffix}"

        details = oci.core.models.CreateVolumeDetails(
            compartment_id=compartment_id,
            availability_domain=availability_domain,
            display_name=display_name,
            size_in_gbs=size_in_gbs
        )
        response = storage_client.create_volume(details)
        return {
            "status": "success",
            "message": f"Block volume '{display_name}' creation initiated.",
            "volume_id": response.data.id
        }
    except Exception as e:
        return f"Error creating block volume: {str(e)}"

@mcp.tool()
def get_instances_by_display_name(compartment_id: str, display_name: str):
    """
    Return all instances in a compartment whose display name matches the given substring (case-insensitive), with full details.

    Args:
        compartment_id (str): The OCID of the compartment.
        display_name (str): The display name substring to match.
    
    Returns:
        dict: A dictionary containing the status and a list of matching instances if successful.
        str: An error message if the operation fails.
    """
    if not compute_client:
        return {"status": "error", "message": "OCI not configured. Please run configure_oci first."}
    try:
        response = compute_client.list_instances(compartment_id=compartment_id)
        normalized_input = display_name.strip().lower()
        matches = []
        for instance in response.data:
            if instance.display_name and normalized_input in instance.display_name.strip().lower():
                # Try to get OCPU and memory info from shape_config or instance
                ocpus = None
                memory_in_gbs = None
                if hasattr(instance, "shape_config") and instance.shape_config:
                    ocpus = getattr(instance.shape_config, "ocpus", None)
                    memory_in_gbs = getattr(instance.shape_config, "memory_in_gbs", None)
                elif hasattr(instance, "ocpus"):
                    ocpus = getattr(instance, "ocpus", None)
                elif hasattr(instance, "memory_in_gbs"):
                    memory_in_gbs = getattr(instance, "memory_in_gbs", None)
                agent_id = getattr(instance, "instance_agent_id", None)
                matches.append({
                    "id": instance.id,
                    "display_name": instance.display_name,
                    "lifecycle_state": instance.lifecycle_state,
                    "availability_domain": instance.availability_domain,
                    "compartment_id": instance.compartment_id,
                    "shape": instance.shape,
                    "region": instance.region,
                    "time_created": instance.time_created.isoformat(),
                    "image_id": instance.image_id if hasattr(instance, 'image_id') else None,
                    "metadata": instance.metadata if hasattr(instance, 'metadata') else {},
                    "ocpus": ocpus,
                    "memory_in_gbs": memory_in_gbs,
                    "instance_agent_id": agent_id
                })
        if matches:
            return {"status": "success", "instances": matches}
        else:
            available_names = [inst.display_name for inst in response.data if inst.display_name]
            return {
                "status": "error",
                "message": f"No instances found with display name containing '{display_name}'.",
                "available_instance_names": available_names
            }
    except Exception as e:
        return f"Error searching for instances: {str(e)}"

@mcp.tool()
def list_block_volumes(compartment_id: str):
    """
    List all block volumes in a compartment.

    Args:
        compartment_id (str): The OCID of the compartment.
    
    Returns:
        dict: A dictionary containing the status and a list of block volumes if successful.
        str: An error message if the operation fails.
    """
    try:
        response = storage_client.list_volumes(compartment_id=compartment_id)
        volumes = []
        for volume in response.data:
            volumes.append({
                "id": volume.id,
                "display_name": volume.display_name,
                "size_in_gbs": volume.size_in_gbs,
                "lifecycle_state": volume.lifecycle_state,
                "availability_domain": volume.availability_domain,
                "time_created": volume.time_created.isoformat() if hasattr(volume, 'time_created') else None
            })
        return {"status": "success", "block_volumes": volumes}
    except Exception as e:
        return f"Error listing block volumes: {str(e)}"


@mcp.tool()
def get_block_volume_id_by_name(compartment_id: str, display_name: str):
    """
    Get the OCID of a block volume by its display name in a compartment (case-insensitive, substring match).

    Args:
        compartment_id (str): The OCID of the compartment.
        display_name (str): The display name of the block volume.
    
    Returns:
        dict: A dictionary containing the status and block volume ID if successful.
        str: An error message if the operation fails.
    """
    try:
        response = storage_client.list_volumes(compartment_id=compartment_id)
        normalized_input = display_name.strip().lower()
        # First, try exact match
        for volume in response.data:
            if volume.display_name and volume.display_name.strip().lower() == normalized_input:
                return {"status": "success", "block_volume_id": volume.id}
        # If not found, try substring match
        for volume in response.data:
            if volume.display_name and normalized_input in volume.display_name.strip().lower():
                return {"status": "success", "block_volume_id": volume.id}
        available_volumes = [vol.display_name for vol in response.data if vol.display_name]
        return {
            "status": "error",
            "message": f"Block volume with display name containing '{display_name}' not found.",
            "available_block_volumes": available_volumes
        }
    except Exception as e:
        return f"Error searching for block volume: {str(e)}"


@mcp.tool()
def start_instance(instance_id: str):
    """
    Start an OCI instance using its Instance ID.

    Args:
        instance_id (str): The OCID of the instance.
    
    Returns:
        dict: A dictionary containing the status and start details if successful.
        str: An error message if the operation fails.
    """
    if not compute_client:
        return {"status": "error", "message": "OCI not configured."}
    try:
        response = compute_client.instance_action(instance_id, "START")
        return {"status": "success", "message": f"Instance {instance_id} start initiated."}
    except Exception as e:
        return f"Error starting instance: {str(e)}"

@mcp.tool()
def replace_boot_volume_with_image(
    instance_id: str,
    image_id: str,
    boot_volume_size_in_gbs: int = 50,
    is_preserve_boot_volume_enabled: bool = False
):
    """
    Replace the boot volume of an instance with a new image. The instance will be stopped and replaced automatically by the update operation. Tracks the work request for progress.

    Args:
        instance_id (str): The OCID of the instance.
        image_id (str): The OCID of the new image to use for the boot volume.
        boot_volume_size_in_gbs (int, optional): Size of the new boot volume in GBs. Defaults to 50.
        is_preserve_boot_volume_enabled (bool, optional): Whether to preserve the old boot volume. Defaults to False.

    Returns:
        dict: Status, message, and work request ID about the operation.
    """
    if not compute_client:
        return {"status": "error", "message": "OCI not configured."}
    try:
        update_details = oci.core.models.UpdateInstanceDetails(
            source_details=oci.core.models.UpdateInstanceSourceViaImageDetails(
                source_type="image",
                image_id=image_id,
                boot_volume_size_in_gbs=boot_volume_size_in_gbs,
                is_preserve_boot_volume_enabled=is_preserve_boot_volume_enabled
            )
        )
        update_response = compute_client.update_instance(instance_id, update_details)
        work_request_id = update_response.headers.get("opc-work-request-id")
        return {
            "status": "success",
            "message": f"Boot volume replacement initiated for instance {instance_id} with image {image_id}.",
            "instance_id": instance_id,
            "new_image_id": image_id,
            "work_request_id": work_request_id
        }
    except Exception as e:
        return {"status": "error", "message": f"Error replacing boot volume: {str(e)}"}


@mcp.tool()
def list_vcns(compartment_id: str):
    """
    List all VCNs in a compartment.

    Args:
        compartment_id (str): The OCID of the compartment.
    
    Returns:
        dict: A dictionary containing the status and a list of VCNs if successful.
        str: An error message if the operation fails.
    """
    if not network_client:
        return {"status": "error", "message": "OCI not configured. Please run configure_oci first."}
    
    try:
        response = network_client.list_vcns(compartment_id=compartment_id)
        
        vcns = []
        for vcn in response.data:
            vcns.append({
                "id": vcn.id,
                "display_name": vcn.display_name,
                "cidr_block": vcn.cidr_block,
                "lifecycle_state": vcn.lifecycle_state,
                "time_created": vcn.time_created.isoformat()
            })
        
        return {"status": "success", "vcns": vcns}
    except Exception as e:
        return f"Error listing VCNs: {str(e)}"


@mcp.tool()
def get_vcn_id_by_name(compartment_id: str, display_name: str):
    """
    Get the VCN ID by its name in a compartment (case-insensitive, substring match).

    Args:
        compartment_id (str): The OCID of the compartment.
        display_name (str): The display name of the VCN.
    
    Returns:
        dict: A dictionary containing the status and VCN ID if successful.
        str: An error message if the operation fails.
    """
    if not network_client:
        return {"status": "error", "message": "OCI not configured. Please run configure_oci first."}
    try:
        response = network_client.list_vcns(compartment_id=compartment_id)
        normalized_input = display_name.strip().lower()
        # First, try exact match
        for vcn in response.data:
            if vcn.display_name and vcn.display_name.strip().lower() == normalized_input:
                return {"status": "success", "vcn_id": vcn.id}
        # If not found, try substring match
        for vcn in response.data:
            if vcn.display_name and normalized_input in vcn.display_name.strip().lower():
                return {"status": "success", "vcn_id": vcn.id}
        # If still not found, return available VCN names for guidance
        available_vcns = [vcn.display_name for vcn in response.data if vcn.display_name]
        return {
            "status": "error",
            "message": f"VCN with display name containing '{display_name}' not found.",
            "available_vcns": available_vcns
        }
    except Exception as e:
        return f"Error searching for VCN: {str(e)}"


@mcp.tool()
def create_tag_namespace(compartment_id: str, name: str, description: str = None):
    """
    Create a new tag namespace in the specified compartment.

    Args:
        compartment_id (str): The OCID of the compartment.
        name (str): The name of the tag namespace.
        description (str): Optional description.

    Returns:
        dict: Status and details.
    """
    try:
        details = oci.identity.models.CreateTagNamespaceDetails(
            compartment_id=compartment_id,
            name=name,
            description=description
        )
        response = identity_client.create_tag_namespace(details)
        return {"status": "success", "tag_namespace_id": response.data.id, "name": response.data.name}
    except Exception as e:
        return f"Error creating tag namespace: {str(e)}"


@mcp.tool()
def get_tag_namespace_by_name(compartment_id: str, name: str):
    """
    Get tag namespace by name in the specified compartment.

    Args:
        compartment_id (str): The OCID of the compartment.
        name (str): The name of the tag namespace.

    Returns:
        dict: Status and details.
    """
    try:
        response = identity_client.list_tag_namespaces(compartment_id=compartment_id)
        for ns in response.data:
            if ns.name == name:
                return {"status": "success", "tag_namespace_id": ns.id, "name": ns.name, "description": ns.description}
        return {"status": "error", "message": f"Tag namespace '{name}' not found in compartment {compartment_id}"}
    except Exception as e:
        return f"Error getting tag namespace: {str(e)}"


@mcp.tool()
def create_tag_name(tag_namespace_id: str, name: str, description: str = None):
    """
    Create a new tag in the specified tag namespace.

    Args:
        tag_namespace_id (str): The OCID of the tag namespace.
        name (str): The name of the tag.
        description (str): Optional description.

    Returns:
        dict: Status and details.
    """
    try:
        details = oci.identity.models.CreateTagDetails(
            name=name,
            description=description
        )
        response = identity_client.create_tag(tag_namespace_id, details)
        return {"status": "success", "tag_id": response.data.id, "name": response.data.name}
    except Exception as e:
        return f"Error creating tag: {str(e)}"


@mcp.tool()
def get_tags_by_name(tag_namespace_id: str, name: str):
    """
    Get tag by name in the specified tag namespace.

    Args:
        tag_namespace_id (str): The OCID of the tag namespace.
        name (str): The name of the tag.

    Returns:
        dict: Status and details.
    """
    try:
        response = identity_client.list_tags(tag_namespace_id)
        for tag in response.data:
            if tag.name == name:
                return {"status": "success", "tag_id": tag.id, "name": tag.name, "description": tag.description}
        return {"status": "error", "message": f"Tag '{name}' not found in namespace {tag_namespace_id}"}
    except Exception as e:
        return f"Error getting tag: {str(e)}"


@mcp.tool()
def assign_tag_name(instance_id: str, tag_namespace: str, tag_name: str, tag_value: str):
    """
    Assign a defined tag to an instance.

    Args:
        instance_id (str): The OCID of the instance.
        tag_namespace (str): The tag namespace name.
        tag_name (str): The tag name.
        tag_value (str): The tag value.

    Returns:
        dict: Status and details.
    """
    try:
        # Get the current instance to preserve other tags
        response = compute_client.get_instance(instance_id)
        current_defined_tags = response.data.defined_tags or {}
        # Add the new tag
        if tag_namespace not in current_defined_tags:
            current_defined_tags[tag_namespace] = {}
        current_defined_tags[tag_namespace][tag_name] = tag_value
        update_details = oci.core.models.UpdateInstanceDetails(
            defined_tags=current_defined_tags
        )
        compute_client.update_instance(instance_id, update_details)
        return {"status": "success", "message": f"Tag {tag_namespace}.{tag_name}={tag_value} assigned to instance {instance_id}"}
    except Exception as e:
        return f"Error assigning tag: {str(e)}"


@mcp.tool()
def get_assigned_tag_names(instance_id: str):
    """
    Get all assigned tags (defined and freeform) for an instance.

    Args:
        instance_id (str): The OCID of the instance.

    Returns:
        dict: Status and details.
    """
    try:
        response = compute_client.get_instance(instance_id)
        defined_tags = response.data.defined_tags or {}
        freeform_tags = response.data.freeform_tags or {}
        return {"status": "success", "defined_tags": defined_tags, "freeform_tags": freeform_tags}
    except Exception as e:
        return f"Error getting assigned tags: {str(e)}"


@mcp.tool()
def list_tag_namespaces(compartment_id: str):
    """
    List all tag namespaces in the specified compartment.

    Args:
        compartment_id (str): The OCID of the compartment.

    Returns:
        dict: Status and list of tag namespaces.
    """
    try:
        response = identity_client.list_tag_namespaces(compartment_id=compartment_id)
        namespaces = []
        for ns in response.data:
            namespaces.append({
                "id": ns.id,
                "name": ns.name,
                "description": ns.description,
                "time_created": ns.time_created.isoformat() if hasattr(ns, 'time_created') else None
            })
        return {"status": "success", "tag_namespaces": namespaces}
    except Exception as e:
        return f"Error listing tag namespaces: {str(e)}"


@mcp.tool()
def cve_to_elsa(
    compartment_id: str,
    instance_id: str
):
    """
    USE THIS TOOL WHEN:
    - User asks to "patch", "remediate", "fix vulnerabilities" on an instance
    - User asks "generate a patch script" for an instance

    WHAT IT DOES (fully internal — LLM never sees CVE list):
    1. Fetches ALL CVEs from the latest VSS vulnerability scan
    2. Fetches ALL SECURITY advisories from OSMH
    3. Matches CVEs -> ELSA advisories
    4. Returns patch command + unmatched CVEs

    LLM INSTRUCTIONS FOR BASH SCRIPT:
    - Use patch_command to build the yum update command
    - Add unmatched_cve_ids as comments (# No ELSA patch available)
    - If requires_reboot is true, append "sudo reboot" at end of script

    Args:
        compartment_id (str): OCID of the compartment the instance belongs to.
        instance_id (str): OCID of the instance (used for both VSS and OSMH).

    Returns:
        dict: {
            scan_id,
            total_cves_in_scan,
            total_matched,
            total_unmatched,
            all_elsa_advisories: ["ELSA-XXXX", ...],
            unmatched_cve_ids: ["CVE-XXXX", ...],
            requires_reboot: true/false,
            patch_command: "sudo yum update --advisory ELSA-XXXX ... -y"
        }
    """
    try:
        # Step 1: Fetch ALL CVEs from latest VSS scan
        list_resp = vulnerability_scanning_client.list_host_agent_scan_results(
            compartment_id=compartment_id,
            instance_id=instance_id,
            sort_order="ASC",
            is_latest_only=True
        )

        if not list_resp.data.items:
            return {"status": "error", "message": "No vulnerability scan results found."}

        scan_id   = list_resp.data.items[0].id
        scan_resp = vulnerability_scanning_client.get_host_agent_scan_result(
            host_agent_scan_result_id=scan_id
        )

        problems = scan_resp.data.problems or []

        seen     = set()
        cve_list = []
        for p in problems:
            if p.cve_reference and p.cve_reference not in seen:
                seen.add(p.cve_reference)
                cve_list.append(p.cve_reference.upper())

        if not cve_list:
            return {"status": "success", "message": "No CVEs found in scan.", "scan_id": scan_id}

        # Step 2: Fetch ALL SECURITY errata from OSMH
        all_errata = []
        next_page  = None

        while True:
            kwargs = {
                "managed_instance_id": instance_id,
                "classification_type": ["SECURITY"],
                "limit": 100,
            }
            if next_page:
                kwargs["page"] = next_page

            resp = osmh_client.list_managed_instance_errata(**kwargs)
            all_errata.extend(resp.data.items or [])
            next_page = resp.headers.get("opc-next-page")
            if not next_page:
                break

        if not all_errata:
            return {
                "status": "error",
                "message": (
                    "No OSMH SECURITY advisories found. "
                    "Verify instance_id is the OSMH managed instance OCID."
                )
            }

        # Step 3: Build reverse index CVE -> [ELSA, ...] for O(1) lookup
        cve_elsa_index = {}
        for e in all_errata:
            for cve in (e.related_cves or []):
                cve_upper = cve.upper()
                if cve_upper not in cve_elsa_index:
                    cve_elsa_index[cve_upper] = []
                cve_elsa_index[cve_upper].append(e.name)

        # Step 4: Match CVEs -> ELSA
        all_elsa      = set()
        all_unmatched = []

        for cve in cve_list:
            matched = cve_elsa_index.get(cve, [])
            if matched:
                all_elsa.update(matched)
            else:
                all_unmatched.append(cve)

        # Step 5: Detect reboot requirement (kernel advisory)
        matched_errata  = [e for e in all_errata if e.name in all_elsa]
        requires_reboot = any(
            "kernel" in (getattr(e, "synopsis", "") or "").lower() or
            any("kernel" in (getattr(p, "name", "") or "").lower()
                for p in (getattr(e, "packages", None) or []))
            for e in matched_errata
        )

        sorted_elsa   = sorted(all_elsa)
        advisory_args = " ".join(f"--advisory {e}" for e in sorted_elsa)

        return {
            "status": "success",
            "scan_id": scan_id,
            "total_cves_in_scan": len(cve_list),
            "total_matched": len(cve_list) - len(all_unmatched),
            "total_unmatched": len(all_unmatched),
            "all_elsa_advisories": sorted_elsa,
            "unmatched_cve_ids": all_unmatched,
            "requires_reboot": requires_reboot,
            "patch_command": f"sudo yum update {advisory_args} -y" if sorted_elsa else None,
        }

    except oci.exceptions.ServiceError as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def reboot_instance(instance_id: str):
    """
    Reboot an OCI instance using SOFTRESET.

    Args:
        instance_id (str): The OCID of the instance

    Returns:
        dict: Reboot status
    """
    try:
        response = compute_client.instance_action(
            instance_id=instance_id,
            action="SOFTRESET"
        )

        lifecycle_state = response.data.lifecycle_state

        return {
            "status": "success",
            "instance_id": instance_id,
            "action": "SOFTRESET",
            "lifecycle_state": lifecycle_state,
            "message": "Reboot initiated successfully"
        }

    except Exception as e:
        return {
            "status": "error",
            "message": str(e)
        }

@mcp.tool()
def remediate_vulnerabilities(compartment_id: str, instance_id: str, remediation_script: str):
    """
    Executes a bash remediation script on an OCI instance via the Run Command functionality.
    
    Args:
        compartment_id (str): The OCID of the compartment.
        instance_id (str): The OCID of the instance to run the script on.
        remediation_script (str): The bash script to run for remediation.
    
    Returns:
        dict: Contains the status and command ID of the executed command.
        str: Error message if execution fails.
    """

    try:
        print("Submitting Run Command...")

        # Prepare the command details
        command_details = oci.compute_instance_agent.models.CreateInstanceAgentCommandDetails(
            compartment_id=compartment_id,
            display_name="VulnerabilityRemediation",
            execution_time_out_in_seconds=7200,
            target=oci.compute_instance_agent.models.InstanceAgentCommandTarget(
                instance_id=instance_id
            ),
            content=oci.compute_instance_agent.models.InstanceAgentCommandContent(
                source=oci.compute_instance_agent.models.InstanceAgentCommandSourceViaTextDetails(
                    source_type="TEXT",
                    text=remediation_script
                )
            )
        )

        # Submit the command
        response = compute_instance_agent_client.create_instance_agent_command(
            create_instance_agent_command_details=command_details
        )

        command_id = response.data.id
        print(f"Command submitted. Command ID: {command_id}")

        # Poll until completion by using get_instance_agent_command_execution
        while True:
            # Fetch command execution status
            command_execution = compute_instance_agent_client.get_instance_agent_command_execution(
                instance_agent_command_id=command_id, instance_id=instance_id
            ).data

            status = command_execution.lifecycle_state  # Status of the command execution
            print("Current Status:", status)

            if status in ["IN_PROGRESS", "SUCCEEDED", "ACCEPTED", "FAILED", "CANCELED"]:
                break

            time.sleep(5)

        # Return final results
        return {
            "status": status,
            "command_id": command_id
        }

    except Exception as e:
        return {
            "status": "error",
            "message": str(e)
        }
    
@mcp.tool()
def create_boot_volume_backup(compartment_id: str, instance_id: str, availability_domain: str):
    """
    Purpose: Create a backup of an OCI instance boot volume.

    Args:
        instance_id (str): OCID of the OCI instance
        availability_domain (str): Availability domain where the instance resides

    Returns:
        dict: Boot volume backup information
    """

    try:

        # Get boot volume attachment
        attachments = compute_client.list_boot_volume_attachments(
            compartment_id=compartment_id,
            availability_domain=availability_domain
        ).data

        boot_attachment = next(
            (a for a in attachments if a.instance_id == instance_id), None
        )

        if not boot_attachment:
            return {
                "status": "error",
                "message": f"No boot volume found for instance {instance_id}"
            }

        boot_volume_id = boot_attachment.boot_volume_id

        # Create backup name
        backup_name = f"OS_Boot_Volume_Backup_{datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')}"

        # Create backup
        backup_response = storage_client.create_boot_volume_backup(
            oci.core.models.CreateBootVolumeBackupDetails(
                display_name=backup_name,
                boot_volume_id=boot_volume_id,
                type="FULL"
            )
        )

        backup_id = backup_response.data.id

        # Wait until backup is available
        while True:
            backup = storage_client.get_boot_volume_backup(backup_id).data

            if backup.lifecycle_state == "AVAILABLE":
                break
            elif backup.lifecycle_state == "FAILED":
                return {
                    "status": "error",
                    "message": f"Backup failed for boot volume {boot_volume_id}"
                }

            time.sleep(10)

        return {
            "status": "success",
            "backup_id": backup_id,
            "boot_volume_id": boot_volume_id,
            "backup_name": backup_name,
            "lifecycle_state": "AVAILABLE"
        }

    except Exception as e:
        return {
            "status": "error",
            "message": str(e)
        }

@mcp.tool()
def get_alarm(alarmtype: str, compartment_id: str):
    """
    Get list of OCI instance names which are in the specified alarm state (FIRING).

    Args:
        alarmtype (str): Alarm display name (e.g., "CPU_ALARM", "MEMORY_ALARM")

    Returns:
        dict: List of instance names in FIRING state
    """
    try:

        # Step 1: Get alarms by display name
        alarms = monitoring_client.list_alarms_status(
            compartment_id=compartment_id,
            display_name=alarmtype
        ).data

        if not alarms:
            return {
                "status": "error",
                "message": f"No alarms found with name '{alarmtype}'"
            }

        resource_names = []

        # Step 2: Iterate each alarm (IMPORTANT FIX)
        for alarm in alarms:
            dimension_states = monitoring_client.retrieve_dimension_states(
                alarm_id=alarm.id
            ).data

            for item in dimension_states.items:
                if item.status == "FIRING":
                    name = item.dimensions.get("resourceDisplayName")
                    if name:
                        resource_names.append(name)

        return {
            "status": "success",
            "alarm_type": alarmtype,
            "firing_instances": list(set(resource_names)),  # remove duplicates
            "count": len(set(resource_names))
        }

    except Exception as e:
        return {
            "status": "error",
            "message": str(e)
        }

@mcp.tool()
def email_notification(
    recipient: str,
    instance_name: str,
    instance_id: str,
    compartment_id: str,
    alarm_type: str,
    message: str
):
    """
    Send an email notification. The AI agent generates the message body.
    This tool ONLY sends an email — it does NOT determine content.

    Args:
        recipient (str): Email address to notify.
        instance_name (str): Name of the OCI instance.
        instance_id (str): Instance OCID.
        compartment_id (str): Compartment OCID.
        alarm_type (str): Type of alarm (e.g., Backup, Failure, Reboot).
        message (str): The full AI-generated content of the email.

    Returns:
        dict: Email send status.
    """

    SMTP_HOST = os.getenv("SMTP_HOST")
    SMTP_PORT = int(os.getenv("SMTP_PORT", "587"))
    SMTP_SENDER = os.getenv("SMTP_SENDER")
    SMTP_USERNAME = os.getenv("SMTP_USERNAME")
    SMTP_PASSWORD = os.getenv("SMTP_PASSWORD")

    if not all([SMTP_HOST, SMTP_SENDER, SMTP_USERNAME, SMTP_PASSWORD]):
        return {
            "status": "error",
            "message": "Missing SMTP configuration. Ensure SMTP_HOST, SMTP_SENDER, SMTP_USERNAME, SMTP_PASSWORD are set."
        }

    # Subject line includes alarm type — stable and non-AI
    subject = f"{alarm_type} Alert for {instance_name}"

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = SMTP_SENDER
    msg["To"] = recipient

    # AI-generated message is appended below instance metadata
    msg.set_content(
        f"Alarm Type: {alarm_type}\n"
        f"Instance Name: {instance_name}\n"
        f"Instance ID: {instance_id}\n"
        f"Compartment ID: {compartment_id}\n\n"
        f"{message}"
    )

    try:
        context = ssl.create_default_context()
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT) as server:
            server.ehlo()
            server.starttls(context=context)
            server.ehlo()
            server.login(SMTP_USERNAME, SMTP_PASSWORD)
            server.send_message(msg)

        return {
            "status": "success",
            "email_status": "sent",
            "recipient": recipient,
            "instance_name": instance_name,
            "instance_id": instance_id,
            "compartment_id": compartment_id,
            "alarm_type": alarm_type
        }

    except Exception as e:
        return {
            "status": "error",
            "email_status": "failed",
            "message": str(e)
        }

@mcp.tool()
def run_kubectl(
    argv: List[str],
    timeout: int = 30,
):
    """
    Execute kubectl commands against the OKE cluster.
    IMPORTANT: Call create_kubeconfig tool first to generate kubeconfig before using this tool.

    Common examples:
        ["kubectl", "get", "pods", "-n", "default", "-o", "json"]
        ["kubectl", "get", "deployments", "-A", "-o", "json"]
        ["kubectl", "describe", "pod", "<pod-name>", "-n", "<namespace>"]
        ["kubectl", "logs", "<pod-name>", "-n", "<namespace>", "--tail=100"]
        ["kubectl", "get", "nodes", "-o", "json"]
        ["kubectl", "get", "services", "-A", "-o", "json"]
        ["kubectl", "top", "pods", "-n", "<namespace>"]
        ["kubectl", "get", "events", "-n", "<namespace>", "--sort-by=.lastTimestamp"]
        ["kubectl", "apply", "-f", "<manifest-path>"]
        ["kubectl", "scale", "deployment", "<name>", "--replicas=3", "-n", "<namespace>"]

    Args:
        argv (List[str]): kubectl command and arguments. Must start with "kubectl".
        timeout (int): Maximum execution time in seconds. Default 30. Increase for logs or large outputs.

    Returns:
        dict: JSON-safe result with stdout, stderr, return code, and parsed JSON if available.
    """
    if not argv or not isinstance(argv, list):
        return {"status": "error", "message": "argv must be a non-empty list of strings"}

    if argv[0] != "kubectl":
        return {"status": "error", "message": "Only kubectl commands are allowed"}

    DANGEROUS_ARGS = ["delete namespace", "delete node", "drain", "cordon", "taint"]
    argv_str = " ".join(argv).lower()
    for dangerous in DANGEROUS_ARGS:
        if dangerous in argv_str:
            return {"status": "error", "message": f"Blocked dangerous operation: '{dangerous}'"}

    env = os.environ.copy()
    env["KUBECONFIG"] = os.path.expanduser("~/.kube/config")
    env["OCI_CLI_AUTH"] = "resource_principal"

    logger.info(f"Running kubectl: {argv}")

    try:
        completed = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
            check=False,
        )

        stdout = completed.stdout
        MAX_OUTPUT = 50000
        truncated = False
        if len(stdout) > MAX_OUTPUT:
            stdout = stdout[:MAX_OUTPUT]
            truncated = True

        result = {
            "status": "success" if completed.returncode == 0 else "error",
            "argv": argv,
            "returncode": completed.returncode,
            "stdout": stdout,
            "stderr": completed.stderr,
            "truncated": truncated,
        }

        stripped = stdout.strip()
        if stripped:
            try:
                result["json"] = json.loads(stripped)
            except json.JSONDecodeError:
                result["json"] = None

        return result

    except subprocess.TimeoutExpired:
        return {"status": "error", "argv": argv, "message": f"Command timed out after {timeout} seconds"}
    except FileNotFoundError:
        return {"status": "error", "argv": argv, "message": "kubectl not found. Is it installed in the container?"}
    except Exception as e:
        return {"status": "error", "argv": argv, "message": str(e)}

@mcp.tool()
def list_clusters(compartment_id: str):
    """
    List all OKE (Oracle Kubernetes Engine) clusters in a compartment.

    Args:
        compartment_id (str): OCI compartment OCID

    Returns:
        dict: List of clusters with id, name, lifecycle state, and Kubernetes version
    """
    try:
        resp = ce_client.list_clusters(compartment_id=compartment_id).data

        if not resp:
            return {"status": "success", "clusters": [], "count": 0}

        clusters = [{"id": c.id, "name": c.name, "state": c.lifecycle_state,
                      "k8s_version": c.kubernetes_version} for c in resp]

        return {"status": "success", "clusters": clusters, "count": len(clusters)}

    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def get_cluster(cluster_id: str):
    """
    Get details of a specific OKE cluster including public/private endpoints, VCN, and available upgrades.
    Use this to determine which endpoint type (PUBLIC_ENDPOINT or PRIVATE_ENDPOINT) to pass to create_kubeconfig.
    If public_endpoint is not null, use PUBLIC_ENDPOINT. If private_endpoint is not null, use PRIVATE_ENDPOINT.

    Args:
        cluster_id (str): Cluster OCID

    Returns:
        dict: Cluster details including endpoints, endpoint config, vcn, k8s version, and available upgrades
    """
    try:
        c = ce_client.get_cluster(cluster_id=cluster_id).data

        endpoint_config = None
        if c.endpoint_config:
            endpoint_config = {
                "is_public_ip_enabled": getattr(c.endpoint_config, "is_public_ip_enabled", None),
                "subnet_id": getattr(c.endpoint_config, "subnet_id", None),
            }

        endpoints = None
        if c.endpoints:
            endpoints = {
                "kubernetes": getattr(c.endpoints, "kubernetes", None),
                "public_endpoint": getattr(c.endpoints, "public_endpoint", None),
                "private_endpoint": getattr(c.endpoints, "private_endpoint", None),
            }

        return {
            "status": "success",
            "cluster": {
                "id": c.id,
                "name": c.name,
                "state": c.lifecycle_state,
                "k8s_version": c.kubernetes_version,
                "vcn_id": c.vcn_id,
                "endpoint_config": endpoint_config,
                "endpoints": endpoints,
                "available_upgrades": c.available_kubernetes_upgrades
            }
        }

    except Exception as e:
        return {"status": "error", "message": str(e)}



@mcp.tool()
def list_node_pools(compartment_id: str, cluster_id: str):
    """
    List all node pools for a specific OKE cluster.

    Args:
        compartment_id (str): OCI compartment OCID
        cluster_id (str): Cluster OCID

    Returns:
        dict: List of node pools with id, name, shape, k8s version, and node count
    """
    try:
        resp = ce_client.list_node_pools(
            compartment_id=compartment_id, cluster_id=cluster_id
        ).data

        if not resp:
            return {"status": "success", "node_pools": [], "count": 0}

        pools = [{"id": np.id, "name": np.name, "node_shape": np.node_shape,
                   "k8s_version": np.kubernetes_version,
                   "node_count": np.node_config_details.size if np.node_config_details else None
                   } for np in resp]

        return {"status": "success", "node_pools": pools, "count": len(pools)}

    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def get_node_pool(node_pool_id: str):
    """
    Get details of a specific node pool including individual node states, IPs, and availability domains.

    Args:
        node_pool_id (str): Node pool OCID

    Returns:
        dict: Node pool details with node list, their lifecycle states, and IPs
    """
    try:
        np = ce_client.get_node_pool(node_pool_id=node_pool_id).data

        nodes = [{"id": n.id, "name": n.name, "state": n.lifecycle_state,
                   "private_ip": n.private_ip, "public_ip": n.public_ip,
                   "availability_domain": n.availability_domain
                   } for n in (np.nodes or [])]

        return {
            "status": "success",
            "node_pool": {
                "id": np.id, "name": np.name, "cluster_id": np.cluster_id,
                "node_shape": np.node_shape, "k8s_version": np.kubernetes_version
            },
            "nodes": nodes,
            "node_count": len(nodes)
        }

    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def create_kubeconfig(cluster_id: str, endpoint: str):
    """
    Generate kubeconfig for an OKE cluster and write to ~/.kube/config.
    Must be called before using kubectl commands via run_kubectl tool.
    Use get_cluster tool first to check which endpoints are available.
    If public_endpoint is not null, pass endpoint="PUBLIC_ENDPOINT".
    If private_endpoint is not null, pass endpoint="PRIVATE_ENDPOINT".

    Args:
        cluster_id (str): Cluster OCID
        endpoint (str): Endpoint type - "PUBLIC_ENDPOINT" or "PRIVATE_ENDPOINT"

    Returns:
        dict: Status, file path of generated kubeconfig, and endpoint type used
    """
    try:
        endpoint_map = {
            "PUBLIC_ENDPOINT": oci.container_engine.models.CreateClusterKubeconfigContentDetails.ENDPOINT_PUBLIC_ENDPOINT,
            "PRIVATE_ENDPOINT": oci.container_engine.models.CreateClusterKubeconfigContentDetails.ENDPOINT_PRIVATE_ENDPOINT,
        }

        endpoint_value = endpoint_map.get(endpoint.upper())
        if not endpoint_value:
            return {"status": "error", "message": f"Invalid endpoint type '{endpoint}'. Use PUBLIC_ENDPOINT or PRIVATE_ENDPOINT."}

        resp = ce_client.create_kubeconfig(
            cluster_id=cluster_id,
            create_cluster_kubeconfig_content_details=oci.container_engine.models.CreateClusterKubeconfigContentDetails(
                token_version="2.0.0",
                endpoint=endpoint_value
            )
        )

        path = os.path.expanduser("~/.kube/config")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(resp.data.text)

        return {"status": "success", "path": path, "cluster_id": cluster_id, "endpoint": endpoint}

    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def update_cluster(cluster_id: str, name: Optional[str] = None, k8s_version: Optional[str] = None):
    """
    Update an OKE cluster name or upgrade its Kubernetes version.
    Use get_cluster_options tool to find available k8s versions before upgrading.

    Args:
        cluster_id (str): Cluster OCID
        name (str): New cluster display name (optional)
        k8s_version (str): Target Kubernetes version to upgrade to (optional)

    Returns:
        dict: Work request ID to track the update progress via get_work_request tool
    """
    try:
        update_details = {}
        if name:
            update_details["name"] = name
        if k8s_version:
            update_details["kubernetes_version"] = k8s_version

        if not update_details:
            return {"status": "error", "message": "Provide at least one field to update (name or k8s_version)"}

        resp = ce_client.update_cluster(
            cluster_id=cluster_id,
            update_cluster_details=oci.container_engine.models.UpdateClusterDetails(**update_details)
        )

        return {
            "status": "success",
            "cluster_id": cluster_id,
            "work_request_id": resp.headers.get("opc-work-request-id")
        }

    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def delete_cluster(cluster_id: str):
    """
    Delete an OKE cluster. This is irreversible. All node pools must be deleted first.

    Args:
        cluster_id (str): Cluster OCID

    Returns:
        dict: Work request ID to track the deletion progress via get_work_request tool
    """
    try:
        resp = ce_client.delete_cluster(cluster_id=cluster_id)

        return {
            "status": "success",
            "cluster_id": cluster_id,
            "work_request_id": resp.headers.get("opc-work-request-id")
        }

    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def update_node_pool(node_pool_id: str, name: Optional[str] = None, k8s_version: Optional[str] = None, size: Optional[int] = None):
    """
    Update a node pool — change its name, upgrade Kubernetes version, or scale node count.
    To scale nodes, set size to desired count. Cluster k8s version must be upgraded first before node pool.

    Args:
        node_pool_id (str): Node pool OCID
        name (str): New node pool name (optional)
        k8s_version (str): Target Kubernetes version (optional)
        size (int): Desired number of worker nodes (optional)

    Returns:
        dict: Work request ID to track the update progress via get_work_request tool
    """
    try:
        update_details = {}
        if name:
            update_details["name"] = name
        if k8s_version:
            update_details["kubernetes_version"] = k8s_version
        if size is not None:
            update_details["node_config_details"] = oci.container_engine.models.UpdateNodePoolNodeConfigDetails(
                size=size
            )

        if not update_details:
            return {"status": "error", "message": "Provide at least one field to update (name, k8s_version, or size)"}

        resp = ce_client.update_node_pool(
            node_pool_id=node_pool_id,
            update_node_pool_details=oci.container_engine.models.UpdateNodePoolDetails(**update_details)
        )

        return {
            "status": "success",
            "node_pool_id": node_pool_id,
            "work_request_id": resp.headers.get("opc-work-request-id")
        }

    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def delete_node_pool(node_pool_id: str):
    """
    Delete an entire node pool from an OKE cluster. All nodes in the pool will be terminated.

    Args:
        node_pool_id (str): Node pool OCID

    Returns:
        dict: Work request ID to track the deletion progress via get_work_request tool
    """
    try:
        resp = ce_client.delete_node_pool(node_pool_id=node_pool_id)

        return {
            "status": "success",
            "node_pool_id": node_pool_id,
            "work_request_id": resp.headers.get("opc-work-request-id")
        }

    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def delete_node(node_pool_id: str, node_id: str, is_decrement: bool,
                eviction_grace_period_minutes: int,
                force_terminate_after_grace: bool):
    """
    Permanently delete (remove) a specific managed worker node. Use this tool only
    when the user explicitly asks to delete or remove a node. Do NOT use it for
    cycling, rebooting, replacing a node, or replacing its boot volume; use
    cycle_node for those actions. is_decrement=False still deletes the selected
    node and asks OKE to create a replacement, so it is a replacement operation,
    not a plain deletion.

    Args:
        node_pool_id (str): Node pool OCID
        node_id (str): Node OCID to remove
        is_decrement: Required choice. True decreases pool size by one; False provisions a replacement.
        eviction_grace_period_minutes: Required grace period from 0 to 60 minutes. 0 skips cordon/drain.
        force_terminate_after_grace: Required choice to force termination if pods are not drained by the grace-period deadline.

    Returns:
        On success: status, node_pool_id, node_id, is_decrement, and work_request_id.
        On failure: status="error" and an OCI service message.
    """
    try:
        if not isinstance(eviction_grace_period_minutes, int) or not 0 <= eviction_grace_period_minutes <= 60:
            return {"status": "error", "message": "eviction_grace_period_minutes must be an integer from 0 to 60"}
        resp = ce_client.delete_node(
            node_pool_id=node_pool_id,
            node_id=node_id,
            is_decrement_size=is_decrement,
            override_eviction_grace_duration=f"PT{eviction_grace_period_minutes}M",
            is_force_deletion_after_override_grace_duration=force_terminate_after_grace,
        )

        return {
            "status": "success",
            "node_pool_id": node_pool_id,
            "node_id": node_id,
            "is_decrement": is_decrement,
            "work_request_id": resp.headers.get("opc-work-request-id")
        }

    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def cycle_node(node_pool_id: str, node_id: str, cycling_option: str,
               eviction_grace_period_minutes: int,
               force_after_grace_duration: bool):
    """Cycle one managed worker node: reboot it, replace its boot volume, or
    replace the node while keeping the node pool size unchanged.

    ROUTING: For any request to cycle, reboot, replace, or refresh a node, call
    this cycle_node tool. Do not call delete_node for those requests. Use
    delete_node only when the user explicitly wants the node removed from the
    pool (with or without decreasing pool size).

    Args:
        node_pool_id: OCID of the node pool containing the node.
        node_id: OCID of the managed worker node.
        cycling_option: Required action. REBOOT_NODE reboots; REPLACE_BOOT_VOLUME
            replaces the boot volume; REPLACE_NODE replaces the node and keeps
            pool size unchanged. Required for every cycle_node call.
        eviction_grace_period_minutes: Required grace period from 0 to 60 minutes.
            0 skips cordon/drain where supported.
        force_after_grace_duration: Required choice to force the selected action if
            pods are not drained by the grace-period deadline.

    Returns:
        On success: status, node_pool_id, node_id, cycling_option, and work_request_id.
        On failure: status="error" and an OCI service message.

    Notes:
        REBOOT_NODE reboots the instance. REPLACE_BOOT_VOLUME replaces its boot
        volume. REPLACE_NODE terminates and recreates the instance, preserving
        pool size but resulting in a new node OCID and network address. This
        operation applies to managed nodes.
    """
    try:
        allowed_options = {"REBOOT_NODE", "REPLACE_BOOT_VOLUME", "REPLACE_NODE"}
        if cycling_option not in allowed_options:
            return {"status": "error", "message":
                    "cycling_option must be REBOOT_NODE, REPLACE_BOOT_VOLUME, or REPLACE_NODE"}
        if not isinstance(eviction_grace_period_minutes, int) or not 0 <= eviction_grace_period_minutes <= 60:
            return {"status": "error", "message": "eviction_grace_period_minutes must be an integer from 0 to 60"}

        pool = ce_client.get_node_pool(node_pool_id=node_pool_id).data
        cluster_id = pool.cluster_id
        duration = f"PT{eviction_grace_period_minutes}M"
        eviction = oci.container_engine.models.NodeEvictionSettings(
            eviction_grace_duration=duration,
            is_force_action_after_grace_duration=force_after_grace_duration)

        if cycling_option == "REBOOT_NODE":
            resp = ce_client.reboot_cluster_node(
                cluster_id=cluster_id, node_id=node_id,
                reboot_cluster_node_details=oci.container_engine.models.RebootClusterNodeDetails(
                    node_eviction_settings=eviction))
        elif cycling_option == "REPLACE_BOOT_VOLUME":
            resp = ce_client.replace_boot_volume_cluster_node(
                cluster_id=cluster_id, node_id=node_id,
                replace_boot_volume_cluster_node_details=oci.container_engine.models.ReplaceBootVolumeClusterNodeDetails(
                    node_eviction_settings=eviction))
        else:
            resp = ce_client.delete_node(
                node_pool_id=node_pool_id, node_id=node_id, is_decrement_size=False,
                override_eviction_grace_duration=duration,
                is_force_deletion_after_override_grace_duration=force_after_grace_duration)
        return {
            "status": "success",
            "node_pool_id": node_pool_id,
            "node_id": node_id,
            "cycling_option": cycling_option,
            "work_request_id": resp.headers.get("opc-work-request-id"),
        }
    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def list_work_requests(compartment_id: str, cluster_id: str):
    """
    List all async work requests (create, update, delete operations) for an OKE cluster.
    Use this to check the progress of cluster or node pool operations.

    Args:
        compartment_id (str): OCI compartment OCID
        cluster_id (str): Cluster OCID

    Returns:
        dict: List of work requests with operation type, status, and timestamps
    """
    try:
        resp = ce_client.list_work_requests(
            compartment_id=compartment_id, cluster_id=cluster_id
        ).data

        if not resp:
            return {"status": "success", "work_requests": [], "count": 0}

        requests = [{"id": wr.id, "operation": wr.operation_type,
                      "status": wr.status, "time_started": str(wr.time_started),
                      "time_finished": str(wr.time_finished)
                      } for wr in resp]

        return {"status": "success", "work_requests": requests, "count": len(requests)}

    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def get_work_request(work_request_id: str):
    """
    Get the current status of a specific OKE work request.
    Use this after any cluster/node pool create, update, or delete operation to track progress.

    Args:
        work_request_id (str): Work request OCID (returned by update/delete/create operations)

    Returns:
        dict: Work request details with operation type, status, and timestamps
    """
    try:
        wr = ce_client.get_work_request(work_request_id=work_request_id).data

        return {
            "status": "success",
            "work_request": {
                "id": wr.id, "operation": wr.operation_type,
                "status": wr.status,
                "time_started": str(wr.time_started),
                "time_finished": str(wr.time_finished),
                "time_accepted": str(wr.time_accepted)
            }
        }

    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def get_cluster_options(cluster_option_id: str = "all"):
    """
    Get supported Kubernetes versions and network options available for OKE.
    Use this before upgrading a cluster to find valid target k8s versions.

    Args:
        cluster_option_id (str): Option set ID. Default "all" returns all available options.

    Returns:
        dict: List of available Kubernetes versions
    """
    try:
        resp = ce_client.get_cluster_options(cluster_option_id=cluster_option_id).data

        return {
            "status": "success",
            "k8s_versions": resp.kubernetes_versions
        }

    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def list_addons(cluster_id: str):
    """
    List all installed add-ons on an OKE cluster (e.g., CoreDNS, KubeProxy, Flannel).

    Args:
        cluster_id (str): Cluster OCID

    Returns:
        dict: List of add-ons with name, lifecycle state, and installed version
    """
    try:
        resp = ce_client.list_addons(cluster_id=cluster_id).data

        if not resp:
            return {"status": "success", "addons": [], "count": 0}

        addons = [{"name": a.name, "state": a.lifecycle_state,
                    "version": a.current_installed_version
                    } for a in resp]

        return {"status": "success", "addons": addons, "count": len(addons)}

    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def create_cluster(compartment_id: str, name: str, kubernetes_version: str,
                   vcn_id: str, endpoint_subnet_id: str,
                   cluster_type: str,
                   is_public_ip_enabled: bool,
                   pod_network_cni_type: Optional[str] = None,
                   freeform_tags: Optional[Dict[str, str]] = None):
    """Create an OKE control-plane cluster from explicit OCI settings.

    Conversation guidance:
        If the user requests a cluster but omits required arguments, ask only for
        those missing cluster arguments before calling this tool. Use
        list_compartments, list_vcns, list_subnets, and get_cluster_options to
        help identify valid values. Do not ask for worker shape, node count, boot
        volume, SSH key, worker subnet, or pod subnet here; those belong to the
        separate create_node_pool call after cluster creation.
        Add-ons are optional and are installed after the cluster exists. Ask
        whether the user wants any add-ons, but do not block cluster creation on
        that choice. After creation, use list_addon_options and install_addon.

    Args:
        compartment_id: OCID of the cluster's compartment.
        name: Display name for the cluster.
        kubernetes_version: Kubernetes control-plane version.
        vcn_id: OCID of the cluster VCN.
        endpoint_subnet_id: Subnet OCID for the Kubernetes API endpoint.
        is_public_ip_enabled: Required endpoint visibility choice: true for public,
            false for private.
        cluster_type: Required cluster type: BASIC_CLUSTER or ENHANCED_CLUSTER.
        pod_network_cni_type: Optional OCI_VCN_IP_NATIVE or FLANNEL_OVERLAY CNI.
        freeform_tags: Optional freeform tags applied to the cluster.

    Returns:
        On success: status, cluster_id, cluster_name, and work_request_id.
        On failure: status="error" and a validation or OCI service message.
    """
    try:
        if cluster_type not in {"BASIC_CLUSTER", "ENHANCED_CLUSTER"}:
            return {"status": "error", "message": "cluster_type must be BASIC_CLUSTER or ENHANCED_CLUSTER"}
        endpoint_config = oci.container_engine.models.CreateClusterEndpointConfigDetails(
            subnet_id=endpoint_subnet_id,
            is_public_ip_enabled=is_public_ip_enabled)
        details_args = {
            "compartment_id": compartment_id,
            "name": name,
            "kubernetes_version": kubernetes_version,
            "vcn_id": vcn_id,
            "endpoint_config": endpoint_config,
            "freeform_tags": freeform_tags,
            "type": cluster_type,
        }
        if pod_network_cni_type:
            pod_models = {
                "OCI_VCN_IP_NATIVE": oci.container_engine.models.OciVcnIpNativeClusterPodNetworkOptionDetails,
                "FLANNEL_OVERLAY": oci.container_engine.models.FlannelOverlayClusterPodNetworkOptionDetails,
            }
            if pod_network_cni_type not in pod_models:
                return {"status": "error", "message": "pod_network_cni_type must be OCI_VCN_IP_NATIVE or FLANNEL_OVERLAY"}
            details_args["cluster_pod_network_options"] = [
                pod_models[pod_network_cni_type](cni_type=pod_network_cni_type)]
        details = oci.container_engine.models.CreateClusterDetails(
            **{key: value for key, value in details_args.items() if value is not None})
        resp = ce_client.create_cluster(create_cluster_details=details)
        return {
            "status": "success", "cluster_id": getattr(resp.data, "id", None),
            "cluster_name": name,
            "work_request_id": resp.headers.get("opc-work-request-id"),
        }
    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def create_node_pool(
    compartment_id: str,
    cluster_id: str,
    name: str,
    kubernetes_version: str,
    node_shape: str,
    size: int,
    availability_domain: str,
    node_subnet_id: str,
    pool_subnet_id: str,
    node_type: str,
    node_image_name: Optional[str] = None,
    image_id: Optional[str] = None,
    ssh_public_key: Optional[str] = None,
    boot_volume_size_in_gbs: int = 50,
    ocpus: Optional[float] = None,
    memory_in_gbs: Optional[float] = None,
    initial_node_labels: Optional[List[Dict[str, str]]] = None,
    pod_nsg_ids: Optional[List[str]] = None,
    nsg_ids: Optional[List[str]] = None,
    max_pods_per_node: Optional[int] = None,
    network_launch_type: Optional[str] = None,
    capacity_type: str = "ON_DEMAND",
    capacity_reservation_id: Optional[str] = None,
    preserve_boot_volume_on_preemption: bool = False,
    cloud_init_script: Optional[str] = None,
    node_metadata: Optional[Dict[str, str]] = None,
    node_pool_cycling_enabled: Optional[bool] = None,
    node_pool_cycling_max_surge: Optional[str] = None,
    node_pool_cycling_max_unavailable: Optional[str] = None,
    node_eviction_grace_duration: Optional[str] = None,
    is_force_delete_after_grace_duration: Optional[bool] = None,
    is_force_action_after_grace_duration: Optional[bool] = None,
    freeform_tags: Optional[Dict[str, str]] = None,
):
    """Create a managed or virtual OKE node pool and return its OCID and work request.

    Args:
        compartment_id: OCID of the node pool's compartment.
        cluster_id: OCID of the target OKE cluster.
        name: Display name for the node pool.
        kubernetes_version: Kubernetes version for the worker nodes.
        node_shape: Compute shape for managed nodes, or pod shape for virtual nodes.
        size: Desired number of nodes.
        availability_domain: Availability domain for the worker nodes.
        node_subnet_id: Subnet for managed worker-node VNICs or virtual-node placement.
        pool_subnet_id: Pod subnet for VCN-native networking; required for virtual pools.
        node_type: Either MANAGED or VIRTUAL.
        node_image_name: Supported OKE image name for managed nodes. Call
            get_node_pool_options first and choose a source_name matching the
            requested Kubernetes version. Use this or image_id, not both.
        image_id: OCID of a custom image for managed nodes. Use this or
            node_image_name, not both.
        ssh_public_key: SSH public key for managed worker nodes.
        boot_volume_size_in_gbs: Managed worker boot volume size. Defaults to 50 GiB.
        ocpus: OCPUs for a flexible managed-node shape; provide with memory_in_gbs.
        memory_in_gbs: Memory for a flexible managed-node shape; provide with ocpus.
        initial_node_labels: Kubernetes labels as key/value objects.
        pod_nsg_ids: Network security group OCIDs for pod networking.
        nsg_ids: Network security group OCIDs for node networking.
        max_pods_per_node: Maximum pods per managed node when using VCN-native CNI.
        network_launch_type: Managed-node launch type: VFIO, E1000, or PARAVIRTUALIZED.
        capacity_type: Managed-node capacity: ON_DEMAND, PREEMPTIBLE, or
            CAPACITY_RESERVATION. Defaults to ON_DEMAND.
        capacity_reservation_id: Reservation OCID; required for CAPACITY_RESERVATION.
        preserve_boot_volume_on_preemption: Preserve a managed node's boot volume
            when preemptible capacity is reclaimed.
        cloud_init_script: Optional cloud-config user data for managed nodes. The
            tool adds the #cloud-config header when it is missing and base64 encodes it.
        node_metadata: Additional string metadata for managed worker nodes.
        node_pool_cycling_enabled: Enable managed-node cycling during updates.
        node_pool_cycling_max_surge: Maximum extra nodes during cycling, as a count or percent.
        node_pool_cycling_max_unavailable: Maximum unavailable nodes during cycling.
        node_eviction_grace_duration: Grace period for managed-node eviction, such as PT30M.
        is_force_delete_after_grace_duration: Force-delete nodes after the grace period.
        is_force_action_after_grace_duration: Force the configured node eviction action after grace.
        freeform_tags: Freeform tags applied to the node pool.

    Returns:
        On success: status, node_pool_id, node_pool_name, node_type, and work_request_id.
        On failure: status="error" and a message describing validation or OCI service failure.

    Notes:
        For managed pools, the tool checks the Kubernetes version, shape, and named OKE
        image against current get_node_pool_options results before submitting the create.
        Virtual pools use the virtual node pool API and do not accept image, SSH, cloud-init,
        managed capacity, or managed network-launch settings.
    """
    try:
        if node_type not in {"MANAGED", "VIRTUAL"}:
            return {"status": "error", "message": "node_type must be MANAGED or VIRTUAL"}
        if node_type == "MANAGED" and not (node_image_name or image_id):
            return {"status": "error", "message": "For MANAGED nodes, provide node_image_name from get_node_pool_options or a custom image_id"}
        if node_type == "MANAGED" and node_image_name and image_id:
            return {"status": "error", "message": "Provide node_image_name or image_id, not both"}
        if (ocpus is None) != (memory_in_gbs is None):
            return {"status": "error", "message": "Provide both ocpus and memory_in_gbs for a flexible node shape"}
        if network_launch_type not in {None, "VFIO", "E1000", "PARAVIRTUALIZED"}:
            return {"status": "error", "message": "network_launch_type must be VFIO, E1000, or PARAVIRTUALIZED"}
        if capacity_type not in {"ON_DEMAND", "PREEMPTIBLE", "CAPACITY_RESERVATION"}:
            return {"status": "error", "message": "capacity_type must be ON_DEMAND, PREEMPTIBLE, or CAPACITY_RESERVATION"}
        if capacity_type == "CAPACITY_RESERVATION" and not capacity_reservation_id:
            return {"status": "error", "message": "capacity_reservation_id is required for CAPACITY_RESERVATION capacity"}
        if capacity_type == "PREEMPTIBLE" and capacity_reservation_id:
            return {"status": "error", "message": "capacity_reservation_id cannot be combined with PREEMPTIBLE capacity"}

        if node_type == "MANAGED":
            # Confirm the selected shape, Kubernetes version, and Oracle image
            # against OKE's current option set before submitting the request.
            options = ce_client.get_node_pool_options(
                node_pool_option_id=cluster_id,
                compartment_id=compartment_id,
                node_pool_k8s_version=kubernetes_version).data
            if options.shapes and node_shape not in options.shapes:
                return {"status": "error", "message": f"Unsupported node_shape '{node_shape}' for this cluster"}
            if options.kubernetes_versions and kubernetes_version not in options.kubernetes_versions:
                return {"status": "error", "message": f"Unsupported Kubernetes version '{kubernetes_version}' for this cluster"}
            if node_image_name and options.sources:
                supported_images = {item.source_name for item in options.sources if item.source_type == "IMAGE"}
                if node_image_name not in supported_images:
                    return {"status": "error", "message": f"Unsupported OKE node_image_name '{node_image_name}' for this Kubernetes version"}

        if node_type == "VIRTUAL":
            if image_id or node_image_name or ssh_public_key or cloud_init_script:
                return {"status": "error", "message": "VIRTUAL nodes do not take an image, SSH key, or cloud-init script"}
            if ocpus is not None or memory_in_gbs is not None or network_launch_type or capacity_type != "ON_DEMAND" or capacity_reservation_id:
                return {"status": "error", "message": "VIRTUAL nodes do not support shape configuration, network_launch_type, or managed-node capacity settings"}
            if node_pool_cycling_enabled is not None or node_pool_cycling_max_surge is not None or node_pool_cycling_max_unavailable is not None:
                cycling = oci.container_engine.models.VirtualNodePoolCyclingDetails(
                    is_virtual_node_cycling_enabled=node_pool_cycling_enabled,
                    maximum_surge=node_pool_cycling_max_surge,
                    maximum_unavailable=node_pool_cycling_max_unavailable)
            else:
                cycling = None
            virtual_details_args = {
                "compartment_id": compartment_id,
                "cluster_id": cluster_id,
                "display_name": name,
                "size": size,
                "placement_configurations": [oci.container_engine.models.PlacementConfiguration(
                    availability_domain=availability_domain, subnet_id=node_subnet_id)],
                "pod_configuration": oci.container_engine.models.PodConfiguration(
                    subnet_id=pool_subnet_id, nsg_ids=pod_nsg_ids, shape=node_shape),
                "nsg_ids": nsg_ids,
                "freeform_tags": freeform_tags,
                "virtual_node_pool_cycling_details": cycling,
            }
            if initial_node_labels:
                virtual_details_args["initial_virtual_node_labels"] = [
                    oci.container_engine.models.InitialVirtualNodeLabel(key=item["key"], value=item["value"])
                    for item in initial_node_labels]
            resp = ce_client.create_virtual_node_pool(
                create_virtual_node_pool_details=oci.container_engine.models.CreateVirtualNodePoolDetails(
                    **{key: value for key, value in virtual_details_args.items() if value is not None}))
            return {"status": "success", "node_pool_id": getattr(resp.data, "id", None),
                    "node_pool_name": name, "node_type": node_type,
                    "work_request_id": resp.headers.get("opc-work-request-id")}

        placement_args = {
            "availability_domain": availability_domain,
            "subnet_id": node_subnet_id,
            "capacity_reservation_id": capacity_reservation_id,
        }
        if capacity_type == "PREEMPTIBLE":
            placement_args["preemptible_node_config"] = oci.container_engine.models.PreemptibleNodeConfigDetails(
                preemption_action=oci.container_engine.models.TerminatePreemptionAction(
                    type="TERMINATE",
                    is_preserve_boot_volume=preserve_boot_volume_on_preemption))
        placement = oci.container_engine.models.NodePoolPlacementConfigDetails(
            **{key: value for key, value in placement_args.items() if value is not None})

        node_metadata = dict(node_metadata or {})
        if cloud_init_script:
            if "user_data" in node_metadata:
                return {"status": "error", "message": "Do not provide user_data in node_metadata together with cloud_init_script"}
            cloud_config = cloud_init_script.replace("&#10;", "\n").replace("&#13;", "\r")
            if not cloud_config.lstrip().startswith("#cloud-config"):
                cloud_config = "#cloud-config\n" + cloud_config
            node_metadata["user_data"] = base64.b64encode(cloud_config.encode("utf-8")).decode("ascii")

        pod_network_details = None
        if pool_subnet_id or pod_nsg_ids or max_pods_per_node is not None:
            pod_network_details = oci.container_engine.models.OciVcnIpNativeNodePoolPodNetworkOptionDetails(
                cni_type="OCI_VCN_IP_NATIVE",
                pod_subnet_ids=[pool_subnet_id] if pool_subnet_id else None,
                pod_nsg_ids=pod_nsg_ids,
                max_pods_per_node=max_pods_per_node)

        node_config_details = oci.container_engine.models.CreateNodePoolNodeConfigDetails(
            size=size,
            nsg_ids=nsg_ids,
            placement_configs=[placement],
            node_pool_pod_network_option_details=pod_network_details)
        details_args = {
            "compartment_id": compartment_id,
            "cluster_id": cluster_id,
            "name": name,
            "kubernetes_version": kubernetes_version,
            "node_shape": node_shape,
            "node_config_details": node_config_details,
            "ssh_public_key": ssh_public_key,
            "node_metadata": node_metadata or None,
            "network_launch_type": network_launch_type,
            "freeform_tags": freeform_tags,
        }
        if image_id:
            details_args["node_source_details"] = oci.container_engine.models.NodeSourceViaImageDetails(
                source_type="IMAGE", image_id=image_id,
                boot_volume_size_in_gbs=boot_volume_size_in_gbs)
        else:
            details_args["node_image_name"] = node_image_name
        if ocpus is not None:
            details_args["node_shape_config"] = oci.container_engine.models.CreateNodeShapeConfigDetails(
                ocpus=ocpus, memory_in_gbs=memory_in_gbs)
        if initial_node_labels:
            details_args["initial_node_labels"] = [
                oci.container_engine.models.KeyValue(key=label["key"], value=label["value"])
                for label in initial_node_labels]
        if node_pool_cycling_enabled is not None or node_pool_cycling_max_surge is not None or node_pool_cycling_max_unavailable is not None:
            details_args["node_pool_cycling_details"] = oci.container_engine.models.NodePoolCyclingDetails(
                is_node_cycling_enabled=node_pool_cycling_enabled,
                maximum_surge=node_pool_cycling_max_surge,
                maximum_unavailable=node_pool_cycling_max_unavailable)
        if node_eviction_grace_duration is not None or is_force_delete_after_grace_duration is not None or is_force_action_after_grace_duration is not None:
            details_args["node_eviction_node_pool_settings"] = oci.container_engine.models.NodeEvictionNodePoolSettings(
                eviction_grace_duration=node_eviction_grace_duration,
                is_force_delete_after_grace_duration=is_force_delete_after_grace_duration,
                is_force_action_after_grace_duration=is_force_action_after_grace_duration)
        details = oci.container_engine.models.CreateNodePoolDetails(
            **{key: value for key, value in details_args.items() if value is not None})
        resp = ce_client.create_node_pool(create_node_pool_details=details)
        return {
            "status": "success", "node_pool_id": getattr(resp.data, "id", None),
            "node_pool_name": name,
            "node_type": node_type,
            "work_request_id": resp.headers.get("opc-work-request-id"),
        }
    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def get_work_request_errors(work_request_id: str):
    """Return OCI service errors reported for an OKE work request.

    Args:
        work_request_id: OCID of the OKE work request.

    Returns:
        On success: status, work_request_id, errors, and count.
        On failure: status="error" and an OCI service message.
    """
    try:
        response = oci.pagination.list_call_get_all_results(
            work_requests_client.list_work_request_errors,
            work_request_id=work_request_id)
        data = response.data
        return {"status": "success", "work_request_id": work_request_id,
                "errors": oci.util.to_dict(data), "count": len(data or [])}
    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def get_work_request_logs(work_request_id: str):
    """Return service log entries reported for an OKE work request.

    Args:
        work_request_id: OCID of the OKE work request.

    Returns:
        On success: status, work_request_id, logs, and count.
        On failure: status="error" and an OCI service message.
    """
    try:
        response = oci.pagination.list_call_get_all_results(
            work_requests_client.list_work_request_logs,
            work_request_id=work_request_id)
        data = response.data
        return {"status": "success", "work_request_id": work_request_id,
                "logs": oci.util.to_dict(data), "count": len(data or [])}
    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def get_node_pool_options(node_pool_option_id: str = "all", compartment_id: Optional[str] = None,
                          node_pool_os_type: Optional[str] = None,
                          node_pool_os_arch: Optional[str] = None,
                          node_pool_k8s_version: Optional[str] = None,
                          should_list_all_patch_versions: Optional[bool] = None):
    """Get supported node pool images, shapes, and Kubernetes versions.

    Args:
        node_pool_option_id: OKE option ID, usually "all".
        compartment_id: Optional compartment OCID for option filtering.
        node_pool_os_type: Optional operating-system type filter.
        node_pool_os_arch: Optional operating-system architecture filter.
        node_pool_k8s_version: Optional Kubernetes version filter.
        should_list_all_patch_versions: Whether to include all patch versions.

    Returns:
        On success: status and the OCI node-pool options object.
        On failure: status="error" and an OCI service message.
    """
    try:
        kwargs = {"compartment_id": compartment_id, "node_pool_os_type": node_pool_os_type,
                  "node_pool_os_arch": node_pool_os_arch,
                  "node_pool_k8s_version": node_pool_k8s_version,
                  "should_list_all_patch_versions": should_list_all_patch_versions}
        resp = ce_client.get_node_pool_options(
            node_pool_option_id=node_pool_option_id,
            **{key: value for key, value in kwargs.items() if value is not None}).data
        return {"status": "success", "options": oci.util.to_dict(resp)}
    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def list_addon_options(kubernetes_version: str, addon_name: Optional[str] = None):
    """List add-ons supported for a Kubernetes version.

    Args:
        kubernetes_version: Kubernetes version to query.
        addon_name: Optional add-on name to filter the results.

    Returns:
        On success: status, kubernetes_version, addon_options, and count.
        On failure: status="error" and an OCI service message.
    """
    try:
        kwargs = {"addon_name": addon_name} if addon_name else {}
        data = ce_client.list_addon_options(kubernetes_version=kubernetes_version, **kwargs).data
        return {"status": "success", "kubernetes_version": kubernetes_version,
                "addon_options": oci.util.to_dict(data), "count": len(data or [])}
    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def install_addon(cluster_id: str, addon_name: str, update_policy: str,
                  version: Optional[str] = None,
                  configurations: Optional[List[Dict[str, str]]] = None,
                  is_override_existing: bool = False):
    """Install or enable an add-on on an OKE cluster.

    Args:
        cluster_id: OCID of the target cluster.
        addon_name: OKE add-on name.
        update_policy: Required version policy: AUTOMATIC or PINNED. AUTOMATIC
            lets OKE select/update a compatible version and must omit version.
            PINNED requires version.
        version: Required when update_policy is PINNED; choose an ACTIVE version
            returned by list_addon_options for the cluster's Kubernetes version.
        configurations: Optional list of approved add-on configuration key/value
            objects. Use list_addon_options to see the keys, required flags, and
            defaults. Supply only required values or optional overrides.
            For ClusterAutoscaler, configure exactly one of `nodes` with value
            `<min>:<max>:<node_pool_ocid>` or `nodeGroupAutoDiscovery` with value
            `compartmentId:<compartment_ocid>,nodepoolTags:<key>=<value>,min:<min>,max:<max>`.
            Do not pass min/max as separate configuration keys.
        is_override_existing: Whether to override an existing add-on installation.

    Returns:
        Work-request status and identifiers returned by OKE.
        On failure: status="error" and an OCI service message.

    Notes:
        Cluster Autoscaler manages managed node pools only. Its workload needs
        the instance-principal or workload-identity setup and IAM policy described
        in Oracle's OKE guide; installing the add-on does not create those policies.
    """
    try:
        if update_policy not in {"AUTOMATIC", "PINNED"}:
            return {"status": "error", "message":
                    "update_policy must be AUTOMATIC or PINNED"}
        if update_policy == "AUTOMATIC" and version is not None:
            return {"status": "error", "message":
                    "Omit version when update_policy is AUTOMATIC; choose PINNED to specify a version"}
        if update_policy == "PINNED" and not version:
            return {"status": "error", "message":
                    "version is required when update_policy is PINNED"}
        # Validate user-supplied configuration against the OKE schema before
        # sending an install request. This produces actionable errors for keys
        # such as minNodeCount/maxNodeCount that OKE does not support.
        cluster = ce_client.get_cluster(cluster_id=cluster_id).data
        option_data = ce_client.list_addon_options(
            kubernetes_version=cluster.kubernetes_version,
            addon_name=addon_name).data or []
        addon_option = next(
            (item for item in option_data if item.name.lower() == addon_name.lower()),
            None)
        if addon_option:
            addon_versions = [item for item in (addon_option.versions or [])
                              if item.status == "ACTIVE"]
            selected = next((item for item in addon_versions
                             if version and item.version_number == version), None)
            if version and selected is None:
                return {"status": "error", "message":
                        f"Version '{version}' is not an ACTIVE version of {addon_name} "
                        f"for Kubernetes {cluster.kubernetes_version}. Supported ACTIVE "
                        f"versions: {[item.version_number for item in addon_versions]}"}
            if selected is None and addon_versions:
                selected = addon_versions[0]

            supported_keys = ({item.key for item in (selected.configurations or [])}
                              if selected else set())
            supplied_keys = [item.get("key") for item in (configurations or [])]
            invalid_keys = sorted({key for key in supplied_keys
                                   if key and supported_keys and key not in supported_keys})
            if invalid_keys:
                message = (f"Unsupported {addon_name} configuration key(s): "
                           f"{', '.join(invalid_keys)}. Supported keys include: "
                           f"{', '.join(sorted(supported_keys))}.")
                if addon_name.lower() == "clusterautoscaler":
                    message += (" Configure min/max within one `nodes` value "
                                "(`<min>:<max>:<node_pool_ocid>`) or one "
                                "`nodeGroupAutoDiscovery` value "
                                "(`compartmentId:<ocid>,nodepoolTags:<key>=<value>,min:<min>,max:<max>`); "
                                "minNodeCount, maxNodeCount, minNodes, and maxNodes are not keys.")
                return {"status": "error", "message": message}

        if addon_name.lower() == "clusterautoscaler":
            config_keys = {item.get("key") for item in (configurations or [])}
            has_nodes = "nodes" in config_keys
            has_discovery = "nodeGroupAutoDiscovery" in config_keys
            if has_nodes and has_discovery:
                return {"status": "error", "message":
                        "ClusterAutoscaler accepts `nodes` or `nodeGroupAutoDiscovery`, not both."}
            if not has_nodes and not has_discovery:
                return {"status": "error", "message":
                        "ClusterAutoscaler requires exactly one configuration: `nodes` with "
                        "value `<min>:<max>:<node_pool_ocid>`, or `nodeGroupAutoDiscovery` "
                        "with value `compartmentId:<compartment_ocid>,nodepoolTags:<key>=<value>,"
                        "min:<min>,max:<max>`. These keys are alternatives; do not pass "
                        "minNodeCount, maxNodeCount, minNodes, or maxNodes."}

        addon_configs = [oci.container_engine.models.AddonConfiguration(**item)
                         for item in (configurations or [])]
        details = oci.container_engine.models.InstallAddonDetails(
            addon_name=addon_name, version=version,
            configurations=addon_configs or None,
            is_override_existing=is_override_existing)
        resp = ce_client.install_addon(cluster_id=cluster_id, install_addon_details=details)
        return _work_request_result(resp, "cluster_id", cluster_id)
    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def update_addon(cluster_id: str, addon_name: str, version: Optional[str] = None,
                 configurations: Optional[List[Dict[str, str]]] = None):
    """Update an installed add-on's version or configuration.

    Args:
        cluster_id: OCID of the target cluster.
        addon_name: Name of the installed add-on.
        version: Optional replacement add-on version.
        configurations: Optional replacement configuration key/value objects.

    Returns:
        Work-request status and identifiers returned by OKE.
        On failure: status="error" and an OCI service or validation message.
    """
    if version is None and not configurations:
        return {"status": "error", "message": "Provide a version or configurations to update"}
    try:
        addon_configs = [oci.container_engine.models.AddonConfiguration(**item)
                         for item in (configurations or [])]
        details = oci.container_engine.models.UpdateAddonDetails(
            version=version, configurations=addon_configs or None)
        resp = ce_client.update_addon(cluster_id=cluster_id, addon_name=addon_name,
                                      update_addon_details=details)
        return _work_request_result(resp, "cluster_id", cluster_id)
    except Exception as e:
        return {"status": "error", "message": str(e)}


@mcp.tool()
def disable_addon(cluster_id: str, addon_name: str, remove_existing_resources: bool):
    """Disable an add-on and choose whether its resources are removed.

    Args:
        cluster_id: OCID of the target cluster.
        addon_name: Name of the add-on to disable.
        remove_existing_resources: Whether to remove resources created by the add-on.

    Returns:
        Work-request status and identifiers returned by OKE.
        On failure: status="error" and an OCI service message.
    """
    try:
        resp = ce_client.disable_addon(
            cluster_id=cluster_id, addon_name=addon_name,
            is_remove_existing_add_on=remove_existing_resources)
        return _work_request_result(resp, "cluster_id", cluster_id)
    except Exception as e:
        return {"status": "error", "message": str(e)}

@mcp.custom_route("/healthz", methods=["GET"])
async def health_check(request):
    return JSONResponse({"status": "healthy", "service": "oci-instance-mcp-server"})


@mcp.custom_route("/ready", methods=["GET"])
async def readiness_check(request):
    return JSONResponse({"status": "healthy", "service": "oci-instance-mcp-server"})

def main() -> None:
    mcp.run(transport="streamable-http", port=8080, host="0.0.0.0")


if __name__ == "__main__":
    main()
