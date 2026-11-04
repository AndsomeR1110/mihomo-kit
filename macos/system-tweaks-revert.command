#!/bin/bash
exec /bin/bash "$(dirname "$0")/scripts/system-tweaks.sh" --revert "$@"
