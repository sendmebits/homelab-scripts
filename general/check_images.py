#!/usr/bin/env python3
"""
Docker Image Update Checker
Scans docker compose files and checks running containers for available updates.

Pre-reqs:
> sudo apt install python3-yaml python3-requests

"""

import os
import sys
import yaml
import subprocess
import json
import requests
from datetime import datetime
from typing import Dict, List, Tuple, Optional
from pathlib import Path

# Configuration
COMPOSE_BASE_DIR = "/opt/stacks/"
DOCKER_HUB_API = "https://registry.hub.docker.com/v2"
REQUEST_TIMEOUT = 10

class Colors:
    """ANSI color codes for terminal output"""
    HEADER = '\033[95m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    END = '\033[0m'
    BOLD = '\033[1m'
    UNDERLINE = '\033[4m'


def find_compose_files(base_dir: str) -> List[Path]:
    """Recursively find all docker-compose.yaml files"""
    compose_files = []
    base_path = Path(base_dir)
    
    if not base_path.exists():
        print(f"{Colors.RED}Error: Directory {base_dir} does not exist{Colors.END}")
        return []
    
    for pattern in ['docker-compose.yml', 'docker-compose.yaml', 'compose.yml', 'compose.yaml']:
        compose_files.extend(base_path.rglob(pattern))
    
    return compose_files


def parse_compose_file(file_path: Path) -> Dict[str, str]:
    """Parse compose file and extract image definitions"""
    images = {}
    
    try:
        with open(file_path, 'r') as f:
            compose_data = yaml.safe_load(f)
        
        if not compose_data:
            return images
        
        services = compose_data.get('services', {})
        for service_name, service_config in services.items():
            if isinstance(service_config, dict) and 'image' in service_config:
                image = service_config['image']
                images[service_name] = image
    
    except Exception as e:
        print(f"{Colors.YELLOW}Warning: Could not parse {file_path}: {e}{Colors.END}")
    
    return images


def get_running_containers() -> Dict[str, Dict]:
    """Get list of running containers with their image info"""
    try:
        result = subprocess.run(
            ['docker', 'ps', '--format', '{{json .}}'],
            capture_output=True,
            text=True,
            check=True
        )
        
        containers = {}
        for line in result.stdout.strip().split('\n'):
            if line:
                container = json.loads(line)
                container_name = container['Names']
                image = container['Image']
                containers[container_name] = {
                    'image': image,
                    'id': container['ID'],
                    'created': container['CreatedAt']
                }
        
        return containers
    
    except subprocess.CalledProcessError as e:
        print(f"{Colors.RED}Error running docker command: {e}{Colors.END}")
        return {}


def parse_image_name(image: str) -> Tuple[str, str, str]:
    """Parse image into registry, repository, and tag
    Returns: (registry, repo, tag)
    """
    # Handle registry prefix (e.g., ghcr.io/user/image:tag)
    parts = image.split('/')
    
    if len(parts) >= 2 and '.' in parts[0]:
        # Has registry (ghcr.io, docker.n8n.io, etc.)
        registry = parts[0]
        repo_parts = parts[1:]
        repo_with_tag = '/'.join(repo_parts)
        
        if ':' in repo_with_tag:
            repo = repo_with_tag.rsplit(':', 1)[0]
            tag = repo_with_tag.rsplit(':', 1)[1]
        else:
            repo = repo_with_tag
            tag = 'latest'
        
        full_repo = '/'.join(parts[1:]).split(':')[0]
        return registry, full_repo, tag
    elif len(parts) == 2:
        # Official or user repo without registry
        registry = 'docker.io'
        repo = f"{parts[0]}/{parts[1].split(':')[0]}"
        tag = parts[1].split(':')[1] if ':' in parts[1] else 'latest'
    else:
        # Official image (e.g., nginx:latest)
        registry = 'docker.io'
        repo = f"library/{parts[0].split(':')[0]}"
        tag = parts[0].split(':')[1] if ':' in parts[0] else 'latest'
    
    return registry, repo, tag


def get_docker_hub_token(repo: str) -> Optional[str]:
    """Get authentication token for Docker Hub API"""
    try:
        response = requests.get(
            f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull",
            timeout=REQUEST_TIMEOUT
        )
        if response.status_code == 200:
            return response.json().get('token')
    except Exception as e:
        # Silently fail for token retrieval
        pass
    
    return None


def get_ghcr_token(repo: str) -> Optional[str]:
    """Get authentication token for GitHub Container Registry"""
    try:
        response = requests.get(
            f"https://ghcr.io/token?scope=repository:{repo}:pull",
            timeout=REQUEST_TIMEOUT
        )
        if response.status_code == 200:
            return response.json().get('token')
    except Exception as e:
        pass
    
    return None


def get_ghcr_digest(repo: str, tag: str) -> Optional[str]:
    """Get digest from GitHub Container Registry"""
    try:
        # Get authentication token
        token = get_ghcr_token(repo)
        
        headers = {
            'Accept': 'application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.index.v1+json'
        }
        
        if token:
            headers['Authorization'] = f'Bearer {token}'
        
        response = requests.get(
            f"https://ghcr.io/v2/{repo}/manifests/{tag}",
            headers=headers,
            timeout=REQUEST_TIMEOUT
        )
        
        if response.status_code == 200:
            digest = response.headers.get('Docker-Content-Digest')
            if digest:
                return digest
            # If no digest in header, compute from response
            import hashlib
            manifest_bytes = response.content
            digest_hash = hashlib.sha256(manifest_bytes).hexdigest()
            return f"sha256:{digest_hash}"
    
    except Exception as e:
        pass
    
    return None


def get_generic_registry_token(registry: str, repo: str) -> Optional[str]:
    """Try to get authentication token for a generic registry"""
    try:
        # Try common auth endpoints
        for auth_url in [
            f"https://{registry}/token?scope=repository:{repo}:pull",
            f"https://auth.{registry}/token?scope=repository:{repo}:pull",
        ]:
            try:
                response = requests.get(auth_url, timeout=REQUEST_TIMEOUT)
                if response.status_code == 200:
                    return response.json().get('token')
            except:
                continue
    except Exception as e:
        pass
    
    return None


def get_generic_registry_digest(registry: str, repo: str, tag: str) -> Optional[str]:
    """Get digest from a generic OCI-compatible registry"""
    try:
        # Try to get token
        token = get_generic_registry_token(registry, repo)
        
        headers = {
            'Accept': 'application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json'
        }
        
        if token:
            headers['Authorization'] = f'Bearer {token}'
        
        # Try GET first (more compatible)
        response = requests.get(
            f"https://{registry}/v2/{repo}/manifests/{tag}",
            headers=headers,
            timeout=REQUEST_TIMEOUT,
            allow_redirects=True
        )
        
        if response.status_code == 200:
            digest = response.headers.get('Docker-Content-Digest')
            if digest:
                return digest
            # Compute digest from manifest
            import hashlib
            manifest_bytes = response.content
            digest_hash = hashlib.sha256(manifest_bytes).hexdigest()
            return f"sha256:{digest_hash}"
    
    except Exception as e:
        pass
    
    return None


def get_latest_digest(registry: str, repo: str, tag: str) -> Optional[str]:
    """Get the latest digest for an image from the registry"""
    
    # GitHub Container Registry
    if registry == 'ghcr.io':
        return get_ghcr_digest(repo, tag)
    
    # Docker Hub
    elif registry == 'docker.io':
        token = get_docker_hub_token(repo)
        if not token:
            return None
        
        try:
            headers = {
                'Authorization': f'Bearer {token}',
                'Accept': 'application/vnd.docker.distribution.manifest.v2+json'
            }
            
            response = requests.head(
                f"{DOCKER_HUB_API}/{repo}/manifests/{tag}",
                headers=headers,
                timeout=REQUEST_TIMEOUT
            )
            
            if response.status_code == 200:
                return response.headers.get('Docker-Content-Digest')
        
        except Exception as e:
            pass
        
        return None
    
    # Try generic OCI-compatible registry (docker.n8n.io, quay.io, etc.)
    else:
        return get_generic_registry_digest(registry, repo, tag)


def get_local_image_digest(image: str) -> Optional[str]:
    """Get the digest of a local image"""
    try:
        # First try to get RepoDigests
        result = subprocess.run(
            ['docker', 'image', 'inspect', image, '--format', '{{json .RepoDigests}}'],
            capture_output=True,
            text=True,
            check=True
        )
        
        repo_digests = json.loads(result.stdout.strip())
        if repo_digests and len(repo_digests) > 0:
            digest_output = repo_digests[0]
            if '@sha256:' in digest_output:
                return digest_output.split('@')[1]
        
        # If no RepoDigests, try to get the image ID as fallback
        result = subprocess.run(
            ['docker', 'image', 'inspect', image, '--format', '{{.Id}}'],
            capture_output=True,
            text=True,
            check=True
        )
        
        image_id = result.stdout.strip()
        if image_id and 'sha256:' in image_id:
            return image_id.replace('sha256:', 'sha256:')
        
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        pass
    
    return None


def check_for_updates(image: str) -> Tuple[bool, Optional[str], Optional[str], Optional[str]]:
    """Check if an update is available for an image
    Returns: (has_update, local_digest, remote_digest, error_msg)
    """
    registry, repo, tag = parse_image_name(image)
    
    # Get local digest
    local_digest = get_local_image_digest(image)
    
    # Get remote digest
    remote_digest = get_latest_digest(registry, repo, tag)
    
    error_msg = None
    if not local_digest:
        error_msg = "No local digest"
    elif not remote_digest:
        error_msg = f"Cannot reach {registry}"
    
    if not local_digest or not remote_digest:
        return False, local_digest, remote_digest, error_msg
    
    has_update = local_digest != remote_digest
    return has_update, local_digest, remote_digest, error_msg


def print_header():
    """Print script header"""
    print(f"\n{Colors.BOLD}{Colors.CYAN}{'='*80}{Colors.END}")
    print(f"{Colors.BOLD}{Colors.CYAN}Docker Image Update Checker{Colors.END}")
    print(f"{Colors.CYAN}Scan Date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}{Colors.END}")
    print(f"{Colors.BOLD}{Colors.CYAN}{'='*80}{Colors.END}\n")


def print_summary(results: List[Dict]):
    """Print summary table of results"""
    if not results:
        print(f"{Colors.YELLOW}No running containers found.{Colors.END}\n")
        return
    
    # Calculate column widths
    max_container = max(len(r['container']) for r in results)
    max_image = max(len(r['image']) for r in results)
    max_status = 20
    
    # Ensure minimum widths
    max_container = max(max_container, 15)
    max_image = max(max_image, 30)
    
    # Print table header
    header = f"{'CONTAINER':<{max_container}} | {'IMAGE':<{max_image}} | {'STATUS':<{max_status}}"
    print(f"{Colors.BOLD}{header}{Colors.END}")
    print(f"{'-'*len(header)}")
    
    # Print rows
    updates_available = 0
    for result in results:
        container = result['container'][:max_container]
        image = result['image'][:max_image]
        
        if result['has_update']:
            status = f"{Colors.GREEN}✓ Update Available{Colors.END}"
            updates_available += 1
        elif result['checked']:
            status = f"{Colors.BLUE}✓ Up to date{Colors.END}"
        else:
            status = f"{Colors.YELLOW}⚠ Could not check{Colors.END}"
        
        print(f"{container:<{max_container}} | {image:<{max_image}} | {status}")
    
    # Print summary
    print(f"\n{Colors.BOLD}Summary:{Colors.END}")
    print(f"  Total containers: {len(results)}")
    print(f"  Updates available: {Colors.GREEN if updates_available > 0 else Colors.BLUE}{updates_available}{Colors.END}")
    print(f"  Up to date: {Colors.BLUE}{sum(1 for r in results if r['checked'] and not r['has_update'])}{Colors.END}")
    print(f"  Could not check: {Colors.YELLOW}{sum(1 for r in results if not r['checked'])}{Colors.END}\n")


def main():
    """Main execution function"""
    print_header()
    
    # Find compose files
    print(f"{Colors.BOLD}Scanning for compose files in: {COMPOSE_BASE_DIR}{Colors.END}")
    compose_files = find_compose_files(COMPOSE_BASE_DIR)
    print(f"Found {len(compose_files)} compose file(s)\n")
    
    # Parse compose files to build image map
    compose_images = {}
    for compose_file in compose_files:
        images = parse_compose_file(compose_file)
        if images:
            print(f"{Colors.CYAN}  {compose_file.parent.name}/{compose_file.name}{Colors.END}: {len(images)} service(s)")
            compose_images.update(images)
    
    print()
    
    # Get running containers
    print(f"{Colors.BOLD}Checking running containers...{Colors.END}")
    running_containers = get_running_containers()
    print(f"Found {len(running_containers)} running container(s)\n")
    
    if not running_containers:
        print(f"{Colors.YELLOW}No running containers found.{Colors.END}\n")
        return
    
    # Check for updates
    print(f"{Colors.BOLD}Checking for image updates...{Colors.END}\n")
    results = []
    
    for container_name, container_info in running_containers.items():
        image = container_info['image']
        print(f"Checking {Colors.CYAN}{container_name}{Colors.END} ({image})...", end=' ')
        
        has_update, local_digest, remote_digest, error_msg = check_for_updates(image)
        
        if local_digest and remote_digest:
            if has_update:
                print(f"{Colors.GREEN}UPDATE AVAILABLE{Colors.END}")
            else:
                print(f"{Colors.BLUE}Up to date{Colors.END}")
            checked = True
        else:
            if error_msg:
                print(f"{Colors.YELLOW}Could not verify ({error_msg}){Colors.END}")
            else:
                print(f"{Colors.YELLOW}Could not verify{Colors.END}")
            checked = False
        
        results.append({
            'container': container_name,
            'image': image,
            'has_update': has_update,
            'checked': checked,
            'local_digest': local_digest,
            'remote_digest': remote_digest,
            'error_msg': error_msg
        })
    
    print()
    
    # Print summary table
    print_summary(results)
    
    # Exit with appropriate code
    if any(r['has_update'] for r in results):
        sys.exit(1)  # Exit code 1 if updates available (useful for cron)
    else:
        sys.exit(0)


if __name__ == "__main__":
    main()
