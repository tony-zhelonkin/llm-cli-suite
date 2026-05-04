# Security Considerations

## Remote SSH Inference & The 0.0.0.0 Bind
By default, the `ollama.service` override file in this architecture binds to `0.0.0.0` to allow Docker Devcontainers (via the `172.17.0.1` bridge) to access the API.

**The Risk:** If you expose this instance to a remote laptop via SSH port forwarding (`ssh -L 11434:localhost:11434 user@host`), the `0.0.0.0` bind means the Ollama API is technically listening to the entire University network, protected only by the host's UFW firewall. Ollama has no native authentication.

**Mitigation Strategy:**
If you plan to use this machine primarily for remote SSH inference from a laptop, you do not need `0.0.0.0`. 
1. Edit `/etc/systemd/system/ollama.service.d/override.conf`
2. Change `OLLAMA_HOST` to explicitly bind to the Docker bridge and localhost:
   `Environment="OLLAMA_HOST=127.0.0.1"` (Note: binding to multiple IPs in Ollama requires separate instances or fronting with nginx, so just use 127.0.0.1 if dropping Docker)
3. Restart the service: `sudo systemctl daemon-reload && sudo systemctl restart ollama`

This drops the network attack surface to zero while preserving SSH tunnel functionality.

## API Concurrency Collisions
The `llm-manage` script uses `keep_alive=-1` to pin massive models into RAM. However, tools like the Pi Coding Agent inject their own `keep_alive` headers on every API call. 
If a remote laptop connects to this workstation and requests `keep_alive: 0`, the model will instantly flush, desyncing the host's `llm-status` and `llm-manage` states.

**Recommendation:** Treat the workstation strictly as a "dumb" inference engine when working remotely. Manage model states exclusively from the laptop's client, or exclusively from the host shell, but do not mix them.
