#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

git -C "$repository_root" describe --long --tags |
    sed 's/^v//;s/\([^-]*-g\)/r\1/;s/-/./g'
