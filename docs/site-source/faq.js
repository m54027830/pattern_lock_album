(() => {
  const form = document.querySelector('[data-faq-search]');
  if (!form) return;
  const input = form.querySelector('input');
  const status = document.querySelector('[data-search-status]');
  const empty = document.querySelector('[data-empty]');
  const items = Array.from(document.querySelectorAll('.faq-item'));
  const groups = Array.from(document.querySelectorAll('.faq-section'));
  const countTemplate = form.dataset.countTemplate;
  const normalize = value => value.normalize('NFKC').toLocaleLowerCase().trim();
  const texts = new Map(items.map(item => [item, normalize(item.textContent)]));
  function filter() {
    const query = normalize(input.value);
    const words = query.split(/\s+/).filter(Boolean);
    let count = 0;
    items.forEach(item => {
      const matched = words.every(word => texts.get(item).includes(word));
      item.hidden = !matched;
      item.open = matched && words.length > 0;
      if (matched) count++;
    });
    groups.forEach(group => {
      group.hidden = !Array.from(group.querySelectorAll('.faq-item')).some(item => !item.hidden);
      document.querySelectorAll(`[data-group-link="${group.id}"]`).forEach(link => {
        link.parentElement.hidden = group.hidden;
      });
    });
    status.textContent = countTemplate.replace('{count}', count).replace('{total}', items.length);
    empty.hidden = count > 0;
  }
  function revealHash() {
    let id;
    try { id = decodeURIComponent(location.hash.slice(1)); } catch { return; }
    const target = document.getElementById(id);
    if (!target || !target.classList.contains('faq-item')) return;
    if (target.hidden) { input.value = ''; filter(); }
    target.open = true;
    requestAnimationFrame(() => target.scrollIntoView({block:'start'}));
  }
  form.hidden = false;
  input.addEventListener('input', filter);
  form.addEventListener('submit', event => event.preventDefault());
  form.addEventListener('reset', () => {
    input.value = '';
    filter();
    input.focus();
  });
  window.addEventListener('hashchange', revealHash);
  let printState;
  window.addEventListener('beforeprint', () => {
    printState = items.map(item => ({hidden:item.hidden,open:item.open}));
    items.forEach(item => {item.hidden = false; item.open = true;});
    groups.forEach(group => {group.hidden = false;});
    empty.hidden = true;
  });
  window.addEventListener('afterprint', () => {
    if (!printState) return;
    filter();
    items.forEach((item, i) => {item.hidden = printState[i].hidden; item.open = printState[i].open;});
    printState = undefined;
  });
  filter();
  revealHash();
})();
