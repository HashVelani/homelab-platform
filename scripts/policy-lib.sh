#!/usr/bin/env bash

UNPINNED_IMAGE_REGEX='^[[:space:]]*image:[[:space:]]*[^[:space:]@]+:[^[:space:]@]+$'
SECRET_PATTERN='(?:\bAKIA[0-9A-Z]{16}\b|\bASIA[0-9A-Z]{16}\b|\bghp_[A-Za-z0-9]{36}\b|\bgithub_pat_[A-Za-z0-9_]{82}\b|-----BEGIN (?:RSA|EC|OPENSSH|DSA|PGP|PRIVATE) KEY-----|\bAIza[0-9A-Za-z\-_]{35}\b)'

find_unpinned_images() {
  local target_file="$1"
  grep -nE "$UNPINNED_IMAGE_REGEX" "$target_file" || true
}

find_secret_pattern_matches() {
  grep -RPn "$SECRET_PATTERN" "$@" || true
}
