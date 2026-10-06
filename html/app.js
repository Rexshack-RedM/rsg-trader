const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'rsg-trader';
const $ = (id) => document.getElementById(id);

let S = {};            // locale strings
let shop = null;       // { trader, mode, items, maxBuy, maxSell, cash }
let admin = { traders: [], itemList: [], defaultModel: '', imagePath: '', trader: null, items: [] };
let trade = null;      // item currently in the trade modal
let editingTrader = null;
let editingItem = null;
let confirmAction = null;

/* ---------------- helpers ---------------- */
async function post(name, data = {}) {
    try {
        const r = await fetch(`https://${RES}/${name}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(data),
        });
        return await r.json();
    } catch (e) {
        return null;
    }
}

const t = (k) => S[k] || k;
const money = (n) => '$' + Number(n || 0).toFixed(2);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function applyStrings() {
    document.querySelectorAll('[data-i18n]').forEach((el) => { if (S[el.dataset.i18n]) el.textContent = S[el.dataset.i18n]; });
    document.querySelectorAll('[data-i18n-ph]').forEach((el) => { if (S[el.dataset.i18nPh]) el.placeholder = S[el.dataset.i18nPh]; });
    document.querySelectorAll('[data-i18n-title]').forEach((el) => { if (S[el.dataset.i18nTitle]) el.title = S[el.dataset.i18nTitle]; });
}

// notifications are shown with ox_lib (lib.notify) by the client
function toast(type, msg) {
    if (msg) post('notify', { type, msg });
}

function showResult(res) {
    if (res && res.msg) toast(res.ok ? 'success' : 'error', res.msg);
}

function stockLevel(item) {
    if (item.stock <= item.lowstock) return 'bad';
    if (item.stock >= item.highstock) return 'good';
    return 'warn';
}

/* ---------------- open / close ---------------- */
function hideAll() {
    $('shop').classList.add('hidden');
    $('admin').classList.add('hidden');
    closeModal();
}

function closeUI() {
    hideAll();
    $('app').classList.add('hidden');
    post('close');
}

function openModal(id) {
    $('modal-backdrop').classList.remove('hidden');
    document.querySelectorAll('.modal').forEach((m) => m.classList.add('hidden'));
    $(id).classList.remove('hidden');
    const first = [...$(id).querySelectorAll('input:not([type=checkbox]):not([type=hidden])')].find((el) => el.offsetParent !== null);
    if (first) setTimeout(() => first.focus(), 30);
}

function closeModal() {
    $('modal-backdrop').classList.add('hidden');
    document.querySelectorAll('.modal').forEach((m) => m.classList.add('hidden'));
    trade = null;
}

function modalOpen() {
    return !$('modal-backdrop').classList.contains('hidden');
}

/* ================= SHOP ================= */
function renderShop() {
    const { trader, mode, items } = shop;
    $('shop-title').textContent = trader.name;
    $('shop-sub').textContent = `${t('ui_cash')}: ${money(shop.cash)}`;
    document.querySelectorAll('.tab').forEach((b) => b.classList.toggle('active', b.dataset.mode === mode));

    const list = $('shop-list');
    const isBuy = mode === 'buy';
    const rows = isBuy ? items : items.filter((i) => i.owned > 0);

    if (!rows.length) {
        list.innerHTML = `<div class="empty">${esc(isBuy ? t('ui_no_items') : t('ui_no_sell_items'))}</div>`;
        return;
    }

    list.innerHTML = rows.map((i) => {
        const level = stockLevel(i);
        const pct = Math.max(3, Math.min(100, (i.stock / Math.max(1, i.highstock)) * 100));
        const soldOut = i.stock < 1;
        const levelLabel = soldOut ? t('ui_sold_out') : level === 'bad' ? t('ui_low') : level === 'good' ? t('ui_high') : t('ui_normal');
        const disabled = isBuy && i.stock < 1;
        const desc = isBuy
            ? `${t('ui_stock')}: ${i.stock} · ${t('ui_owned')}: ${i.owned}`
            : `${t('ui_owned')}: ${i.owned} · ${t('ui_stock')}: ${i.stock}`;
        return `
        <div class="row clickable ${disabled ? 'disabled' : ''}" data-idx="${items.indexOf(i)}">
            <div class="badge"><img src="${esc(i.image)}" onerror="this.style.display='none'"></div>
            <div class="row-main">
                <div class="row-title">${esc(i.label)}<span class="pill ${level}">${esc(levelLabel)}</span></div>
                <div class="row-desc">${esc(desc)}</div>
                <div class="stat"><div class="stat-${level}" style="width:${pct}%"></div></div>
            </div>
            <div class="price">${money(isBuy ? i.buyprice : i.sellprice)}<small>${esc(t('ui_each'))}</small></div>
        </div>`;
    }).join('');
}

// buy max also respects what the player can afford
function tradeMax(item) {
    if (shop.mode !== 'buy') return Math.min(shop.maxSell, item.owned);
    const affordable = item.buyprice > 0 ? Math.floor(shop.cash / item.buyprice + 1e-9) : shop.maxBuy;
    return Math.max(0, Math.min(shop.maxBuy, item.stock, affordable));
}

function openTrade(item) {
    trade = item;
    const isBuy = shop.mode === 'buy';
    $('trade-title').textContent = isBuy ? t('ui_buy') : t('ui_sell');
    $('trade-img').src = item.image;
    $('trade-label').textContent = item.label;
    $('trade-desc').textContent = `${money(isBuy ? item.buyprice : item.sellprice)} ${t('ui_each')} · ${t('ui_max')}: ${tradeMax(item)}`;
    $('qty').value = 1;
    $('qty').max = tradeMax(item);
    updateTotal();
    openModal('modal-trade');
}

function clampQty() {
    const max = tradeMax(trade);
    let q = parseInt($('qty').value, 10);
    if (isNaN(q) || q < 1) q = 1;
    if (q > max) q = Math.max(1, max);
    return q;
}

function updateTotal() {
    if (!trade) return;
    const q = clampQty();
    const price = shop.mode === 'buy' ? trade.buyprice : trade.sellprice;
    const total = price * q;
    const el = $('trade-total');
    el.textContent = money(total);
    const over = shop.mode === 'buy' && total > shop.cash;
    el.classList.toggle('over', over);
    $('trade-confirm').disabled = over || tradeMax(trade) < 1;
}

/* ================= ADMIN ================= */
function setAdminView(view) {
    const items = view === 'items';
    $('view-traders').classList.toggle('hidden', items);
    $('view-items').classList.toggle('hidden', !items);
    $('admin-back').classList.toggle('invisible', !items);
    $('admin-title').textContent = items ? admin.trader.tradername : t('ui_admin_title');
    $('admin-sub').textContent = items ? `${t('ui_items')} · ${admin.trader.traderid}` : t('ui_admin_sub');
}

function renderTraders() {
    const q = $('trader-search').value.trim().toLowerCase();
    const rows = admin.traders.filter((tr) => !q || tr.tradername.toLowerCase().includes(q) || tr.traderid.includes(q));
    const list = $('trader-list');
    if (!rows.length) {
        list.innerHTML = `<div class="empty">${esc(t('ui_no_traders'))}</div>`;
        return;
    }
    list.innerHTML = rows.map((tr) => `
        <div class="row" data-id="${esc(tr.traderid)}">
            <div class="badge">&#9878;</div>
            <div class="row-main">
                <div class="row-title">${esc(tr.tradername)}<span class="pill">${tr.itemcount} ${esc(t('ui_itemcount'))}</span>${tr.showblip ? '' : `<span class="pill">${esc(t('ui_no_blip'))}</span>`}</div>
                <div class="row-desc">${esc(tr.traderid)} · ${esc(tr.npcmodel)} · ${Number(tr.x).toFixed(1)}, ${Number(tr.y).toFixed(1)}, ${Number(tr.z).toFixed(1)}</div>
            </div>
            <div class="row-actions">
                <button class="wood-btn small" data-act="items">${esc(t('ui_items'))}</button>
                <button class="wood-btn small muted" data-act="edit">${esc(t('ui_edit'))}</button>
                <button class="wood-btn small muted" data-act="tp">${esc(t('ui_teleport'))}</button>
                <button class="wood-btn small muted danger" data-act="delete">${esc(t('ui_delete'))}</button>
            </div>
        </div>`).join('');
}

function itemImage(name) {
    const it = admin.itemList.find((i) => i.name === name);
    return it && it.image ? it.image : name + '.png';
}

function itemLabel(name) {
    const it = admin.itemList.find((i) => i.name === name);
    return it ? it.label : name;
}

function renderItems() {
    const q = $('item-search').value.trim().toLowerCase();
    const rows = admin.items.filter((i) => !q || i.item.includes(q) || itemLabel(i.item).toLowerCase().includes(q));
    const list = $('item-list');
    if (!rows.length) {
        list.innerHTML = `<div class="empty">${esc(t('ui_no_items'))}</div>`;
        return;
    }
    list.innerHTML = rows.map((i) => {
        const level = stockLevel(i);
        const pct = Math.max(3, Math.min(100, (i.stock / Math.max(1, i.highstock)) * 100));
        return `
        <div class="row" data-item="${esc(i.item)}">
            <div class="badge"><img src="${esc(admin.imagePath + (itemImage(i.item)))}" onerror="this.style.display='none'"></div>
            <div class="row-main">
                <div class="row-title">${esc(itemLabel(i.item))} <span class="pill">${esc(i.item)}</span></div>
                <div class="row-desc">${esc(t('ui_stock'))} ${i.stock} · ${esc(t('ui_lowstock'))} ${i.lowstock} · ${esc(t('ui_highstock'))} ${i.highstock} · ${esc(t('ui_baseprice'))} ${money(i.baseprice)}</div>
                <div class="stat"><div class="stat-${level}" style="width:${pct}%"></div></div>
            </div>
            <div class="row-actions">
                <button class="wood-btn small muted" data-act="edit">${esc(t('ui_edit'))}</button>
                <button class="wood-btn small muted danger" data-act="delete">${esc(t('ui_delete'))}</button>
            </div>
        </div>`;
    }).join('');
}

async function loadItems() {
    const res = await post('admin:items', { traderid: admin.trader.traderid });
    admin.items = (res && res.items) || [];
    renderItems();
}

function openTraderForm(tr) {
    editingTrader = tr || null;
    $('trader-form-title').textContent = tr ? t('ui_edit_trader') : t('ui_add_trader');
    $('f-tradername').value = tr ? tr.tradername : '';
    $('f-npcmodel').value = tr ? tr.npcmodel : admin.defaultModel;
    $('f-showblip').checked = tr ? !!tr.showblip : true;
    $('f-movehere').checked = false;
    $('f-movehere-wrap').classList.toggle('hidden', !tr);
    $('f-pos-note').classList.toggle('hidden', !!tr);
    openModal('modal-trader');
}

const PICKER_LIMIT = 150;

function setPicked(name) {
    $('f-item').value = name || '';
    const it = name && admin.itemList.find((i) => i.name === name);
    $('picked').classList.toggle('empty-pick', !it);
    $('picked-label').textContent = it ? it.label : t('ui_pick_item');
    $('picked-name').textContent = it ? it.name : '';
    const img = $('picked-img');
    img.style.visibility = it ? 'visible' : 'hidden';
    if (it) img.src = admin.imagePath + itemImage(it.name);
    document.querySelectorAll('#item-picker .tile').forEach((el) => el.classList.toggle('selected', el.dataset.name === name));
}

function renderPicker() {
    const q = $('f-item-search').value.trim().toLowerCase();
    const onTrader = new Set(admin.items.map((i) => i.item));
    const matches = admin.itemList.filter((i) => !q || i.name.includes(q) || (i.label || '').toLowerCase().includes(q));
    const shown = matches.slice(0, PICKER_LIMIT);
    const current = $('f-item').value;

    $('item-picker').innerHTML = shown.length ? shown.map((i) => {
        const used = onTrader.has(i.name);
        return `<div class="tile ${used ? 'disabled' : ''} ${i.name === current ? 'selected' : ''}" data-name="${esc(i.name)}" title="${esc(i.label)} (${esc(i.name)})${used ? ' - ' + esc(t('ui_already_listed')) : ''}">
            <img src="${esc(admin.imagePath + (i.image || i.name + '.png'))}" loading="lazy" onerror="this.style.visibility='hidden'">
            <span>${esc(i.label)}</span>
        </div>`;
    }).join('') : `<div class="empty" style="grid-column:1/-1">${esc(t('ui_no_matches'))}</div>`;

    $('picker-count').textContent = matches.length > PICKER_LIMIT
        ? `${PICKER_LIMIT} / ${matches.length} — ${t('ui_refine_search')}`
        : `${matches.length}`;
}

function openItemForm(item) {
    editingItem = item || null;
    $('item-form-title').textContent = item ? t('ui_edit_item') : t('ui_add_item');
    $('picker-wrap').classList.toggle('hidden', !!item);
    $('f-item-search').value = '';
    setPicked(item ? item.item : '');
    if (!item) renderPicker();
    $('f-stock').value = item ? item.stock : 0;
    $('f-lowstock').value = item ? item.lowstock : 10;
    $('f-highstock').value = item ? item.highstock : 100;
    $('f-baseprice').value = item ? item.baseprice : '';
    openModal('modal-item');
}

function openConfirm(text, checkLabel, action) {
    $('confirm-text').textContent = text;
    $('confirm-check').checked = false;
    $('confirm-check-wrap').classList.toggle('hidden', !checkLabel);
    $('confirm-check-label').textContent = checkLabel || '';
    confirmAction = action;
    openModal('modal-confirm');
}

/* ================= EVENTS ================= */
window.addEventListener('message', (e) => {
    const d = e.data;
    if (!d || !d.action) return;

    if (d.strings) { S = d.strings; applyStrings(); }

    switch (d.action) {
        case 'openShop':
            hideAll();
            shop = { trader: d.trader, mode: d.mode, items: d.items || [], maxBuy: d.maxBuy, maxSell: d.maxSell, cash: d.cash || 0 };
            $('app').classList.remove('hidden');
            $('shop').classList.remove('hidden');
            renderShop();
            break;

        case 'openAdmin':
            hideAll();
            admin.traders = d.traders || [];
            admin.itemList = d.itemList || [];
            admin.defaultModel = d.defaultModel || '';
            admin.imagePath = d.imagePath || '';
            admin.trader = null;
            $('trader-search').value = '';
            $('app').classList.remove('hidden');
            $('admin').classList.remove('hidden');
            setAdminView('traders');
            renderTraders();
            break;

        case 'adminTraders':
            admin.traders = d.traders || [];
            if (admin.trader) admin.trader = admin.traders.find((x) => x.traderid === admin.trader.traderid) || admin.trader;
            renderTraders();
            break;

        case 'close':
            hideAll();
            $('app').classList.add('hidden');
            break;
    }
});

// Escape closes modal -> leaves items view -> closes UI. Enter submits the open modal.
document.addEventListener('keydown', (e) => {
    if ($('app').classList.contains('hidden')) return;
    if (e.key === 'Escape') {
        if (modalOpen()) closeModal();
        else if (!$('view-items').classList.contains('hidden') && !$('admin').classList.contains('hidden')) setAdminView('traders');
        else closeUI();
    } else if (e.key === 'Enter' && modalOpen()) {
        const primary = document.querySelector('.modal:not(.hidden) .actions .wood-btn:not(.muted)');
        if (primary && !primary.disabled) primary.click();
    }
});

document.querySelectorAll('[data-close]').forEach((b) => b.addEventListener('click', closeUI));
document.querySelectorAll('[data-modal-cancel]').forEach((b) => b.addEventListener('click', closeModal));
$('modal-backdrop').addEventListener('mousedown', (e) => { if (e.target.id === 'modal-backdrop') closeModal(); });

/* shop */
document.querySelectorAll('.tab').forEach((b) => b.addEventListener('click', () => {
    shop.mode = b.dataset.mode;
    renderShop();
}));

$('shop-list').addEventListener('click', (e) => {
    const row = e.target.closest('.row');
    if (!row || row.classList.contains('disabled')) return;
    openTrade(shop.items[Number(row.dataset.idx)]);
});

$('qty').addEventListener('input', updateTotal);
$('qty').addEventListener('blur', () => { if (trade) { $('qty').value = clampQty(); updateTotal(); } });
$('qty-minus').addEventListener('click', () => { $('qty').value = Math.max(1, clampQty() - 1); updateTotal(); });
$('qty-plus').addEventListener('click', () => { $('qty').value = Math.min(clampQty() + 1, Math.max(1, tradeMax(trade))); updateTotal(); });
$('qty-max').addEventListener('click', () => { $('qty').value = Math.max(1, tradeMax(trade)); updateTotal(); });

$('trade-confirm').addEventListener('click', () => {
    if (!trade) return;
    const amount = clampQty();
    post('trade', { traderid: shop.trader.id, item: trade.item, amount, mode: shop.mode });
    closeModal();
});

/* admin: traders */
$('trader-search').addEventListener('input', renderTraders);
$('btn-add-trader').addEventListener('click', () => openTraderForm(null));
$('admin-back').addEventListener('click', () => setAdminView('traders'));

$('trader-list').addEventListener('click', (e) => {
    const btn = e.target.closest('[data-act]');
    if (!btn) return;
    const tr = admin.traders.find((x) => x.traderid === btn.closest('.row').dataset.id);
    if (!tr) return;

    switch (btn.dataset.act) {
        case 'items':
            admin.trader = tr;
            $('item-search').value = '';
            setAdminView('items');
            loadItems();
            break;
        case 'edit':
            openTraderForm(tr);
            break;
        case 'tp':
            post('admin:teleport', { traderid: tr.traderid });
            break;
        case 'delete':
            openConfirm(`${t('ui_delete_trader_q')} (${tr.tradername})`, t('ui_delete_items_too'), async () => {
                const res = await post('admin:deleteTrader', { traderid: tr.traderid, removeItems: $('confirm-check').checked });
                showResult(res);
            });
            break;
    }
});

$('trader-save').addEventListener('click', async () => {
    const data = {
        tradername: $('f-tradername').value.trim(),
        npcmodel: $('f-npcmodel').value.trim(),
        showblip: $('f-showblip').checked,
    };
    if (editingTrader) {
        data.traderid = editingTrader.traderid;
        data.moveHere = $('f-movehere').checked;
    }
    $('trader-save').disabled = true;
    const res = await post('admin:saveTrader', data);
    $('trader-save').disabled = false;
    showResult(res);
    if (res && res.ok) closeModal();
});

/* admin: items */
$('item-search').addEventListener('input', renderItems);
$('btn-add-item').addEventListener('click', () => openItemForm(null));
$('f-item-search').addEventListener('input', renderPicker);
$('item-picker').addEventListener('click', (e) => {
    const tile = e.target.closest('.tile');
    if (!tile || tile.classList.contains('disabled')) return;
    setPicked(tile.dataset.name);
});

$('item-list').addEventListener('click', (e) => {
    const btn = e.target.closest('[data-act]');
    if (!btn) return;
    const item = admin.items.find((x) => x.item === btn.closest('.row').dataset.item);
    if (!item) return;

    if (btn.dataset.act === 'edit') openItemForm(item);
    if (btn.dataset.act === 'delete') {
        openConfirm(`${t('ui_delete_item_q')} (${itemLabel(item.item)})`, null, async () => {
            const res = await post('admin:deleteItem', { traderid: admin.trader.traderid, item: item.item });
            showResult(res);
            if (res && res.ok) { loadItems(); post('admin:refresh'); }
        });
    }
});

$('item-save').addEventListener('click', async () => {
    const data = {
        traderid: admin.trader.traderid,
        item: $('f-item').value.trim().toLowerCase(),
        stock: $('f-stock').value,
        lowstock: $('f-lowstock').value,
        highstock: $('f-highstock').value,
        baseprice: $('f-baseprice').value,
        isNew: !editingItem,
    };
    if (!data.item) { toast('error', t('ui_pick_item')); return; }
    $('item-save').disabled = true;
    const res = await post('admin:saveItem', data);
    $('item-save').disabled = false;
    showResult(res);
    if (res && res.ok) { closeModal(); loadItems(); post('admin:refresh'); }
});

$('confirm-ok').addEventListener('click', async () => {
    const action = confirmAction;
    confirmAction = null;
    closeModal();
    if (action) await action();
});

/* ================= DRAGGABLE PANELS ================= */
// drag a panel by its header; position is remembered per panel. Double-click the header to reset.
const POS_KEY = 'rsg-trader:pos:';

function clampPos(panel, left, top) {
    const maxL = window.innerWidth - panel.offsetWidth;
    const maxT = window.innerHeight - panel.offsetHeight;
    return [Math.min(Math.max(0, left), Math.max(0, maxL)), Math.min(Math.max(0, top), Math.max(0, maxT))];
}

function placePanel(panel, left, top) {
    [left, top] = clampPos(panel, left, top);
    panel.style.left = left + 'px';
    panel.style.top = top + 'px';
    panel.style.right = 'auto';
    panel.style.transform = 'none';
    panel.classList.add('moved');
}

function resetPanel(panel) {
    panel.style.left = panel.style.top = panel.style.right = panel.style.transform = '';
    panel.classList.remove('moved');
    try { localStorage.removeItem(POS_KEY + panel.id); } catch (e) {}
}

function restorePanel(panel) {
    try {
        const saved = JSON.parse(localStorage.getItem(POS_KEY + panel.id) || 'null');
        if (saved) placePanel(panel, saved.left, saved.top);
    } catch (e) {}
}

function makeDraggable(panel) {
    const handle = panel.querySelector('.panel-header');
    let start = null;

    handle.addEventListener('mousedown', (e) => {
        if (e.button !== 0 || e.target.closest('button, input')) return;
        const r = panel.getBoundingClientRect();
        start = { x: e.clientX, y: e.clientY, left: r.left, top: r.top };
        panel.classList.add('dragging');
        e.preventDefault();
    });

    window.addEventListener('mousemove', (e) => {
        if (!start) return;
        placePanel(panel, start.left + e.clientX - start.x, start.top + e.clientY - start.y);
    });

    window.addEventListener('mouseup', () => {
        if (!start) return;
        start = null;
        panel.classList.remove('dragging');
        const r = panel.getBoundingClientRect();
        try { localStorage.setItem(POS_KEY + panel.id, JSON.stringify({ left: r.left, top: r.top })); } catch (e) {}
    });

    handle.addEventListener('dblclick', (e) => {
        if (!e.target.closest('button')) resetPanel(panel);
    });

    // re-apply saved position whenever the panel is shown (size may differ per trader)
    let wasHidden = panel.classList.contains('hidden');
    new MutationObserver(() => {
        const hidden = panel.classList.contains('hidden');
        if (wasHidden && !hidden) requestAnimationFrame(() => restorePanel(panel));
        wasHidden = hidden;
    }).observe(panel, { attributes: true, attributeFilter: ['class'] });
}

makeDraggable($('shop'));
makeDraggable($('admin'));
window.addEventListener('resize', () => ['shop', 'admin'].forEach((id) => {
    const p = $(id);
    if (p.classList.contains('moved')) placePanel(p, p.offsetLeft, p.offsetTop);
}));
