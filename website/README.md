# Plandit production landing page

A responsive, static launch site prepared for `https://plandit.app/`. It can be deployed to Vercel, Netlify, GitHub Pages, Cloudflare Pages, or any basic static host.

## Preview locally

Run a local server from this folder:

```sh
python3 -m http.server 8000
```

Then open `http://localhost:8000`.

## Deploy

Upload the contents of this folder to a static host. Set `plandit.app` as the custom domain in the host, then copy the DNS records provided by that host into the domain registrar.

The site includes production metadata, `robots.txt`, `sitemap.xml`, responsive navigation, reduced-motion support, and legacy redirects for `make-plans.html` and `share-plans.html`.

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
