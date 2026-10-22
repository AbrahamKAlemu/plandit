# Plandit production landing page

A responsive, static launch site prepared for `https://plandit.app/`. It can be deployed to Vercel, Netlify, GitHub Pages, Cloudflare Pages, or any basic static host.

## Preview locally

Run a local server from this folder:

```sh
python3 -m http.server 8000
```

Then open `http://localhost:8000`.

## Deploy (Vercel)

The repo is pre-configured for Vercel with a root-level `vercel.json`: no build step, `website/` is served as the output directory, clean URLs are on, and the legacy `make-plans` / `share-plans` pages 301-redirect to their homepage sections.

1. In Vercel: **Add New → Project → Import** `AbrahamKAlemu/plandit`. If the repo is not listed, the repo owner must grant the Vercel GitHub App access: GitHub → Settings → Applications → Installed GitHub Apps → Vercel → Configure → add `plandit`.
2. Leave every setting at its default (Framework Preset: Other, Root Directory: `./`, no build command). `vercel.json` handles the rest. Click **Deploy**.
3. Project → Settings → Domains → add `plandit.app` and `www.plandit.app`, then copy the DNS records Vercel shows into the domain registrar.

Production deploys from `main`; every other branch and PR gets a preview URL.

## Connect the waitlist

The form intentionally does not store emails yet. In `config.js`, set `endpoint` to an HTTPS URL that accepts:

```json
{"email":"person@example.com","source":"plandit.app"}
```

The endpoint must return a successful 2xx response only after storing the signup.

## Before launch

- Choose a static host and connect the `plandit.app` DNS records.
- Connect and test a real waitlist endpoint.
- Replace the cropped picnic photo with the original high-resolution source if available.
- Confirm that TikTok/Instagram imports, budgets, routes, and group sharing match the launch product.
