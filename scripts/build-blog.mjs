import {readFile, mkdir, rm, writeFile} from 'node:fs/promises'
import {join} from 'node:path'
import {fileURLToPath} from 'node:url'
import {createClient} from '@sanity/client'
import {toHTML} from '@portabletext/to-html'

const root = fileURLToPath(new URL('..', import.meta.url))
const websiteDir = join(root, 'website')
const blogDir = join(websiteDir, 'blog')
const samplePost = JSON.parse(
  await readFile(join(root, 'content', 'sample-post.json'), 'utf8'),
)
const projectId =
  process.env.SANITY_PROJECT_ID || process.env.SANITY_STUDIO_PROJECT_ID || ''
const dataset =
  process.env.SANITY_DATASET || process.env.SANITY_STUDIO_DATASET || 'production'

const escapeHtml = (value = '') =>
  String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;')

const dateLabel = (value) =>
  new Intl.DateTimeFormat('en-US', {
    month: 'long',
    day: 'numeric',
    year: 'numeric',
    timeZone: 'America/New_York',
  }).format(new Date(value))

const absoluteUrl = (value) =>
  value?.startsWith('/') ? `https://plandit.app${value}` : value

const readingTime = (post) => {
  const words = (post.body || [])
    .flatMap((block) => block.children || [])
    .map((child) => child.text || '')
    .join(' ')
    .trim()
    .split(/\s+/)
    .filter(Boolean).length
  return Math.max(1, Math.ceil(words / 220))
}

const ctaContent = {
  waitlist: {
    eyebrow: 'Turn inspiration into a real day',
    title: 'You saved the places. Let Plandit make the plan.',
    text: 'Join the early access list and be first to turn scattered places into a day that fits your time, budget, and distance.',
    href: '/#waitlist',
    label: 'Get early access',
  },
  'group-plans': {
    eyebrow: 'Planning for the group?',
    title: 'Send the plan. Not another question.',
    text: 'Bring everyone’s ideas into one concrete, budget-visible day with the timing and route ready to share.',
    href: '/group-plans',
    label: 'See group plans',
  },
  'free-window': {
    eyebrow: 'Only have a few hours?',
    title: 'Make the free window count.',
    text: 'Start with the time you have and how far you will go. Plandit builds a nearby plan that fits.',
    href: '/free-window',
    label: 'See short plans',
  },
}

const pageHead = ({
  title,
  description,
  canonical,
  image,
  type = 'article',
}) => `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(title)}</title>
  <meta name="description" content="${escapeHtml(description)}">
  <meta name="theme-color" content="#0b0d0c">
  <link rel="canonical" href="${escapeHtml(canonical)}">
  <script async src="https://www.googletagmanager.com/gtag/js?id=G-R1ZGRKW23Z"></script>
  <script>window.dataLayer=window.dataLayer||[];function gtag(){dataLayer.push(arguments)}gtag("js",new Date());gtag("config","G-R1ZGRKW23Z");</script>
  <script defer src="/_vercel/insights/script.js"></script>
  <meta property="og:type" content="${escapeHtml(type)}">
  <meta property="og:url" content="${escapeHtml(canonical)}">
  <meta property="og:title" content="${escapeHtml(title)}">
  <meta property="og:description" content="${escapeHtml(description)}">
  <meta property="og:image" content="${escapeHtml(absoluteUrl(image))}">
  <meta name="twitter:card" content="summary_large_image">
  <link rel="icon" type="image/png" sizes="32x32" href="/images/favicon-32.png">
  <link rel="apple-touch-icon" href="/images/favicon-180.png">
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Manrope:wght@400;500;600;700;800&display=swap">
  <link rel="stylesheet" href="/styles.css">
  <link rel="stylesheet" href="/blog.css">
</head>`

const header = `
<header class="site-header scrolled">
  <div class="shell header-inner">
    <a class="logo" href="/" aria-label="Plandit home"><img src="/images/logo-mark-app-icon.png" width="40" height="40" alt=""><span>Pland<span>it</span></span></a>
    <nav class="nav blog-nav" aria-label="Main navigation">
      <a href="/blog">Blog</a>
      <a href="/#how-it-works">How it works</a>
      <a href="/#waitlist" class="nav-cta">Get early access <span aria-hidden="true">→</span></a>
    </nav>
  </div>
</header>`

const footer = `
<footer class="site-footer">
  <div class="shell footer-grid">
    <a class="logo footer-logo" href="/" aria-label="Plandit home"><img src="/images/logo-mark-app-icon.png" width="40" height="40" alt=""><span>Pland<span>it</span></span></a>
    <p>Saved places.<br>Real plans.</p>
    <div class="footer-links"><a href="/blog">Blog</a><a href="/group-plans">Group plans</a><a href="/free-window">Short plans</a><a href="/privacy">Privacy</a><a href="/terms">Terms</a><a href="/support">Support</a></div>
    <p class="copyright">© 2026 Plandit. Made for days worth leaving the house for.</p>
  </div>
</footer>`

const renderBody = (body) =>
  toHTML(body || [], {
    components: {
      marks: {
        link: ({children, value}) => {
          const href = value?.href || '#'
          const external = /^https?:\/\//.test(href)
          return `<a href="${escapeHtml(href)}"${external ? ' target="_blank" rel="noopener noreferrer"' : ''}>${children}</a>`
        },
      },
      unknownType: () => '',
      unknownMark: ({children}) => children,
    },
  })

const getPosts = async () => {
  if (!projectId) {
    console.warn('SANITY_PROJECT_ID is not set; building the sample blog post.')
    return [samplePost]
  }

  const client = createClient({
    projectId,
    dataset,
    apiVersion: '2026-10-25',
    useCdn: false,
    perspective: 'published',
  })
  const query = `*[
    _type == "post" &&
    defined(slug.current) &&
    publishedAt <= now()
  ] | order(publishedAt desc) {
    _id,
    title,
    "slug": slug.current,
    excerpt,
    author,
    category,
    tags,
    publishedAt,
    body,
    ctaVariant,
    seoTitle,
    seoDescription,
    "coverUrl": coverImage.asset->url,
    "coverAlt": coverImage.alt
  }`
  const posts = await client.fetch(query)
  return posts.length ? posts : [samplePost]
}

const renderCard = (post) => `
<article class="blog-card">
  <a class="blog-card-image" href="/blog/${escapeHtml(post.slug)}"><img src="${escapeHtml(post.coverUrl)}" alt="${escapeHtml(post.coverAlt)}" loading="lazy"></a>
  <div class="blog-card-copy">
    <p class="blog-meta"><span>${escapeHtml(post.category)}</span> · ${escapeHtml(dateLabel(post.publishedAt))}</p>
    <h2><a href="/blog/${escapeHtml(post.slug)}">${escapeHtml(post.title)}</a></h2>
    <p>${escapeHtml(post.excerpt)}</p>
    <a class="blog-read-link" href="/blog/${escapeHtml(post.slug)}">Read article <span aria-hidden="true">→</span></a>
  </div>
</article>`

const renderIndex = (posts) => {
  const title = 'Plandit Blog — NYC day plans, city guides, and saved places'
  const description =
    'Practical guides for turning saved places into nearby, on-budget days you can actually go do.'
  return `${pageHead({
    title,
    description,
    canonical: 'https://plandit.app/blog',
    image: 'https://plandit.app/images/social-preview.png',
    type: 'website',
  })}
<body>${header}
<main>
  <section class="blog-hero">
    <div class="shell">
      <p class="kicker"><span></span> The Plandit blog</p>
      <h1>Places worth saving.<br><em>Plans worth doing.</em></h1>
      <p>City guides and practical ideas for turning the places on your list into a day that fits.</p>
    </div>
  </section>
  <section class="blog-list-section">
    <div class="shell blog-list">${posts.map(renderCard).join('')}</div>
  </section>
  <section class="blog-cta">
    <div class="shell blog-cta-inner">
      <div><p class="kicker"><span></span> Ready when you are</p><h2>Save the place. Plandit will handle the day.</h2></div>
      <a class="button button-primary" href="/#waitlist" data-blog-event="blog_cta_click" data-article-slug="blog-index" data-cta-variant="waitlist" data-link-location="index-closing">Get early access <span aria-hidden="true">→</span></a>
    </div>
  </section>
</main>${footer}<script src="/blog.js"></script></body></html>`
}

const renderArticle = (post) => {
  const seoTitle = post.seoTitle || `${post.title} | Plandit`
  const description = post.seoDescription || post.excerpt
  const canonical = `https://plandit.app/blog/${post.slug}`
  const cta = ctaContent[post.ctaVariant] || ctaContent.waitlist
  return `${pageHead({
    title: seoTitle,
    description,
    canonical,
    image: absoluteUrl(post.coverUrl),
  })}
<body>${header}
<main>
  <article>
    <header class="article-header">
      <div class="shell article-header-inner">
        <a class="article-back" href="/blog">← All articles</a>
        <p class="blog-meta"><span>${escapeHtml(post.category)}</span> · ${escapeHtml(dateLabel(post.publishedAt))} · ${readingTime(post)} min read</p>
        <h1>${escapeHtml(post.title)}</h1>
        <p class="article-deck">${escapeHtml(post.excerpt)}</p>
        <p class="article-author">By ${escapeHtml(post.author?.name || 'Plandit')}${post.author?.role ? ` · ${escapeHtml(post.author.role)}` : ''}</p>
      </div>
    </header>
    <div class="shell article-cover"><img src="${escapeHtml(post.coverUrl)}" alt="${escapeHtml(post.coverAlt)}"></div>
    <div class="shell article-layout">
      <div class="article-body">${renderBody(post.body)}</div>
      <aside class="article-aside"><p>Make this a real day</p><a href="${cta.href}" data-blog-event="blog_cta_click" data-article-slug="${escapeHtml(post.slug)}" data-cta-variant="${escapeHtml(post.ctaVariant || 'waitlist')}" data-link-location="article-aside">${cta.label} →</a></aside>
    </div>
  </article>
  <section class="blog-cta article-cta">
    <div class="shell blog-cta-inner">
      <div><p class="kicker"><span></span> ${escapeHtml(cta.eyebrow)}</p><h2>${escapeHtml(cta.title)}</h2><p>${escapeHtml(cta.text)}</p></div>
      <a class="button button-primary" href="${cta.href}" data-blog-event="blog_cta_click" data-article-slug="${escapeHtml(post.slug)}" data-cta-variant="${escapeHtml(post.ctaVariant || 'waitlist')}" data-link-location="article-closing">${escapeHtml(cta.label)} <span aria-hidden="true">→</span></a>
    </div>
  </section>
</main>${footer}<script src="/blog.js"></script>
<script type="application/ld+json">${JSON.stringify({
    '@context': 'https://schema.org',
    '@type': 'BlogPosting',
    headline: post.title,
    description,
    datePublished: post.publishedAt,
    author: {'@type': 'Organization', name: post.author?.name || 'Plandit'},
    image: absoluteUrl(post.coverUrl),
    mainEntityOfPage: canonical,
    publisher: {
      '@type': 'Organization',
      name: 'Plandit',
      url: 'https://plandit.app',
    },
  }).replaceAll('<', '\\u003c')}</script>
</body></html>`
}

const writeSitemap = async (posts) => {
  const staticUrls = [
    ['https://plandit.app/', '1.0'],
    ['https://plandit.app/blog', '0.9'],
    ['https://plandit.app/group-plans', '0.8'],
    ['https://plandit.app/free-window', '0.8'],
    ['https://plandit.app/privacy', '0.3'],
    ['https://plandit.app/terms', '0.3'],
    ['https://plandit.app/support', '0.5'],
  ]
  const urls = [
    ...staticUrls.map(
      ([url, priority]) =>
        `  <url><loc>${url}</loc><changefreq>weekly</changefreq><priority>${priority}</priority></url>`,
    ),
    ...posts.map(
      (post) =>
        `  <url><loc>https://plandit.app/blog/${escapeHtml(post.slug)}</loc><lastmod>${new Date(post.publishedAt).toISOString()}</lastmod><changefreq>monthly</changefreq><priority>0.7</priority></url>`,
    ),
  ]
  await writeFile(
    join(websiteDir, 'sitemap.xml'),
    `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.join('\n')}\n</urlset>\n`,
  )
}

const posts = await getPosts()
await rm(blogDir, {recursive: true, force: true})
await mkdir(blogDir, {recursive: true})
await writeFile(join(blogDir, 'index.html'), renderIndex(posts))

for (const post of posts) {
  const postDir = join(blogDir, post.slug)
  await mkdir(postDir, {recursive: true})
  await writeFile(join(postDir, 'index.html'), renderArticle(post))
}

await writeSitemap(posts)
console.log(`Built ${posts.length} blog post${posts.length === 1 ? '' : 's'}.`)
