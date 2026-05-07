---
name: Remi PHP-FPM listen.allowed_clients fix
description: Remi PHP 7.4/8.3 on Rocky Linux 9 has listen.allowed_clients=127.0.0.1 uncommented by default, blocking all non-localhost FastCGI connections
type: feedback
---

In the Dockerfile, after configuring FPM pool with sed, always also comment out `listen.allowed_clients`:

```
-e 's|^listen.allowed_clients|;listen.allowed_clients|'
```

**Why:** Remi's default www.conf for Rocky Linux 9 ships with `listen.allowed_clients = 127.0.0.1` ACTIVE (not commented out). When nginx runs in a separate Docker container, it connects from a non-localhost IP, causing FPM to silently reset the connection → nginx gets 502 Bad Gateway on every request. PHP CLI works fine, FPM does not — this mismatch is the diagnostic clue.

**How to apply:** Any time Remi PHP-FPM is installed in a Docker setup where FPM and nginx are in separate containers. Must be fixed in Dockerfile sed commands AND applied to running containers if already built.
