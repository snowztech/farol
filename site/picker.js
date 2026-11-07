// Tabs and swatches crossfade the picture under them. Arrow keys move between them, as in any tab list.
function picker(buttons, stack, select) {
  const shotOf = button => [...stack.children].find(shot => shot.dataset.key === (button.dataset.key ?? button.id.slice(4)));
  // A picture's sources wait in data attributes until it's about to show, and hovering its button starts the download.
  // Only this stack's own: a stack inside one of its pictures loads when its own buttons ask.
  const wake = shot => {
    for (const element of shot.querySelectorAll("[data-src], [data-srcset]")) {
      if (element.closest(".stack") !== stack) continue;
      if (element.dataset.srcset) element.srcset = element.dataset.srcset;
      if (element.dataset.src) element.src = element.dataset.src;
      delete element.dataset.srcset;
      delete element.dataset.src;
    }
  };
  let latest;
  const choose = async button => {
    latest = button;
    for (const other of buttons) {
      const on = other === button;
      other.setAttribute(other.role === "tab" ? "aria-selected" : "aria-checked", on);
      other.tabIndex = on ? 0 : -1;
    }
    select?.(button);
    const target = shotOf(button);
    wake(target);
    // Faded in once decoded, so the frame never fades to a blank picture. A quicker click in between wins.
    await target.querySelector("img").decode().catch(() => {});
    if (latest !== button) return;
    for (const shot of stack.children) shot.toggleAttribute("data-active", shot === target);
  };
  buttons.forEach((button, index) => {
    button.addEventListener("pointerenter", () => wake(shotOf(button)));
    button.addEventListener("focus", () => wake(shotOf(button)));
    button.addEventListener("click", () => choose(button));
    button.addEventListener("keydown", event => {
      const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[event.key];
      if (!step) return;
      event.preventDefault();
      const next = buttons[(index + step + buttons.length) % buttons.length];
      next.focus();
      choose(next);
    });
  });
}
