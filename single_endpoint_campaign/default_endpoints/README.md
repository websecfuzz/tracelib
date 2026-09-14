# Default Fixed-Endpoint Seeds

These endpoint files are used by `run_all_apps_single_endpoint_campaign.sh`.
Each retained application has ten default GET endpoints.

The lists were derived from prior standard WebFuzz crawl artifacts under
`eval_result/` and `eval_result_nonphp/`, ranking observed crawl/request
shapes by unique query-parameter count. Stale nonces, session ids, and obvious
payload artifacts were replaced with stable placeholder values so the endpoints
remain reusable after app resets.

`gogs.txt`, `huginn.txt`, `superset.txt`, `wikijs.txt`, `petclinic.txt` and
`roller.txt` were built the same way from the crawl logs of the
first non-PHP campaigns for those apps, then every URL was checked against the
running application with `validate_endpoints.py` and the app's auto-login
cookies; all sixty answer HTTP 200 (PetClinic's are unauthenticated because the
application has no accounts). Superset's list
uses the Flask-AppBuilder list-view parameters (`_flt_0_*`, `_oc_*`, `_od_*`,
`psize_*`) and three rison `q=` API endpoints; Wiki.js's covers the page
renderer, the admin sections and the tag/browse routes. Their
id-bearing paths (`/agents/1`, `/scenarios/1`, `/diagram?scenario_id=1`) refer
to Huginn's seeded default scenario, which `rake db:seed` recreates identically
on every fresh database, so they survive an app reset like the other lists do.

The wrapper reads the first `--endpoints-per-app` non-comment lines from each
`APP.txt` file.
