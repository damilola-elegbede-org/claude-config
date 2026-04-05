# Email Patterns

**Rule:** Do not send plain-text emails. Use HTML by default. Use Markdown only if the
exact send path is known to render it correctly; otherwise convert it to HTML first.

### Markdown note

If drafting in Markdown for thinking or intermediate editing, convert it into structured HTML before send. Preserve:

- headings as bold section labels or semantic headers when supported
- bullet lists as `<ul>` / `<ol>`
- links as clickable `<a href="...">...</a>`
- emphasis as `<strong>` / `<em>`

## 1. Linked recommendation email

Use for travel, product choices, or research summaries.

```html
<p>D —</p>
<p><strong>Bottom line:</strong> [one to three sentences with recommendation].</p>
<p><strong>Quick links:</strong></p>
<ul>
  <li><a href="LINK_1">Primary source / search</a></li>
  <li><a href="LINK_2">Secondary source / search</a></li>
</ul>
<p><strong>Options</strong></p>
<ol>
  <li>
    <strong>Option name — price — duration</strong><br />
    Short tradeoff note.
  </li>
  <li>
    <strong>Option name — price — duration</strong><br />
    Short tradeoff note.
  </li>
</ol>
<p><strong>Recommendation:</strong> [clear recommendation]</p>
<p><strong>Watch-outs:</strong> [key caveats]</p>
<p>— Clara</p>
```

## 2. Executive update email

```html
<p>D —</p>
<p><strong>Bottom line:</strong> [status in 1-2 sentences].</p>
<p><strong>What changed:</strong></p>
<ul>
  <li>[change 1]</li>
  <li>[change 2]</li>
</ul>
<p><strong>Risk / blocker:</strong> [if any]</p>
<p><strong>Recommended next step:</strong> [action]</p>
<p>— Clara</p>
```

## 3. Coordination email with CC

Use only when D explicitly asks for CC, or when replying within an existing thread where preserving recipients is clearly intended.

```html
<p>D, [Name] —</p>
<p><strong>Bottom line:</strong> [shared update].</p>
<p><strong>Decision / recommendation:</strong> [clear answer]</p>
<p><strong>Next step:</strong> [owner + action]</p>
<p>— Clara</p>
```

## Anchor text examples

Prefer:

- `Google Flights — DEN → LIS — Jun 2`
- `Booking page`
- `Trip comparison sheet`
- `Hotel option 1`

Avoid:

- raw pasted URLs when readable anchor text would work better
- `click here`
- vague labels like `link 1`
