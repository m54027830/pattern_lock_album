(() => {
  const picker = document.querySelector('[data-language-picker]');
  if (!picker) return;
  picker.addEventListener('click', event => {
    const link = event.target.closest('a[data-language-link]');
    if (link && location.hash) {
      const destination = new URL(link.getAttribute('href'), location.href);
      destination.hash = location.hash;
      link.href = destination.href;
    }
  });
  document.addEventListener('click', event => {
    if (!picker.contains(event.target)) picker.open = false;
  });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && picker.open) {
      picker.open = false;
      picker.querySelector('summary').focus();
    }
  });
})();
