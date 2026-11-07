// Puts each code block of a post in a snowztech .sn-code frame, with its
// data-name in the bar and a copy button. Without this script, the plain
// <pre> still reads fine.
import { initCopyButtons } from "https://cdn.jsdelivr.net/npm/@snowztech/ui-js@0.3/dist/snowztech-ui.esm.js";

const icons =
  '<svg class="sn-copy-btn__idle" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="11" height="11" rx="1.5"/><path d="M5 15V5a1 1 0 0 1 1-1h10"/></svg>' +
  '<svg class="sn-copy-btn__copied" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m4 12 5 5L20 6"/></svg>';

for (const pre of document.querySelectorAll(".sn-prose pre")) {
  const figure = document.createElement("figure");
  figure.className = "sn-code";
  figure.innerHTML = `<figcaption class="sn-code__bar"><span class="sn-code__name"></span><button type="button" class="sn-copy-btn" data-sn-copy aria-label="Copy">${icons}</button></figcaption>`;
  figure.querySelector(".sn-code__name").textContent = pre.dataset.name ?? "";
  pre.replaceWith(figure);
  figure.append(pre);
}
initCopyButtons();
