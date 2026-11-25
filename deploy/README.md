# Deployment records

One file per environment above dev, naming the build that environment runs
and the version of its infrastructure:

```json
{
  "build": 142,
  "commit": "<full commit SHA>",
  "image": "europe-west1-docker.pkg.dev/ingka-dp-sap-dev/rotator-repo/rotator@sha256:<digest>",
  "summary": "<first line of the commit message>",
  "infra": "<commit of main whose terraform/ the environment has>"
}
```

`infra` is missing in records from before infrastructure was promoted; the
environment's next promotion adds it. A rollback leaves it as it is.

Don't edit these by hand. Use Actions → **Create promotion PR**, which opens
a PR changing one file; merging it applies the infrastructure (if `infra`
moved) and deploys that build. To roll an environment
back, run the same button with an earlier build (test), or open a PR that
points the file at an earlier image. See [CICD.md](../CICD.md).

A file appears with the first promotion to its environment. Dev has no file:
it always runs the newest build of main (or a PR preview).
