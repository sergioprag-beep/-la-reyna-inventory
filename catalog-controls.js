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

// Use an in-app ingredient picker because mobile Safari does not reliably show datalist options.
(() => {
  'use strict';
  let active = null, activeIndex = -1, panel = null;
  const normalize = value => String(value || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
  const escapeHtml = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  function getOptions(input) {
    const list = document.getElementById(input.dataset.mobilePickerList || input.getAttribute('list'));
    const query = normalize(input.value);
    return [...(list?.options || [])].filter(option => option.value && (!query || normalize(`${option.value} ${option.textContent}`).includes(query))).slice(0, 60);
  }
  function ensurePanel() {
    if (panel) return panel;
    const style = document.createElement('style');
    style.id = 'lrx-recipe-mobile-picker-style';
    style.textContent = '.recipe-ingredient-options{position:fixed;z-index:100020;overflow:auto;overscroll-behavior:contain;-webkit-overflow-scrolling:touch;border:1px solid #cfd8e8;border-radius:12px;background:#fff;color:#172033;box-shadow:0 14px 34px #1018283d;padding:4px}.recipe-ingredient-options[hidden]{display:none!important}.recipe-ingredient-option{display:flex;align-items:flex-start;justify-content:space-between;gap:12px;width:100%;min-height:48px;padding:11px 12px;border:0;border-bottom:1px solid #edf0f5;background:#fff;color:#172033;text-align:left;font:inherit;cursor:pointer;touch-action:manipulation}.recipe-ingredient-option:last-child{border-bottom:0}.recipe-ingredient-option:active,.recipe-ingredient-option.active{background:#eef4ff}.recipe-ingredient-option span{min-width:0;overflow-wrap:anywhere}.recipe-ingredient-option small{flex:none;color:#667085;font-size:12px}.recipe-ingredient-empty{padding:14px;color:#667085;font-size:14px}@media(max-width:650px){.recipe-ingredient-options{border-radius:10px;padding:3px}.recipe-ingredient-option{min-height:50px;padding:12px 10px;font-size:15px}.recipe-ingredient-option small{font-size:11px}}';
    document.head.append(style);
    panel = document.createElement('div');
    panel.id = 'recipeIngredientOptions';
    panel.className = 'recipe-ingredient-options';
    panel.setAttribute('role', 'listbox');
    panel.hidden = true;
    document.body.append(panel);
    panel.addEventListener('pointerdown', event => {
      const item = event.target.closest('[data-recipe-option]');
      if (!item || !active) return;
      event.preventDefault();
      choose(Number(item.dataset.recipeOption));
    });
    return panel;
  }
  function position() {
    if (!panel || panel.hidden || !active?.isConnected) return;
    const rect = active.getBoundingClientRect(), viewport = window.visualViewport;
    const top = viewport?.offsetTop || 0, left = viewport?.offsetLeft || 0;
    const height = viewport?.height || innerHeight, width = viewport?.width || innerWidth;
    const pad = 10, gap = 6, bottom = top + height - pad;
    const below = bottom - (rect.bottom + top), above = rect.top - pad;
    const upward = below < 150 && above > below;
    const maxHeight = Math.max(90, Math.min(320, height * .42, upward ? above : below));
    const panelWidth = Math.max(180, Math.min(rect.width, width - pad * 2));
    panel.style.left = `${Math.max(left + pad, Math.min(rect.left + left, left + width - pad - panelWidth))}px`;
    panel.style.width = `${panelWidth}px`;
    panel.style.maxHeight = `${maxHeight}px`;
    panel.style.top = upward ? `${Math.max(top + pad, rect.top + top - maxHeight - gap)}px` : `${Math.min(bottom - maxHeight, rect.bottom + top + gap)}px`;
  }
  function close() {
    if (panel) panel.hidden = true;
    if (active) active.setAttribute('aria-expanded', 'false');
    active = null;
    activeIndex = -1;
  }
  function render(input) {
    active = input;
    const list = ensurePanel(), options = getOptions(input);
    input.setAttribute('aria-expanded', 'true');
    input.setAttribute('aria-controls', list.id);
    list.innerHTML = options.length ? options.map((option, index) => `<button type="button" class="recipe-ingredient-option${index === activeIndex ? ' active' : ''}" role="option" aria-selected="${index === activeIndex}" data-recipe-option="${index}"><span>${escapeHtml(option.value)}</span><small>${escapeHtml(option.textContent || '')}</small></button>`).join('') : '<div class="recipe-ingredient-empty">No hay ingredientes que coincidan.</div>';
    list.hidden = false;
    position();
  }
  function choose(index) {
    if (!active) return;
    const input = active, option = getOptions(input)[index];
    if (!option) return;
    input.value = option.value;
    input.dispatchEvent(new Event('input', {bubbles:true}));
    if (option.dataset.productId) input.dataset.productId = option.dataset.productId;
    if (option.dataset.prepId) input.dataset.prepId = option.dataset.prepId;
    close();
    input.focus({preventScroll:true});
  }
  function bind(input) {
    if (input.dataset.mobilePickerBound) return;
    input.dataset.mobilePickerBound = '1';
    input.dataset.mobilePickerList = input.getAttribute('list') || '';
    input.removeAttribute('list');
    input.setAttribute('autocomplete', 'off');
    input.setAttribute('role', 'combobox');
    input.setAttribute('aria-autocomplete', 'list');
    input.addEventListener('focus', () => { activeIndex = -1; render(input); setTimeout(position, 100); });
    input.addEventListener('input', () => { activeIndex = -1; render(input); });
    input.addEventListener('keydown', event => {
      if (event.key === 'Escape') { close(); return; }
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
        const options = getOptions(input);
        if (!options.length) return;
        event.preventDefault();
        active = input;
        activeIndex = (activeIndex + (event.key === 'ArrowDown' ? 1 : -1) + options.length) % options.length;
        render(input);
        panel.querySelector(`[data-recipe-option="${activeIndex}"]`)?.scrollIntoView({block:'nearest'});
      }
      if (event.key === 'Enter' && active === input && !panel?.hidden) {
        const options = getOptions(input);
        if (options.length) { event.preventDefault(); choose(Math.max(0, activeIndex)); }
      }
    });
    input.addEventListener('blur', () => setTimeout(() => { if (active === input) close(); }, 250));
  }
  function scan(root = document) {
    if (root.matches?.('.ri-product')) bind(root);
    root.querySelectorAll?.('.ri-product').forEach(bind);
    const editor = document.querySelector('#modalBox .recipe-editor-heading small');
    const orphanFiles = document.querySelector('#modalBox #recipeDocStatus');
    if (editor?.textContent.includes('NUEVO') && orphanFiles) orphanFiles.textContent = 'Sin documento adjunto.';
  }
  function start() {
    scan();
    new MutationObserver(records => records.forEach(record => record.addedNodes.forEach(node => { if (node.nodeType === 1) scan(node); }))).observe(document.body, {childList:true, subtree:true});
    const reposition = () => position();
    addEventListener('resize', reposition);
    addEventListener('scroll', reposition, true);
    window.visualViewport?.addEventListener('resize', reposition);
    window.visualViewport?.addEventListener('scroll', reposition);
    document.addEventListener('pointerdown', event => { if (!event.target.closest('.ri-product') && !event.target.closest('#recipeIngredientOptions')) close(); });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, {once:true});
  else start();
})();
