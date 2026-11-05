// Small static pages. Two tones, one accent, system font.
function page(title: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>${title}</title>
<style>
:root { --bg: #F4F4F1; --fg: #121212; --muted: rgba(18,18,18,.62); --accent: #5A78FF; }
@media (prefers-color-scheme: dark) { :root { --bg: #121212; --fg: #F4F4F1; --muted: rgba(244,244,241,.62); } }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 17px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
main { max-width: 560px; margin: 0 auto; padding: 56px 20px 72px; }
h1 { font-size: 34px; line-height: 1.1; letter-spacing: -0.02em; margin: 0 0 16px; }
h2 { font-size: 19px; margin: 32px 0 8px; }
p, li { color: var(--muted); }
strong { color: var(--fg); }
.dot { display: inline-block; width: 10px; height: 10px; border-radius: 50%; background: var(--accent); margin-right: 8px; }
.brand { font-weight: 600; margin-bottom: 40px; }
.button { display: block; text-align: center; background: var(--accent); color: #F4F4F1; text-decoration: none; font-weight: 600; padding: 16px; border-radius: 14px; margin: 28px 0 16px; }
a { color: var(--accent); }
</style>
</head>
<body><main><div class="brand"><span class="dot"></span>Loop</div>
${body}
</main></body>
</html>`;
}

export function invitePage(code: string | null): string {
  const button = code
    ? `<a class="button" href="loop://invite/${code}">Open in Loop</a>`
    : '';
  return page('Join a Loop circle', `<h1>You are invited to a circle.</h1>
<p>Loop is a quiet workout app. Friends see who showed up this week, nothing more.</p>
${button}
<p>Loop is in early testing. Ask the friend who invited you for a TestFlight invite.</p>`);
}

export function privacyPage(): string {
  return page('Loop privacy', `<h1>Privacy</h1>
<p>Loop is built so our server never holds personal data. Your workouts, routes and health data stay on your iPhone.</p>
<h2>What the server stores</h2>
<ul>
<li><strong>A random ID</strong> made by your phone. We keep only a hash of it.</li>
<li><strong>A made-up handle</strong> such as "Kite 41". It is not your name.</li>
<li><strong>Your circles</strong>: which friends you added and which nearby or same-hour circle you are in. For those circles we keep a rough city area and the hour you usually go out, only if you turn them on.</li>
<li><strong>Showed-up days</strong>: the dates you worked out and the kind (run, walk, ride, swim, gym). Kept for 10 weeks.</li>
<li><strong>Cheers</strong> between circle members. Kept for 14 days.</li>
<li><strong>A notification token</strong> so cheers can reach you.</li>
<li><strong>Anonymous map counts</strong>: how many workouts passed through each map square, with a random per-square tag so one person is counted once. These are not linked to your ID and are kept for 3 months. A square shows on the map only after 5 different people.</li>
</ul>
<h2>What the server never receives</h2>
<p>Contacts, names, phone numbers, emails, routes, distances, paces, health data or precise places. IP addresses are not logged.</p>
<h2>Delete everything</h2>
<p>In the app, open Settings and tap <strong>Delete my data</strong>. This removes your ID, handle, friends, circles, showed-up days, cheers, invites and notification token right away. Anonymous map counts are not linked to you, so they stay until they expire.</p>
<h2>Contact</h2>
<p>Questions: open an issue at <a href="https://github.com/pranay8297/loop">github.com/pranay8297/loop</a></p>`);
}

export function supportPage(): string {
  return page('Loop support', `<h1>Support</h1>
<p>Loop is in early testing on TestFlight.</p>
<h2>Join a friend</h2>
<p>Ask a friend for an invite link and open it on your iPhone.</p>
<h2>Leave a circle</h2>
<p>Open the circle and tap Leave. You will not be placed in that kind of circle again until you turn it back on.</p>
<h2>Delete my data</h2>
<p>Open Settings in the app and tap Delete my data.</p>
<h2>Contact</h2>
<p>Questions: open an issue at <a href="https://github.com/pranay8297/loop">github.com/pranay8297/loop</a></p>`);
}
