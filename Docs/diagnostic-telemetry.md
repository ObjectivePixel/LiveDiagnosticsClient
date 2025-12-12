## CloudKit Schema Setup (Automated Preferred, Manual Backup)

### Preferred: Automate with cktool
1. Ensure Xcode 15+ is installed (for `cktool`) or set `CKTOOL_PATH` to the binary path.
2. Set a management token using `cktool`:
   ```bash
   /Applications/Xcode.app/Contents/Developer/usr/bin/cktool save-token --type management
   ./tools/cktool-telemetry-schema.sh 3MUMKKCU58 iCloud.objectivepixel.prototype.remindful.telemetry development
   ```
   Replace `<TOKEN>` with your CloudKit management token.
2. From the repo root, run:
   ```bash
   ./tools/cktool-telemetry-schema.sh <TEAM_ID> <CONTAINER_ID> [environment=development] [--validate-only]
   ```
   - `TEAM_ID`: Your Apple Developer Team ID (e.g., `A1B2C3D4E5`)
   - `CONTAINER_ID`: CloudKit container identifier (e.g., `iCloud.com.yourcompany.yourapp`)
   - `environment`: `development` (default) or `production`
   - Add `--validate-only` to check schema without importing changes
3. The script imports (or validates) both the `TelemetryEvent` and `TelemetryClient` schema with correct fields, indexes, and permissions in one step.

### Step 1.1: Access CloudKit Dashboard
1. Navigate to https://icloud.developer.apple.com/
2. Sign in with Apple Developer account
3. Select the shared Remindful CloudKit container used by all platforms (e.g., `iCloud.com.yourcompany.yourapp`)

### Step 1.2: Create Record Type in Development
1. Go to **Schema** → **Record Types** → **Development**
2. Click **"+"** button to create new record type
3. Name it: `TelemetryEvent`
4. Click **"Save"**

### Step 1.3: Add Fields to TelemetryEvent Record Type

Add the following fields one by one (click "Add Field" for each):

| Field Name       | Type      | Queryable/Indexed | Notes                           |
|------------------|-----------|-------------------|---------------------------------|
| eventId          | String    | ☐ No              | Unique identifier per event     |
| eventName        | String    | ☑ Yes             | Event type/category             |
| eventTimestamp   | Date/Time | ☑ Yes             | When event occurred             |
| deviceType       | String    | ☑ Yes             | "iPhone", "iPad", "Vision Pro", "Watch", "Apple TV" |
| deviceName       | String    | ☑ Yes             | User-assigned device name or host name             |
| deviceModel      | String    | ☐ No              | Hardware model identifier       |
| osVersion        | String    | ☐ No              | OS version string               |
| appVersion       | String    | ☑ Yes             | App version for filtering       |
| threadId         | String    | ☐ No              | Calling thread identifier       |
| property1        | String    | ☐ No              | Custom property slot 1          |

**Important Notes:**
- **Queryable/Indexed** checkbox enables filtering/sorting on that field in queries
- Only index fields you'll frequently query to optimize performance
- Date/Time type is critical for `eventTimestamp` (not String)
- All other fields should be String type

### Step 1.4: Add Fields to TelemetryClient Record Type

Add the following fields to the `TelemetryClient` record type:

| Field Name | Type      | Queryable/Indexed | Notes                      |
|------------|-----------|-------------------|----------------------------|
| clientid   | String    | ☑ Yes             | Client identifier          |
| created    | Date/Time | ☑ Yes             | When the client was added  |
| isEnabled  | Boolean   | ☑ Yes             | Whether the client is active |

**Notes:**
- Leave default permissions identical to TelemetryEvent (read `_world`, create `_icloud`, write `_creator`).
- Use Boolean for `isEnabled` (not String) when creating manually in Dashboard.
