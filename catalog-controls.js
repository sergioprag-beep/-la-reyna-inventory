(() => {
  'use strict';
  function addProductDuplicateButtons() {
    if ((location.hash.split('#')[1] || '').split('?')[0] !== 'productos') return;
    document.querySelectorAll('#content .catalog-card').forEach(card => {
      const edit = card.querySelector('[data-action="edit-product"]');
      const actions = edit?.parentElement;
      if (!edit || !actions || actions.querySelector('[data-action="duplicate-product"]')) return;
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'btn';
      button.dataset.action = 'duplicate-product';
      button.dataset.id = edit.dataset.id;
      button.textContent = 'Duplicar';
      edit.insertAdjacentElement('afterend', button);
    });
  }
  const content = document.getElementById('content');
  if (content) new MutationObserver(addProductDuplicateButtons).observe(content, { childList: true, subtree: true });
  addProductDuplicateButtons();
})();
