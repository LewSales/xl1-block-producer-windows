# upstream-overrides

`upstream/` is fetched fresh at setup time and gitignored — it isn't ours to push to
(`XYOracleNetwork/xl1-docker-images`). This folder tracks the files we've actually
changed there, so the change survives a re-clone and is pushable from this repo.

Currently: `docker/Dockerfile` (Alpine base, no `curl` — Node's own `fetch` runs the
healthcheck instead) and `compose/node.yml` (matching healthcheck). Built and
verified end-to-end on 2026-09-20 (self-hosted producer boot, native `lmdb` under
musl, Docker healthcheck) before being applied to `upstream/` and built as `xl1:local`.

To apply: copy these over the matching path under `upstream/` before building.
Not yet wired into `Build.ps1` automatically — that's a deliberate follow-up, not
an oversight.
