#!/usr/bin/env bash
# Creates the TelemetryEvent schema via cktool. Requires team id and container id.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <TEAM_ID> <CONTAINER_ID> [environment=development] [--validate-only]" >&2
  exit 1
fi

TEAM_ID="$1"
CONTAINER_ID="$2"
ENVIRONMENT="${3:-development}"
FLAG="${4:-}"

if [[ "$ENVIRONMENT" != "development" && "$ENVIRONMENT" != "production" ]]; then
  echo "Environment must be development or production" >&2
  exit 1
fi

CKTOOL="${CKTOOL_PATH:-/Applications/Xcode.app/Contents/Developer/usr/bin/cktool}"
if [[ ! -x "$CKTOOL" ]]; then
  CKTOOL="$(command -v cktool || true)"
fi

if [[ -z "$CKTOOL" || ! -x "$CKTOOL" ]]; then
  echo "cktool not found. Install Xcode 15+ or set CKTOOL_PATH to the binary (e.g. /Applications/Xcode.app/Contents/Developer/usr/bin/cktool)." >&2
  exit 1
fi

SCHEMA_FILE="${SCHEMA_FILE:-$(mktemp -t telemetry-schema)}"

# CloudKit schema DSL (same format as cktool export-schema).
cat > "$SCHEMA_FILE" <<'SCHEMA'
DEFINE SCHEMA

    RECORD TYPE TelemetryEvent (
        eventId          STRING,
        eventName        STRING QUERYABLE SEARCHABLE SORTABLE,
        eventTimestamp   TIMESTAMP QUERYABLE SORTABLE,
        deviceType       STRING QUERYABLE SEARCHABLE SORTABLE,
        deviceName       STRING QUERYABLE SEARCHABLE SORTABLE,
        deviceModel      STRING,
        osVersion        STRING,
        appVersion       STRING QUERYABLE SEARCHABLE SORTABLE,
        threadId         STRING,
        property1        STRING,
        "___createTime"  TIMESTAMP,
        "___createdBy"   REFERENCE,
        "___etag"        STRING,
        "___modTime"     TIMESTAMP,
        "___modifiedBy"  REFERENCE,
        "___recordID"    REFERENCE QUERYABLE,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );
SCHEMA

echo "Schema file: $SCHEMA_FILE"

# No JSON validation needed; DSL is used for import/export.

CMD=("$CKTOOL")
if [[ "$FLAG" == "--validate-only" ]]; then
  CMD+=("validate-schema" --team-id "$TEAM_ID" --container-id "$CONTAINER_ID" --environment "$ENVIRONMENT" --file "$SCHEMA_FILE")
else
  CMD+=("import-schema" --validate --team-id "$TEAM_ID" --container-id "$CONTAINER_ID" --environment "$ENVIRONMENT" --file "$SCHEMA_FILE")
fi

echo "Running: ${CMD[*]}"
"${CMD[@]}"

echo "Done."
