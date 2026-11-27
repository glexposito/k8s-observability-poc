# SigNoz dashboards

SigNoz has no file-based provisioning like Grafana's: its built-in dashboards
are compiled into the binary, and everything else goes through its API. So the
JSON here is the source of truth, and you import it by hand after a fresh
stack (`docker compose down -v` wipes SigNoz's database).

## Import

1. Open http://127.0.0.1:3301 and log in as `admin@playground.local` /
   `Playground123!` (created by SigNoz on startup, see
   `observability/signoz/values.yaml`).
2. **Dashboards → New dashboard → Import JSON**, paste the file's contents and
   save.

| File | Dashboard |
| --- | --- |
| `queue-consumer-overview.json` | queue-consumer overview: same panels as the Grafana dashboard of the same name |

## Changing a dashboard

Edit it in the UI, export the JSON and commit it here, so the next fresh stack
gets your version. The files use SigNoz's v6 dashboard schema; each has a fixed
`name`, and SigNoz rejects a second dashboard with the same name, so delete the
old one before re-importing.

If you ever want this automated, the proper tool is the official SigNoz
Operator (a `Dashboard` custom resource that Argo CD can sync). It needs a
SigNoz API key, which has to be created in the UI after each fresh stack.
