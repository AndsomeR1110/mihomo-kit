#!/bin/bash
exec /bin/bash "$(dirname "$0")/build.sh" --uninstall "$@"
