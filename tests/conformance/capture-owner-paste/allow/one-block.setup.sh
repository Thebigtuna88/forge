#!/bin/bash
# A frozen handoff, as handoff ready leaves it.
mkdir -p "$ROOT/work/owner/2026-01-01-demo"
printf '{"id": "2026-01-01-demo", "state": "ready"}\n' >"$ROOT/work/owner/2026-01-01-demo/META.json"
printf '#!/usr/bin/env bash\n' >"$ROOT/work/owner/2026-01-01-demo/OWNER-RUN.sh"
