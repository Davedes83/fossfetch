#!/usr/bin/env python3
"""Connectivity probe for FossFetch.

ICMP is blocked on a lot of public Wi-Fi, mobile hotspots and corporate
networks even when HTTPS works fine. Pinging 8.8.8.8 therefore produced false
"Offline" banners and stopped every live search. This probes TCP/443 instead,
which is what the package backends actually need.

Exit 0 if any endpoint is reachable, 1 otherwise.
"""

import socket
import sys

HOSTS = ("1.1.1.1", "8.8.8.8", "archlinux.org", "flathub.org")
TIMEOUT = 3

for host in HOSTS:
    try:
        socket.create_connection((host, 443), timeout=TIMEOUT).close()
        sys.exit(0)
    except OSError:
        continue

sys.exit(1)
