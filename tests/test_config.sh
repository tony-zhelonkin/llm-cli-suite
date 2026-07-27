#!/usr/bin/env bash
# Provider config invariants: valid JSON, exactly one provider key per file,
# and the declared _hostEnv/_defaultHost the renderer relies on.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for f in "$REPO"/config/providers/*.json; do
  name="$(basename "$f")"
  ok  "$name is valid JSON" jq -e . "$f"
  eq  "$name has exactly one provider key" "1" "$(jq -r '.providers | keys | length' "$f")"
  # each provider file the renderer rewrites must declare both host fields
  eq  "$name declares _hostEnv"     "true" "$(jq -r 'has("_hostEnv")' "$f")"
  eq  "$name declares _defaultHost" "true" "$(jq -r 'has("_defaultHost")' "$f")"
  # every model needs id + contextWindow (what the agent consumes)
  bad="$(jq -r '.providers[].models[] | select((.id|not) or (.contextWindow|not)) | .id // "??"' "$f")"
  eq  "$name models all have id+contextWindow" "" "$bad"
done

finish
