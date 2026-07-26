#!/usr/bin/env bash

UNPINNED_IMAGE_REGEX='^[[:space:]]*image:[[:space:]]*[^[:space:]@]+:[^[:space:]@]+$'

find_unpinned_images() {
  local target_file="$1"
  grep -nE "$UNPINNED_IMAGE_REGEX" "$target_file" || true
}
