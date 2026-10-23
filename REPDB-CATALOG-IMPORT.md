# RepDB exercise catalog import

The exercise catalog uses RepDB's free-tier data under its [data license](https://github.com/RepDB/exercise-dataset/blob/main/LICENSE-DATA.md). RepDB requires the visible attribution now shown in the app: **Exercise data by RepDB (repdb.co)**. The license permits use inside applications but prohibits redistributing the catalog as a dataset.

The import scope is 569 records: 530 strength, 19 cardio, 16 Olympic, and 4 plyometric. All 81 stretching records are excluded. Cardio maps to the app's cardio logging flow; the other imported categories use set logging. Image paths and source metadata are stored as app catalog data; image binaries are not copied to Supabase or this repository.

## Apply and import

1. Back up the database and confirm the existing `public.workouts` schema matches the base migration preflight: `id text`, `user_id uuid`, `start_time bigint`, `end_time bigint`, `duration integer`, `volume numeric`, and `exercises jsonb`. Also review existing workout policies and the deployed exercise tables before applying changes.
2. Apply [`20261023193333_workout_schema.sql`](./supabase/migrations/20261023193333_workout_schema.sql) if it has not already been applied, followed by [`20261023193334_repdb_catalog_migration.sql`](./supabase/migrations/20261023193334_repdb_catalog_migration.sql). Their timestamps enforce the required order.
3. Download the official free-tier ZIP from [RepDB's dataset README](https://github.com/RepDB/exercise-dataset) or its [official ZIP link](https://cdn.repdb.co/repdb-assets/site/repdb-free.zip), save it as `repdb-free.zip` in the repository root, and run local validation:

   ```powershell
   python scripts\import_repdb_catalog.py --dry-run
   ```

4. In the Supabase dashboard, open your project and go to **Project Settings → API** (or **API Keys**, depending on the dashboard layout). Copy the **Project URL** for `SUPABASE_URL` and the **service_role** key for `SUPABASE_SERVICE_ROLE_KEY`. The service-role key may be listed under the legacy API keys section. Do not use the `anon`/publishable key.
5. In the same PowerShell window where you will run the importer, set the values for that window's process environment:

   ```powershell
   $env:SUPABASE_URL = Read-Host "Supabase Project URL"
   $secureKey = Read-Host "Supabase service_role key" -AsSecureString
   $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
   try {
       $env:SUPABASE_SERVICE_ROLE_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
   }
   finally {
       [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
       Remove-Variable secureKey, ptr
   }
   ```

   These values are temporary and are cleared when you close the PowerShell window. Then run:

   ```powershell
   python scripts\import_repdb_catalog.py
   ```

   If the importer reports that a Supabase REST response contains invalid JSON, the message identifies the request method and table and includes the response status, content type, and a short redacted preview. Check that `SUPABASE_URL` is the project's URL (not a dashboard URL) and that a proxy or network filter is not replacing the API response. The importer does not retry malformed responses.

   To clear them sooner, run `$env:SUPABASE_URL = $null` and `$env:SUPABASE_SERVICE_ROLE_KEY = $null`.

The importer requires Python 3.10 or newer and uses only the standard library.
The service-role key is only used by this local importer; never place it in the browser app, a committed file, a command-line argument, or source control. The importer reads `repdb-free.zip`, which is ignored by Git, validates the expected source schema/counts, and can be safely rerun. Against the 77 shared seed records in the current schema file, 35 have unambiguous canonical-name or synonym matches and retain their UUIDs; 42 unmatched shared rows are hidden from new selectors but retained for history. User-owned custom exercises are left intact.

Import into a non-production Supabase project first. The migration and importer have not been run against the live project; successful local validation is not a substitute for checking deployed schema, RLS, and data reconciliation.
