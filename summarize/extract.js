// Run inside the page (Chrome, via AppleScript): the main article text, or a reason it isn't one.
// Readability-lite: every paragraph adds its length to its parent (and half to the grandparent);
// the best-scoring container is the article.
(() => {
  const ps = [...document.querySelectorAll("p, pre, blockquote")].filter(p => p.innerText && p.innerText.trim().length > 40);
  const score = new Map();
  for (const p of ps) {
    const n = p.innerText.trim().length;
    const a = p.parentElement, b = a && a.parentElement;
    if (a) score.set(a, (score.get(a) || 0) + n);
    if (b) score.set(b, (score.get(b) || 0) + n / 2);
  }
  let best = null, top = 0;
  for (const [el, s] of score) if (s > top) { top = s; best = el; }
  if (!best) return JSON.stringify({ article: false });
  const text = best.innerText.replace(/\n{3,}/g, "\n\n").trim();
  const words = text.split(/\s+/).length;
  const paras = best.querySelectorAll("p").length;
  const h1 = document.querySelector("h1");
  return JSON.stringify({
    article: words >= 250 && paras >= 4,
    title: (h1 && h1.innerText.trim()) || document.title,
    url: location.href, words, text: text.slice(0, 80000),
  });
})()
