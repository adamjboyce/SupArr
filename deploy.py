#!/usr/bin/env python3
"""
SupArr Deploy GUI — Launcher.

Starts the local HTTP server and opens the browser.
Usage: python3 deploy.py
"""

import os
import sys
import webbrowser

# Ensure deploy package is importable
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from deploy.server import start_server, find_port


def main():
    project_dir = os.path.dirname(os.path.abspath(__file__))
    port = find_port()
    if port is None:
        print("ERROR: No available port found (tried 8765-8775)")
        sys.exit(1)

    server, port, token = start_server(project_dir, port)
    url = f"http://127.0.0.1:{port}"

    print(f"""
  SupArr Deploy GUI
  ─────────────────
  Running at: {url}
  Session token: {token[:8]}...

  Press Ctrl+C to stop.
""")

    try:
        webbrowser.open(url)
    except Exception:
        pass  # No browser available (headless) — user can open URL manually

    try:
        # Server runs in a daemon thread — block main thread until Ctrl+C
        while True:
            import time
            time.sleep(3600)
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.shutdown()


if __name__ == "__main__":
    main()
