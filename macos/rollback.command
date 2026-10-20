#!/bin/bash
exec /bin/bash "$(dirname "$0")/scripts/rollback.sh" "$@"
