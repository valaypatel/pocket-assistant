# Music recognition service

A small AWS Lambda (Python 3.12 + [ShazamIO](https://github.com/shazamio/ShazamIO))
behind a private Function URL. The app records a 12 second clip on Circuit, syncs
it to the phone, and posts it here. The service answers with the track, if any.

Audio is processed in memory for one request. It is never written to S3 or disk,
and the logs hold only the request id, route and outcome.

> ShazamIO is an unofficial client. Recognition can fail or change upstream, so
> treat it as a convenience, not a guarantee. The bearer key below suits a
> personal app only. Before any public release, replace it with per-user
> authentication and rate limiting.

## API

| Route | Body | Result |
|---|---|---|
| `POST /music/identify` | raw WAV bytes (`content-type: audio/wav`) | `{matched, title, artist, album, artworkUrl, providerUrl, spotifyUri, spotifyUrl, spotifyTrackUri, spotifyTrackUrl}` |
| `GET /music/health` | none | `{"ok": true}` when the key is accepted |

Every request needs `Authorization: Bearer <service key>`.

`spotifyUri` and `spotifyUrl` are the links Shazam attaches to the track, or `null`. They are a Spotify *search* for the song, not the song. `spotifyTrackUri` and `spotifyTrackUrl` are the exact Spotify track, and are only filled in when the service has Spotify credentials (see below). `matched: false` (with the other fields `null`) means no match. It is a normal
200 answer, not an error.

| Status | Meaning |
|---|---|
| 400 | not a WAV file, or bad base64 |
| 401 | missing or wrong key |
| 404 | unknown route |
| 413 | clip over the size limit (3 MiB by default) |
| 500 | `SERVICE_KEY` is not set, so the service refuses everything |
| 502 | recognition failed upstream; safe to retry |

## Deploy with Terraform

You need Terraform, Python 3 and an AWS profile that can create Lambda
functions and IAM roles. No Docker is needed.

```bash
cd services/music-lambda

# 1. Build the Lambda package (Linux wheels, so it works from a Mac).
python3 build.py

# 2. Create the function, its role, log group and public Function URL.
cd terraform
export AWS_PROFILE=<your profile>     # region defaults to ap-south-1
terraform init
terraform plan -out tfplan
terraform apply tfplan

# 3. Read the two values the app needs.
terraform output function_url
terraform output -raw service_key
```

In the app, open **Settings → Music recognition**, paste the address and the
key, and tap the flask button to test.

From then on the **code** is deployed by GitHub Actions on merges to `main`
(see [docs/ci-cd.md](../../docs/ci-cd.md)), and Terraform ignores it. Use
`terraform apply` for infrastructure and settings.

Variables (`terraform/variables.tf`): `region`, `aws_profile`, `name`,
`max_audio_bytes`, `log_retention_days`, `allowed_origin`.

Notes:

- Terraform generates the service key. It is stored in the Lambda environment
  and in Terraform state, so keep `terraform.tfstate` and `tfplan` private. Both
  are git-ignored. Rotate the key with
  `terraform apply -replace=random_password.service_key`, then update the app.
- State is local. Move it to a remote backend before sharing the setup.
- The runtime must stay on Python 3.12. ShazamIO imports `pydub`, which needs
  `audioop`, and Python 3.13 removed it.
- The function role can only write logs. It has no S3 or database access.
- The Function URL is public on the internet and protected only by the bearer
  key. CORS only restricts browsers; the Android app is not a browser.
- Remove everything with `terraform destroy`.

## Opening the exact song in Spotify (optional)

Shazam only gives Spotify *search* links, so without this step Spotify opens a
search page. With a free Spotify developer app the service looks the track up in
Spotify's catalogue (by its ISRC, then by title and artist) and returns the exact
track. Only text is sent to Spotify, never audio. If the lookup fails or finds
nothing, the match is still returned and the app falls back to the search.

1. Go to <https://developer.spotify.com/dashboard> and create an app. Any name
   works and it needs Web API access only. Spotify makes you enter a redirect URI
   even though this service never uses one; `http://127.0.0.1:3000/callback` is
   accepted (Spotify no longer allows `localhost` itself, and may change this).
2. Copy its **Client ID** and **Client secret**.
3. Put them in `terraform/terraform.tfvars` (git-ignored), then apply:

   ```hcl
   spotify_client_id     = "..."
   spotify_client_secret = "..."
   ```

   ```bash
   cd terraform && terraform apply
   ```

The secret is stored in Terraform state and in the function's environment, like
the service key. Spotify can change the rules for its Web API, so check their
current terms.

## Test

The tests replace ShazamIO, so they need no network or AWS account.

```bash
cd services/music-lambda
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt
pytest -q tests
```

They cover matched, no-match and upstream-error answers, bad and missing keys,
non-WAV and oversize uploads, base64 handling, the logs holding no audio or track
details, and a request writing nothing to the temp directory.

## Checking that nothing is kept

After deploying, send a clip and then look in CloudWatch Logs for the function:
each request should show one JSON line with `requestId`, `route` and `outcome`
only. The function role in `terraform/main.tf` has no S3 or database access.
