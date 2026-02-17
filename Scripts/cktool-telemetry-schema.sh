#!/usr/bin/env bash
# Creates the TelemetryEvent, TelemetryClient, TelemetryCommand, and TelemetryScenario schema via cktool. Requires team id and container id.

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
# Note: TelemetryEvent and TelemetryClient are PUBLIC database records.
# TelemetrySettingsBackup is a PRIVATE database record (per-user backup).
#
# IMPORTANT: This script imports to the PUBLIC database by default.
# For TelemetrySettingsBackup (private database), the schema is auto-created
# when the app first writes to it. No manual setup needed for private records.
cat > "$SCHEMA_FILE" <<'SCHEMA'
DEFINE SCHEMA

    RECORD TYPE TelemetryClient (
        "___createTime" TIMESTAMP,
        "___createdBy"  REFERENCE,
        "___etag"       STRING,
        "___modTime"    TIMESTAMP,
        "___modifiedBy" REFERENCE,
        "___recordID"   REFERENCE QUERYABLE,
        clientid        STRING QUERYABLE SEARCHABLE SORTABLE,
        created         TIMESTAMP QUERYABLE SORTABLE,
        isEnabled       INT64 QUERYABLE SORTABLE,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );

    RECORD TYPE TelemetryCommand (
        "___createTime" TIMESTAMP,
        "___createdBy"  REFERENCE,
        "___etag"       STRING,
        "___modTime"    TIMESTAMP,
        "___modifiedBy" REFERENCE,
        "___recordID"   REFERENCE QUERYABLE,
        action          STRING,
        clientid        STRING QUERYABLE SEARCHABLE SORTABLE,
        commandId       STRING QUERYABLE SEARCHABLE SORTABLE,
        created         TIMESTAMP QUERYABLE SORTABLE,
        errorMessage    STRING,
        executedAt      TIMESTAMP,
        scenarioName    STRING,
        status          STRING QUERYABLE SEARCHABLE SORTABLE,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );

    RECORD TYPE TelemetryEvent (
        "___createTime" TIMESTAMP,
        "___createdBy"  REFERENCE,
        "___etag"       STRING,
        "___modTime"    TIMESTAMP,
        "___modifiedBy" REFERENCE,
        "___recordID"   REFERENCE QUERYABLE,
        appVersion      STRING QUERYABLE SEARCHABLE SORTABLE,
        deviceModel     STRING,
        deviceName      STRING QUERYABLE SEARCHABLE SORTABLE,
        deviceType      STRING QUERYABLE SEARCHABLE SORTABLE,
        eventId         STRING,
        eventName       STRING QUERYABLE SEARCHABLE SORTABLE,
        eventTimestamp  TIMESTAMP QUERYABLE SORTABLE,
        logLevel        STRING QUERYABLE SEARCHABLE SORTABLE,
        osVersion       STRING,
        property1       STRING,
        scenario        STRING QUERYABLE SEARCHABLE SORTABLE,
        sessionId       STRING QUERYABLE SEARCHABLE SORTABLE,
        threadId        STRING,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );

    RECORD TYPE TelemetryScenario (
        "___createTime" TIMESTAMP,
        "___createdBy"  REFERENCE,
        "___etag"       STRING,
        "___modTime"    TIMESTAMP,
        "___modifiedBy" REFERENCE,
        "___recordID"   REFERENCE QUERYABLE,
        clientid        STRING QUERYABLE SEARCHABLE SORTABLE,
        created         TIMESTAMP,
        isEnabled       INT64 QUERYABLE SORTABLE,
        scenarioName    STRING QUERYABLE SEARCHABLE SORTABLE,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );

    RECORD TYPE TelemetrySettingsBackup (
        "___createTime"         TIMESTAMP,
        "___createdBy"          REFERENCE,
        "___etag"               STRING,
        "___modTime"            TIMESTAMP,
        "___modifiedBy"         REFERENCE,
        "___recordID"           REFERENCE QUERYABLE,
        clientIdentifier        STRING,
        lastUpdated             TIMESTAMP,
        telemetryRequested      INT64,
        telemetrySendingEnabled INT64,
        GRANT READ, WRITE TO "_creator",
        GRANT CREATE TO "_icloud"
    );

    RECORD TYPE Users (
        "___createTime" TIMESTAMP,
        "___createdBy"  REFERENCE,
        "___etag"       STRING,
        "___modTime"    TIMESTAMP,
        "___modifiedBy" REFERENCE,
        "___recordID"   REFERENCE,
        roles           LIST<INT64>,
        GRANT WRITE TO "_creator",
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
