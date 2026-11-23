#!/usr/bin/env python3
# Fetch flatpak permissions for a given app ID from the Flathub remote.
# Outputs a tab-separated line: appid\tpermissions_json
#
# The permissions JSON contains:
#   - filesystems: list of filesystem access strings
#   - sockets: list of socket access strings
#   - devices: list of device access strings
#   - shared: list of shared resources
#   - session_bus: list of session bus policies
#   - system_bus: list of system bus policies

import json
import os
import subprocess
import sys

def parse_flatpak_metadata(text):
    """Parse flatpak remote-info --show-metadata output into a dict."""
    sections = {}
    current_section = None
    current_data = {}
    
    for line in text.split('\n'):
        line = line.strip()
        if not line:
            continue
        if line.startswith('[') and line.endswith(']'):
            if current_section:
                sections[current_section] = current_data
            current_section = line[1:-1]
            current_data = {}
        elif '=' in line and current_section:
            key, value = line.split('=', 1)
            current_data[key.strip()] = value.strip()
    
    if current_section:
        sections[current_section] = current_data
    
    return sections

def extract_permissions(sections):
    """Extract permission info from parsed metadata sections."""
    perms = {
        'filesystems': [],
        'sockets': [],
        'devices': [],
        'shared': [],
        'session_bus': [],
        'system_bus': [],
    }
    
    context = sections.get('Context', {})
    
    # Filesystems
    if 'filesystems' in context:
        perms['filesystems'] = [fs.strip() for fs in context['filesystems'].split(';') if fs.strip()]
    
    # Sockets
    if 'sockets' in context:
        perms['sockets'] = [s.strip() for s in context['sockets'].split(';') if s.strip()]
    
    # Devices
    if 'devices' in context:
        perms['devices'] = [d.strip() for d in context['devices'].split(';') if d.strip()]
    
    # Shared
    if 'shared' in context:
        perms['shared'] = [s.strip() for s in context['shared'].split(';') if s.strip()]
    
    # Session Bus Policy
    session_bus = sections.get('Session Bus Policy', {})
    for key, value in session_bus.items():
        perms['session_bus'].append(f"{key}={value}")
    
    # System Bus Policy (if present)
    system_bus = sections.get('System Bus Policy', {})
    for key, value in system_bus.items():
        perms['system_bus'].append(f"{key}={value}")
    
    return perms

def format_permission_chips(perms):
    """Convert permissions to human-readable chip labels."""
    chips = []
    
    # Filesystem access
    for fs in perms['filesystems']:
        if fs == 'host':
            chips.append(('🔓', 'Host FS'))
        elif fs.startswith('xdg-'):
            if 'create' in fs or 'ro' in fs:
                chips.append(('📁', fs.replace('xdg-', '').split(':')[0]))
            else:
                chips.append(('📁', fs))
        elif fs == 'host-os':
            chips.append(('🔓', 'Host OS'))
        elif fs == 'home':
            chips.append(('🏠', 'Home'))
        else:
            chips.append(('📁', fs))
    
    # Sockets
    for sock in perms['sockets']:
        if sock == 'wayland':
            chips.append(('🖥️', 'Wayland'))
        elif sock == 'x11' or sock == 'fallback-x11':
            chips.append(('🖥️', 'X11'))
        elif sock == 'pulseaudio':
            chips.append(('🔊', 'PulseAudio'))
        elif sock == 'pipewire':
            chips.append(('🔊', 'PipeWire'))
        elif sock == 'network':
            chips.append(('🌐', 'Network'))
        elif sock == 'ssh-auth':
            chips.append(('🔑', 'SSH Auth'))
        elif sock == 'gpg-agent':
            chips.append(('🔐', 'GPG Agent'))
        elif sock == 'cups':
            chips.append(('🖨️', 'CUPS'))
        else:
            chips.append(('🔌', sock))
    
    # Devices
    for dev in perms['devices']:
        if dev == 'all':
            chips.append(('📱', 'All Devices'))
        elif dev == 'dri':
            chips.append(('🎮', 'GPU (DRI)'))
        elif dev == 'kvm':
            chips.append(('🖥️', 'KVM'))
        elif dev == 'v4l2':
            chips.append(('📹', 'Video4Linux'))
        else:
            chips.append(('📱', dev))
    
    # Shared
    for shr in perms['shared']:
        if shr == 'ipc':
            chips.append(('🔗', 'IPC'))
        elif shr == 'network':
            chips.append(('🌐', 'Network'))
        else:
            chips.append(('🔗', shr))
    
    return chips

def main():
    if len(sys.argv) < 2:
        print("Usage: flatpak_permissions.py <appid>", file=sys.stderr)
        sys.exit(1)
    
    appid = sys.argv[1].strip()
    if not appid:
        sys.exit(1)
    
    # Fetch metadata from Flathub remote
    try:
        result = subprocess.run(
            ['flatpak', 'remote-info', '--show-metadata', 'flathub', appid],
            capture_output=True,
            text=True,
            timeout=15
        )
    except subprocess.TimeoutExpired:
        print(json.dumps({'error': 'timeout'}), file=sys.stderr)
        sys.exit(1)
    except FileNotFoundError:
        print(json.dumps({'error': 'flatpak not found'}), file=sys.stderr)
        sys.exit(1)
    
    if result.returncode != 0:
        print(json.dumps({'error': 'not found'}), file=sys.stderr)
        sys.exit(1)
    
    sections = parse_flatpak_metadata(result.stdout)
    perms = extract_permissions(sections)
    chips = format_permission_chips(perms)
    
    # Output: appid, raw permissions JSON, formatted chips JSON
    output = {
        'appid': appid,
        'permissions': perms,
        'chips': chips
    }
    print(json.dumps(output))

if __name__ == '__main__':
    main()